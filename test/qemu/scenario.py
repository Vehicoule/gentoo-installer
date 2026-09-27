#!/usr/bin/env python3
"""M5 scenario harness — drive variant installs end-to-end under QEMU.

Usage: scenario.py <luks|bios> [phase-a|phase-b]   (default: both phases)

  luks — UEFI install with disk.luks=true; phase B expects the dracut
         passphrase prompt on serial, enters it, reaches login.
  bios — SeaBIOS install (no OVMF); exercises the BIOS partition layout
         and `limine bios-install`; phase B boots the disk via SeaBIOS.
"""
import os, subprocess, sys
import pexpect

HERE = os.path.dirname(os.path.abspath(__file__))
ISO = os.path.join(HERE, "install-amd64-minimal.iso")
OVMF = "/usr/share/OVMF/OVMF_CODE.fd"
LUKS_PASS = "TestLuks#2026"
USER, USER_PW, ROOT_PW = "gentoo", "TestUser#2026", "TestRoot#2026"

def iso_label():
    return subprocess.check_output(
        ["blkid", "-o", "value", "-s", "LABEL", ISO]).decode().strip()

def qemu(scn, disk):
    fw = [] if scn == "bios" else ["-bios", OVMF]
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
    ops = os.path.join(HERE, "ops-%s.jsonl" % scn)
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
    c.sendline(b"su - root -c 'echo SU-OK; poweroff'")
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
            subprocess.run(["qemu-img", "create", "-f", "qcow2", disk, "24G"], check=True)
            phase_a(scn, disk)
        if which in ("both", "phase-b"):
            phase_b(scn, disk)
    except pexpect.ExceptionPexpect as e:
        print("!! harness exception:", e)
        sys.exit(1)
