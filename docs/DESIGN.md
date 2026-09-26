# gentoo-installer — Design

A guided installer for Gentoo Linux with a modern interface, built for
extensibility toward a downstream Gentoo-based distribution.

**Status:** draft (first commit)

## Goals

- Make a Gentoo install feel like a modern OS install: a guided wizard with
  sane defaults, visible progress, and no copy-pasting from the Handbook.
- Two frontends on one engine: a **TUI** that runs on the minimal ISO
  (~140 MB RAM, no graphics, possibly no terminfo) and a **GUI** that runs
  on the LiveGUI (KDE/Qt, Wayland).
- Cover the full matrix Gentoo offers — init systems, stage3 flavors
  (glibc **and** musl, gcc **and** llvm/clang toolchains, hardened /
  hardened-selinux), filesystems, LUKS/LVM/RAID, kernels, bootloaders —
  and the **amd64 / arm64 / riscv64** architectures.
- **Dual-boot**: detect existing OSes (Windows, other Linux, FreeBSD) and
  install alongside them — shrink/make room, keep the existing ESP,
  register both systems in the boot menu.
- **UEFI and BIOS/CSM** boot paths on amd64 (UEFI primary; BIOS supported
  for legacy hardware).
- **Secure Boot**: a real signing flow — sbctl-managed keys or shim+MOK —
  so UKI/GRUB installs boot with SB enabled.
- **Mass-install automation**: `--config` answer files plus the headless
  protocol are a first-class product surface — a fleet tool or CI can
  drive installs without any UI.
- Be the installer for a future Gentoo-based distro: presets, branding, and
  extra steps are data, not forks.
- Memory efficiency is a project value: the installer must be a small static
  binary with no runtime deps beyond what the live environment already has.

## Non-goals (v1)

- Split-usr and x32 stage3 flavors (accepted by the config schema, gated
  behind "expert" until validated).
- Replacing the Handbook for experts — `gentoo-installer --config` gives a
  scriptable path; the wizard targets the guided experience.

## Stack

| Piece | Choice | Why |
|---|---|---|
| Engine + TUI | **Zig** (pinned via `build.zig.zon`) | tiny static binaries, best-in-class cross-compile to aarch64/riscv64/musl, systems-programming fit |
| TUI framework | **libvaxis** (`vxfw` widget layer) | active, Flutter-like model, and — critically — does capability detection via terminal queries, **no terminfo dependency** (minimal ISO has a stripped terminfo db) |
| GUI | **Rust + libcosmic** (iced + COSMIC widgets/theme) | the distro's future DE is COSMIC-flavored; the installer becomes a native-looking app of that DE and reuses its stack |
| Engine↔GUI link | headless subprocess protocol (JSONL) | the GUI is a thin shell; any frontend (GUI, web, remote) can drive the same engine |

Rejected: gpui (Vulkan-only, heavyweight, tracks zed git), Slint (excellent but
loses to libcosmic given the DE direction), GTK/Qt (runtime deps / footprint),
Rust core (ratatui is fine but Zig core + Rust TUI buys an FFI seam across the
hottest interface for nothing).

## Architecture

```
┌─────────────┐        ┌──────────────────────────────────┐
│  TUI binary │──in-proc─▶│         Zig engine lib          │
│ (libvaxis)  │        │                                  │
└─────────────┘        │  wizard state machine             │
┌─────────────┐  JSONL │  install pipeline (steps)         │
│  GUI binary │◄──────▶│  hardware/env detection           │
│ (libcosmic) │ stdin/ │  command runner (real|dry-run)    │
│             │ stdout │  stage3/verify, portage gen       │
└─────────────┘        └──────────────────────────────────┘
        ▲
        └──────── `gentoo-installer --headless`
                  config in (JSON) → events out (JSONL)
```

### Key decisions

- **The wizard state machine lives in the engine**, not in the frontends.
  `gentoo-installer wizard --headless` exposes `GET page`, `SET field`, `NEXT`,
  `BACK`, `VALIDATE` over JSONL, so TUI and GUI can never drift apart and
  `--config file` (unattended) is the same engine with a prefilled config.
  Two flows — **Express** (opinionated defaults pre-selected; asks only
  for disk, confirmation, credentials) and **Advanced** (every field
  editable) — differ only in page visibility, never in behavior.
