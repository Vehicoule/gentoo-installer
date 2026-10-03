# Vendored libvaxis

Source: https://github.com/rockorager/libvaxis @ `173a890d1394946b5d7623c66cd34bcd36d8eeb8`
(upstream HEAD at vendoring time — no upstream Zig 0.17 port exists yet).

Vendored because the installer pins a commit and needs 0.17 API fixes upstream
hasn't made; org has no fork rights, so the port lives here.

Local changes for Zig 0.17:

- `build.zig`:
  - `std.meta.fields(Example)` → `@typeInfo(Example).@"enum"` parallel
    `field_names`/`field_values` arrays (std.meta.fields removed).
  - dropped the removed `b.args` bench arg-forwarding.
- `build.zig.zon`:
  - `zigimg` → `11c3b9b56b452c86dc2dc06f48cfc18c8869804d` (master before the
    SGI test line that breaks 0.17's whitespace rule).
  - `uucode` → `ea62149739404a73c202b48a33bf6dd2af4bd9b0` (upstream `zig-0.17`
    branch).
  - `minimum_zig_version` → `0.17.0`.
- `examples/` and upstream test targets are not vendored (installer only uses
  the `vaxis` module).

Sync policy: bump by diffing upstream into this tree and re-applying the
changes above; update this file's pin.
