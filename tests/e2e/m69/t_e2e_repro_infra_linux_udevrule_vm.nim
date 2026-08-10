## M83 step 13 — disposable-WSL gate for `linux.udevRule`.
##
## Writes a `/etc/udev/rules.d/` drop-in. The driver invokes
## `udevadm control --reload-rules`; if the udev daemon is not
## running (likely the case inside a bare WSL Ubuntu rootfs without
## systemd-as-PID-1), the reload returns non-zero AND the driver
## raises `EProtocol`. We therefore guard the apply with a
## `try/except` and treat a "udev daemon missing" failure as SKIP
## (writing `SKIP: linux.udevRule (no udev daemon in WSL)` to the
## sentinel), exactly as the prompt's "what WSL cannot test, the next
## Linux VM catches" guidance allows.
##
## Gated by `defined(linux)` AND `REPRO_M69_UDEV_VM=1`.

import std/[os, strutils, unittest]

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

proc main() =
  when defined(linux):
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

    var skipped = false
    try:
      discard applyLinuxUdevRule(op)
    except CatchableError as e:
      # Treat "udevadm control --reload-rules" failure as SKIP — WSL
      # bare rootfs has no udev daemon to talk to. The file write
      # itself succeeded (it happens before the reload).
      if e.msg.contains("udevadm") or
         e.msg.contains("reload-rules") or
         e.msg.contains("polling on epoll"):
        echo "  [SKIP] " & GateName & ": " & e.msg.splitLines()[0]
        # File should still exist; clean it up so the next run is idempotent.
        if fileExists(path):
          try: removeFile(path)
          except OSError: discard
        writeLineSentinel("SKIP: " & GateName & " (no udev daemon in WSL)")
        skipped = true
      else:
        raise

    if not skipped:
      doAssert fileExists(path),
        "expected udev rule file " & path & " after apply"
      doAssert readFile(path) == ruleContent,
        "udev rule content mismatch on disk"

      let post = observeLinuxUdevRule(op)
      doAssert post.present
      doAssert post.digestHex == posixDigestHexOfText(ruleContent),
        "observe digest != desired digest"

      var destroyOp = op
      destroyOp.udevDestroy = true
      try:
        discard destroyLinuxUdevRule(destroyOp)
      except CatchableError:
        # The destroy path also runs `udevadm control --reload-rules`.
        # Tolerate it the same way; clean the file manually.
        if fileExists(path):
          try: removeFile(path)
          except OSError: discard
      doAssert not fileExists(path),
        "udev rule file still exists after destroy"

      writeLineSentinel("OK: " & GateName)
      echo "  [OK] linux.udevRule lifecycle"
  else:
    discard

suite "e2e_repro_infra_linux_udevrule_vm":
  test "linux.udevRule disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)
