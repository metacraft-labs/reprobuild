## M83 step 13 — disposable-WSL gate for the POSIX arm of `os.timezone`.
##
## The driver invokes `timedatectl set-timezone <iana>` on Linux. In
## WSL Ubuntu 22.04 without systemd-as-PID-1 `timedatectl` returns
## "Failed to connect to bus: No such file or directory" and exits
## non-zero — the driver then raises `EProtocol`. We catch that and
## emit a SKIP sentinel, exactly as the prompt's failure-resistance
## guidance allows. When systemd-as-PID-1 is active (or on a
## conventional Linux VM) this gate exercises the real `timedatectl
## set-timezone` shell-out.
##
## Gated by `defined(linux)` AND `REPRO_M69_OS_TIMEZONE_VM=1`.

import std/[os, strutils]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "os.timezone (POSIX)"

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
    defined(linux) and getEnv("REPRO_M69_OS_TIMEZONE_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_OS_TIMEZONE_VM not set."
    quit(0)

  when defined(linux):
    # UTC is universally available in the IANA database; safe and
    # observable through `timedatectl`.
    let tz = "UTC"
    let op = PrivilegedOperation(kind: pokOsTimezone,
      address: "timezone:" & tz,
      tzIana: tz)

    try:
      discard applyPosixOsTimezone(op)
      let post = observePosixOsTimezone(op)
      doAssert post.present, "observePosixOsTimezone reports absent"
      writeLineSentinel("OK: " & GateName)
      echo "  [OK] os.timezone (POSIX) lifecycle"
    except CatchableError as e:
      let head = e.msg.splitLines()[0]
      if head.contains("Failed to connect to bus") or
         head.contains("timedatectl") or
         head.contains("systemd") or
         head.contains("D-Bus") or
         head.contains("dbus"):
        echo "  [SKIP] " & GateName & ": " & head
        writeLineSentinel("SKIP: " & GateName &
          " (timedatectl needs systemd-as-PID-1 in WSL)")
      else:
        raise
  else:
    discard

main()
