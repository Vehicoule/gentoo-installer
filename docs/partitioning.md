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
<part>:<GUID>` sets the planned PARTUUID, `mkfs.* -U` (btrfs/ext4/f2fs)
/ `-m uuid=` (xfs) / `-i` (vfat) set the fs uuid — and **captured
post-op where they can't be** (LUKS container UUID via
`cryptsetup luksUUID`, md/LVM metadata ids via `blkid` after partprobe).
Either way the journal records what the disk actually ended up with.

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

`EF02` BIOS-boot partition (1 MiB, grub core image) instead of ESP;
`/boot` on rootfs unless `boot_part`. Limine BIOS mode needs only the
MBR gap it installs into — no EF02 required when bootloader=limine.

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
- `resize_fs` runs **before** the partition shrink so fs metadata is
  consistent; ntfsresize then sgdisk resize; `ntfsfix`-clean required
  first (dirty NTFS ⇒ refuse with instructions to `chkdsk` / full
  shutdown, not fastboot-hibernation).
- xfs/f2fs cannot shrink → `space_src=free-space` only; if no free space
  either, `alongside` is not offered for that disk.
- BitLocker-protected NTFS ⇒ refuse early (recovery key + decrypt first).

### `manual` (expert)

Free-form table editor producing the same `DiskPlan` op list — so
VALIDATE, preview, and resume work identically. Nothing is type-specific
to guided layouts.

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
- `alongside` ⇒ `wipe=false`, ESP exists, `space_src` resolvable.
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
  P7's gate — type-the-disk for `wipe=true`, the "existing OS will be
  modified/shrunk" acknowledgement for alongside — stands immediately
  before that op in the stream; every op before it is read-only.
