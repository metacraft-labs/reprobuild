## The switch's own root snapshot (ReproOS Add-On Mode §7.2, §6.4, §8.5,
## §12.2; §13 decisions 90, 100, 101, 105, 116, 119).
##
## A fresh switch on a host whose snapper has a configuration for ``/``
## takes one snapshot of ``/`` after every plan-time refusal and after step 1
## (which touches no base path), and before its pending marker is first
## written. It is created with
##
## .. code-block:: sh
##   snapper -c <config> create --cleanup-algorithm '' \
##     --description "repro-addon gen <n>" --userdata "repro-addon=<key>" \
##     --print-number
##
## The empty cleanup algorithm keeps it out of snapper's ``number`` and
## ``timeline`` cleanups (Omarchy keeps five numbered snapshots, so a
## numbered add-on snapshot would be deleted by the next ``omarchy
## update``). ``<key>`` is a random token the switch draws for the attempt;
## the add-on finds its snapshots by the ``repro-addon`` userdata and
## identifies each by that key, never by its number alone: snapper takes
## the next number as the highest existing one plus one, so a number the
## add-on deleted can come back on a snapshot Omarchy takes.
##
## Records, all under the add-on's state directory (root only):
##
## ==========================================  ================================
## ``addon/root-snapshots/<key>``              written, durably, BEFORE
##                                             ``snapper create`` runs: the
##                                             configuration and, once known,
##                                             the number. It is what lets the
##                                             sweep recognise a snapshot a
##                                             crash left between ``create``
##                                             and the marker as the add-on's
##                                             own. Removed when the snapshot
##                                             is deleted.
## the pending marker's ``root-snapshot``      the attempt's key: the present
##                                             marker's attempt owns it
## the marker's ``revert-snapshot``            a revert: the key of the
##                                             attempt it reverts, which the
##                                             actor that completes the
##                                             revert deletes (decision 105)
## ``generations/<id>/root-snapshot``          a COMMITTED generation's key,
##                                             written at step 9; the
##                                             generation owns its snapshot
##                                             while retention keeps it
## ==========================================  ================================
##
## The attempt's apply log (the generation log) records the snapshot's
## configuration, number and key from step 4, where the attempt is given
## its id.
##
## *The sweep* (decision 116) deletes every snapshot the state directory
## recorded (``addon/root-snapshots``) that is owned by no retained
## generation -- a committed generation whose store root retention still
## keeps, or the current or previous one -- and by no present marker's
## attempt. A ``rolled-back`` record owns none. Two narrowings keep it from
## deleting a way back:
##
## - it acts only on keys this state directory recorded. A host booted into
##   one of its own snapshots runs with the state that snapshot holds, which
##   never heard of the snapshots taken after it; those are left alone;
## - when the store's roots cannot be listed (the store is gone, §7.6), every
##   committed generation's snapshot counts as retained: those snapshots are
##   the way back after a lost store.
##
## Uninstall deletes every snapshot carrying the ``repro-addon`` userdata in
## every snapper configuration, recorded or not (§6.4).
##
## A snapshot is only ever deleted after its ``info.xml`` was read again and
## still carries ``repro-addon=<key>``: the add-on never deletes a snapshot
## it did not create (threat model T61).
##
## snapper is run through D-Bus (its default), so ``snapperd`` -- the base's
## own service -- does the btrfs work: the add-on's units, which see ``/``
## read-only outside their ``ReadWritePaths=``, never write a subvolume
## themselves.
##
## References: snapper(8) (``create --cleanup-algorithm``, ``--userdata``,
## ``--print-number``, ``delete``), snapper-configs(5) (``SUBVOLUME``,
## ``NUMBER_LIMIT``), https://github.com/openSUSE/snapper.

import std/[algorithm, os, sets, strutils, sysrand]

import repro_infra/addon_diagnostics
import repro_infra/gen_envelope
import repro_infra/profile
import repro_infra/state_dir
import repro_elevation/nofollow_write

import ./generation0
import ./host_exec
import ./mutations
import ./preflight
import ./static_tree
import ./store_custody
import ./store_root

