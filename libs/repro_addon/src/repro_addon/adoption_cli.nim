## The command-line verbs of adoption and conversion (ReproOS Add-On Mode
## §11): ``repro system addon import`` (§11.2 step 1) and ``repro system
## addon state`` (the declared state set, §11.1), shared by the static
## add-on binary and the full engine (which also answers ``repro system
## state …``, because a restore runs on a host realised in full).
##
## Their command lines are declared in ``repro_infra/addon_command_line``
## and read by the parser generated from it (``repro_addon/cli``), which
## hands the procs below their typed values; `repro system addon state
## --help` prints what each verb takes.
##
## Exit status: 0 success; 1 a failure, or a verify that found a
## difference; 2 a usage error or a refusal decided before anything was
## written.

import std/[algorithm, os, posix, strutils, tables]

import repro_core/source_root
import repro_infra

import ./addon_import
import ./collision
import ./host_exec
import ./mutations
import ./state_sets
import ./static_tree

const
  RestoreUnitName* = CarriedRestoreUnit

const RestoreStartTimeout* = "90min"
  ## The restore unit's start timeout (§13 decision 191). A oneshot has no
  ## start timeout by default, so a hung extraction would leave the boot
  ## reporting the restore as starting for ever. 90 minutes is §7.7's bound
  ## on a boot-time recovery, and covers the largest archive a conversion is
  ## expected to carry: a validator's or a beacon node's data directory of a
  ## few hundred GB, read and verified at disk speed (well over 100 MB/s on
  ## the hosts the add-on supports). A restore that needs longer fails at
  ## every boot until an operator runs ``repro system state restore`` by
  ## hand, which has no timeout.

proc stateRestoreUnitText*(repro: string; carried: seq[string] = @[]): string =
  ## The first-boot unit a conversion installs with the carried directory
  ## (spec §11.1). Ordered ``Before=`` each carried unit by name, so one
  ## without default dependencies waits for it too, and every carried unit
  ## requires it by its own drop-in; after ``local-fs.target``, so ``/var``
  ## and ``/srv`` are mounted. Not before ``sysinit.target`` (§13 decision
  ## 191, the owner's "both", 2026-11-25): a hung restore held every unit
  ## with default dependencies -- sshd among them -- with no way in; the
  ## units decision 60 leaves out of the requirement now run beside the
  ## restore, which therefore refuses a target that fills while it runs
  ## (``restoreStateSet``). Bounded by ``RestoreStartTimeout``: a restore
  ## that does not finish fails, its carried units stay down, and the boot
  ## goes on. No condition on the manifest: ``restore --boot`` decides, and
  ## fails when carried state was installed here but its manifest is gone.
  let before = (when mutated("restore-unordered"): newSeq[string]()
                else: carried)
  let sysinit = (when mutated("restore-holds-sysinit"): "sysinit.target "
                 else: "")
  "[Unit]\n" &
    "Description=Restore carried service state (Reprobuild)\n" &
    "DefaultDependencies=no\n" &
    "Wants=local-fs.target\n" &
    "After=local-fs.target\n" &
    "Before=" & sysinit & "shutdown.target" &
      (if before.len > 0: " " & before.join(" ") else: "") & "\n" &
    "Conflicts=shutdown.target\n" &
    "\n[Service]\n" &
    "Type=oneshot\n" &
    "RemainAfterExit=yes\n" &
    (when mutated("restore-unbounded"): ""
     else: "TimeoutStartSec=" & RestoreStartTimeout & "\n") &
    "ExecStart=" & repro & " system state restore --boot\n" &
    "\n[Install]\n" &
    "WantedBy=sysinit.target\n"

proc restoreRequiredDropInText*(): string =
  ## ``carried_state.restoreRequirementText``: the bytes ``install-unit``
  ## writes as ``RestoreRequiredDropIn`` and a generation writes for every
  ## unit reaching carried state.
  restoreRequirementText()

