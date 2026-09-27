# QEMU install test harness

Drives a real headless install end-to-end — the M3 acceptance test.

## Prereqs (host)

- `qemu-system-x86_64` with KVM (`/dev/kvm`), OVMF (`/usr/share/OVMF/OVMF_CODE.fd`), `qemu-img`
- `pexpect` (`pip install pexpect` or `python3-pexpect`) and `blkid` (util-linux — derives the ISO volume label)
- A Gentoo minimal ISO at `test/qemu/install-amd64-minimal.iso` plus its extracted
  kernel/initrd at `test/qemu/boot/vmlinuz-live` and `test/qemu/boot/initrd-live`
  (extract: `isoinfo -i iso -x /boot/gentoo` etc., or mount + copy)
- `python3 -m http.server 8000` running in a dir serving the freshly built
  `zig-out/bin/gentoo-installer` as `gentoo-installer` and the ops file as
  `ops.jsonl` (QEMU user-net exposes it to the guest as `http://10.0.2.2:8000`)

## Ops file

`ops.jsonl` (next to this script): detect → set disk/users → validate →
install(confirm) → quit. Adjust disk (`/dev/vda`), credentials, and fields to
the scenario under test.

## Run

```sh
qemu-img create -f qcow2 target.qcow2 24G
python3 test/qemu/install.py   # phase A: live ISO + headless install (~15 min)
python3 test/qemu/verify.py    # phase B: boot disk, expect login, log in
```

## Variant scenarios (M5)

`scenario.py` runs the same two-phase drive for non-default configs:

```sh
python3 test/qemu/scenario.py luks   # UEFI + disk.luks — phase B types the passphrase at the initramfs prompt
python3 test/qemu/scenario.py bios   # SeaBIOS boot — exercises the BIOS layout + `limine bios-install`
```

Each takes `ops-<scenario>.jsonl` next to this script and logs to
`<scenario>-a.log` / `<scenario>-b.log`. `bios` drops OVMF so SeaBIOS is
the firmware on both phases.

Pexpect note: never expect a bare marker the typed command also contains
(`echo GOT` echoes `GOT` into the stream and matches early). Emit
`echo MARK-$?` and expect `MARK-0` instead.

Phase A fails loud with guest-side forensics (findmnt, /boot+ESP listing,
installer stderr tail) if the install errors mid-run. Phase B is green when
the serial console shows `gentoo login:` and the configured user can log in
and `su - root`.

Serial-only (`-nographic`) can't show limine's menu — for bootloader UI
debugging swap to `-display gtk -serial file:serial.log`.
