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
##  3. **Nothing twice.** A prefix the destination already indexes under the
##     same prefix id, with a receipt sealing that id and a tree whose
##     content is the source's, is skipped -- whoever sealed it, so a store
##     that realized the prefix itself is prewarmed, not refused. A repeated
##     copy transfers nothing.
##  4. **Independent bytes.** Files are copied, never hard-linked: a store
##     that shares inodes with its source is not a mirror.
##  5. **Kept alive.** The closure is attached to a destination root
##     `copy:<closure-id>`, or the destination's next GC would reap it. An
##     existing root is never replaced (that would drop its holds), what is
##     already present is held before the first publish, and each published
##     prefix is indexed and held in one transaction.
##
## Neither store may contain the other.
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
      ## Prefixes of the closure holding a symbolic link whose target lies
      ## outside the source store root: the link (pinned import metadata)
      ## is copied, the content it points at is not.
    copiedBytes*: int64

  PlannedPrefix = object
    row: PrefixRow
    sourceDir: string
    receiptBytes: string
    expectedDigest: string          ## `tree-v2:<hex>` the copy must reproduce
    recorded: bool                  ## the digest came from the receipt
    external: bool                  ## a link leaves the source store
    present: bool                   ## the destination already has it

const CopyRootPrefix* = "copy:"

proc fail(msg: string) {.noreturn.} =
  raise newException(StoreCopyError, msg)

proc hexOf(id: PrefixIdBytes): string =
  for b in id:
    result.add(toHex(b.int, 2).toLowerAscii)

proc within(path, root: string): bool =
  ## Lexical containment of two absolute, normalized paths.
  path == root or path.startsWith(root & DirSep)

proc canonicalPath(path: string): string =
  ## `path` with symlinks resolved as far as it exists: the deepest existing
  ## ancestor is resolved and the rest re-appended, so a destination that
  ## does not exist yet still compares by where it WILL be.
  var head = normalizedPath(absolutePath(path))
  var tail: seq[string]
  while not (dirExists(head) or fileExists(head)):
    let parent = head.parentDir
    if parent == head or parent.len == 0: break
    tail.insert(head.extractFilename, 0)
    head = parent
  result = try: expandFilename(head) except OSError: head
  for part in tail: result = result / part

proc linksLeave*(prefixDir, storeRoot: string): bool =
  ## Whether a symbolic link in `prefixDir` names a target outside
  ## `storeRoot` (resolved lexically against the link's own directory).
  ## Such a prefix holds pinned import metadata for content the copy cannot
  ## carry: an external imported node.
  let root = normalizedPath(storeRoot)
  for rel in walkDirRec(prefixDir, yieldFilter = {pcLinkToFile, pcLinkToDir},
      relative = true, followFilter = {pcDir}):
    let link = prefixDir / rel
    var target = expandSymlink(link)
    if not target.isAbsolute: target = link.parentDir / target
    if not normalizedPath(target).within(root):
      return true
  false

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
  result.external = linksLeave(result.sourceDir, s.root)

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

proc destinationHolds(d: Store; plan: PlannedPrefix): bool =
  ## Whether the destination's directory for `plan` is that prefix: its
  ## receipt seals the same prefix id and its tree has the source's content.
  ##
  ## The receipt DIGEST is deliberately not compared. A store that realized
  ## the same prefix itself (a prewarmed worker) holds a receipt that differs
  ## only in when and by whom it was sealed; the prefix id is the identity
  ## and the content is what has to agree with it. The content is checked in
  ## every case, so a damaged destination copy is never taken for a present
  ## one. Raises `StoreCopyError` when the directory is something else.
  let where = plan.row.realizedPath
  let dir = d.absolutePrefixPath(where)
  if not dirExists(dir):
    return false
  var receipt: RealizationReceipt
  try: receipt = readReceiptFile(dir / ReceiptFileName)
  except CatchableError as e:
    fail("destination prefix receipt is unreadable (" & e.msg & "): " & where)
  if receipt.realizationHash != plan.row.prefixId:
    fail("destination receipt at " & where & " seals a different prefix id")
  let got = storeTreeDigest(dir)
  if got != plan.expectedDigest:
    fail("destination already holds prefix id " & hexOf(plan.row.prefixId) &
      " with different content (" & got & ", source " & plan.expectedDigest &
      "): " & where)
  true

