# gentoo-installer

A guided installer for Gentoo Linux — one engine, two frontends:

- **TUI** (Zig + libvaxis) for the minimal ISO
- **GUI** (Rust + libcosmic) for the LiveGUI
- **headless/config mode** for automation (`--config`, `--dry-run`)

Multi-arch: amd64, arm64, riscv64. Designed to host distro presets, so a
Gentoo-based distribution can ship it with its own branding, defaults, and
extra steps.

Status: **1.0** — QEMU-verified installs on amd64 (UEFI + BIOS, LUKS,
LVM, btrfs, musl/hardened stage3s, runit/dinit/s6 inits, alongside
dual-boot, shim secure-boot chain). See
[docs/DESIGN.md](docs/DESIGN.md) for the architecture, config model,
headless protocol, and roadmap.

## Building

Engine + TUI (Zig 0.17.x):

```sh
zig build            # zig-out/bin/gentoo-installer  (tui | headless | run | plan | validate | detect)
zig build test
```

GUI (Rust + libcosmic, pins a libcosmic git rev in `crates/gui/Cargo.toml`):

```sh
cargo build -p gentoo-installer-gui   # binary: target/debug/gentoo-installer-gui
```

The GUI spawns `gentoo-installer headless` — set `GI_BIN=/path/to/binary` to
point it at a built engine, otherwise it looks for `zig-out/bin/gentoo-installer`
relative to the workspace.
