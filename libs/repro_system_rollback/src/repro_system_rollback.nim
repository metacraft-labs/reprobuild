## Reprobuild system-scope rollback / switch / list / GC pipeline (B3).
##
## Public surface:
##
##   * ``switchGeneration`` — activate a specific generation. If the
##     transition requires kernel / initramfs / cmdline changes we
##     stage-for-reboot (the GRUB default is flipped + ``staged-next``
##     records the target); otherwise the switch is applied LIVE via
##     ``systemctl daemon-reload`` + targeted unit restarts (skipped
##     when ``--dry-run`` or under the test harness).
##   * ``rollbackGeneration`` — convenience for ``switchGeneration``
##     against the (current - steps) generation.
##   * ``listGenerations`` — surface every recorded generation with
##     timestamp + config hash + current/staged markers.
##   * ``gcGenerations`` — drop generation manifests older than a
##     duration AND not currently referenced (current / staged).
##   * ``bootFailureAutoRollback`` — primitive the systemd watchdog
##     unit invokes when ``multi-user.target`` is not reached within
##     the deadline.
##
## All entry points take the system apply lock for the duration of
## their work (re-using the M62-style ``acquireApplyLock`` from
## ``repro_system_apply.locks``). The functions return structured
## results rather than printing — the CLI in
## ``apps/reproos-rebuild/reproos_rebuild.nim`` is responsible for
## operator output.

import std/[algorithm, os, strutils, times]
from repro_core/paths import extendedPath

import repro_system_apply

# ---------------------------------------------------------------------------
# Result types.
# ---------------------------------------------------------------------------

type
  SwitchMode* = enum
    smLive = "live"               ## activated without reboot
    smStaged = "staged-for-reboot"
                                  ## staged via ``<state>/staged-next``;
                                  ## GRUB default points at the target
    smNoOp = "no-op"              ## the requested target is already
                                  ## ``current``

  SwitchOptions* = object
    stateDir*: string             ## "" -> defaultStateDir()
    bootDir*: string              ## "" -> defaultBootDir()
    runtimeDir*: string           ## "" -> defaultRuntimeDir()
    dryRun*: bool                 ## skip on-disk writes; report what
                                  ## the call would do
    forceReboot*: bool            ## treat the switch as reboot-required
                                  ## even when only systemd / package /
                                  ## user transitions are present
    skipUnitRestart*: bool        ## omit the systemctl daemon-reload
                                  ## + unit restart pass (tests + CI
                                  ## without systemd)
    lockTimeoutSeconds*: int      ## ``0`` -> ``DefaultLockTimeoutSeconds``

  SwitchResult* = object
    mode*: SwitchMode
    fromGeneration*: int
    toGeneration*: int
    reasonForReboot*: string      ## populated when ``mode == smStaged``
    unitsToReload*: seq[string]   ## services whose state differs
                                  ## between from + to generations
    unitsRestarted*: seq[string]  ## under live mode: which units the
                                  ## switch actually restarted (empty
                                  ## on dry-run / skipUnitRestart)
    daemonReloadInvoked*: bool

  RollbackOptions* = object
    stateDir*: string
    bootDir*: string
    runtimeDir*: string
    steps*: int                   ## ``0``/``1`` -> roll back by 1
    dryRun*: bool
    skipUnitRestart*: bool
    lockTimeoutSeconds*: int

  RollbackResult* = object
    switch*: SwitchResult

  GenerationMarker* = enum
    gmCurrent = "current"
    gmStaged = "staged"
    gmNone = "none"

  GenerationSummary* = object
    number*: int
    activationTimestamp*: int64
    activationTimeIso*: string
    kernelName*: string
    cmdlineParts*: seq[string]
    packageCount*: int
    userCount*: int
    serviceCount*: int
    mountCount*: int
    marker*: GenerationMarker
    sourceConfigPath*: string

  GcOptions* = object
    stateDir*: string
    olderThan*: Duration          ## relative to ``now``; generations
                                  ## whose activation predates the
                                  ## cutoff are eligible
    keepCurrent*: bool            ## default true: never drop the
                                  ## confirmed current generation
    keepStaged*: bool             ## default true: never drop a staged
                                  ## generation
    keepMostRecent*: bool         ## default true: defence in depth —
                                  ## never drop the single newest
                                  ## generation, even if it is older
                                  ## than the cutoff
    dryRun*: bool
    lockTimeoutSeconds*: int

  GcDropReason* = enum
    gdrOlderThanCutoff = "older-than-cutoff"
    gdrKeptCurrent = "kept-current"
    gdrKeptStaged = "kept-staged"
    gdrKeptMostRecent = "kept-most-recent"
    gdrKeptInsideCutoff = "kept-inside-cutoff"

  GcEntry* = object
    number*: int
    activationTimestamp*: int64
    dropped*: bool
    reason*: GcDropReason
    path*: string

  GcResult* = object
    entries*: seq[GcEntry]
    droppedCount*: int
    keptCount*: int

  AutoRollbackOptions* = object
    stateDir*: string
    bootDir*: string
    runtimeDir*: string
    deadlineSeconds*: int         ## the watchdog budget; default 60
    dryRun*: bool

  AutoRollbackResult* = object
    triggered*: bool
    fromGeneration*: int
    toGeneration*: int
    reason*: string

