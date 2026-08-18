## M83 step 13 — disposable-WSL gate for the POSIX arm of `os.hostname`.
##
## The driver invokes `hostnamectl set-hostname <name>` on Linux. In
## WSL Ubuntu 22.04 without systemd-as-PID-1, `hostnamectl` cannot reach
## the bus at all.
##
## That environment fact is decided by a PRE-WORK probe
## (`hostnamectlLive`), which returns a skip reason the case reports as
## a genuine `skip()`. It used to be decided AFTER the fact instead, by
## matching the driver's exception text against a list of known-bad
## substrings ("Failed to connect to bus", "hostnamectl", "systemd",
## "D-Bus", "dbus", "Could not set property") and swallowing the
## exception when one matched. That is a mechanism for manufacturing
## green: any NEW failure whose message happened to contain the word
## "hostnamectl" — including a bug in `applyPosixOsHostname` itself,
## whose diagnostics name the tool — disappeared as a skip, and the case
## body then completed normally so `unittest` recorded a PASS. The probe
## answers the same question honestly and answers it before any work
## starts, so an exception from the lifecycle is now what it always was:
## a failure.
##
## Gated by `defined(linux)` AND `REPRO_M69_OS_HOSTNAME_VM=1`.

import std/[os, osproc, strutils]

import ct_test_unittest_parallel
when defined(posix):
  import std/posix

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "os.hostname (POSIX)"
const GateEnv = "REPRO_M69_OS_HOSTNAME_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_OS_HOSTNAME_VM not set."

proc writeLineSentinel(text: string) =
  let path = getEnv("REPRO_M69_VM_SENTINEL_FILE", SentinelDefault)
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var f: File
  if open(f, path, fmAppend):
    try:
      f.writeLine(text)
    finally:
      close(f)

proc hostnamectlLive(): bool =
  ## Pre-work probe: can `hostnamectl` reach a hostname bus at all?
  ##
  ## `hostnamectl status` is read-only and exits non-zero with
  ## "Failed to connect to bus" when there is no systemd-as-PID-1
  ## (bare WSL rootfs). Asking before the work replaces asking the
  ## failure afterwards what it was.
  let (_, code) = execCmdEx("hostnamectl status > /dev/null 2>&1")
  result = code == 0

proc main(): string =
  ## Returns "" when the scenario ran, or a skip reason when the
  ## in-VM prerequisite is missing.
  when defined(linux):
    # Two PRE-WORK environment facts, in order. Neither is a claim about
    # what a failure looked like; both are checkable before anything is
    # attempted, and the harness satisfies both (it runs as root inside a
    # systemd VM), so in the environment this gate exists for it always
    # goes on to do the work.
    if geteuid() != 0:
      writeLineSentinel("SKIP: " & GateName & " (not root)")
      return GateName &
        ": setting the system hostname requires root; the " &
        "disposable-VM harness runs as root"
    if not hostnamectlLive():
      writeLineSentinel("SKIP: " & GateName &
        " (hostnamectl cannot reach a bus)")
      # Returning the reason (rather than ``quit(0)``) keeps the case a
      # reported SKIP. A bare ``quit`` from inside a test body exits
      # before the protocol result document is written, so the runner
      # would have to fall back to the exit code and call it a PASS.
      return GateName &
        ": hostnamectl cannot reach a bus (no PID-1 systemd)"

    # A PID-scoped sentinel hostname so concurrent runs and the
    # original distro hostname don't collide. Must satisfy the RFC
    # 1123 constraint enforced by `isSafeHostname`.
    let newHost = "repro-m83-vm-" & $getCurrentProcessId()
    let op = PrivilegedOperation(kind: pokOsHostname,
      address: "hostname:" & newHost,
      hostnameName: newHost)

    try:
      discard applyPosixOsHostname(op)
      let post = observePosixOsHostname(op)
      doAssert post.present, "observePosixOsHostname reports absent"
      writeLineSentinel("OK: " & GateName)
      echo "  [OK] os.hostname (POSIX) lifecycle"
    except CatchableError as e:
      # Bus reachability is decided by `hostnamectlLive` ABOVE, before
      # any work starts. Anything raised from here down is an operational
      # failure of the apply/observe lifecycle itself, and it fails the
      # case — no message matching, no swallow.
      let head = e.msg.splitLines()[0]
      echo "  [FAIL] " & GateName & ": " & head
      writeLineSentinel("FAIL: " & GateName & " (" & head & ")")
      raise
  else:
    discard

suite "e2e_repro_infra_os_hostname_posix_vm":
  test "os.hostname (POSIX) disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      let secondaryGate = main()
      if secondaryGate.len > 0:
        skip(secondaryGate)
    else:
      skip(GateSkipReason)