proc installRestoreUnit*(dir, repro: string; root = "/"): seq[string] =
  ## Install the first-boot restore unit under ``root`` (enabled: a link in
  ## ``sysinit.target.wants``), record that carried state is installed at
  ## ``dir`` (``installedMarkerPath``: from now on a missing manifest there
  ## refuses every apply and fails the restore), and give each unit of the
  ## carried directories a drop-in requiring the restore. Returns those
  ## units. The boot path is then governed by the restore as the apply path
  ## is by ``carried_state``. Run on the converted host, which applies in
  ## full: on an add-on host the add-on's effective-unit check would refuse
  ## the drop-in (spec §10.1), which fails closed.
  let m = readStateManifest(dir)
  var units: seq[string]
  for e in m.entries:
    if e.disposition != sdCarry: continue
    for u in e.units:
      if u notin units: units.add(u)
  let unitDir = root / "etc/systemd/system"
  createDir(unitDir)
  writeFile(unitDir / RestoreUnitName, stateRestoreUnitText(repro, units))
  proc linkInto(d: string) =
    createDir(d)
    let link = d / RestoreUnitName
    if symlinkExists(link) or fileExists(link): removeFile(link)
    createSymlink("/etc/systemd/system/" & RestoreUnitName, link)
  linkInto(unitDir / "sysinit.target.wants")
  # ``dir`` is the carried directory as this process sees it (under
  # ``root`` already, ``runStateCommand``), so its marker is beside it.
  let marker = installedMarkerPath(dir)
  createDir(marker.parentDir)
  writeFile(marker, dir & "\n")
  for u in units:
    when mutated("restore-not-required-by-units"):
      discard
    elif mutated("restore-required-by-link"):
      # FALSIFYING MUTATION: round 2's link, removed by a disable.
      linkInto(unitDir / (u & ".requires"))
    else:
      let d = unitDir / (u & ".d")
      createDir(d)
      writeFile(d / RestoreRequiredDropIn, restoreRequiredDropInText())
  units

const RetiredRecordName* = "carried.retired"
  ## Beside the marker: ``retireCarriedState`` writes it before the commit
  ## point and completes it after the cleanup (§13 decision 194).

proc retiredRecordPath*(dir: string): string =
  ## ``carried.retired`` beside the carried directory ``dir``.
  parentDir(installedMarkerPath(dir)) / RetiredRecordName

proc fsyncDir(d: string) =
  let fd = posix.open(d.cstring, O_RDONLY or O_CLOEXEC)
  if fd < 0: raiseOSError(osLastError(), "open " & d)
  let r = fsync(fd)
  let err = osLastError()
  discard posix.close(fd)
  if r != 0: raiseOSError(err, "fsync " & d)

proc writeDurably(path, text: string) =
  let tmp = path & ".tmp"
  writeFile(tmp, text)
  let fd = posix.open(tmp.cstring, O_RDONLY or O_CLOEXEC)
  if fd < 0: raiseOSError(osLastError(), "open " & tmp)
  let r = fsync(fd)
  let err = osLastError()
  discard posix.close(fd)
  if r != 0: raiseOSError(err, "fsync " & tmp)
  moveFile(tmp, path)
  fsyncDir(parentDir(path))

proc retireRefusal*(dir, root, stateDir: string): string =
  ## Why carried state at ``dir`` may not be retired now (§13 decision
  ## 194), or "": it must be installed (marker and manifest), every
  ## carried entry restored and identified by the receipt -- a restore has
  ## succeeded since the conversion -- and no add-on switch nor full apply
  ## be pending.
  if not fileExists(installedMarkerPath(dir)):
    return "carried state is not installed at " & dir &
      " (no " & installedMarkerPath(dir) & "); nothing to retire"
  if not fileExists(dir / ManifestFileName):
    return "carried state was installed at " & dir &
      " but its manifest is missing; a restore cannot have been confirmed"
  when not mutated("retire-without-confirmed-restore"):
    let m = readStateManifest(dir)
    let receipt = readReceipt(dir)
    var unconfirmed: seq[string]
    for e in m.entries:
      if e.disposition != sdCarry: continue
      if e.path notin receipt or receipt[e.path].digest != e.digest:
        unconfirmed.add(e.path)
    for e in pendingCarriedState(dir, root):
      if e.path notin unconfirmed: unconfirmed.add(e.path)
    if unconfirmed.len > 0:
      return "no confirmed restore of " & unconfirmed.join(", ") &
        " since the conversion (the receipt beside the manifest does not " &
        "identify it as restored); run `repro system state restore` and " &
        "retire after it succeeds"
  if hasPendingMarker(stateDir):
    return "an add-on switch is pending on this host (" & stateDir &
      "); recover it first"
  if readLiveCheckUnits(stateDir).len > 0 or
      readLiveCheckTriggers(stateDir).len > 0:
    return "a full apply died under its carried-state hold (its records " &
      "in " & stateDir & "); run the next apply first"
  ""

proc requirementDropIns*(root: string): seq[string] =
  ## Every per-unit restore requirement under ``root``'s
  ## ``/etc/systemd/system``: ``install-unit``'s ``80-repro-state-restore.conf``
  ## and the generations' ``50-repro-state-restore.conf``.
  let unitDir = root / "etc/systemd/system"
  if not dirExists(unitDir): return
  for kind, d in walkDir(unitDir):
    if kind != pcDir or not d.endsWith(".d"): continue
    for name in [RestoreRequiredDropIn, "50-repro-" & RequirementDropInName & ".conf"]:
      when mutated("retire-leaves-requirements"):
        # FALSIFYING MUTATION: only install-unit's drop-ins are removed.
        if name != RestoreRequiredDropIn: continue
      if fileExists(d / name): result.add(d / name)
  result.sort()

