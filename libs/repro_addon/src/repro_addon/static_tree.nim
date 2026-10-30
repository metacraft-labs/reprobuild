## The generation's static tree and the switch's recoverable state.
##
## Each add-on generation materialises its link-form objects as one store
## object, a tree mirroring the managed ``/etc`` paths
## (``<tree>/systemd/system/foo.service`` for ``/etc/systemd/system/
## foo.service``). ``/etc/repro/static`` is a symlink to the current
## generation's tree, and every link-form object on the host is a link
## ``/etc/X -> /etc/repro/static/X``; so replacing the one link
## ``/etc/repro/static`` is the switch for all of them at once, in one
## ``rename(2)`` (ReproOS Add-On Mode §7.2 step 3). The tree is
## content-addressed: two generations with the same link-form objects
## share it, and a flip to the same tree is a no-op.
##
## The **pending marker** is the switch's crash record (§7.2: "written
## before step 2 and removed at step 9"). It names the generation being
## left, the tree being switched to and the one being left, the step the
## switch reached, and the units step 2 stopped, so the re-assert unit
## (milestone A5) can finish or undo an interrupted switch from it. It is
## rewritten atomically at every step boundary; a host that reboots
## mid-switch finds exactly the last step completed.

import std/[algorithm, os, posix, strutils]

import repro_core
import repro_local_store/store

import ./etc_write
import ./fingerprint
import ./generation0
import ./store_root

type
  StaticTreeError* = object of CatchableError

  StaticFile* = object
    ## One link-form object of a generation: its ``/etc`` path and bytes.
    path*: string          ## absolute, below /etc
    content*: string

  SwitchStep* = enum
    ## The nine steps of the switch (spec §7.2), in order. The pending
    ## marker records the last one COMPLETED.
    ssNone = "0-none"
    ssRealise = "1-realise"
    ssPreStop = "2-pre-stop"
    ssFlip = "3-flip"
    ssReconcileLinks = "4-reconcile-links"
    ssCopies = "5-copies"
    ssFragmentTools = "6-fragment-tools"
    ssStart = "7-start"
    ssConfirm = "8-confirm"
    ssCommit = "9-commit"

  PendingMarker* = object
    fromGeneration*: string   ## `current` when the switch began
    planId*: string           ## the infra plan being applied
    newStatic*: string        ## the tree being switched to
    previousStatic*: string   ## the tree `/etc/repro/static` pointed at
    step*: SwitchStep         ## the last step completed
    status*: string           ## in-progress | failed
    stopped*: seq[string]     ## units step 2 stopped (and may need restarting
                              ## by a recovery that undoes the switch).
                              ## Each is recorded BEFORE it is stopped, so a
                              ## crash or a refusal in the middle of step 2
                              ## never leaves a stopped unit unrecorded.
    disabled*: seq[string]    ## units step 2 disabled, recorded the same way
    detail*: string           ## why it failed, when it did
    attempt*: string          ## the generation id the infra apply allocated
                              ## for this switch (known from step 4 on); the
                              ## switch committed iff `current` names it
    purpose*: string          ## apply | revert | rollback | replay: what
                              ## started this switch
    revertOf*: string         ## a revert: the failed attempt's generation id
                              ## ("" when it failed before it had one)
    revertReason*: string     ## a revert: why the attempt failed

const
  StaticLinkPath* = "/etc/repro/static"
  StaticTreePackage* = "repro-addon-etc"
  PendingMarkerHeader* = "# repro-addon-pending v1"
  PendingRootId* = "addon-pending"
    ## The store root that holds the tree being switched to until the
    ## generation that owns it is committed and registered.

proc staticRelPath*(etcPath: string): string =
  ## ``/etc/X`` -> ``X``: the path's location in the tree.
  if not etcPath.startsWith("/etc/") or etcPath.len <= 5:
    raise newException(StaticTreeError, "not a path below /etc: " & etcPath)
  etcPath[5 .. ^1]

proc staticLinkTargetFor*(etcPath: string): string =
  ## The target of the link materialising ``etcPath``:
  ## ``/etc/repro/static/<rel>``.
  StaticLinkPath & "/" & staticRelPath(etcPath)

proc isStaticLinkTarget*(etcPath, target: string): bool =
  ## Is ``target`` exactly the link the add-on would install at
  ## ``etcPath``? (The collision observer's "this link is ours".)
  etcPath.startsWith("/etc/") and etcPath.len > 5 and
    target == staticLinkTargetFor(etcPath)

proc treeManifest*(files: seq[StaticFile]): string =
  ## The canonical description of a tree: one line per file, sorted by
  ## path, ``<rel>\t<sha256>``. Its digest is the tree's identity.
  var lines: seq[string]
  for f in files:
    lines.add(staticRelPath(f.path) & "\t" & sha256Hex(f.content))
  lines.sort()
  lines.join("\n") & "\n"

