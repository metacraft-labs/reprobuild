## Garbage-collecting a cargo target directory.
##
## A unit is deleted when ALL of these hold:
##   * its profile directory appears in at least one recorded live set (a
##     target directory the janitor was never told about is left alone, as
##     is anything that is not a cargo profile directory: `test-logs/`,
##     `nextest/`, `flycheck*/` and every other name);
##   * it is in none of the last `keepSets` live sets of that directory;
##   * and it is older than `minAgeSeconds`, OR its toolchain is orphaned: the
##     unit was built by a `rustc` that no retained live set was built by
##     (the equivalent of cargo-sweep's `--installed`), which needs no waiting
##     because nothing can use it any more.
##
## Deleting a unit removes its entries in `deps/`, `.fingerprint/` and
## `build/`, the final artifacts hard-linked out of its `deps/` files, and
## the `incremental/` directories of crates that have no unit left (or more
## directories than units, keeping the newest).
##
## It never runs beside a build: it needs cargo's own `.cargo-lock` of every
## profile directory it touches, non-blocking, and refuses with
## `GcBusyError` when any is held. Cargo takes the same lock for the whole of
## a build, so a janitor that holds it makes a starting build wait for it
## rather than race it.

import std/[algorithm, os, sets, strutils, tables, times]
import repro_core/file_lock
import ./[types, layout, store]

type
  DeletionReason* = enum
    drOutsideLiveSets = "outside the retained live sets"
    drOrphanedToolchain = "built by a toolchain no retained live set used"
    drFinalArtifact = "final artifact of a deleted unit"
    drIncrementalNoUnit = "incremental cache of a crate with no unit left"
    drIncrementalSurplus = "surplus incremental cache"

  Deletion* = object
    path*: string
    bytes*: int64
    reason*: DeletionReason
    profileDir*: string
    unitHash*: string

  GcReport* = object
    targetDir*: string
    dryRun*: bool
    profileDirs*: seq[string]        ## processed
    skippedProfileDirs*: seq[string] ## notes: why a directory was not processed
    deletions*: seq[Deletion]
    unitsKept*: int
    unitsDeleted*: int
    bytesFreed*: int64               ## would free, for a dry run
    errors*: seq[string]             ## deletions that failed

  ProfilePlan = object
    profileDir: string
    deletions: seq[Deletion]
    kept: int
    deleted: int

proc isUnder(root, path: string): bool =
  let r = if root.endsWith($DirSep): root else: root & $DirSep
  path.startsWith(r)

proc entryKind(path: string): PathComponent =
  if symlinkExists(path): pcLinkToFile
  elif dirExists(path): pcDir
  else: pcFile

proc finalArtifactTwins(profileAbsDir: string; deletedFiles: seq[string]):
    seq[string] =
  ## Hard-linked copies, directly in the profile directory, of the `deps/`
  ## files being deleted (`debug/libc1.rlib` next to `deps/libc1-<hash>.rlib`),
  ## and the `<stem>.d` dep-info file cargo writes beside each such copy.
  var wanted = initHashSet[(int64, int64)]()
  for f in deletedFiles:
    let info =
      try: getFileInfo(f, followSymlink = false)
      except OSError: continue
    if info.linkCount > 1:
      wanted.incl (int64(info.id.device), int64(info.id.file))
  if wanted.len == 0: return
  for kind, path in walkDir(profileAbsDir):
    if kind != pcFile: continue
    if fileIdOfPath(path) in wanted:
      result.add path
      # cargo's uplifted dep-info: `<stem>.d`, first token is the artifact.
      let dep = path.changeFileExt("d")
      if dep != path and fileExists(dep) and not symlinkExists(dep):
        try:
          let head = readFile(dep)
          if head.startsWith(path & ":"):
            result.add dep
        except IOError: discard