proc retireCarriedState*(dir, root, stateDir: string;
                         reload: proc () {.closure.} = nil;
                         crashAt: proc (point: string) {.closure.} = nil):
    seq[string] =
  ## ``repro system state retire`` (§13 decision 194): end the carried-state
  ## protection once a restore has succeeded. Returns what it removed.
  ## Order: the record that the retire began (durable), the marker (the
  ## commit point: before it the host keeps every protection), then every
  ## restore requirement, then the restore unit and its link, then the
  ## reload and the completed record. A crash after the commit point
  ## leaves only requirements on a restore that succeeds -- fail-closed --
  ## and a second run finishes. ``crashAt`` is a test seam: it is called
  ## after each step with its name, and may raise.
  let marker = installedMarkerPath(dir)
  let record = retiredRecordPath(dir)
  let resuming = not fileExists(marker) and fileExists(record)
  if not resuming:
    let why = retireRefusal(dir, root, stateDir)
    if why.len > 0: raise newException(StateSetError, why)
  proc step(point: string) =
    if crashAt != nil: crashAt(point)
  proc dropRequirements(): seq[string] =
    for f in requirementDropIns(root):
      removeFile(f)
      result.add(f)
      let d = parentDir(f)
      var empty = true
      for _ in walkDir(d):
        empty = false
        break
      if empty: removeDir(d)
    step("requirements-removed")
  if not resuming:
    writeDurably(record, "retiring " & dir & "\n")
    step("record-written")
    when mutated("retire-requirements-first"):
      # FALSIFYING MUTATION: the requirements go before the marker.
      result.add(dropRequirements())
    removeFile(marker)
    fsyncDir(parentDir(marker))
    result.add(marker)
    step("marker-removed")
  when not mutated("retire-requirements-first"):
    result.add(dropRequirements())
  else:
    if resuming: result.add(dropRequirements())
  let unitDir = root / "etc/systemd/system"
  for f in [unitDir / "sysinit.target.wants" / RestoreUnitName,
            unitDir / RestoreUnitName]:
    if symlinkExists(f) or fileExists(f):
      removeFile(f)
      result.add(f)
  step("unit-removed")
  if reload != nil: reload()
  writeDurably(record, "retired " & dir & "\n")

type
  StateCommand* = object
    ## A `repro system addon state <verb>` command line (and `repro system
    ## state <verb>`), as the add-on's parser read it.
    verb*: string
      ## `backup`, `release`, `verify`, `restore`, `digest`, `unit`,
      ## `install-unit` or `retire`.
    profile*, outDir*, fromDir*, root*, only*, path*: string
      ## ``--profile``, ``--out``, ``--from``, ``--root``, ``--only`` and
      ## `digest`'s directory; empty when the verb was not given one.
    boot*, source*: bool
      ## ``--boot`` (`restore`) and ``--source`` (`verify`).

proc runAddonImport*(unit: string): int =
  ## ``repro system addon import --unit <name>``: the skeleton on stdout.
  try:
    if unit.len == 0:
      raise newException(ValueError, "--unit <name> is required")
    let sk = importUnit(ImportObserver(root: "/",
                                       driver: detectCollisionDriver()), unit)
    stdout.write(sk.text)
    0
  except ValueError as e:
    stderr.write("repro system addon import: " & e.msg & "\n")
    2
  except ImportError as e:
    stderr.write("repro system addon import: " & e.msg & "\n")
    2
  except CatchableError as e:
    stderr.write("repro system addon import: " & e.msg & "\n")
    1

