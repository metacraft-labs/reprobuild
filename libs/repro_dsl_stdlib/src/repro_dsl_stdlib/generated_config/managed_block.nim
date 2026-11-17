## Sentinel-delimited managed blocks in partial-ownership home files (e.g.
## `~/.bashrc`), addressed by block id alone:
##
##   # >>> repro:home:<blockId> >>>
##   ...managed content...
##   # <<< repro:home:<blockId> <<<
##
## This module is the home-profile entry point onto the ONE managed-file
## writer, `repro_core/managed_block` (Core-Invariants.md §"One
## Implementation Per Concern"). The sentinel format, the locator (which
## refuses a duplicated or unterminated block), the splice and the atomic
## temp + fsync + rename write are that module's; this one only fixes the
## key to the elided home form (Generated-Configuration-Files.md
## §"Sentinel uniqueness") and keeps the API its callers use.
##
## Updates rewrite only the block. Removal deletes the sentinels plus the
## managed content, leaving the rest of the host file intact; a host file
## left empty is deleted (Generated-Configuration-Files.md §"Deletion
## semantics").

import std/os
from repro_core/paths import extendedPath
import repro_core/managed_block as shared

export shared.ManagedBlockError, shared.ManagedBlockOverlap

type
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

proc homeKey(blockId: string): ManagedBlockKey =
  managedBlockKey(HomeBlockScope, "", blockId)

proc openSentinel*(blockId: string): string =
  shared.openSentinel(homeKey(blockId))

proc closeSentinel*(blockId: string): string =
  shared.closeSentinel(homeKey(blockId))

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
  ## Raises `ManagedBlockError` for a duplicated or unterminated block.
  let span = locateManagedBlock(content, homeKey(blockId))
  result.found = span.found
  if span.found:
    result.openLineStart = span.openLineStart
    result.blockStart = span.contentStart
    result.blockEnd = span.contentEnd
    result.closeLineEnd = span.closeLineEnd

# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------

proc updateManagedBlock*(hostFile: string; blockId: string;
                        content: string): ManagedBlockUpdateResult =
  ## Insert or update the managed block in `hostFile` (which need not exist).
  ## Writes the file atomically (temp + fsync + rename) when the bytes
  ## change. Returns the prior + new managed-block payloads so callers can
  ## derive the cache key.
  let key = homeKey(blockId)
  let prior = readManagedFile(hostFile)
  result.priorContent = prior
  let span = locateManagedBlock(prior, key, hostFile)
  result.blockExisted = span.found
  if span.found:
    result.priorBlockBytes = prior.substr(span.contentStart,
      span.contentEnd - 1)
  result.newBlockBytes = content
  result.newContent = spliceManagedBlock(prior, key, content,
    alDirectlyAfter, hostFile)
  result.rewroteFile = updateManagedFile(hostFile, prior, result.newContent)

proc removeManagedBlock*(hostFile: string; blockId: string): bool =
  ## Remove `blockId`'s sentinels and contents. Returns true if the file
  ## was modified. The bytes outside the block are kept exactly as they
  ## are now; the file is deleted only when nothing is left in it
  ## (Generated-Configuration-Files.md §"Deletion semantics").
  if not fileExists(extendedPath(hostFile)): return false
  let prior = readManagedFile(hostFile)
  let newContent = withoutManagedBlock(prior, homeKey(blockId), hostFile)
  if newContent == prior: return false
  if newContent.len == 0:
    removeFile(extendedPath(hostFile))
    return true
  updateManagedFile(hostFile, prior, newContent)
