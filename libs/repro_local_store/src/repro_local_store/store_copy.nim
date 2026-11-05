## Copy a realized closure from one local store root into another
## (`repro store copy ... --to=STORE-ROOT`).
##
## A bundle (`store_bundle`) moves a workspace's store prefixes together with
## its action-cache records and project state, and only works at the absolute
## paths it was produced at. This module moves store prefixes only, straight
## from one store root into another one that may live anywhere, with no
## intermediate archive.
##
## The rules it keeps, in order:
##
##  1. **The whole closure or nothing.** Every prefix of the closure is
##     verified in the source (receipt, index row, directory name, content
##     digest) and checked for conflicts in the destination BEFORE the first
##     byte is written. A closure with one missing or altered file is refused,
##     never copied in part.
##  2. **Exact identity.** The sealed `.repro-receipt` is copied byte for
##     byte and never re-sealed, the prefix lands at the same store-relative
##     path, and the source's index row is inserted unchanged. The staged tree
##     is digested again before it is published, so the transfer itself is
##     checked, not assumed.
##  3. **Nothing twice.** A prefix the destination already indexes with the
##     same receipt digest is skipped, so a repeated copy transfers nothing.
##  4. **Independent bytes.** Files are copied, never hard-linked: a store
##     that shares inodes with its source is not a mirror.
##  5. **Kept alive.** The closure is attached to a destination root
##     `copy:<closure-id>`, or the destination's next GC would reap it.
##
## POSIX only, like the bundle commands: the copy recreates symbolic links
## and permission bits with POSIX semantics.

import std/[algorithm, os, sets, strutils, tables]
import blake3
import ./store
import ./prefix_paths
import ./sqlite3_binding

type
  StoreCopyError* = object of CatchableError
    ## Raised for every refusal. The message names the prefix (or argument)
    ## and the reason, so an operator can act on it.

  StoreCopyRequest* = object
    sourceRoot*: string
    destinationRoot*: string
    prefixes*: seq[string]
      ## Absolute paths, or store-relative paths (`prefixes/<pkg>/<dir>`).
      ## A path inside a prefix names the prefix that owns it.
    rootIds*: seq[string]
      ## Registered roots of the source store; each selects what it holds.

  StoreCopyReport* = object
    sourceRoot*: string
    destinationRoot*: string
    rootId*: string                 ## the destination root holding the closure
    closure*: seq[string]           ## store-relative paths, sorted
    copied*: seq[string]
    alreadyPresent*: seq[string]
    unverified*: seq[string]
      ## Copied prefixes whose receipt records no content digest: the
      ## transfer was checked against the source tree, but nothing vouches
      ## for the source tree itself.
    external*: seq[string]
      ## Prefixes of the closure whose adapter imports content from outside
      ## the store (`nix`, `adopted:*`): their receipt and links are what
      ## the destination holds, the external payload is not copied.
    copiedBytes*: int64

  PlannedPrefix = object
    row: PrefixRow
    sourceDir: string
    receiptBytes: string
    expectedDigest: string          ## `tree-v2:<hex>` the copy must reproduce
    recorded: bool                  ## the digest came from the receipt
    present: bool                   ## the destination already has it

const CopyRootPrefix* = "copy:"

proc fail(msg: string) {.noreturn.} =
  raise newException(StoreCopyError, msg)

proc hexOf(id: PrefixIdBytes): string =
  for b in id:
    result.add(toHex(b.int, 2).toLowerAscii)

proc isExternalAdapter*(adapter: string): bool =
  ## Adapters whose prefix holds pinned import metadata for content that
  ## lives outside the store, rather than the content itself.
  adapter == $anNix or adapter.startsWith(AdoptedAdapterPrefix)

proc closureRootId*(prefixIds: openArray[PrefixIdBytes]): string =
  ## `copy:` and the first 32 hex digits of BLAKE3 over the sorted prefix
  ## ids, so the same closure always lands in the same destination root.
  var hexes: seq[string]
  for id in prefixIds: hexes.add(hexOf(id))
  hexes.sort()
  CopyRootPrefix & blake3.digest(hexes.join("\n")).toHex().toLowerAscii()[0 ..< 32]

proc resolvePrefixArg(s: Store; arg: string): PrefixRow =
  let candidate =
    if arg.isAbsolute: arg
    elif arg.startsWith("prefixes/") or arg.startsWith("prefixes" & DirSep):
      s.root / arg
    else: absolutePath(arg)
  let hit = s.prefixOwningPath(candidate)
  if not hit.found:
    fail("not a prefix of the source store " & s.root & ": " & arg)
  hit.row