const
  SnapperUserdataKey* = "repro-addon"
    ## The userdata key every add-on snapshot carries (§7.2).
  RootSnapshotRecordHeader* = "# repro-addon root-snapshot v1"
  SnapperCandidates = ["/usr/bin/snapper", "/usr/sbin/snapper", "/bin/snapper",
                       "/sbin/snapper"]
  SnapperTimeoutSec = 300

type
  RootSnapshotError* = object of CatchableError

  SnapperRunner* = proc (args: seq[string]): tuple[exitCode: int; output: string]
    ## Runs ``snapper <args>`` on the host. The default runs the base's
    ## snapper; a unit test substitutes one that works on a fixture tree.

  HostSnapshot* = object
    ## One snapper snapshot carrying the ``repro-addon`` userdata.
    config*: string     ## the snapper configuration
    number*: int
    key*: string        ## the userdata value ("" when the key has none)
    dir*: string        ## ``<SUBVOLUME>/.snapshots/<number>``

  RootSnapshotRecord* = object
    key*: string
    config*: string
    number*: int        ## 0 until ``snapper create`` returned it

  RootSnapshotPlan* = object
    ## What a switch will do about its root snapshot (decided at plan time).
    take*: bool         ## a snapshot will be taken
    config*: string     ## the snapper configuration for ``/`` it uses
    refusal*: string    ## non-empty: ``required`` and no configuration
    line*: string       ## the plan's line (``root snapshot: ...``)

  SnapshotSite* = object
    ## Where the add-on looks for snapper's configurations and snapshots:
    ## ``/`` on a host, a fixture tree in a unit test.
    root*: string
    snapper*: SnapperRunner
    mountinfo*: string
      ## ``/proc/self/mountinfo`` as text; "" reads the host's
    cmdline*: string
      ## ``/proc/cmdline`` as text; "" reads the host's

proc defaultSnapperRunner*(): SnapperRunner =
  ## snapper as the base installs it, through D-Bus (``snapperd``).
  result = proc (args: seq[string]): tuple[exitCode: int; output: string] =
    let exe = resolveHostTool(SnapperCandidates)
    if exe.len == 0:
      return (127, "snapper is not installed")
    try:
      let r = runHostTool(@[exe] & args, timeoutSec = SnapperTimeoutSec)
      (r.exitCode, r.output)
    except CatchableError as e:
      (1, e.msg)

proc hostSnapshotSite*(): SnapshotSite =
  SnapshotSite(root: "/", snapper: defaultSnapperRunner())

proc underRoot(site: SnapshotSite; path: string): string =
  if site.root.len == 0 or site.root == "/": path
  else: site.root / path

# ---------------------------------------------------------------------------
# snapper's own files.
# ---------------------------------------------------------------------------

proc snapperUserdataValue*(infoXml: string): tuple[found: bool; value: string] =
  ## The value of the ``repro-addon`` userdata in a snapshot's ``info.xml``
  ## (snapper writes each pair as ``<userdata><key>K</key><value>V</value>
  ## </userdata>``); ``found`` false when the snapshot has none.
  for chunk in infoXml.split("<userdata>")[1 .. ^1]:
    let e = chunk.find("</userdata>")
    let body = if e >= 0: chunk[0 ..< e] else: chunk
    let ks = body.find("<key>")
    let ke = body.find("</key>")
    if ks < 0 or ke < ks: continue
    if body[ks + 5 ..< ke].strip() != SnapperUserdataKey: continue
    let vs = body.find("<value>")
    let ve = body.find("</value>")
    if vs >= 0 and ve > vs:
      return (true, body[vs + 7 ..< ve].strip())
    return (true, "")
  (false, "")

proc snapperConfigs*(site: SnapshotSite): seq[tuple[name, subvolume: string]] =
  ## Every snapper configuration with its ``SUBVOLUME``, sorted by name.
  let dir = site.underRoot("/etc/snapper/configs")
  if not dirExists(dir): return
  for kind, p in walkDir(dir):
    if kind notin {pcFile, pcLinkToFile}: continue
    let sub = snapperConfigSubvolume(readFile(p))
    if sub.len > 0: result.add((extractFilename(p), sub))
  result.sort(proc (a, b: tuple[name, subvolume: string]): int = cmp(a.name, b.name))

