## Every home-layer managed block -- the profile's `fs.managedBlock`, the
## typed resources (`fs.managedBlock`, `shell.integration`, `env.user*`, the
## hook installers), the apply pipeline's step 8b and rollback -- is written,
## found and verified by ONE writer: one sentinel format, one locator, one
## atomic replacement.
##
## Issue: reprobuild-pm
## `issues/2026-11-16-home-apply-writes-managed-blocks-with-a-repro-managed-sentinel-of-its-own.md`.
## Governing text: reprobuild-pm `spec/Generated-Configuration-Files.md`
## §"Sentinel uniqueness" (one sentinel shape, `repro:<scope>:...`, with the
## earlier `repro-managed:` home form recognised as the same block) and
## §"Caching" (temp + fsync + rename, never a truncated or missing file);
## `spec/Core-Invariants.md` §"One Implementation Per Concern".
##
## The defect: `repro_home_resources/drivers/managed_block` and
## `repro_home_apply/materialize_managed_blocks` each carried a private copy
## of a writer that framed blocks as `# >>> repro-managed:<id> >>>`, while the
## profile's `fs.managedBlock` (the shared `repro_core/managed_block`) frames
## them as `# >>> repro:home:<id> >>>`. Neither locator saw the other's
## block, so one rc file could receive the same block twice; and both private
## writers replaced the host file by deleting it and then renaming a
## temporary file into the gap, so a crash in between left the user's rc file
## missing.
##
## Every case drives the real entry points on real files in a scratch
## directory under the system temp dir (inside the test-home fence's
## carve-out). NOTHING IS MOCKED: the properties are bytes on disk and
## whether the file exists.

import std/[os, strutils, tempfiles, unittest]

import repro_home_apply
import repro_home_generations
import repro_home_resources
import repro_home_rollback
from repro_dsl_stdlib/generated_config/managed_block as profileBlock import nil
from repro_core/managed_block import ManagedBlockError

const
  Id = "shared-block"
  CurrentOpen = "# >>> repro:home:shared-block >>>"
  CurrentClose = "# <<< repro:home:shared-block <<<"
  LegacyOpen = "# >>> repro-managed:shared-block >>>"
  LegacyClose = "# <<< repro-managed:shared-block <<<"

proc scratchRc(): string =
  createTempDir("repro-home-one-writer-", "") / ".bashrc"

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s: result[i] = byte(ord(ch))

proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc legacySeed(body: string): string =
  "user line 1\n" & LegacyOpen & "\n" & body & LegacyClose & "\nuser line 2\n"

proc currentWith(body: string): string =
  "user line 1\n" & CurrentOpen & "\n" & body & CurrentClose & "\nuser line 2\n"

