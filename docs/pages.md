# Wizard pages — field-level spec (v1)

Pages are **data owned by the engine**: each page is a schema (fields,
defaults, validation rules, visibility conditions) served over the wizard
protocol. TUI and GUI render the same schema; neither frontend implements
validation itself.

Two flows, picked on P0:

- **Express** — opinionated defaults are pre-selected for every choice;
  the wizard only asks for the disk, confirmation, and credentials.
  Defaults: btrfs + zram, systemd, `hardened-selinux-systemd` stage3
  (glibc/gcc — one resolved stem; desktop-profile bits are applied
  post-stage3), dist-bin kernel, **limine** bootloader (uniform across
  BIOS/UEFI — one predictable path), NM, doas, minimal package set.
- **Advanced** — every field on every page is editable; fields marked
  `expert` below appear only here.

Field notation: `name: type = default` — `expert` fields appear only in
Advanced flow; `secret` fields are never echoed or persisted.

## P0 — Welcome / mode

Purpose: orient the user, verify the environment is installable, pick the
interaction mode.

| Field | Type | Default | Notes |
|---|---|---|---|
| locale | enum (preset list) | `en_US.UTF-8` | display language for the wizard itself |
| mode | enum `express\|advanced` | `express` | sets the flow: express skips all non-essential pages; advanced exposes every field |
| answer_file | path (optional) | — | loads a saved config and jumps to P7 Review |

Env card (read-only, from `detect`): arch, boot mode (UEFI/BIOS), RAM,
network status, live-media type (minimal ISO vs LiveGUI vs foreign live
env).

Edge cases: no network → warning banner + `net-setup`/nmtui handoff
button; non-Gentoo live env → info banner (supported path on arm64/riscv64);
RAM < 512 MB → warning (emerge will be painful).

## P1 — Disk

Purpose: choose target disk(s) and partition plan. The most consequential
page — everything downstream depends on it.

User-facing layout options are presented Calamares-style:
**Normal** (erase disk, everything below auto-defaulted), **Install
alongside Windows** (only shown when Windows/another OS is detected),
**Advanced** (full control).

| Field | Type | Default | Validation |
|---|---|---|---|
| device | enum (detected disks) | — | nonempty; excluded: the disk hosting the live env |
| scheme | enum `normal (efi-swap-root)\|bios-boot-swap-root\|alongside\|advanced (manual)` | `normal` (UEFI) | `bios-*` shown only when booted via BIOS; `alongside` shown only when an existing OS is detected and requires free space or shrinkable partition |
| wipe | bool | `true` | must be `false` when `scheme=alongside` (VALIDATE) |
| root_fs | enum `xfs\|ext4\|btrfs\|f2fs` (+expert `bcachefs`) | `btrfs` | modern default — CoW enables system snapshots/rollbacks (xfs/ext4/f2fs get kernel rollback only — surfaced here); bcachefs needs a recent kernel — expert flag |
| swap | enum `zram\|partition\|none` | `zram` | `partition` reveals swap_mib; zram default fits memory-efficiency ethos (no disk swap) |
| swap_mib | int | 4096 | only when `swap=partition` |
| esp_mib | int (expert) | 512 | ≥128; ≥512 recommended for UKI/systemd-boot |
| boot_part | bool (expert) | false | separate /boot partition (needed for advanced crypto layouts; ESP stays separate) |
| luks | bool | false | reveals passphrase + `cryptsetup` options (pbkdf argon2id) |
| luks_passphrase | secret | — | required iff `luks`; min length 8; confirm field; supplied to `cryptsetup luksFormat` via stdin (no argv/env leak) |
| lvm | bool | false | LVM2 vg on root part (or inside LUKS if set); with snapshots on, provisions a thin pool + thin root LV |
| home_part | bool (expert) | false | separate /home partition |
| btrfs_subvols | list (expert) | `@,@home,@snapshots` | only when `root_fs=btrfs` |
| space_src | enum `shrink\|free-space` | auto-detected | alongside only: `free-space` uses existing unallocated space — no partition is touched; `shrink` reveals the two fields below |
| shrink_part | enum (existing partitions) | — | shrink only; fs must be ntfs/ext4/btrfs (xfs/f2fs unshrinkable → need unallocated space) |
| shrink_mib | int | — | shrink only; ≥ min install size (8 GiB) and ≤ fs free space |
| manual_plan | partition table editor (expert) | — | free-form: part/fs/mount table; validated like any scheme |

Normal/alongside modes auto-default every field above — the user only
picks disk, fs, LUKS toggle. Live preview: engine emits the post-install
partition table (the same `Cmd` plan the pipeline will run); TUI renders
a table, GUI renders a disk-bar graphic.