proc rootSnapshotConfig*(site: SnapshotSite): string =
  ## The configuration a root snapshot is taken with: the one for ``/``
  ## named ``root`` (snapper's and Omarchy's name for it) when there is one,
  ## else the first for ``/`` by name; "" when snapper has none for ``/``.
  var forRoot: seq[string]
  for c in snapperConfigs(site):
    if c.subvolume == "/": forRoot.add(c.name)
  if "root" in forRoot: return "root"
  if forRoot.len > 0: return forRoot[0]
  ""

proc addonSnapshotsOnHost*(site: SnapshotSite): seq[HostSnapshot] =
  ## Every snapshot of every snapper configuration whose ``info.xml``
  ## carries the ``repro-addon`` userdata, by configuration and number.
  for c in snapperConfigs(site):
    let snaps = site.underRoot(c.subvolume / ".snapshots")
    if not dirExists(snaps): continue
    for kind, d in walkDir(snaps):
      if kind != pcDir: continue
      var n = 0
      try: n = parseInt(extractFilename(d))
      except ValueError: continue
      let info = d / "info.xml"
      if not fileExists(info): continue
      let ud = try: snapperUserdataValue(readFile(info))
               except IOError, OSError: (false, "")
      if ud.found:
        result.add(HostSnapshot(config: c.name, number: n, key: ud.value,
                                dir: d))
  result.sort(proc (a, b: HostSnapshot): int =
    result = cmp(a.config, b.config)
    if result == 0: result = cmp(a.number, b.number))

proc rootMountSource*(mountinfo: string): string =
  ## The subvolume path ``/`` is mounted from, as ``/proc/self/mountinfo``
  ## gives it (field 4, the root of the mount within its filesystem, e.g.
  ## ``/@`` or ``/@/.snapshots/7/snapshot``); for an overlay root, its
  ## ``lowerdir``. See proc_pid_mountinfo(5).
  for l in mountinfo.splitLines():
    let f = l.splitWhitespace()
    if f.len < 10 or f[4] != "/": continue
    let sep = f.find("-")
    if sep < 0 or sep + 3 >= f.len: continue
    if f[sep + 1] == "overlay":
      for o in f[sep + 3].split(','):
        if o.startsWith("lowerdir="): result = o["lowerdir=".len .. ^1]
    else:
      result = f[3]

proc rootflagsSubvol*(cmdline: string): string =
  ## The ``subvol=`` of the kernel command line's ``rootflags=`` (what the
  ## boot loader asked the initrd to mount as ``/``); "" when none.
  ## kernel-parameters ``rootflags``, btrfs(5) ``subvol``.
  for w in cmdline.splitWhitespace():
    if not w.startsWith("rootflags="): continue
    for o in w["rootflags=".len .. ^1].split(','):
      if o.startsWith("subvol="): result = o["subvol=".len .. ^1]

proc isRunningRoot*(site: SnapshotSite; s: HostSnapshot): bool =
  ## Is ``/`` mounted from this snapshot? A host booted into one of its
  ## snapshots (Omarchy's boot menu offers each) runs with the state that
  ## snapshot holds -- in which the snapshot's own record, written just
  ## before ``snapper create``, has no owner yet. It is never deleted.
  ## Read from the mount table and, because Omarchy boots a read-only
  ## snapshot under an overlay whose lower layer the table names only as
  ## ``/sysroot``, from the kernel command line too.
  let mi = if site.mountinfo.len > 0: site.mountinfo
           else: (try: readFile("/proc/self/mountinfo") except IOError, OSError: "")
  let cl = if site.cmdline.len > 0: site.cmdline
           else: (try: readFile("/proc/cmdline") except IOError, OSError: "")
  let tail = "/.snapshots/" & $s.number & "/snapshot"
  for src in [rootMountSource(mi), rootflagsSubvol(cl)]:
    if src.len > 0 and (src.endsWith(tail) or (tail & "/") in src):
      return true
  false

proc snapshotName*(s: HostSnapshot): string =
  s.config & "#" & $s.number & " (" & SnapperUserdataKey & "=" & s.key & ")"

# ---------------------------------------------------------------------------
# The records.
# ---------------------------------------------------------------------------

proc recordsDir*(stateDir: string): string = stateDir / "addon" / "root-snapshots"