proc verifySource(s: Store; row: PrefixRow): PlannedPrefix =
  ## Rule 1, the source half: the prefix is what its receipt and its index
  ## row say it is.
  result.row = row
  result.sourceDir = s.absolutePrefixPath(row.realizedPath)
  let where = row.realizedPath
  if not dirExists(result.sourceDir):
    fail("source prefix directory is missing: " & where)
  let receiptPath = result.sourceDir / ReceiptFileName
  if not fileExists(receiptPath):
    fail("source prefix has no " & ReceiptFileName & ": " & where)
  var receipt: RealizationReceipt
  try:
    result.receiptBytes = readFile(receiptPath)
    receipt = readReceiptFile(receiptPath)
  except CatchableError as e:
    fail("source prefix receipt is unreadable (" & e.msg & "): " & where)
  if receipt.realizationHash != row.prefixId:
    fail("source receipt realization hash does not match the index row: " &
      where)
  if receiptDigest(receipt) != row.receiptDigest:
    fail("source receipt digest does not match the index row: " & where)
  let adoptedHere = receipt.adapter.startsWith(AdoptedAdapterPrefix) and
    receipt.realizedPath == row.realizedPath
  if result.sourceDir.extractFilename !=
      realizationDirName(receipt.version, receipt.realizationHash) and
      not adoptedHere:
    fail("source prefix directory name does not match its receipt: " & where)
  let actual = storeTreeDigest(result.sourceDir)
  if receipt.contentDigest.len > 0:
    if actual != receipt.contentDigest:
      fail("source prefix content does not match its receipt (" &
        receipt.contentDigest & " recorded, " & actual & " on disk): " & where)
    result.recorded = true
  result.expectedDigest = actual

proc closureOf(s: Store; req: StoreCopyRequest): seq[PrefixRow] =
  ## The selected prefixes plus, transitively, the sibling outputs a
  ## multi-output receipt names. The index records no other edge between
  ## prefixes.
  var pending: seq[PrefixRow]
  for arg in req.prefixes:
    pending.add(s.resolvePrefixArg(arg))
  if req.rootIds.len > 0:
    var known = initHashSet[string]()
    for r in s.listRoots(): known.incl(r.rootId)
    for id in req.rootIds:
      if id notin known:
        fail("no such root in the source store " & s.root & ": " & id)
      for prefixId in s.prefixesHeldByRoot(id):
        let hit = s.lookupPrefix(prefixId)
        if not hit.found:
          fail("root " & id & " holds a prefix the index does not know: " &
            hexOf(prefixId))
        pending.add(hit.row)
  var seen = initHashSet[string]()
  while pending.len > 0:
    let row = pending.pop()
    if row.realizedPath in seen:
      continue
    seen.incl(row.realizedPath)
    result.add(row)
    let receiptPath = s.absolutePrefixPath(row.realizedPath) / ReceiptFileName
    if not fileExists(receiptPath):
      continue   # verifySource reports it
    var receipt: RealizationReceipt
    try: receipt = readReceiptFile(receiptPath)
    except CatchableError: continue   # verifySource reports it
    for name, sibling in receipt.outputPrefixes:
      let hit = s.lookupPrefixByRealizedPath(sibling)
      if not hit.found:
        fail("multi-output receipt of " & row.realizedPath & " names output " &
          name & " at " & sibling & ", which the source index does not know")
      pending.add(hit.row)
  result.sort(proc (a, b: PrefixRow): int = cmp(a.realizedPath, b.realizedPath))

proc checkDestination(d: Store; plan: var PlannedPrefix) =
  ## Rule 1, the destination half, and rule 3.
  let where = plan.row.realizedPath
  let dir = d.absolutePrefixPath(where)
  let hit = d.lookupPrefix(plan.row.prefixId)
  if hit.found:
    if hit.row.receiptDigest != plan.row.receiptDigest:
      fail("destination already holds prefix id " & hexOf(plan.row.prefixId) &
        " with a different receipt: " & where)
    if hit.row.realizedPath != where:
      fail("destination indexes prefix id " & hexOf(plan.row.prefixId) &
        " at " & hit.row.realizedPath & ", not " & where)
    if not dirExists(dir):
      fail("destination indexes " & where & " but its directory is " &
        "missing; run `repro store recover` on " & d.root)
    plan.present = true
  elif dirExists(dir) or fileExists(dir) or symlinkExists(dir):
    fail("destination has an unindexed entry at " & where &
      "; run `repro store recover` on " & d.root)

