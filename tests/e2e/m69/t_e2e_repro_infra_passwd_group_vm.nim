## M83 step 13 — disposable-WSL gate for `passwd.group`.
##
## Creates a group with `groupadd`, observes it, then removes it with
## `groupdel`. Mirrors the M69 `passwd.user` baseline gate's shape but
## targets group lifecycle (M83 step 6 driver B).
##
## Gated by `defined(linux)` AND `REPRO_M69_PASSWD_GROUP_VM=1`. The
## PID-scoped group name guarantees no collision with the rootfs's
## existing groups.

import std/[os]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "passwd.group"

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
    defined(linux) and getEnv("REPRO_M69_PASSWD_GROUP_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_PASSWD_GROUP_VM not set."
    quit(0)

  when defined(linux):
    let groupName = "reprom83vm" & $getCurrentProcessId()
    let op = PrivilegedOperation(kind: pokPasswdGroup,
      address: "group:" & groupName,
      pgName: groupName,
      pgGid: "",
      pgMembers: @[],
      pgDestroy: false)

    discard applyPasswdGroup(op)
    let post = observePasswdGroup(op)
    doAssert post.present, "group '" & groupName & "' should exist after apply"

    var destroyOp = op
    destroyOp.pgDestroy = true
    discard destroyPasswdGroup(destroyOp)
    let post2 = observePasswdGroup(op)
    doAssert not post2.present,
      "group '" & groupName & "' should not exist after destroy"

    writeSentinel(GateName)
    echo "  [OK] passwd.group lifecycle"
  else:
    discard

main()