proc isSnapshotKey*(key: string): bool =
  ## A key the add-on draws: 32 lowercase hex digits.
  key.len == 32 and key.allCharsInSet(HexDigits - {'A' .. 'F'})

proc recordPath(stateDir, key: string): string =
  if not isSnapshotKey(key):
    raise newException(RootSnapshotError, "not a root snapshot key: " & key)
  recordsDir(stateDir) / key

proc renderRecord(r: RootSnapshotRecord): string =
  RootSnapshotRecordHeader & "\nconfig\t" & r.config & "\n" &
    (if r.number > 0: "number\t" & $r.number & "\n" else: "")

proc parseRecord*(key, text: string): RootSnapshotRecord =
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != RootSnapshotRecordHeader:
    raise newException(RootSnapshotError, "not a root snapshot record: " & key)
  result.key = key
  for l in lines[1 .. ^1]:
    if l.len == 0: continue
    let f = l.split('\t', 1)
    if f.len != 2:
      raise newException(RootSnapshotError, "malformed root snapshot record " & key)
    case f[0]
    of "config": result.config = f[1]
    of "number":
      try: result.number = parseInt(f[1])
      except ValueError:
        raise newException(RootSnapshotError, "malformed number in " & key)
    else:
      raise newException(RootSnapshotError, "unknown field " & f[0] & " in " & key)

proc writeRecord(stateDir: string; r: RootSnapshotRecord) =
  ## Durable (``writeFileNoFollow`` renames over a synced temporary file):
  ## the record must be on disk before ``snapper create`` runs.
  # A directory created here is made durable in its parent too: a record
  # whose directory entry is lost in a crash leaves a snapshot no state
  # records, which only uninstall would delete.
  let dir = recordsDir(stateDir)
  if not dirExists(dir):
    createDir(dir)
    fsyncPath(parentDir(dir))
    fsyncPath(parentDir(parentDir(dir)))
  writeFileNoFollow(recordPath(stateDir, r.key), renderRecord(r), 0o600)
  fsyncPath(dir)

proc readRecords*(stateDir: string): seq[RootSnapshotRecord] =
  ## Every record; an unreadable one is kept by its key alone (config "",
  ## number 0), so its snapshot is still the add-on's to sweep.
  let dir = recordsDir(stateDir)
  if not dirExists(dir): return
  for kind, p in walkDir(dir):
    if kind != pcFile: continue
    let key = extractFilename(p)
    if not isSnapshotKey(key): continue
    try:
      result.add(parseRecord(key, readFile(p)))
    except CatchableError:
      result.add(RootSnapshotRecord(key: key))
  result.sort(proc (a, b: RootSnapshotRecord): int = cmp(a.key, b.key))

proc removeRecord*(stateDir, key: string) =
  discard removeLeafNoFollow(recordPath(stateDir, key))

proc generationSnapshotPath*(stateDir, generationId: string): string =
  stateDir / "generations" / generationId / "root-snapshot"

proc readGenerationSnapshotKey*(stateDir, generationId: string):
    tuple[key: string; known: bool] =
  ## The key of the snapshot a committed generation owns. ``known`` is
  ## false when the generation's ``root-snapshot`` file is there but cannot
  ## be read or does not hold a key: what it owns is then unknown, and the
  ## sweep deletes nothing (it must never delete a way back, spec §7.2).
  ## A generation without the file owns no snapshot: ("", true).
  if generationId.len == 0: return ("", true)
  let p = generationSnapshotPath(stateDir, generationId)
  if not fileExists(p) and not symlinkExists(p): return ("", true)
  try:
    let k = readFile(p).strip()
    if isSnapshotKey(k): (k, true) else: ("", false)
  except IOError, OSError:
    ("", false)

proc generationSnapshotKey*(stateDir, generationId: string): string =
  ## The key of the snapshot a committed generation owns; "" when none or
  ## when it cannot be read (``readGenerationSnapshotKey`` tells the two
  ## apart).
  readGenerationSnapshotKey(stateDir, generationId).key

