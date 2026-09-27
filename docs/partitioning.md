# Partition planner — internals

The planner is a **pure function**: `InstallConfig + ProbeResult → DiskPlan`.
It never touches the OS. The same plan object backs the wizard's live
preview (P1), VALIDATE, `--dry-run` output, and the `partition`/`mount`
pipeline steps — the user always sees exactly what will run.

```
probe ──► DiskPlan ──► VALIDATE ──► [Cmd] ──► Runner
(detect)   (ops list)   (rules)    (sgdisk…)   (Real|Dry)
```

`DiskPlan` is a list of tagged ops; each op records the device paths and
IDs it will produce so resume can verify them against `blkid` output
instead of trusting the journal blindly.

## Probing

`probe` reads (no writes): `lsblk -J -b -O`, `blkid`, `/sys/block/*`,
`efibootmgr -v` (UEFI only), `/proc/partitions`, DMI vendor. It produces:

- `disks[]` — model, size, sector size (512 vs 4Kn), transport
  (nvme/mmc/sata/usb), current table type, `live_host` flag.
- `parts[]` — per disk: PARTUUID, fs type+uuid, size, flags, free-space
  regions (start/end, ≥1 MiB aligned).
- `oses[]` — detected OSes: Windows (`/EFI/Microsoft/Boot/bootmgfw.efi`
  on ESP + `ntfs` part), Linux (`os-release` on discovered roots), BSD
  (ufs/zfs parts), macOS (apfs/hfs+). Drives the `alongside` visibility
  rule and dual-boot menu generation.
- `esps[]` — existing ESPs (EF00 parts) with size and free space.

The disk hosting the live environment is flagged `live_host` and never
offered as a target.

## Ops

| op | payload | notes |
|---|---|---|
| `wipe_table` | disk, table=gpt | wipefs + fresh GPT |
| `create_part` | disk, start, size_mib, type GUID, name | MiB-aligned |
| `format` | part, fs, label, fs_opts | mkfs.* |
| `luks_format` | part, pbkdf=argon2id, label | passphrase via stdin file |
| `luks_open` | part, name=`cryptroot` | `--key-file -` |
| `pvcreate` / `vgcreate` | device, vg=`vg0` | on raw part or opened LUKS |
| `lvcreate_thinpool` | vg, name=`tank`, size | only when `lvm=on` ∧ `snapshots!=off` |
| `lvcreate` | vg, name, size (linear) or thin LV on `tank` | root/home |
| `btrfs_subvol` | mountpoint, name | `@`, `@home`, `@snapshots` |
| `resize_fs` | part, shrink_mib | `ntfsresize`/`resize2fs`/`btrfs filesystem resize` |
| `move_part` | — | *v2+ only* — never in v1 alongside |
| `mount` / `swap_on` / `zram` | target, opts | mount step ops |

Every `create_part`/`format` op carries ID postconditions so `--resume`
and `detect --repair` can distinguish "op already applied" from "op
needed". IDs are **prescribed where the tool allows** — `sgdisk -u
<part>:<GUID>` sets the planned PARTUUID; `mkfs.* -U` (btrfs/ext4/f2fs),
`-m uuid=` (xfs), `-i` (vfat — a 32-bit serial surfaced as `XXXX-XXXX`,
FAT has no real UUID) set fs ids; `cryptsetup luksFormat --uuid` sets
the LUKS UUID; `pvcreate --uuid <u> --norestorefile` sets the PV uuid
(the restorefile flag is required alongside `--uuid`). What remains
unprescribed — VG/LV uuids — is probed with the LVM tools
(`vgs`/`lvs -o *_uuid`, not `blkid`) and journaled.

Repair after a reboot (live journal gone) anchors on prescribed IDs,
never generated ones: a partition slot is identified by its planned
PARTUUID; `cryptsetup isLuks` or an LVM PV signature on that slot
proves `luks_format`/`pvcreate` ran; `vg0`/`tank`/`root` names plus
the parent PV's signature are the VG/LV identity check. With `luks=on`
the PV sits *inside* `cryptroot` — repair first asks for the
passphrase (or `--key-file` in unattended runs) and opens the
container before probing inner layers; until unlocked, those ops
report `unknown` (locked), never `done`.

## Layer stacking (fixed order)

```
GPT partitions ──► LUKS2 ──► LVM ──► filesystems
                  (argon2id)  (thin pool when snapshots on)
