## The local content-addressed source store (NPC-AREQ20, NPC-AREQ21).
##
## One directory per verified tree, named by its tree digest:
##
##   <store root>/<tree>/            the tree, as extracted and verified
##   <store root>/<tree>.receipt     where it came from (diagnostics only)
##
## An entry is created only by renaming a private staging directory, in
## which the tree was extracted and re-hashed, into place (`installStaged`):
## an entry either holds the verified tree or does not exist. Staging
## directories are created beside the entries with random names and removed,
## links never followed, on every failure.
##
## The store is shared by every project of a user: an entry depends only on
## its digest, so a second project that locks a tree already present fetches
## nothing for it (`test_npc_store_shared_across_projects`).
##
## A receipt is NOT a statement about the bytes: `repro nimble verify`
## re-hashes the tree and compares it with the lock, never with the receipt.

import std/[os, strutils, tempfiles]
when defined(posix):
  # rename(2) itself: Nim's moveDir falls back to copy-and-remove when the
  # rename fails, which would expose a half-copied entry.
  proc cRename(oldPath, newPath: cstring): cint {.importc: "rename",
    header: "<stdio.h>".}

import repro_core/tree_removal

import ./mirror
import ./tree_walk

const ReceiptHeader* = "reprobuild.nimble-source-receipt.v1"

proc defaultStoreRoot*(): string =
  ## The user's source store: under the user cache directory, shared by
  ## every project of the user.
  getCacheDir("reprobuild") / "store" / "nimble-sources"

proc entryPath*(root, tree: string): string =
  if not isTreeHex(tree):
    raise newException(ValueError, "not a tree digest: " & tree.escape())
  root / tree

proc receiptPath*(root, tree: string): string = entryPath(root, tree) & ".receipt"

proc hasEntry*(root, tree: string): bool =
  let p = entryPath(root, tree)
  dirExists(p) and not symlinkExists(p)

proc newStaging*(root: string): string =
  ## A fresh, empty, private staging directory beside the entries.
  createDir(root)
  createTempDir(".stage-", "", root)

proc discardStaging*(staging: string) =
  ## Remove a staging directory without following any link in it.
  if staging.len == 0: return
  if symlinkExists(staging):
    removeFile(staging)
  elif dirExists(staging):
    removeTreeNoFollow(staging)
    if dirExists(staging): removeDir(staging)

proc installStaged*(root, staging, tree: string; receipt: string):
    tuple[installed: bool; detail: string] =
  ## Rename a verified staging tree into place as the entry of ``tree``.
  ## When another process installed the same tree first, the staging tree is
  ## discarded and the existing entry kept (it is checked by its caller).
  let dest = entryPath(root, tree)
  when defined(posix):
    if cRename(staging.cstring, dest.cstring) != 0:
      let err = osLastError()
      discardStaging(staging)
      if hasEntry(root, tree):
        return (false, "already installed")
      return (false, "cannot install " & dest & ": " & osErrorMsg(err))
  else:
    if dirExists(dest):
      discardStaging(staging)
      return (false, "already installed")
    moveDir(staging, dest)
  writeFile(receiptPath(root, tree), receipt)
  (true, "")

proc entryVerified*(root, tree: string): bool =
  ## Whether the entry of ``tree`` exists and re-hashes to ``tree``.
  if not hasEntry(root, tree): return false
  try:
    treeDigestOf(entryPath(root, tree)) == tree
  except CatchableError:
    false
