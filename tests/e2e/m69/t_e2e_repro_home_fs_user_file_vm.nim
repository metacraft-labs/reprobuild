## M83 step 13 — disposable-WSL gate for the POSIX arm of `fs.userFile`.
##
## The home-scope `fs.userFile` driver writes a whole-file under the
## user's HOME. The Linux smoke is a thin direct-call of
## `applyUserFileResource` / `observeUserFile` / `destroyUserFileResource`
## targeting `/tmp/repro-vm-test/<file>` (a writable path that does
## not pollute the distro rootfs further than the throwaway image).
##
## Gated by `defined(linux)` AND `REPRO_M69_FS_USER_FILE_VM=1`.

import std/os

import ct_test_unittest_parallel

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "fs.userFile (POSIX)"
const GateEnv = "REPRO_M69_FS_USER_FILE_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_FS_USER_FILE_VM not set."

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
    let testRoot = "/tmp/repro-vm-test"
    if not dirExists(testRoot):
      createDir(testRoot)
    let target = testRoot / "fs-user-file-" &
      $getCurrentProcessId() & ".txt"
    let content = "managed=true\nversion=1\n"

    if fileExists(target):
      removeFile(target)

    # 1. Apply.
    let recorded = applyUserFileResource(target, content, "0644")
    doAssert fileExists(target),
      "expected " & target & " to exist after apply"
    doAssert readFile(target) == content,
      "fs.userFile content mismatch on disk"
    doAssert recorded.len == content.len

    # 2. Observe present.
    let obs = observeUserFile(target)
    doAssert obs.present
    doAssert obs.rawBytes.len == content.len

    # 3. Destroy.
    destroyUserFileResource(target)
    doAssert not fileExists(target),
      "file still exists after destroy"
    let obs2 = observeUserFile(target)
    doAssert not obs2.present

    writeSentinel(GateName)
    echo "  [OK] fs.userFile (POSIX) lifecycle"
  else:
    discard

suite "e2e_repro_home_fs_user_file_vm":
  test "fs.userFile (POSIX) disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)