# ---------------------------------------------------------------------------
# Internal helpers.
# ---------------------------------------------------------------------------

proc resolveStateDir(stateDir: string): string =
  if stateDir.len > 0: return stateDir
  when defined(windows):
    let lad = getEnv("LOCALAPPDATA")
    if lad.len > 0: lad / "reproos"
    else: getHomeDir() / "reproos-state"
  else:
    "/var/lib/reproos"

proc lockSeconds(s: int): int =
  if s > 0: s else: DefaultLockTimeoutSeconds

proc loadManifestForGen(stateDir: string; n: int):
    SystemConfigManifest =
  let mp = generationDirFor(stateDir, n) / ManifestFileName
  if not fileExists(extendedPath(mp)):
    return newEmptyManifest()
  let body = readFile(extendedPath(mp))
  parseManifest(body)

proc enumGenerationNumbers(stateDir: string): seq[int] =
  let root = generationsRoot(stateDir)
  if not dirExists(extendedPath(root)): return
  for kind, path in walkDir(extendedPath(root)):
    if kind != pcDir: continue
    let name = path.lastPathPart
    try:
      let n = parseInt(name)
      if fileExists(extendedPath(path / ManifestFileName)):
        result.add n
    except ValueError:
      discard
  result.sort()

proc readStagedNext(stateDir: string): int =
  let sp = stagedNextPathFor(stateDir)
  if not fileExists(extendedPath(sp)): return 0
  let raw = readFile(extendedPath(sp)).strip()
  try: parseInt(raw) except ValueError: 0

proc previewServiceState(s: ServiceState): string =
  s.unit & ":" & $s.state

proc differingServices(fromM, toM: SystemConfigManifest): seq[string] =
  var fromMap = newSeq[(string, string)]()
  var toMap = newSeq[(string, string)]()
  for s in fromM.services: fromMap.add (s.unit, $s.state)
  for s in toM.services: toMap.add (s.unit, $s.state)
  # Detect units that appear in to but with a different state, or
  # appear only in one side.
  for (u, st) in toMap:
    var matched = false
    for (u2, st2) in fromMap:
      if u2 == u:
        matched = true
        if st2 != st:
          result.add u
        break
    if not matched:
      result.add u
  for (u, _) in fromMap:
    var stillThere = false
    for (u2, _) in toMap:
      if u2 == u:
        stillThere = true
        break
    if not stillThere:
      result.add u
  result.sort()

proc kernelCmdlineChanged(fromM, toM: SystemConfigManifest): bool =
  fromM.kernelCmdline.parts != toM.kernelCmdline.parts

proc kernelChanged(fromM, toM: SystemConfigManifest): bool =
  fromM.kernel.name != toM.kernel.name

proc rebootReasonFor(fromM, toM: SystemConfigManifest): string =
  if kernelChanged(fromM, toM):
    return "kernel changed: " & fromM.kernel.name & " -> " & toM.kernel.name
  if kernelCmdlineChanged(fromM, toM):
    return "kernel cmdline changed"
  ""