proc runStateCommand*(c: StateCommand): int =
  ## ``repro system addon state <verb>`` (and ``repro system state``).
  let verb = c.verb
  let profile = c.profile
  let outDir = c.outDir
  let fromDir = c.fromDir
  let only = c.only
  let boot = c.boot
  let source = c.source
  var root = c.root
  try:
    if root.len > 0 and not root.isAbsolute:
      raise newException(ValueError, "--root must be an absolute path")
    if root.len == 0: root = "/"
    case verb
    of "backup":
      if profile.len == 0 or outDir.len == 0:
        raise newException(ValueError, "backup needs --profile and --out")
      let p = parseSystemProfile(readFile(profile))
      let m = backupStateSet(p, outDir, readFile("/etc/hostname").strip(),
                             root = root)
      for e in m.entries:
        stdout.write($e.disposition & " " & e.path & " " & e.digest &
          (if e.archive.len > 0: " " & e.archive else: "") & "\n")
      stdout.write("held until the next boot: " &
        (block:
          var us: seq[string]
          for e in m.entries:
            for u in e.units:
              if u notin us: us.add(u)
          us.join(", ")) & "\n")
      0
    of "release":
      if profile.len == 0:
        raise newException(ValueError, "release needs --profile")
      var units: seq[string]
      for e in stateSetOf(parseSystemProfile(readFile(profile))):
        for u in e.units:
          if u notin units: units.add(u)
      releaseUnits(units)
      0
    of "verify":
      if fromDir.len == 0:
        raise newException(ValueError, "verify needs --from")
      let set = case only
        of "": {sdKeep, sdCarry}
        of "keep": {sdKeep}
        of "carry": {sdCarry}
        else: raise newException(ValueError, "--only is keep or carry")
      let m = readStateManifest(fromDir)
      let r = verifyEntries(m, root, set)
      for p in r.matched: stdout.write("ok " & p & "\n")
      for d in r.differing: stdout.write("DIFFERS " & d & "\n")
      if source:
        # On the source host just before the conversion: every unit of the
        # set must still be held (`systemctl revert` deletes drop-ins).
        var units: seq[string]
        for e in m.entries:
          for u in e.units:
            if u notin units: units.add(u)
        for u in holdsNotLoaded(units):
          stdout.write("HOLD MISSING " & u & "\n")
          return 1
      (if r.differing.len == 0: 0 else: 1)
    of "restore":
      # Without --from, the carried directory of the system under --root
      # (A13 review round 5, finding 8).
      let dir = if fromDir.len > 0: fromDir
                else: (when mutated("install-unit-reads-host-manifest"):
                         CarriedStateDir
                       else: under(root, CarriedStateDir))
      if not fileExists(dir / ManifestFileName):
        if boot and not fileExists(installedMarkerPath(dir)):
          stdout.write("no carried state at " & dir & "\n")
          return 0
        if boot:
          raise newException(StateSetError, "carried state was installed " &
            "at " & dir & " but its manifest is missing")
        raise newException(ValueError, "no manifest at " & dir)
      let done = restoreStateSet(dir, root = root)
      for p in done: stdout.write("restored " & p & "\n")
      let left = pendingCarriedState(dir, root)
      if left.len > 0:
        raise newException(StateSetError, $left.len &
          " carried directory(ies) still pending")
      0
    of "digest":
      if c.path.len == 0:
        raise newException(ValueError, "digest needs one path")
      stdout.write(treeDigest(c.path) & "\n")
      0
    of "unit":
      # The path that re-enters this binary (a launcher's, when the engine
      # runs under one), not the loader `getAppFilename` may name.
      stdout.write(stateRestoreUnitText(publicCliImagePath()))
      0
    of "install-unit":
      # One location: the restore unit's `restore --boot` and every apply
      # read the default directory, so another one would leave both guards
      # looking at nothing.
      if fromDir.len > 0 and fromDir.strip(leading = false, chars = {'/'}) !=
          CarriedStateDir:
        raise newException(ValueError, "install-unit reads " &
          CarriedStateDir & " (the directory the restore unit and every " &
          "apply use); move the carried state there instead of --from " &
          fromDir)
      # The system under --root: its manifest, its unit, its marker (A13
      # review round 5, finding 8).
      let dir = when mutated("install-unit-reads-host-manifest"): CarriedStateDir
                else: under(root, CarriedStateDir)
      let units = installRestoreUnit(dir, publicCliImagePath(), root)
      stdout.write("installed " & RestoreUnitName & "; required by: " &
        units.join(", ") & "\n")
      if root == "/":
        let r = runSystemctl(["daemon-reload"])
        if r.exitCode != 0:
          raise newException(StateSetError, "systemctl daemon-reload " &
            "failed: " & r.output)
      0
    of "retire":
      # The carried directory of the system under --root, as install-unit
      # and restore read it (§13 decision 194).
      if fromDir.len > 0:
        raise newException(ValueError, "retire reads " & CarriedStateDir &
          ", the directory install-unit installed; it takes no --from")
      let dir = under(root, CarriedStateDir)
      let stateDir = under(root, osDefaultSystemStateDir())
      let removed = retireCarriedState(dir, root, stateDir,
        reload = (if root == "/":
                    proc () =
                      let r = runSystemctl(["daemon-reload"])
                      if r.exitCode != 0:
                        raise newException(StateSetError, "systemctl " &
                          "daemon-reload failed: " & r.output)
                  else: nil))
      for f in removed: stdout.write("removed " & f & "\n")
      stdout.write("carried state retired at " & dir & "\n")
      0
    else:
      raise newException(ValueError, "unknown state command " & verb)
  except ValueError as e:
    stderr.write("repro system addon state: " & e.msg & "\n")
    2
  except ESystemProfileInvalid as e:
    stderr.write("repro system addon state: " & e.msg & "\n")
    2
  except StateSetError as e:
    stderr.write("repro system addon state " & verb & ": " & e.msg & "\n")
    1
  except CatchableError as e:
    stderr.write("repro system addon state " & verb & ": " & e.msg & "\n")
    1
