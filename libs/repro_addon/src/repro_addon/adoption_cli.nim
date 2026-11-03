## The command-line verbs of adoption and conversion (ReproOS Add-On Mode
## §11): ``repro system addon import`` (§11.2 step 1) and ``repro system
## addon state`` (the declared state set, §11.1), shared by the static
## add-on binary and the full engine (which also answers ``repro system
## state …``, because a restore runs on a host realised in full).
##
##   repro system addon import --unit <name>
##   repro system addon state backup --profile <file> --out <dir>
##   repro system addon state release --profile <file>
##   repro system addon state verify --from <dir> [--root R] [--only keep|carry] [--source]
##   repro system addon state restore [--from <dir>] [--root R] [--boot]
##   repro system addon state digest <path>
##   repro system addon state unit
##
## Exit status: 0 success; 1 a failure, or a verify that found a
## difference; 2 a usage error or a refusal decided before anything was
## written.

import std/[os, strutils]

import repro_core/source_root
import repro_infra

import ./addon_import
import ./collision
import ./state_sets

const
  StateUsage* = """usage: repro system addon state <command>

  backup --profile <file> --out <dir>
      Back up the profile's state set (spec §11.1): refuses unless every
      unit of the set is stopped, holds each (a drop-in in /etc that
      fails every start; while one exists every apply refuses), archives
      each carried directory and writes the manifest.
  release --profile <file>
      Lift the hold of a backup (an abandoned conversion).
  verify --from <dir> [--root R] [--only keep|carry] [--source]
      Recompute every directory's digest against the manifest in <dir>;
      exit 1 on a difference. --source (on the host the backup was taken
      on, just before the conversion): also exit 1 when a unit of the set
      is no longer held.
  restore [--from <dir>] [--root R] [--boot]
      Restore the carried directories (default dir /var/lib/repro/system/carried);
      --boot (the first-boot unit): nothing to do when there is no manifest.
  digest <path>
      Print a directory's state digest.
  unit
      Print the first-boot restore unit for this binary.
"""
  RestoreUnitName* = "repro-state-restore.service"

proc stateRestoreUnitText*(repro: string): string =
  ## The first-boot unit a conversion installs with the carried directory
  ## (spec §11.1). Ordered before ``sysinit.target``, so every ordinary
  ## service (``DefaultDependencies=yes`` puts it after ``sysinit.target``)
  ## starts after the restore; after ``local-fs.target``, so ``/var`` and
  ## ``/srv`` are mounted. A failed restore fails the unit visibly, and the
  ## apply refuses to start a unit of the pending state either way.
  "[Unit]\n" &
    "Description=Restore carried service state (Reprobuild)\n" &
    "DefaultDependencies=no\n" &
    "Wants=local-fs.target\n" &
    "After=local-fs.target\n" &
    "Before=sysinit.target shutdown.target\n" &
    "Conflicts=shutdown.target\n" &
    "ConditionPathExists=" & CarriedStateDir & "/" & ManifestFileName & "\n" &
    "\n[Service]\n" &
    "Type=oneshot\n" &
    "RemainAfterExit=yes\n" &
    "ExecStart=" & repro & " system state restore --boot\n" &
    "\n[Install]\n" &
    "WantedBy=sysinit.target\n"

proc takeArg(args: seq[string]; i: var int; flag: string): string =
  let a = args[i]
  if a.startsWith(flag & "="): return a[flag.len + 1 .. ^1]
  if i + 1 >= args.len:
    raise newException(ValueError, flag & " needs a value")
  inc i
  args[i]

proc runAddonImportCli*(args: seq[string]): int =
  ## ``repro system addon import --unit <name>``: the skeleton on stdout.
  var unit = ""
  var i = 0
  try:
    while i < args.len:
      let a = args[i]
      if a == "--unit" or a.startsWith("--unit="):
        unit = takeArg(args, i, "--unit")
      else:
        raise newException(ValueError, "unknown option " & a)
      inc i
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

proc runStateCli*(args: seq[string]): int =
  ## ``repro system addon state <verb>`` (and ``repro system state``).
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    stdout.write(StateUsage)
    return (if args.len == 0: 2 else: 0)
  let verb = args[0]
  let rest = args[1 .. ^1]
  var profile, outDir, fromDir, root, only = ""
  var boot = false
  var source = false
  var positional: seq[string]
  try:
    var i = 0
    while i < rest.len:
      let a = rest[i]
      if a == "--profile" or a.startsWith("--profile="):
        profile = takeArg(rest, i, "--profile")
      elif a == "--out" or a.startsWith("--out="):
        outDir = takeArg(rest, i, "--out")
      elif a == "--from" or a.startsWith("--from="):
        fromDir = takeArg(rest, i, "--from")
      elif a == "--root" or a.startsWith("--root="):
        root = takeArg(rest, i, "--root")
      elif a == "--only" or a.startsWith("--only="):
        only = takeArg(rest, i, "--only")
      elif a == "--boot":
        boot = true
      elif a == "--source":
        source = true
      elif a.startsWith("-"):
        raise newException(ValueError, "unknown option " & a)
      else:
        positional.add(a)
      inc i
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
      let dir = if fromDir.len > 0: fromDir else: CarriedStateDir
      if not fileExists(dir / ManifestFileName):
        if boot:
          stdout.write("no carried state at " & dir & "\n")
          return 0
        raise newException(ValueError, "no manifest at " & dir)
      let done = restoreStateSet(dir, root = root)
      for p in done: stdout.write("restored " & p & "\n")
      let left = pendingCarriedState(dir, root)
      if left.len > 0:
        raise newException(StateSetError, $left.len &
          " carried directory(ies) still pending")
      0
    of "digest":
      if positional.len != 1:
        raise newException(ValueError, "digest needs one path")
      stdout.write(treeDigest(positional[0]) & "\n")
      0
    of "unit":
      # The path that re-enters this binary (a launcher's, when the engine
      # runs under one), not the loader `getAppFilename` may name.
      stdout.write(stateRestoreUnitText(publicCliImagePath()))
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