proc checkDestination(d: Store; plan: var PlannedPrefix) =
  ## Rule 1, the destination half, and rule 3.
  let where = plan.row.realizedPath
  let dir = d.absolutePrefixPath(where)
  let hit = d.lookupPrefix(plan.row.prefixId)
  if hit.found:
    if hit.row.realizedPath != where:
      fail("destination indexes prefix id " & hexOf(plan.row.prefixId) &
        " at " & hit.row.realizedPath & ", not " & where)
    if not d.destinationHolds(plan):
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

proc indexAndHold(d: var Store; row: PrefixRow; rootId: string) =
  ## The index row and the root's hold in ONE transaction, so no GC can
  ## observe the prefix indexed but unheld.
  d.db.exec("BEGIN IMMEDIATE")
  var committed = false
  try:
    discard d.insertPrefixOrIgnore(row)
    d.attachPrefixToRoot(rootId, row.prefixId)
    d.db.exec("COMMIT")
    committed = true
  finally:
    if not committed:
      try: d.db.exec("ROLLBACK") except CatchableError: discard

proc publish(d: var Store; plan: PlannedPrefix; rootId: string;
             bytes: var int64): bool =
  ## Rule 2: stage, re-verify, rename, index — the realization protocol,
  ## with the source's receipt and row in place of fresh ones. Returns false
  ## when another writer published the same prefix first and it verifies:
  ## like realization's lost race, that is the prefix being present.
  let where = plan.row.realizedPath
  let stage = d.allocateStagingDir() / "prefix"
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
    var won = not (dirExists(target) or symlinkExists(target))
    if won:
      try: moveDir(stage, target)
      except OSError:
        if not dirExists(target): raise
        won = false
    if not won:
      # Lost the race. Accept the winner only if it is this prefix; it is
      # indexed (or about to be) by its own writer, and held here.
      if not d.destinationHolds(plan):
        fail("destination gained an entry at " & where & " during the copy")
      if not d.lookupPrefix(plan.row.prefixId).found:
        fail("destination gained an unindexed entry at " & where &
          " during the copy; run `repro store recover` on " & d.root)
      d.attachPrefixToRoot(rootId, plan.row.prefixId)
      return false
    d.indexAndHold(plan.row, rootId)
    bytes += staged
    true
  finally:
    makeWritable(stage.parentDir)
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
  # Neither store may contain the other: a destination inside the source
  # would be written into a source prefix (changing its content) or into the
  # source's `tmp/` (which its recovery sweeps), and a source inside the
  # destination would be copied into itself.
  let srcCanon = canonicalPath(req.sourceRoot)
  let dstCanon = canonicalPath(destRoot)
  if dstCanon.within(srcCanon) or srcCanon.within(dstCanon):
    fail(if dstCanon == srcCanon: "the destination is the source store " &
           "itself: " & destRoot
         else: "the destination and source stores must not contain each " &
           "other: " & destRoot & " and " & req.sourceRoot)
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
    if plan.external:
      result.external.add(plan.row.realizedPath)
  result.rootId = closureRootId(ids)

  # Rule 5. The root is registered only when it is absent: re-registering
  # replaces the row, and the cascade would drop the holds an earlier copy
  # left. Everything already present is held BEFORE the first publish, so a
  # copy that fails part-way leaves every prefix it found or wrote held.
  var rootKnown = false
  for r in dst.listRoots():
    if r.rootId == result.rootId: rootKnown = true
  if not rootKnown:
    dst.registerRoot(result.rootId, rkWorkspace)
  for plan in plans:
    if plan.present:
      dst.attachPrefixToRoot(result.rootId, plan.row.prefixId)
      result.alreadyPresent.add(plan.row.realizedPath)
  for plan in plans:
    if plan.present:
      continue
    if publish(dst, plan, result.rootId, result.copiedBytes):
      result.copied.add(plan.row.realizedPath)
      if not plan.recorded:
        result.unverified.add(plan.row.realizedPath)
    else:
      result.alreadyPresent.add(plan.row.realizedPath)
