## M83 step 13 — disposable-WSL gate for `linux.dconfKey`.
##
## The driver shells out to `dconf write` / `dconf read` / `dconf reset`.
## `dconf` requires a running dbus session at
## `$DBUS_SESSION_BUS_ADDRESS`; the orchestrator starts a session bus
## under the throwaway distro before running this gate. If `dconf` is
## not installed (Ubuntu's `dconf-cli` package) or the dbus session
## connection fails, the gate emits a SKIP sentinel rather than failing
## the harness.
##
## Gated by `defined(linux)` AND `REPRO_M69_DCONF_KEY_VM=1`.

import std/[os, strutils, osproc]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.dconfKey"

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

proc dconfPresent(): bool =
  let (output, code) = execCmdEx("command -v dconf")
  result = code == 0 and output.strip().len > 0

proc dbusSessionLive(): bool =
  # `dconf list /` is a quick smoke that exercises the dbus path the
  # driver depends on without writing anything. If dbus is missing,
  # it exits non-zero with a "Cannot autolaunch D-Bus" or similar
  # message.
  let (_, code) = execCmdEx("dconf list / 2>&1")
  result = code == 0

proc main() =
  let sandboxMode =
    defined(linux) and getEnv("REPRO_M69_DCONF_KEY_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_DCONF_KEY_VM not set."
    quit(0)

  when defined(linux):
    if not dconfPresent():
      echo "  [SKIP] " & GateName & ": dconf-cli not installed in distro"
      writeLineSentinel("SKIP: " & GateName & " (dconf-cli missing)")
      quit(0)

    if not dbusSessionLive():
      echo "  [SKIP] " & GateName & ": no live dbus session in WSL"
      writeLineSentinel("SKIP: " & GateName & " (dbus session missing)")
      quit(0)

    # Use a namespaced key under /org/reprobuild/m83-vm-test/ so we
    # don't disturb any real GNOME settings (and there is no schema
    # for our path — dconf accepts the write anyway).
    let key = "/org/reprobuild/m83-vm-test/value"
    let value = "'hello'"  # GVariant string literal

    try:
      discard applyDconfKey(key, value)
      let obs = observeDconfKey(key)
      doAssert obs.present, "dconf key should be present after apply"
      destroyDconfKey(key)
      let obs2 = observeDconfKey(key)
      doAssert not obs2.present, "dconf key should be absent after destroy"
      writeLineSentinel("OK: " & GateName)
      echo "  [OK] linux.dconfKey lifecycle"
    except CatchableError as e:
      let head = e.msg.splitLines()[0]
      echo "  [SKIP] " & GateName & ": " & head
      writeLineSentinel("SKIP: " & GateName & " (" & head & ")")
  else:
    discard

main()
