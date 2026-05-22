## Apply managed-block writes (apply pipeline step 8b).
##
## A "managed block" is a sentinel-delimited region inside an otherwise
## user-owned host file (typical example: a `# >>> repro-managed >>>`
## fenced section inside `~/.bashrc`). The pipeline records the bytes
## inside the fences plus the pre-write and post-write whole-file
## digests, so rollback can either restore the block or remove it
## without disturbing the user's surrounding edits.
##
## Phase A does not exercise managed blocks (the gates do not enable
## any package whose stdlib output declares a `fs.managedBlock`
## action), so this module contains the writer and the manifest-record
## synthesis but not a discovery pipeline. M65's
## `repro home set` integration is the first consumer.

import std/[os, strutils]
from repro_core/paths import extendedPath

import blake3
import repro_home_generations

import ./errors

type
  PlannedManagedBlock* = object
    ## One managed-block write the planner has scheduled. `blockBytes`
    ## is the content that goes BETWEEN the sentinels; the sentinels
    ## themselves are added by this module.
    hostFilePath*: string
    blockId*: string
    blockBytes*: string

  AppliedManagedBlockRecord* = object
    hostFilePath*: string
    blockId*: string
    preWriteFileDigest*: Digest256
    postWriteBlockBytes*: seq[byte]
    postWriteFileDigest*: Digest256

const
  OpenSentinelPrefix* = "# >>> repro-managed:"
  OpenSentinelSuffix* = " >>>"
  CloseSentinelPrefix* = "# <<< repro-managed:"
  CloseSentinelSuffix* = " <<<"

proc renderSentinel(prefix, id, suffix: string): string =
  prefix & id & suffix

proc digestBytes(content: string): Digest256 =
  var buf = newSeq[byte](content.len)
  for i, ch in content:
    buf[i] = byte(ord(ch))
  let raw = blake3.digest(buf)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc digestSeqBytes(content: openArray[byte]): Digest256 =
  let raw = blake3.digest(content)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc spliceBlock(existing, blockBytes, openSentinel, closeSentinel: string):
    string =
  ## Find the (open, close) sentinel pair in `existing`. If both are
  ## present, replace the bytes between them with `blockBytes`. If
  ## neither is present, append a new block at the end of the file.
  ## If exactly one is present the file is corrupt; we treat that as
  ## "append fresh" (the renderer would otherwise lose data); the
  ## pipeline records the pre-write digest, so rollback can still
  ## restore the corrupt state.
  let openIdx = existing.find(openSentinel)
  let closeIdx = existing.find(closeSentinel)
  if openIdx >= 0 and closeIdx >= 0 and closeIdx > openIdx:
    let lineEndAfterOpen = existing.find('\n', openIdx)
    let bodyStart = if lineEndAfterOpen >= 0: lineEndAfterOpen + 1
                    else: openIdx + openSentinel.len
    return existing[0 ..< bodyStart] & blockBytes &
      (if blockBytes.len > 0 and not blockBytes.endsWith("\n"): "\n" else: "") &
      existing[closeIdx .. ^1]
  let separator = if existing.len == 0 or existing.endsWith("\n"): ""
                  else: "\n"
  return existing & separator & openSentinel & "\n" & blockBytes &
    (if blockBytes.len > 0 and not blockBytes.endsWith("\n"): "\n" else: "") &
    closeSentinel & "\n"

proc applyManagedBlock*(planned: PlannedManagedBlock): AppliedManagedBlockRecord =
  let parent = parentDir(planned.hostFilePath)
  if parent.len > 0:
    createDir(extendedPath(parent))
  var existing = ""
  if fileExists(extendedPath(planned.hostFilePath)):
    existing = readFile(extendedPath(planned.hostFilePath))
  result.hostFilePath = planned.hostFilePath
  result.blockId = planned.blockId
  result.preWriteFileDigest = digestBytes(existing)
  let openS = renderSentinel(OpenSentinelPrefix, planned.blockId,
    OpenSentinelSuffix)
  let closeS = renderSentinel(CloseSentinelPrefix, planned.blockId,
    CloseSentinelSuffix)
  let rewritten = spliceBlock(existing, planned.blockBytes, openS, closeS)
  let tmp = planned.hostFilePath & ".repro.tmp"
  writeFile(extendedPath(tmp), rewritten)
  try:
    if fileExists(extendedPath(planned.hostFilePath)):
      removeFile(extendedPath(planned.hostFilePath))
    moveFile(extendedPath(tmp), extendedPath(planned.hostFilePath))
  except OSError as err:
    raiseMaterializeFailed(planned.hostFilePath,
      "managed-block atomic rename failed: " & err.msg)
  result.postWriteBlockBytes = newSeq[byte](planned.blockBytes.len)
  for i, ch in planned.blockBytes:
    result.postWriteBlockBytes[i] = byte(ord(ch))
  result.postWriteFileDigest = digestBytes(rewritten)