- **Every side effect is a `Cmd` through a `Runner`.** `RealRunner` execs;
  `DryRunner` logs. Nothing in the pipeline touches the OS except through this
  seam — that is what makes `--dry-run`, unit tests, and the QEMU harness work.
- **Steps are idempotent and checkpointed.** The engine writes a journal
  after each step at `/var/lib/gentoo-installer/state.json` **in the live
  env** (tmpfs) — so `detect`/`partition`/`mount` are checkpointed before
  the target exists — and mirrors it to
  `/mnt/gentoo/var/lib/gentoo-installer/state.json` once `mount` lands, for
  forensics. `--resume` reads the live-env journal, re-derives mounts from
  it (re-mounting target partitions per the recorded disk plan), and
  re-enters at the last completed step. Like the Handbook's "remount and
  re-chroot" story, resume is same-boot only: a rebooted live env loses the
  tmpfs journal, so the engine then offers `detect --repair` (probe disks
  for a partially-written install) rather than blind replay.
- **Distro preset = data.** A preset TOML provides: branding (name, logo,
  colors), a default `InstallConfig` overlay (init system, profile, package
  set), optional extra steps (shell snippets with descriptions), and the
  post-install hook used to drop in the distro's own WM/tools. Stock Gentoo
  is the built-in preset.

## The pipeline

Ordered engine steps (each emits `step_started` / `log` / `step_finished`
events; failures emit `step_failed` with a retry/skip/abort choice where
sensible):

1. **detect** — boot mode (UEFI vs BIOS via `/sys/firmware/efi`), arch
   (`uname -m` → amd64/arm64/riscv64), RAM, CPU flags (`cpuid2cpuflags`
   equivalent), network reachability, clock sanity (offer `chronyd -q`).
2. **partition** — guided layouts: `efi+swap+root` (GPT, EF00/8200/8304
   DPS GUIDs) or `bios-boot+swap+root`; LUKS2 container option; LVM option;
   `alongside` mode for dual-boot (probe existing OSes via os-prober-style
   detection + ESP inspection, offer shrink of ntfs/ext4/btrfs —
   xfs/f2fs cannot shrink, so there we require existing unallocated
   space — then reuse the existing ESP); manual passthrough.
   `sgdisk`/`wipefs`/`cryptsetup`/`mkfs.*`/`ntfsresize`/`resize2fs`.
3. **mount** — root at `/mnt/gentoo`, ESP at `/efi` (or `/boot` for BIOS);
   bind-mounts for chroot.
4. **stage3** — resolve `latest-stage3-<stem>.txt` pointer on the distfiles
   mirror → download `.tar.xz` + `.asc` + `.DIGESTS` → GPG-verify against
   `openpgp-keys-gentoo-release` → `tar --xattrs-include='*.*'
   --numeric-owner` extract.
5. **portage-config** — generate `make.conf` (CFLAGS by safe/native/nocona
   preset, MAKEOPTS from nproc/mem, CPU_FLAGS_* from detection,
   VIDEO_CARDS), `repos.conf`, `package.use/installkernel` per bootloader
   choice, `binrepos.conf` + `FEATURES=getbinpkg` when the official binhost
   is enabled (signature verification is on by default in current Portage).
6. **enter-chroot** — resolv.conf copy, `/proc /sys /dev /run` mounts
   (rslave semantics), `arch-chroot` when available.
7. **repo-sync** — `emerge-webrsync` (firewall-friendly) or `emerge --sync`
   over git/rsync; on arm64/riscv64 where webrsync snapshots exist likewise.
8. **profile** — `eselect profile set` derived from stage3 + desktop toggle.
9. **world-update** — `emerge -uDN @world` (skippable; recommended on
   profile/USE changes).
10. **base-config** — timezone, locales (`locale.gen` + `locale-gen` +
    `eselect locale`), keymap (`/etc/conf.d/keymaps` or `localectl`).
