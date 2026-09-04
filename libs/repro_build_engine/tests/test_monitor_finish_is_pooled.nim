## Engine-Threadpool TP-2 — ``finishMonitor`` on the pool.
##
## WHAT IS BEING PINNED, and why each case is shaped the way it is.
##
## TP-2 moves the monitor's post-exit evidence assembly off the scheduler's
## poll loop and onto TP-1's worker pool. Two properties have to hold, and
## they are the two the milestone names:
##
##   * THE EVIDENCE IS UNCHANGED. A pooled finish must produce the same
##     dependency evidence as the batch reference form — io-mon's
##     ``runMonitored``, which is what the ``repro internal io monitor``
##     wrapper runs — INCLUDING for a detached descendant. Agreeing on
##     ``mcComplete`` proves nothing, which is why the headline case holds a
##     real descendant alive across the §4.1 grace window and requires BOTH
##     forms to grade the edge ``mcIncomplete``.
##   * A POOLED FINISH DOES NOT WIDEN THE GRACE WINDOW. DH-3/DH-4 measured
##     that the §4.1 detached-descendant window OPENS when ``finishMonitor``
##     runs, so WHEN a worker gets to it is part of the evidence: a monitor
##     left sitting grades a descendant that dies in the interval
##     ``mcComplete`` where the reference grades it ``mcIncomplete`` — the
##     wrong direction to err. HM-4 finishes on the poll pass that first
##     observes exit for exactly this reason, and a pool must not silently
##     lengthen that interval. So the TIMING is asserted, not only the output.
##
## NO MOCKS. Every case runs a real build, with a real monitored child, a real
## LD_PRELOAD shim, a real detached descendant held alive across a real grace
## window, and a real ``.iomon`` decoded with io-mon's own reader. The
## reference arm is the shipped wrapper, not a reimplementation of it. The one
## thing configured rather than observed is the pool's WORKER COUNT, which is
## a shipped knob (``configureEnginePool`` / ``REPROBUILD_ENGINE_POOL_WORKERS``)
## and is what the sensitivity control in the timing case is built from.
##
## HOW A RUN IS JUDGED. By its EXIT CODE, never by its label counts: a SIGSEGV
## exits 1 while printing ``0 [FAILED]``, which is exactly how a concurrency
## crash hides. Every assertion helper below is a ``template`` for the sibling
## reason — ``check`` inside a plain ``proc`` prints "Check failed" and the
## case still reports ``[OK]``.
##
## WHAT THE COMPARISON DELIBERATELY DOES NOT DO, declared rather than left to
## be discovered. DH-4 compares two record streams IN ORDER, because both of
## its runs are performed by one process. Here the two arms are merged by
## DIFFERENT host processes — the engine on one side, a ``repro internal io
## monitor`` child on the other — and nothing requires two hosts to interleave
## fragments from independent producer threads identically. So the records are
## compared as a normalised MULTISET and ``MonitorRecord.seq`` (the merge's own
## canonical index, which is a function of that interleaving) is not part of
## the rendering. Everything else about every record is: the renderer walks
## ``fieldPairs``, so a field added to ``MonitorRecord`` later is compared
## without anyone remembering to add it.
##
## AND ONE THING THE COMPARISON HAD TO BE TOLD, because the first run of it
## found a PRE-EXISTING divergence between the two hosting forms that has
## nothing to do with TP-2. The engine reduces io-mon's event interest to
## ``{ecFileDeps, ecProcessTree, ecLibraryLoads}`` for a build edge, on the
## grounds that an edge depends on the files it reads and not on the clock or
## the sysctls a tool happens to touch. On the HOSTED path that reduction is
## carried on ``FsSnoopRequest.interest`` and takes effect. On the WRAPPED
## path the engine can only seed ``REPRO_MONITOR_INTEREST`` into the action's
## environment — and io-mon's ``composeInjectionEnv`` OVERWRITES that variable
## with the request's own interest, which for ``repro internal io monitor``
## is ``FullInterest`` because the CLI takes no interest flag. So the wrapped
## arm records ``mrSysctlRead`` / ``mrTimeRead`` that the hosted arm does not:
## measured here as 142 records against 140 for the identical fixture, with
## ``sysconf:1`` and a time read the only difference.
##
## That is a real finding about the engine's env seed (whose comment says
## "same event-interest as the hosted path") and it is reported as one rather
## than worked around silently. What this file does about it is make the two
## arms ASK FOR THE SAME THING: the fixture opts into ``captureNonDeterminism``
## and ``captureIpc``, so the hosted request is ``FullInterest`` too and the
## comparison is about where ``finishMonitor`` ran rather than about which
## categories were requested. HM-6's field-by-field comparison could not see
## this difference at all, because ``PathSetEvidence`` has no field a sysctl
## read lands in.

import std/[algorithm, os, sets, strutils, tables, unittest]

import repro_build_engine
import repro_build_engine/worker_pool
from repro_test_support import prepareMonitorTools, testCaseScratchSlug
from repro_core/dependency_gathering import DependencyGatheringPolicy,
  automaticMonitorGatheringPolicy

when defined(linux) or defined(macosx):
  import io_mon

template checkOrEcho(cond: untyped; msg: string) =
  ## `check` inside a plain `proc` prints "Check failed" and still reports
  ## `[OK]`, so every helper that asserts in this file is a template.
  if not (cond):
    echo msg
  check cond

when not (defined(linux) or defined(macosx)):
  suite "TP-2 pooled monitor finish":
    test "in-process monitor hosting is not supported on this platform":
      skip()