proc staticTreePath*(files: seq[StaticFile]): string =
  ## Where the store places the tree for ``files``: pure, so a plan can
  ## name it without writing.
  let id = computeRealizationHash(StaticTreePackage, ReprobuildVersion,
    "addon-switch", "", "",
    provenanceChecksum = "tree:" & sha256Hex(treeManifest(files)))
  StoreRoot / prefixRelativePath(StaticTreePackage, ReprobuildVersion, id)

proc treeCarries(path: string; files: seq[StaticFile]): bool =
  ## Every file of the tree at ``path`` carries its planned bytes.
  for f in files:
    let at = path / staticRelPath(f.path)
    if not fileExists(at) or sha256OfFile(at) != sha256Hex(f.content):
      return false
  true

proc fsyncPath(path: string) =
  ## fsync one file or directory by path (opened read-only).
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC)
  if fd < 0:
    raiseOSError(osLastError(), "open " & path & " to sync it")
  try:
    if posix.fsync(fd) != 0:
      raiseOSError(osLastError(), "fsync " & path)
  finally:
    discard posix.close(fd)

proc syncTree*(root: string) =
  ## Make a realised tree durable: every file and directory in it, and the
  ## directories its name lives in. The store writes a prefix without
  ## syncing it (a build cache can recompute what a crash loses), but the
  ## static tree is what `/etc` reads through once the flip happens: a
  ## power cut after the flip must not bring the tree back empty.
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    fsyncPath(path)
  var d = root
  while d.len > StoreRoot.len and d.startsWith(StoreRoot):
    fsyncPath(d)
    d = parentDir(d)
  fsyncPath(StoreRoot)

proc realiseStaticTree*(files: seq[StaticFile]):
    tuple[path: string; prefixId: PrefixIdBytes] =
  ## Step 1 of the switch: put the tree into the store (an existing
  ## identical tree is reused), verify every file in it against the bytes
  ## it was built from, and hold it with the ``addon-pending`` root until
  ## the generation is committed. Every file is 0644; a secret never
  ## travels this way (the ``secret`` class is tmpfs-only, §10.3).
  enterWritableStoreView()
  # A tree a crash tore (the store had indexed it, its files never reached
  # the disk) is removed so the store re-materialises it: the store
  # re-creates a prefix whose directory is gone.
  let planned = staticTreePath(files)
  if dirExists(planned) and not treeCarries(planned, files):
    removeDir(planned)
  var s = openStore(StoreRoot)
  defer: s.close()
  let staging = StoreRoot / "tmp" / ("addon-etc-" & $getCurrentProcessId())
  removeDir(staging)
  createDir(staging)
  defer: removeDir(staging)
  for f in files:
    let dest = staging / staticRelPath(f.path)
    createDir(parentDir(dest))
    writeFile(dest, f.content)
    setFilePermissions(dest, {fpUserRead, fpUserWrite, fpGroupRead,
                              fpOthersRead})
  let res = s.realizeDirectoryAsPrefix(staging,
    StoreReceiptHint(adapter: "addon-switch", packageName: StaticTreePackage,
      version: ReprobuildVersion,
      provenanceChecksum: "tree:" & sha256Hex(treeManifest(files))))
  result.path = res.absolutePath
  result.prefixId = res.prefixId
  if result.path != staticTreePath(files):
    raise newException(StaticTreeError, "store placed the static tree at " &
      result.path & ", not at the planned " & staticTreePath(files))
  # Verify: the bytes that will be linked are the bytes that were planned.
  for f in files:
    let at = result.path / staticRelPath(f.path)
    if not fileExists(at) or sha256OfFile(at) != sha256Hex(f.content):
      raise newException(StaticTreeError, "static tree file " & at &
        " does not carry the planned bytes")
  syncTree(result.path)
  s.registerRoot(PendingRootId, rkProfile)
  s.attachPrefixToRoot(PendingRootId, result.prefixId)

proc holdOnPendingRoot*(prefixIds: openArray[PrefixIdBytes]) =
  ## Attach more of the generation's closure (its units' realised package
  ## closures) to the ``addon-pending`` root, so ``repro store gc`` can
  ## collect none of what the switch is about to run from -- before the
  ## commit, and after a crash until recovery promotes or releases it
  ## (spec §7.2 step 1: the root is registered at realise). Called after
  ## ``realiseStaticTree``, which registered the root: it is not registered
  ## again here, because re-registering replaces the root's row.
  if prefixIds.len == 0: return
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  for p in prefixIds:
    s.attachPrefixToRoot(PendingRootId, p)

