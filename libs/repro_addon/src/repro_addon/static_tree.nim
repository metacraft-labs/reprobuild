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

import std/[algorithm, os, posix, strutils, tables, times]

import repro_core
import repro_local_store/store
from repro_dsl_stdlib/packages/apt_closure import
  adoptLegacyAptClosurePrefixes, adoptUnverifiedPrefix, LegacyAptAdoption,
  LegacyAptPrefix
from repro_infra/apply_lock import currentBootId, processAlive

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
    ownerPid*: int            ## the process running the switch: the one
                              ## that wrote the marker last (stamped by
                              ## `writePendingMarker`); 0 for a marker an
                              ## older build wrote
    ownerBoot*: string        ## the kernel boot id when it was written

const
  StaticLinkPath* = "/etc/repro/static"
  StaticTreePackage* = "repro-addon-etc"
  PendingMarkerHeader* = "# repro-addon-pending v1"
  PendingRootId* = "addon-pending"
    ## The store root that holds the tree being switched to until the
    ## generation that owns it is committed and registered.
  HandBackRootId* = "addon-hand-back"
    ## The store root that holds every prefix a file on the host names
    ## outside any generation's static tree: a unit or launcher manifest on
    ## disk (``LiveReferenceDirs``), or a hand-back record the switch
    ## preserved when it relocated one from an older realiser's prefix
    ## (ReproOS Add-On Mode §5.2, §9 "Migration"). Recomputed by every
    ## ``migrateLegacyAptClosures``.

const SystemStateDir* = "/var/lib/repro/system"
  ## The add-on's state directory (``addon_apply.DefaultStateDir``).

proc preservedDir*(stateDir = SystemStateDir): string =
  ## Where the switch keeps the bytes it displaced (hand-back records,
  ## content-addressed): what a removal or a rollback restores.
  stateDir / "addon" / "preserved"

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

proc closureBindings(treeRoot: string): seq[string] =
  ## The closure prefixes a generation's units bind: the source of every
  ## ``BindReadOnlyPaths=<prefix>/usr:/usr`` line in a unit file or drop-in
  ## of its static tree (``<tree>/systemd/system``), as
  ## ``aptClosureUnitDirectives`` renders them.
  let units = treeRoot / "systemd" / "system"
  if not dirExists(units): return
  for path in walkDirRec(units, yieldFilter = {pcFile},
                         followFilter = {pcDir}):
    var text = ""
    try: text = readFile(path)
    except IOError: continue
    for raw in text.splitLines():
      let line = raw.strip()
      if not line.startsWith("BindReadOnlyPaths="): continue
      for entry in line["BindReadOnlyPaths=".len .. ^1].splitWhitespace():
        let src = entry.strip(trailing = false, chars = {'-', '+'}).split(':')[0]
        if src.endsWith("/usr"):
          result.add(src[0 ..< src.len - "/usr".len])

const LiveReferenceDirs* = @["/etc/systemd/system", "/run/systemd/system",
                             "/etc/repro/bin"]
  ## Where the files are that name store prefixes the host runs from right
  ## now, whatever wrote them: unit files (`BindReadOnlyPaths=`, or an
  ## `ExecStart=` of a store binary such as generation 0's
  ## `repro-addon-reassert.service`), their drop-ins (`<unit>.d/*.conf`),
  ## transient and runtime units, and launcher manifests.

