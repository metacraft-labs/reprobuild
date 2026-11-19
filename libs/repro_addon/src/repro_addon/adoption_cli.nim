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

import std/[os, strutils]

import repro_core/source_root
import repro_infra

import ./addon_import
import ./collision
import ./host_exec
import ./mutations
import ./state_sets

const
  RestoreUnitName* = CarriedRestoreUnit

proc stateRestoreUnitText*(repro: string; carried: seq[string] = @[]): string =
  ## The first-boot unit a conversion installs with the carried directory
  ## (spec §11.1). Ordered before ``sysinit.target``, so every service with
  ## default dependencies starts after the restore, and ``Before=`` each
  ## carried unit by name, so one without default dependencies does too;
  ## after ``local-fs.target``, so ``/var`` and ``/srv`` are mounted. No
  ## condition on the manifest: ``restore --boot`` decides, and fails when
  ## carried state was installed here but its manifest is gone.
  let before = (when mutated("restore-unordered"): newSeq[string]()
                else: carried)
  "[Unit]\n" &
    "Description=Restore carried service state (Reprobuild)\n" &
    "DefaultDependencies=no\n" &
    "Wants=local-fs.target\n" &
    "After=local-fs.target\n" &
    "Before=sysinit.target shutdown.target" &
      (if before.len > 0: " " & before.join(" ") else: "") & "\n" &
    "Conflicts=shutdown.target\n" &
    "\n[Service]\n" &
    "Type=oneshot\n" &
    "RemainAfterExit=yes\n" &
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

type
  StateCommand* = object
    ## A `repro system addon state <verb>` command line (and `repro system
    ## state <verb>`), as the add-on's parser read it.
    verb*: string
      ## `backup`, `release`, `verify`, `restore`, `digest`, `unit` or
      ## `install-unit`.
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