proc promotePendingRoot*(generationId: string;
                         extra: openArray[PrefixIdBytes] = []) =
  ## Step 9: the committed generation's ``profile`` root takes over every
  ## prefix the ``addon-pending`` root held (the static tree and the units'
  ## closures, rooted at realise) plus ``extra`` (the prefixes its ledger
  ## names), then the pending root goes. The generation root holds all of
  ## them before the pending root lets any go, so nothing is collectable
  ## in between. Idempotent: a recovery that finishes a committed switch
  ## calls it again.
  if not dirExists(StoreRoot): return
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  var held = s.prefixesHeldByRoot(PendingRootId)
  for p in extra: held.add(p)
  let rootId = RootIdPrefix & generationId
  var exists = false
  for r in s.listRoots():
    if r.rootId == rootId: exists = true
  if not exists:
    s.registerRoot(rootId, rkProfile)
  for p in held:
    s.attachPrefixToRoot(rootId, p)
  s.deleteRoot(PendingRootId)

proc releasePendingRoot*() =
  ## Drop the ``addon-pending`` root once the generation holds the tree.
  if not dirExists(StoreRoot): return
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  s.deleteRoot(PendingRootId)

proc readStaticTarget*(): string =
  ## What ``/etc/repro/static`` points at now, "" when absent.
  if symlinkExists(StaticLinkPath): expandSymlink(StaticLinkPath) else: ""

proc flipStatic*(treePath: string) =
  ## Step 3: make ``/etc/repro/static`` point at ``treePath`` in one
  ## rename (a temporary link beside it, then ``renameat``), never through
  ## a link on the way. A flip to the tree already current is a no-op.
  if readStaticTarget() == treePath:
    return
  replaceWithLinkNoFollow(StaticLinkPath, treePath)

proc removeStaticLink*() =
  ## Uninstall: drop the static tree link.
  discard removeLeafNoFollow(StaticLinkPath)

# ---------------------------------------------------------------------------
# The pending marker.
# ---------------------------------------------------------------------------

proc pendingMarkerPath*(stateDir: string): string =
  stateDir / "addon" / "pending"

proc render*(m: PendingMarker): string =
  result = PendingMarkerHeader & "\n"
  result.add("from\t" & escapeField(m.fromGeneration) & "\n")
  result.add("plan\t" & escapeField(m.planId) & "\n")
  result.add("static\t" & escapeField(m.newStatic) & "\n")
  result.add("previous-static\t" & escapeField(m.previousStatic) & "\n")
  result.add("step\t" & $m.step & "\n")
  result.add("status\t" & escapeField(m.status) & "\n")
  result.add("stopped\t" & escapeField(m.stopped.join(" ")) & "\n")
  result.add("detail\t" & escapeField(m.detail) & "\n")
  result.add("disabled\t" & escapeField(m.disabled.join(" ")) & "\n")
  result.add("attempt\t" & escapeField(m.attempt) & "\n")
  result.add("purpose\t" & escapeField(m.purpose) & "\n")
  result.add("revert-of\t" & escapeField(m.revertOf) & "\n")
  result.add("revert-reason\t" & escapeField(m.revertReason) & "\n")

proc parsePendingMarker*(text: string): PendingMarker =
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != PendingMarkerHeader:
    raise newException(StaticTreeError, "not a repro-addon pending marker")
  for i in 1 ..< lines.len:
    if lines[i].len == 0: continue
    let f = lines[i].split('\t', 1)
    if f.len != 2:
      raise newException(StaticTreeError, "malformed pending marker line " &
        $(i + 1))
    let v = unescapeField(f[1])
    case f[0]
    of "from": result.fromGeneration = v
    of "plan": result.planId = v
    of "static": result.newStatic = v
    of "previous-static": result.previousStatic = v
    of "step":
      var found = false
      for s in SwitchStep:
        if $s == v:
          result.step = s
          found = true
      if not found:
        raise newException(StaticTreeError, "unknown switch step " & v)
    of "status": result.status = v
    of "stopped":
      if v.len > 0: result.stopped = v.split(' ')
    of "detail": result.detail = v
    of "disabled":
      if v.len > 0: result.disabled = v.split(' ')
    of "attempt": result.attempt = v
    of "purpose": result.purpose = v
    of "revert-of": result.revertOf = v
    of "revert-reason": result.revertReason = v
    else:
      raise newException(StaticTreeError, "unknown pending marker field " & f[0])

proc writePendingMarker*(stateDir: string; m: PendingMarker) =
  ## Atomic: a crash leaves the previous marker or this one.
  createDir(parentDir(pendingMarkerPath(stateDir)))
  writeFileNoFollow(pendingMarkerPath(stateDir), m.render(), 0o600)

proc readPendingMarker*(stateDir: string): PendingMarker =
  parsePendingMarker(readFile(pendingMarkerPath(stateDir)))

proc hasPendingMarker*(stateDir: string): bool =
  fileExists(pendingMarkerPath(stateDir))

proc clearPendingMarker*(stateDir: string) =
  ## Step 9's last act.
  discard removeLeafNoFollow(pendingMarkerPath(stateDir))
