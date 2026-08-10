## M83 step 13 — disposable-WSL gate for `systemd.systemTimer`.
##
## Writes a `.timer` unit under `/etc/systemd/system/` + runs
## `systemctl daemon-reload`. `stEnabled = false` and `stRunning =
## false` for the same reason as the M69 `systemd.systemUnit`
## baseline gate: WSL Ubuntu 22.04 does NOT activate
## systemd-as-PID-1 in this harness, so the runtime-state path
## (`enable` / `start`) is deferred to a Hyper-V / real-Linux VM.
## The driver's best-effort `disable` + `stop` calls in the
## `false`/`false` branch are `discard execCmd` so a non-zero exit
## from systemd-not-running is tolerated.
##
## Gated by `defined(linux)` AND `REPRO_M69_SYSTEMD_TIMER_VM=1`.

import std/[os, unittest]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "systemd.systemTimer"
const GateEnv = "REPRO_M69_SYSTEMD_TIMER_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_SYSTEMD_TIMER_VM not set."

proc writeSentinel(gate: string) =
  let path = getEnv("REPRO_M69_VM_SENTINEL_FILE", SentinelDefault)
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var f: File
  if open(f, path, fmAppend):
    try:
      f.writeLine("OK: " & gate)
    finally:
      close(f)

proc main() =
  when defined(linux):
    let timerName = "repro-m83-vm-test-" &
      $getCurrentProcessId() & ".timer"
    let timerContent =
      "[Unit]\n" &
      "Description=Reprobuild M83 step 13 systemd timer smoke\n" &
      "[Timer]\n" &
      "OnUnitActiveSec=1h\n" &
      "[Install]\n" &
      "WantedBy=timers.target\n"

    let op = PrivilegedOperation(kind: pokSystemdSystemTimer,
      address: "systemTimer:" & timerName,
      stName: timerName,
      stContent: timerContent,
      stEnabled: false,
      stRunning: false,
      stDestroy: false)
    let path = systemUnitPath(timerName)
    echo "  timer path: ", path

    discard applySystemdSystemTimer(op)
    doAssert fileExists(path),
      "expected timer unit file " & path & " after apply"
    let onDisk = readFile(path)
    doAssert onDisk == timerContent,
      "timer content mismatch on disk: " & onDisk

    let post = observeSystemdSystemTimer(op)
    doAssert post.present
    doAssert post.digestHex == posixDigestHexOfText(timerContent),
      "observe digest != desired digest"

    var destroyOp = op
    destroyOp.stDestroy = true
    discard applySystemdSystemTimer(destroyOp)
    doAssert not fileExists(path),
      "timer unit file still exists after destroy"

    writeSentinel(GateName)
    echo "  [OK] systemd.systemTimer lifecycle (file + daemon-reload)"
  else:
    discard

suite "e2e_repro_infra_systemd_system_timer_vm":
  test "systemd.systemTimer disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)