proc planProfile(targetDir, profileDir: string; sets: seq[LiveSet];
                 config: GcConfig; now: int64): ProfilePlan =
  result.profileDir = profileDir
  let abs = profileAbs(targetDir, profileDir)
  let retained = retainedSets(sets, profileDir, config.keepSets)
  var live = initHashSet[string]()
  var toolchains = initHashSet[string]()
  for s in retained:
    for u in s.units:
      if u.profileDir != profileDir: continue
      live.incl u.hash
      if u.rustcFingerprint.len > 0: toolchains.incl u.rustcFingerprint
  let index = indexProfileDir(abs)

  var survivorCrates = initCountTable[string]()
  var survivorUnknownCrate = false
  var deletedCrates = initHashSet[string]()
  var deletedDepsFiles: seq[string]

  for hash, entries in index:
    var reason = drOutsideLiveSets
    var doDelete = false
    if hash notin live:
      let fp = fingerprintRustcOf(abs, hash, index)
      let orphan = fp.len > 0 and toolchains.len > 0 and fp notin toolchains
      let age = now - entries.newestMtime
      if orphan:
        doDelete = true
        reason = drOrphanedToolchain
      elif age >= config.minAgeSeconds:
        doDelete = true
    if doDelete:
      inc result.deleted
      if entries.crateName.len > 0:
        deletedCrates.incl normalizeCrateName(entries.crateName)
      for path in entries.paths:
        result.deletions.add Deletion(path: path, bytes: treeBytes(path),
          reason: reason, profileDir: profileDir, unitHash: hash)
        if path.parentDir.extractFilename == DepsDir and fileExists(path):
          deletedDepsFiles.add path
    else:
      inc result.kept
      if entries.crateName.len > 0:
        survivorCrates.inc normalizeCrateName(entries.crateName)
      elif entries.compiled:
        # Compiled, yet no `<crate>-<hash>.d` names the crate.
        survivorUnknownCrate = true

  for twin in finalArtifactTwins(abs, deletedDepsFiles):
    # Counted as 0 bytes: it is a hard link of a `deps/` file deleted above,
    # whose bytes are already counted there.
    result.deletions.add Deletion(path: twin, bytes: 0,
      reason: drFinalArtifact, profileDir: profileDir)

  # Incremental caches are named by rustc (`<crate>-<id>`), not by the unit
  # hash, so they are matched to units by crate name. When any surviving unit
  # has no crate name we cannot tell whose cache is whose, and keep them all.
  let incDir = abs / IncrementalDir
  if not survivorUnknownCrate and dirExists(incDir):
    var byCrate = initOrderedTable[string, seq[(int64, string)]]()
    for kind, path in walkDir(incDir):
      if kind != pcDir: continue
      let crate = normalizeCrateName(incrementalCrateName(path.extractFilename))
      if crate.len == 0: continue
      byCrate.mgetOrPut(crate, @[]).add (treeNewestMtime(path, 3), path)
    for crate, dirs in byCrate.mpairs:
      dirs.sort(proc (a, b: (int64, string)): int = cmp(b[0], a[0]))
      let units = survivorCrates.getOrDefault(crate, 0)
      for i, entry in dirs:
        let age = now - entry[0]
        if units == 0:
          if crate in deletedCrates or age >= config.minAgeSeconds:
            result.deletions.add Deletion(path: entry[1],
              bytes: treeBytes(entry[1]), reason: drIncrementalNoUnit,
              profileDir: profileDir)
        elif i >= units and age >= config.minAgeSeconds:
          result.deletions.add Deletion(path: entry[1],
            bytes: treeBytes(entry[1]), reason: drIncrementalSurplus,
            profileDir: profileDir)

proc acquireCargoLocks(targetDir: string; profileDirs: seq[string]):
    seq[ReproFileLock] =
  ## Cargo's `.cargo-lock` of every profile directory (and of the target
  ## root, where cargo versions that have one use it), then the janitor's own
  ## store lock. Non-blocking all of them: all or `GcBusyError`.
  var paths: seq[string]
  if fileExists(targetDir / CargoLockName):
    paths.add targetDir / CargoLockName
  for d in profileDirs:
    paths.add profileAbs(targetDir, d) / CargoLockName
  paths.add storeDir(targetDir) / "lock"
  for path in paths:
    var lock: ReproFileLock
    if tryAcquireExclusiveFileLock(path, lock):
      result.add lock
    else:
      for held in result.mitems: releaseExclusiveFileLock(held)
      var err = newException(GcBusyError,
        "'" & path & "' is locked: a cargo build (or another janitor run) is " &
        "using this target directory; try again when it has finished")
      err.lockPath = path
      raise err