Edge cases: zero eligible disks → hard error page; active swap/LVM/md on
target → refuse until deactivated; `alongside` reuses the existing ESP —
never reformats it.

## P2 — Variant

Purpose: the Gentoo-specific choice — init system, stage3 flavor, profile.

| Field | Type | Default | Validation |
|---|---|---|---|
| init | enum `openrc\|systemd\|runit\|s6\|dinit` | `systemd` | all first-class options (alt inits get an "early support" badge, not a gate) — see init-backend note in DESIGN.md |
| libc | enum `glibc\|musl` | `glibc` | `musl` disables systemd (needs glibc); runit/s6/dinit fine on musl |
| toolchain | enum `gcc\|llvm` | `gcc` | `llvm` ⇒ `llvm-*`/`musl-llvm-*` stage3 |
| hardening | enum `standard\|hardened\|hardened+selinux` | `hardened+selinux` | per user direction: hardening on by default; see caveat below |
| profile | enum/string (expert override) | derived | must exist in `eselect profile list` for the variant |
| binhost | bool | `true` | official binpkg host; signature-verified |

Variant selection is **axes-based** — libc × toolchain × hardening map to
a stage3 stem (e.g. glibc+llvm+hardened ⇒ `hardened-llvm-*`; musl+llvm ⇒
`musl-llvm-*`). Caveat the UI must convey: *hardening is baked into the
stage3's toolchain* (hardened gcc/clang defaults), so it can't be applied
on top of a standard stage3 — selecting it selects a different tarball.
SELinux policy, by contrast, is additive (sec-policy/*, refpolicy,
`security.selinux=true`).

Init constraints (encoded, surfaced as disabled options): `musl` ⇒
systemd unavailable; `*-systemd` stage3 flavors ⇒ `init=systemd`;
runit/s6/dinit on any libc (post-stage3 init swap for non-openrc).

Profile preview: show the fully resolved profile name (e.g.
`default/linux/amd64/23.0/desktop/systemd`) so users see exactly what
they're getting.

## P3 — Region & input

| Field | Type | Default |
|---|---|---|
| timezone | searchable enum (zoneinfo) | **autodetected** via geoip when net is up; user confirms/overrides; `UTC` fallback |
| locales | multi-select (locale.gen) | `en_US.UTF-8` |
| default_locale | enum (⊂ locales) | first selected |
| keymap | enum (console keymaps) | `us` — drives xkb_layout default |
| ntp | bool | `true` (chrony / systemd-timesyncd) |

## P4 — Accounts

| Field | Type | Default | Validation |
|---|---|---|---|
| root_mode | enum `password\|locked` | `password` | `locked` → `lock_root=true` |
| root_password | secret | — | required iff root_mode=password; min 8, confirm |
| users[] | list of records | `[larry]` | username regex, uid auto |
| user.name / .groups / .shell | str / list / enum | — / `wheel,audio,video` / `/bin/bash` | shell from /etc/shells of stage3 |
| user.password | secret | — | optional if ssh key present |
| user.ssh_authorized_keys | textarea | — | ssh pubkey syntax check |
| privilege | enum `doas\|sudo\|none` | `doas` | minimal-footprint default per distro ethos; `none` only if root unlocked |

VALIDATE (hard): after all options applied, ≥1 usable login path —
password on a surviving account, or `sshd=true` + authorized key.

## P5 — System

| Field | Type | Default | Validation |
|---|---|---|---|
| hostname | string | `gentoo` | RFC 1123 |
| kernel | enum with user-facing explanations: `dist-bin` = "prebuilt official kernel — fastest, recommended"; `dist` = "compiled from source with Gentoo defaults — tunable"; `manual` = "gentoo-sources, you configure it" (expert) | `dist-bin` | — |
| initramfs | enum `dracut\|ugrd\|none` | `dracut` | `none` unsafe with LUKS/LVM/separate-/usr — VALIDATE warns/blocks |
| uki | bool | false | implies dracut/ugrd + installkernel[uki] |
| bootloader | enum `auto\|grub\|systemd-boot\|efistub\|limine\|refind` | `auto` (resolves to **limine** on both BIOS and UEFI, both flows) | grub/systemd-boot/efistub/rEFInd are explicit Advanced picks. VALIDATE hard-rejects `systemd-boot`/`efistub`/`uki`/`refind` on BIOS (limine BIOS mode is supported) |
| secure_boot | enum `off\|sbctl\|shim` | `off` | UEFI-only — hidden and forced `off` on BIOS boots (VALIDATE rejects non-`off` there too); `sbctl` requires uki or signed bootloader; `shim` for grub only |
| snapshots | enum `auto\|off` | `auto` | system snapshots before world-update/kernel installs; needs btrfs root or `lvm=on`, else kernel rollback only |
| keep_kernels | int | 3 | kernel boot entries retained; 0 = never prune |
| net_manager | enum `networkmanager\|dhcpcd\|netifrc\|systemd-networkd` | `networkmanager` | `systemd-networkd` needs init=systemd |
| wifi_fw | bool | detected | `linux-firmware` + `sof-firmware` |
| microcode | bool | detected (vendor) | intel-microcode / amd via linux-firmware |
| services.sshd / .logger / .cron | bool | false/true/true | — |

Seamless kernel upgrades (hard requirement): dist kernels +
installkernel regenerate boot entries on every kernel emerge —
systemd-boot/grub via existing installkernel plugins; **limine** gets a
shipped kernel-install plugin writing `limine.conf` entries; **rEFInd**
auto-discovers kernels/UKIs on the ESP (no config regen needed).

**Rollback**, same for every bootloader: (a) kernel rollback — the last
`keep_kernels` (default 3) kernels+initramfs always keep live boot
entries; (b) system snapshots — a hook snapshots root before each
world-update/kernel install and registers a boot entry per snapshot
(btrfs `@snapshots` on the default layout, LVM-thin when `lvm=on`).
Entries are emitted per bootloader: limine/grub/systemd-boot via our
hooks, rEFInd via generated `refind.conf` `menuentry` stanzas whose
`options "…"` line adds `rootflags=subvol=@snapshots/<n>` to the normal
kernel args; efistub has no menu — snapshots there recover via the same
`rootflags` override or live media. Shown as a
`snapshots` toggle; on CoW-less roots it degrades to kernel rollback
only, with a note.

Dual-boot menus: every detected OS gets an entry — grub merges
os-prober output, systemd-boot/rEFInd auto-discover ESP loaders, and
the limine plugin emits `efi_chainload` entries (e.g. Windows Boot
Manager at `EFI/Microsoft/Boot/bootmgfw.efi`); efistub relies on the
firmware menu, which already lists them.

## P6 — Packages & USE (the Gentoo page)

| Field | Type | Default |
|---|---|---|
| package_sets | multi-select from preset — stock preset ships `minimal` only; downstream distros define their own sets | `minimal` |
| extra_atoms | list editor | `[]` |
| use_global | searchable flag editor (tri-state: on/off/unset) with `use.desc` descriptions | profile defaults |
| use_pkg | per-package `package.use` records (v2; v1 edits a raw table) | `[]` |
| accept_license | enum + free text | `@FREE` (common toggles: `@BINARY-REDISTRIBUTABLE`, `linux-fw-redistributable`) |
| cflags | enum `safe\|native\|custom` + text | `native` |
| jobs / mem_cap | int | auto (nproc, ~2 GiB/job) |
| video_cards | string | autodetected |
| cpu_flags | string | autodetected (cpuid2cpuflags equiv.) |

Engine compiles this into `make.conf` + `package.use/*` at the
`portage-config` step; preview shows the generated make.conf diff.

## P7 — Review

Read-only grouped summary of the whole config (jump-back links per
section), **print plan** (the exact `Cmd` list — same output as
`--dry-run`), **export answer file** (writes the `--config` TOML — the
mass-install artifact), and the safety gate:

Answer-file export and secrets: in-memory passwords are converted to
crypt `password_hash` values at export, so the file is fully reusable
for unattended installs **without plaintext** — and because it then
contains hashes, it is written mode `0600` with a "keep this file
private" notice. SSH authorized keys are copied verbatim.

| Field | Type | Notes |
|---|---|---|
| confirm_wipe | type-the-device-name | required when `wipe=true` |
| confirm_text | acknowledge checkbox | alongside mode: "existing OS will be modified/shrunk" |

## P8 — Progress

Renders the pipeline's event stream: 16-step checklist with per-step
status + elapsed, live log tail, journal state line ("resumable through
step N").

Failure handling: `step_failed` → dialog with `{code, message, hint}` +
`retry` / `skip` (where safe) / `abort`. `cancel` finishes the current
step then halts, leaving the journal resumable.

## P9 — Finish

Success: summary card (hostname, users, boot entries), **save answer
file** (again — last chance), **"enter target chroot"** button (drops a
shell into the installed system — archinstall-style escape hatch),
unmount + reboot, install-media removal note.

Failure/abort path: resume instructions (`gentoo-installer --resume`
same-boot; `detect --repair` after reboot) + copyable log bundle for a
bug report.