proc recordGenerationSnapshot*(stateDir, generationId, key: string) =
  ## Step 9: the committed generation owns the attempt's snapshot.
  if key.len == 0 or generationId.len == 0: return
  # Durable before step 9 goes on to retention and the sweeps: a lost
  # ownership file would leave a retained generation's snapshot an orphan.
  let p = generationSnapshotPath(stateDir, generationId)
  createDir(parentDir(p))
  writeFileNoFollow(p, key & "\n", 0o600)
  fsyncPath(parentDir(p))

# ---------------------------------------------------------------------------
# Plan, take, delete.
# ---------------------------------------------------------------------------

proc newSnapshotKey*(): string =
  ## 128 random bits as 32 hex digits.
  let b = urandom(16)
  for x in b: result.add(toHex(int(x), 2).toLowerAscii())

proc planRootSnapshot*(setting: RootSnapshotSetting; fresh: bool;
                       site: SnapshotSite): RootSnapshotPlan =
  ## What the switch does about its snapshot. ``fresh`` is false for a
  ## replay, a revert, a rollback, generation 0 and a plan of none of them:
  ## those take no snapshot of their own (§7.2).
  if not fresh:
    result.line = "root snapshot: none (a rollback, a revert, a replay and " &
      "generation 0 take no snapshot of their own)"
    return
  if setting == rsOff:
    result.line = "root snapshot: none (rootSnapshot = \"off\"); no second " &
      "way back exists"
    return
  let config = rootSnapshotConfig(site)
  if config.len == 0:
    if setting == rsRequired:
      result.refusal = "rootSnapshot = \"required\", but snapper has no " &
        "configuration for / (" & site.underRoot("/etc/snapper/configs") &
        "); nothing was written"
      result.line = "root snapshot: refused (" &
        diagnosticMessage(adRootSnapshot, result.refusal) & ")"
    else:
      result.line = "root snapshot: none (snapper has no configuration for " &
        "/); no second way back exists"
    return
  result.take = true
  result.config = config
  result.line = "root snapshot: snapper configuration " & config & " (" &
    "rootSnapshot = \"" & $setting & "\"), taken before the switch's " &
    "first write"

proc cleanupAlgorithmArg(): string =
  when mutated("snapshot-cleanup-number"):
    # The falsifying build of e2e_arch_addon_root_snapshot_setting: the
    # snapshot joins snapper's numbered ones, so a base's own `cleanup
    # number` (every `omarchy update`) deletes it.
    "number"
  else:
    ""

proc takeRootSnapshot*(stateDir: string; plan: RootSnapshotPlan;
                       description: string; site: SnapshotSite):
    tuple[ok: bool; record: RootSnapshotRecord; why: string] =
  ## Record the attempt's key durably, then create the snapshot and record
  ## its number. On failure the record is removed again (nothing is left
  ## for a refused apply) and ``why`` says what snapper reported.
  let key = newSnapshotKey()
  var rec = RootSnapshotRecord(key: key, config: plan.config)
  writeRecord(stateDir, rec)
  let r = site.snapper(@["-c", plan.config, "create", "--cleanup-algorithm",
    cleanupAlgorithmArg(), "--description", description, "--userdata",
    SnapperUserdataKey & "=" & key, "--print-number"])
  var number = 0
  if r.exitCode == 0:
    for l in r.output.splitLines():
      try:
        number = parseInt(l.strip())
        break
      except ValueError:
        discard
  if r.exitCode != 0 or number <= 0:
    # A snapshot snapper made but did not report would carry the key: it
    # is found by its userdata, never left behind.
    var left = false
    for s in addonSnapshotsOnHost(site):
      if s.key == key: left = true
    if not left:
      removeRecord(stateDir, key)
    return (false, rec, "snapper -c " & plan.config & " create failed (exit " &
      $r.exitCode & "): " & r.output.strip())
  rec.number = number
  writeRecord(stateDir, rec)
  (true, rec, "")

