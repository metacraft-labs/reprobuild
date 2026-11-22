## What a convention's emit-time subprocess read, as the io monitor saw it.
##
## Some Tier 2b conventions run an ecosystem tool inside ``emitFragment`` and
## derive the graph from its output (``go list`` for Go, ``nim c
## --compileOnly`` for Nim). A key over the files the convention expects the
## tool to read is a key over some of its inputs
## (``Core-Invariants.md`` §"One Implementation Per Concern"), so these
## conventions run the tool under the io monitor and key what they derive on
## what it actually read: every file opened, read, probed or executed (a probe
## of an absent path included: the path appearing changes what the tool does),
## every directory enumerated, and every environment variable read
## (``Edge-Derived-Identities.md``; ``Go.md`` §"Implicit-dependency capture";
## ``Nim.md`` §"Cross-module ordering").
##
## This module holds the parts the conventions share:
##   * ``runMonitoredTool`` runs one command under io-mon's in-process host,
##     with its stdout and stderr captured to files, and folds the monitor's
##     records into an ``ObservedReads``;
##   * ``observedStamps``, ``observedStampInputs`` and ``observedReadsInputs``
##     turn a recorded set back into what a later emit compares: file
##     contents, directory memberships, digests of environment values;
##   * ``unstableObservedReads`` tells whether an input changed while the tool
##     was running, in which case what it produced must not be reused;
##   * ``renderObservedReads`` / ``parseObservedReads`` persist a set beside a
##     convention's emit cache, and ``registerObservedReads`` reports it as the
##     fragment's evaluation inputs.

import std/[algorithm, os, strutils, tables, times]

import io_mon
import repro_core
import repro_core/monitor_spawn_stdio
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/conventions/emit_cache
import repro_local_store/pattern_scoped_enumeration

type
  ObservedReads* = object
    ## The reads of one or more monitored runs.
    files*: seq[string]
      ## Absolute paths read, opened, probed or executed, that the runs did
      ## not also write.
    directories*: seq[string]
      ## The directories enumerated: an absolute path for a full listing,
      ## or a pattern-scoped name (``patternScopedEnumerationPath``) for a
      ## scan that kept only the entries matching one glob component, such
      ## as Nim's search of every ancestor of a module's directory for
      ## ``*.nimble``. ``directoryMemberNames`` lists either.
    envNames*: seq[string]
      ## Environment variables the runs read.
    rewritten*: seq[string]
      ## Absolute paths the runs both read and wrote. They are not in
      ## ``files``: what the run read is no longer on disk, so no digest
      ## taken afterwards stands for it.
    incomplete*: seq[string]
      ## Empty when every run was observed completely. Otherwise the
      ## monitor's diagnosis of each run it graded incomplete. The recorded
      ## sets are then a lower bound, not a key, and nothing derived from
      ## the runs may be reused (Failure-Semantics.md §"Monitoring
      ## Failures", unknown-scope loss).

  MonitoredRun* = object
    ## What a monitored command printed, and how it exited. A non-zero exit
    ## is reported here, not raised: the caller words the failure.
    stdout*: string
    stderr*: string
    exitCode*: int

  MonitorUnavailableError* = object of ValueError
    ## The monitor could not be started for a run (no shim, unsupported
    ## host). The command did not run.

const
  DefaultQuiescence* = initDuration(seconds = 2)
    ## How long before a run an input must have been left alone for its
    ## change time alone to show that the run read its current content.
    ## git's "racily clean" window, which the content table applies too
    ## (Caching-Architecture.md §"The per-host content table"): a file system may store
    ## times in whole seconds (two on FAT), and the kernel stamps them from a
    ## coarse clock, so a write that lands just after a run starts can carry
    ## a time from just before it.

proc keepObservedPath*(path: string): bool =
  ## The kernel's pseudo file systems are not inputs a digest can key:
  ## ``/proc`` and ``/sys`` describe the running system, ``/dev`` holds
  ## devices.
  if path.len == 0:
    return false
  when defined(posix):
    for prefix in ["/proc", "/sys", "/dev"]:
      if path == prefix or path.startsWith(prefix & "/"):
        return false
  true

proc addUnique(list: var seq[string]; value: string) =
  if value notin list:
    list.add(value)

