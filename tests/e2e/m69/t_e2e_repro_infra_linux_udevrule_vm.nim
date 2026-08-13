## M83 step 13 — disposable-WSL gate for `linux.udevRule`.
##
## Writes a `/etc/udev/rules.d/` drop-in. The driver invokes
## `udevadm control --reload-rules`; if the udev daemon is not running
## (likely the case inside a bare WSL Ubuntu rootfs without
## systemd-as-PID-1) the reload cannot succeed.
##
## That environment fact is decided by a PRE-WORK probe (`udevdLive`,
## which is `udevadm control --ping`), and the case reports a genuine
## `skip()` carrying the reason. It used to be decided AFTER the fact
## instead: the apply was wrapped in a `try/except` that matched the
## exception text against "udevadm", "reload-rules" and "polling on
## epoll", and on a match set `skipped = true` — which then jumped over
## the ENTIRE remainder of the lifecycle (the on-disk content check, the
## observe/digest comparison, the destroy and its absence check) while
## the case still completed normally and `unittest` recorded a PASS.
## Every diagnostic `applyLinuxUdevRule` emits names `udevadm`, so any
## new bug in the driver matched that filter and vanished. The probe
## asks the same question honestly and asks it before any work starts.
##
## Gated by `defined(linux)` AND `REPRO_M69_UDEV_VM=1`.

import std/[os, osproc, strutils, unittest]
when defined(posix):
  import std/posix

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.udevRule"
const GateEnv = "REPRO_M69_UDEV_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_UDEV_VM not set."

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

proc udevdLive(): bool =
  ## Pre-work probe: is there a udev daemon to reload?
  ##
  ## `udevadm control --ping` is the daemon's own liveness check: it
  ## exits non-zero when nothing is listening on the control socket,
  ## which is the bare-WSL-rootfs case. Asking before the work replaces
  ## asking the failure afterwards what it was.
  let (_, code) = execCmdEx("udevadm control --ping > /dev/null 2>&1")
  result = code == 0

proc main(): string =
  ## Returns "" when the scenario ran, or a skip reason when the
  ## in-VM prerequisite is missing.
  when defined(linux):
    # Two PRE-WORK environment facts, in order. Neither is a claim about
    # what a failure looked like; both are checkable before anything is
    # attempted, and the harness satisfies both (it runs as root inside a
    # systemd VM), so in the environment this gate exists for it always
    # goes on to do the work. The root check comes FIRST because
    # `udevadm control --ping` needs root itself: without it a non-root
    # run would answer "no daemon" for the wrong reason.
    if geteuid() != 0:
      writeLineSentinel("SKIP: " & GateName & " (not root)")
      return GateName &
        ": writing /etc/udev/rules.d and pinging udevd requires root; " &
        "the disposable-VM harness runs as root"
    if not udevdLive():
      writeLineSentinel("SKIP: " & GateName & " (no udev daemon)")
      # Returning the reason (rather than ``quit(0)``) keeps the case a
      # reported SKIP. A bare ``quit`` from inside a test body exits
      # before the protocol result document is written, so the runner
      # would have to fall back to the exit code and call it a PASS.
      return GateName & ": udevadm control --ping found no udev daemon"

    let ruleName = "99-reprobuild-m83-vm-test-" &
      $getCurrentProcessId() & ".rules"
    # A no-op udev rule: a comment line. udev parses it and ignores.
    let ruleContent =
      "# Reprobuild M83 step 13 udev smoke rule. No-op.\n"

    let op = PrivilegedOperation(kind: pokLinuxUdevRule,
      address: "udevRule:" & ruleName,
      udevName: ruleName,
      udevContent: ruleContent,
      udevDestroy: false)
    let path = udevRulePath(ruleName)
    echo "  rule path: ", path

    # Daemon liveness is decided by `udevdLive` ABOVE, before any work
    # starts. Anything raised from here down is an operational failure of
    # the apply/observe/destroy lifecycle itself, and it fails the case.
    try:
      discard applyLinuxUdevRule(op)

      doAssert fileExists(path),
        "expected udev rule file " & path & " after apply"
      doAssert readFile(path) == ruleContent,
        "udev rule content mismatch on disk"

      let post = observeLinuxUdevRule(op)
      doAssert post.present
      doAssert post.digestHex == posixDigestHexOfText(ruleContent),
        "observe digest != desired digest"

      # The destroy must remove the file ON ITS OWN. This used to be
      # wrapped in a `try/except` that, on any driver failure, deleted the
      # file by hand and then asserted the file was gone — an assertion
      # the test had just satisfied itself, so a completely broken
      # `destroyLinuxUdevRule` still produced a green lifecycle.
      var destroyOp = op
      destroyOp.udevDestroy = true
      discard destroyLinuxUdevRule(destroyOp)
      doAssert not fileExists(path),
        "udev rule file still exists after destroy"

      writeLineSentinel("OK: " & GateName)
      echo "  [OK] linux.udevRule lifecycle"
    except CatchableError as e:
      # Leave the drop-in behind only if we cannot clean it: the next run
      # uses a PID-scoped name, so a residue cannot make a later run pass.
      if fileExists(path):
        try: removeFile(path)
        except OSError: discard
      let head = e.msg.splitLines()[0]
      echo "  [FAIL] " & GateName & ": " & head
      writeLineSentinel("FAIL: " & GateName & " (" & head & ")")
      raise
  else:
    discard

suite "e2e_repro_infra_linux_udevrule_vm":
  test "linux.udevRule disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      let secondaryGate = main()
      if secondaryGate.len > 0:
        skip(secondaryGate)
    else:
      skip(GateSkipReason)
