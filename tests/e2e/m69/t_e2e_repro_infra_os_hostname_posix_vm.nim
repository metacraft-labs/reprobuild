## M83 step 13 — disposable-WSL gate for the POSIX arm of `os.hostname`.
##
## The driver invokes `hostnamectl set-hostname <name>` on Linux. In
## WSL Ubuntu 22.04 without systemd-as-PID-1, `hostnamectl` typically
## returns "Could not set property" or "Failed to connect to bus"
## and exits non-zero — the driver then raises `EProtocol`. We catch
## that and emit a SKIP sentinel.
##
## Gated by `defined(linux)` AND `REPRO_M69_OS_HOSTNAME_VM=1`.

import std/[os, strutils, unittest]

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

proc main() =
  when defined(linux):
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
      let head = e.msg.splitLines()[0]
      if head.contains("Failed to connect to bus") or
         head.contains("hostnamectl") or
         head.contains("systemd") or
         head.contains("D-Bus") or
         head.contains("dbus") or
         head.contains("Could not set property"):
        echo "  [SKIP] " & GateName & ": " & head
        writeLineSentinel("SKIP: " & GateName &
          " (hostnamectl needs systemd-as-PID-1 in WSL)")
      else:
        raise
  else:
    discard

suite "e2e_repro_infra_os_hostname_posix_vm":
  test "os.hostname (POSIX) disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)
