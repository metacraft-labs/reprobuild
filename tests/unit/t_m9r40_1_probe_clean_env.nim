## M9.R.40.1 — pin the hardware-probe child-env hygiene helpers.
##
## The M9.R.39.6 launcher set ``LD_LIBRARY_PATH=<nix-glibc>`` on the
## installer's env so the installer's PT_INTERP nix glibc resolved
## ALL of its glibc subsystems against the SAME nix instance.  The
## /bin/sh process spawned via ``execCmdEx`` inherited
## ``LD_LIBRARY_PATH`` and the glibc-2.40-66 libc.so.6 lacked the
## ``__nptl_change_stack_perm`` GLIBC_PRIVATE symbol Debian's dash
## was linked against -> RC=127 before ``lsblk`` ever ran.  The
## captured "lsblk output" was actually ``/bin/sh: symbol lookup
## error: ...`` -> ``parseJson`` choked on the first character with
## ``input(1, 1) Error: { expected``.
##
## M9.R.40.1 (this commit) closes the issue at TWO layers:
##   1. Launcher (DIAG mode): use ``ld.so --library-path`` AS the
##      strace child so LD_LIBRARY_PATH never enters the installer's
##      env (mirrors the non-DIAG branch's existing shape).
##   2. Probe (this test gates): ``execShellCmdCleanEnv`` strips
##      ``LD_LIBRARY_PATH`` / ``LD_DEBUG`` / ``LD_DEBUG_OUTPUT`` /
##      ``LD_PRELOAD`` / ``LD_AUDIT`` from the child env so the
##      hardware-probe shells stay clean even if a future launcher
##      change reintroduces propagation.

import std/[os, strtabs, strutils, unittest]
import repro_profile/hardware_probe

suite "M9.R.40.1: hardware probe child env hygiene":

  test "childEnvWithoutLdLibPath drops every LD_* loader var":
    putEnv("LD_LIBRARY_PATH", "/should/not/propagate")
    putEnv("LD_DEBUG", "libs")
    putEnv("LD_DEBUG_OUTPUT", "/tmp/foo")
    putEnv("LD_PRELOAD", "/some/lib")
    putEnv("LD_AUDIT", "/some/audit")
    putEnv("PATH_KEEP_ME", "1")
    let t = childEnvWithoutLdLibPath()
    check not t.hasKey("LD_LIBRARY_PATH")
    check not t.hasKey("LD_DEBUG")
    check not t.hasKey("LD_DEBUG_OUTPUT")
    check not t.hasKey("LD_PRELOAD")
    check not t.hasKey("LD_AUDIT")
    check t.hasKey("PATH_KEEP_ME")
    check t["PATH_KEEP_ME"] == "1"
    delEnv("LD_LIBRARY_PATH")
    delEnv("LD_DEBUG")
    delEnv("LD_DEBUG_OUTPUT")
    delEnv("LD_PRELOAD")
    delEnv("LD_AUDIT")
    delEnv("PATH_KEEP_ME")

  test "execShellCmdCleanEnv child sees no LD_LIBRARY_PATH":
    putEnv("LD_LIBRARY_PATH", "/foo")
    let r = execShellCmdCleanEnv(
      "echo \"x=${LD_LIBRARY_PATH:-unset}\"")
    delEnv("LD_LIBRARY_PATH")
    check r.exitCode == 0
    check r.output.strip() == "x=unset"

  test "execShellCmdCleanEnv merges stderr and reports exit code":
    let r = execShellCmdCleanEnv(
      "echo to-stdout && echo to-stderr 1>&2 && exit 7")
    check r.exitCode == 7
    # Order of stdout vs stderr in the merged stream may interleave,
    # but both must be present.
    check "to-stdout" in r.output
    check "to-stderr" in r.output
