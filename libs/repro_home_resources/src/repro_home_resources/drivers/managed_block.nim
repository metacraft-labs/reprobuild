## `fs.managedBlock` as a typed resource.
##
## The home layer's entry point onto the ONE managed-file writer,
## `repro_core/managed_block` (Core-Invariants.md §"One Implementation Per
## Concern"; Generated-Configuration-Files.md §"Sentinel uniqueness"). The
## sentinel format (`# >>> repro:home:<blockId> >>>`), the locator (which
## refuses a duplicated or unterminated block), the splice and the atomic
## temp + fsync + rename write are that module's. This module fixes the key
## to the elided home form and adapts it to the M68 resource lifecycle; the
## apply pipeline (`repro_home_apply/materialize_managed_blocks`), rollback
## (`repro_home_rollback`) and the hook installers all reach the writer
## through the procs below, never through a sentinel of their own.
##
## Earlier releases wrote these blocks as `# >>> repro-managed:<blockId> >>>`
## from two private copies of a writer. The shared locator recognises that
## form as the same block, so the next write migrates a live rc file in
## place rather than appending a second block beside it.
##
## Drift detection: BLAKE3-256 over the bytes BETWEEN the sentinels.
## Surrounding edits (the user's own lines outside the block) do
## NOT count as drift — the spec's "managed block in a partially
## owned file" semantics are preserved.

import std/[os, strutils]
from repro_core/paths import extendedPath
import repro_core/managed_block as shared

import ./../manifest_record
import ./../test_home_fence
import ./../types

export shared.ManagedBlockError, shared.ManagedBlockOverlap

proc homeManagedBlockKey*(blockId: string): shared.ManagedBlockKey =
  ## The key of a home-layer block: the elided `repro:home:<blockId>` form.
  shared.managedBlockKey(shared.HomeBlockScope, "", blockId)

proc homeManagedBlockOpenSentinel*(blockId: string): string =
  shared.openSentinel(homeManagedBlockKey(blockId))

proc homeManagedBlockCloseSentinel*(blockId: string): string =
  shared.closeSentinel(homeManagedBlockKey(blockId))

# ---------------------------------------------------------------------------
# Reading.
# ---------------------------------------------------------------------------

proc readHomeManagedBlockBody*(content, blockId: string; fileName = ""):
    tuple[found: bool; body: string] =
  ## The bytes between `blockId`'s sentinels in `content`, sentinel lines
  ## excluded, with every CRLF folded to LF. The shared writer lays the
  ## block's lines out with the host file's line terminator (which can change
  ## when the user edits the file's first line), so the folded form is the
  ## one stable across terminators: what was written, not how the file
  ## spells it. Desired digests (`lifecycle.managedBlockBodyDigest`) and
  ## rollback's verification fold the same way.
  ## Raises `ManagedBlockError` for a duplicated or unterminated block.
  let span = shared.locateManagedBlock(content, homeManagedBlockKey(blockId),
    fileName)
  if not span.found:
    return (false, "")
  (true, content[span.contentStart ..< span.contentEnd].replace("\r\n", "\n"))

proc withoutHomeManagedBlock*(content, blockId: string; fileName = ""):
    string =
  ## `content` with `blockId`'s block and its sentinel lines removed, every
  ## other byte kept.
  shared.withoutManagedBlock(content, homeManagedBlockKey(blockId), fileName)

# ---------------------------------------------------------------------------
# Observation.
# ---------------------------------------------------------------------------

proc observeManagedBlock*(hostFile, blockId: string): ObservedState =
  ## Look up the managed block in `hostFile`. The observed bytes
  ## are the content BETWEEN the sentinels — the block id and the
  ## sentinel lines themselves are NOT included so surrounding
  ## edits don't trigger drift. A host file holding the block twice, or
  ## an unterminated block, raises `ManagedBlockError`: guessing "absent"
  ## would append a further copy.
  if not fileExists(extendedPath(hostFile)):
    result.present = false
    result.digest = zeroDigest()
    return
  let content = readFile(extendedPath(hostFile))
  let found = readHomeManagedBlockBody(content, blockId, hostFile)
  if not found.found:
    result.present = false
    result.digest = zeroDigest()
    return
  var raw = newSeq[byte](found.body.len)
  for i, ch in found.body:
    raw[i] = byte(ord(ch))
  result.present = true
  result.rawBytes = raw
  result.digest = digestOfBytes(raw)

# ---------------------------------------------------------------------------
# Apply and removal.
# ---------------------------------------------------------------------------

proc spliceHomeManagedBlock*(existing, blockId, content: string;
                             fileName = ""): string =
  ## The bytes a host file holding `existing` should hold once `blockId`'s
  ## block holds `content`. A new block goes directly after the last line,
  ## as `fs.managedBlock` has always placed it.
  shared.spliceManagedBlock(existing, homeManagedBlockKey(blockId), content,
    shared.alDirectlyAfter, fileName)

proc writeHomeManagedBlock*(hostFile, blockId, content: string):
    tuple[prior, written: string] =
  ## Insert or update `blockId`'s block in `hostFile` (which need not
  ## exist) through the shared writer: atomic and durable, and not written
  ## at all when its bytes would not change. Returns the bytes the file held
  ## before and holds after. Does not apply the test-home fence; callers do.
  let prior = shared.readManagedFile(hostFile)
  let next = spliceHomeManagedBlock(prior, blockId, content, hostFile)
  discard shared.updateManagedFile(hostFile, prior, next)
  (prior, next)

proc applyManagedBlockResource*(hostFile, blockId, content: string):
    seq[byte] =
  ## Insert or update the managed block. Returns the bytes between
  ## the sentinels (the recorded payload), read back from the file, so
  ## the recorded digest matches what `observeManagedBlock` will read
  ## on the next apply. The writer terminates a body that does not end
  ## in a newline, so the on-disk body can be 1 byte longer than
  ## `content`.
  enforceTestHomeFence(hostFile, "fs.managedBlock apply")
  discard writeHomeManagedBlock(hostFile, blockId, content)
  let post = observeManagedBlock(hostFile, blockId)
  if post.present:
    return post.rawBytes
  result = newSeq[byte](content.len)
  for i, ch in content:
    result[i] = byte(ord(ch))

proc removeHomeManagedBlockFile*(hostFile, blockId: string): bool =
  ## Remove `blockId`'s block from `hostFile` without the test-home fence.
  ## Returns whether the file changed. See `destroyManagedBlockResource`.
  if not fileExists(extendedPath(hostFile)):
    return false
  let prior = readFile(extendedPath(hostFile))
  let rewritten = withoutHomeManagedBlock(prior, blockId, hostFile)
  if rewritten == prior:
    return false
  if rewritten.len == 0:
    # The block was all the file held: a zero-block file is never left
    # behind. Any byte of the user's -- a blank line included -- keeps it.
    removeFile(extendedPath(hostFile))
    return true
  shared.updateManagedFile(hostFile, prior, rewritten)

proc destroyManagedBlockResource*(hostFile, blockId: string) =
  ## Remove the managed-block sentinels and content from the host
  ## file. Every byte outside the block is kept exactly as it is now --
  ## including edits the user made after the block was first written, so
  ## the file is never reverted to an earlier snapshot -- and the host
  ## file is deleted only when nothing at all is left in it once the
  ## block is gone (Generated-Configuration-Files.md §"Deletion
  ## semantics"). This is the one removal path for a home-layer block:
  ## apply, rollback and the hook installers all call it.
  enforceTestHomeFence(hostFile, "fs.managedBlock destroy")
  discard removeHomeManagedBlockFile(hostFile, blockId)
