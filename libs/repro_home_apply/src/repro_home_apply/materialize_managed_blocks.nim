## Apply managed-block writes (apply pipeline step 8b).
##
## A "managed block" is a sentinel-delimited region inside an otherwise
## user-owned host file (typical example: a `# >>> repro:home:<blockId> >>>`
## fenced section inside `~/.bashrc`). The pipeline records the bytes
## inside the fences plus the pre-write and post-write whole-file
## digests, so rollback can either restore the block or remove it
## without disturbing the user's surrounding edits.
##
## The write itself is the shared managed-file writer's
## (`repro_core/managed_block`, reached through
## `repro_home_resources/drivers/managed_block`): one sentinel format, one
## locator, one atomic temp + fsync + rename (Core-Invariants.md §"One
## Implementation Per Concern"). A block an earlier release wrote as
## `repro-managed:<blockId>` is the same block and is rewritten in place.
##
## Phase A does not exercise managed blocks (the gates do not enable
## any package whose stdlib output declares a `fs.managedBlock`
## action), so this module contains the writer and the manifest-record
## synthesis but not a discovery pipeline. M65's
## `repro home set` integration is the first consumer.

import std/strutils

import blake3
import repro_home_generations

import repro_home_resources/test_home_fence
import repro_home_resources/drivers/managed_block as homeBlock
import ./errors

type
  PlannedManagedBlock* = object
    ## One managed-block write the planner has scheduled. `blockBytes`
    ## is the content that goes BETWEEN the sentinels; the sentinels
    ## themselves are added by the shared writer.
    hostFilePath*: string
    blockId*: string
    blockBytes*: string

  AppliedManagedBlockRecord* = object
    hostFilePath*: string
    blockId*: string
    preWriteFileDigest*: Digest256
    postWriteBlockBytes*: seq[byte]
    postWriteFileDigest*: Digest256

proc digestBytes(content: string): Digest256 =
  var buf = newSeq[byte](content.len)
  for i, ch in content:
    buf[i] = byte(ord(ch))
  let raw = blake3.digest(buf)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc applyManagedBlock*(planned: PlannedManagedBlock): AppliedManagedBlockRecord =
  enforceTestHomeFence(planned.hostFilePath, "home.managedBlock apply")
  result.hostFilePath = planned.hostFilePath
  result.blockId = planned.blockId
  var written: tuple[prior, written: string]
  try:
    written = homeBlock.writeHomeManagedBlock(planned.hostFilePath,
      planned.blockId, planned.blockBytes)
  except homeBlock.ManagedBlockError as err:
    raiseMaterializeFailed(planned.hostFilePath,
      "managed block '" & planned.blockId & "': " & err.msg)
  except OSError as err:
    raiseMaterializeFailed(planned.hostFilePath,
      "managed-block atomic replace failed: " & err.msg)
  result.preWriteFileDigest = digestBytes(written.prior)
  # Recorded in the LF-folded form the readers compare against: the shared
  # writer spells the block's line ends as the host file does.
  let recorded = planned.blockBytes.replace("\r\n", "\n")
  result.postWriteBlockBytes = newSeq[byte](recorded.len)
  for i, ch in recorded:
    result.postWriteBlockBytes[i] = byte(ord(ch))
  result.postWriteFileDigest = digestBytes(written.written)