11. **firmware-kernel** — `linux-firmware`, `sof-firmware`, CPU microcode
    (`intel-microcode`/`linux-firmware` amd), kernel per choice below.
12. **fstab** — generated from blkid PARTUUIDs; skipped entirely for
    systemd+DPS+UEFI layouts (auto-discovery).
13. **system-config** — hostname, `/etc/hosts`, root password, user
    accounts (`useradd -m -G wheel,audio,video,...`), sudo/doas.
14. **services** — init-appropriate: `systemctl enable` / `rc-update add`
    / runit `ln -s /etc/sv/* /run/runit/service` / s6-rc bundle edits,
    for network (dhcpcd/NetworkManager/netifrc/systemd-networkd), sshd,
    logger (sysklogd on OpenRC), cron (cronie), chrony.
15. **bootloader** — GRUB (BIOS `grub-install /dev/X`; UEFI
    `grub-install --efi-directory=/efi` + `grub-mkconfig`), systemd-boot
    (`bootctl install`, kernels at `/efi`), EFI-stub/UKI via
    `installkernel[uki dracut]`, **Limine** (UEFI + BIOS modes — a shipped
    kernel-install plugin rewrites `limine.conf` on kernel emerge), or
    **rEFInd** (UEFI; auto-discovers kernels/UKIs on the ESP).
    `--removable` fallback offered when efivars are unavailable.
    **Seamless upgrades** are a hard requirement: every supported
    bootloader regenerates/picks up new kernel entries automatically via
    installkernel hooks. **Rollback** is bootloader-agnostic and two-
    layered: kernel rollback keeps the last `keep_kernels`
    kernels+initramfs with live boot entries (never pruned unprompted);
    system snapshots come from a hook that snapshots root before each
    `world-update` or kernel install — btrfs `@snapshots` subvol on the
    default layout, or an LVM-thin snapshot when `lvm=on` (the planner
    then provisions a thin pool + thin root LV, not just a VG) — and
    registers a boot entry per snapshot. Entry generation is per-
    bootloader: limine/grub/systemd-boot emit menu entries from our
    hooks; rEFInd gets generated `refind.conf` stanzas carrying
    `options="rootflags=subvol=@snapshots/<n>"` (auto-discovery alone
    only finds ESP kernels, never snapshot roots); efistub has no menu
    at all — snapshots stay recoverable by adding `rootflags=subvol=`
    to a manual UEFI entry or from live media (no per-snapshot NVRAM
    churn). CoW-less roots (xfs/ext4/f2fs without LVM) get kernel
    rollback only — P1 surfaces that trade-off at fs selection.
    **Secure Boot**: sign the boot path —
    sbctl-generated keys enrolled via firmware setup mode (or shim+MOK
    for GRUB), `sbctl sign` on UKIs/bootloader binaries, ukify hooks so
    future kernel installs stay signed. **Dual-boot**: every detected OS
    gets a menu entry on every menu-capable bootloader — grub merges
    `os-prober` output, systemd-boot auto-discovers ESP entries, rEFInd
    discovers them too, and our limine plugin emits `efi_chainload`
    entries for ESP-resident loaders (e.g.
    `EFI/Microsoft/Boot/bootmgfw.efi`). efistub needs nothing — the
    firmware boot menu already lists the foreign entries. Windows Boot
    Manager entry always preserved.
16. **finish** — `passwd -l root` when `root.lock_root`, artifact cleanup
    (`/stage3-*`), preset post-install hook, summary + reboot prompt.

## Config model

Single `InstallConfig` (TOML on disk / JSON over the wire), defaulted by the
active preset and editable through the wizard. Shape:

```toml
arch        = "amd64"            # amd64 | arm64 | riscv64
boot_mode   = "uefi"             # detected; uefi | bios

[disk]
device      = "/dev/sda"
wipe        = true               # must be false when scheme = "alongside"
scheme      = "efi-swap-root"    # | bios-boot-swap-root | alongside | manual
root_fs     = "btrfs"            # btrfs | xfs | ext4 | f2fs (+expert bcachefs)
swap        = "zram"             # zram | partition | none
swap_mib    = 4096               # only when swap=partition
boot_part   = false              # separate /boot (expert crypto layouts)
luks        = false              # LUKS2 on root (passphrase via stdin only)
lvm         = false              # LVM2 vg on the raw root part (or inside
                                # LUKS); with snapshots!=off provisions a thin
                                # pool + thin root LV

# alongside mode only:
space_src   = "shrink"            # shrink | free-space — free-space reuses the
                                # largest contiguous unallocated region (≥ min
                                # install size) and touches no partition
shrink_part = "/dev/sda3"         # shrink only: partition to shrink (ntfs/ext4/btrfs)
shrink_mib  = 61440               # shrink only: space to free for the new install
# unattended dual-boot = scheme "alongside" + space_src: "shrink" requires
# shrink_part + shrink_mib; "free-space" needs neither shrink_* field.

[stage3]
# axes-based selection; variant stem is resolved from these
libc        = "glibc"            # glibc | musl (musl disables systemd)
toolchain   = "gcc"              # gcc | llvm
variant     = "hardened-selinux-systemd"  # resolved stem; per-arch
                               # availability via the axes table
mirror      = "https://distfiles.gentoo.org"

[system]
init        = "systemd"          # openrc | systemd | runit | s6 | dinit
                               # all offered; alt inits install via
                               # post-stage3 swap — see "Init systems"
hostname    = "gentoo"
timezone    = "UTC"              # autodetected via geoip when possible
locales     = ["en_US.UTF-8"]    # locale.gen entries
locale      = "en_US.UTF-8"      # default LANG (⊂ locales)
keymap      = "us"
kernel      = "dist-bin"         # dist-bin | dist | manual
bootloader  = "auto"             # auto | grub | systemd-boot | efistub | limine | refind
                               # Express pins limine (uniform BIOS+UEFI); auto
                               # is the Advanced-flow default resolution
initramfs   = "dracut"           # dracut | ugrd | none
uki         = false              # unified kernel image
binhost     = true               # official gentoo binhost
privilege   = "doas"             # doas | sudo | none (none ⇒ root unlocked)
keep_kernels = 3                 # boot entries retained; 0 = never prune
snapshots   = "auto"             # auto | off — auto: btrfs @snapshots, or
                                # lvm-thin when lvm=on; CoW-less roots get
                                # kernel rollback only

[makeconf]
cflags      = "native"           # safe | native | custom "<flags>"
jobs        = 0                  # 0 = auto (nproc, mem-capped)
mem_cap_gib = 0                  # 0 = auto (~2 GiB/job heuristic)
video_cards = "auto"
accept_license = "@FREE"

[network]
manager     = "networkmanager"   # networkmanager | dhcpcd | netifrc | systemd-networkd
wifi        = true

[services]
sshd = false
logger = true                    # sysklogd (openrc) — journald covers systemd
cron   = true
ntp    = true                    # chrony / systemd-timesyncd

[[users]]
name = "larry"
groups = ["wheel", "audio", "video"]
shell = "/bin/bash"
# credentials: TUI/GUI prompt interactively and never persist plaintext.
# For `--config` (unattended) supply one of:
password_hash = "$6$rounds=…"       # crypt() hash, e.g. `openssl passwd -6`
ssh_authorized_keys = ["ssh-ed25519 AAAA…"]
# a user with neither is created locked (`useradd` + `passwd -l`)

[root]
password_hash = "$6$…"              # same rule; absent = root stays locked
lock_root = false                   # `passwd -l root` at finish (sudo-only box)

# VALIDATE must prove at least one login path exists *after* install
# options are applied: a password_hash on an account that survives to the
# finished system (lock_root = true doesn't count), OR services.sshd =
# true with at least one ssh_authorized_keys. Key-only + sshd=false, or
# root-hash + lock_root with nothing else, are rejected — they would
# yield a system no one can log into.

[security]
secure_boot = "off"              # off | sbctl | shim — UEFI only
hardening   = "hardened-selinux" # standard | hardened | hardened-selinux
                               # default ON per project direction; selects
                               # the hardened-* stage3 stem (toolchain is
                               # baked in — cannot be layered on later)
selinux     = true               # additive: sec-policy/* + refpolicy;
                               # forces a hardened-selinux stem

[packages]
sets = ["minimal"]               # preset-defined package sets
atoms = []                       # extra package atoms (world)

[use]
global = {}                      # "flag" = true|false (unset = profile default)
[use.pkg]                        # per-package package.use records
# "sys-kernel/gentoo-kernel" = "dracut uki"

[extra]
update_world = true
```