else:
  const GraceMs = 300
    ## The §4.1 detached-descendant grace, shortened from io-mon's 500 ms
    ## default so the timing case runs in seconds rather than tens of them.
    ## It is the unit BOTH arms of that case are measured in, so shortening it
    ## changes the runtime and not the property.

  proc scratchRoot(name: string): string =
    let root = absolutePath("build" / "test-tmp" / "test_monitor_finish" /
      testCaseScratchSlug() / name)
    if dirExists(root):
      removeDir(root)
    createDir(root)
    root

  proc engineConfig(cacheRoot: string; parallelism: uint32;
                    hosted: bool): BuildEngineConfig =
    ## THE TWO ARMS DIFFER IN ONE FIELD. ``monitorHosting`` decides whether
    ## the engine drives io-mon's decomposed API itself (and, since TP-2,
    ## finishes on a pool worker) or spawns ``repro internal io monitor``,
    ## which runs io-mon's BATCH ``runMonitored`` — the reference DH-4 diffs
    ## against. Everything else is identical on purpose: same launch path,
    ## same shim, same limits, same parallelism.
    let tools = prepareMonitorTools(getCurrentDir(),
      getCurrentDir() / "build" / "test-tp2-finish", "tp2-finish")
    putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
    BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: tools.monitorCliPath,
      monitorCliPath: tools.monitorCliPath,
      monitorCliArgs: tools.monitorCliArgs,
      maxParallelism: parallelism,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true,
      monitorHosting: if hosted: mhmWhereSupported else: mhmNever)

  proc depfilePathFor(cacheRoot, actionId: string): string =
    cacheRoot / "monitor-depfiles" / (actionId & ".iomon")

  proc comparableInterestPolicy(): DependencyGatheringPolicy =
    ## BOTH ARMS ASK IO-MON FOR THE SAME CATEGORIES. See the header: the
    ## engine's interest reduction reaches io-mon on the hosted path (through
    ## ``FsSnoopRequest.interest``) and is overwritten on the wrapped one
    ## (io-mon's own injection variable wins over the engine's env seed), so
    ## without this the two arms differ by two records for a reason that
    ## predates TP-2 and has nothing to do with it. Opting in makes both
    ## requests ``FullInterest``, which is the one value the two paths agree
    ## on today.
    result = automaticMonitorGatheringPolicy()
    result.captureNonDeterminism = true
    result.captureIpc = true

  # ------------------------------------------------------------------
  # THE NORMALISER, AND THE FLAKE THAT REWROTE IT.
  #
  # It was first written DH-4's way: kernel-allocated identifiers mapped
  # through a BIJECTION assigned BY FIRST APPEARANCE, because a bijection
  # erases a consistent global RENAMING (that is the definition) while
  # leaving a COLLAPSE of two values into one visible.
  #
  # That is right for DH-4 and WRONG HERE, and the difference was measured
  # rather than reasoned: the case passed three times and failed a fourth
  # under a mutation that changes only a failure MESSAGE, on one record —
  # the detached ``sleep``'s ``parentOsPid`` rendered ``P5`` in one arm and
  # ``P4`` in the other, out of 181 records that were otherwise identical.
  # "First appearance" is an order-dependent rule, DH-4's two runs are
  # merged by ONE process, and this file's two arms are merged by two
  # DIFFERENT ones (the engine, and a ``repro internal io monitor`` child).
  # Nothing requires two hosts to interleave fragments from independent
  # producer threads in the same order, so the bijection itself was the
  # flake. Sorting the rendered records afterwards does not help: the
  # LABELS were already assigned from the unsorted order.
  #
  # WHAT REPLACES IT, and it keeps both halves of what the bijection was
  # for while depending on no order at all:
  #
  #   1. Every pid-valued field is BLANKED to ``<pid>`` in the record
  #      rendering, and the blanked renderings are compared as a sorted
  #      multiset. That is the bulk of the evidence — kinds, paths,
  #      details, flags, probe results — and it is exactly what a renaming
  #      would erase anyway.
  #   2. The pid STRUCTURE is compared by COUNTING: how many DISTINCT
  #      processes the run's records mention. That is what a collapse of
  #      two pids into one changes and a consistent renaming does not,
  #      which is the half of the bijection's job worth keeping, and it
  #      depends on no order whatsoever.
  #
  # A RICHER STRUCTURAL COMPARISON WAS TRIED AND WITHDRAWN, and it is
  # recorded here rather than quietly dropped. Per-pid FINGERPRINTS — for
  # each pid, the sorted multiset of ``<field>@<pid-blanked rendering>``
  # over the records it appears in — are one round of colour refinement,
  # and one round is not a complete invariant: the fixture's two
  # ``mrProcessSpawn(fork)`` records render identically once pids are
  # blanked, so "child of a fork" and "parent of a fork" cannot be told
  # apart between the two forks, and the resulting multisets disagreed
  # between the arms on 2 of 7 runs with nothing else different. A test
  # that fails intermittently is worse than no test, so the fingerprints
  # are computed (they are what ``pidCount`` counts) but only their COUNT
  # is asserted. Iterating the refinement to a fixpoint would restore the
  # stronger comparison; it is not done here because nothing in TP-2 turns
  # on it, and the two arms' agreement on WHICH paths were touched — the
  # thing an edge's fingerprint is built from — is asserted in full by (1)
  # and by the ``PathSetEvidence`` comparison.
  # ------------------------------------------------------------------
  const PidPlaceholder = "<pid>"

  type Normaliser = object
    runs: Table[string, string]

  proc normaliseDetail(n: var Normaliser; detail: string): string =
    ## The writer's whitespace-separated ``key=value`` convention. Two token
    ## kinds carry per-run identity: ``run=<id>`` and ``pids=<list>``.
    ## A run token is a BIJECTION and stays one — there is exactly one run
    ## id per run, so its assignment cannot depend on an order.
    var parts: seq[string] = @[]
    for token in detail.split(' '):
      if token.startsWith("run="):
        let id = token[4 .. ^1]
        if not n.runs.hasKey(id):
          n.runs[id] = "R" & $n.runs.len
        parts.add "run=" & n.runs[id]
      elif token.startsWith("pids="):
        var mapped: seq[string] = @[]
        for entry in token[5 .. ^1].split(','):
          if entry.len == 0: continue
          try:
            discard parseInt(entry)
            mapped.add PidPlaceholder
          except ValueError:
            mapped.add entry
        parts.add "pids=" & mapped.join(",")
      else:
        parts.add token
    parts.join(" ")

  proc normalisePath(path, workDir: string): string =
    ## Real filesystem paths are NOT normalised away — placeholdering them is
    ## the normalisation that passes vacuously, and they are the largest
    ## evidence-bearing field in a record. Both arms run the same command in
    ## the SAME directory, so every path either matches exactly or is a real
    ## difference. Two exceptions:
    ##   * the work directory's own absolute prefix, which differs between
    ##     arms only in the case-scratch segment;
    ##   * the inode inside a ``localfd:<dev>:<ino>`` channel pseudo-path,
    ##     which names a fresh kernel object per run. The scheme and the
    ##     DEVICE are compared verbatim; the inode is BLANKED for the same
    ##     order-independence reason the pids are.
    var value = path
    if workDir.len > 0 and value.startsWith(workDir):
      value = "<work>" & value[workDir.len .. ^1]
    if value.startsWith("localfd:"):
      let bits = value.split(':')
      if bits.len == 3:
        value = bits[0] & ":" & bits[1] & ":<ino>"
    value

  proc renderOneRecord(n: var Normaliser; record: MonitorRecord;
                       workDir: string): string =
    ## EVERY FIELD OF ``MonitorRecord``, ASKED OF THE TYPE. ``fieldPairs``
    ## means a field added to the record later is compared without anyone
    ## remembering to add a line here, and EXCLUDING one would take a
    ## deliberate edit. ``seq`` is the one deliberate exclusion — it is the
    ## merge's own canonical index, i.e. a function of the very interleaving
    ## two independent hosts are not required to share.
    var parts: seq[string] = @[]
    for name, value in record.fieldPairs:
      when name == "seq":
        discard value
      elif name == "path":
        parts.add name & "=" & normalisePath(value, workDir)
      elif name == "detail":
        parts.add name & "=" & n.normaliseDetail(value)
      elif name == "osPid" or name == "parentOsPid" or
           name == "threadId" or name == "childOsPid":
        parts.add name & "=" & (if value == 0'u64: "0" else: PidPlaceholder)
      elif name == "result":
        # For an ``mrProcessSpawn`` this field IS the forked child's pid, in
        # a field whose name says nothing about pids (measured by DH-4), so
        # it is blanked like one.
        if record.kind == mrProcessSpawn and value > 0:
          parts.add name & "=" & PidPlaceholder
        else:
          parts.add name & "=" & $value
      else:
        parts.add name & "=" & $value
    parts.join(" ")

  proc renderRecords(depFile: MonitorDepFile; workDir: string): seq[string] =
    ## The bulk comparison: every record, pid-blanked, as a sorted multiset.
    var n = Normaliser()
    result = @[]
    for record in depFile.records:
      result.add n.renderOneRecord(record, workDir)
    result.sort()

  proc distinctPids(depFile: MonitorDepFile): int =
    ## How many DISTINCT processes this run's records mention. ``0`` is not
    ## a process — it is "no pid" — so it does not count.
    var seen = initHashSet[uint64]()
    for record in depFile.records:
      for name, value in record.fieldPairs:
        when name == "osPid" or name == "parentOsPid" or
             name == "threadId" or name == "childOsPid":
          if value != 0'u64:
            seen.incl value
    seen.len

  proc renderEvidence(evidence: PathSetEvidence; workDir: string): string =
    ## The ENGINE's own view of the same run, rendered field by field from
    ## the type. This is the second layer of the comparison: the record sets
    ## above are what io-mon produced, this is what the engine made of them,
    ## and the two arms reach it by different folds (from records on the
    ## hosted path, from the file on the wrapped one).
    ##
    ## FIELD BY FIELD FROM THE TYPE, AND EVERY SHAPE THE TYPE CAN HAVE.
    ## This walk used to assume every `PathSetEvidence` field was a
    ## `seq[string]` — it ran `normalisePath(entry, workDir)` over `value`
    ## unconditionally. That assumption stopped being true when `afebdcd2`
    ## added `entropyObservations: seq[EntropyObservation]` and
    ## `entropyObservability: EntropyObservability`, and the walk stopped
    ## COMPILING, which is the only reason anybody noticed.
    ##
    ## THE TEMPTING FIX IS THE DEFECT. Writing `when value is seq[string]`
    ## with a bare `else: discard` would compile immediately and would drop
    ## both new fields out of the comparison silently — a field the
    ## comparison ignores, which is In-Process-Monitor-Hosting P6 (a
    ## `monitorProbes` difference nothing rendered) and P10
    ## (`monitorDirectoryEnumerations` rendered by nothing at all) for the
    ## third time in this campaign, and the second time in this one type.
    ## So the `else` arm is a COMPILE ERROR instead: a twelfth field of a
    ## shape this walk has never seen cannot enter the type without someone
    ## deciding here how the two arms should be compared for it. A red
    ## build is a decision that has to be made; a silent `discard` is one
    ## that never is.
    ##
    ## WHAT EACH ARM IS WORTH ON THIS FIXTURE, said plainly, because
    ## rendering is not comparing:
    ##   * the `seq[string]` arms — non-vacuous, the fixture populates
    ##     `declaredInputs`/`declaredOutputs`/`monitorReads`/`monitorWrites`
    ##     /`monitorProbes`/`monitorEnvReads` and the case asserts the
    ##     marker is among the reads before it asserts the arms agree;
    ##   * `entropyObservability` — a SCALAR, and a decided one
    ##     (`entObserved`/`entNotObserved` rather than the `entUnknown`
    ##     zero) whenever the capture carried a backend profile, so it
    ##     compares an answer against an answer;
    ##   * `entropyObservations` — VACUOUS on this fixture, which reads no
    ##     randomness: both arms render `[]`. It is rendered anyway so the
    ##     field cannot be silently dropped, and it is NOT claimed here that
    ##     the two arms were shown to attribute entropy identically. They
    ##     were not. Producing the class would need a fixture that draws
    ##     randomness, and `t_every_launch_path_is_monitored` records the
    ##     same limitation for the same reason.
    var lines: seq[string] = @[]
    for name, value in evidence.fieldPairs:
      var entries: seq[string] = @[]
      when value is seq[string]:
        for entry in value:
          entries.add normalisePath(entry, workDir)
      elif value is seq[EntropyObservation]:
        # BOTH components. `EntropyCallerOrigin` is the axis on which a
        # hosted monitor (io-mon running inside the ENGINE process) could
        # plausibly attribute the same read differently from a monitor in a
        # process of its own, so rendering only `source` would drop exactly
        # the difference this case exists to find.
        for entry in value:
          entries.add entry.source & "@" & $entry.origin
      elif value is EntropyObservability:
        entries.add $value
      else:
        {.error: "renderEvidence has no rendering for a new " &
          "PathSetEvidence field of this shape. Add an arm — do NOT add " &
          "an `else: discard`, which is how a field stops being compared " &
          "without anything going red (In-Process-Monitor-Hosting P6/P10).".}
      entries.sort()
      lines.add name & "=[" & entries.join(" ") & "]"
    lines.join("\n")

  proc kindHistogram(depFile: MonitorDepFile): string =
    var counts = initCountTable[string]()
    for record in depFile.records:
      counts.inc($record.kind & "/" & $record.observationKind)
    var keys: seq[string] = @[]
    for key in counts.keys: keys.add key
    keys.sort()
    var parts: seq[string] = @[]
    for key in keys: parts.add key & "=" & $counts[key]
    parts.join(" ")

  proc mentionsMarker(paths: seq[string]; workDir: string): bool =
    for path in paths:
      if path == workDir / "marker.txt": return true
    false

  proc firstDifference(a, b: seq[string]): string =
    for i in 0 ..< max(a.len, b.len):
      let left = if i < a.len: a[i] else: "<absent>"
      let right = if i < b.len: b[i] else: "<absent>"
      if left != right:
        return "at index " & $i & ":\n  hosted:  " & left & "\n  wrapped: " &
          right
    ""

  suite "TP-2 pooled monitor finish":
    test "evidence is unchanged versus the serial form":
      ## THE ACCEPTANCE CASE. The same action is run twice in the SAME
      ## directory — once with the engine hosting io-mon and finishing on a
      ## pool worker, once through the ``repro internal io monitor`` wrapper,
      ## which is io-mon's BATCH ``runMonitored`` and the reference DH-4
      ## diffs against — and the two must produce the same evidence.
      ##
      ## IT IS RUN FOR TWO FIXTURES AND THE SECOND ONE IS THE POINT. The
      ## quiesced fixture is the control: it exists so the detached-descendant
      ## fixture below cannot pass because io-mon grades this whole family
      ## ``mcIncomplete`` for some unrelated reason. The descendant fixture is
      ## the acceptance: a real ``sleep`` is left running past the root's
      ## exit, held alive across every grace window either path can open, so
      ## BOTH arms must reach ``mcIncomplete`` through the §4.1 guard. Two
      ## paths agreeing on ``mcComplete`` proves nothing.
      ##
      ## MUTATION TARGETS.
      ## (1) Make ``handOffMonitorFinish`` submit the job WITHOUT moving the
      ##     handle (finish on the main thread as before) — this case must
      ##     stay green, because it is about the evidence and not about where
      ##     the work ran. It is the timing case that reddens.
      ## (2) Make ``applyMonitorFinishOutcome`` drop the records
      ##     (``pool.records[slot].records = @[]``): the hosted arm's evidence
      ##     collapses to the declared sets and this case reddens on the
      ##     rendered comparison.
      ## (3) Skip the §4.1 grace on the hosted arm — reachable only by
      ##     shortening ``IO_MON_LINUX_DESCENDANT_GRACE_MS`` to 0 for one arm
      ##     — and the descendant fixture reddens on ``completeness``.
      let root = scratchRoot("evidence")
      let work = root / "work"

      # A TEMPLATE, NOT A PROC: `check` inside a plain `proc` prints
      # "Check failed" and the case still reports [OK].
      template runOneArm(tag: string; hosted: bool; descendant: bool):
          tuple[records: seq[string]; pidCount: int;
                evidence, histogram: string;
                completeness: MonitorCompleteness; status: ActionStatus] =
        # The work directory is torn down and REBUILT for every arm, with
        # the same contents at the same absolute path. That is what makes the
        # two runs' real paths equal by construction instead of by a
        # placeholder that would erase the difference it is meant to catch.
        if dirExists(work): removeDir(work)
        createDir(work)
        writeFile(work / "marker.txt", "tp2-marker\n")
        let armCacheRoot = root / ("cache-" & tag)
        let actionId = "tp2-evidence-" & tag
        let command =
          if descendant:
            # A REAL detached descendant. The subshell's ``sleep`` outlives
            # the root shell, inherits the shim through ``LD_PRELOAD``, and
            # is therefore a live INJECTED descendant for the whole of the
            # §4.1 grace window — which is the state that must downgrade the
            # edge on both paths.
            "cat marker.txt > out.txt; (sleep 4 >/dev/null 2>&1 &)"
          else:
            "cat marker.txt > out.txt"
        let run = runBuild(graph([action(actionId,
          @["sh", "-c", command],
          cwd = work,
          inputs = ["marker.txt"],
          outputs = ["out.txt"],
          cacheable = false,
          dependencyPolicy = comparableInterestPolicy(),
          governingLockIdentity = lockIdentityOutsideSolvedGraph())]),
          engineConfig(armCacheRoot, 1'u32, hosted))
        check run.results.len == 1
        let depPath = depfilePathFor(armCacheRoot, actionId)
        checkOrEcho fileExists(depPath),
          "[" & tag & "] no depfile was published at " & depPath &
          "; the arm produced no evidence to compare"
        let depFile =
          if fileExists(depPath): readMonitorDepFile(depPath)
          else: MonitorDepFile()
        (renderRecords(depFile, work), distinctPids(depFile),
         renderEvidence(run.results[0].evidence, work),
         kindHistogram(depFile), depFile.completeness,
         run.results[0].status)

      putEnv("IO_MON_LINUX_DESCENDANT_GRACE_MS", $GraceMs)
      defer: delEnv("IO_MON_LINUX_DESCENDANT_GRACE_MS")

      # ---- the quiesced control ----
      let quiescedHosted = runOneArm("quiesced-hosted", true, false)
      let quiescedWrapped = runOneArm("quiesced-wrapped", false, false)

      checkOrEcho quiescedHosted.status == asSucceeded and
          quiescedWrapped.status == asSucceeded,
        "the quiesced fixture did not succeed on both arms: hosted=" &
        $quiescedHosted.status & " wrapped=" & $quiescedWrapped.status
      checkOrEcho quiescedHosted.completeness == mcComplete and
          quiescedWrapped.completeness == mcComplete,
        "CONTROL: a quiesced monitored action must grade mcComplete on both " &
        "arms, otherwise the descendant case below cannot distinguish the " &
        "§4.1 downgrade from a fixture that is incomplete for some other " &
        "reason. hosted=" & $quiescedHosted.completeness & " wrapped=" &
        $quiescedWrapped.completeness
      # NOT VACUOUS: identical-but-empty would satisfy every comparison below.
      checkOrEcho quiescedHosted.records.len > 0,
        "the hosted arm produced NO records, so comparing the two arms " &
        "proves nothing"
      checkOrEcho quiescedHosted.evidence.contains("<work>/marker.txt"),
        "the hosted arm's evidence does not name the file the fixture " &
        "reads, so it is not evidence of this action:\n" &
        quiescedHosted.evidence

      checkOrEcho quiescedHosted.histogram == quiescedWrapped.histogram,
        "the two arms disagree about WHICH KINDS of observation the same " &
        "action produced:\n  hosted:  " & quiescedHosted.histogram &
        "\n  wrapped: " & quiescedWrapped.histogram
      checkOrEcho quiescedHosted.records == quiescedWrapped.records,
        "a pooled finish produced different evidence from the batch " &
        "reference for a quiesced action (" &
        $quiescedHosted.records.len & " vs " & $quiescedWrapped.records.len &
        " records) " & firstDifference(quiescedHosted.records,
          quiescedWrapped.records)
      checkOrEcho quiescedHosted.pidCount == quiescedWrapped.pidCount,
        "the two arms agree record-for-record but mention a different " &
        "NUMBER of distinct processes: " & $quiescedHosted.pidCount &
        " hosted, " & $quiescedWrapped.pidCount & " wrapped. Two pids " &
        "collapsed into one renders identically once pids are blanked, so " &
        "this count is what catches it."
      checkOrEcho quiescedHosted.pidCount > 1,
        "the quiesced fixture mentions " & $quiescedHosted.pidCount &
        " distinct process(es), so the count above cannot distinguish a " &
        "collapse from a match"
      checkOrEcho quiescedHosted.evidence == quiescedWrapped.evidence,
        "the ENGINE's evidence differs between the two arms:\n--- hosted\n" &
        quiescedHosted.evidence & "\n--- wrapped\n" & quiescedWrapped.evidence

      # ---- the acceptance: a real detached descendant ----
      let liveHosted = runOneArm("descendant-hosted", true, true)
      let liveWrapped = runOneArm("descendant-wrapped", false, true)

      checkOrEcho liveHosted.status == asSucceeded and
          liveWrapped.status == asSucceeded,
        "the descendant fixture did not succeed on both arms: hosted=" &
        $liveHosted.status & " wrapped=" & $liveWrapped.status
      # THE HALF THAT MAKES THE COMPARISON MEAN SOMETHING. Both arms must
      # reach the §4.1 downgrade; agreeing on mcComplete would be agreement
      # that the guard never ran.
      checkOrEcho liveHosted.completeness == mcIncomplete,
        "the HOSTED arm graded an action with a descendant alive across the " &
        "whole grace window " & $liveHosted.completeness &
        "; the §4.1 guard did not downgrade it, so the pooled finish is " &
        "erring toward mcComplete — the direction DH-4 says is wrong"
      checkOrEcho liveWrapped.completeness == mcIncomplete,
        "the WRAPPED reference graded the descendant fixture " &
        $liveWrapped.completeness & ", so this fixture does not exercise " &
        "the §4.1 guard at all and the assertion above proves nothing"

      checkOrEcho liveHosted.histogram == liveWrapped.histogram,
        "the two arms disagree about WHICH KINDS of observation the " &
        "descendant fixture produced:\n  hosted:  " & liveHosted.histogram &
        "\n  wrapped: " & liveWrapped.histogram
      checkOrEcho liveHosted.records == liveWrapped.records,
        "a pooled finish produced different evidence from the batch " &
        "reference for a DETACHED-DESCENDANT action (" &
        $liveHosted.records.len & " vs " & $liveWrapped.records.len &
        " records) " & firstDifference(liveHosted.records, liveWrapped.records)
      checkOrEcho liveHosted.pidCount == liveWrapped.pidCount,
        "the two arms agree record-for-record but mention a different " &
        "NUMBER of distinct processes for the descendant fixture: " &
        $liveHosted.pidCount & " hosted, " & $liveWrapped.pidCount &
        " wrapped"
      checkOrEcho liveHosted.pidCount > quiescedHosted.pidCount,
        "the descendant fixture produced no MORE processes than the " &
        "quiesced one (" & $liveHosted.pidCount & " vs " &
        $quiescedHosted.pidCount & "), so the detached `sleep` this case " &
        "is built on is not in the evidence at all"
      checkOrEcho liveHosted.evidence == liveWrapped.evidence,
        "the ENGINE's evidence differs between the two arms for the " &
        "descendant fixture:\n--- hosted\n" & liveHosted.evidence &
        "\n--- wrapped\n" & liveWrapped.evidence

    test "a pooled finish does not widen the grace window":
      ## THE TIMING PROPERTY, AND IT IS EVIDENCE RATHER THAN PERFORMANCE.
      ## DH-3/DH-4 measured that the §4.1 detached-descendant window opens
      ## when ``finishMonitor`` runs. A monitor whose finish is DEFERRED
      ## therefore grades a descendant that dies in the interval
      ## ``mcComplete`` where the batch reference grades it ``mcIncomplete``
      ## — on identical inputs, with nothing wrong — so how long after the
      ## scheduler NOTICES the exit the window opens is part of the evidence,
      ## not a scheduling detail.
      ##
      ## WHAT IS MEASURED. ``MonitorFinishOutcome.openDelayNs``: the interval
      ## between the START of the poll pass that first observed a root's exit
      ## and the instant a worker entered ``finishMonitor``. Measured
      ## identically for both arms below, from the pass and not from the
      ## submit, because that is the only scale on which a serial settle loop
      ## and a pooled one are comparable: a serial loop spends the interval
      ## inside its predecessors' ``finishMonitor`` calls rather than in a
      ## queue.
      ##
      ## THE SENSITIVITY CONTROL IS THE POINT. A bound that is never
      ## approached says nothing, and "the delay was small" is worthless from
      ## an instrument that cannot report a large one. So the SAME build is
      ## run twice: once with as many workers as there are monitors, and once
      ## with ONE worker — which reproduces the serial shape, because the
      ## k-th finish then waits for its k-1 predecessors exactly as it did
      ## before TP-2. Each finish is made expensive and DETERMINISTICALLY so,
      ## by a real detached descendant that holds the §4.1 grace window open
      ## for its full duration, so the expected serial delay is a known
      ## multiple of a known quantity rather than a guess about machine speed.
      ##
      ## THE BOUND THIS CASE ASSERTS, STATED HONESTLY. A pool of W workers
      ## opens the k-th of N simultaneous monitors' windows after
      ## ``ceil(k/W) - 1`` finishes, where the serial form took ``k - 1``. So
      ## the pool divides the delay by W; it does not make it zero, and with
      ## W < N some monitor still waits. The case runs W = N because that is
      ## where the strongest TRUE statement lives — "not by even one grace
      ## window" — and because W < N is a SIZING question, which
      ## ``defaultWorkerCount`` deliberately leaves to TP-3's measurement
      ## rather than to taste. The engine does not size the pool from
      ## ``maxParallelism`` today (``min(4, countProcessors())``, overridable
      ## with ``REPROBUILD_ENGINE_POOL_WORKERS``), so a build at parallelism
      ## 8 whose actions all finish at once has four monitors waiting one
      ## finish each. That is four times better than before TP-2 and it is
      ## not nothing; whoever takes TP-3 should measure it before deciding
      ## whether the sizing should follow the build's parallelism.
      ##
      ## MUTATION TARGETS.
      ## (1) Make ``handOffMonitorFinish`` wait for its own job
      ##     (``discard awaitMonitorFinishes()`` after ``submitMonitorFinish``):
      ##     the pooled arm becomes serial and this case reddens on
      ##     ``pooled max < one grace window``.
      ## (2) Move the handoff out of the settle pass and into
      ##     ``finishMonitorHostAction`` (i.e. finish on the REAPING pass, the
      ##     shape HM-4 deliberately rejected): the delay becomes a function
      ##     of queue depth and the same assertion reddens.
      ## (3) Delete ``drainMonitorFinishesInto`` from the poll loop: the build
      ##     never reaps and the case fails on its deadline instead — which is
      ##     a real failure, not this assertion, and is noted so it is not
      ##     mistaken for one.
      const Monitors = 4

      putEnv("IO_MON_LINUX_DESCENDANT_GRACE_MS", $GraceMs)
      defer: delEnv("IO_MON_LINUX_DESCENDANT_GRACE_MS")

      template runTimedArm(tag: string; workerCount: int):
          tuple[samples: int; maxOpenDelayMs, maxQueueDelayMs: float;
                failures: string] =
        let root = scratchRoot("timing-" & tag)
        let work = root / "work"
        createDir(work)
        writeFile(work / "marker.txt", "tp2-marker\n")

        # The pool's sizing only takes effect at the next START, and the
        # flush tenant may have brought it up already, so it is stopped
        # first. This is the shipped knob, not a test seam.
        shutdownEnginePool()
        configureEnginePool(workers = workerCount, queueLimit = 64)
        resetMonitorFinishStats()

        var actions: seq[BuildAction] = @[]
        for i in 0 ..< Monitors:
          actions.add action("tp2-timing-" & tag & "-" & $i,
            @["sh", "-c",
              "cat marker.txt > out-" & $i & ".txt; " &
              "(sleep 4 >/dev/null 2>&1 &)"],
            cwd = work,
            inputs = ["marker.txt"],
            outputs = ["out-" & $i & ".txt"],
            cacheable = false,
            governingLockIdentity = lockIdentityOutsideSolvedGraph())
        let run = runBuild(graph(actions),
          engineConfig(root / "cache", uint32(Monitors), true))
        var failed: seq[string] = @[]
        for res in run.results:
          if res.status != asSucceeded:
            failed.add res.id & "=" & $res.status & " " & res.stderr
        let stats = monitorFinishStats()
        shutdownEnginePool()
        resetEnginePoolConfiguration()
        (stats.samples, float(stats.maxOpenDelayNs) / 1_000_000.0,
         float(stats.maxQueueDelayNs) / 1_000_000.0, failed.join("; "))

      # ---- the arm under test: one worker per monitor ----
      let pooled = runTimedArm("pooled", Monitors)
      checkOrEcho pooled.failures.len == 0,
        "the pooled arm's actions did not all succeed: " & pooled.failures
      checkOrEcho pooled.samples == Monitors,
        "the pooled arm handed off " & $pooled.samples & " finishes, not " &
        $Monitors & "; this case is not measuring what it believes it is"

      # ---- the sensitivity control: one worker, i.e. the serial shape ----
      let serial = runTimedArm("serial", 1)
      # The MEASUREMENT, printed whether the case passes or fails. A timing
      # property whose numbers appear only on failure cannot be sanity-checked
      # by whoever reads the run, and "it passed" is not evidence of what it
      # measured.
      echo "grace-window delay, worst of ", Monitors, " monitors, grace ",
        GraceMs, " ms: pooled(", Monitors, " workers) open=",
        formatFloat(pooled.maxOpenDelayMs, ffDecimal, 1), " ms queue=",
        formatFloat(pooled.maxQueueDelayMs, ffDecimal, 1),
        " ms | serial(1 worker) open=",
        formatFloat(serial.maxOpenDelayMs, ffDecimal, 1), " ms queue=",
        formatFloat(serial.maxQueueDelayMs, ffDecimal, 1), " ms"
      checkOrEcho serial.failures.len == 0,
        "the one-worker arm's actions did not all succeed: " & serial.failures
      checkOrEcho serial.samples == Monitors,
        "the one-worker arm handed off " & $serial.samples & " finishes, " &
        "not " & $Monitors

      # THE INSTRUMENT IS NOT BLIND. With one worker the k-th finish waits
      # for its k-1 predecessors, each of which holds the §4.1 window open
      # for a full grace, so the worst delay must exceed one grace window.
      # If it does not, the measurement below cannot distinguish a pool that
      # runs finishes concurrently from one that does not, and this case
      # refuses to report a pass it did not earn.
      checkOrEcho serial.maxOpenDelayMs > float(GraceMs),
        "SENSITIVITY CONTROL FAILED: with ONE worker and " & $Monitors &
        " monitors each holding a " & $GraceMs & " ms grace window open, " &
        "the worst grace-window delay was only " &
        formatFloat(serial.maxOpenDelayMs, ffDecimal, 1) & " ms. The " &
        "instrument cannot see a delay it is supposed to be able to see, " &
        "so the assertion below would pass from blindness."

      # THE PROPERTY. With a worker per monitor the pool must not delay the
      # window's opening by even one grace window — i.e. no monitor's
      # evidence can drift toward mcComplete by as much as a single §4.1
      # interval because of where the work ran.
      checkOrEcho pooled.maxOpenDelayMs < float(GraceMs),
        "a pooled finish widened the §4.1 grace window by " &
        formatFloat(pooled.maxOpenDelayMs, ffDecimal, 1) & " ms, which is " &
        "at least one whole grace window (" & $GraceMs & " ms). A monitor " &
        "that opens its window that late grades a descendant that died in " &
        "the interval mcComplete where the reference grades it " &
        "mcIncomplete (DH-4 item 2)."
      checkOrEcho pooled.maxOpenDelayMs * 2.0 < serial.maxOpenDelayMs,
        "the pooled arm's worst grace-window delay (" &
        formatFloat(pooled.maxOpenDelayMs, ffDecimal, 1) & " ms) is not " &
        "materially better than the one-worker arm's (" &
        formatFloat(serial.maxOpenDelayMs, ffDecimal, 1) & " ms), so the " &
        "finishes are not actually running concurrently"

      # AND THE HANDOFF ITSELF COSTS NOTHING. ``openDelayNs`` includes the
      # rest of the settle pass; ``queueDelayNs`` is submit-to-worker alone,
      # which is what a thread handoff costs against a process spawn's tens
      # of milliseconds.
      checkOrEcho pooled.maxQueueDelayMs < 50.0,
        "the pool took " & formatFloat(pooled.maxQueueDelayMs, ffDecimal, 1) &
        " ms to get a submitted finish onto a free worker"

    test "the finish worker touches no io-mon producer state":
      ## THE RUNTIME HALF OF ``monitor_finish``'s ``{.cast(gcsafe).}``
      ## ARGUMENT, asserted rather than claimed in a comment.
      ##
      ## ``finishMonitor`` is not ``gcsafe`` — measured, and the compile-side
      ## pin for that lives in
      ## ``test_monitor_finish_handoff_is_exclusive.nim``. The cast is sound
      ## because the three GC'd globals reachable from it are all
      ## PRODUCER-side state that a HOST process never attaches, and two of
      ## the three (``setProducer``, ``setElemImage``) are reached only under
      ## ``if setProducerAttached:``. ``depSetIsActive()`` is io-mon's OWN
      ## reading of that guard, so this asserts the guard's value in the very
      ## process the workers run in — before a build, and after one that
      ## really did host and finish monitors.
      ##
      ## MUTATION TARGET: there is no source mutation that reddens this from
      ## reprobuild's side, and that is stated rather than glossed — the
      ## predicate belongs to io-mon and turning it true takes a call to
      ## ``attachDepQueueForShim``, which only the shim makes. What this case
      ## catches is an io-mon change that starts attaching a producer in the
      ## host, which is exactly the change that would make the cast unsound.
      checkOrEcho not monitorFinishTenantIsAttachedToADepSet(),
        "io-mon reports a dep-set PRODUCER attached in the engine's own " &
        "process before any build has run. The `{.cast(gcsafe).}` in " &
        "the TP-2 block of repro_build_engine.nim is justified by that " &
        "never happening: with a " &
        "producer attached, `appendFragmentRecord` reads and writes the " &
        "GC'd globals `setProducer` and `setElemImage` from whichever " &
        "thread runs `finishMonitor`."

      let root = scratchRoot("gcsafe")
      let work = root / "work"
      createDir(work)
      writeFile(work / "marker.txt", "tp2-marker\n")
      let run = runBuild(graph([action("tp2-gcsafe",
        @["sh", "-c", "cat marker.txt > out.txt"],
        cwd = work,
        inputs = ["marker.txt"],
        outputs = ["out.txt"],
        cacheable = false,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())]),
        engineConfig(root / "cache", 1'u32, true))
      check run.results.len == 1
      checkOrEcho run.results[0].status == asSucceeded,
        "the fixture did not run, so the assertion below is about a " &
        "process that never hosted a monitor: " & run.results[0].stderr
      checkOrEcho not monitorFinishTenantIsAttachedToADepSet(),
        "io-mon reports a dep-set PRODUCER attached in the engine's process " &
        "AFTER a hosted build. A worker running `finishMonitor` would then " &
        "be touching GC'd globals the main thread can also reach."

    test "a fault on the finish worker fails its action, not the build":
      ## HM-4's "a monitor fault fails the action, not the daemon" property,
      ## RESTATED FOR THE PLACE THE WORK NOW RUNS. Hosting removed the process
      ## boundary that used to contain a monitor fault; TP-2 moves the fault
      ## onto a worker THREAD, where an exception escaping the thread proc
      ## would terminate the whole engine rather than one action.
      ## ``t_monitor_fault_fails_the_action_not_the_daemon`` pins the property
      ## for a corrupt depfile READ, which never reaches ``finishMonitor`` at
      ## all, so nothing covered this until now.
      ##
      ## THE FAULT IS REAL AND IS NOT A SEAM ADDED FOR IT. The build's depfile
      ## directory is made READ-ONLY for the duration, so io-mon's own
      ## canonical write inside ``finishMonitor`` fails the way a genuine
      ## ENOSPC or a lost mount would — measured: ``cannot open iomon depfile
      ## for write: …``. Nothing about the monitored commands is wrong; they
      ## both succeed, and their actions still have to fail, because their
      ## evidence never arrived.
      ##
      ## TWO FAULTS, ON TWO WORKERS, AT ONCE, and that is the point rather
      ## than a way to save a build. Each action must be failed by ITS OWN
      ## fault: the diagnostic an action carries has to name that action's own
      ## scratch file. A pool that attributed one worker's failure to another
      ## job would produce two plausible-looking failures and this is what
      ## distinguishes them.
      ##
      ## THAT THE PROCESS SURVIVES AT ALL is reported by the run's EXIT CODE
      ## and by nothing else: an exception escaping a worker's thread proc
      ## aborts the binary mid-suite, which prints a SHORTER list of ``[OK]``
      ## lines rather than a ``[FAILED]`` one.
      ##
      ## MUTATION TARGETS.
      ## (1) Make ``runMonitorFinishJob``'s ``except CatchableError`` arm
      ##     swallow the fault (``node.failure = nil``). Both actions are then
      ##     reported as SUCCESSES with empty dependency sets — successful,
      ##     publishing actions that report nothing wrong — and this case
      ##     reddens on ``status == asFailed``. Deleting the arm outright is
      ##     not the interesting mutation: the compiler refuses the
      ##     ``{.nimcall, gcsafe.}`` task for the escaping effect before any
      ##     test runs.
      ## (2) Attribute the failure to the wrong slot in
      ##     ``applyMonitorFinishOutcome`` (drop the ``actionId`` check and
      ##     use ``outcome.slot`` alone with a fixed slot): the per-action
      ##     diagnostic assertion below reddens.
      let root = scratchRoot("fault")
      let work = root / "work"
      createDir(work)
      writeFile(work / "marker.txt", "tp2-marker\n")
      let cacheRoot = root / "cache"
      let depDir = cacheRoot / "monitor-depfiles"
      createDir(depDir)

      const Faulting = ["tp2-fault-a", "tp2-fault-b"]
      var actions: seq[BuildAction] = @[]
      for name in Faulting:
        actions.add action(name,
          @["sh", "-c", "cat marker.txt > " & name & "-out.txt"],
          cwd = work,
          inputs = ["marker.txt"],
          outputs = [name & "-out.txt"],
          cacheable = false,
          dependencyPolicy = comparableInterestPolicy(),
          governingLockIdentity = lockIdentityOutsideSolvedGraph())

      # Sealed AFTER the directory exists and BEFORE the build runs, so the
      # only thing that cannot write here is io-mon's canonical write.
      setFilePermissions(depDir, {fpUserRead, fpUserExec})
      var run: BuildRunResult
      var escaped = ""
      try:
        run = runBuild(graph(actions), engineConfig(cacheRoot, 2'u32, true))
      except CatchableError as err:
        escaped = $err.name & ": " & err.msg
      finally:
        setFilePermissions(depDir, {fpUserRead, fpUserWrite, fpUserExec})

      # PRIMARY: the fault did not escape the engine.
      checkOrEcho escaped.len == 0,
        "a monitor fault escaped runBuild instead of failing its action: " &
        escaped

      # THE CASE REFUSES TO REPORT A PASS IT DID NOT EARN. Running as root, or
      # on a filesystem that ignores the mode, would let the write succeed and
      # every assertion below would be about a build with no fault in it.
      var landed: seq[string] = @[]
      for kind, path in walkDir(depDir):
        landed.add path.extractFilename
      checkOrEcho landed.len == 0,
        "the read-only depfile directory was written to anyway (" &
        landed.join(", ") & "), so io-mon's canonical write did not fail " &
        "and this case measured nothing. (Are these tests running as root?)"

      if escaped.len == 0:
        check run.results.len == Faulting.len
        for res in run.results:
          checkOrEcho res.status == asFailed,
            res.id & " SUCCEEDED although its evidence never arrived. That " &
            "is a cache-publishing action with no dependencies that reports " &
            "nothing wrong: " & $res.status
          checkOrEcho res.stderr.contains("io-monitor host failed"),
            res.id & " failed, but not as a monitor-host fault, so it is " &
            "not the failure this case is about: " & res.stderr
          # ATTRIBUTION, and the reason this build has two faults in it: the
          # sentence an action carries names its OWN scratch file.
          checkOrEcho res.stderr.contains("." & res.id & ".iomon.flush-"),
            res.id & " carries a diagnostic naming somebody else's scratch " &
            "file, so the pool attributed one worker's fault to another " &
            "job: " & res.stderr
          # THE COMMAND ITSELF WAS FINE. This is an evidence fault, not a
          # command failure, which is what makes the claim about the monitor.
          checkOrEcho fileExists(work / (res.id & "-out.txt")),
            res.id & "'s command did not run, so the failure is not the " &
            "evidence fault this case is about"

      # AND THE PROCESS IS STILL USABLE for another hosted build — the "not
      # session-wide" arm, and the thing a dead worker would make impossible.
      let after = runBuild(graph([action("tp2-after-fault",
        @["sh", "-c", "cat marker.txt > after-out.txt"],
        cwd = work,
        inputs = ["marker.txt"],
        outputs = ["after-out.txt"],
        cacheable = false,
        dependencyPolicy = comparableInterestPolicy(),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())]),
        engineConfig(root / "cache-after", 1'u32, true))
      check after.results.len == 1
      checkOrEcho after.results[0].status == asSucceeded,
        "the engine could not host another monitor after two concurrent " &
        "worker faults: " & after.results[0].stderr
      checkOrEcho mentionsMarker(after.results[0].evidence.monitorReads, work),
        "the build after the faults produced no evidence of its own, so the " &
        "faults were not confined to the build they happened in: " &
        after.results[0].evidence.monitorReads.join(" ")
      checkOrEcho fileExists(
          depfilePathFor(root / "cache-after", "tp2-after-fault")),
        "the build after the faults published no depfile"