proc referenceText(dirs: seq[string]): string =
  ## What the files in ``dirs`` say, concatenated: every regular file
  ## directly in each directory and in its ``*.d`` drop-in directories, and
  ## for each symbolic link there (a unit file linked from elsewhere, maybe
  ## from the store) the path it resolves to as well as the file's text.
  ## Raises ``StaticTreeError`` when one cannot be read: then nothing can
  ## say what it binds, and a collection that went ahead could take a
  ## prefix a unit runs from.
  proc addFile(f: string; acc: var string) =
    try:
      if symlinkExists(f):
        acc.add(expandFilename(f) & "\n")
      if fileExists(f):
        acc.add(readFile(f))
        acc.add("\n")
    except IOError, OSError:
      let e = getCurrentException()
      raise newException(StaticTreeError, "cannot read " & f & " (" &
        e.msg & "), so what it binds in the store cannot be held; " &
        "nothing was collected or recovered")
  for d in dirs:
    if not dirExists(d): continue
    for kind, f in walkDir(d):
      case kind
      of pcFile, pcLinkToFile: addFile(f, result)
      of pcDir:
        if f.endsWith(".d"):
          for k2, g in walkDir(f):
            if k2 in {pcFile, pcLinkToFile}: addFile(g, result)
      else: discard

proc names(text, path: string): bool =
  ## Whether ``text`` names the prefix ``path``: followed by `/` (a bind of
  ## its `usr`, a binary in its `bin`) or by an end of the path (a line
  ## end, a space, a `:`, a quote).
  for sep in ["/", "\n", " ", ":", "\"", "'", "\t"]:
    if (path & sep) in text: return true

proc migrateLegacyAptClosures*(storeRoot = StoreRoot;
                               handBack: seq[string] = @[];
                               live: seq[string] = LiveReferenceDirs):
    LegacyAptAdoption =
  ## Adopt the apt closure prefixes a realiser before version 3 wrote (no
  ## receipt, no index row; ``adoptLegacyAptClosurePrefixes``) and root
  ## them:
  ##
  ## * each adopted closure -- its union and its members -- to every
  ##   generation root (and the pending root) whose static tree has a unit
  ##   binding it;
  ## * to ``HandBackRootId``, every indexed prefix (adopted or the store's
  ##   own; a closure with its members) that a file names, in the
  ##   ``handBack`` directories (the add-on's preserved bytes) or the
  ##   ``live`` ones (``LiveReferenceDirs``): before the first add-on switch
  ##   of an upgraded host, rpi2's 22 closure units, its tool manifests and
  ##   generation 0's reassert unit (which runs the add-on's own
  ##   `repro` from the store) are bound by no generation's static tree;
  ##   after it, a relocated service still runs from its older prefix
  ##   until it restarts, and a rollback or a removal writes the older
  ##   binding back.
  ##
  ## A file under those directories that cannot be read raises
  ## ``StaticTreeError`` before anything is adopted or released (the caller
  ## refuses its collection or recovery). An older realiser's directory
  ## that does not verify but that a file names is adopted unverified (``adoptUnverifiedPrefix``) and held, and
  ## reported (``heldUnverified``): recovery would otherwise quarantine it
  ## under the unit. The hand-back hold is recomputed from scratch on each
  ## run, so a prefix no file names any more is released and collected by
  ## the next gc. Runs under the caller's host apply lock (every add-on
  ## store writer holds it), in one store session, before anything
  ## collects. Idempotent. ``storeRoot`` is the add-on's system store;
  ## another root is for tests.
  if not dirExists(storeRoot / "prefixes"): return
  if storeRoot == StoreRoot: enterWritableStoreView()
  var s = openStore(storeRoot)
  defer: s.close()
  let refs = referenceText(handBack & live)
  result = adoptLegacyAptClosurePrefixes(s, storeRoot)
  # Directories that did not verify but that a file names: held anyway.
  var stillRefused: seq[tuple[path, reason: string]]
  for r in result.refused:
    if names(refs, r.path):
      try:
        discard adoptUnverifiedPrefix(s, storeRoot, r.path)
        result.heldUnverified.add(r)
      except CatchableError as e:
        stillRefused.add((r.path, r.reason & "; adopting it unverified " &
          "failed: " & e.msg))
    else:
      stillRefused.add(r)
  result.refused = stillRefused
  var byPath = initTable[string, seq[PrefixIdBytes]]()
  var debIds = initTable[string, PrefixIdBytes]()
  for a in result.adopted:
    if not a.closure: debIds[a.path] = a.prefixId
  for a in result.adopted:
    if a.closure:
      var ids = @[a.prefixId]
      for m in a.members:
        if m in debIds: ids.add(debIds[m])
      byPath[a.path] = ids
  s.deleteRoot(HandBackRootId)
  var held = false
  for row in s.listPrefixes():
    let path = storeRoot / row.realizedPath
    let legacy = path in byPath
    if not names(refs, path):
      continue
    if not held:
      s.registerRoot(HandBackRootId, rkProfile)
      held = true
    s.attachPrefixToRoot(HandBackRootId, row.prefixId)
    if legacy:
      for id in byPath[path]: s.attachPrefixToRoot(HandBackRootId, id)
  if byPath.len == 0: return
  for r in s.listRoots():
    if not (r.rootId.startsWith(RootIdPrefix) or r.rootId == PendingRootId):
      continue
    for held in s.prefixesHeldByRoot(r.rootId):
      let row = s.lookupPrefix(held)
      if not row.found or row.row.packageName != StaticTreePackage: continue
      for bound in closureBindings(storeRoot / row.row.realizedPath):
        if bound in byPath:
          for id in byPath[bound]:
            s.attachPrefixToRoot(r.rootId, id)

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
  result.add("owner-pid\t" & $m.ownerPid & "\n")
  result.add("owner-boot\t" & escapeField(m.ownerBoot) & "\n")

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
    of "owner-pid":
      try: result.ownerPid = parseInt(v)
      except ValueError:
        raise newException(StaticTreeError, "malformed owner-pid " & v)
    of "owner-boot": result.ownerBoot = v
    else:
      raise newException(StaticTreeError, "unknown pending marker field " & f[0])