# ---------------------------------------------------------------------------
# Regenerate the GRUB menu after switch / rollback. The pipeline owns
# the per-gen ``<state>/generations/<N>/boot/`` directory; the GRUB
# generator pulls each kernel + cmdline out of those.
# ---------------------------------------------------------------------------

proc rewriteGrubMenuFor(stateDir, bootDir: string;
                       defaultGeneration: int) =
  let inputs = enumerateGenerations(stateDir)
  let body = generateGrubMenu(inputs, defaultGeneration)
  let bootDirAbs = if bootDir.len > 0: bootDir
                   else:
                     when defined(windows):
                       let lad = getEnv("LOCALAPPDATA")
                       if lad.len > 0: lad / "reproos" / "boot"
                       else: getHomeDir() / "reproos-state" / "boot"
                     else:
                       "/boot"
  let grubDir = bootDirAbs / "grub"
  if not dirExists(extendedPath(grubDir)):
    createDir(extendedPath(grubDir))
  writeFile(extendedPath(grubDir / "grub.cfg"), body)

# ---------------------------------------------------------------------------
# Live unit-restart pass. On Linux ``systemctl`` is available; on
# Windows / under tests we record the units we WOULD have touched and
# return without invoking ``systemctl``.
# ---------------------------------------------------------------------------

proc invokeSystemctl(args: openArray[string]; dryRun: bool): bool =
  when defined(windows):
    discard args
    discard dryRun
    return false
  else:
    if dryRun:
      return true
    var cmd = "systemctl"
    var found = ""
    try: found = findExe("systemctl") except OSError: discard
    if found.len == 0:
      return false
    var fullArgs = newSeq[string](args.len)
    for i, a in args: fullArgs[i] = a
    let exitCode = try:
      let cmdline = found & " " & fullArgs.join(" ")
      execShellCmd(cmdline)
    except OSError:
      return false
    return exitCode == 0

# ---------------------------------------------------------------------------
# Public: switchGeneration.
# ---------------------------------------------------------------------------

proc switchGeneration*(targetGen: int;
                      opts: SwitchOptions): SwitchResult =
  ## Activate generation ``targetGen``.
  let stateDir = resolveStateDir(opts.stateDir)
  let lockTimeout = lockSeconds(opts.lockTimeoutSeconds)
  var lock = acquireApplyLock(stateDir, lockTimeout)
  try:
    let knownNums = enumGenerationNumbers(stateDir)
    if targetGen <= 0 or targetGen notin knownNums:
      raiseUnknownGeneration(targetGen, knownNums)
    let current = readCurrentGeneration(stateDir)
    result.fromGeneration = current
    result.toGeneration = targetGen
    if current == targetGen and readStagedNext(stateDir) == 0:
      result.mode = smNoOp
      return
    let fromManifest = if current > 0: loadManifestForGen(stateDir, current)
                       else: newEmptyManifest()
    let toManifest = loadManifestForGen(stateDir, targetGen)
    let units = differingServices(fromManifest, toManifest)
    result.unitsToReload = units
    let rebootReason = rebootReasonFor(fromManifest, toManifest)
    let mustReboot = opts.forceReboot or
      (current > 0 and rebootReason.len > 0)
    if mustReboot:
      result.mode = smStaged
      result.reasonForReboot = if rebootReason.len > 0: rebootReason
                               else: "reboot requested"
      if not opts.dryRun:
        # Stage the target via <state>/staged-next; the operator runs
        # ``reproos-rebuild confirm`` from the systemd unit on the next
        # boot to flip ``<state>/current``. We deliberately do NOT
        # touch the current pointer until confirmStagedGeneration runs.
        let sp = stagedNextPathFor(stateDir)
        if not dirExists(extendedPath(stateDir)):
          createDir(extendedPath(stateDir))
        writeFile(extendedPath(sp), $targetGen & "\n")
        rewriteGrubMenuFor(stateDir, opts.bootDir, targetGen)
      return
    # Live path: flip ``current`` immediately and run the
    # daemon-reload + unit-restart pass.
    if not opts.dryRun:
      let genDir = generationDirFor(stateDir, targetGen)
      rotateCurrentPointer(stateDir, genDir, targetGen)
      # Clear any stale staged-next pointing at the old target.
      let sp = stagedNextPathFor(stateDir)
      if fileExists(extendedPath(sp)):
        try: removeFile(extendedPath(sp)) except OSError: discard
      rewriteGrubMenuFor(stateDir, opts.bootDir, targetGen)
    if not opts.skipUnitRestart and not opts.dryRun:
      if invokeSystemctl(["daemon-reload"], dryRun = false):
        result.daemonReloadInvoked = true
        for u in units:
          discard invokeSystemctl(["restart", u], dryRun = false)
          result.unitsRestarted.add u
    result.mode = smLive
  finally:
    releaseApplyLock(lock)