```

- ESP is always raw FAT32, never encrypted, never in LVM.
- `boot_part` (expert) adds a separate unencrypted `/boot` — required
  for layouts where the bootloader can't read the root stack (limine
  BIOS mode + LUKS, FDE purists).
- LUKS-on-LVM (encrypting LVs individually) is deliberately unsupported —
  LVM-on-LUKS gives one passphrase, one initramfs hook.
- btrfs subvols are created on the mounted fs as mount-time ops, not
  partition ops.

## Layouts

### `normal` (UEFI erase-disk)

```
┌──────────────┬────────────────────┬──────────────────────────┐
│ ESP          │ swap (8200)        │ root (8304 DPS GUID)     │
│ EF00, FAT32  │ only if            │ btrfs default            │
│ esp_mib      │ swap=partition     │ @ @home @snapshots       │
└──────────────┴────────────────────┴──────────────────────────┘
```

- DPS (Discoverable Partitions Spec) GUIDs so systemd can auto-discover
  the rootfs — fstab becomes optional on systemd+UEFI.
- `lvm=on`: root part becomes a PV → `vg0`; with `snapshots!=off` a thin
  pool `tank` (~all free VG space) + thin `root` LV; else linear LVs.
- `luks=on`: root part (or the PV) sits inside `cryptroot`.

### `bios-boot-swap-root` (BIOS)

`EF02` BIOS-boot partition (1 MiB) instead of ESP — GPT has no
post-MBR gap, so both grub's core image and limine's stage2 embed
there (`limine bios-install <disk> 1`). `boot_part` creates a 1 GiB
/boot; under limine it is FAT32 because limine ≥12 reads only
FAT/ISO9660 (ext support was dropped upstream).

### `alongside`

State machine:

```
detect OSes ──► space_src?
                 ├─ free-space: largest unallocated region ≥ MIN_INSTALL
                 └─ shrink: pick shrinkable part (ntfs|ext4|btrfs) with
                    free space ≥ shrink_mib + fs reserve
                                    │
                 ┌──────────────────┴──────────────────┐
                 ▼ reuse existing ESP                   ▼ append parts
           warn if ESP free < 256 MiB          root (+swap) in new space
```

- Never reformats the existing ESP; Windows Boot Manager preserved.
  Bootloader files land under a scoped dir (`EFI/gentoo` for the stock
  preset — `EFI/<preset.id>`) so a new install never overwrites another
  loader — the ESP write list is part of the plan preview, and the
  alongside ack notes the ESP gains files (nothing removed). limine
  also appends `efi_chainload` stanzas for detected loaders
  (`EFI/Microsoft/Boot/bootmgfw.efi`, `EFI/BOOT/BOOTX64.EFI`); grub
  emerges os-prober with `GRUB_DISABLE_OS_PROBER=false`.
- `resize_fs` runs **before** the partition shrink so fs metadata is
  consistent; ntfsresize then sgdisk resize; `ntfsfix`-clean required
  first (dirty NTFS ⇒ refuse with instructions to `chkdsk` / full
  shutdown, not fastboot-hibernation).
- xfs/f2fs cannot shrink → `space_src=free-space` only; if no free space
  either, `alongside` is not offered for that disk.
- BitLocker-protected NTFS ⇒ refuse early (recovery key + decrypt first).

### `manual` (expert)

Free-form table producing the same plan ops as guided layouts — so
validate, preview, and exec work identically. The table is a list of
`[[disk.partitions]]` entries in the answer file:

```toml
[[disk.partitions]]
size  = "512MiB"   # <n>MiB | <n>GiB | "rest" ("rest" last only, ≤1)
type  = "EF00"     # GPT type code (EF00 ESP, EF02 BIOS boot, 8200 swap,
                   #   8300/8304 Linux)
name  = "ESP"      # partition label (GPT PARTLABEL)
fs    = "vfat"     # vfat|ext4|xfs|btrfs|f2fs|bcachefs|swap|none
                   #   ("none" = leave unformatted)