proc copyTreeExact(src, dst: string; bytes: var int64) =
  ## Rule 4: an independent copy that keeps what the tree digest covers —
  ## every directory, every file's bytes and permission bits, every symbolic
  ## link's target text. Directory permissions are applied last, so a
  ## read-only source directory does not stop its own children being
  ## written.
  createDir(dst)
  var dirModes: seq[(string, set[FilePermission])]
  dirModes.add((dst, getFilePermissions(src)))
  for rel in walkDirRec(src, yieldFilter = {pcFile, pcLinkToFile, pcDir,
      pcLinkToDir}, relative = true, followFilter = {pcDir}):
    let s = src / rel
    let t = dst / rel
    let info = getFileInfo(s, followSymlink = false)
    case info.kind
    of pcDir:
      createDir(t)
      dirModes.add((t, getFilePermissions(s)))
    of pcLinkToFile, pcLinkToDir:
      createSymlink(expandSymlink(s), t)
    of pcFile:
      copyFile(s, t)
      setFilePermissions(t, getFilePermissions(s), followSymlinks = false)
      bytes += info.size
  for i in countdown(dirModes.high, 0):
    setFilePermissions(dirModes[i][0], dirModes[i][1])

proc makeWritable(dir: string) =
  ## A staged tree that failed verification is removed; a read-only
  ## directory in it would stop that.
  if not dirExists(dir): return
  for rel in walkDirRec(dir, yieldFilter = {pcDir}, relative = true):
    try: setFilePermissions(dir / rel, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
  try: setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  except OSError: discard

proc publish(d: var Store; plan: PlannedPrefix; bytes: var int64) =
  ## Rule 2: stage, re-verify, rename, index — the realization protocol,
  ## with the source's receipt and row in place of fresh ones.
  let where = plan.row.realizedPath
  let stage = d.allocateStagingDir() / "prefix"
  var published = false
  try:
    var staged = 0'i64
    copyTreeExact(plan.sourceDir, stage, staged)
    let got = storeTreeDigest(stage)
    if got != plan.expectedDigest:
      fail("copied tree does not match the source (" & plan.expectedDigest &
        " expected, " & got & " copied): " & where)
    if readFile(stage / ReceiptFileName) != plan.receiptBytes:
      fail("copied receipt differs from the source receipt: " & where)
    let target = d.absolutePrefixPath(where)
    createDir(target.parentDir)
    if dirExists(target) or symlinkExists(target):
      fail("destination gained an entry at " & where & " during the copy")
    moveDir(stage, target)
    published = true
    d.db.exec("BEGIN IMMEDIATE")
    var committed = false
    try:
      discard d.insertPrefixOrIgnore(plan.row)
      d.db.exec("COMMIT")
      committed = true
    finally:
      if not committed:
        try: d.db.exec("ROLLBACK") except CatchableError: discard
    bytes += staged
  finally:
    if not published:
      makeWritable(stage.parentDir)
      try: removeDir(stage.parentDir) except OSError: discard
    else:
      try: removeDir(stage.parentDir) except OSError: discard

proc copyClosure*(req: StoreCopyRequest): StoreCopyReport =
  ## Copy the closure `req` selects from `req.sourceRoot` into
  ## `req.destinationRoot`. Raises `StoreCopyError` (or `StoreError` /
  ## `OSError` from the store) on refusal; see the module comment for what
  ## is checked before the first write.
  if req.prefixes.len == 0 and req.rootIds.len == 0:
    fail("nothing to copy: name at least one prefix or --root-id")
  if req.destinationRoot.len == 0:
    fail("no destination store root")
  if not dirExists(req.sourceRoot / "prefixes") or
      not fileExists(req.sourceRoot / "index.db"):
    fail("source is not a store root (no prefixes/ and index.db): " &
      req.sourceRoot)
  let destRoot = absolutePath(req.destinationRoot)
  if dirExists(destRoot) and sameFile(destRoot, req.sourceRoot):
    fail("the destination is the source store itself: " & destRoot)
  result.sourceRoot = req.sourceRoot
  result.destinationRoot = destRoot

  var plans: seq[PlannedPrefix]
  block:
    var src = openStore(req.sourceRoot)
    defer: src.close()
    for row in closureOf(src, req):
      plans.add(verifySource(src, row))

  var dst = openStore(destRoot)
  defer: dst.close()
  for plan in plans.mitems:
    checkDestination(dst, plan)

  var ids: seq[PrefixIdBytes]
  for plan in plans:
    ids.add(plan.row.prefixId)
    result.closure.add(plan.row.realizedPath)
  result.rootId = closureRootId(ids)

  # The root is registered before the first publish, so a copy that fails
  # part-way leaves what it did publish held rather than reapable.
  dst.registerRoot(result.rootId, rkWorkspace)
  for plan in plans:
    if isExternalAdapter(plan.row.adapter):
      result.external.add(plan.row.realizedPath)
    if plan.present:
      result.alreadyPresent.add(plan.row.realizedPath)
    else:
      publish(dst, plan, result.copiedBytes)
      result.copied.add(plan.row.realizedPath)
      if not plan.recorded:
        result.unverified.add(plan.row.realizedPath)
    dst.attachPrefixToRoot(result.rootId, plan.row.prefixId)