# ---------------------------------------------------------------------------
# Public: rollbackGeneration.
# ---------------------------------------------------------------------------

proc rollbackGeneration*(opts: RollbackOptions): RollbackResult =
  ## Roll back the active generation by ``opts.steps`` (default 1).
  ## Equivalent to ``switchGeneration(current - steps, ...)``.
  let stateDir = resolveStateDir(opts.stateDir)
  let steps = if opts.steps <= 0: 1 else: opts.steps
  let current = readCurrentGeneration(stateDir)
  if current == 0:
    raiseNoPreviousGeneration("no current generation pointer found")
  # We resolve the target by walking the recorded numbers in descending
  # order and skipping ``steps`` of them BELOW the current one. This
  # tolerates gaps in the generation number sequence (e.g. after a
  # gc(--older-than=0) sweep that removed older generations).
  let nums = enumGenerationNumbers(stateDir)
  if nums.len <= 1:
    raiseNoPreviousGeneration("only one generation is recorded")
  var below: seq[int]
  for n in nums:
    if n < current:
      below.add n
  if below.len == 0:
    raiseNoPreviousGeneration("no generation older than current")
  below.sort()
  let target = if steps - 1 >= below.len: below[0]
               else: below[below.len - steps]
  var so: SwitchOptions
  so.stateDir = opts.stateDir
  so.bootDir = opts.bootDir
  so.runtimeDir = opts.runtimeDir
  so.dryRun = opts.dryRun
  so.skipUnitRestart = opts.skipUnitRestart
  so.lockTimeoutSeconds = opts.lockTimeoutSeconds
  result.switch = switchGeneration(target, so)

# ---------------------------------------------------------------------------
# Public: listGenerations.
# ---------------------------------------------------------------------------

proc listGenerations*(stateDir: string): seq[GenerationSummary] =
  ## Return one ``GenerationSummary`` per recorded generation, ordered
  ## by generation number (ascending). Malformed manifests are
  ## silently skipped — call ``repairPartialApply`` first to surface
  ## them.
  let dir = resolveStateDir(stateDir)
  let current = readCurrentGeneration(dir)
  let staged = readStagedNext(dir)
  for n in enumGenerationNumbers(dir):
    let m = loadManifestForGen(dir, n)
    if m.isEmptyManifest: continue
    var summary = GenerationSummary(number: n,
      activationTimestamp: m.activationTimestamp,
      activationTimeIso: m.activationTimeIso,
      kernelName: m.kernel.name,
      cmdlineParts: m.kernelCmdline.parts,
      packageCount: m.packages.len,
      userCount: m.users.len,
      serviceCount: m.services.len,
      mountCount: m.mounts.len,
      sourceConfigPath: m.sourceConfigPath)
    summary.marker =
      if n == current: gmCurrent
      elif n == staged: gmStaged
      else: gmNone
    result.add summary

# ---------------------------------------------------------------------------
# Public: gcGenerations.
# ---------------------------------------------------------------------------

proc removeGenerationDir(stateDir: string; n: int): tuple[ok: bool, path: string] =
  let path = generationDirFor(stateDir, n)
  if not dirExists(extendedPath(path)):
    return (false, path)
  try:
    removeDir(extendedPath(path))
    return (true, path)
  except OSError:
    return (false, path)

