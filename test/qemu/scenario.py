#!/usr/bin/env python3
"""M5 scenario harness — drive variant installs end-to-end under QEMU.

Usage: scenario.py <luks|bios|musl|dinit|runit> [phase-a|phase-b]   (default: both phases)

  luks — UEFI install with disk.luks=true; phase B expects the dracut
         passphrase prompt on serial, enters it, reaches login.
  bios — SeaBIOS install (no OVMF); exercises the BIOS partition layout
         and `limine bios-install`; phase B boots the disk via SeaBIOS.
  musl — UEFI install on stage3-musl-hardened-openrc; verifies the
         alternate-libc variant path end to end (musl world from
         source, openrc init).
  dinit — UEFI install with system.init=dinit; verifies the alt-init
         backend: gi-sysinit stage-1, dinit.d units + boot.d links,
         init=/sbin/dinit on the kernel cmdline.
"""
import os, secrets, shutil, subprocess, sys
import pexpect

HERE = os.path.dirname(os.path.abspath(__file__))
ISO = os.path.join(HERE, "install-amd64-minimal.iso")
OVMF = "/usr/share/OVMF/OVMF_CODE.fd"
OVMF_VARS = "/usr/share/OVMF/OVMF_VARS.fd"
WWW = os.environ.get("GI_WWW", os.path.expanduser("~/m3/www"))
# Credentials live only in the throwaway qcow2 — generated per run so
# the repo carries no reusable test passwords. GI_* env vars pin them
# when reproducing a specific failure.
LUKS_PASS = os.environ.get("GI_LUKS_PASS") or secrets.token_urlsafe(12)
USER = os.environ.get("GI_USER", "gentoo")
USER_PW = os.environ.get("GI_USER_PASS") or secrets.token_urlsafe(12)
ROOT_PW = os.environ.get("GI_ROOT_PASS") or secrets.token_urlsafe(12)

def iso_label():
    return subprocess.check_output(
        ["blkid", "-o", "value", "-s", "LABEL", ISO]).decode().strip()

def qemu(scn, disk):
    if scn == "bios":
        fw = []
    else:
        # Split pflash so efibootmgr NVRAM writes persist across the
        # phase-A→B reboot — bare `-bios OVMF_CODE.fd` silently discards
        # them and efistub/refind installs then boot straight to the
        # UEFI shell.
        vars_fd = "%s/%s-vars.fd" % (HERE, scn)
        if not os.path.exists(vars_fd):
            shutil.copyfile(OVMF_VARS, vars_fd)
        fw = ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=%s" % OVMF,
              "-drive", "if=pflash,format=raw,unit=1,file=%s" % vars_fd]
    return (["qemu-system-x86_64",
             "-machine", "q35,accel=kvm", "-cpu", "host",
             "-smp", "4", "-m", "12288"] + fw +
            ["-drive", "file=%s,if=virtio,format=qcow2" % disk,
             "-nic", "user,model=virtio-net-pci",
             "-nographic", "-no-reboot"])

def live_args():
    return ["-kernel", os.path.join(HERE, "boot/vmlinuz-live"),
            "-initrd", os.path.join(HERE, "boot/initrd-live"),
            "-append", "console=ttyS0,115200 root=live:CDLABEL=%s rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot dokeymap" % iso_label(),
            "-cdrom", ISO]

def sh(c, cmd, pat=rb"livecd.*# ", timeout=120):
    c.sendline(cmd.encode())
    c.expect(pat, timeout=timeout)

# Marker sentinel: the terminal echoes the typed command, so a literal
# marker matches `&& echo ZZ-GOT` before output arrives. Including $? in
# the echo sidesteps it — the echoed line reads `ZZ-GOT-$?` while the
# real output prints `ZZ-GOT-0` (and a nonzero exit prints its code).
DONE = rb"ZZ-GOT-0"

