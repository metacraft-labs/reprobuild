## Ownership: from an installed file to the package, prefix, recipe and
## generations that account for it (ReproOS-Agent-Harbor-Integration M3
## deliverable 1; spec `ReproOS-Agent-Integration-Protocol.md`
## §"Ownership record").
##
## The chain uses only records Reprobuild already writes:
##
## 1. the store index maps the file to its realized prefix
##    (`prefixOwningPath`), and the prefix's sealed receipt names the
##    package, version, adapter and lock identity;
## 2. an install-mirror publish writes, beside the recipe that produced
##    it, a `.realization-info` sidecar naming the realization hash. The
##    recipe that owns a prefix is the one whose sidecar names that prefix's
##    hash. The sidecar is overwritten by every later build of the recipe,
##    so a prefix whose recipe has since been rebuilt resolves to NO recipe
##    and is refused, never to the recipe's newer output;
## 3. store roots name the home generations that hold the prefix.
##
## What this cannot yet say, and reports as such instead of guessing: the
## exact upstream source revision and the package interface fingerprint
## (the receipt carries neither; Campaign Completion M13 deliverable 3 is
## the owner of source identity), and which *system* generations use the
## prefix (system generation manifests record package names, not prefix
## ids).

import std/[algorithm, os, strutils]

import blake3
import repro_core/link_target
import repro_local_store
import repro_project_dsl/install_mirror_resolver

type
  OwnershipError* = object of CatchableError
    reason*: string
      ## `not-installed`, `not-from-source`, `no-recipe`, `ambiguous-recipe`.

  OwnershipRecord* = object
    path*: string            ## the file asked about, as given
    package*: string
    version*: string
    adapter*: string
    lockIdentity*: string
    prefixId*: string        ## hex realization hash
    prefixPath*: string      ## absolute
    receiptDigest*: string   ## hex
    catalogRoot*: string     ## the recipes root the recipe was found in
    recipeName*: string      ## the recipe directory's name in that root
    recipeDir*: string       ## absolute
    recipeTreeDigest*: string
      ## BLAKE3 of the recipe directory as found (every file but `.repro/`
      ## and `build/`), so a checkout can prove it copied what was found.
    homeGenerations*: seq[string]
      ## Store roots of kind profile that hold the prefix.
    pending*: seq[string]
      ## The ownership facts this record does not establish, by name.

const
  ExcludedRecipeDirs* = [".repro", "build"]
    ## Build state, not definition. Everything else in a recipe directory —
    ## `repro.nim`, local sources, vendored archives, patch files — is.
  PendingFacts* = [
    "source-revision: the receipt binds the output tree, not the upstream " &
      "revision (Campaign Completion M13 deliverable 3)",
    "interface-fingerprint: computing it needs a provider compile of the " &
      "recipe",
    "system-generations: system generation manifests record package " &
      "names, not prefix ids"]

proc fail(reason, detail: string) {.noreturn.} =
  var e = newException(OwnershipError, reason & ": " & detail)
  e.reason = reason
  raise e

proc hexOf(d: openArray[byte]): string =
  const h = "0123456789abcdef"
  for x in d:
    result.add h[int(x shr 4)]
    result.add h[int(x and 0xf)]

proc isExcluded(rel: string): bool =
  let first = rel.split('/')[0]
  first in ExcludedRecipeDirs

proc recipeFiles*(dir: string): seq[string] =
  ## The recipe-relative, `/`-separated paths of a recipe's definition
  ## files, sorted. Symlinks are listed as files (their target text is
  ## what the tree digest binds), never followed.
  for rel in walkDirRec(dir, yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir},
                        followFilter = {pcDir}, relative = true):
    let r = rel.replace('\\', '/')
    if not isExcluded(r):
      result.add r
  result.sort()

proc recipeTreeDigest*(dir: string): string =
  ## BLAKE3 over `reproos.agent.recipe-tree.v1`, then for each definition
  ## file its path, kind and contents digest. A symlink contributes its
  ## target string, so the digest never depends on what lies outside.
  var manifest = "reproos.agent.recipe-tree.v1\n"
  for rel in recipeFiles(dir):
    let p = dir / rel
    if symlinkExists(p):
      manifest.add rel & "\tlink\t" & readSymlinkTarget(p) & "\n"
    else:
      let exec = fpUserExec in getFilePermissions(p)
      manifest.add rel & "\t" & (if exec: "exec" else: "file") & "\t" &
        hexOf(blake3.digest(readFile(p))) & "\n"
  hexOf(blake3.digest(manifest))

proc findRecipe(catalogRoots: seq[string]; prefixHex: string):
    tuple[root, name: string] =
  var hits: seq[tuple[root, name: string]]
  for root in catalogRoots:
    if not dirExists(root):
      continue
    for kind, dir in walkDir(root):
      if kind notin {pcDir, pcLinkToDir}:
        continue
      let name = dir.extractFilename
      let info = readRealizationInfoFile(root, name)
      if info.realizationHashHex == prefixHex:
        hits.add (root, name)
  if hits.len == 0:
    fail("no-recipe", "no recipe in the catalog roots names prefix " &
      prefixHex & " as its current output")
  if hits.len > 1:
    var names: seq[string]
    for h in hits:
      names.add h.root / h.name
    fail("ambiguous-recipe", "several recipes name prefix " & prefixHex &
      ": " & names.join(", "))
  hits[0]

proc resolveOwnership*(storeRoot: string; catalogRoots: seq[string];
                       path: string): OwnershipRecord =
  ## The ownership record of `path`. Refuses, with `OwnershipError.reason`,
  ## a path no prefix owns, a prefix not produced from a recipe, and a
  ## prefix no single recipe names as its current output.
  var store = openStore(storeRoot)
  defer: store.close()
  let owner = store.prefixOwningPath(path)
  if not owner.found:
    fail("not-installed", path & " is not inside a realized prefix")
  let row = owner.row
  let prefixPath = store.absolutePrefixPath(row.realizedPath)
  let receipt = readReceiptFile(prefixPath / ReceiptFileName)
  if receipt.adapter != "install-mirror":
    fail("not-from-source", row.packageName & " was realized by the " &
      receipt.adapter & " adapter; only from-source packages have a " &
      "recipe to modify")
  let prefixHex = prefixIdHex(row.prefixId)
  let (root, name) = findRecipe(catalogRoots, prefixHex)
  result = OwnershipRecord(path: path, package: receipt.packageName,
    version: receipt.version, adapter: receipt.adapter,
    lockIdentity: receipt.lockIdentity, prefixId: prefixHex,
    prefixPath: prefixPath, receiptDigest: hexOf(row.receiptDigest),
    catalogRoot: root, recipeName: name, recipeDir: root / name,
    recipeTreeDigest: recipeTreeDigest(root / name), pending: @PendingFacts)
  for r in store.rootsHolding(row.prefixId):
    result.homeGenerations.add r