### Stage3 variant matrix (amd64 names shown; mapped per-arch)

`openrc`, `systemd`, `desktop-openrc`, `desktop-systemd`,
`nomultilib-*`, `hardened-*`, `hardened-selinux-*`, `musl-*`,
`musl-hardened-*`, `musl-llvm-*`, `llvm-*`, `openrc-splitusr`, `x32-*`.

Selection is **axes-based**: `libc × toolchain × hardening × init` map to
a stage3 stem (glibc+llvm+hardened ⇒ `hardened-llvm-*`; musl+llvm ⇒
`musl-llvm-*`; plain glibc+gcc+systemd ⇒ `systemd`). Hardening is baked
into the stage3 toolchain — it cannot be applied atop a standard stage3
— while SELinux policy is additive (sec-policy/*, refpolicy). Defaults:
glibc, gcc, `hardened+selinux`, per project direction.

The userland is GNU on every stem (glibc or musl libc + coreutils):
portage ebuilds assume GNU/POSIX tools throughout the tree, so leaner
userlands (busybox, uutils coreutils) are a preset-layer concern, not an
install-time axis.

Constraints: `musl` ⇒ no systemd (needs glibc); runit/s6/dinit OK on
either libc; `*-systemd` stems ⇒ systemd. nomultilib and x32 stay
expert-gated until the QEMU matrix covers them.

arm64/riscv64 differences handled by an `arch table`: stage3 stems
(`stage3-arm64-openrc`, `stage3-rv64_lp64d-openrc` …), profile names, boot
media availability (riscv has no minimal ISO — installer runs in any Linux
live env there), and bootloader choices (grub-efi, systemd-boot, or
firmware-specific like U-Boot on some riscv boards — v1 amd64 only for
bootloader writes; arm64/riscv64 installs land the userland + fstab and
document the firmware step until validated).

### Init systems

All five inits are offered in the wizard — `openrc`, `systemd` are
first-class (they have stage3s and profiles); `runit`, `s6` (+s6-rc),
`dinit` carry an "early support" badge: no official stage3s exist, so
those installs extract a normal stage3 and swap the init. An
`init-backend` engine interface (`services`, `logger`, `getty`, `boot`
wiring per init) keeps the pipeline agnostic. Constraint: `musl` removes
only systemd — the supervision inits work fine on musl.

## Headless protocol (GUI ↔ engine)

`gentoo-installer --headless` (or `gentoo-installer wizard --headless`):

```jsonl
→ {"op":"hello","version":1}
← {"ev":"hello","engine":"0.1.0","caps":["wizard","install","detect"]}
→ {"op":"detect"}
← {"ev":"env","boot":"uefi","arch":"amd64","ram_mib":15625,...}
→ {"op":"get_config"}            ← {"ev":"config","config":{...}}
→ {"op":"page"}                  ← {"ev":"page","id":"disks","fields":[...]}
→ {"op":"set","field":"stage3.variant","value":"desktop-systemd"}
→ {"op":"next"}                  ← {"ev":"page","id":"variant",...}
→ {"op":"install","dry_run":false}
← {"ev":"step","i":4,"of":16,"name":"stage3","state":"started"}
← {"ev":"log","line":"downloading stage3-amd64-desktop-systemd-…"}
← {"ev":"step","i":4,"state":"done","secs":41.2}
← {"ev":"done","ok":true}
```

Errors carry `{code, message, hint}`; the GUI renders them as dialogs, the
TUI as an error page. `wizard` commands that need a choice
(`confirm_wipe`, `ask_retry`) are first-class ops. Answer-file export
serializes the current `InstallConfig` to TOML; interactive passwords are
converted to `password_hash` at export (no plaintext, file mode 0600).

## Safety

- Target disk confirmation: type-the-disk-name gate; the plan's partition
  table is rendered before apply.
- `--dry-run` always available; the review page offers "print plan" —
  shows the exact command list.
- Journal + resume: remount-aware; `gentoo-installer --resume` re-enters an
  interrupted install at the last step (Handbook-equivalent behavior).
- No destructive op runs before the review page; `wipe=false` aborts if the
  disk isn't in the expected state.

## Testing

- **Unit**: pure generators — make.conf, fstab, partition plan, stage3 URL
  resolution, config (de)serialization, wizard transitions.
- **Dry-run golden tests**: canned `lsblk`/`uname` inputs → assert emitted
  `Cmd` sequence matches fixtures.
- **QEMU harness** (`scripts/qemu-test.sh`): boots the real
  `install-amd64-minimal.iso`, drops the static binary in via a virtio
  drive/9p, runs `--config test.conf` over serial, asserts the guest boots
  to a login prompt. The same script scales to arm64 (qemu-system-aarch64 +
  UEFI firmware) and riscv64 later.
- CI matrix (later): {openrc,systemd} × {ext4,xfs,btrfs} × {grub,systemd-boot}
  × {amd64,arm64,riscv64}.

## Repo layout

```
build.zig, build.zig.zon        # zig 0.16.x pinned
src/engine/                     # zig library: steps, runner, wizard, model
src/tui/                        # zig, libvaxis/vxfw
src/main.zig                    # cli: tui|headless|--config|--dry-run
gui/                            # rust crate, libcosmic; spawns headless engine
presets/gentoo.toml             # the built-in stock preset
scripts/qemu-test.sh
docs/                           # DESIGN.md, protocol.md, presets.md
```

Toolchain: zig 0.16.x (libvaxis baseline), rust stable (iced/libcosmic).
GUI is a separate build artifact; the TUI/engine binary stays dependency-free.

## Milestones

- **M1** — engine: config model, runner, partition/mount/stage3/chroot,
  portage gen; `--dry-run` end-to-end. Unit + golden tests.
- **M2** — TUI wizard over the shared state machine; happy path
  (UEFI/GPT, openrc|systemd, ext4/xfs, dist-bin kernel, grub|systemd-boot).
- **M3** — QEMU green: real install boots on amd64 for the happy path.
- **M4** — libcosmic GUI shell on the headless protocol.
- **M5** — option matrix: LUKS, LVM, btrfs subvols, nomultilib, manual
  kernel, custom partitions; musl + llvm + hardened(-selinux) stage3
  paths; BIOS/CSM boot path; arm64 + riscv64 bring-up.
- **M6** — secure boot signing flow (sbctl path first), dual-boot
  alongside-mode + menu merge, runit/s6/dinit init-backend exploration.
- **M7** — distro preset layer hardening (branding, extra steps,
  post-install hooks), docs, 1.0.

## Open questions

1. License — defaulting to **GPL-3.0-or-later** (installer convention, e.g.
   Calamares; Slint not in play anymore so no constraint). Confirm or pick
   MIT/Apache-2.0.
2. Binary naming: `gentoo-installer` (cli+tui+headless) and
   `gentoo-installer-gui`? 
3. Bootloader default on UEFI: `systemd-boot` (lighter, fits the efficiency
   ethos) vs `grub` (most familiar)? Proposal: `auto` resolves boot mode
   first — BIOS ⇒ always grub; UEFI ⇒ systemd-boot on systemd variants,
   grub on openrc. VALIDATE hard-rejects systemd-boot/efistub/uki on BIOS.
4. Do we ship a `.zigmod`/`zig` version manager pin or rely on distro zig?
5. First distro preset beyond stock gentoo — defer until M6, but the schema
   should be drafted against a real wish-list (your wayland WM + tools).