def phase_a(scn, disk):
    # Substitute the credential placeholders and publish the resolved
    # ops to the dir the guest curls from — the committed file never
    # holds a real password.
    ops_txt = open(os.path.join(HERE, "ops-%s.jsonl" % scn)).read()
    for k, v in {"@USER@": USER, "@USER_PASS@": USER_PW,
                 "@ROOT_PASS@": ROOT_PW, "@LUKS_PASS@": LUKS_PASS}.items():
        ops_txt = ops_txt.replace(k, v)
    with open(os.path.join(WWW, "ops-%s.jsonl" % scn), "w") as f:
        f.write(ops_txt)
    log = open(os.path.join(HERE, "%s-a.log" % scn), "wb")
    c = pexpect.spawn(qemu(scn, disk)[0], qemu(scn, disk)[1:] + live_args(),
                      timeout=240, logfile=log, encoding=None)
    c.expect(b"livecd.*# ", timeout=180)
    print("== live shell")
    sh(c, "dhcpcd")
    sh(c, "curl -sf http://10.0.2.2:8000/gentoo-installer -o /tmp/gi && chmod +x /tmp/gi && echo ZZ-GOT-$?", pat=DONE)
    sh(c, "curl -sf http://10.0.2.2:8000/ops-%s.jsonl -o /tmp/ops.jsonl && echo ZZ-GOT-$?" % scn, pat=DONE)
    sh(c, "wc -l /tmp/ops.jsonl", timeout=30)
    print("== running install")
    c.sendline(b"/tmp/gi headless < /tmp/ops.jsonl 2>/tmp/gi.err | tee /tmp/gi.out")
    i = c.expect([b'"ev":"done","req":\d+,"ok":true', b'"ev":"error"'], timeout=7200)
    if i == 1:
        print("== INSTALL FAILED — forensics")
        sh(c, "tail -40 /tmp/gi.err; echo ZZ-GOT-$?", pat=DONE, timeout=30)
        sh(c, "tail -25 /tmp/gi.out; echo ZZ-GOT-$?", pat=DONE, timeout=30)
        # journal records every cmd argv+status — the 'fail' line names
        # the culprit even when the command itself printed nothing.
        sh(c, "grep -n 'fail\\|\"firmware-kernel\"' /tmp/gentoo-installer.journal | tail -12; "
              "echo ZZ-GOT-$?", pat=DONE, timeout=30)
        c.sendline(b"poweroff"); c.expect(pexpect.EOF, timeout=120)
        sys.exit(2)
    print("== install OK")
    # serial console on the installed kernel cmdline — filesystems stay
    # mounted at /mnt/gentoo after the install, and limine.conf sits on
    # the ESP under UEFI, on /boot under BIOS.
    sh(c, "for f in /mnt/gentoo/efi/limine.conf /mnt/gentoo/boot/limine.conf; do "
          "[ -f \"$f\" ] || continue; grep -q ttyS0 \"$f\" || "
          "sed -i 's|^\\s*cmdline:|    cmdline: console=ttyS0,115200|' \"$f\"; done; "
          "grep -rn cmdline /mnt/gentoo/efi/limine.conf /mnt/gentoo/boot/limine.conf 2>/dev/null", timeout=60)
    # openrc stage3s ship the serial getty commented out — enable a
    # 115200 ttyS0 agetty so phase B sees a login prompt (harmless on
    # systemd, which has no inittab to match).
    sh(c, "[ -f /mnt/gentoo/etc/inittab ] && { "
          "sed -i 's|^#\\?s0:.*|s0:12345:respawn:/sbin/agetty -L 115200 ttyS0 linux|' /mnt/gentoo/etc/inittab; "
          "grep -q '^s0:' /mnt/gentoo/etc/inittab || "
          "echo 's0:12345:respawn:/sbin/agetty -L 115200 ttyS0 linux' >> /mnt/gentoo/etc/inittab; }; "
          # always OK — no inittab at all on alt-init/systemd installs
          "echo ZZ-GOT-0", pat=DONE, timeout=30)
    # dinit has no inittab — the installer generates tty1-4 only, so a
    # serial getty needs its own process unit linked into boot.d.
    sh(c, "[ -d /mnt/gentoo/etc/dinit.d ] && { "
          "printf 'type = process\\ncommand = /sbin/agetty -L 115200 ttyS0 linux\\nrestart = true\\ndepends-on = sysinit\\n' "
          "> /mnt/gentoo/etc/dinit.d/ttyS0 && "
          "ln -sf ../ttyS0 /mnt/gentoo/etc/dinit.d/boot.d/ttyS0; }; "
          "echo ZZ-GOT-0", pat=DONE, timeout=30)
    # runit likewise — a supervised agetty on ttyS0 under runsvdir.
    sh(c, "[ -d /mnt/gentoo/etc/sv ] && { "
          "mkdir -p /mnt/gentoo/etc/sv/agetty-ttyS0 && "
          "printf '#!/bin/sh\\nexec /sbin/agetty -L 115200 ttyS0 linux 2>&1\\n' "
          "> /mnt/gentoo/etc/sv/agetty-ttyS0/run && "
          "chmod 755 /mnt/gentoo/etc/sv/agetty-ttyS0/run && "
          "ln -sf /etc/sv/agetty-ttyS0 /mnt/gentoo/etc/runit/runsvdir/default/agetty-ttyS0; }; "
          "echo ZZ-GOT-0", pat=DONE, timeout=30)
    c.sendline(b"poweroff"); c.expect(pexpect.EOF, timeout=120)
    log.close()
    print("== phase A done")

