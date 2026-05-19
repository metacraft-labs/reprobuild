## Sentinel-delimited managed-block reader/writer for partial-ownership
## files (e.g. `~/.bashrc`).
##
## Sentinel format (matches the example in Generated-Configuration-Files.md):
##
##   # >>> repro:home:<blockId> >>>
##   ...managed content...
##   # <<< repro:home:<blockId> <<<
##
## Updates rewrite only the bytes between the sentinels (exclusive on
## both ends). Removal deletes the sentinels plus the managed content,
## leaving the rest of the host file intact.

import std/[os, strutils]

type
  ManagedBlockError* = object of CatchableError
  ManagedBlockOverlap* = object of ManagedBlockError
    ## Two blocks with the same `blockId` collide, or the closing sentinel
    ## appears before its opening sentinel.

  ManagedBlockUpdateResult* = object
    rewroteFile*: bool
    newContent*: string
    priorContent*: string
    blockExisted*: bool
    priorBlockBytes*: string
    newBlockBytes*: string

const
  SentinelOpenPrefix* = "# >>> repro:home:"
  SentinelOpenSuffix* = " >>>"
  SentinelCloseLeader* = "# <<< repro:home:"
  SentinelCloseSuffix* = " <<<"

proc openSentinel*(blockId: string): string =
  SentinelOpenPrefix & blockId & SentinelOpenSuffix

proc closeSentinel*(blockId: string): string =
  SentinelCloseLeader & blockId & SentinelCloseSuffix

# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------

type
  BlockRange* = object
    found*: bool
    openLineStart*: int    ## byte offset of the opening sentinel line
    blockStart*: int       ## byte offset of the first byte of the block
    blockEnd*: int         ## byte offset just past the last byte of the block
    closeLineEnd*: int     ## byte offset just past the closing sentinel's newline

proc locateBlock*(content, blockId: string): BlockRange =
  ## Locate a managed block inside `content` by id. The returned offsets
  ## bound:
  ##   - the opening-sentinel line (`openLineStart` .. `blockStart - 1`)
  ##   - the block content (`blockStart` .. `blockEnd - 1`) — exclusive
  ##   - the closing-sentinel line (`blockEnd` .. `closeLineEnd - 1`)
  let openText = openSentinel(blockId)
  let closeText = closeSentinel(blockId)
  result.found = false
  let openIdx = content.find(openText)
  if openIdx < 0:
    return
  # Walk back to the start of the opening line.
  var lineStart = openIdx
  while lineStart > 0 and content[lineStart - 1] != '\n':
    dec lineStart
  # The block starts AFTER the newline that ends the opening-sentinel line.
  var afterOpen = openIdx + openText.len
  if afterOpen < content.len and content[afterOpen] == '\r': inc afterOpen
  if afterOpen < content.len and content[afterOpen] == '\n':
    inc afterOpen
  else:
    raise newException(ManagedBlockError,
      "managed-block opening sentinel for '" & blockId &
      "' is not terminated by a newline")
  let closeIdx = content.find(closeText, start = afterOpen)
  if closeIdx < 0:
    raise newException(ManagedBlockError,
      "managed-block '" & blockId & "' has an opening sentinel without " &
      "a matching closing sentinel")
  var closeLineStart = closeIdx
  while closeLineStart > 0 and content[closeLineStart - 1] != '\n':
    dec closeLineStart
  if closeLineStart < afterOpen:
    raise newException(ManagedBlockOverlap,
      "managed-block '" & blockId & "' closing sentinel overlaps its opening")
  var afterClose = closeIdx + closeText.len
  if afterClose < content.len and content[afterClose] == '\r': inc afterClose
  if afterClose < content.len and content[afterClose] == '\n':
    inc afterClose
  result.found = true
  result.openLineStart = lineStart
  result.blockStart = afterOpen
  result.blockEnd = closeLineStart
  result.closeLineEnd = afterClose

# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------

proc renderBlock(blockId, content: string): string =
  result = openSentinel(blockId) & "\n"
  result.add(content)
  if not content.endsWith("\n"):
    result.add('\n')
  result.add(closeSentinel(blockId) & "\n")

proc updateManagedBlock*(hostFile: string; blockId: string;
                        content: string): ManagedBlockUpdateResult =
  ## Insert or update the managed block in `hostFile` (which need not exist).
  ## Writes the file atomically (write-temp + rename) when the bytes change.
  ## Returns the prior + new managed-block payloads so callers can derive
  ## the cache key.
  var prior =
    if fileExists(hostFile): readFile(hostFile)
    else: ""
  result.priorContent = prior
  let blockText = renderBlock(blockId, content)
  let range = locateBlock(prior, blockId)
  var newContent: string
  if range.found:
    result.blockExisted = true
    result.priorBlockBytes = prior.substr(range.blockStart,
      range.blockEnd - 1)
    newContent = prior.substr(0, range.openLineStart - 1) & blockText &
      prior.substr(range.closeLineEnd, prior.len - 1)
  else:
    result.blockExisted = false
    result.priorBlockBytes = ""
    var prefix = prior
    if prefix.len > 0 and not prefix.endsWith("\n"):
      prefix.add('\n')
    newContent = prefix & blockText
  result.newBlockBytes = content
  result.newContent = newContent
  if newContent != prior:
    createDir(parentDir(hostFile))
    let tmpPath = hostFile & ".reprotmp." & $getCurrentProcessId()
    writeFile(tmpPath, newContent)
    if fileExists(hostFile):
      removeFile(hostFile)
    moveFile(tmpPath, hostFile)
    result.rewroteFile = true
  else:
    result.rewroteFile = false

proc removeManagedBlock*(hostFile: string; blockId: string): bool =
  ## Remove `blockId`'s sentinels and contents. Returns true if the file
  ## was modified.
  if not fileExists(hostFile): return false
  let prior = readFile(hostFile)
  let range = locateBlock(prior, blockId)
  if not range.found: return false
  let newContent = prior.substr(0, range.openLineStart - 1) &
    prior.substr(range.closeLineEnd, prior.len - 1)
  if newContent == prior: return false
  let tmpPath = hostFile & ".reprotmp." & $getCurrentProcessId()
  writeFile(tmpPath, newContent)
  if fileExists(hostFile):
    removeFile(hostFile)
  moveFile(tmpPath, hostFile)
  return true