proc deletePath(targetDir: string; d: Deletion; report: var GcReport) =
  ## Remove one planned path; every path must be strictly inside the target
  ## directory, whatever the plan says.
  if not isUnder(targetDir, d.path):
    report.errors.add "refusing to delete outside the target directory: " & d.path
    return
  # The check above is lexical. A `deps/`, `.fingerprint/` or profile
  # directory that is a symlink out of the target directory would pass it
  # while resolving elsewhere, so also require the entry's *parent* to resolve
  # inside the resolved target directory. (The entry itself may be a symlink:
  # removing it removes the link, never its destination.)
  try:
    if not isUnder(expandFilename(targetDir), expandFilename(d.path.parentDir)):
      report.errors.add "refusing to delete through a symlink that leaves " &
        "the target directory: " & d.path
      return
  except OSError as err:
    report.errors.add d.path & ": " & err.msg
    return
  try:
    case entryKind(d.path)
    of pcDir: removeDir(d.path)
    else: removeFile(d.path)
  except OSError as err:
    report.errors.add d.path & ": " & err.msg

proc collectGarbage*(targetDir: string; config: GcConfig;
                     now: int64 = getTime().toUnix): GcReport =
  ## Delete (or, for `config.dryRun`, list) the target directory's stale
  ## units. Raises `GcSetupError` when `targetDir` is unusable or the live-set
  ## store is damaged, and `GcBusyError` when a build holds a lock.
  if config.keepSets < 1:
    raise newException(GcSetupError, "keep-sets must be at least 1")
  if config.minAgeSeconds < 0:
    raise newException(GcSetupError, "min-age must not be negative")
  if not dirExists(targetDir):
    raise newException(GcSetupError,
      "target directory '" & targetDir & "' does not exist")
  let target = absolutePath(targetDir)
  result.targetDir = target
  result.dryRun = config.dryRun

  var problems: seq[string]
  let sets = loadLiveSets(target, problems)
  if problems.len > 0:
    # A damaged record could be one that protected units; delete nothing.
    raise newException(GcSetupError,
      "live-set store is damaged, refusing to delete anything:\n  " &
      problems.join("\n  "))

  var named: seq[string]
  for s in sets:
    for u in s.units:
      if u.profileDir notin named: named.add u.profileDir
  named.sort()
  var todo: seq[string]
  for d in named:
    if isProfileDir(profileAbs(target, d)): todo.add d
    else:
      result.skippedProfileDirs.add d & ": no longer a cargo profile directory"
  if sets.len == 0:
    result.skippedProfileDirs.add "no live set has been recorded: nothing to " &
      "judge the units against (record one with `repro cargo record-live`)"

  var locks: seq[ReproFileLock]
  if not config.dryRun and todo.len > 0:
    locks = acquireCargoLocks(target, todo)
  try:
    for d in todo:
      let plan = planProfile(target, d, sets, config, now)
      result.profileDirs.add d
      result.unitsKept += plan.kept
      result.unitsDeleted += plan.deleted
      for del in plan.deletions:
        result.deletions.add del
        result.bytesFreed += del.bytes
        if not config.dryRun:
          deletePath(target, del, result)
    if not config.dryRun:
      discard pruneLiveSets(target, config.keepSets)
  finally:
    for l in locks.mitems: releaseExclusiveFileLock(l)

proc renderReport*(r: GcReport): string =
  ## Human-readable summary: one line per deleted path, then totals.
  let verb = if r.dryRun: "would delete" else: "deleted"
  for d in r.deletions:
    result.add verb & " " & $d.bytes & " B  " & d.path & "  (" & $d.reason & ")\n"
  for note in r.skippedProfileDirs:
    result.add "skipped: " & note & "\n"
  for e in r.errors:
    result.add "error: " & e & "\n"
  result.add (if r.dryRun: "would free " else: "freed ") & $r.bytesFreed &
    " B in " & $r.deletions.len & " paths; " & $r.unitsDeleted &
    " units " & (if r.dryRun: "to delete" else: "deleted") & ", " &
    $r.unitsKept & " kept, over " & $r.profileDirs.len & " profile dir(s)\n"