proc foldMonitorEvidence*(observed: var ObservedReads;
                          records: openArray[MonitorRecord]; cwd: string;
                          ownPaths: openArray[string]) =
  ## Fold one monitored run's records into ``observed``: every file read,
  ## opened, probed or executed, and every directory enumerated. A path the
  ## run also wrote goes to ``rewritten`` when it read it too, and is
  ## otherwise dropped: it is an output. ``ownPaths`` are the capture files
  ## this process opened for the run; the child never opens them, but they
  ## are excluded explicitly so a backend that reported an inherited
  ## descriptor's path cannot make the key depend on its own output.
  proc material(path: string): string =
    if path.len == 0:
      return ""
    let absolute = if path.isAbsolute: path else: cwd / path
    os.normalizedPath(absolute)
  var written: seq[string] = @[]
  for r in records:
    if r.observationKind in {moFileWrite, moPathMutation}:
      written.addUnique(material(r.path))
  for r in records:
    let path = material(r.path)
    case r.observationKind
    of moFileOpen, moFileRead, moPathProbe, moExecute:
      if keepObservedPath(path) and path notin ownPaths:
        if path in written:
          observed.rewritten.addUnique(path)
        else:
          observed.files.addUnique(path)
    of moDirectoryEnumerate:
      if keepObservedPath(path) and path notin ownPaths:
        # A pattern-scoped scan depends only on the matching entries, as
        # the engine keys it for an action (``io_mon.globScanPattern``).
        let pattern = globScanPattern(r.detail)
        observed.directories.addUnique(
          if pattern.len > 0: patternScopedEnumerationPath(path, pattern)
          else: path)
    of moEnvRead:
      if r.path.len > 0:
        observed.envNames.addUnique(r.path)
    else:
      discard

proc monitorDiagnosis*(capture: MonitorResult): string =
  ## Why a capture was graded incomplete, in the monitor's own words.
  var reasons: seq[string] = @[]
  for r in capture.records:
    if r.observationKind == moEventLoss:
      reasons.add(if r.detail.len > 0: r.detail else: r.path)
  for gap in capture.depFile.capabilityGaps:
    if gap.required:
      reasons.add("required capability missing: " & $gap.capability)
  if reasons.len == 0:
    reasons.add("the monitor graded the capture incomplete without naming " &
      "a loss")
  reasons.join("; ")

proc runMonitoredTool*(argv: seq[string]; cwd, scratchDir, stem,
                       label: string;
                       observed: var ObservedReads): MonitoredRun =
  ## Run ``argv`` from ``cwd`` under io-mon's in-process host and fold what
  ## it read into ``observed``. ``label`` names the command in a diagnosis.
  ##
  ##   * A monitor that cannot be started raises ``MonitorUnavailableError``;
  ##     the command has not run. Whether to refuse or to fall back is the
  ##     convention's policy.
  ##   * A capture graded incomplete is recorded in ``observed.incomplete``;
  ##     its output is still returned.
  ##
  ## io-mon spawns with ``poParentStreams``. On POSIX this process's
  ## descriptors 1 and 2 are pointed at two capture files under
  ## ``scratchDir`` across the spawn (``repro_core/monitor_spawn_stdio``, the
  ## engine's implementation), so the child opens nothing to write them. On
  ## Windows io-mon captures the child's stdout and stderr into one file,
  ## returned as ``stdout``. The capture files are removed afterwards.
  createDir(extendedPath(scratchDir))
  let outPath = scratchDir / (stem & ".stdout")
  let errPath = scratchDir / (stem & ".stderr")
  let depPath = scratchDir / (stem & ".iomon")
  var request = FsSnoopRequest(
    command: argv,
    depFilePath: depPath,
    cwd: cwd,
    streamMode: fsoNone,
    passthroughChildStdout: true,
    passthroughChildStderr: true)
  var monitored: MonitorResult
  try:
    when defined(windows):
      request.captureChildStdio = true
      request.captureStdioPath = outPath
      monitored = runMonitored(request)
    else:
      var ctx = beginMonitorSpawnContext(outPath, errPath)
      var handle: MonitorHandle
      try:
        handle = startMonitor(request)
      finally:
        endMonitorSpawnContext(ctx)
      monitored = finishMonitor(move handle)
  except CatchableError as e:
    raise newException(MonitorUnavailableError,
      "cannot run '" & label & "' under the io monitor: " & e.msg)
  try:
    result.stdout = readFile(extendedPath(outPath))
  except CatchableError:
    result.stdout = ""
  try:
    if fileExists(extendedPath(errPath)):
      result.stderr = readFile(extendedPath(errPath))
  except CatchableError:
    result.stderr = ""
  for path in [outPath, errPath, depPath]:
    try:
      if fileExists(extendedPath(path)):
        removeFile(extendedPath(path))
    except CatchableError:
      discard
  result.exitCode = monitored.exitCode
  if monitored.completeness != mcComplete:
    observed.incomplete.add("'" & label & "': " & monitorDiagnosis(monitored))
  foldMonitorEvidence(observed, monitored.records, cwd,
    [outPath, errPath, depPath])

