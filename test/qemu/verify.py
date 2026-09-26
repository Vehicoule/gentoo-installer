#!/usr/bin/env python3
"""Phase B: add serial console to limine.conf (if needed) via live ISO,
then boot the installed qcow2 under OVMF alone and expect a login prompt."""
import os, subprocess, sys, pexpect

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "phase-b.log")
ISO = os.path.join(HERE, "install-amd64-minimal.iso")

def iso_label():
    return subprocess.check_output(
        ["blkid", "-o", "value", "-s", "LABEL", ISO]).decode().strip()

def live_extra_args():
    return [
        "-kernel", os.path.join(HERE, "boot/vmlinuz-live"),
        "-initrd", os.path.join(HERE, "boot/initrd-live"),
        "-append", "console=ttyS0,115200 root=live:CDLABEL=%s rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot dokeymap" % iso_label(),
        "-cdrom", ISO,
    ]

QEMU_BASE = [
    "qemu-system-x86_64",
    "-machine", "q35,accel=kvm",
    "-cpu", "host", "-smp", "4", "-m", "8192",
    "-bios", "/usr/share/OVMF/OVMF_CODE.fd",
    "-drive", "file=%s,if=virtio,format=qcow2" % os.path.join(HERE, "target.qcow2"),
    "-nic", "user,model=virtio-net-pci",
    "-nographic", "-no-reboot",
]

def main():
    log = open(LOG, "wb")
    # --- part 1: live ISO, patch limine.conf for serial console ---
    c = pexpect.spawn(QEMU_BASE[0], QEMU_BASE[1:] + live_extra_args(),
                      timeout=180, logfile=log, encoding=None)
    c.expect(b"livecd.*# ", timeout=180)
    def sh(cmd, pat=b"livecd.*# ", timeout=60):
        c.sendline(cmd.encode()); c.expect(pat, timeout=timeout)
    sh("mount /dev/vda1 /mnt && cat /mnt/limine.conf")
    # ensure serial console on the installed kernel cmdline
    sh("grep -q 'ttyS0' /mnt/limine.conf || sed -i '/^.*cmdline:/ s|: *|: console=ttyS0,115200 |' /mnt/limine.conf; grep cmdline /mnt/limine.conf")
    sh("ls -la /mnt; ls -la /mnt/EFI/BOOT")
    sh("umount /mnt")
    c.sendline(b"poweroff")
    c.expect(pexpect.EOF, timeout=120)
    print("== limine.conf patched; booting installed disk")
    c.close()

    # --- part 2: boot the installed disk alone ---
    c = pexpect.spawn(QEMU_BASE[0], QEMU_BASE[1:], timeout=240, logfile=log, encoding=None)
    # limine menu → kernel → init → login prompt on serial
    c.expect(b"login:", timeout=240)
    print("== LOGIN PROMPT REACHED — M3 install is bootable")
    c.sendline(b"gentoo")
    c.expect(b"[Pp]assword", timeout=20)
    c.sendline(b"TestUser#2026")
    c.expect(r"gentoo.*[$#]|~".encode(), timeout=20)
    print("== LOGIN WORKS")
    c.sendline(b"uname -a; cat /etc/os-release | head -2; id; echo V-MARK-$?")
    c.expect(b"V-MARK-0", timeout=20)
    c.sendline(b"su - root -c 'echo SU-OK; poweroff'")
    c.expect(b"[Pp]assword", timeout=20)
    c.sendline(b"TestRoot#2026")
    c.expect(b"SU-OK", timeout=20)
    c.expect(pexpect.EOF, timeout=60)
    print("== PHASE B PASS")
    log.close()

if __name__ == "__main__":
    try:
        main()
    except pexpect.ExceptionPexpect as e:
        print("!! phase-B exception:", e)
        sys.exit(1)