proc gcGenerations*(opts: GcOptions): GcResult =
  ## Drop every recorded generation older than ``opts.olderThan`` that
  ## is NOT marked ``current``, NOT marked ``staged``, AND NOT the
  ## single most-recent generation. Returns the per-generation
  ## decision so the CLI can echo the reasoning.
  ##
  ## ``opts.keepCurrent`` / ``opts.keepStaged`` / ``opts.keepMostRecent``
  ## are reserved for future "force-drop" overrides; for B3 we always
  ## treat them as ``true`` (defence in depth — the user requested
  ## ``--older-than=0`` should not be able to brick the box).
  let stateDir = resolveStateDir(opts.stateDir)
  let lockTimeout = lockSeconds(opts.lockTimeoutSeconds)
  var lock = acquireApplyLock(stateDir, lockTimeout)
  try:
    let current = readCurrentGeneration(stateDir)
    let staged = readStagedNext(stateDir)
    let nums = enumGenerationNumbers(stateDir)
    if nums.len == 0: return
    let newest = nums[^1]
    let cutoff = getTime() - opts.olderThan
    let cutoffUnix = cutoff.toUnix
    for n in nums:
      let m = loadManifestForGen(stateDir, n)
      var entry = GcEntry(number: n,
        activationTimestamp: m.activationTimestamp,
        path: generationDirFor(stateDir, n))
      if n == current:
        entry.reason = gdrKeptCurrent
        result.entries.add entry
        inc result.keptCount
        continue
      if n == staged:
        entry.reason = gdrKeptStaged
        result.entries.add entry
        inc result.keptCount
        continue
      if n == newest:
        entry.reason = gdrKeptMostRecent
        result.entries.add entry
        inc result.keptCount
        continue
      if m.activationTimestamp >= cutoffUnix:
        entry.reason = gdrKeptInsideCutoff
        result.entries.add entry
        inc result.keptCount
        continue
      entry.reason = gdrOlderThanCutoff
      if not opts.dryRun:
        let outcome = removeGenerationDir(stateDir, n)
        entry.dropped = outcome.ok
      else:
        entry.dropped = true
      if entry.dropped: inc result.droppedCount
      else: inc result.keptCount
      result.entries.add entry
  finally:
    releaseApplyLock(lock)

# ---------------------------------------------------------------------------
# Public: bootFailureAutoRollback.
# ---------------------------------------------------------------------------

proc bootFailureAutoRollback*(opts: AutoRollbackOptions): AutoRollbackResult =
  ## Invoked by the ``reproos-boot-once-watchdog`` systemd unit when
  ## ``multi-user.target`` is not reached within the budget. The
  ## staged generation (if any) is rolled back: ``<state>/staged-next``
  ## is cleared, the GRUB menu's default flips back to the previously
  ## confirmed ``current`` generation. A subsequent reboot loads the
  ## previous kernel.
  let stateDir = resolveStateDir(opts.stateDir)
  let staged = readStagedNext(stateDir)
  if staged == 0:
    result.reason = "no staged generation; nothing to roll back"
    return
  let current = readCurrentGeneration(stateDir)
  result.fromGeneration = staged
  result.toGeneration = current
  if opts.dryRun:
    result.triggered = true
    result.reason = "dry-run: would clear staged-next " & $staged
    return
  var lock = acquireApplyLock(stateDir, DefaultLockTimeoutSeconds)
  try:
    let sp = stagedNextPathFor(stateDir)
    if fileExists(extendedPath(sp)):
      try: removeFile(extendedPath(sp)) except OSError: discard
    if current > 0:
      rewriteGrubMenuFor(stateDir, opts.bootDir, current)
    elif enumGenerationNumbers(stateDir).len > 0:
      let nums = enumGenerationNumbers(stateDir)
      rewriteGrubMenuFor(stateDir, opts.bootDir, nums[^1])
    result.triggered = true
    result.reason = "watchdog fired after " & $opts.deadlineSeconds &
      "s without multi-user.target; staged generation " & $staged &
      " disabled, GRUB default = generation " & $current
  finally:
    releaseApplyLock(lock)
