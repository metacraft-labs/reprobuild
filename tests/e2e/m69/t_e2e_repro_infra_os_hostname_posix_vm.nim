## M83 step 13 — disposable-WSL gate for the POSIX arm of `os.hostname`.
##
## The driver invokes `hostnamectl set-hostname <name>` on Linux. In
## WSL Ubuntu 22.04 without systemd-as-PID-1, `hostnamectl` typically
## returns "Could not set property" or "Failed to connect to bus"
## and exits non-zero — the driver then raises `EProtocol`. We catch
## that and emit a SKIP sentinel.
##
## Gated by `defined(linux)` AND `REPRO_M69_OS_HOSTNAME_VM=1`.

import std/[os, strutils]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "os.hostname (POSIX)"

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
  let sandboxMode =
    defined(linux) and getEnv("REPRO_M69_OS_HOSTNAME_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_OS_HOSTNAME_VM not set."
    quit(0)

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

main()
