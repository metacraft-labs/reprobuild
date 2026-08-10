## M83 step 13 — disposable-WSL gate for the POSIX arm of
## `fs.managedBlock`.
##
## Writes a managed block into a writable file under `/tmp/repro-vm-test`
## with surrounding user content. Verifies that:
##   * the block is inserted with the correct sentinels;
##   * surrounding content is preserved;
##   * observe digests the block body only;
##   * destroy removes the block and its sentinels but keeps the
##     surrounding content.
##
## Gated by `defined(linux)` AND `REPRO_M69_FS_MANAGED_BLOCK_VM=1`.

import std/[os, strutils, unittest]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "fs.managedBlock (POSIX)"
const GateEnv = "REPRO_M69_FS_MANAGED_BLOCK_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_FS_MANAGED_BLOCK_VM not set."

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
    let target = testRoot / "managed-block-" &
      $getCurrentProcessId() & ".sh"
    let blockId = "repro-m83-vm-test"
    let blockBody = "export REPRO_MANAGED_BLOCK_TEST=1\n"
    let userPreamble = "# user content above\n"

    # Pre-seed with user content so we can verify it's preserved.
    writeFile(target, userPreamble)

    # 1. Apply: insert the managed block.
    discard applyManagedBlockResource(target, blockId, blockBody)
    let after1 = readFile(target)
    doAssert after1.contains(userPreamble),
      "user preamble was not preserved"
    doAssert after1.contains("repro-managed:" & blockId),
      "managed-block open sentinel missing"
    doAssert after1.contains(blockBody),
      "block body missing from on-disk file"

    # 2. Observe present.
    let obs = observeManagedBlock(target, blockId)
    doAssert obs.present
    doAssert obs.rawBytes.len > 0

    # 3. Destroy: removes the block + sentinels, preserves the
    #    surrounding content.
    destroyManagedBlockResource(target, blockId)
    let after2 = readFile(target)
    doAssert after2.contains(userPreamble),
      "user preamble was lost during destroy"
    doAssert not after2.contains("repro-managed:" & blockId),
      "managed-block sentinel still present after destroy"

    let obs2 = observeManagedBlock(target, blockId)
    doAssert not obs2.present

    writeSentinel(GateName)
    echo "  [OK] fs.managedBlock (POSIX) lifecycle"
  else:
    discard

suite "e2e_repro_home_fs_managed_block_vm":
  test "fs.managedBlock (POSIX) disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)