const DirectoryStampPrefix = "members:"

proc directoryStamp(dir: string): string =
  DirectoryStampPrefix & directoryMemberNames(dir).join("\x1f")

proc stampMembers(stamp: string): seq[string] =
  ## The member names a ``directoryStamp`` holds.
  let names = stamp[DirectoryStampPrefix.len .. ^1]
  if names.len > 0:
    result = names.split('\x1f')

proc fileStamp(path: string): string =
  ## What reading, opening or probing ``path`` finds: the content digest of
  ## a file, ``missing`` when nothing is there, and ``directory`` for a
  ## directory (opened or probed, not listed: its members are not what was
  ## read).
  if dirExists(extendedPath(path)): "directory"
  else: fileContentDigest(path)

proc observedStamps*(observed: ObservedReads): Table[string, string] =
  ## The current state of every recorded file and directory, keyed by its
  ## path (a directory listing by ``"dir:" & <name>``): what ``fileStamp``
  ## finds, and a listing's member names. Taken before a run, these are
  ## what the run is about to read; taken again after it, a difference means
  ## an input changed while the run was reading it
  ## (``unstableObservedReads``).
  for file in observed.files:
    result[file] = fileStamp(file)
  for dir in observed.directories:
    result["dir:" & dir] = directoryStamp(dir)

proc observedStampInputs*(observed: ObservedReads;
                          stamps: Table[string, string]): seq[EmitCacheInput] =
  ## Emit-cache inputs for a recorded set: the membership of every recorded
  ## directory, the value of every recorded environment variable, and what
  ## ``fileStamp`` finds at every recorded file. Stamps already taken are
  ## used as they are, so a convention that needs the stamps themselves does
  ## not hash every file twice; a path missing from ``stamps`` is stamped
  ## now.
  ##
  ## An environment variable enters the key as the digest the evaluation
  ## input records (``hostFactDigest``), never as its value: the key is
  ## written to the sidecar as text, and a variable may hold a secret.
  var dirs = observed.directories
  dirs.sort(system.cmp[string])
  for dir in dirs:
    let key = "dir:" & dir
    let stamp =
      if key in stamps: stamps[key]
      else: directoryStamp(dir)
    result.add(textInput(key & "=" & stamp))
  var names = observed.envNames
  names.sort(system.cmp[string])
  for name in names:
    result.add(textInput("env:" & name & "=" &
      hostFactDigest(EnvironmentHostFactPrefix & name)))
  var files = observed.files
  files.sort(system.cmp[string])
  for file in files:
    let stamp =
      if file in stamps: stamps[file]
      else: fileStamp(file)
    result.add(textInput("file:" & file & "\t" & stamp))

proc observedReadsInputs*(observed: ObservedReads): seq[EmitCacheInput] =
  ## ``observedStampInputs`` over the CURRENT state of every recorded read.
  observedStampInputs(observed, initTable[string, string]())

proc lastChange(path: string): tuple[exists: bool; at: Time] =
  ## The later of a path's modification time and, on POSIX, its status
  ## change time (``st_ctim``, which ``getFileInfo`` reports as
  ## ``creationTime`` there and which user code cannot set back). Windows
  ## reports the creation time in that field, never later than the
  ## modification time. A pattern-scoped name stands for its directory.
  try:
    let info = getFileInfo(extendedPath(patternScopedBase(path)),
      followSymlink = true)
    result.exists = true
    result.at = info.lastWriteTime
    when defined(posix):
      if info.creationTime > result.at:
        result.at = info.creationTime
  except OSError:
    result.exists = false

