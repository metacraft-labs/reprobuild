#!/usr/bin/env python3
"""Run a command in a pseudo-terminal and answer sudo's password prompts.

The Omarchy update gate (milestone AR6) drives `omarchy update` as the
operator account would at a terminal: `omarchy update` asks for the sudo
password once (and again when the credential has expired), on the terminal
-- sudo reads it from /dev/tty, never from standard input, and discards
input typed ahead of its prompt. This driver plays the operator: it watches
the terminal's output and types the password after each `[sudo] password`
prompt. Everything the terminal printed is copied to DRIVE_LOG.

Environment: DRIVE_PASSWORD, DRIVE_LOG, DRIVE_TIMEOUT (seconds, default
3600). Prints `exit=<status> prompts=<n> seconds=<s>` and exits with the
command's status (124 when it had to be killed at the timeout).
"""
import os, pty, select, signal, sys, time

argv = sys.argv[1:]
password = os.environ.get("DRIVE_PASSWORD", "").encode()
log = open(os.environ.get("DRIVE_LOG", "/dev/null"), "wb")
timeout = int(os.environ.get("DRIVE_TIMEOUT", "3600"))
t0 = time.time()
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
tail = b""
prompts = 0
killed = False
while True:
    if time.time() - t0 > timeout:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
        killed = True
        break
    r, _, _ = select.select([fd], [], [], 1.0)
    if not r:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    log.write(data)
    log.flush()
    tail = (tail + data)[-512:]
    if b"[sudo] password for" in tail or b"Password:" in tail:
        time.sleep(0.3)
        os.write(fd, password + b"\n")
        prompts += 1
        tail = b""
_, status = os.waitpid(pid, 0)
code = 124 if killed else (os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
print("exit=%d prompts=%d seconds=%.1f" % (code, prompts, time.time() - t0))
sys.exit(code)
