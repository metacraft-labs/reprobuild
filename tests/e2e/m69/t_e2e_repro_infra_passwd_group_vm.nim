## M83 step 13 — disposable-WSL gate for `passwd.group`.
##
## Creates a group with `groupadd`, observes it, then removes it with
## `groupdel`. Mirrors the M69 `passwd.user` baseline gate's shape but
## targets group lifecycle (M83 step 6 driver B).
##
## Gated by `defined(linux)` AND `REPRO_M69_PASSWD_GROUP_VM=1`. The
## PID-scoped group name guarantees no collision with the rootfs's
## existing groups.

import std/os

import ct_test_unittest_parallel

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "passwd.group"
const GateEnv = "REPRO_M69_PASSWD_GROUP_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_PASSWD_GROUP_VM not set."

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

suite "e2e_repro_infra_passwd_group_vm":
  test "passwd.group disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)