proc deleteHostSnapshot(site: SnapshotSite; s: HostSnapshot): string =
  ## Delete one add-on snapshot after reading its userdata again; "" on
  ## success (or when it is already gone).
  let info = s.dir / "info.xml"
  if not fileExists(info): return ""
  if isRunningRoot(site, s):
    return "/ is mounted from it (the host was booted into this snapshot)"
  var ud: tuple[found: bool; value: string]
  try:
    ud = snapperUserdataValue(readFile(info))
  except CatchableError as e:
    return "cannot read " & info & ": " & e.msg
  if not ud.found or ud.value != s.key:
    # Not the snapshot it was a moment ago: never ours to delete.
    return ""
  let r = site.snapper(@["-c", s.config, "delete", $s.number])
  if r.exitCode != 0:
    return "snapper -c " & s.config & " delete " & $s.number & " failed (exit " &
      $r.exitCode & "): " & r.output.strip()
  if fileExists(info):
    return "snapper -c " & s.config & " delete " & $s.number &
      " reported success but the snapshot is still there"
  ""

proc snapshotLeft(s: HostSnapshot; why, by: string): string =
  diagnosticMessage(adSnapshotLeft, "the root snapshot " & s.snapshotName &
    " could not be deleted by " & by & ": " & why &
    "; it is retried by the next recovery or apply")

proc deleteSnapshotByKey*(stateDir, key, by: string; site: SnapshotSite):
    tuple[deleted: seq[string]; left: seq[string]] =
  ## Delete the snapshot(s) carrying ``repro-addon=<key>`` and, once none is
  ## left, the record. ``left`` holds an ``EAddOnSnapshotLeft`` line for
  ## each that could not be deleted (its record stays, for the sweep).
  if not isSnapshotKey(key): return
  var failed = false
  for s in addonSnapshotsOnHost(site):
    if s.key != key: continue
    let why = deleteHostSnapshot(site, s)
    if why.len > 0:
      failed = true
      result.left.add(snapshotLeft(s, why, by))
    else:
      result.deleted.add(s.snapshotName)
  if not failed:
    removeRecord(stateDir, key)

type
  SnapshotOwners* = object
    ## The keys something owns, and whether that is all of them: ``known``
    ## is false when an owner's record could not be read (``unknown`` says
    ## which), and then the sweep deletes nothing.
    keys*: HashSet[string]
    known*: bool
    unknown*: seq[string]

proc retainedOwners*(stateDir: string; current, previous: string;
                     retainedIds: seq[string]; storeListed: bool):
    SnapshotOwners =
  ## The keys owned by a retained committed generation: one with a store
  ## root (``retainedIds``), the current and the previous one; and, when
  ## the store's roots could not be listed, every generation that records
  ## a key. A retained generation whose ownership file cannot be read
  ## makes the result not ``known``.
  result.known = true
  let gens = stateDir / "generations"
  if not dirExists(gens): return
  var keep = initHashSet[string]()
  for g in retainedIds: keep.incl(g)
  if current.len > 0: keep.incl(current)
  if previous.len > 0: keep.incl(previous)
  for kind, d in walkDir(gens):
    if kind != pcDir: continue
    let id = extractFilename(d)
    if storeListed and id notin keep: continue
    let k = readGenerationSnapshotKey(stateDir, id)
    if not k.known:
      result.known = false
      result.unknown.add("generation " & id & "'s " &
        generationSnapshotPath(stateDir, id) & " is unreadable")
    elif k.key.len > 0: result.keys.incl(k.key)

proc markerStateDirs*(applyStateDir: string;
                      pointer = AddonStateDirPointer;
                      pointerOwner = 0): seq[string] =
  ## Where an interrupted add-on switch's marker can be: the state
  ## directory of the apply asking, the add-on's own state directory as
  ## bootstrap recorded it (an add-on bootstrapped with `--state-dir X` is
  ## found even by an apply that was not given X, such as a deploy-agent
  ## tick), the resolved system state directory, and the default.
  ## Deduplicated, in that order.
  for d in [applyStateDir, readAddonStateDirPointer(pointer, pointerOwner),
            resolveSystemStateDir(), SystemStateDir]:
    if d.len > 0 and d notin result: result.add(d)

proc markerOwners*(stateDirs: openArray[string]): SnapshotOwners =
  ## The keys present markers own: the attempt's own snapshot and, for a
  ## revert or its replay, the snapshot of the failed attempt it reverts
  ## (``revert-snapshot``), which only the actor that completes the revert
  ## deletes (§13 decision 105) -- while the marker is there, the revert
  ## has not completed. A marker that cannot be read makes the result not
  ## ``known``.
  result.known = true
  for d in stateDirs:
    if not hasPendingMarker(d): continue
    try:
      let m = readPendingMarker(d)
      if m.rootSnapshot.len > 0: result.keys.incl(m.rootSnapshot)
      when not mutated("snapshot-sweep-ignores-revert-marker"):
        if m.revertSnapshot.len > 0: result.keys.incl(m.revertSnapshot)
    except CatchableError as e:
      result.known = false
      result.unknown.add("the pending marker in " & d & " is unreadable (" &
        e.msg & ")")