proc writePendingMarker*(stateDir: string; m: PendingMarker) =
  ## Atomic: a crash leaves the previous marker or this one. The writer is
  ## the switch, so the marker is stamped with this process and this boot:
  ## that is how recovery and the apply guard tell the switch that owns a
  ## marker from any other holder of the host apply lock.
  var stamped = m
  stamped.ownerPid = getCurrentProcessId()
  stamped.ownerBoot = currentBootId()
  createDir(parentDir(pendingMarkerPath(stateDir)))
  writeFileNoFollow(pendingMarkerPath(stateDir), stamped.render(), 0o600)

proc markerOwnedByCaller*(m: PendingMarker; pid: int; bootId: string): bool =
  ## Pure: the marker was written by process ``pid`` in the boot
  ## ``bootId``. A caller holding the host apply lock exclusively asks
  ## this, not "is the owner alive": the only switch that can be live
  ## while the caller holds the lock is the caller itself, and an
  ## unrelated process that reused a dead owner's PID (pid_max is 32768
  ## on armv7) is alive too. Where the kernel has no boot id (macOS,
  ## Windows) both sides are "" and the PID alone decides.
  m.ownerPid > 0 and m.ownerPid == pid and m.ownerBoot == bootId

const AddonStateDirPointer* = "/var/lib/repro/addon-state-dir"
  ## Where bootstrap records the add-on's state directory (one line). It
  ## lives under the add-on root ``/var/lib/repro``, which uninstall removes
  ## whole and the fingerprint records only as a root, so it is part of the
  ## add-on's own state, like the state directory itself. A process that is
  ## not given the add-on's ``--state-dir`` -- a deploy-agent tick runs with
  ## its own -- finds the add-on's pending marker through it.

proc writeAddonStateDirPointer*(stateDir: string;
                                path = AddonStateDirPointer) =
  createDir(parentDir(path))
  writeFileNoFollow(path, stateDir & "\n", 0o644)

when defined(posix):
  var PointerOpenNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

