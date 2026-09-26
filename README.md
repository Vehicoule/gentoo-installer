# gentoo-installer

A guided installer for Gentoo Linux — one engine, two frontends:

- **TUI** (Zig + libvaxis) for the minimal ISO
- **GUI** (Rust + libcosmic) for the LiveGUI
- **headless/config mode** for automation (`--config`, `--dry-run`)

Multi-arch: amd64, arm64, riscv64. Designed to host distro presets, so a
Gentoo-based distribution can ship it with its own branding, defaults, and
extra steps.

Early stage — see [docs/DESIGN.md](docs/DESIGN.md) for the architecture, config model,
headless protocol, and roadmap.

## Status

Nothing to install yet. Build instructions land with the first milestone.
