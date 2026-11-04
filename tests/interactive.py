#!/usr/bin/env python3
"""Boots Linux under wiltee on a pseudo-terminal and drives the console the
way a user would: wait for the login prompt, log in, run commands in the
shell, power off. Proves the interactive path (raw stdin -> UART -> getty ->
/bin/sh) end to end. Usage: tests/interactive.py [timeout-seconds]"""
import os, pty, re, select, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARGS = [os.path.join(ROOT, "build/wiltee"), os.path.join(ROOT, "build/linux/Image"),
        os.path.join(ROOT, "platform/wiltee.dtb"), os.path.join(ROOT, "build/linux/rootfs.cpio")]
LIMIT = float(sys.argv[1]) if len(sys.argv) > 1 else 1800

pid, fd = pty.fork()
if pid == 0:
    os.execv(ARGS[0], ARGS)

seen = b""
start = time.time()

def expect(pattern, what):
    global seen
    rx = re.compile(pattern)
    while not (m := rx.search(seen)):
        if time.time() - start > LIMIT:
            sys.exit(f"timeout waiting for {what}; last output:\n{seen[-800:].decode(errors='replace')}")
        r, _, _ = select.select([fd], [], [], 1.0)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                sys.exit(f"emulator exited while waiting for {what}")
            sys.stdout.write(chunk.decode(errors="replace")); sys.stdout.flush()
            seen += chunk
    print(f"\n--- [{time.time() - start:6.1f}s] saw {what}", flush=True)
    seen = seen[m.end():]

def send(line):
    for ch in line + "\r":  # a terminal in raw mode sends CR for Enter
        os.write(fd, ch.encode()); time.sleep(0.02)

expect(rb"login: ", "login prompt")
send("root")
expect(rb"# ", "shell prompt")
send("uname -sm; echo shell-ok-$((6*7))")
expect(rb"shell-ok-42", "command output from the shell")
expect(rb"# ", "shell prompt again")
send("sleep 1; cat /proc/cpuinfo | grep -i isa")
expect(rb"rv32ima", "cpuinfo")
expect(rb"# ", "shell prompt again")
send("poweroff -f")
expect(rb"\[wiltee\] powered off", "power off")
os.waitpid(pid, 0)
print("interactive: PASS")