proc readAddonStateDirPointerChecked*(path = AddonStateDirPointer;
                                      owner = 0):
    tuple[dir: string; why: string] =
  ## The recorded add-on state directory, or ``dir`` "" and ``why`` the
  ## reason the pointer is not trusted ("" too when there is none). The
  ## pointer decides where an apply looks for an interrupted switch to
  ## recover, so it is trusted only as bootstrap writes it: a regular file,
  ## opened without following a symbolic link, owned by ``owner`` (root on
  ## a host; a test passes its own uid) and not writable by group or
  ## others, naming an absolute, normalised path to an existing directory.
  when defined(posix):
    let fd = posix.open(path.cstring, O_RDONLY or PointerOpenNoFollow or O_CLOEXEC)
    if fd < 0:
      let err = osLastError()
      if err.int32 == ENOENT: return ("", "")
      return ("", path & " is not opened (" & osErrorMsg(err) &
        "; a symbolic link is refused)")
    var content = ""
    try:
      var st: Stat
      if fstat(fd, st) != 0:
        return ("", path & ": fstat failed")
      if not S_ISREG(st.st_mode):
        return ("", path & " is not a regular file")
      if int(st.st_uid) != owner:
        return ("", path & " is owned by uid " & $st.st_uid & ", not " &
          $owner)
      if (int(st.st_mode) and 0o022) != 0:
        return ("", path & " is writable by group or others")
      var buf = newString(4096)
      let n = posix.read(fd, addr buf[0], buf.len)
      if n < 0: return ("", path & ": read failed")
      content = buf[0 ..< n].strip()
    finally:
      discard posix.close(fd)
    if content.len == 0 or not content.isAbsolute or
        os.normalizedPath(content) != content or content.endsWith("/"):
      return ("", path & " does not hold an absolute, normalised path")
    if not dirExists(content) or symlinkExists(content):
      return ("", path & " names " & content & ", which is not an " &
        "existing directory")
    (content, "")
  else:
    discard owner
    ("", "")

proc readAddonStateDirPointer*(path = AddonStateDirPointer;
                               owner = 0): string =
  ## The recorded add-on state directory, "" when there is none or it is
  ## not trusted (see ``readAddonStateDirPointerChecked``; the reason goes
  ## to stderr).
  let r = readAddonStateDirPointerChecked(path, owner)
  if r.why.len > 0:
    stderr.writeLine("repro-addon: ignoring the add-on state-directory " &
      "pointer: " & r.why)
  r.dir

proc hostHandBackDirs*(pointer = AddonStateDirPointer; owner = 0):
    seq[string] =
  ## The hand-back record directory of the add-on's real state directory:
  ## the one bootstrap recorded in its trusted pointer
  ## (``readAddonStateDirPointerChecked``), else the default. What a
  ## collection or a recovery of the store must hold is named there; a
  ## `store gc` that read the default directory of a host bootstrapped
  ## with another one rebuilt the hold without those records, and collected
  ## the older prefixes relocated services still run from. A pointer that
  ## is not trusted cannot say where they are: raises ``StaticTreeError``,
  ## and nothing is collected or recovered.
  let r = readAddonStateDirPointerChecked(pointer, owner)
  if r.why.len > 0:
    raise newException(StaticTreeError, "the add-on's state-directory " &
      "pointer is not trusted (" & r.why & "), so the hand-back records " &
      "the store must keep cannot be found; nothing was collected or " &
      "recovered")
  @[preservedDir(if r.dir.len > 0: r.dir else: SystemStateDir)]

proc markerOwnerLive*(m: PendingMarker): bool =
  ## True when the process that owns the switch is still running it: the
  ## recorded PID exists and the marker was written in this boot (a PID
  ## from an earlier boot names some unrelated process now).
  m.ownerPid > 0 and m.ownerBoot.len > 0 and
    m.ownerBoot == currentBootId() and processAlive(m.ownerPid)

proc readPendingMarker*(stateDir: string): PendingMarker =
  parsePendingMarker(readFile(pendingMarkerPath(stateDir)))

proc hasPendingMarker*(stateDir: string): bool =
  fileExists(pendingMarkerPath(stateDir))

proc clearPendingMarker*(stateDir: string) =
  ## Step 9's last act.
  discard removeLeafNoFollow(pendingMarkerPath(stateDir))
