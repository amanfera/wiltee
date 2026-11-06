#!/usr/bin/env python3
"""Boots build/linux64-<profile>/Image under qemu-system-riscv64 (-M virt with OpenSBI,
2 harts (--smp), 256 MiB, virtio-blk + virtio-net over virtio-mmio) and drives the serial
console like a user: log in as root, then check uname, /proc/cpuinfo, nproc, the
virtio disk, DHCP + ping + TCP over virtio-net, floating point in awk, and power off.
It exits 0 only if every check passed.

Usage: tests/qemu64.py ima|imac|gc [-v] [--timeout SECONDS] [--smp N] [--cpu QEMU_CPU]
       [--no-mmu-check] [--no-tcp]
The full console transcript is saved to build/linux64-<profile>/qemu.log.

The default -cpu mirrors the profile and the wiltee machine (Sv39 only, no Sstc), so the
kernel takes the same paths: SBI timer, Sv39 fallback, no F/D or no C where the profile
says so. Needs build/disk64.img (made by scripts/mkdisk64.sh when missing)."""
import argparse
import hashlib
import os
import pty
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELLO = "hello from wiltee virtio-blk"
APPLETS = ("awk dd md5sum sha256sum seq sync df du nproc uptime date time head tail wc sort cut "
           "tr hexdump mknod mke2fs mkfs.ext2 ifconfig ip route udhcpc ping wget nc telnet arp "
           "taskset").split()
SCRATCH_SECTORS = 16384  # second, blank virtio disk (8 MiB) for the mke2fs check
# Common QEMU CPU tail: no H, SBI timer only, Sv39 only (what the wiltee machine implements).
COMMON = "h=false,sstc=false,sv39=on,sv48=off,sv57=off"
NOFP = "f=false,d=false,zfa=false,zfh=false,zfhmin=false"
PROFILES = {
    # name: (qemu -cpu, single-letter extensions the isa line must / must not have)
    "ima": (f"rv64,c=false,{NOFP},{COMMON}", "ima", "cfdv"),
    "imac": (f"rv64,{NOFP},{COMMON}", "imac", "fdv"),
    "gc": (f"rv64,{COMMON}", "imafdc", "v"),
}


class Fail(Exception):
    pass