def phase_b(scn, disk):
    log = open(os.path.join(HERE, "%s-b.log" % scn), "wb")
    c = pexpect.spawn(qemu(scn, disk)[0], qemu(scn, disk)[1:],
                      timeout=300, logfile=log, encoding=None)
    if scn == "luks":
        # dracut's early-boot unlock prompt on the serial console
        c.expect(b"(?i)(passphrase|password for)", timeout=240)
        print("== LUKS prompt seen; entering passphrase")
        c.sendline(LUKS_PASS.encode())
    c.expect(b"login:", timeout=300)
    print("== login prompt reached")
    c.sendline(USER.encode())
    c.expect(b"[Pp]assword", timeout=20)
    c.sendline(USER_PW.encode())
    c.expect(rb"[$#]", timeout=20)
    c.sendline(b"uname -a; id; echo V-MARK-$?")
    c.expect(b"V-MARK-0", timeout=20)
    # runit/dinit don't answer util-linux poweroff (no sysvinit compat
    # ioctl chain by default) — sysrq 'o' powers off regardless of PID1.
    c.sendline(b"su - root -c 'echo SU-OK; (poweroff 2>/dev/null || echo o > /proc/sysrq-trigger)'")
    c.expect(b"[Pp]assword", timeout=20)
    c.sendline(ROOT_PW.encode())
    c.expect(b"SU-OK", timeout=20)
    c.expect(pexpect.EOF, timeout=60)
    log.close()
    print("== PHASE B PASS — %s scenario verified" % scn)

if __name__ == "__main__":
    scn = sys.argv[1] if len(sys.argv) > 1 else "luks"
    which = sys.argv[2] if len(sys.argv) > 2 else "both"
    disk = os.path.join(HERE, "target-%s.qcow2" % scn)
    try:
        if which in ("both", "phase-a"):
            # fresh NVRAM alongside the fresh disk — a reused vars.fd
            # would carry the previous run's BootOrder/entries.
            vars_fd = "%s/%s-vars.fd" % (HERE, scn)
            if os.path.exists(vars_fd):
                os.remove(vars_fd)
            subprocess.run(["qemu-img", "create", "-f", "qcow2", disk, "24G"], check=True)
            phase_a(scn, disk)
        if which in ("both", "phase-b"):
            phase_b(scn, disk)
    except pexpect.ExceptionPexpect as e:
        print("!! harness exception:", e)
        sys.exit(1)