mount = "/efi"     # absolute mount point, or "" (unmounted)
```

In the wizard's text field the same table is one row per entry,
`size:type:name:fs:mount` colon-separated, `;` or newline between
entries (`-` = empty name):
`512MiB:EF00:ESP:vfat:/efi; rest:8304:root:btrfs:/`

Rules the validator enforces: exactly one row mounts `/` with a root
filesystem; UEFI needs a `type=EF00 fs=vfat` row (its mount is the ESP —
default `/efi` when omitted); BIOS needs a `type=EF02` BIOS-boot row
(grub core image / limine stage2 embed target — GPT has no post-MBR
gap) and rejects `EF00`; BIOS + limine needs a `mount="/boot"
fs="vfat"` row (limine ≥12 reads only FAT — no ext4, and LUKS roots
get their kernel+initramfs from the FAT /boot either way); mounts are deduplicated; an explicit root size below 8 GiB
is refused; `swap` fs rows take no mount and are swapped on at mount
time; `lvm` and `swap=partition` are guided-layout features and are
rejected (express volumes as plain partitions); `luks=on` still wraps
the `/` row exactly as in guided mode.

## Sizing rules

| thing | rule |
|---|---|
| `esp_mib` | ≥128; default 512; forced ≥512 when `uki` or systemd-boot (kernels on ESP) |
| `boot` part | 512 MiB–1 GiB when expert-enabled |
| swap partition | default 4 GiB; hibernation needs ≥ RAM — wizard warns, doesn't default it |
| zram | `size = min(ram/2, 8 GiB)`, `zstd`, `vm.swappiness=180` — see below |
| min install | root ≥ 8 GiB (stage3 + toolchain + minimal world) |
| alignment | 1 MiB everywhere; first usable sector 2048 on 512e, native on 4Kn |
| thin pool | `tank` gets ~all VG free space; root thin LV virtual size = `tank` size (no overcommit by default — expert can overprovision); snapshots are thin snapshots sharing the pool |

**zram vs zswap:** `swap=zram` (default) — zram device as swap, no disk
I/O, best on modest RAM. `swap=partition` additionally gets `zswap`
enabled (compressed write-back cache before the swap partition) — memory
efficiency without giving up swap capacity. `swap=none` is allowed with
a "no swap at all" warning when RAM < 8 GiB.

## VALIDATE (planner)

- Layout bounds: sum(parts) ≤ disk, all MiB-aligned, GPT entry limits.
- `alongside` ⇒ `wipe=false`, UEFI boot mode, GPT label, ESP exists,
  `space_src` resolvable (BIOS ⇒ refuse: no foreign-OS chainload path).
- `luks|lvm|boot_part` ⇒ `initramfs != none`.
- `root_fs` on target part: fs tools present on live env
  (`mkfs.btrfs`/`mkfs.xfs`/`mkfs.f2fs`/`bcachefs` availability gate —
  flagged at detect, offered options filtered accordingly).
- `shrink` ⇒ fs ∈ {ntfs, ext4, btrfs} ∧ fs clean ∧ free space suffices.
- `secure_boot!=off` ⇒ UEFI boot mode.
- Result: error list with codes; the wizard renders them inline on P1.

## Cmd rendering

`DiskPlan → [Cmd]` is mechanical: `wipefs`/`sgdisk`/`partprobe`,
`cryptsetup luksFormat --pbkdf argon2id --key-file -`, `lvm` tools,
`mkfs.*`, `mount -o subvol=`. Secrets (LUKS passphrase) travel only via
stdin files with mode 0400, deleted after use — never argv, never the
journal, never `Cmd` serialization (the dry-run log redacts them).

## Resume & repair

- Op tags + postconditions (PARTUUID/fs-uuid) make each step
  idempotent: re-running skips ops whose postcondition already holds
  on-disk.
- `detect --repair` (post-reboot, journal gone): reprobe, diff observed
  state against a planned `DiskPlan`, classify ops as done/pending/failed.
- The point of no return is the **first mutating op**: `wipe_table` on
  erase layouts, `resize_fs` on alongside (which has no wipe_table).
  P7's gate stands immediately before it — type-the-disk for
  `wipe=true`; for alongside, a **plan-derived** acknowledgement:
  "shrink <fs> on <part> by N MiB" under `space_src=shrink`, "create
  partitions in unallocated space beside <os>" under `free-space`
  (nothing existing is touched). Every op before the gate is
  read-only.