class Console:
    """The guest's serial console, reached through QEMU's stdio on a pty."""

    def __init__(self, argv, deadline, verbose, logfile):
        self.deadline = deadline
        self.verbose = verbose
        self.log = open(logfile, "wb")
        self.buf = ""
        self.pos = 0
        self.eof = False
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execv(argv[0], argv)

    def _pump(self, timeout):
        r, _, _ = select.select([self.fd], [], [], max(0.0, timeout))
        if not r:
            return
        try:
            chunk = os.read(self.fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            self.eof = True
            return
        self.log.write(chunk)
        self.log.flush()
        text = chunk.decode("latin-1")
        if self.verbose:
            sys.stdout.write(text.replace("\r", ""))
            sys.stdout.flush()
        self.buf += text

    def expect(self, pattern, what, timeout):
        """Wait for a regex after the last match; returns (text before match, match)."""
        rx = re.compile(pattern)
        limit = min(time.time() + timeout, self.deadline)
        while True:
            m = rx.search(self.buf, self.pos)
            if m:
                before = self.buf[self.pos:m.start()]
                self.pos = m.end()
                return before, m
            if "Kernel panic - not syncing" in self.buf[self.pos:]:
                raise Fail(f"kernel panic while waiting for {what}")
            if self.eof:
                raise Fail(f"QEMU exited while waiting for {what}")
            if time.time() >= limit:
                raise Fail(f"timeout waiting for {what}")
            self._pump(min(1.0, limit - time.time()))

    def send(self, line):
        os.write(self.fd, (line + "\r").encode())

    def tail(self, n=40):
        return "\n".join(l.rstrip("\r") for l in self.buf.splitlines()[-n:])

    def wait_exit(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                self.pid = 0
                return os.waitstatus_to_exitcode(status)
            try:
                self._pump(0.2)
            except Exception:
                pass
        return None

    def kill(self):
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
            except OSError:
                pass
            self.pid = 0


class TcpHello(threading.Thread):
    """Host side of the TCP check: the guest reaches it as 10.0.2.2 (QEMU user networking)."""

    def __init__(self):
        super().__init__(daemon=True)
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.sock.settimeout(300)
        self.port = self.sock.getsockname()[1]
        self.received = b""

    def run(self):
        try:
            conn, _ = self.sock.accept()
            self.received = conn.recv(100)
            conn.sendall(b"wiltee-tcp-ok:" + self.received)
            conn.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("profile", choices=sorted(PROFILES))
    ap.add_argument("-v", "--verbose", action="store_true", help="echo the console while running")
    ap.add_argument("--timeout", type=float, default=900, help="overall limit in seconds")
    ap.add_argument("--smp", type=int, default=2, help="number of harts (default 2, kernel supports 8)")
    ap.add_argument("--cpu", help="override the QEMU -cpu string")
    ap.add_argument("--no-mmu-check", action="store_true", help="do not require 'mmu : sv39'")
    ap.add_argument("--no-tcp", action="store_true", help="skip the TCP check (needs QEMU user networking to reach the host's loopback)")
    args = ap.parse_args()

    profile = args.profile
    cpu, want_isa, deny_isa = PROFILES[profile]
    if args.cpu:
        cpu = args.cpu
    outdir = os.path.join(ROOT, f"build/linux64-{profile}")
    image = os.path.join(outdir, "Image")
    disk = os.path.join(ROOT, "build/disk64.img")
    qemu = os.environ.get("QEMU") or shutil.which("qemu-system-riscv64")
    if not qemu:
        sys.exit("qemu-system-riscv64 not found")
    if not os.path.isfile(image):
        sys.exit(f"missing {image} (run: PROFILE={profile} scripts/build-linux64.sh)")
    if not os.path.isfile(disk):
        subprocess.run([os.path.join(ROOT, "scripts/mkdisk64.sh")], check=True)

    # QEMU's own firmware is built with C and F/D; build-linux64.sh builds one for the profile
    bios = os.path.join(outdir, "opensbi.bin")
    if profile == "ima" and not os.path.isfile(bios):
        sys.exit(f"missing {bios}: QEMU's bundled OpenSBI uses compressed instructions and cannot "
                 "run on a CPU without C; scripts/build-linux64.sh builds one for rv64ima")
    scratch = tempfile.NamedTemporaryFile(prefix="wiltee-scratch-", suffix=".img")
    scratch.truncate(SCRATCH_SECTORS * 512)
    argv = [qemu, "-M", "virt", "-cpu", cpu, "-smp", str(args.smp), "-m", "256M",
            "-nographic", "-no-reboot", "-bios", bios if os.path.isfile(bios) else "default",
            "-kernel", image,
            "-drive", f"file={disk},format=raw,if=none,id=hd0,snapshot=on",
            "-device", "virtio-blk-device,drive=hd0",
            "-drive", f"file={scratch.name},format=raw,if=none,id=hd1",
            "-device", "virtio-blk-device,drive=hd1",
            "-netdev", "user,id=n0", "-device", "virtio-net-device,netdev=n0"]
    print(f"qemu64 [{profile}]: {' '.join(argv)}", flush=True)

    start = time.time()
    con = Console(argv, start + args.timeout, args.verbose, os.path.join(outdir, "qemu.log"))
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print(f"[{'PASS' if ok else 'FAIL'}] {time.time() - start:6.1f}s {name}"
              f"{': ' + detail if detail else ''}", flush=True)
        return ok

    tag = [0]

    def run(cmd, timeout=60):
        """Run a shell command; returns (exit status, its output)."""
        tag[0] += 1
        t = f"@@{tag[0]}"
        # The typed (echoed) markers are split by "" or end in '$?', so only real output
        # matches; long lines may be re-wrapped by the line editor, which then cannot matter.
        con.send(f'echo "{t}"":b"; {cmd}; echo "{t}"":e$?"')
        con.expect(re.escape(t) + r":b\r*\n", f"start of '{cmd}'", timeout)
        out, m = con.expect(re.escape(t) + r":e(\d+)\r*\n", f"end of '{cmd}'", timeout)
        con.expect(r"# ", "shell prompt", 10)
        return int(m.group(1)), out.replace("\r", "").strip()

    tcp = TcpHello()
    tcp.start()
    try:
        con.expect(r"login: ", "login prompt", 600)
        check("boot", True, "login prompt reached")
        con.send("root")
        con.expect(r"# ", "shell prompt after login", 60)
        check("login", True, "root, no password")

        rc, out = run("uname -a")
        check("uname", rc == 0 and re.search(r"Linux \S+ 6\.12\.115 .*riscv64", out) is not None, out)

        rc, out = run("cat /proc/cpuinfo")
        isas = re.findall(r"^isa\s*:\s*(\S+)", out, re.M)
        mmus = re.findall(r"^mmu\s*:\s*(\S+)", out, re.M)
        letters = [set(i.split("_")[0][4:]) for i in isas]  # after "rv64"
        ok = (rc == 0 and len(isas) == args.smp and all(
            set(want_isa) <= l and not (set(deny_isa) & l) for l in letters))
        check("cpuinfo isa", ok, f"{isas[0] if isas else 'no isa line'} "
              f"(need {want_isa}, forbid {deny_isa}, {len(isas)} harts)")
        if not args.no_mmu_check and not args.cpu:
            check("cpuinfo mmu", mmus == ["sv39"] * args.smp, ",".join(mmus))

        rc, out = run("nproc")
        check("nproc", rc == 0 and out == str(args.smp), out)

        rc, out = run("dmesg | grep -ciE 'oops|BUG:|call trace|kernel panic|unable to handle'")
        check("dmesg has no oops/BUG", out == "0", f"{out} matching lines")

        # virtio-mmio probe order decides which of vda/vdb is which, so tell them apart by size
        rc, out = run("for d in /sys/block/vd*; do echo ${d##*/} $(cat $d/size); done")
        sizes = dict(l.split() for l in out.splitlines() if len(l.split()) == 2)
        main_disk = next((d for d, n in sizes.items() if n != str(SCRATCH_SECTORS)), "vda")
        scratch_disk = next((d for d, n in sizes.items() if n == str(SCRATCH_SECTORS)), "vdb")
        check("two virtio-blk disks", len(sizes) == 2 and main_disk != scratch_disk, out.replace("\n", ", "))
        rc, out = run(f"mount -t ext2 /dev/{main_disk} /mnt && cat /mnt/hello.txt")
        check("virtio-blk read", rc == 0 and out == HELLO, out)
        rc, out = run("sha256sum /mnt/data.bin | cut -d' ' -f1; cut -d' ' -f1 /mnt/data.sha256")
        sums = out.split()
        check("virtio-blk large read (sha256)", rc == 0 and len(sums) == 2 and sums[0] == sums[1], sums[0] if sums else out)
        rc, out = run("echo wiltee-write > /mnt/w.txt && sync && cat /mnt/w.txt && umount /mnt")
        check("virtio-blk write + umount", rc == 0 and out == "wiltee-write", out)
        rc, out = run(f"mke2fs -q /dev/{scratch_disk} && mount /dev/{scratch_disk} /mnt && "
                      "echo mkfs-ok > /mnt/f && sync && cat /mnt/f && umount /mnt", 120)
        check("mke2fs + mount scratch disk", rc == 0 and out.endswith("mkfs-ok"), out.splitlines()[-1] if out else "")

        rc, out = run("for a in " + " ".join(APPLETS) + "; do command -v $a >/dev/null || echo $a; done")
        check("busybox applets present", out == "", f"missing: {out}" if out else f"all {len(APPLETS)} found")
        rc, out = run("echo abc | md5sum; echo abc | sha256sum; seq 1 5 | sort -r | head -n 2 | tr '\\n' ' '; echo; "
                      "dd if=/dev/zero bs=4k count=3 2>/dev/null | wc -c")
        want = [hashlib.md5(b"abc\n").hexdigest() + "  -", hashlib.sha256(b"abc\n").hexdigest() + "  -",
                "5 4", "12288"]
        check("md5sum/sha256sum/seq/sort/dd", [l.strip() for l in out.splitlines()] == want, out.replace("\n", " | "))

        rc, out = run("udhcpc -i eth0 -n -q 2>&1 | tail -n 3", 90)
        rc2, addr = run("ip -4 addr show eth0")
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+/\d+)", addr)
        check("udhcpc eth0", m is not None, m.group(1) if m else addr + "\n" + out)
        rc, out = run("ifconfig eth0 | grep -c 10.0.2.15; route -n | grep -c 10.0.2.2")
        check("ifconfig/route show the lease", out.split() == ["1", "1"], out.replace("\n", " "))
        rc, out = run("ping -c 2 -W 5 10.0.2.2", 60)
        check("ping gateway", rc == 0 and re.search(r"[1-9]\d* packets received", out) is not None,
              out.splitlines()[-2] if out else "")
        rc, out = run("arp -n | grep -c 10.0.2.2")
        check("arp shows the gateway", out == "1", out)
        if not args.no_tcp:
            rc, out = run(f"echo ping | nc -w 10 10.0.2.2 {tcp.port}", 60)
            check("tcp to host (nc)", out.endswith("wiltee-tcp-ok:ping"), out)

        rc, out = run("awk 'BEGIN{printf \"%.6f\\n\", atan2(1,1)*4}'")
        check("awk pi", rc == 0 and out == "3.141593", out)
        rc, out = run("awk 'BEGIN{printf \"%.4f %.4f %.4f\\n\", sqrt(2), exp(1), sin(1)}'")
        check("awk sqrt/exp/sin", rc == 0 and out == "1.4142 2.7183 0.8415", out)

        con.send("poweroff -f")
        code = con.wait_exit(60)
        check("poweroff -f", code == 0, f"QEMU exit status {code}")
    except Fail as e:
        check("run", False, str(e))
        print("--- last console output ---\n" + con.tail(), flush=True)
    finally:
        con.kill()
        tcp.sock.close()

    ok = bool(results) and all(results)
    print(f"qemu64 [{profile}]: {'PASS' if ok else 'FAIL'} ({sum(results)}/{len(results)} checks, "
          f"{time.time() - start:.0f}s); transcript: build/linux64-{profile}/qemu.log", flush=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
