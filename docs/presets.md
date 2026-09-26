# Distro presets — schema

A preset is a directory of **data** (one `preset.toml` + assets +
scripts) that turns the generic Gentoo installer into your distro's
installer. Stock Gentoo is the built-in preset (`preset.id = "gentoo"`);
it must always work with no preset dir present.

Selection: `--preset <dir|id>`; embedded default otherwise. The chosen
preset id lands in the journal and the exported answer file, so a
`--config` replay reproduces the same distro.

## What a preset can and cannot do

| can | cannot |
|---|---|
| brand (name/logo/colors/strings) | add pipeline *code* — extra steps are declarative chroot scripts |
| overlay default `InstallConfig` values | weaken VALIDATE or safety gates |
| lock fields (distro-fixed choices) | change the protocol or page schema |
| define package sets + post-install hook | touch the live env / host — hooks run in the target chroot only |
| insert script steps at named anchors | run before `mount` (target doesn't exist) or after `finish` |

A preset is **trusted code**: its scripts run as root inside the target
chroot. Presets ship with the distro image or are passed explicitly —
the installer never fetches one from the network.

## `preset.toml`

```toml
[preset]
id          = "mydistro"        # lowercase, unique
name        = "MyDistro"
version     = "1.0.0"
engine_min  = "0.1.0"           # engine semver floor; refused below

[branding]
product_name = "MyDistro"       # replaces "Gentoo" in UI strings
logo         = "assets/logo.svg"
accent       = "#5294e2"
dark_default = true
support_url  = "https://mydistro.example/help"

[welcome]                        # P0 strings
tagline    = "A lean Gentoo-based desktop"
notice_url = "https://mydistro.example/relnotes"

[defaults]                       # partial InstallConfig overlay —
                                 # every key lives nested under it
[defaults.disk]
root_fs = "btrfs"
swap    = "zram"
[defaults.system]
init       = "dinit"
bootloader = "limine"
[defaults.stage3]
libc      = "glibc"              # required: the field is locked below
[defaults.security]
hardening = "hardened-selinux"
[defaults.packages]
sets = ["minimal"]               # authoritative pre-check list —
                                 # set.default only applies when unset

[locks]                          # fields the distro fixes — hidden in
fields = ["stage3.libc", "system.init"]   # the wizard, rejected if a
                                        # config file sets otherwise;
                                        # each must have a default above

[express]                        # opinionated-flow surface
enabled = true                   # a distro may ship Express-only
fields_shown = ["disk.device", "confirm"] # plus credentials, always

[[package_sets]]                 # multi-select on P6
id          = "minimal"
label       = "Minimal"
description = "bootable base: kernel, init, portage, network"
atoms       = ["app-admin/doas", "sys-apps/dinit", "net-misc/dhcpcd"]
default     = true               # pre-checked (when defaults.packages
                                 # .sets is absent)

[[package_sets]]
id          = "mydistro-desktop"
label       = "MyDistro Desktop"
description = "COSMIC session + audio + distro tools"
atoms       = ["cosmic-de/cosmic-meta", "media-libs/pipewire"]
use         = { "media-libs/pipewire" = "sound-server dbus" }
default     = false

[[extra_steps]]                  # journaled pipeline extensions
name        = "distro-tools"
after       = "system-config"    # anchor: a pipeline step name
script      = "scripts/distro-tools.sh"   # runs in target chroot
description = "Install distro tooling"
skippable   = true               # retry/skip allowed on failure

[hooks]
post_install = "scripts/post-install.sh"  # last thing inside chroot,
                                          # before unmount
```

## Semantics

- **Overlay merge**: preset `[defaults]` sit *under* user input — wizard
  pages pre-fill from them, `--config` keys override them. A field in
  `[locks]` is forced to the preset's value and hidden entirely.
- **Merged validation**: the engine validates `preset + config` as one
  InstallConfig — a preset can't ship an impossible default.
- **`extra_steps` run like built-ins**: journaled, emit `step`/`log`
  events, participate in resume (a failed script step resumes at that
  step), honor retry/skip/`skippable`. Sandboxing is the chroot; they
  see `/mnt/gentoo` as `/`.
- **package_sets** are the only way a preset shapes P6 — the stock
  preset ships `minimal` alone; COSMIC or any DE is a downstream set.
- **hooks.post_install** is where the distro's own magic lives (install
  the WM, write first-boot units, seed `/etc/mydistro`).
- **Assets** are relative to the preset dir; the GUI resolves `logo`
  etc. against it. Missing assets degrade to text-only branding.
- **Refusal cases**: unknown `after` anchor, `engine_min` unmet, locked
  field with no matching default, script not executable — the preset
  fails to load with a named error rather than half-applying.

## The stock preset

`presets/gentoo/` in-tree: `id="gentoo"`, zero locks, `minimal`
package set only, no extra steps, branding = Gentoo. It exists to keep
the generic installer fully functional and to serve as the reference
preset.
