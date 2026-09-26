#!/usr/bin/env python3
"""M3 harness — drive a headless gentoo-installer run inside QEMU.

Phase A (this script): boot the Gentoo minimal ISO kernel+initrd under
OVMF with a serial console, pull the installer binary + ops over
hostfwd-friendly user-net http, run the install, power off.
"""
import os, sys, time
import pexpect

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "phase-a.log")

QEMU = [
    "qemu-system-x86_64",
    "-machine", "q35,accel=kvm",
    "-cpu", "host", "-smp", "4", "-m", "12288",
    "-bios", "/usr/share/OVMF/OVMF_CODE.fd",
    "-kernel", os.path.join(HERE, "boot/vmlinuz-live"),
    "-initrd", os.path.join(HERE, "boot/initrd-live"),
    "-append", "console=ttyS0,115200 root=live:CDLABEL=Gentoo-amd64-20260913 rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot dokeymap",
    "-cdrom", os.path.join(HERE, "install-amd64-minimal.iso"),
    "-drive", "file=%s,if=virtio,format=qcow2" % os.path.join(HERE, "target.qcow2"),
    "-nic", "user,model=virtio-net-pci",
    "-nographic", "-no-reboot",
]

def main():
    log = open(LOG, "wb")
    print("== spawning qemu; logging to", LOG)
    c = pexpect.spawn(QEMU[0], QEMU[1:], timeout=240, logfile=log, encoding=None)

    # live env → root shell
    c.expect(b"livecd.*# ", timeout=180)
    print("== live shell reached")

    def sh(cmd, pat=b"livecd.*# ", timeout=120):
        c.sendline(cmd.encode())
        c.expect(pat, timeout=timeout)

    sh("dhcpcd")
    sh("curl -sf http://10.0.2.2:8000/gentoo-installer -o /tmp/gi && chmod +x /tmp/gi && echo GOT-BIN", pat=b"GOT-BIN")
    print("== installer binary fetched")

    sh("curl -sf http://10.0.2.2:8000/ops.jsonl -o /tmp/ops.jsonl && echo GOT-OPS", pat=b"GOT-OPS")

    print("== running install (long)")
    c.sendline(b"/tmp/gi headless < /tmp/ops.jsonl 2>/tmp/gi.err | tee /tmp/gi.out")
    # wait for the install verdict — ok or error — then dump diagnostics
    i = c.expect([b'"ev":"done","req":7,"ok":true', b'"ev":"error","req":7'], timeout=7200)
    if i == 1:
        print("== install FAILED; forensics")
        # mount/FS state at failure time — bounded output only (a huge
        # backlog on the serial races the prompt and times out)
        sh("tail -40 /tmp/gi.err > /dev/console; echo ERR-END", pat=b"ERR-END", timeout=30)
        sh("findmnt /mnt/gentoo /mnt/gentoo/efi /mnt/gentoo/boot; echo MNT-END", pat=b"MNT-END", timeout=30)
        sh("ls -laR /mnt/gentoo/efi /mnt/gentoo/boot 2>&1 | head -40; echo LS-END", pat=b"LS-END", timeout=30)
        sh("tail -25 /tmp/gi.out; echo OUT-END", pat=b"OUT-END", timeout=30)
        c.sendline(b"poweroff")
        c.expect(pexpect.EOF, timeout=120)
        sys.exit(2)
    print("== install completed OK")

    sh("tail -20 /tmp/gi.err")
    # add serial console to installed kernel cmdline for phase-B verify
    sh("mount /dev/vda1 /mnt && sed -i 's|^    cmdline: |    cmdline: console=ttyS0,115200 |' /mnt/limine.conf /mnt/limine.conf.d/*.conf 2>/dev/null; grep -rn 'cmdline' /mnt/ | head; umount /mnt")
    c.sendline(b"poweroff")
    c.expect(pexpect.EOF, timeout=120)
    print("== guest powered off")
    log.close()

if __name__ == "__main__":
    try:
        main()
    except pexpect.ExceptionPexpect as e:
        print("!! harness exception:", e)
        sys.exit(1)
