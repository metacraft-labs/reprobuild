## M83 step 13 — disposable-WSL gate for `linux.sysctl`.
##
## Extends the M69 WSL harness (tools/wsl-m69-posix/) to cover the
## post-M69 Linux drivers. Each "VM gate" file is a thin standalone
## program that calls the driver's `apply*` / `observe*` / `destroy*`
## entry points directly inside a throwaway Ubuntu 22.04 distro — the
## host-side runner unregisters the distro in `finally`, so a failure
## here cannot leak.
##
## ===========================================================================
## DESTRUCTIVE GATE — REQUIRES A LINUX SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## Gated by BOTH `defined(linux)` AND `REPRO_M69_SYSCTL_VM=1`. Outside
## the disposable distro the program exits 0 immediately — the smoke
## suites in `libs/repro_elevation/tests/` already cover the pure parser
## + drift logic cross-platform; this gate adds the real-mutation half.
##
## ## Why `net.ipv4.ip_forward`
##
## Many sysctl keys are container-restricted in WSL kernels; the chosen
## key is unprivileged AND universally supported by WSL2's Microsoft
## kernel. The drop-in file is namespaced with the PID so concurrent
## runs cannot collide.
##
## ## Sentinel
##
## On success the program appends `OK: linux.sysctl\n` to the file at
## `REPRO_M69_VM_SENTINEL_FILE` (or `/tmp/repro-vm-test/sentinels.txt`
## when unset). The orchestrator greps for the gate's `OK:` line.

import std/[os, strutils]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.sysctl"

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
  let sandboxMode =
    defined(linux) and getEnv("REPRO_M69_SYSCTL_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_SYSCTL_VM not set (or not on " &
      "Linux) — the real /etc/sysctl.d/ write scenario is NOT " &
      "EXERCISED on this host."
    quit(0)

  when defined(linux):
    # PID-scoped filename so concurrent / re-runs do not collide.
    let dropInName = "99-reprobuild-m83-vm-test-" &
      $getCurrentProcessId() & ".conf"
    let key = "net.ipv4.ip_forward"
    let value = "0"

    let op = PrivilegedOperation(kind: pokLinuxSysctl,
      address: "sysctl:" & key,
      sysctlKey: key,
      sysctlValue: value,
      sysctlFilename: dropInName,
      sysctlDestroy: false)
    let path = sysctlDropInPath(op)
    echo "  drop-in path: ", path

    # 1. APPLY — writes the drop-in + runs `sysctl -p <path>`.
    discard applyLinuxSysctl(op)
    doAssert fileExists(path),
      "expected drop-in file " & path & " to exist after apply"
    let live = readFile(path)
    doAssert live == sysctlDropInContent(key, value),
      "drop-in bytes did not match canonical form: " & live

    # 2. OBSERVE — drift gate confirms the live file matches desired.
    let post = observeLinuxSysctl(op)
    doAssert post.present, "observe reports absent after a successful apply"
    let desired = sysctlDropInContent(key, value)
    let desiredHex = posixDigestHexOfText(desired)
    doAssert post.digestHex == desiredHex,
      "observed digest != desired digest: " & post.digestHex & " vs " &
      desiredHex

    # 3. DESTROY — file gone, observe reports absent.
    var destroyOp = op
    destroyOp.sysctlDestroy = true
    discard destroyLinuxSysctl(destroyOp)
    doAssert not fileExists(path),
      "drop-in file " & path & " still exists after destroy"
    let postDestroy = observeLinuxSysctl(op)
    doAssert not postDestroy.present,
      "observe reports present after destroy"

    writeSentinel(GateName)
    echo "  [OK] linux.sysctl apply/observe/destroy lifecycle"
  else:
    discard

main()