suite "home managed blocks share the one writer":

  test "the profile writer and the resource writer update one block":
    let rc = scratchRc()
    writeFile(rc, "user line\n")
    discard profileBlock.updateManagedBlock(rc, Id, "from profile\n")
    discard applyManagedBlockResource(rc, Id, "from resource\n")
    var text = readFile(rc)
    checkpoint(text)
    check text.count(">>> ") == 1
    check text == "user line\n" & CurrentOpen & "\nfrom resource\n" &
      CurrentClose & "\n"
    # And the other way round.
    discard profileBlock.updateManagedBlock(rc, Id, "from profile again\n")
    text = readFile(rc)
    checkpoint(text)
    check text.count(">>> ") == 1
    check observeManagedBlock(rc, Id).rawBytes.toStr == "from profile again\n"

  test "the apply pipeline's writer updates the profile's block":
    let rc = scratchRc()
    discard profileBlock.updateManagedBlock(rc, Id, "from profile\n")
    let rec = applyManagedBlock(PlannedManagedBlock(hostFilePath: rc,
      blockId: Id, blockBytes: "from apply\n"))
    let text = readFile(rc)
    checkpoint(text)
    check text.count(">>> ") == 1
    check text == CurrentOpen & "\nfrom apply\n" & CurrentClose & "\n"
    check rec.postWriteBlockBytes.toStr == "from apply\n"

  test "a block written as repro-managed: is the same block and migrates in place":
    for writer in ["resource", "apply", "profile"]:
      let rc = scratchRc()
      writeFile(rc, legacySeed("old\n"))
      # It is observed as present before any write ...
      check observeManagedBlock(rc, Id).rawBytes.toStr == "old\n"
      case writer
      of "resource": discard applyManagedBlockResource(rc, Id, "new\n")
      of "apply":
        discard applyManagedBlock(PlannedManagedBlock(hostFilePath: rc,
          blockId: Id, blockBytes: "new\n"))
      else: discard profileBlock.updateManagedBlock(rc, Id, "new\n")
      # ... and rewritten in the current form, user lines untouched.
      checkpoint(writer & ": " & readFile(rc))
      check readFile(rc) == currentWith("new\n")

  test "removing a repro-managed: block keeps every user byte":
    let rc = scratchRc()
    writeFile(rc, legacySeed("old\n"))
    destroyManagedBlockResource(rc, Id)
    check readFile(rc) == "user line 1\nuser line 2\n"

  test "a generation recorded against a repro-managed: block still verifies":
    let rc = scratchRc()
    writeFile(rc, legacySeed("old\n"))
    let rec = ManagedBlock(hostFilePath: rc, blockId: Id,
      postWriteBlockBytes: toBytes("old\n"))
    var report = verifyManagedBlockAgainstCurrent(rec)
    check not report.drifted
    # Migrating the sentinels does not change the block's bytes, so the
    # record keeps verifying after the next write of the same content.
    discard applyManagedBlockResource(rc, Id, "old\n")
    check readFile(rc) == currentWith("old\n")
    report = verifyManagedBlockAgainstCurrent(rec)
    check not report.drifted

  test "a file holding the block in both forms is refused, not appended to":
    let rc = scratchRc()
    let doubled = legacySeed("a\n") & CurrentOpen & "\nb\n" & CurrentClose & "\n"
    writeFile(rc, doubled)
    expect ManagedBlockError:
      discard applyManagedBlockResource(rc, Id, "c\n")
    expect ManagedBlockError:
      discard observeManagedBlock(rc, Id)
    check readFile(rc) == doubled
    let report = verifyManagedBlockAgainstCurrent(ManagedBlock(
      hostFilePath: rc, blockId: Id, postWriteBlockBytes: toBytes("a\n")))
    check report.drifted

  test "an empty block stays empty, and its earlier record keeps verifying":
    # Review finding: a writer that gave an empty body a blank line changed
    # the bytes between the sentinels on migration.
    let rc = scratchRc()
    writeFile(rc, "u\n" & LegacyOpen & "\n" & LegacyClose & "\n")
    let rec = ManagedBlock(hostFilePath: rc, blockId: Id,
      postWriteBlockBytes: @[])
    check not verifyManagedBlockAgainstCurrent(rec).drifted
    let recorded = applyManagedBlockResource(rc, Id, "")
    check readFile(rc) == "u\n" & CurrentOpen & "\n" & CurrentClose & "\n"
    check recorded.len == 0
    check not verifyManagedBlockAgainstCurrent(rec).drifted
    let desired = Resource(kind: rkFsManagedBlock, hostFilePath: rc,
      managedBlockId: Id, managedBlockContent: "")
    check digestFsManagedBlock(desired) == observeManagedBlock(rc, Id).digest

  test "line ends are compared folded, so CRLF neither drifts nor re-plans":
    # Review finding: the writer spells a block's line ends as the host file
    # does, so declared CRLF content, a CRLF host file, and an edit to the
    # host file's first line must not read as drift.
    let rc = scratchRc()
    writeFile(rc, "first\r\nsecond\r\n")
    let content = "a\r\nb\r\n"
    discard applyManagedBlockResource(rc, Id, content)
    check readFile(rc).contains(CurrentOpen & "\r\na\r\nb\r\n" & CurrentClose)
    let desired = Resource(kind: rkFsManagedBlock, hostFilePath: rc,
      managedBlockId: Id, managedBlockContent: content)
    check digestFsManagedBlock(desired) == observeManagedBlock(rc, Id).digest
    let rec = applyManagedBlock(PlannedManagedBlock(hostFilePath: rc,
      blockId: Id, blockBytes: content))
    check not verifyManagedBlockAgainstCurrent(ManagedBlock(
      hostFilePath: rc, blockId: Id,
      postWriteBlockBytes: rec.postWriteBlockBytes)).drifted
    # The user re-terminates the file's first line with LF: an edit outside
    # the block, which is not drift.
    writeFile(rc, readFile(rc).replace("first\r\n", "first\n"))
    check digestFsManagedBlock(desired) == observeManagedBlock(rc, Id).digest
    # An earlier record that kept the CRLF bytes it was given still verifies.
    check not verifyManagedBlockAgainstCurrent(ManagedBlock(
      hostFilePath: rc, blockId: Id,
      postWriteBlockBytes: toBytes(content))).drifted

  test "the host file never disappears while its block is rewritten":
    # A crash between "delete the rc file" and "rename the new one into
    # place" leaves the user without their rc file. A watcher thread stats
    # the file as fast as it can while the writers rewrite the block many
    # times; any moment at which the file is absent is that gap.
    let rc = scratchRc()
    writeFile(rc, repeat("# user content line\n", 2000))
    var stop {.global.}: bool
    var absent {.global.}: int
    var watched {.global.}: string
    stop = false
    absent = 0
    watched = rc
    proc watch() {.thread.} =
      {.cast(gcsafe).}:
        while not stop:
          if not fileExists(watched):
            inc absent
    var watcher: Thread[void]
    createThread(watcher, watch)
    for i in 0 ..< 1500:
      if i mod 2 == 0:
        discard applyManagedBlockResource(rc, Id, "round " & $i & "\n")
      else:
        discard applyManagedBlock(PlannedManagedBlock(hostFilePath: rc,
          blockId: Id, blockBytes: "round " & $i & "\n"))
    stop = true
    joinThread(watcher)
    checkpoint("rewrites during which the rc file was observed missing: " &
      $absent)
    check absent == 0