proc storeGenerationRoots*(): tuple[ok: bool; ids: seq[string]] =
  ## The generation ids the store holds roots for; ``ok`` false when the
  ## store's roots cannot be listed (no store, an unreadable index).
  if not dirExists(StoreRoot): return (false, @[])
  try:
    (true, generationRoots())
  except CatchableError:
    (false, @[])

proc sweepOrphanSnapshots*(stateDir: string; current, previous: string;
                           markerDirs: openArray[string];
                           site: SnapshotSite;
                           storeRoots = storeGenerationRoots()): seq[string] =
  ## The orphan sweep (§7.2, decision 116), run under the host apply lock
  ## after the pending marker has been decided. Returns what it deleted and
  ## an ``EAddOnSnapshotLeft`` line for each it could not delete.
  ## ``storeRoots`` is the store's generation roots (``ok`` false when they
  ## cannot be listed).
  let records = readRecords(stateDir)
  if records.len == 0: return
  var roots = storeRoots
  when mutated("snapshot-sweep-ignores-retention"):
    roots = (true, newSeq[string]())
  let retained = retainedOwners(stateDir, current, previous, roots.ids,
                                roots.ok)
  let markers = markerOwners(markerDirs)
  if not (retained.known and markers.known):
    # What some owner holds is unknown: deleting anything could delete its
    # way back. Nothing is deleted until the owner can be read again.
    return @[diagnosticMessage(adSnapshotLeft, "the orphan sweep deleted " &
      "nothing: " & (retained.unknown & markers.unknown).join("; "))]
  var owned = retained.keys
  for k in markers.keys: owned.incl(k)
  let onHost = addonSnapshotsOnHost(site)
  for rec in records:
    if rec.key in owned: continue
    var found, running = false
    for s in onHost:
      if s.key == rec.key:
        found = true
        if isRunningRoot(site, s): running = true
    if running:
      # Booted into it: its record predates its own marker in the state it
      # holds. Left alone, and not reported: nothing failed.
      continue
    if not found:
      # Nothing left to delete: a create that never happened, or a
      # snapshot deleted another way. The record goes.
      removeRecord(stateDir, rec.key)
      continue
    let d = deleteSnapshotByKey(stateDir, rec.key, "the orphan sweep", site)
    for n in d.deleted: result.add("deleted the orphan root snapshot " & n)
    result.add(d.left)

proc previousGenerationIn*(stateDir, current: string): string =
  ## The generation ``current`` succeeded; "" for none.
  if current.len == 0: return ""
  try:
    readGenerationEnvelope(pointerPath(stateDir, current)).previousGenerationId
  except CatchableError:
    ""

proc sweepFor*(stateDir: string; markerDirs: openArray[string];
               site = hostSnapshotSite()): seq[string] =
  ## ``sweepOrphanSnapshots`` for the state directory's current and
  ## previous generation. Never raises: a failure is a line.
  try:
    let current = readCurrentGenerationId(stateDir)
    sweepOrphanSnapshots(stateDir, current,
      previousGenerationIn(stateDir, current), markerDirs, site)
  except CatchableError as e:
    @[diagnosticMessage(adSnapshotLeft, "the orphan sweep failed: " & e.msg)]

type
  SnapshotAccount* = object
    ## One add-on snapshot and what owns it (``accountRootSnapshots``).
    snapshot*: HostSnapshot
    owner*: string
      ## ``generation <id>`` (a retained committed generation), ``marker
      ## <state dir>`` (a present marker's attempt), ``orphan`` (recorded by
      ## this state, owned by nothing: the next sweep deletes it) or
      ## ``unrecorded`` (not this state's: never swept)
    running*: bool  ## ``/`` is mounted from it