proc unstableObservedReads*(observed: ObservedReads;
                            before, after: Table[string, string];
                            runStart: Time;
                            quiescence = DefaultQuiescence): seq[string] =
  ## Inputs that may have changed while the run read them, each with the
  ## reason. Empty when what the run read is what is on disk now, so that
  ## stamps taken after the run stand for what it read.
  ##
  ## ``before`` holds ``observedStamps`` taken just before the run started,
  ## for the paths an earlier run read, which the caller knew to stamp;
  ## ``after`` holds them taken after it. A path is unstable when:
  ##   * the run wrote it as well as read it (``observed.rewritten``);
  ##   * it was stamped before the run and its stamp differs now;
  ##   * it is a file stamped before the run whose own change time is after
  ##     ``runStart``: it was rewritten during the run, if only to the same
  ##     bytes;
  ##   * it was not stamped before the run, and it changed less than
  ##     ``quiescence`` before ``runStart`` or later. A time from a coarse
  ##     clock does not show which side of the start such a change was on.
  ## The change time of a directory moves with every entry added or removed,
  ## whether or not the run depends on it, so a directory, listed or not, is
  ## judged by its stamp alone once it has one. Before then it is judged by
  ## its change time like anything else: that is the only evidence a run
  ## that saw it for the first time has, and an unrelated change costs only
  ## that its result is not stored, once. A missing path that is still
  ## missing is stable.
  for path in observed.rewritten:
    result.add(path & ": written by the run that read it")
  proc check(path, key: string; isDirectory: bool;
             reasons: var seq[string]) =
    let change = lastChange(path)
    if key in before:
      if before[key] != after.getOrDefault(key, ""):
        reasons.add(path & ": changed while the run was reading it")
      elif not isDirectory and change.exists and change.at >= runStart:
        reasons.add(path & ": rewritten while the run was reading it")
    elif change.exists and change.at >= runStart - quiescence:
      reasons.add(patternScopedBase(path) & ": changed less than " &
        $quiescence.inSeconds & " s before the run or during it, and no " &
        "earlier run recorded what it held")
  for file in observed.files:
    check(file, file, after.getOrDefault(file, "") == "directory", result)
  for dir in observed.directories:
    check(dir, "dir:" & dir, true, result)

proc renderObservedReads*(observed: ObservedReads): string =
  ## One ``<kind> <path-or-name>`` line per input: ``f`` file, ``d``
  ## directory, ``e`` environment variable, ``w`` rewritten path.
  for f in observed.files: result.add("f " & f & "\n")
  for d in observed.directories: result.add("d " & d & "\n")
  for e in observed.envNames: result.add("e " & e & "\n")
  for w in observed.rewritten: result.add("w " & w & "\n")

proc parseObservedReads*(text: string): ObservedReads =
  for line in text.splitLines():
    if line.len < 3 or line[1] != ' ':
      continue
    let value = line[2 .. ^1]
    case line[0]
    of 'f': result.files.add(value)
    of 'd': result.directories.add(value)
    of 'e': result.envNames.add(value)
    of 'w': result.rewritten.add(value)
    else: discard

proc registerObservedReads*(observed: ObservedReads;
                            unobservedIdentity: string;
                            reusable = true;
                            stamps = initTable[string, string]()) =
  ## Report the recorded reads as the fragment's evaluation inputs
  ## (Project-Provider-Graph-Protocol.md §"Evaluation Inputs"): a changed
  ## file or environment variable re-invokes the convention, a changed
  ## directory membership re-runs the root. Must run inside
  ## ``buildPackageFragment``'s build proc, which resets the registry before
  ## calling it. A path that is a directory when registered is covered by
  ## its enumeration if it was enumerated; a file digest of it would read as
  ## ``missing`` either way.
  ##
  ## ``stamps`` (``observedStamps``) are the states the caller checked when
  ## it decided that the graph stands for these reads: the stamps its key
  ## was computed from. Each input is reported with its stamp, not with what
  ## is on disk when it is registered, so an edit made after that decision
  ## is recorded as a change rather than against a graph derived from the
  ## old content. A path without a stamp is read now.
  ##
  ## When the capture was incomplete, or ``reusable`` is false (the caller
  ## found an input unstable, or could not monitor at all), the recorded
  ## sets are not a key: the fragment is also marked as derived from
  ## unobserved reads, so every refresh produces it again.
  for file in observed.files:
    if file in stamps:
      if stamps[file] != "directory":
        providerRecordedFileInput(file, stamps[file])
    elif not dirExists(extendedPath(file)):
      providerFileInput(file)
  for dir in observed.directories:
    let key = "dir:" & dir
    if key in stamps:
      providerRecordedDirectoryInput(dir, stampMembers(stamps[key]))
    else:
      providerDirectoryInput(dir)
  for name in observed.envNames:
    providerEnvironmentInput(name)
  if observed.incomplete.len > 0 or not reusable:
    providerUnobservedInput(unobservedIdentity)
