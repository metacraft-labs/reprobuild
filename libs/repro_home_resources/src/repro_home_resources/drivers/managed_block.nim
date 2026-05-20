## `fs.managedBlock` as a typed resource.
##
## Wraps the M59 stdlib's managed-block reader/writer
## (`repro_dsl_stdlib/generated_config/managed_block.nim`) plus the
## M63 apply-pipeline writer
## (`repro_home_apply/materialize_managed_blocks.nim`) as a
## resource that participates in the M68 lifecycle algorithm.
##
## Drift detection: BLAKE3-256 over the bytes BETWEEN the sentinels.
## Surrounding edits (the user's own lines outside the block) do
## NOT count as drift — the spec's "managed block in a partially
## owned file" semantics are preserved.

import std/[os, strutils]

import ./../manifest_record
import ./../types

# Sentinel format matches `repro_home_apply/materialize_managed_blocks`
# (the M63 writer). We re-declare the constants locally to avoid
# pulling `repro_home_apply` into the resources library (the apply
# pipeline will import this driver, so we cannot create a cycle).

const
  ResourceOpenSentinelPrefix* = "# >>> repro-managed:"
  ResourceOpenSentinelSuffix* = " >>>"
  ResourceCloseSentinelPrefix* = "# <<< repro-managed:"
  ResourceCloseSentinelSuffix* = " <<<"

# ---------------------------------------------------------------------------
# Observation.
# ---------------------------------------------------------------------------

proc observeManagedBlock*(hostFile, blockId: string): ObservedState =
  ## Look up the managed block in `hostFile`. The observed bytes
  ## are the content BETWEEN the sentinels — the block id and the
  ## sentinel lines themselves are NOT included so surrounding
  ## edits don't trigger drift.
  if not fileExists(hostFile):
    result.present = false
    result.digest = zeroDigest()
    return
  let content = readFile(hostFile)
  let openS = ResourceOpenSentinelPrefix & blockId & ResourceOpenSentinelSuffix
  let closeS = ResourceCloseSentinelPrefix & blockId & ResourceCloseSentinelSuffix
  let openIdx = content.find(openS)
  let closeIdx = content.find(closeS)
  if openIdx < 0 or closeIdx < 0 or closeIdx <= openIdx:
    result.present = false
    result.digest = zeroDigest()
    return
  let lineEndAfterOpen = content.find('\n', openIdx)
  let bodyStart =
    if lineEndAfterOpen >= 0: lineEndAfterOpen + 1
    else: openIdx + openS.len
  var closeLineStart = closeIdx
  while closeLineStart > 0 and content[closeLineStart - 1] != '\n':
    dec closeLineStart
  let body = content[bodyStart ..< closeLineStart]
  var raw = newSeq[byte](body.len)
  for i, ch in body:
    raw[i] = byte(ord(ch))
  result.present = true
  result.rawBytes = raw
  result.digest = digestOfBytes(raw)

# ---------------------------------------------------------------------------
# Apply (sentinel splice).
# ---------------------------------------------------------------------------

proc spliceManagedBlock*(existing, content, openS, closeS: string): string =
  let openIdx = existing.find(openS)
  let closeIdx = existing.find(closeS)
  if openIdx >= 0 and closeIdx >= 0 and closeIdx > openIdx:
    let lineEndAfterOpen = existing.find('\n', openIdx)
    let bodyStart =
      if lineEndAfterOpen >= 0: lineEndAfterOpen + 1
      else: openIdx + openS.len
    return existing[0 ..< bodyStart] & content &
      (if content.len > 0 and not content.endsWith("\n"): "\n" else: "") &
      existing[closeIdx .. ^1]
  let separator =
    if existing.len == 0 or existing.endsWith("\n"): ""
    else: "\n"
  return existing & separator & openS & "\n" & content &
    (if content.len > 0 and not content.endsWith("\n"): "\n" else: "") &
    closeS & "\n"

proc applyManagedBlockResource*(hostFile, blockId, content: string):
    seq[byte] =
  ## Insert or update the managed block. Returns the bytes between
  ## the sentinels (the recorded payload). The returned bytes are
  ## what's ACTUALLY on disk after the write — on Windows that may
  ## include `\r\n` translation that `writeFile` applies in text
  ## mode, so the recorded digest matches what `observeManagedBlock`
  ## will read back on the next apply.
  let parent = parentDir(hostFile)
  if parent.len > 0:
    createDir(parent)
  var existing = ""
  if fileExists(hostFile):
    existing = readFile(hostFile)
  let openS = ResourceOpenSentinelPrefix & blockId & ResourceOpenSentinelSuffix
  let closeS = ResourceCloseSentinelPrefix & blockId & ResourceCloseSentinelSuffix
  let rewritten = spliceManagedBlock(existing, content, openS, closeS)
  let tmp = hostFile & ".repro.tmp"
  # Binary-mode write: bypass std/syncio.writeFile's CRLF
  # translation on Windows so the bytes on disk equal the bytes
  # we passed in. Drift detection compares bytes via BLAKE3-256;
  # any translation would produce constant false-positive drift
  # on every re-apply.
  block:
    var f: File
    if not open(f, tmp, fmWrite):
      raise newException(IOError, "cannot open " & tmp)
    try:
      if rewritten.len > 0:
        discard f.writeBuffer(unsafeAddr rewritten[0], rewritten.len)
    finally:
      close(f)
  if fileExists(hostFile):
    try: removeFile(hostFile) except OSError: discard
  moveFile(tmp, hostFile)
  # Re-read the just-written block so the recorded payload bytes
  # match exactly what `observeManagedBlock` will see on the next
  # apply's drift check. `spliceManagedBlock` may have inserted a
  # trailing `\n` when the caller's content didn't end with one,
  # so the on-disk body can be 1 byte longer than `content`.
  let post = observeManagedBlock(hostFile, blockId)
  if post.present:
    return post.rawBytes
  result = newSeq[byte](content.len)
  for i, ch in content:
    result[i] = byte(ord(ch))

proc destroyManagedBlockResource*(hostFile, blockId: string) =
  ## Remove the managed-block sentinels and content from the host
  ## file (leaves the surrounding user content intact).
  if not fileExists(hostFile):
    return
  let content = readFile(hostFile)
  let openS = ResourceOpenSentinelPrefix & blockId & ResourceOpenSentinelSuffix
  let closeS = ResourceCloseSentinelPrefix & blockId & ResourceCloseSentinelSuffix
  let openIdx = content.find(openS)
  let closeIdx = content.find(closeS)
  if openIdx < 0 or closeIdx < 0 or closeIdx <= openIdx:
    return
  var openLineStart = openIdx
  while openLineStart > 0 and content[openLineStart - 1] != '\n':
    dec openLineStart
  var closeLineEnd = closeIdx + closeS.len
  if closeLineEnd < content.len and content[closeLineEnd] == '\n':
    inc closeLineEnd
  let rewritten = content[0 ..< openLineStart] & content[closeLineEnd .. ^1]
  let tmp = hostFile & ".repro.tmp"
  writeFile(tmp, rewritten)
  if fileExists(hostFile):
    try: removeFile(hostFile) except OSError: discard
  moveFile(tmp, hostFile)