proc accountRootSnapshots*(stateDir: string; markerDirs: openArray[string];
                           site = hostSnapshotSite();
                           storeRoots = storeGenerationRoots()):
    tuple[snapshots: seq[SnapshotAccount]; missing: seq[string]] =
  ## Every ``repro-addon`` snapshot on the host with its owner, and every
  ## key a retained generation or a present marker owns whose snapshot is
  ## not on the host. What ``repro system addon root-snapshots`` prints.
  let current = readCurrentGenerationId(stateDir)
  let previous = previousGenerationIn(stateDir, current)
  var byKey: seq[tuple[key, owner: string]]
  let gens = stateDir / "generations"
  var keep = initHashSet[string]()
  for g in storeRoots.ids: keep.incl(g)
  if current.len > 0: keep.incl(current)
  if previous.len > 0: keep.incl(previous)
  if dirExists(gens):
    for kind, d in walkDir(gens):
      if kind != pcDir: continue
      let id = extractFilename(d)
      if storeRoots.ok and id notin keep: continue
      let k = generationSnapshotKey(stateDir, id)
      if k.len > 0: byKey.add((k, "generation " & id))
  for d in markerDirs:
    if not hasPendingMarker(d): continue
    try:
      let m = readPendingMarker(d)
      if m.rootSnapshot.len > 0: byKey.add((m.rootSnapshot, "marker " & d))
      if m.revertSnapshot.len > 0:
        byKey.add((m.revertSnapshot, "marker " & d & " (the attempt it reverts)"))
    except CatchableError:
      discard
  byKey.sort(proc (a, b: tuple[key, owner: string]): int = cmp(a.owner, b.owner))
  var recorded = initHashSet[string]()
  for r in readRecords(stateDir): recorded.incl(r.key)
  let onHost = addonSnapshotsOnHost(site)
  for s in onHost:
    var owner = ""
    for o in byKey:
      if o.key == s.key and owner.len == 0: owner = o.owner
    if owner.len == 0:
      owner = if s.key in recorded: "orphan" else: "unrecorded"
    result.snapshots.add(SnapshotAccount(snapshot: s, owner: owner,
                                         running: isRunningRoot(site, s)))
  for o in byKey:
    var found = false
    for s in onHost:
      if s.key == o.key: found = true
    if not found:
      result.missing.add(o.owner & " owns " & SnapperUserdataKey & "=" & o.key &
                         ", which is not on the host")

proc renderRootSnapshots*(a: tuple[snapshots: seq[SnapshotAccount];
                                   missing: seq[string]]): string =
  ## ``<config>#<n> repro-addon=<key> owner=<owner>[ running]`` per line,
  ## then ``missing: ...`` lines.
  for s in a.snapshots:
    result.add(s.snapshot.config & "#" & $s.snapshot.number & " " &
      SnapperUserdataKey & "=" & s.snapshot.key & " owner=" & s.owner &
      (if s.running: " running" else: "") & "\n")
  for m in a.missing: result.add("missing: " & m & "\n")

proc deleteGenerationSnapshots*(stateDir: string; dropped: openArray[string];
                                site: SnapshotSite): seq[string] =
  ## Retention dropped these committed generations: each one's snapshot is
  ## deleted (§7.2). An ``EAddOnSnapshotLeft`` line for each that could not
  ## be; the sweep retries it, since its generation no longer owns it.
  for g in dropped:
    let k = generationSnapshotKey(stateDir, g)
    if k.len == 0: continue
    let d = deleteSnapshotByKey(stateDir, k, "retention", site)
    for n in d.deleted:
      result.add("deleted the root snapshot " & n & " of generation " & g)
    result.add(d.left)

proc deleteEveryAddonSnapshot*(stateDir: string; site: SnapshotSite):
    tuple[deleted: seq[string]; errors: seq[string]] =
  ## Uninstall (§6.4 step 5): every snapshot carrying the ``repro-addon``
  ## userdata in every configuration, recorded or not, and no other.
  when mutated("uninstall-keeps-snapshots"):
    return
  for s in addonSnapshotsOnHost(site):
    let why = deleteHostSnapshot(site, s)
    if why.len > 0:
      result.errors.add(snapshotLeft(s, why, "uninstall"))
    else:
      result.deleted.add(s.snapshotName)
