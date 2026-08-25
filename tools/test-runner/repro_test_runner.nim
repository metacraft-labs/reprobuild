## repro_test_runner — Test-Edges-And-Parallel-Runner M3
##
## Minimal protocol-level parallel runner for reprobuild's Nim test
## suite. Consumes the Tier-1 "Standard" binary protocol shipped in
## ``ct_test_unittest_parallel`` (M2):
##
## * ``--list-json``                — JSON catalog of test cases
## * ``--run "<suite>::<test>"``    — execute one named test
## * ``$NIMTEST_RESULT_FILE``       — JSON result document path
## * exit codes 0/1/2               — pass/fail/skip
##
## Mixed mode: binaries that don't speak the protocol (e.g. existing
## ``import std/unittest`` tests that haven't migrated yet) are detected
## at probe time and executed whole; their single exit code becomes the
## edge's pass/fail status.
##
## Concurrency: process-per-test (exec-per-test). N worker tasks pull
## from a shared queue protected by a single ``Lock``; the main thread
## blocks on a barrier until every worker drains the queue. No
## fork-server, no persistent worker — that's ct-test-runner's job and
## explicitly out of scope for M3.
##
## CLI::
##
##   repro_test_runner [--threads N] [--bin-dir DIR] [--build]
##                     [--summary-json PATH] [--quiet]
##                     [--filter GLOB]... [--test-timeout=N]
##                     [--catalog-write PATH] [--catalog-read PATH]
##
## Incremental selection::
##
##   --catalog-write PATH  after probing, record every catalogued case's
##                         ``bodyHash`` to PATH.
##   --catalog-read PATH   consult a catalog written earlier and skip
##                         cases whose ``bodyHash`` it positively
##                         vouches for.
##
## Selection is FAIL-CLOSED and can only ever subtract. A missing,
## unreadable, malformed, wrongly-versioned catalog — or one written
## under a different project root or ``--bin-dir`` — is refused with a
## stated reason on stderr and in ``summary.selection.fell_back_because``,
## and the run is the full run. So is an unknown binary, an unknown case,
## or an empty hash on either side. Omitting ``--catalog-read`` is the
## full run and always remains available. See the "run catalog" section
## below ``probeBinary`` for the complete rule.
##
## WHAT A BODY HASH DOES AND DOES NOT COVER. It is computed by the
## compiler over the case as compiled, so it moves when the case's own
## source moves AND when a module it compiles against moves — editing a
## library a test calls changes that test's hash even though its body
## text is untouched (measured, not assumed). It does NOT move for
## anything outside the compiled program: a fixture or data file read at
## run time, an environment variable, an external tool or a sibling
## checkout. A case whose behaviour depends on those can be deselected
## while genuinely failing. That is why ``--catalog-read`` is opt-in, why
## a selected run is flagged in the summary as ``selected_subset``, and
## why a gate must read that flag before treating ``total`` as coverage.
##
## Default ``--bin-dir`` is ``build/test-bin`` relative to the current
## working directory. ``--threads`` defaults to ``$NPROC`` or the
## platform's countProcessors() value.
##
## Aggregate exit code::
##
##   0  every case passed or skipped AND both status channels agreed
##      everywhere AND every case actually ran
##   1  at least one case FAILED, or at least one case reported a
##      ``status_disagreement``, or at least one case could not be run
##      at all (``ERROR`` — see ``TestStatus.tsHarnessError``)
##
## ``ERROR`` is deliberately not merged into either of the other two
## buckets. A case whose child could not be spawned produced no verdict:
## calling it a FAIL asserts something about the code that was never
## observed, and calling it a PASS is a fail-open. It is counted
## separately (``summary.harness_errors``), labelled separately in the
## console, carries its reason in ``harness_error``, and fails the run.
##
## The second clause is not redundant. A case's label comes from its
## result document, which the ``std/unittest`` fork writes in
## ``testEnded`` — before the process exits. A case that passes and then
## dies non-zero in a destructor, a ``defer``, an exit proc or a teardown
## segfault therefore has a PASS document and a crashing process. Labelling
## it PASS is defensible; letting the RUN exit 0 is not, and used to be
## what happened. See ``TestResult.statusDisagreement``.
##
## Environment::
##
##   REPRO_TEST_FAIL_FAST=1     stop scheduling new tests after first FAIL
##   REPRO_TEST_THREADS=N       override default worker count
##   REPRO_TEST_PROBE_TIMEOUT=N wall-clock bound, in seconds, on a single
##                              ``--list-json`` discovery probe (default
##                              ``DefaultProbeTimeoutSec``). Expiry
##                              downgrades the binary to whole-binary
##                              execution; it is never a failure.
##

import std/[algorithm, atomics, json, locks, os, osproc, parseopt, streams,
            strtabs, strutils, tables, tempfiles, times]

# RunQuota-Observation-Store M19: the ``HistoryReporter`` write path.
#
# THE RUNNER DOES NOT OPEN A DATABASE, AND THERE IS NO ``.nimtest/history.db``.
# ``Nim-Parallel-Test-Framework.md`` §17.3 §"How these read": "The runner MUST
# NOT open the store's database file directly: ``runquotad`` is the only
# sanctioned reader". §17.1.2 replaced the per-runner history backend with
# RunQuota's shared observation store outright — the old path is retired, not
# migrated, because nothing reads it.
import ct_test_history

# RunQuota-Observation-Store M20: the READ side, §17.3's ``stats flaky`` and
# ``stats duration``.
#
# IT IS A SEPARATE LIBRARY FROM THE REPORTER ABOVE, AND THE SEPARATION IS THE
# POINT. The queries read ``ext_test_execution`` and nothing else, so they
# answer identically for every runner that writes the generic layer — which is
# what OS-8's "populated by at least two different runners" is worth only if
# the reading side is neutral too. A query hosted inside CodeTracer's reporter
# would make every other runner's statistics reachable only by linking
# CodeTracer's write path.
import repro_test_stats

when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean

const
  DefaultBinDir = "build/test-bin"
  DefaultResultsSubdir = "test-logs/results"
  DefaultSummaryPath = "test-logs/parallel-run.json"

  ## Test-binary basenames that are excluded from runner discovery.
  ## ``repro_test_runner`` is this binary itself (self-spawn would
  ## recurse). The rest are diagnostic / fixture / helper binaries left
  ## behind in ``build/test-bin/`` by other tooling. The list is the
  ## minimum the spec lets us hard-code; M4 retires it.
  ExcludeStems = [
    "repro_test_runner",
  ]

  ## These tests intentionally drive self-hosted ``repro build`` actions
  ## against shared workspace state. The B0/D2 cases mutate the sibling
  ## ``../runquota/build/bin/runquotad`` prerequisite; the B1/D5 cases rebuild
  ## or probe shared ``build/bin`` app artifacts, including the single public
  ## ``repro`` CLI; the B2/B3 cases inspect
  ## the global ``.repro/build/.../build-report.json`` emitted by those builds.
  ## Run the cluster with no other test active so shared prerequisites,
  ## app binaries, and report files are not removed or overwritten under
  ## another test's feet. D1 is in the same family: it drives a self-hosted
  ## Python test edge and reads the shared full build report for the
  ## resulting action.
  ##
  ## The M7 HTTPS cache gate starts a real TLS cache daemon and relies on
  ## process-local TLS context setup. Run it alone so other cache daemon tests
  ## cannot starve its listener startup under clean-cold load.
  ## The M77 no-op latency gate is also exclusive: it is a subprocess-spawn
  ## microbenchmark, so running it beside clean-cold compiler/linker tests
  ## measures runner contention instead of the shell-hook fast path.
  ##
  ## The dev-session e2e test starts foreground services, a file watcher, and an
  ## HTTP/SSE control plane, then waits for readiness transitions. Running it
  ## beside the heavier e2e cluster can starve the session startup path enough
  ## that the test measures host load instead of dev-session behavior.
  ##
  ## The binary-cache streaming checks run a loopback server in the same test
  ## process and deliberately enforce a 30-second receive/throughput budget.
  ## Under nested compiler load the server thread can be starved for the entire
  ## budget even though the transfer completes in under a second when the test
  ## owns the host. Likewise, the comprehensive local-build e2e case performs
  ## many nested Nim compiler invocations; concurrent nested builds have been
  ## observed to make Nim report SuccessX without materializing its requested
  ## extractor binary. The native-shell gate performs the same nested provider
  ## extraction for Bash, Zsh, and Fish and must own the host for the same
  ## reason. Keep these resource-sensitive checks fully enabled but execute
  ## them without competing test processes. The SC-7 capstone and SC-11
  ## cross-repo library test also perform repeated nested interface extraction;
  ## under contention Nim can report SuccessX without materializing the
  ## requested extractor binary, so they require the same scheduling boundary.
  ExclusiveStems = [
    "t_a2_5_p3_streaming_sink",
    "t_a2_5_p8_throughput_bench",
    "t_b0_repro_build_runquota_daemon",
    "t_b1_apps_action_cache_hit",
    "t_b1_repro_build_apps_byte_equivalent",
    "t_b1_repro_build_apps_collection",
    "t_b2_helper_invalidation",
    "t_b3_test_execute_edge_cache_hit",
    "t_b3_test_invalidation_rebuilds_repro",
    "t_cross_repo_nim_library_src_threaded_onto_consumer_path",
    "t_d1_pythonunittest_resolves_in_path_mode",
    "t_d2_cross_project_selector_recognised",
    "t_d5_collection_member_selector",
    "t_e2e_local_reprobuild_project_build",
    "t_e2e_native_shell_hooks",
    "t_e2e_repro_dev_sessions",
    "t_e2e_shell_hook_noop_latency",
    "t_repro_https_cache_end_to_end",
    "t_sc_capstone_reprobuild_runquota_and_library_edge_both_modes",
  ]

type
  CatalogEntry = object
    ## One row of a binary's ``--list-json`` catalog.
    ##
    ## RETENTION RULE. Every field the protocol emits is kept here and
    ## carried to the summary verbatim. The runner used to keep exactly
    ## ``suite`` and ``name`` and drop the rest at the parse site, which
    ## made the whole ``--list-json`` surface — file, line, column, kind,
    ## group, threadsRequired, xfail, tags, bodyHash, deterministic —
    ## unobservable downstream: a consumer reading the run artifact could
    ## not tell where a case lives, whether it is expected to fail, or
    ## whether its body changed. Dropping a field at the parse site is
    ## indistinguishable, downstream, from the producer never emitting it.
    ##
    ## HONEST LABELLING OF WHAT IS REAL. This block used to say that
    ## ``group``, ``threadsRequired``, ``xfail``, ``tags`` and
    ## ``deterministic`` were fixed literals in the emitter and therefore
    ## constants rather than measurements, and that the day the producer
    ## started varying them the consumer had to already be carrying them.
    ## That day arrived with the fork bump: a test can now DECLARE each of
    ## the five, every default is what the field held before, and the
    ## values reaching this parser vary with what the author wrote.
    ##
    ## What has NOT changed is that no scheduling, selection or reporting
    ## decision in this runner is built on them. Carrying a field and
    ## acting on it are separate steps, and only the first has been taken;
    ## ``bodyHash`` remains the one field any behaviour here depends on.
    ## A consumer must also not read a default as a declaration — the fork's
    ## conformance contract is explicit that "the producer never mentioned
    ## this field" and "the author declared the default" are the same state.
    ##
    ## ``kind`` is the one that stays constant, and for a stated reason
    ## rather than by omission: ``unittest`` registers in-process bodies
    ## and has no other kind of test to register.
    suite: string    ## the ``suite`` field, verbatim
    bare: string     ## display name: ``name`` with any ``suite::`` prefix cut
    runName: string  ## the ``name`` field, verbatim — the ``--run`` argument
    file: string             ## ``file``: source file the case was declared in
    line: int                ## ``line``: 1-based declaration line; 0 if absent
    column: int              ## ``column``: declaration column; 0 if absent
    kind: string             ## ``kind``: always ``"in-process"``; see above
    group: string
      ## ``group``: the case's ``group`` option, else its enclosing
      ## ``testGroup``, else ``"@global"``.
    threadsRequired: int
      ## ``threadsRequired``: the declared thread weight, else 1.
    xfail: string
      ## ``xfail`` rendered as text: ``""`` for JSON ``null`` (a case that
      ## declared no expected failure), otherwise the reason string or the
      ## literal ``"true"``/``"false"``. Kept as text rather than a
      ## ``bool`` so "the producer said nothing" stays distinguishable
      ## from "the producer said false".
    tags: seq[string]        ## ``tags``: the declared tags, else empty
    bodyHash: string
      ## ``bodyHash``: the compiler-computed digest of the case's body.
      ## The one field selection is built on. Empty when the producer
      ## emitted none — which is a fail-closed signal, never a match.
    deterministic: bool
      ## ``deterministic``: the declared value, else true.

type
  TestCase = object
    binary: string          ## absolute path to the compiled test binary
    binaryStem: string      ## file basename without extension
    protocolAware: bool     ## true if the binary speaks --list-json
    qualifiedName: string   ## ``suite::test``; "" when whole-binary
    suite: string
    name: string
    runName: string
      ## The catalog's ``name`` field, kept **verbatim**. This is the
      ## only string that may be handed to ``--run``: it is the
      ## binary's own identifier for the case, and reconstructing it
      ## from ``suite`` + ``name`` is not round-trip safe. A suite-less
      ## case is catalogued as ``::testname`` by the codetracer-nim
      ## ``std/unittest`` fork; rebuilding it from an empty suite
      ## yields the bare ``testname``, which that binary's ``--run``
      ## matcher rejects with "test not found" (exit 1, reported FAIL).
      ## Empty for whole-binary cases, which take no ``--run``.
    meta: CatalogEntry
      ## The case's ``--list-json`` row, retained whole. See
      ## ``CatalogEntry`` for the retention rule and for which of its
      ## fields are measurements and which are producer constants.
      ##
      ## Default-initialised (every field empty/zero/false) for a
      ## whole-binary case, which has no catalog row by construction. A
      ## consumer must therefore read ``protocolAware`` before reading any
      ## of these: an empty ``bodyHash`` on a whole-binary entry means
      ## "there is no such row", not "the producer emitted no hash".

  TestStatus = enum
    tsPass = "PASS"
    tsFail = "FAIL"
    tsSkip = "SKIP"
    tsHarnessError = "ERROR"
      ## The harness could not obtain a verdict from the case at all —
      ## the child was never started, or was started and then could not
      ## be reached. It is NOT a test result: nothing about the code
      ## under test was observed.
      ##
      ## This is the third outcome the two-channel rule requires. The
      ## runner reads two channels for "did this case pass" (the result
      ## document and the child's exit code); a spawn fault produces
      ## NEITHER, and folding that into ``tsFail`` states something the
      ## runner did not observe. Folding it into ``tsPass`` would be a
      ## fail-open. So it gets its own label, its own count in the
      ## summary, and — like ``statusDisagreement`` — it forces a
      ## non-zero aggregate exit on its own.

  TestResult = object
    testCase: TestCase
    status: TestStatus
    durationMs: int
    resultFile: string
    stdout: string
    stderr: string
    skipReason: string
      ## ``skipReason`` from the result document. The protocol emits the
      ## key only when non-empty, so absence is normal (a bare
      ## ``skip()``) and must never be read as a missing-key error.
    exception: string
      ## ``exception`` from the result document; the protocol writes
      ## JSON ``null`` when the case raised nothing.
    checkpointCount: int
      ## Number of ``checkpoints`` entries in the result document.
      ## Recorded so a consumer can tell "no diagnostics were captured"
      ## from "the document was never read".
    checkpoints: seq[string]
      ## The ``checkpoints`` entries themselves — the failed ``check``
      ## expressions, their evaluated operands, and any ``checkpoint()``
      ## the case wrote.
      ##
      ## WHY THE COUNT ALONE WAS NOT ENOUGH. A per-case child runs with
      ## ``--run``, which puts the fork's ``unittest`` into ``pmRun``;
      ## ``ensureInitialized`` registers NO console formatter in that mode
      ## (see ``lib/pure/unittest.nim``: ``protocolMode notin {… pmRun …}``).
      ## So a failing per-case child prints NOTHING — its stdout is empty
      ## by construction, and the result document is the only channel that
      ## ever carries the diagnosis. Recording just the count therefore
      ## made a per-case FAIL strictly LESS informative than the
      ## whole-binary FAIL it replaced: a whole-binary run is ``pmDefault``,
      ## keeps its console formatter, and its checkpoints reach the summary
      ## inside ``stdout``. That asymmetry is also why a harness fault
      ## looked "capturable" while an ordinary assertion did not — the
      ## harness-fault text is synthesised by this runner, not by the child.
      ##
      ## Kept out of PASS entries: on a 6800-case sweep the passing
      ## checkpoints are noise and would bloat the summary.
    harnessError: string
      ## Non-empty exactly when ``status == tsHarnessError``: the reason
      ## the harness could not run the case, verbatim (e.g. the OS error
      ## text from the failed spawn, or the child-side ``HARNESS ERROR``
      ## exit 126 written by ``processGroupWrapperMain``).
      ##
      ## Rides in the summary as ``harness_error`` so a triage script
      ## reading only the machine-readable artifact can tell "the code is
      ## broken" from "we could not run it" without grepping a console
      ## log — the distinction the exit-126 convention introduced but
      ## never surfaced anywhere a consumer could see.
    runnerDiagnosis: string
      ## A diagnosis SYNTHESISED by the runner because the case produced
      ## none — today, exactly the "your result document is not there"
      ## account (see ``missingDocumentDiagnostic``). Kept apart from
      ## ``checkpoints`` on purpose: those are the case's own first-hand
      ## lines and folding runner-authored text into them would inflate
      ## ``checkpoint_count`` and misattribute the text to the case.
      ##
      ## It rides in ``stdout`` for the summary and is printed by
      ## ``emitProgress`` for the console, so neither channel is left with
      ## a bare ``[FAIL] … (5ms)`` line.
    statusDisagreement: string
      ## Non-empty when the result document's ``status`` contradicts the
      ## verdict implied by the child's exit code. That is a protocol
      ## bug in the test binary — the two channels are supposed to agree
      ## — so it is surfaced, never silently reconciled.
      ##
      ## TWO-CHANNEL RULE (shared with ``probe_binary_catalog`` in
      ## scripts/reprobuild_suite_inventory.py; keep the two in step):
      ##
      ##   A component reading two status channels for the same fact may
      ##   choose which channel LABELS the individual item, but it must
      ##   never ABSORB a disagreement between them. Every disagreement
      ##   propagates to the aggregate outcome.
      ##
      ## Here the per-case label goes to the result document, because it
      ## is the case's own first-hand account and carries the reason, the
      ## checkpoints and the exception. The exit code is still evidence:
      ## the fork's ``testEnded`` writes the document BEFORE the process
      ## exits, so a case that passes and then dies non-zero in a
      ## destructor, a ``defer``, an exit proc or a teardown segfault has
      ## a genuine PASS document and a genuine crash. Believing only the
      ## document turned that fail-safe into a fail-open: the case counted
      ## as a pass and the whole run exited 0.
      ##
      ## The label stays with the document; the aggregate exit does not.
      ## ``main`` counts disagreements and exits non-zero on any of them,
      ## so the crash-after-pass case can no longer leave a green run.

  Queue = object
    lock: Lock
    items: seq[TestCase]
    pos: int            ## next index to hand out
    failFastTriggered: bool

  WorkerArgs = object
    queue: ptr Queue
    resultsLock: ptr Lock
    results: ptr seq[TestResult]
    resultsDir: string
    quiet: bool
    failFast: bool
    testTimeoutSec: int
    activeCount: ptr int
    ## Snapshot of the parent process environment taken once before
    ## any worker thread is spawned. ``runOneProtocol`` clones this into
    ## a fresh ``StringTableRef`` per child and adds ``NIMTEST_RESULT_FILE``
    ## — so child env composition is purely thread-local and never
    ## touches the global ``environ``. This is the fix for the M3
    ## "two workers race on ``putEnv``" hazard called out in the
    ## Test-Edges-And-Parallel-Runner milestones.
    baseEnv: ptr seq[tuple[key, value: string]]
    ## M19: the shared ``HistoryReporter``. A POINTER to one object on
    ## the main thread's frame, not one reporter per worker: the daemon
    ## opens exactly one ``runs`` row per registered session, so a
    ## session per worker would shatter a single test run into N run
    ## records and every cross-run query in §17.3 would count them as N
    ## runs. ``nil`` (and a reporter whose ``open`` returned false) means
    ## capture is off, which is the ordinary no-daemon case and not an
    ## error.
    history: ptr HistoryReporter
    memoryLimitBytes: uint64

  TestProcess = object
    process: Process
    when defined(posix):
      processGroup: int
      ownerToken: string
      statusPath: string

  ProcessGroupRefusal = object of CatchableError
    ## The runner reached a verdict and is REFUSING to report a passing or
    ## terminal one, because processes carrying this case's exact owner
    ## token were still alive after bounded TERM -> grace -> KILL cleanup.
    ##
    ## THIS IS A TEST FAILURE, NOT A HARNESS FAULT, and it is the one
    ## distinction this type exists to carry.
    ##
    ## ``tsHarnessError`` means "the harness could not obtain a verdict;
    ## nothing about the code under test was observed" — a spawn that never
    ## produced a child, a child that could not be reached afterwards, exit
    ## 126. None of that applies here: by the time these sites raise, the
    ## child has run, its group exit status has been read off disk, and the
    ## runner has directly OBSERVED that the case leaked processes which
    ## outlived a bounded kill. That is an observation about the code under
    ## test, and a leaked process group is precisely the defect the
    ## process-group ownership work exists to detect.
    ##
    ## These sites used to raise a bare ``IOError``, which the drivers
    ## caught alongside genuine collection faults and — once harness faults
    ## gained their own outcome — relabelled ERROR. That silently moved the
    ## leak out of ``summary.failed``, and
    ## ``t_repro_test_runner_process_group_cleanup`` (which asserts
    ## ``failed == 1``) went red without any test changing: same binary,
    ## same host, pre-change runner PASS, post-change runner FAIL.
    ##
    ## It deliberately does NOT inherit from ``IOError`` or ``OSError``, so
    ## the drivers' harness-fault handlers cannot re-absorb it by accident;
    ## each driver names it explicitly. It is still ``CatchableError``, so
    ## ``workerLoop``'s backstop keeps the run alive if a future path
    ## forgets to name it — that backstop reports ERROR, which is loud and
    ## fails the run rather than losing it.

proc ensureDir(dir: string) =
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

proc looksLikeTestStem(stem: string): bool =
  ## Heuristic for "this binary is a test edge". Matches the file
  ## conventions of reprobuild's M1 generator (``t_*`` and ``test_*``
  ## file basenames lower-cased onto disk).
  stem.startsWith("t_") or stem.startsWith("test_")

proc scanTestBinaries(binDir: string): seq[string] =
  result = @[]
  if not dirExists(binDir):
    return
  for kind, path in walkDir(binDir):
    if kind != pcFile:
      continue
    let stem = splitFile(path).name
    if not looksLikeTestStem(stem):
      continue
    if stem in ExcludeStems:
      continue
    when defined(windows):
      if not path.endsWith(".exe"):
        continue
    else:
      let info = getFileInfo(path)
      if fpUserExec notin info.permissions:
        continue
    result.add(path.absolutePath)
  result.sort()

const ProtocolMarkers = [
  # (1) reprobuild's own ``ct_test_unittest_parallel`` shim. The literal
  #     is the module's stderr-prefix string; a binary that links the
  #     shim always carries it.
  "ct_test_unittest_parallel",
  # (2) the codetracer-nim ``std/unittest`` fork, which carries the same
  #     protocol in the standard library itself, so a binary that merely
  #     does ``import std/unittest`` speaks it without linking any shim.
  #     The literal is the ``--run`` parse-error message from
  #     ``parseProtocolArgs``. That proc is unconditional runtime argv
  #     parsing reached before any test runs, so no optimisation level
  #     can elide the string (verified present under ``-d:release``,
  #     ``-d:danger``, ``--mm:orc -d:release`` and ``--opt:size``), and
  #     the sentence is specific enough that it cannot occur by accident
  #     in an unpatched binary.
  "unittest: --run requires a test name",
]

proc looksProtocolAwareByStrings(binary: string): bool =
  ## Cheap text-scan over the binary: a binary is protocol-aware iff it
  ## embeds one of ``ProtocolMarkers`` — i.e. it either links the
  ## ``ct_test_unittest_parallel`` shim or was compiled against the
  ## protocol-carrying ``std/unittest``. This avoids spending a full
  ## ``--list-json`` execution on every ``std/unittest`` binary just to
  ## discover that it ignores the flag and runs its whole suite.
  ##
  ## A marker hit is a *candidate* signal only: ``probeBinary`` still
  ## has to get a well-formed catalog out of ``--list-json`` before the
  ## binary is treated as protocol-aware, so a binary that merely
  ## mentions one of these strings (the runner's own tests do) costs one
  ## probe and is then classified opaque.
  const ChunkSize = 64 * 1024
  var maxMarkerLen = 0
  for marker in ProtocolMarkers:
    if marker.len > maxMarkerLen:
      maxMarkerLen = marker.len
  try:
    let f = open(binary, fmRead)
    defer: f.close()
    var carry = ""
    var buf = newString(ChunkSize)
    while true:
      let n = f.readBuffer(addr buf[0], ChunkSize)
      if n <= 0:
        break
      let chunk = carry & buf[0 ..< n]
      for marker in ProtocolMarkers:
        if chunk.contains(marker):
          return true
      # Keep the last maxMarkerLen-1 bytes so no marker can be split
      # across chunk boundaries.
      if chunk.len > maxMarkerLen - 1:
        carry = chunk[chunk.len - maxMarkerLen + 1 .. ^1]
      else:
        carry = chunk
    return false
  except CatchableError:
    return false

const DefaultProbeTimeoutSec = 300
  ## Wall-clock ceiling for a single ``--list-json`` probe.
  ##
  ## Probe cost is dominated by the binary's *module initialisation*,
  ## not by cataloguing: the ``recipes/packages/source/*`` tests run
  ## their package macro at module init, which is why their probes are
  ## seconds rather than the ~9 ms median seen elsewhere. Measured p95
  ## in that family is ~25 s, with two outliers (``test_kwin_source``,
  ## ``test_plasma_workspace_source``) above 120 s. 300 s is ~12x the
  ## p95 and >2x the slowest observed legitimate probe, so no real probe
  ## is downgraded, while a genuinely hung binary can no longer park
  ## discovery indefinitely — discovery is a single sequential pass, so
  ## an unbounded probe stalls the entire run, not just one worker.
  ## The bound is also small next to the per-test timeout (1800 s) and
  ## the runner-phase backstop (6 h).
  ##
  ## Expiry is deliberately *not* a failure: the binary falls back to
  ## whole-binary execution, exactly as if it had never carried a
  ## marker, and the per-test timeout governs it from there.

proc probeTimeoutSec(): int =
  let raw = getEnv("REPRO_TEST_PROBE_TIMEOUT")
  if raw.len == 0:
    return DefaultProbeTimeoutSec
  try:
    let parsed = parseInt(raw.strip())
    if parsed > 0: parsed else: DefaultProbeTimeoutSec
  except ValueError:
    DefaultProbeTimeoutSec

const ProbePollIntervalMs = 50

const ProbeDrainBudgetBytes = 64 * 1024

when defined(posix):
  proc makeProbePipeNonBlocking(handle: FileHandle): bool =
    let fd = cint(handle)
    let flags = fcntl(fd, F_GETFL, cint(0))
    flags != -1 and fcntl(fd, F_SETFL, flags or O_NONBLOCK) != -1

  proc drainProbePipe(handle: FileHandle; sink: File):
      tuple[bytes: int; eof: bool] =
    ## Drain one probe channel without ever letting it monopolise discovery.
    ## stdout and stderr each receive the same per-pass budget, so a child
    ## flooding one channel cannot fill and deadlock the other before the
    ## timeout poll gets another turn.
    let fd = cint(handle)
    var buf: array[4096, char]
    while result.bytes < ProbeDrainBudgetBytes:
      let remaining = ProbeDrainBudgetBytes - result.bytes
      let requested = min(buf.len, remaining)
      let n = read(fd, addr buf[0], requested)
      if n > 0:
        let count = int(n)
        discard sink.writeBuffer(addr buf[0], count)
        result.bytes += count
      elif n == 0:
        result.eof = true
        break
      else:
        let e = errno
        if e == EINTR:
          continue
        break
elif defined(windows):
  proc drainProbePipe(handle: FileHandle; sink: File):
      tuple[bytes: int; eof: bool] =
    ## Windows anonymous pipes support PeekNamedPipe. Ask how many bytes can
    ## be read before every ReadFile so discovery never blocks on either
    ## channel; a broken pipe is EOF after the direct child exits.
    let pipe = Handle(handle)
    var available: int32
    if not peekNamedPipe(pipe, lpTotalBytesAvail = addr available):
      # ERROR_BROKEN_PIPE (109) is the ordinary EOF result. Other errors are
      # also treated as a closed capture channel: retrying a failed readiness
      # query must never turn into a blocking read before the timeout check.
      result.eof = true
      return
    while available > 0 and result.bytes < ProbeDrainBudgetBytes:
      var buf: array[4096, char]
      let requested = int32(min(buf.len,
        min(int(available), ProbeDrainBudgetBytes - result.bytes)))
      var count: int32
      if readFile(pipe, addr buf[0], requested, addr count, nil) == 0:
        result.eof = true
        return
      if count <= 0:
        break
      discard sink.writeBuffer(addr buf[0], int(count))
      result.bytes += int(count)
      available -= count

proc runListJson(binary: string): tuple[output: string; stderrOutput: string;
                                        exitCode: int; timedOut: bool] =
  ## Execute ``<binary> --list-json`` under a wall-clock bound.
  ##
  ## The executable is launched directly with an argv vector. In particular,
  ## there is no ``/bin/sh -c`` between the runner and the probe: macOS SIP
  ## strips ``DYLD_*`` variables while starting Apple's protected shell, which
  ## made every Clingo-linked catalog probe fail before its Nim ``main`` even
  ## though the same binary ran successfully as a test case. Direct execution
  ## also means paths and arguments never acquire shell syntax.
  ##
  ## Direct children expose separate stdout/stderr pipes. On POSIX both are
  ## nonblocking and drained round-robin into separate temp files while the
  ## timeout is polled. A fixed per-channel budget keeps either stream from
  ## starving the other or the clock. The stdin pipe is closed immediately,
  ## preserving the former ``/dev/null`` EOF behaviour.
  ##
  ## **stdout and stderr go to separate files.** They used to be merged
  ## with ``2>&1``, which made this probe corrupt its own input: the
  ## catalog is a stdout document, and any library that writes to stderr
  ## during module initialisation prepends noise to it. That is not
  ## hypothetical — every test binary that links the clingo solver emits
  ##
  ##     <block>:22:1-26: info: no atoms over signature occur in program:
  ##
  ## on stderr before ``main`` runs. With the streams merged the parse
  ## check below saw ``<`` instead of ``{`` and silently downgraded the
  ## binary to whole-binary execution; that alone accounted for 170 of
  ## the suite's 1207 binaries, i.e. 898 cases that ran but could no
  ## longer be named, timed or re-run individually. ``subprocess.run`` in
  ## scripts/reprobuild_suite_inventory.py never merged the streams,
  ## which is the entire reason the inventory enumerated 1206/1207 while
  ## the runner enumerated 1037.
  ##
  ## stderr is still captured, because it is the useful diagnostic when a
  ## probe genuinely fails.
  result = (output: "", stderrOutput: "", exitCode: -1, timedOut: false)
  var tmpPath = ""
  var errPath = ""
  try:
    let (tmpFile, path) = createTempFile("repro_probe_", ".json")
    tmpFile.close()
    tmpPath = path
    let (errFile, epath) = createTempFile("repro_probe_", ".err")
    errFile.close()
    errPath = epath
  except CatchableError:
    return
  defer:
    for path in [tmpPath, errPath]:
      if path.len > 0:
        try: removeFile(path)
        except CatchableError: discard

  var stdoutFile: File
  var stderrFile: File
  try:
    stdoutFile = open(tmpPath, fmAppend)
    stderrFile = open(errPath, fmAppend)
  except CatchableError:
    if stdoutFile != nil:
      stdoutFile.close()
    return
  defer:
    stdoutFile.close()
    stderrFile.close()

  var p: Process
  try:
    p = startProcess(binary, args = ["--list-json"], env = nil, options = {})
    let probeStdin = p.inputStream
    if probeStdin != nil:
      probeStdin.close()
  except CatchableError:
    return

  when defined(posix):
    # A failed fcntl would leave a blocking fd behind. Refuse this probe and
    # reap its child rather than allowing the first read to bypass the wall
    # clock forever.
    if not makeProbePipeNonBlocking(p.outputHandle) or
        not makeProbePipeNonBlocking(p.errorHandle):
      try:
        p.kill()
        discard p.waitForExit()
      except CatchableError:
        discard
      try: p.close()
      except CatchableError: discard
      return

  let deadline = epochTime() + probeTimeoutSec().float
  var exitCode = -1
  try:
    while true:
      when defined(posix) or defined(windows):
        discard drainProbePipe(p.outputHandle, stdoutFile)
        discard drainProbePipe(p.errorHandle, stderrFile)
      if not p.running():
        exitCode = p.waitForExit()
        break
      if epochTime() >= deadline:
        result.timedOut = true
        try:
          p.kill()
          discard p.waitForExit()
        except CatchableError:
          discard
        break
      sleep(ProbePollIntervalMs)

    # Collect bytes already in flight after exit/kill. This stays bounded even
    # if a malformed probe leaked a descendant holding one of the pipes open.
    when defined(posix) or defined(windows):
      let drainDeadline = epochTime() + 1.0
      var stdoutEof = false
      var stderrEof = false
      while (not stdoutEof or not stderrEof) and epochTime() < drainDeadline:
        var progressed = false
        if not stdoutEof:
          let drained = drainProbePipe(p.outputHandle, stdoutFile)
          stdoutEof = drained.eof
          progressed = progressed or drained.bytes > 0
        if not stderrEof:
          let drained = drainProbePipe(p.errorHandle, stderrFile)
          stderrEof = drained.eof
          progressed = progressed or drained.bytes > 0
        if not progressed and (not stdoutEof or not stderrEof):
          sleep(10)
    else:
      # Unusual non-POSIX targets retain a compileable direct-process fallback.
      # Windows uses PeekNamedPipe above and does not enter this branch.
      if p.outputStream != nil:
        stdoutFile.write(p.outputStream.readAll())
      if p.errorStream != nil:
        stderrFile.write(p.errorStream.readAll())
  finally:
    try: p.close()
    except CatchableError: discard

  stdoutFile.flushFile()
  stderrFile.flushFile()

  if result.timedOut:
    return
  result.exitCode = exitCode
  try:
    result.output = readFile(tmpPath)
  except CatchableError:
    result.output = ""
  try:
    result.stderrOutput = readFile(errPath)
  except CatchableError:
    result.stderrOutput = ""

proc firstNonEmptyLine(text: string; limit = 200): string =
  for line in text.splitLines():
    let stripped = line.strip()
    if stripped.len > 0:
      return if stripped.len > limit: stripped[0 ..< limit] else: stripped
  ""

proc objectEndIndex(text: string; start: int): int =
  ## Index of the ``}`` closing the object that opens at ``text[start]``,
  ## or -1. Brace counting is string- and escape-aware so a ``}`` inside
  ## a test name (they contain arbitrary text) cannot end the scan early.
  if start >= text.len or text[start] != '{':
    return -1
  var depth = 0
  var i = start
  var inString = false
  var escaped = false
  while i < text.len:
    let c = text[i]
    if inString:
      if escaped: escaped = false
      elif c == '\\': escaped = true
      elif c == '"': inString = false
    else:
      case c
      of '"': inString = true
      of '{': inc depth
      of '}':
        dec depth
        if depth == 0:
          return i
      else: discard
    inc i
  -1

proc extractCatalogDocument(text: string): JsonNode =
  ## Decode the ``--list-json`` payload out of a possibly polluted stream.
  ##
  ## Mirrors ``extract_catalog_document`` in
  ## scripts/reprobuild_suite_inventory.py — the two probes must agree on
  ## what counts as a catalog, or the inventory and the runner disagree
  ## about which binaries are enumerable, which is precisely the drift
  ## that hid 170 opaque binaries. Keep them in step.
  ##
  ## Separating stderr from stdout (see ``runListJson``) removes the
  ## dominant source of pollution; this stays as defence in depth for the
  ## recorded case of a source with a top-level ``echo`` interleaving its
  ## own output with the payload on stdout itself.
  result = nil
  let trimmed = text.strip()
  if trimmed.len == 0:
    return

  proc accept(node: JsonNode): JsonNode =
    if node != nil and node.kind == JObject and node.hasKey("tests") and
        node["tests"].kind == JArray:
      node
    else:
      nil

  # (1) the clean case: the whole stream is the document.
  try:
    let whole = accept(parseJson(trimmed))
    if whole != nil:
      return whole
  except CatchableError:
    discard

  # (2) the payload is one line among leaked lines.
  for line in trimmed.splitLines():
    let candidate = line.strip()
    if not candidate.startsWith("{") or not candidate.contains("\"tests\""):
      continue
    try:
      let parsed = accept(parseJson(candidate))
      if parsed != nil:
        return parsed
    except CatchableError:
      discard

  # (3) the payload is embedded with leading and/or trailing noise.
  const Marker = "{\"tests\""
  var idx = trimmed.find(Marker)
  while idx >= 0:
    let stop = objectEndIndex(trimmed, idx)
    if stop > idx:
      try:
        let parsed = accept(parseJson(trimmed[idx .. stop]))
        if parsed != nil:
          return parsed
      except CatchableError:
        discard
    idx = trimmed.find(Marker, idx + 1)

proc probeBinary(binary: string): tuple[protocol: bool;
                                        catalog: seq[CatalogEntry]] =
  ## Decide whether the binary speaks the protocol and return its test
  ## catalog when so. Two stages: (1) cheap byte-scan for one of
  ## ``ProtocolMarkers`` — if none is present, the binary is treated as
  ## opaque without running it. (2) when a marker is present, invoke
  ## ``--list-json`` under a wall-clock bound and parse the JSON
  ## catalog out of the binary's stdout. Anything short of a well-formed
  ## catalog — non-zero exit, no decodable catalog, or the probe timing
  ## out — leaves the binary classified opaque, i.e. run whole. That is a
  ## degradation in granularity, never a failure: the cases still
  ## execute, they just stop being individually addressable.
  ##
  ## Every downgrade is now announced on stderr with its reason. The
  ## classification is a decision about 1200+ binaries taken silently
  ## once per run; when it was silent, a stderr-merge bug in the probe
  ## (see ``runListJson``) mislabelled 170 of them for an entire test
  ## campaign and nothing in any artifact said so.
  result.protocol = false
  result.catalog = @[]
  if not looksProtocolAwareByStrings(binary):
    return
  let stem = splitFile(binary).name
  let (output, stderrOutput, exitCode, timedOut) = runListJson(binary)
  if timedOut:
    stderr.writeLine "repro_test_runner: --list-json probe of " & stem &
      " exceeded " & $probeTimeoutSec() &
      "s; treating the binary as opaque (whole-binary execution)"
    return
  if exitCode != 0:
    stderr.writeLine "repro_test_runner: --list-json probe of " & stem &
      " exited " & $exitCode & " (" & firstNonEmptyLine(stderrOutput) &
      "); treating the binary as opaque (whole-binary execution)"
    return
  let doc = extractCatalogDocument(output)
  if doc == nil:
    # Say so. A silent downgrade here is how 170 binaries lost per-case
    # addressability for an entire campaign without a single line of
    # evidence in any log.
    stderr.writeLine "repro_test_runner: --list-json probe of " & stem &
      " produced no catalog document (stdout head: " &
      firstNonEmptyLine(output) & "); treating the binary as opaque " &
      "(whole-binary execution)"
    return
  try:
    var cat: seq[CatalogEntry] = @[]
    for entry in doc["tests"]:
      let suite = entry{"suite"}.getStr("")
      let name = entry{"name"}.getStr("")
      # ``name`` is the binary's own identifier for the case and the
      # ONLY string its ``--run`` matcher is guaranteed to accept. It is
      # carried through verbatim as ``runName``; the derived ``bare``
      # form below exists solely for display/report identity.
      #
      # The old code derived the ``--run`` argument by stripping
      # ``suite & "::"`` and re-joining. For a suite-less case
      # (``suite`` empty, ``name`` == ``"::testname"``) the guard
      # degenerated to ``startsWith("::")``, stripped the separator, and
      # re-emitted the bare ``testname`` — which the emitting binary
      # then failed to find. Deriving display text is fine; deriving the
      # execution argument is not.
      var bare = name
      if suite.len > 0 and name.startsWith(suite & "::"):
        bare = name[suite.len + 2 .. ^1]
      elif suite.len == 0 and name.startsWith("::"):
        bare = name[2 .. ^1]
      # Retention, not interpretation: each field is copied out with the
      # producer's own value and a neutral default when the key is
      # absent. ``xfail`` is deliberately rendered to text here so JSON
      # ``null`` (say nothing) and JSON ``false`` (say "not expected to
      # fail") do not collapse into the same Nim value.
      var xfail = ""
      let xfailNode = entry{"xfail"}
      if xfailNode != nil:
        case xfailNode.kind
        of JNull: xfail = ""
        of JString: xfail = xfailNode.getStr("")
        of JBool: xfail = (if xfailNode.getBool(): "true" else: "false")
        else: xfail = $xfailNode
      var tags: seq[string] = @[]
      let tagsNode = entry{"tags"}
      if tagsNode != nil and tagsNode.kind == JArray:
        for t in tagsNode:
          tags.add(if t.kind == JString: t.getStr("") else: $t)
      cat.add(CatalogEntry(
        suite: suite,
        bare: bare,
        runName: name,
        file: entry{"file"}.getStr(""),
        line: entry{"line"}.getInt(0),
        column: entry{"column"}.getInt(0),
        kind: entry{"kind"}.getStr(""),
        group: entry{"group"}.getStr(""),
        threadsRequired: entry{"threadsRequired"}.getInt(0),
        xfail: xfail,
        tags: tags,
        bodyHash: entry{"bodyHash"}.getStr(""),
        deterministic: entry{"deterministic"}.getBool(false)))
    result.protocol = true
    result.catalog = cat
  except JsonParsingError:
    return

# ---- run catalog: write, read, and hash-difference selection ---------
#
# WHAT THIS IS. A *run catalog* is a document the runner writes after
# probing (``--catalog-write PATH``) and may read back on a later run
# (``--catalog-read PATH``). It records, per binary, the ``bodyHash`` of
# every case that binary catalogued. On the later run, a case whose
# ``bodyHash`` is byte-identical to the recorded one is a candidate for
# being skipped; anything else runs.
#
# WHY IT IS A HINT AND NEVER A SOURCE OF TRUTH. This repository's
# boundary rules say JSON may be emitted for inspection but must not be
# an on-disk source of truth. The run catalog obeys that literally: it
# can only ever *remove* work, it is consulted exactly once at queue
# construction, and EVERY way of not understanding it — absent,
# unreadable, malformed, wrong version, written under a different
# project root or a different ``--bin-dir``, a binary it does not
# mention, a case it does not mention, an empty hash on either side —
# resolves to RUN THE CASE. There is no code path in which failing to
# understand the catalog causes a case to be skipped.
#
# WHY FAIL-CLOSED IS THE WHOLE POINT. A selection mechanism that
# silently under-runs converts a coverage loss into a green run, which is
# exactly the failure class this campaign exists to remove. So the
# default is "run", the catalog may only subtract from it, and every
# subtraction is announced on stderr and counted in the summary. A run
# with no ``--catalog-read`` is the full run, unchanged, and stays
# available at all times.
#
# WHY THE PROJECT ROOT IS PART OF THE DOCUMENT. ``bodyHash`` is NOT
# checkout-independent: the codetracer-nim fork's ``check``/``require``/
# ``expect``/``doAssert`` expansions bake the source file's ABSOLUTE path
# into a string literal inside the test body, and the compiler's
# body hash hashes literals verbatim. Two checkouts of identical sources
# at different absolute paths therefore produce entirely different
# hashes. A catalog written at one path and read at another would
# consequently show *every* case as changed — which is safe (it
# over-runs) — but it would also silently make the mechanism useless
# while looking like it worked. Recording the root and refusing to use a
# catalog from a different one turns that from a silent no-op into a
# stated refusal.

const RunCatalogVersion = 1

type
  RunCatalog = object
    ## A previously written run catalog, already validated against the
    ## current run's identity. Only constructed by ``loadRunCatalog``.
    projectRoot: string
    binDir: string
    hashes: Table[string, Table[string, string]]
      ## binary stem -> (catalog ``name`` -> ``bodyHash``). A stem that
      ## was opaque at write time is present with an EMPTY inner table,
      ## which selects every case of that binary on the read side. The
      ## distinction between "absent" and "present but empty" is not
      ## load-bearing today precisely because both resolve to "run".

  SelectionDecision = object
    ## Why the runner is about to run the case set it is about to run.
    ## Carried into the summary so a reader of the artifact alone can
    ## tell a deliberate subset from an accidental one.
    enabled: bool     ## a ``--catalog-read`` was given at all
    usable: bool      ## the catalog was understood and applied
    reason: string    ## why it was not usable; "" when it was
    path: string      ## the ``--catalog-read`` path, verbatim

proc runCatalogDocument(cwd, binDir: string;
                        probed: seq[tuple[stem: string;
                                          protocol: bool;
                                          catalog: seq[CatalogEntry]]]
                       ): JsonNode =
  ## Render the just-probed binary set as a run-catalog document. The
  ## per-binary shape deliberately mirrors the codetracer-nim
  ## ``--catalog -`` payload (``{"version":1,"tests":{name: hash}}``) so
  ## the two are readable with the same eyes; the wrapper adds only the
  ## identity a *multi-binary* run needs and a single binary cannot know.
  result = newJObject()
  result["version"] = %RunCatalogVersion
  result["projectRoot"] = %cwd
  result["binDir"] = %binDir
  var binaries = newJObject()
  for entry in probed:
    var node = newJObject()
    node["protocol"] = %entry.protocol
    var tests = newJObject()
    for c in entry.catalog:
      tests[c.runName] = %c.bodyHash
    node["tests"] = tests
    binaries[entry.stem] = node
  result["binaries"] = binaries

proc loadRunCatalog(path, cwd, binDir: string):
    tuple[catalog: RunCatalog; usable: bool; reason: string] =
  ## Read a run catalog and validate it against THIS run's identity.
  ## Returns ``usable = false`` with a stated reason for every way of not
  ## understanding it. The caller must then run everything.
  result.usable = false
  result.catalog = RunCatalog(hashes: initTable[string, Table[string, string]]())
  if not fileExists(path):
    result.reason = "no catalog at " & path
    return
  var raw = ""
  try:
    raw = readFile(path)
  except CatchableError as e:
    result.reason = "catalog at " & path & " could not be read (" & e.msg & ")"
    return
  var doc: JsonNode = nil
  try:
    doc = parseJson(raw)
  except CatchableError as e:
    result.reason = "catalog at " & path & " is not valid JSON (" & e.msg & ")"
    return
  if doc == nil or doc.kind != JObject:
    result.reason = "catalog at " & path & " is not a JSON object"
    return
  let version = doc{"version"}.getInt(-1)
  if version != RunCatalogVersion:
    result.reason = "catalog at " & path & " is version " & $version &
      ", this runner writes version " & $RunCatalogVersion
    return
  let recordedRoot = doc{"projectRoot"}.getStr("")
  if recordedRoot != cwd:
    # See the header note: bodyHash is path-dependent, so a catalog from
    # another root cannot be compared against this one at all.
    result.reason = "catalog at " & path & " was written under project root " &
      (if recordedRoot.len > 0: recordedRoot else: "<unrecorded>") &
      ", this run is under " & cwd &
      " (bodyHash is not checkout-independent, so the two are incomparable)"
    return
  let recordedBinDir = doc{"binDir"}.getStr("")
  if recordedBinDir != binDir:
    result.reason = "catalog at " & path & " was written for --bin-dir " &
      (if recordedBinDir.len > 0: recordedBinDir else: "<unrecorded>") &
      ", this run uses " & binDir
    return
  let binaries = doc{"binaries"}
  if binaries == nil or binaries.kind != JObject:
    result.reason = "catalog at " & path & " carries no \"binaries\" object"
    return
  for stem, node in binaries.pairs:
    var inner = initTable[string, string]()
    if node != nil and node.kind == JObject:
      let tests = node{"tests"}
      if tests != nil and tests.kind == JObject and
          node{"protocol"}.getBool(false):
        for name, hashNode in tests.pairs:
          if hashNode != nil and hashNode.kind == JString:
            inner[name] = hashNode.getStr("")
    result.catalog.hashes[stem] = inner
  result.catalog.projectRoot = recordedRoot
  result.catalog.binDir = recordedBinDir
  result.usable = true

proc caseIsUnchanged(catalog: RunCatalog; stem: string;
                     entry: CatalogEntry): bool =
  ## True only when the catalog positively vouches for this exact case:
  ## the binary is named, the case is named under it, both hashes are
  ## non-empty, and they are byte-identical. Every other combination is
  ## false, i.e. "run it".
  if stem notin catalog.hashes:
    return false
  let inner = catalog.hashes[stem]
  if entry.runName notin inner:
    return false
  let recorded = inner[entry.runName]
  # An empty hash on EITHER side means a producer told us nothing, and
  # two silences are not an agreement. This is not hypothetical: this
  # repository contains a second, older protocol producer — the vendored
  # ``libs/ct_test_unittest_parallel`` shim, imported by thirteen test
  # files — whose ``--list-json`` rows carry ``name``/``suite``/``file``/
  # ``line`` and no ``bodyHash`` at all. Without this guard, every case in
  # every shim-built binary would compare "" against "", match, and be
  # silently deselected forever. The guard is written as one condition on
  # purpose: split across two statements, one half sat behind the other
  # and could not be shown to do anything.
  if entry.bodyHash.len == 0 or recorded.len == 0:
    return false
  recorded == entry.bodyHash

proc buildEngine(repoRoot: string): bool =
  ## Drive the engine build of the ``test`` aggregate. Returns true on
  ## success. Skipped (no-op, returns true) if ``./build/bin/repro`` is
  ## not present — the calling shell script has already done the build
  ## in that case.
  let repro = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  if not fileExists(repro):
    return true
  stderr.writeLine "repro_test_runner: building :test aggregate"
  let cmd = quoteShell(repro) & " build test"
  let exitCode = execCmd(cmd)
  if exitCode != 0:
    stderr.writeLine "repro_test_runner: repro build test exited " &
      $exitCode
    return false
  true

proc qualifyName(binaryStem, suite, name: string): string =
  if suite.len > 0:
    suite & "::" & name
  else:
    name

# Module-global lock that serialises the child-process spawn step
# (``pipe()`` + ``fork()``/``execve``) across all worker threads.
#
# Why this is needed: on Linux, ``osproc.startProcess`` uses bare
# ``pipe()`` (no ``O_CLOEXEC``) and a bare ``fork()`` from whatever
# worker happens to call it. Two hazards stack up under
# ``--threads=8/16``:
#
# 1. **Pipe FD leak.** Between this thread's ``pipe()`` and the
#    parent's post-spawn ``close()`` of the unused pipe ends, a sibling
#    worker's ``fork()`` will copy those FDs into its own child as
#    ghost holders. The ghost holders prevent EOF on the parent-side
#    read of this thread's stream and can shift FD numbering so the
#    later ``close()`` operates on a different FD than expected.
# 2. **Fork inside multithreaded process.** Nim's
#    ``startProcessAfterFork`` calls non-async-signal-safe code
#    (``findExe``, GC allocations) in the child between ``fork()`` and
#    ``execve``. If another thread held a glibc internal lock (malloc
#    arena, etc.) at fork time, the child sees that lock as
#    permanently held — manifesting as a sporadic
#    ``Bad file descriptor [OSError]`` raised back through the error
#    pipe.
#
# Serialising the spawn step closes hazard (1) entirely: by the time
# ``startProcess`` returns, the parent has closed every pipe end it
# doesn't keep, and no sibling fork can have observed our pipe FDs.
# It also shrinks hazard (2)'s window to "no other worker is forking
# concurrently", which empirically takes the residual failure rate
# from "tears down the runner every few seconds at --threads=16" to
# "occasional, recoverable". The stream drain and ``waitForExit``
# happen with the lock released so per-test concurrency is preserved.
var spawnLock: Lock
initLock(spawnLock)

const TimeoutExitCode = -42
const HarnessErrorExitCode = 126
  ## Reserved child exit status meaning "the harness could not start the
  ## test", written by ``processGroupWrapperMain`` after its own spawn
  ## retries are exhausted. 126 is the shell's "command found but not
  ## executable", i.e. already a not-a-test-result code by convention.
  ##
  ## The convention existed before this change but nothing consumed it:
  ## the exit-code switch had no 126 arm, so a wrapper-side harness error
  ## fell through to ``else: tsFail`` and was reported as a failing test.
  ## It now maps to ``tsHarnessError``. A test that deliberately exits
  ## 126 is misreported by this rule; that is the accepted cost of having
  ## a reserved code at all, and no test in the suite does so.
const TimeoutPollIntervalMs = 100
const TimeoutKillGraceSec = 5
const PostKillVerificationSec = 5

proc drainAvailable(p: Process; output: var string): int
proc finalDrainNonBlocking(p: Process; output: var string)
proc describeChildExit(exitCode: int): string

when defined(posix):
  const
    ProcessGroupWrapperFlag = "--internal-test-process-group"
    ProcessGroupReadyMarker = "REPRO_TEST_RUNNER_GROUP_READY_V1"
    GroupSupervisorPollIntervalMs = 10
    TestOwnerEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"
    CleanupTraceEnv = "REPRO_TEST_RUNNER_CLEANUP_TRACE"

  type
    ActiveProcessGroup = ref object
      processGroup: int
      anchorPid: int
      ownerToken: string
      anchorReaped: bool

  var
    activeProcessGroupsLock: Lock
    activeProcessGroups: seq[ActiveProcessGroup] = @[]
    nextProcessGroupToken = 0
    processGroupStateDir = ""
    cleanupTracePath = ""
    interruptedSignal: Atomic[int]
    interruptSignalSet: Sigset

  initLock(activeProcessGroupsLock)

  proc appendCleanupTrace(event: string) =
    ## Optional production-path observability used by the real process-tree
    ## integration regression. Cleanup correctness never depends on this file:
    ## a missing/unwritable trace must not prevent owned processes from being
    ## terminated.
    if cleanupTracePath.len == 0:
      return
    try:
      let trace = open(cleanupTracePath, fmAppend)
      trace.writeLine(event)
      trace.close()
    except CatchableError:
      discard

  var wrapperTerminationSignal {.global, volatile.}: Sig_atomic

  proc recordWrapperTermination(sig: cint) {.noconv, gcsafe, raises: [].} =
    ## The internal group supervisor must survive the graceful TERM phase so
    ## its PID continues to reserve the process-group identity until the
    ## parent sends SIGKILL. A custom handler (rather than SIG_IGN) is
    ## deliberate: handled dispositions reset to default across exec, while an
    ## ignored SIGTERM would be inherited by the actual test executable.
    wrapperTerminationSignal = Sig_atomic(sig)

  proc unblockWrapperSignals() =
    var signals, oldSignals: Sigset
    discard sigemptyset(signals)
    discard sigaddset(signals, SIGINT)
    discard sigaddset(signals, SIGTERM)
    discard sigaddset(signals, SIGHUP)
    discard pthread_sigmask(SIG_UNBLOCK, signals, oldSignals)

  proc writeGroupStatus(path: string; exitCode: int) =
    let pendingPath = path & ".pending"
    writeFile(pendingPath, $exitCode & "\n")
    moveFile(pendingPath, path)

  proc processGroupWrapperMain(params: seq[string]): int =
    ## Hidden, shell-free supervisor used only by the parent runner. It creates
    ## the process group from inside the child, before the real test is
    ## launched, so Linux's fork-based osproc path and macOS's posix_spawn path
    ## have identical ownership semantics.
    if params.len < 2:
      stderr.writeLine(
        "repro_test_runner: internal process-group wrapper arguments missing")
      return 125
    let statusPath = params[0]
    let binary = params[1]
    let binaryArgs =
      if params.len > 2: params[2 .. ^1]
      else: @[]

    if setpgid(Pid(0), Pid(0)) != 0:
      stderr.writeLine(
        "repro_test_runner: internal process-group setup failed: " &
        osErrorMsg(osLastError()))
      return 125

    signal(SIGINT, recordWrapperTermination)
    signal(SIGTERM, recordWrapperTermination)
    signal(SIGHUP, recordWrapperTermination)
    unblockWrapperSignals()

    # The parent consumes this private first line before returning the spawn to
    # a worker. Since the real child is launched only afterwards, arbitrary
    # test output can never race ahead of the readiness record.
    stdout.writeLine(ProcessGroupReadyMarker)
    stdout.flushFile()

    var child: Process
    var exitCode = 125
    # A spawn failure is the HARNESS failing to start the test, not the test
    # failing. Observed in practice as EACCES against a mode-0755 binary that
    # runs fine standalone — an exec racing the build that wrote it, or a
    # transient fork/exec resource condition under concurrent workers. Both are
    # self-clearing, so retry a bounded number of times with a short backoff
    # before giving up. `waitForExit` is deliberately NOT retried: once the
    # child is running its exit status is the test's answer, whatever it is.
    const
      SpawnAttempts = 4
      SpawnRetryDelayMs = 250
    var spawnError = ""
    for attempt in 1 .. SpawnAttempts:
      spawnError = ""
      try:
        child = startProcess(binary, args = binaryArgs,
          options = {poParentStreams})
      except OSError as e:
        spawnError = e.msg
        if attempt < SpawnAttempts:
          stderr.writeLine(
            "repro_test_runner: spawn attempt " & $attempt & " of " &
            $SpawnAttempts & " failed (" & e.msg & "); retrying")
          sleep(SpawnRetryDelayMs * attempt)
          continue
        break
      try:
        exitCode = child.waitForExit()
        close(child)
      except IOError as e:
        stderr.writeLine(
          "repro_test_runner: internal process-group child wait failed: " &
          e.msg)
      break
    if spawnError.len > 0:
      # Exit 126 ("command found but not executable") distinguishes a harness
      # spawn failure from any status the test itself could return, so a suite
      # summary can separate "the code is broken" from "we could not run it".
      exitCode = 126
      stderr.writeLine(
        "repro_test_runner: HARNESS ERROR — child spawn failed after " &
        $SpawnAttempts & " attempts: " & spawnError)
    try:
      writeGroupStatus(statusPath, exitCode)
    except CatchableError as e:
      stderr.writeLine(
        "repro_test_runner: internal process-group status failed: " & e.msg)
      return 125

    # Stay alive as the group anchor even after the direct test child exits.
    # Every completion path TERM/KILLs all exact-token descendants and this
    # complete group before it reports the result. Keeping the anchor until
    # SIGKILL prevents its PGID from being reused during that cleanup window.
    while true:
      sleep(GroupSupervisorPollIntervalMs)
    exitCode

  proc removeActiveProcessGroupUnlocked(processGroup: int) =
    for i, current in activeProcessGroups:
      if current.processGroup == processGroup:
        activeProcessGroups.delete(i)
        return

  proc findActiveProcessGroupUnlocked(processGroup: int):
      tuple[found: bool; group: ActiveProcessGroup] =
    for current in activeProcessGroups:
      if current.processGroup == processGroup:
        return (true, current)

  proc registerActiveProcessGroup(processGroup: int; ownerToken: string) =
    acquire(activeProcessGroupsLock)
    activeProcessGroups.add(ActiveProcessGroup(
      processGroup: processGroup,
      anchorPid: processGroup,
      ownerToken: ownerToken))
    release(activeProcessGroupsLock)

  proc signalProcessGroup(active: ActiveProcessGroup; sig: cint) =
    ## Revalidate the exact supervisor anchor still leads its recorded group
    ## immediately before using a negative-PID signal; a dead/reused PID must
    ## never redirect cleanup to an unrelated group.
    ##
    ## ``anchorReaped`` is monotonic state on the registered group object, not
    ## per-cleanup-call state. A bounded owner-token verification can fail
    ## after this invocation has already reaped the supervisor; a later final
    ## reaper/interrupt retry must then remain token-only even if the kernel
    ## has reused the old PID/PGID.
    if active.isNil or active.anchorReaped:
      return
    appendCleanupTrace(
      "group-signal-attempt group=" & $active.processGroup &
      " signal=" & $sig)
    if active.anchorPid > 0 and active.processGroup > 0 and
        getpgid(Pid(active.anchorPid)) == Pid(active.processGroup):
      discard kill(Pid(-active.processGroup), sig)

  when defined(linux):
    proc processHasOwnerToken(pid: int; ownerToken: string): bool =
      if pid <= 0 or ownerToken.len == 0:
        return false
      try:
        let environment = readFile("/proc" / $pid / "environ")
        let expected = TestOwnerEnv & "=" & ownerToken
        for entry in environment.split('\0'):
          if entry == expected:
            return true
      except CatchableError:
        discard

    proc ownedProcessIds(ownerToken: string): seq[int] =
      if ownerToken.len == 0 or not dirExists("/proc"):
        return
      for kind, path in walkDir("/proc"):
        if kind != pcDir:
          continue
        var pid = 0
        try:
          pid = parseInt(path.lastPathPart)
        except ValueError:
          continue
        if pid != getCurrentProcessId() and
            processHasOwnerToken(pid, ownerToken):
          result.add(pid)

  elif defined(macosx):
    const
      ProcAllPids = 1'u32
      PidGrowthMargin = 64

    type DarwinPid = int32

    proc procListPids(kind, kindInfo: uint32; buffer: pointer;
                      bufferSize: cint): cint {.
      importc: "proc_listpids", header: "<libproc.h>".}

    {.emit: """
      #include <stdlib.h>
      #include <string.h>
      #include <sys/sysctl.h>

      static int repro_process_has_exact_env_entry(
          int pid, const char *expected) {
        int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
        size_t size = 0;
        if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) {
          return 0;
        }
        char *buffer = (char *)malloc(size);
        if (buffer == NULL) return 0;
        if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0) {
          free(buffer);
          return 0;
        }
        if (size < sizeof(int)) {
          free(buffer);
          return 0;
        }

        int argc = 0;
        memcpy(&argc, buffer, sizeof(argc));
        if (argc < 0) {
          free(buffer);
          return 0;
        }

        /*
         * KERN_PROCARGS2 is:
         *
         *   argc, executable path, NUL padding, argv[0..argc-1],
         *   NUL padding, environment entries
         *
         * Do not scan the complete buffer. An unrelated process may carry a
         * literal argv element that happens to equal our owner-token entry;
         * only the environment segment establishes ownership.
         */
        size_t cursor = sizeof(int);
        while (cursor < size && buffer[cursor] != '\0') ++cursor;
        if (cursor >= size) {
          free(buffer);
          return 0;
        }
        while (cursor < size && buffer[cursor] == '\0') ++cursor;

        for (int arg = 0; arg < argc; ++arg) {
          if (cursor >= size) {
            free(buffer);
            return 0;
          }
          while (cursor < size && buffer[cursor] != '\0') ++cursor;
          if (cursor >= size) {
            free(buffer);
            return 0;
          }
          ++cursor;
        }
        while (cursor < size && buffer[cursor] == '\0') ++cursor;

        const size_t expected_len = strlen(expected);
        int found = 0;
        while (cursor < size) {
          size_t end = cursor;
          while (end < size && buffer[end] != '\0') ++end;
          if (end - cursor == expected_len &&
              memcmp(buffer + cursor, expected, expected_len) == 0) {
            found = 1;
            break;
          }
          if (end >= size) break;
          cursor = end + 1;
        }
        free(buffer);
        return found;
      }
    """.}

    proc macProcessHasExactEnvEntry(pid: cint; expected: cstring): cint {.
      importc: "repro_process_has_exact_env_entry", nodecl.}

    proc processHasOwnerToken(pid: int; ownerToken: string): bool =
      if pid <= 0 or ownerToken.len == 0:
        return false
      let expected = TestOwnerEnv & "=" & ownerToken
      macProcessHasExactEnvEntry(cint(pid), expected.cstring) != 0

    proc ownedProcessIds(ownerToken: string): seq[int] =
      if ownerToken.len == 0:
        return
      let queriedBytes = procListPids(ProcAllPids, 0'u32, nil, 0.cint)
      if queriedBytes <= 0:
        return
      let pidBytes = sizeof(DarwinPid)
      var capacity =
        (int(queriedBytes) + pidBytes - 1) div pidBytes + PidGrowthMargin
      for _ in 0 ..< 3:
        var pids = newSeq[DarwinPid](capacity)
        let returnedBytes = procListPids(
          ProcAllPids, 0'u32, addr pids[0], cint(pids.len * pidBytes))
        if returnedBytes < 0:
          return
        if int(returnedBytes) < pids.len * pidBytes:
          let returnedCount = int(returnedBytes) div pidBytes
          for i in 0 ..< returnedCount:
            let pid = int(pids[i])
            if pid > 0 and pid != getCurrentProcessId() and
                processHasOwnerToken(pid, ownerToken):
              result.add(pid)
          return
        capacity *= 2

  else:
    proc processHasOwnerToken(pid: int; ownerToken: string): bool =
      discard pid
      discard ownerToken
      false

    proc ownedProcessIds(ownerToken: string): seq[int] =
      discard ownerToken
      @[]

  proc signalOwnedProcesses(active: ActiveProcessGroup; sig: cint;
                            exceptPid = 0) =
    ## The exact per-test environment token survives fork/exec and setsid.
    ## Revalidate every enumerated PID immediately before signalling it. The
    ## enumeration-to-kill window can contain PID reuse; an unrelated
    ## replacement PID cannot carry the private token.
    let ownerPids = ownedProcessIds(active.ownerToken)
    appendCleanupTrace(
      "owner-snapshot group=" & $active.processGroup &
      " signal=" & $sig & " count=" & $ownerPids.len)
    for pid in ownerPids:
      if pid != exceptPid and
          processHasOwnerToken(pid, active.ownerToken):
        appendCleanupTrace(
          "owner-signal-attempt group=" & $active.processGroup &
          " pid=" & $pid & " signal=" & $sig)
        discard kill(Pid(pid), sig)

  proc ownedProcessesRemain(ownerToken: string; exceptPid = 0): bool =
    for pid in ownedProcessIds(ownerToken):
      if pid != exceptPid:
        return true

  proc killAndVerifyOwnedProcesses(
      activeGroups: openArray[ActiveProcessGroup]): bool =
    ## SIGKILL closes the graceful phase, but a single process snapshot is not
    ## a cleanup barrier: a detached token-bearing descendant can fork between
    ## enumeration and signal delivery. Re-enumerate, revalidate, and retry for
    ## a bounded interval. Success means an exact post-KILL enumeration found no
    ## owner token; callers must not unregister or publish PASS otherwise.
    ##
    ## Group and token cleanup are deliberately separate phases. The recorded
    ## process group is signalled exactly once while its unreaped supervisor
    ## still reserves the PGID. Only after every supervisor has been reaped do
    ## we enter the retryable token-owner phase. It is therefore structurally
    ## impossible for a later retry to target a reused anchor PID/PGID.
    let deadline = epochTime() + PostKillVerificationSec.float
    # This is the only process-group signal in the function. No control-flow
    # edge from the token-owner retry phase below returns here.
    for active in activeGroups:
      signalProcessGroup(active, SIGKILL)

    # Reap every exact supervisor before allowing the cleanup to proceed using
    # only token ownership. A setsid/poDaemon descendant can intentionally
    # remain alive here; it cannot reserve or authenticate the recorded PGID.
    while true:
      var anchorsRemain = false
      for active in activeGroups:
        if not active.anchorReaped:
          var status: cint
          while true:
            let reaped = waitpid(Pid(active.anchorPid), status, WNOHANG)
            if reaped == Pid(active.anchorPid):
              # Persist retirement on the exact registry object before any
              # retry can release/reacquire the registry lock. From this point
              # onward no group-signal entry point may target this PID/PGID.
              active.anchorReaped = true
              appendCleanupTrace(
                "anchor-reaped group=" & $active.processGroup)
              break
            if reaped < 0 and errno == EINTR:
              continue
            if reaped < 0 and errno == ECHILD:
              # ECHILD means this runner no longer owns a waitable child at
              # the recorded PID. Treat the group identity as permanently
              # retired: signalling it can only be less safe than continuing
              # with exact-token ownership.
              active.anchorReaped = true
              appendCleanupTrace(
                "anchor-already-reaped group=" & $active.processGroup)
            break
        if not active.anchorReaped:
          anchorsRemain = true
      if not anchorsRemain:
        break
      if epochTime() >= deadline:
        return false
      sleep(GroupSupervisorPollIntervalMs)

    # Detached exact-token descendants are killed and verified only after all
    # anchors are reaped. Every retry is PID-safe: enumeration and immediate
    # pre-signal revalidation both require the exact private token.
    while true:
      var ownersRemain = false
      for active in activeGroups:
        if ownedProcessesRemain(active.ownerToken,
                                exceptPid = active.anchorPid):
          ownersRemain = true
          break
      if not ownersRemain:
        return true
      for active in activeGroups:
        signalOwnedProcesses(active, SIGKILL,
          exceptPid = active.anchorPid)
      if epochTime() >= deadline:
        return false
      sleep(TimeoutPollIntervalMs)

  proc terminateProcessGroupLocked(active: ActiveProcessGroup): bool =
    ## Caller holds activeProcessGroupsLock, which keeps this registered group
    ## anchored until escalation completes and prevents concurrent normal
    ## release from making the PGID available for reuse. The environment-token
    ## pass also reaches test-owned grandchildren that deliberately escaped the
    ## group with setsid/poDaemon.
    signalProcessGroup(active, SIGTERM)
    signalOwnedProcesses(active, SIGTERM,
      exceptPid = active.anchorPid)
    let killDeadline = epochTime() + TimeoutKillGraceSec.float
    while ownedProcessesRemain(active.ownerToken,
                               exceptPid = active.anchorPid) and
        epochTime() < killDeadline:
      sleep(TimeoutPollIntervalMs)
    killAndVerifyOwnedProcesses([active])

  proc terminateOwnedProcessGroup(processGroup: int): bool =
    acquire(activeProcessGroupsLock)
    let active = findActiveProcessGroupUnlocked(processGroup)
    if active.found:
      result = terminateProcessGroupLocked(active.group)
    else:
      result = true
    release(activeProcessGroupsLock)

  proc terminateAllActiveProcessGroups(): bool =
    ## Holding the registry serializes cleanup against concurrent release.
    ## Unreaped entries retain a live or reserved supervisor anchor through
    ## process-group signalling and reap; retired entries are token-only, and
    ## signalProcessGroup is a no-op for them.
    acquire(activeProcessGroupsLock)
    if activeProcessGroups.len == 0:
      release(activeProcessGroupsLock)
      return true
    for active in activeProcessGroups:
      signalProcessGroup(active, SIGTERM)
      signalOwnedProcesses(active, SIGTERM,
        exceptPid = active.anchorPid)
    let killDeadline = epochTime() + TimeoutKillGraceSec.float
    var descendantsRemain = true
    while descendantsRemain and epochTime() < killDeadline:
      descendantsRemain = false
      for active in activeProcessGroups:
        if ownedProcessesRemain(active.ownerToken,
                                exceptPid = active.anchorPid):
          descendantsRemain = true
          break
      if descendantsRemain:
        sleep(TimeoutPollIntervalMs)
    result = killAndVerifyOwnedProcesses(activeProcessGroups)
    release(activeProcessGroupsLock)

  proc reapResidualActiveProcessGroups(): bool =
    ## Worker joins are the normal reap barrier. This final invariant is a
    ## fail-closed backstop: a signal exit is never allowed to return while a
    ## registered supervisor remains, even if a worker aborted unexpectedly.
    ## Workers are already joined when this runs, so the registry cannot gain
    ## new entries. Retry any incomplete worker/signal cleanup, but retain the
    ## anchor registrations and refuse summary emission if an exact owner still
    ## survives the bounded verification interval.
    if not terminateAllActiveProcessGroups():
      return false
    acquire(activeProcessGroupsLock)
    activeProcessGroups.setLen(0)
    release(activeProcessGroupsLock)
    true

  proc interruptWaiter(signalSet: ptr Sigset) {.thread.} =
    var received: cint
    if sigwait(signalSet[], received) == 0:
      interruptedSignal.store(int(received), moRelease)
      {.cast(gcsafe).}:
        # The registry is protected by activeProcessGroupsLock; the cast only
        # tells Nim's thread-effect checker about that explicit synchronization.
        discard terminateAllActiveProcessGroups()

  proc startInterruptWaiter(): Thread[ptr Sigset] =
    ## Blocking before worker creation makes every worker inherit the mask.
    ## A dedicated sigwait thread can then take ordinary locks and perform the
    ## bounded two-phase cleanup without running non-signal-safe Nim code from
    ## an asynchronous signal handler.
    var oldSignals: Sigset
    discard sigemptyset(interruptSignalSet)
    discard sigaddset(interruptSignalSet, SIGINT)
    discard sigaddset(interruptSignalSet, SIGTERM)
    discard sigaddset(interruptSignalSet, SIGHUP)
    if pthread_sigmask(SIG_BLOCK, interruptSignalSet, oldSignals) != 0:
      raise newException(OSError,
        "repro_test_runner: could not block interrupt signals")
    createThread(result, interruptWaiter, addr interruptSignalSet)

  proc newProcessGroupPaths():
      tuple[statusPath, ownerToken: string] =
    if processGroupStateDir.len == 0:
      raise newException(IOError,
        "repro_test_runner: process-group state directory is not initialized")
    inc nextProcessGroupToken
    let token = $getCurrentProcessId() & "-" & $nextProcessGroupToken
    result.statusPath = processGroupStateDir / (token & ".status")
    result.ownerToken = processGroupStateDir.lastPathPart & "-" & token

  proc cleanupProcessGroupPaths(testProcess: TestProcess) =
    for path in [
      testProcess.statusPath,
      testProcess.statusPath & ".pending",
    ]:
      if fileExists(path):
        try:
          removeFile(path)
        except CatchableError:
          discard

  proc cleanupProcessGroupStateDir() =
    if processGroupStateDir.len > 0 and dirExists(processGroupStateDir):
      try:
        removeDir(processGroupStateDir)
      except CatchableError:
        discard
    processGroupStateDir = ""

  proc finishInterruptedTestProcess(testProcess: TestProcess;
                                    output: var string): bool =
    ## The sigwait thread has already completed group-wide TERM/KILL and
    ## synchronously reaped the supervisor before it releases
    ## activeProcessGroupsLock. Remove the registry entry only after the same
    ## exact-owner check succeeds.
    acquire(activeProcessGroupsLock)
    try:
      if findActiveProcessGroupUnlocked(testProcess.processGroup).found:
        if not ownedProcessesRemain(testProcess.ownerToken,
                                    exceptPid = testProcess.processGroup):
          removeActiveProcessGroupUnlocked(testProcess.processGroup)
          result = true
    finally:
      release(activeProcessGroupsLock)
    if result:
      finalDrainNonBlocking(testProcess.process, output)
      close(testProcess.process)
      cleanupProcessGroupPaths(testProcess)
    else:
      output.add(
        "\nrepro_test_runner: interrupt cleanup left exact owner-token " &
        "processes; refusing to unregister the process group.\n")

const
  ParentSpawnAttempts = 4
  ParentSpawnRetryDelayMs = 250
    ## Bounded retry around the PARENT-side spawn of the process-group
    ## supervisor.
    ##
    ## ``processGroupWrapperMain`` already retries the spawn of the test
    ## binary *inside* the wrapper, but that covers only the second of the
    ## two forks in this path. The first fork — the runner spawning the
    ## wrapper — had no retry at all, which is why a full-suite run at
    ## ``--threads=8`` recorded ``spawn failed: Bad file descriptor`` as a
    ## flat test FAILURE with no retry line anywhere in the console log.
    ##
    ## ``EBADF`` here comes out of ``startProcessAfterFork``: the forked
    ## child ``dup2()``s the pipe ends it captured before the fork, and a
    ## failing ``dup2`` reports its ``errno`` back to the parent through
    ## the error pipe, where ``osproc`` re-raises it as ``OSError``. It is
    ## a property of the moment, not of the binary, so a short backoff
    ## clears it. Retrying is what makes the residual-fork-hazard note on
    ## ``spawnLock`` actionable instead of merely descriptive.
    ##
    ## Retry covers ONLY the spawn. A supervisor that started and then
    ## failed its readiness/process-group handshake is not retried: at
    ## that point a child exists, and re-spawning would risk two live
    ## groups for one case.

proc spawnGroupSupervisor(binary: string; args: openArray[string];
                          env: StringTableRef): TestProcess =
  when defined(posix):
    if interruptedSignal.load(moAcquire) != 0:
      raise newException(IOError,
        "runner interrupted before test process spawn")
  acquire(spawnLock)
  try:
    when defined(posix):
      let paths = newProcessGroupPaths()
      let wrapperArgs =
        @[ProcessGroupWrapperFlag, paths.statusPath, binary] & @args
      env[TestOwnerEnv] = paths.ownerToken
      let process = startProcess(
        getAppFilename(), args = wrapperArgs, env = env,
        options = {poStdErrToStdOut})
      var readyLine = ""
      let waitStart = epochTime()
      let gotLine = process.outputStream.readLine(readyLine)
      let waitedMs = int((epochTime() - waitStart) * 1000.0)
      if not gotLine or readyLine != ProcessGroupReadyMarker:
        # Collect the evidence BEFORE tearing the supervisor down — every
        # fact below used to be discarded, which is why this failure could
        # only ever report the phase and never the cause. The supervisor's
        # exit status in particular is the difference between "it refused"
        # (125, its own setpgid/arguments guard), "it was killed" (128+N),
        # and "it never got as far as running" (a loader/runtime failure).
        var supervisorExit = -1
        var weKilledIt = false
        var trailing = ""
        # Reap on its OWN terms first. A supervisor that is failing this
        # handshake is already on its way out, so give it a short grace
        # window and take the status it chose. Killing first and reporting
        # what came back would attribute OUR SIGKILL to the supervisor —
        # the message would say "exit code 137 (consistent with termination
        # by signal 9)" about a process that was about to exit 125 on its
        # own, which is worse than saying nothing.
        let reapDeadline = epochTime() + 0.25
        try:
          while epochTime() < reapDeadline:
            supervisorExit = process.peekExitCode()
            if supervisorExit >= 0:
              break
            sleep(GroupSupervisorPollIntervalMs)
          if supervisorExit < 0:
            weKilledIt = true
            process.kill()
            discard process.waitForExit()
        except CatchableError:
          discard
        # Anything the supervisor managed to write after (or instead of) the
        # marker: its own stderr guards are merged onto this pipe by
        # ``poStdErrToStdOut``, so this is where a real refusal message lands.
        try:
          finalDrainNonBlocking(process, trailing)
        except CatchableError:
          discard
        close(process)
        let observed =
          if not gotLine:
            "end of stream — the supervisor's stdout closed without " &
              "delivering a single line"
          elif readyLine.len == 0:
            "an empty line (the stream was open, but the first line " &
              "carried no bytes)"
          else:
            "a different first line: " & readyLine.escape()
        let exitText =
          if supervisorExit >= 0:
            describeChildExit(supervisorExit)
          elif weKilledIt:
            "still running 250ms after the handshake failed; the runner " &
              "killed it, so it has no exit status of its own to report"
          else:
            "not reported (the supervisor could not be reaped)"
        let trailingText =
          if trailing.strip().len == 0: "(none)"
          else: trailing.strip().escape()
        raise newException(IOError,
          "test process-group supervisor did not become ready.\n" &
          "  waiting for: the readiness marker " &
            ProcessGroupReadyMarker.escape() &
            " as the first line of the supervisor's merged stdout+stderr\n" &
          "  waited:      " & $waitedMs & "ms (a blocking read with no " &
            "deadline; it returns as soon as the line or EOF arrives)\n" &
          "  observed:    " & observed & "\n" &
          "  supervisor:  " & exitText & "\n" &
          "  also wrote:  " & trailingText & "\n" &
          "  test binary: " & binary & "\n" &
          # Hard-wrapped: this is printed to the console per affected case,
          # where one 300-column line is not a diagnosis anyone reads.
          "  meaning:     the supervisor is a re-exec of THIS runner that " &
            "writes the marker only after\n" &
          "               setpgid() succeeds and its signal handlers are " &
            "installed, and before it\n" &
          "               spawns the test binary — so nothing here has run " &
            "the test yet, and this is\n" &
          "               a harness fault, never a verdict about the code " &
            "under test. Read it as:\n" &
          "               exit 125 is the wrapper refusing on purpose and " &
            "the reason is on the\n" &
          "               'also wrote' line; 128+N is something killing it; " &
            "no exit status at all\n" &
          "               means the re-exec never reached Nim's main " &
            "(loader failure, fd\n" &
          "               exhaustion, or the image being replaced " &
            "mid-spawn).")
      let processGroup = process.processID
      if processGroup <= 0 or
          getpgid(Pid(processGroup)) != Pid(processGroup):
        try:
          process.kill()
          discard process.waitForExit()
        except CatchableError:
          discard
        close(process)
        raise newException(IOError,
          "test process-group supervisor did not own its expected group")
      result = TestProcess(
        process: process,
        processGroup: processGroup,
        ownerToken: paths.ownerToken,
        statusPath: paths.statusPath)
      registerActiveProcessGroup(processGroup, paths.ownerToken)
    else:
      result.process = startProcess(
        binary, args = args, env = env,
        options = {poStdErrToStdOut, poUsePath})
  finally:
    release(spawnLock)

  when defined(posix):
    # Close the registration race with an interrupt that acquired the active
    # registry while this spawn was establishing its child-side group.
    if interruptedSignal.load(moAcquire) != 0:
      discard terminateOwnedProcessGroup(result.processGroup)

proc spawnedProcess(binary: string; args: openArray[string];
                    env: StringTableRef): TestProcess =
  ## ``spawnGroupSupervisor`` under a bounded retry for the transient
  ## fork/exec faults documented on ``ParentSpawnRetryDelayMs``. Every
  ## attempt is announced on stderr so a retried spawn is visible in the
  ## console log rather than being inferred from a duration; the final
  ## failure is re-raised unchanged and the caller turns it into a
  ## ``tsHarnessError``.
  var lastError: ref OSError = nil
  for attempt in 1 .. ParentSpawnAttempts:
    try:
      return spawnGroupSupervisor(binary, args, env)
    except OSError as e:
      lastError = e
      if attempt >= ParentSpawnAttempts:
        break
      stderr.writeLine "repro_test_runner: spawn attempt " & $attempt &
        " of " & $ParentSpawnAttempts & " for " & splitFile(binary).name &
        " failed (" & e.msg & "); retrying"
      sleep(ParentSpawnRetryDelayMs * attempt)
  raise lastError

const CpuUnavailable = -1.0
  ## Sentinel returned by ``processGroupCpuSeconds`` for "this host (or
  ## this moment) cannot tell me how much CPU the test's process group
  ## has consumed". It is NOT zero: zero means "measured, and the group
  ## burned nothing", which is the signature of a genuine wedge. Folding
  ## the two together would turn every non-Linux host into a host that
  ## believes every test is deadlocked.

when defined(linux):
  let ClockTicksPerSec = block:
    ## ``/proc/<pid>/stat`` reports CPU in clock ticks, not seconds.
    let raw = sysconf(SC_CLK_TCK)
    if raw > 0: raw.float else: 100.0

  proc procStatFields(statText: string): seq[string] =
    ## Split one ``/proc/<pid>/stat`` line into its fields *after* the
    ## comm field. Field 2 (``comm``) is parenthesised and may itself
    ## contain spaces and parentheses — ``t (weird) name`` is a legal
    ## thread name — so a naive ``splitWhitespace`` of the whole line
    ## silently shifts every later index. Scanning from the LAST ``)``
    ## is the documented-safe parse.
    ##
    ## Index 0 of the result is field 3 (``state``); so field N is at
    ## index N - 3: pgrp (5) at 2, utime (14) at 11, stime (15) at 12,
    ## cutime (16) at 13, cstime (17) at 14.
    let closeParen = statText.rfind(')')
    if closeParen < 0:
      return @[]
    statText[closeParen + 1 .. ^1].splitWhitespace()

  proc processGroupCpuSeconds(processGroup: int): float =
    ## Cumulative CPU (user + system) consumed by every live process in
    ## ``processGroup``, including the CPU of descendants those processes
    ## have already reaped (``cutime``/``cstime``).
    ##
    ## This is the liveness signal the idle deadline needs and stdout
    ## cannot provide. A test starved of CPU by fifteen sibling workers
    ## — or by unrelated load on a shared CI runner — is *silent* while
    ## still advancing; a deadlocked test is silent and NOT advancing.
    ## Output alone cannot separate those two, and treating silence as a
    ## hang is what made a 16-worker sweep kill 28 live cases at ~600 s
    ## and fail seven tests that pass at one worker.
    ##
    ## Including ``cutime``/``cstime`` keeps the sum monotone across a
    ## fork-heavy test: when a member is reaped its own time does not
    ## vanish from the total, it moves into its parent's child-time
    ## counters, and the parent is in the same group. Without that, a
    ## test that spawns and reaps compilers would appear to *lose* CPU
    ## between samples.
    ##
    ## Membership is by process group, matching the unit the runner
    ## already owns and kills (``TestProcess.processGroup``, established
    ## by the wrapper's ``setpgid``). A descendant that calls ``setsid``
    ## leaves the group and stops contributing to the signal — such a
    ## case degrades to the old output-only behaviour rather than
    ## misreporting, and the owner-token cleanup path still reaps it.
    ##
    ## Matching by PGID cannot pick up a stranger: the supervisor anchor
    ## is deliberately kept alive (and reaped only after cleanup) so the
    ## kernel cannot recycle this PGID while the case is running — the
    ## same invariant ``signalProcessGroup`` relies on to make a negative
    ## -PID signal safe.
    if processGroup <= 0 or not dirExists("/proc"):
      return CpuUnavailable
    var total = 0.0
    var members = 0
    for kind, path in walkDir("/proc"):
      if kind != pcDir:
        continue
      let base = path.lastPathPart
      if base.len == 0 or base[0] notin {'0' .. '9'}:
        continue
      var statText = ""
      try:
        statText = readFile(path / "stat")
      except CatchableError:
        # The process exited between readdir and open. Not an error:
        # its CPU is already accounted for in its parent's child-time.
        continue
      let fields = procStatFields(statText)
      if fields.len < 15:
        continue
      var ticks = 0.0
      try:
        if parseInt(fields[2]) != processGroup:
          continue
        for idx in 11 .. 14:
          ticks += parseFloat(fields[idx])
      except ValueError:
        continue
      total += ticks
      inc members
    if members == 0:
      # No live member found. Report "unavailable" rather than 0.0 so a
      # momentarily-empty scan cannot be mistaken for measured idleness.
      return CpuUnavailable
    total / ClockTicksPerSec

  proc cpuLivenessAvailable(processGroup: int): bool =
    ## Cheap "is the signal usable at all" probe, kept separate from the
    ## sampler so the poll loop does not pay for a full ``/proc`` walk on
    ## a case that finishes in 40 ms. The suite has 1200+ such cases.
    processGroup > 0 and dirExists("/proc")

else:
  proc processGroupCpuSeconds(processGroup: int): float =
    ## No portable per-process-group CPU accounting is wired up outside
    ## Linux yet. Returning the sentinel makes ``drainAndWaitWithTimeout``
    ## fall back to the previous output-only idle deadline verbatim, so
    ## non-Linux hosts keep exactly the behaviour they had — including
    ## the starvation false-kill. That gap is real and deliberate: an
    ## unverified ``proc_pid_rusage`` path would be worse than a
    ## documented fallback.
    discard processGroup
    CpuUnavailable

  proc cpuLivenessAvailable(processGroup: int): bool =
    discard processGroup
    false

const CpuProgressFloorSec = 0.25
  ## Absolute floor for "the group did some work". One clock tick is
  ## 10 ms on every host we run on, so 0.25 s is 25 ticks — far above
  ## sampling quantisation, and unreachable by a group that is genuinely
  ## blocked (a wedged group accrues exactly zero).

const CpuProgressMinFraction = 0.01
  ## …and the floor is scaled up with the idle window, so the rule reads
  ## "the group must consume at least 1% of one core over the window".
  ## At the 1800 s default that is 18 s of CPU per 1800 s. A test that is
  ## merely starved clears this by orders of magnitude even at extreme
  ## oversubscription; a test that is deadlocked clears nothing.

proc cpuProgressThresholdSec(timeoutSec: int): float =
  max(CpuProgressFloorSec, CpuProgressMinFraction * timeoutSec.float)

proc cpuSampleIntervalSec(timeoutSec: int): float =
  ## Scanning ``/proc`` is cheap but not free, and N workers scan it
  ## concurrently. Sampling ~10x per idle window keeps the resolution
  ## far finer than the decision it feeds while bounding the cost; the
  ## clamp keeps short windows (the regression tests use 3-6 s) responsive
  ## and long ones (the 1800 s default) inexpensive.
  clamp(timeoutSec.float / 10.0, 1.0, 15.0)

const AbsoluteTimeoutMultiplier = 4
  ## The per-test ``--test-timeout`` is interpreted as a *no-progress*
  ## deadline (neither output nor CPU advance for that long ⇒ kill), not
  ## a fixed wall-clock budget. ``AbsoluteTimeoutMultiplier ×
  ## testTimeoutSec`` is the hard ceiling, and BOTH conditions must
  ## exist:
  ##
  ##   * no-progress kills a test that is genuinely wedged (silent and
  ##     burning no CPU);
  ##   * the absolute ceiling kills a test that keeps *making* progress
  ##     by the liveness signal but never finishes — a chatty stuck loop,
  ##     or a livelock like the real ``t_stackable_hooks_extracted_
  ##     process_tree`` spin that held 94% CPU for 19 hours. Progress-
  ##     based liveness alone would let that run forever, which is
  ##     precisely why the ceiling is not optional.
  ##
  ## The two are reported with distinct ``timeoutDescription`` prefixes
  ## (``IDLE TIMEOUT`` vs ``ABSOLUTE TIMEOUT``) so a log line alone says
  ## which rule fired. With the default 600 s window this caps any single
  ## test at 40 min, well inside the 4 h runner-phase backstop.

proc drainAndWait(testProcess: TestProcess):
    tuple[output: string; exitCode: int] =
  ## Drain the merged stdout/stderr stream to EOF, then collect the
  ## child's exit code and free its handles. Reading the stream to EOF
  ## first guarantees ``waitForExit`` won't deadlock on a child that
  ## blocks waiting for the parent to consume its pipe buffer.
  let p = testProcess.process
  when defined(posix):
    # The POSIX group supervisor remains alive after the direct test child
    # exits, so completion is reported through its private status file rather
    # than pipe EOF. This polling path is also used when timeouts are disabled.
    var groupOutput = ""
    while not fileExists(testProcess.statusPath):
      if interruptedSignal.load(moAcquire) != 0:
        groupOutput.add(
          "\nrepro_test_runner: interrupted; owned process group killed.\n")
        discard finishInterruptedTestProcess(testProcess, groupOutput)
        return (groupOutput, TimeoutExitCode)
      discard drainAvailable(p, groupOutput)
      sleep(GroupSupervisorPollIntervalMs)
    let groupExitCode = parseInt(readFile(testProcess.statusPath).strip())
    finalDrainNonBlocking(p, groupOutput)

    acquire(activeProcessGroupsLock)
    var cleanupComplete = true
    try:
      let active = findActiveProcessGroupUnlocked(testProcess.processGroup)
      if active.found:
        # The direct test is complete, but any group member or setsid/poDaemon
        # sidecar carrying this test's private token is still runner-owned.
        # Tear those down before reporting completion to the next test.
        cleanupComplete = terminateProcessGroupLocked(active.group)
      if cleanupComplete:
        removeActiveProcessGroupUnlocked(testProcess.processGroup)
    finally:
      release(activeProcessGroupsLock)
    if not cleanupComplete:
      groupOutput.add(
        "\nrepro_test_runner: exact owner-token processes survived " &
        "bounded cleanup; refusing to unregister or report PASS.\n")
      # A leaked process group is an observation about the case, so it is
      # raised as a REFUSAL and reported FAIL — never as a harness fault.
      raise newException(ProcessGroupRefusal, groupOutput)
    close(p)
    cleanupProcessGroupPaths(testProcess)
    return (groupOutput, groupExitCode)

  var output = ""
  let outp = p.outputStream
  var line = newStringOfCap(120)
  while outp.readLine(line):
    output.add(line)
    output.add('\n')
  let exitCode = p.waitForExit()
  close(p)
  result = (output, exitCode)

proc drainToEof(p: Process; output: var string) =
  ## Drain the merged stdout/stderr pipe to EOF. Safe to call only
  ## after the child has exited (or been killed) — Nim's stream
  ## ``readLine`` is blocking, so calling this on a live child that
  ## isn't emitting output would park the runner indefinitely. The
  ## polling loop in ``drainAndWaitWithTimeout`` is explicitly
  ## structured to avoid that: it only reaches ``drainToEof`` once
  ## ``peekExitCode`` reports the child is gone (either it exited on
  ## its own, or we SIGTERM/SIGKILLed it).
  let outp = p.outputStream
  if outp.isNil:
    return
  var line = newStringOfCap(120)
  while true:
    try:
      if not outp.readLine(line):
        break
    except IOError:
      break
    output.add(line)
    output.add('\n')

const PostExitDrainGraceSec = 10.0

proc drainToEofBounded(p: Process; output: var string;
                       graceSec: float): bool =
  ## Drain the merged stdout/stderr pipe after the child has exited,
  ## but give up after ``graceSec`` if EOF never arrives. Returns
  ## ``true`` if EOF was reached, ``false`` if we bailed out.
  ##
  ## Why this is bounded where ``drainToEof`` is not: a test can spawn a
  ## long-lived helper (e.g. the ``repro_binary_cache`` server, started
  ## with ``poParentStreams``) that inherits the test's stdout — i.e.
  ## the write end of *this* pipe. If the test then exits without
  ## reaping that helper (the classic case being a crashed test whose
  ## ``defer`` teardown never runs), the helper keeps the write end open
  ## and a blocking ``readLine`` here never sees EOF. That parked the
  ## whole runner for hours on Linux (glibc, where the leaked-daemon
  ## scenario is reachable). Bounding the drain turns "runner hangs
  ## forever, masking every later test" into "this one test reports with
  ## a clear leaked-fd note and the suite continues".
  when defined(posix):
    let fd = cint(p.outputHandle)
    let flags = fcntl(fd, F_GETFL, cint(0))
    if flags != -1:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    var buf: array[4096, char]
    let deadline = epochTime() + graceSec
    while true:
      let n = read(fd, addr buf[0], buf.len)
      if n > 0:
        var chunk = newString(int(n))
        copyMem(addr chunk[0], addr buf[0], int(n))
        output.add(chunk)
      elif n == 0:
        return true
      else:
        let e = errno
        if e == EAGAIN or e == EWOULDBLOCK:
          if epochTime() > deadline:
            return false
          sleep(50)
        elif e == EINTR:
          continue
        else:
          return false
  else:
    # Non-posix (Windows CI is not a supported runner host today): keep
    # the original blocking behaviour.
    drainToEof(p, output)
    return true

proc drainAvailable(p: Process; output: var string): int =
  ## Non-blocking read of whatever is currently buffered in the merged
  ## stdout/stderr pipe of a *live* child. Returns the number of bytes
  ## appended (0 if the pipe is momentarily empty). POSIX only — the fd
  ## is put in ``O_NONBLOCK`` so the call never parks the poll loop on a
  ## test that isn't emitting output right now. Used to (a) keep the
  ## pipe drained so a verbose test can't fill the 64 KB kernel buffer
  ## and self-block, and (b) detect forward progress for the idle-
  ## deadline heuristic in ``drainAndWaitWithTimeout``.
  when defined(posix):
    let fd = cint(p.outputHandle)
    let flags = fcntl(fd, F_GETFL, cint(0))
    if flags != -1:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    var total = 0
    var buf: array[4096, char]
    while true:
      let n = read(fd, addr buf[0], buf.len)
      if n > 0:
        var chunk = newString(int(n))
        copyMem(addr chunk[0], addr buf[0], int(n))
        output.add(chunk)
        total += int(n)
        if int(n) < buf.len:
          break          # drained what was available; don't block
      elif n == 0:
        break            # writer closed; EOF handled by peekExitCode path
      else:
        let e = errno
        if e == EAGAIN or e == EWOULDBLOCK or e == EINTR:
          break          # nothing more available right now
        else:
          break
    return total
  else:
    return 0

const FinalDrainPasses = 5
const FinalDrainPassSleepMs = 20

proc finalDrainNonBlocking(p: Process; output: var string) =
  ## Final, *non-blocking* drain of the merged stdout/stderr pipe after
  ## the child has exited (cleanly or via our kill). Grabs whatever is
  ## buffered in a few quick passes and then walks away — it NEVER blocks
  ## waiting for the pipe's EOF.
  ##
  ## Why this replaces the EOF-blocking ``drainToEofBounded`` at the
  ## post-exit sites: a failed ``repro build`` / ``repro develop`` /
  ## ``repro watch`` test can leave a daemon holding a transiently-inherited
  ## copy of this pipe's write end. Blocking for EOF here (even bounded to
  ## 10s) stalls the runner before the ownership cleanup can terminate that
  ## daemon. A test that has produced its exit code is ready for cleanup; the
  ## final drain only captures bytes already in flight.
  ##
  ## The D6 silent-hang guard is unaffected: that guard fires *before* we
  ## ever reach a final drain — a test that goes silent trips the idle
  ## deadline in the poll loop and is SIGTERM/SIGKILLed there. By the time
  ## we drain here the child is already gone; we are only collecting
  ## trailing bytes, not deciding liveness.
  ##
  ## A few short passes (rather than a single read) catch bytes that raced
  ## into the kernel pipe buffer just before the child exited, without
  ## re-introducing an unbounded wait: total worst case is
  ## ``FinalDrainPasses * FinalDrainPassSleepMs`` (~100ms).
  for _ in 0 ..< FinalDrainPasses:
    if drainAvailable(p, output) == 0:
      sleep(FinalDrainPassSleepMs)
    # If bytes are still flowing we keep looping the fixed number of
    # passes; we never extend the loop based on EOF.

type ChildRunOutcome = object
  ## What the wait loop observed about one child process.
  ##
  ## Introduced by M19 because ``termination`` needs facts an exit code
  ## cannot carry: RunQuota's spine distinguishes ``oom_killed`` from
  ## ``exited``, and both of those are non-zero exits. ``memoryExceeded``
  ## is the only field that can make that distinction, and it is TRUE
  ## ONLY WHEN THIS RUNNER ITSELF KILLED THE CHILD for crossing its
  ## declared memory reservation — an observation, never an inference
  ## over a status byte.
  output: string
  exitCode: int
  timedOut: bool
  timeoutDescription: string
  memoryExceeded: bool
  peakRssBytes: uint64

proc drainAndWaitWithTimeout(testProcess: TestProcess; timeoutSec: int;
                             memoryLimitBytes = 0'u64): ChildRunOutcome =
  ## Deadline-aware variant of ``drainAndWait``. When ``timeoutSec <= 0``
  ## and no memory ceiling is configured the call delegates to
  ## ``drainAndWait`` (preserving M3 behaviour).
  ##
  ## ``memoryLimitBytes`` (M19, 0 = OFF and the default) is the resident
  ## size the test's whole process tree may reach. Crossing it kills the
  ## group through exactly the same bounded TERM → grace → KILL path a
  ## timeout uses, and reports ``memoryExceeded``. The ceiling is the
  ## same figure the RunQuota lease reserved for this test, so "the test
  ## exceeded its reservation" and "the runner killed it" are one event
  ## rather than two that have to be correlated afterwards.
  ##
  ## ``timeoutSec`` is interpreted as a **no-progress** deadline, not a
  ## fixed wall-clock budget: the test is killed only after it has shown
  ## no sign of forward progress for ``timeoutSec`` seconds. Two
  ## independent signals count as progress, and either one resets the
  ## clock:
  ##
  ##   1. **Output.** A polling loop drains the pipe non-blockingly every
  ##      ~``TimeoutPollIntervalMs``; any new bytes are progress.
  ##   2. **CPU consumed by the test's process group.** Sampled from
  ##      ``/proc`` (see ``processGroupCpuSeconds``) every
  ##      ``cpuSampleIntervalSec``; an advance of at least
  ##      ``cpuProgressThresholdSec`` since the last recorded progress
  ##      point is progress.
  ##
  ## Signal 2 is the one that is correct at any parallelism, and it is
  ## why this proc no longer equates silence with a hang. A heavy e2e
  ## test starved by fifteen sibling workers (or by unrelated load on
  ## this shared CI runner) can be quiet for many minutes while running
  ## perfectly well; the pure output heuristic killed 28 such cases at
  ## ~600 s in one 16-worker sweep and turned seven 1-worker passes into
  ## 16-worker failures. A genuinely wedged test — the D6
  ## ``sleep(60_000)`` shape, or the real
  ## ``t_local_daemons_control_plane_m11`` leaked-daemon stall — is silent
  ## AND burns no CPU, so it is still killed on the same deadline it was
  ## killed on before.
  ##
  ## An absolute ceiling of ``AbsoluteTimeoutMultiplier × timeoutSec``
  ## still applies, and is now load-bearing rather than a backstop: a
  ## livelock (a spin loop at 94% CPU) satisfies the CPU-progress signal
  ## forever, so only the ceiling can end it. See
  ## ``AbsoluteTimeoutMultiplier``.
  ##
  ## Both kill paths report which rule fired and the numbers behind it —
  ## elapsed, group CPU consumed, CPU advance since the last progress
  ## point, and the age of the last output — so a timeout in a CI log is
  ## diagnosable without a live process to inspect.
  ##
  ## On expiry (no-progress or absolute) the child is SIGTERM'd, given
  ## ``TimeoutKillGraceSec`` to exit, then SIGKILL'd.
  ##
  ## On non-POSIX hosts ``drainAvailable`` is a no-op and
  ## ``processGroupCpuSeconds`` reports ``CpuUnavailable``, so the loop
  ## degrades to the original fixed-budget behaviour — acceptable since
  ## Windows is not a supported runner host today. On macOS the output
  ## signal works and the CPU signal does not; that host keeps the
  ## pre-existing output-only semantics.
  ##
  ## A memory ceiling is reason enough to poll on its own: with
  ## ``timeoutSec <= 0`` but ``memoryLimitBytes`` set, the loop still
  ## runs and both time deadlines become infinite rather than the loop
  ## being skipped (see ``idleDeadlineSec``).
  if timeoutSec <= 0 and memoryLimitBytes == 0'u64:
    let (output, exitCode) = drainAndWait(testProcess)
    return ChildRunOutcome(output: output, exitCode: exitCode)

  let p = testProcess.process
  var output = ""
  let start = epochTime()
  var lastProgress = start
    ## Last moment EITHER signal showed forward progress. This is the
    ## clock the no-progress deadline measures against.
  var lastOutput = start
    ## Last moment bytes arrived. Reported in the diagnostic so a kill
    ## line distinguishes "quiet but working" from "quiet and dead".
  let processGroup =
    when defined(posix): testProcess.processGroup
    else: 0
  # A memory ceiling on its own must still poll, so an absent idle
  # deadline becomes an infinite one rather than turning the loop off.
  let idleDeadlineSec =
    if timeoutSec <= 0: Inf else: timeoutSec.float
  let absoluteDeadlineSec =
    if timeoutSec <= 0: Inf
    else: timeoutSec.float * AbsoluteTimeoutMultiplier.float
  let cpuThreshold = cpuProgressThresholdSec(timeoutSec)
  let cpuInterval = cpuSampleIntervalSec(timeoutSec)
  var cpuSeen = CpuUnavailable
    ## Highest group-CPU total observed so far (``CpuUnavailable`` until
    ## the first sample lands). Tracked as a running maximum: a scan that
    ## races a member's exit can read low, and a transient dip must never
    ## be mistaken for regression.
  var cpuAtLastProgress = CpuUnavailable
    ## The reading ``cpuSeen`` is compared against. Re-based whenever
    ## EITHER signal shows progress, so the required advance is always
    ## measured from the most recent progress point.
  var lastCpuSample = start
    ## No sample is taken at t=0 on purpose: the first one lands a whole
    ## ``cpuInterval`` in, so a case that finishes quickly never touches
    ## ``/proc`` at all.
  let cpuTracked = cpuLivenessAvailable(processGroup)
  var timedOut = false
  var timeoutDescription = ""
  var memoryExceeded = false
  var peakRssBytes = 0'u64
  let childPid = uint64(max(p.processID, 0))

  proc observedNumbers(now: float): string =
    ## The evidence line that accompanies every kill.
    let cpuText =
      if cpuSeen == CpuUnavailable: "unavailable"
      else: formatFloat(cpuSeen, ffDecimal, 2) & "s"
    let advanceText =
      if cpuSeen == CpuUnavailable or cpuAtLastProgress == CpuUnavailable:
        "unavailable"
      else:
        formatFloat(cpuSeen - cpuAtLastProgress, ffDecimal, 2) & "s"
    "elapsed=" & formatFloat(now - start, ffDecimal, 1) &
      "s group-cpu=" & cpuText &
      " cpu-since-last-progress=" & advanceText &
      " last-output-age=" & formatFloat(now - lastOutput, ffDecimal, 1) &
      "s last-progress-age=" & formatFloat(now - lastProgress, ffDecimal, 1) &
      "s cpu-progress-threshold=" &
      formatFloat(cpuThreshold, ffDecimal, 2) & "s"

  while true:
    when defined(posix):
      if interruptedSignal.load(moAcquire) != 0:
        output.add(
          "\nrepro_test_runner: interrupted; owned process group killed.\n")
        discard finishInterruptedTestProcess(testProcess, output)
        return ChildRunOutcome(output: output, exitCode: TimeoutExitCode,
          timedOut: true, timeoutDescription: "INTERRUPTED",
          peakRssBytes: peakRssBytes)
    when defined(posix):
      var code = -1
      var childComplete = false
      if fileExists(testProcess.statusPath):
        try:
          code = parseInt(readFile(testProcess.statusPath).strip())
          childComplete = true
        except ValueError, IOError:
          discard
    else:
      let code = p.peekExitCode()
      let childComplete = code != -1
    if childComplete:
      # Child exited on its own. Collect whatever trailing output is buffered
      # without waiting for pipe EOF, then terminate every same-group or
      # exact-token sidecar before reporting the result. A detached child can
      # keep the pipe open until that ownership cleanup runs.
      when defined(posix):
        finalDrainNonBlocking(p, output)
        acquire(activeProcessGroupsLock)
        var cleanupComplete = true
        try:
          let active =
            findActiveProcessGroupUnlocked(testProcess.processGroup)
          if active.found:
            cleanupComplete = terminateProcessGroupLocked(active.group)
          if cleanupComplete:
            removeActiveProcessGroupUnlocked(testProcess.processGroup)
        finally:
          release(activeProcessGroupsLock)
        if not cleanupComplete:
          output.add(
            "\nrepro_test_runner: exact owner-token processes survived " &
            "bounded cleanup; refusing to unregister or report PASS.\n")
          raise newException(ProcessGroupRefusal, output)
        close(p)
        cleanupProcessGroupPaths(testProcess)
      else:
        finalDrainNonBlocking(p, output)
        close(p)
      return ChildRunOutcome(output: output, exitCode: code,
        peakRssBytes: peakRssBytes)
    # Drain whatever the live child has emitted since the last poll.
    # Non-blocking, so this never parks on a silent test. Any new bytes
    # are forward progress and reset the no-progress clock.
    if drainAvailable(p, output) > 0:
      lastOutput = epochTime()
      lastProgress = lastOutput
      # Rebase the CPU comparison too: the required advance is measured
      # from the most recent progress point, whichever signal produced it.
      cpuAtLastProgress = cpuSeen
    # M19: sample the resident size of the child's WHOLE PROCESS TREE.
    #
    # The tree, not the direct child: on POSIX the direct child is the
    # process-group supervisor and the test itself is its descendant, so
    # sampling only the child would read the supervisor's few hundred KiB
    # and the ceiling would never fire — a check that cannot fail.
    #
    # Sampled through RunQuota's own host backend rather than a ``ps``
    # subprocess: ``ps -o rss`` is entitlement-gated on current macOS and
    # fails outright there, which would have made this a Linux-only
    # mechanism that read green on macOS.
    if memoryLimitBytes > 0'u64 and childPid > 0'u64:
      let rss = sampleProcessTreeRss(childPid)
      if rss > peakRssBytes:
        peakRssBytes = rss
      if rss > memoryLimitBytes:
        output.add("\nrepro_test_runner: resident set of the test process " &
          "tree reached " & $rss & " bytes, above the " &
          $memoryLimitBytes & "-byte reservation; killing it as an " &
          "out-of-memory kill.\n")
        memoryExceeded = true
        timeoutDescription =
          "MEMORY LIMIT EXCEEDED: " & $rss & " > " & $memoryLimitBytes &
          " bytes"
        break
    var now = epochTime()
    # Second signal: has the process group burned CPU? A starved test is
    # quiet but advancing; a deadlocked one is quiet and flat.
    if cpuTracked and (now - lastCpuSample) >= cpuInterval:
      lastCpuSample = now
      let sample = processGroupCpuSeconds(processGroup)
      if sample != CpuUnavailable and sample > cpuSeen:
        cpuSeen = sample
        if cpuAtLastProgress == CpuUnavailable:
          # First successful reading: it establishes the baseline and
          # claims nothing. CPU burned before it is not evidence of
          # progress *since the last progress point*.
          cpuAtLastProgress = cpuSeen
        elif cpuSeen - cpuAtLastProgress >= cpuThreshold:
          cpuAtLastProgress = cpuSeen
          lastProgress = now
      now = epochTime()
    if (now - lastProgress) > idleDeadlineSec:
      let evidence = observedNumbers(now)
      # Never claim a signal that was not actually read. "no CPU
      # progress" is a measurement; "CPU unmeasured" is an admission.
      let cpuMeasured = cpuTracked and cpuSeen != CpuUnavailable
      let signals =
        if cpuMeasured: "no output and no CPU progress"
        elif cpuTracked: "no output; the CPU signal never returned a reading"
        else: "no output; the CPU signal is unavailable on this host"
      output.add("\nrepro_test_runner: no progress for " & $timeoutSec &
        "s (idle deadline; " & signals & "); treating as hung. " &
        evidence & "\n")
      timedOut = true
      # The leading clause is stable text other tooling greps for; the
      # bracketed evidence is what makes a timeout diagnosable from the
      # log alone.
      timeoutDescription =
        "IDLE TIMEOUT after " & $timeoutSec & "s without output" &
        (if cpuMeasured: " or CPU progress" else: "") &
        " [" & evidence & "]"
      break
    if (now - start) > absoluteDeadlineSec:
      let evidence = observedNumbers(now)
      output.add("\nrepro_test_runner: exceeded absolute ceiling of " &
        $absoluteDeadlineSec.int & "s (" & $AbsoluteTimeoutMultiplier &
        "x the no-progress deadline) while still showing progress; " &
        "treating as stuck (livelock or an unbounded loop). " &
        evidence & "\n")
      timedOut = true
      timeoutDescription =
        "ABSOLUTE TIMEOUT after " & $absoluteDeadlineSec.int & "s" &
        " [" & evidence & "]"
      break
    sleep(TimeoutPollIntervalMs)

  # Deadline expired. POSIX keeps the supervisor anchor registered and alive
  # through TERM -> grace -> KILL; other platforms retain leader cleanup.
  when defined(posix):
    acquire(activeProcessGroupsLock)
    var cleanupComplete = true
    try:
      let active = findActiveProcessGroupUnlocked(testProcess.processGroup)
      if active.found:
        cleanupComplete = terminateProcessGroupLocked(active.group)
      if cleanupComplete:
        removeActiveProcessGroupUnlocked(testProcess.processGroup)
    finally:
      release(activeProcessGroupsLock)
    if not cleanupComplete:
      output.add(
        "\nrepro_test_runner: exact owner-token processes survived " &
        "bounded cleanup; refusing to unregister or report a terminal " &
        "test result.\n")
      raise newException(ProcessGroupRefusal, output)
  else:
    try:
      p.terminate()
    except OSError, Exception:
      discard
    let killDeadline = epochTime() + TimeoutKillGraceSec.float
    while epochTime() < killDeadline:
      if p.peekExitCode() != -1:
        break
      sleep(TimeoutPollIntervalMs)
    if p.peekExitCode() == -1:
      try:
        p.kill()
      except OSError, Exception:
        discard
      # Block on waitForExit only after the SIGKILL has been delivered;
      # the kernel must reap the zombie before peekExitCode returns a
      # real code, but the wait window is bounded by the kill itself.
      discard p.waitForExit()
  # The child has been killed and reaped; collect any trailing buffered
  # output without blocking for EOF. Exact-token cleanup above has already
  # killed detached descendants, but their inherited descriptors can still be
  # closing while the pipe is drained. The timeout itself — already recorded
  # in ``timedOut`` — is what makes this a FAIL; the drain only gathers
  # diagnostics.
  finalDrainNonBlocking(p, output)
  close(p)
  when defined(posix):
    cleanupProcessGroupPaths(testProcess)
  result = ChildRunOutcome(output: output, exitCode: TimeoutExitCode,
    timedOut: timedOut, timeoutDescription: timeoutDescription,
    memoryExceeded: memoryExceeded, peakRssBytes: peakRssBytes)

# ---------------------------------------------------------------------------
# RunQuota-Observation-Store M19 — the reporter's runner-side glue
# ---------------------------------------------------------------------------

const DefaultLeaseMemoryBytes = 128'u64 * 1024'u64 * 1024'u64
  ## What a test reserves when no ceiling is configured. Matches the
  ## reprobuild engine's own per-action default, so a test and a compile
  ## are admitted against the same units.

proc leaseMemoryBytes(memoryLimitBytes: uint64): uint64 =
  ## THE CEILING IS THE RESERVATION, not a second number beside it.
  ##
  ## A runner that reserved one figure from RunQuota and enforced a
  ## different one would be reporting ``oom_killed`` for a process that
  ## never exceeded what the store says it was admitted for, and no
  ## reader of the two rows could reconcile them.
  if memoryLimitBytes > 0'u64: memoryLimitBytes else: DefaultLeaseMemoryBytes

proc historyStatus(res: TestResult; outcome: ChildRunOutcome;
                   groupRefused: bool): TestHistoryStatus =
  ## Map the runner's verdict onto the framework-neutral vocabulary.
  ##
  ## THE VOCABULARY IS THE SPECIFICATION'S, NOT THIS RUNNER'S, which is
  ## why the mapping lives here rather than the enum being widened to
  ## fit: ``timeout`` and ``leak`` are outcomes any parallel runner
  ## produces, and ``xfail``/``xpass`` are read from the case's own
  ## catalog row rather than invented.
  if groupRefused:
    # A case whose processes outlived a bounded kill. ``leak`` is the
    # vocabulary's name for exactly this and nothing else.
    return thsLeak
  if outcome.timedOut:
    return thsTimeout
  case res.status
  of tsSkip: thsSkip
  of tsPass:
    if res.testCase.protocolAware and res.testCase.meta.xfail.len > 0: thsXpass
    else: thsPass
  else:
    if res.testCase.protocolAware and res.testCase.meta.xfail.len > 0: thsXfail
    else: thsFail

proc reportExecution(history: ptr HistoryReporter; testLease: var TestLease;
                     res: TestResult; outcome: ChildRunOutcome;
                     groupRefused = false) =
  ## Close the lease and write both extension rows for one execution.
  ##
  ## A HARNESS ERROR WRITES NO EXTENSION ROW, DELIBERATELY. ``tsHarnessError``
  ## means the runner obtained no verdict about the code under test; the
  ## generic layer's ``status`` vocabulary has no member for that and
  ## inventing one — or borrowing ``fail`` — would put a statement about
  ## the RUN into a column every flake and pass-rate query reads as a
  ## statement about the TREE. The lease is still finished, so the spine
  ## keeps an execution row whose ``termination`` is ``refused``, which is
  ## the honest record that something was admitted and produced nothing.
  if not testLease.captured:
    return
  let harnessFault = res.status == tsHarnessError
  # SIGNAL, INFERRED FROM THE 128+N CONVENTION AND SAID TO BE INFERRED.
  # The process-group wrapper records a status integer, not a raw wait
  # status word, so 128+N is the only signal evidence the runner has —
  # the same evidence, and the same caveat, as ``describeChildExit``.
  var signalNumber = 0
  if not outcome.timedOut and not outcome.memoryExceeded and
      outcome.exitCode > 128 and outcome.exitCode <= 128 + 64:
    signalNumber = outcome.exitCode - 128
  history.finishExecution(testLease, TestExecutionOutcome(
    exitCode:
      if outcome.exitCode < 0: 1 else: outcome.exitCode,
    signal: signalNumber,
    # A timeout or a ceiling kill IS a signalled death — the runner sent
    # the SIGKILL itself — but ``memoryLimitExceeded`` is checked ahead of
    # it by the daemon, so the OOM arm is not swallowed by the signal arm.
    signalled: signalNumber != 0 or outcome.timedOut or
      outcome.memoryExceeded,
    peakRssBytes: outcome.peakRssBytes,
    processCount: 0'u32,
    memoryLimitExceeded: outcome.memoryExceeded,
    timedOut: outcome.timedOut,
    launchFailed: harnessFault))
  if not harnessFault:
    var generic = GenericTestFacts(
      testId:
        if res.testCase.qualifiedName.len > 0: res.testCase.qualifiedName
        else: res.testCase.binaryStem,
      suite: res.testCase.suite,
      status: historyStatus(res, outcome, groupRefused),
      durationMs: res.durationMs,
      durationKnown: true,
      # ONE ATTEMPT. This runner does not retry, so every row is the
      # first and ``retry_of`` is NULL. Recording a fixed 1 is a
      # measurement, not a placeholder: the ordinal is known.
      attempt: 1,
      retryOf: "",
      errorMessage: res.exception,
      skipReason: res.skipReason,
      # The runner spawns children with ``poStdErrToStdOut``, so what it
      # holds is the MERGED stream. ``stderr_len`` is therefore unknown
      # rather than zero; see the column note in the schema module.
      stdoutLen: res.stdout.len,
      stdoutKnown: true,
      stderrLen: 0,
      stderrKnown: false)
    if generic.errorMessage.len == 0 and res.checkpoints.len > 0:
      generic.errorMessage = res.checkpoints[0]
    let specific = CodetracerTestFacts(
      # The trace columns §17.1.2 names are absent for a test that
      # records nothing, which is every test in reprobuild's own suite.
      # They are declared so a CodeTracer run does not need a migration.
      protocolAware: res.testCase.protocolAware,
      runName: res.testCase.runName,
      bodyHash: res.testCase.meta.bodyHash,
      checkpointCount: res.checkpointCount,
      statusDisagreement: res.statusDisagreement,
      harnessError: res.harnessError)
    history.recordRows(testLease, generic, specific)
  history.releaseLease(testLease)

const WholeBinarySkipMarker = "[SKIPPED] "
  ## The console formatter's own status marker for a skipped case
  ## (``lib/pure/unittest.nim``: ``ConsoleOutputFormatter.testEnded``
  ## prints ``[", $status, "] ", testName``). This is the ONLY channel a
  ## whole-binary run has for a skip.
  ##
  ## Why there is no other channel. ``unittest``'s result document and
  ## its exit-code-2 convention both live behind ``protocolMode ==
  ## pmRun`` — i.e. behind ``--run <case>``. A binary executed whole is
  ## ``pmDefault``: it writes no document, and its exit code is 1 if any
  ## case FAILED and 0 otherwise. A skipped case therefore exits 0 and is
  ## indistinguishable, by exit code alone, from a case that passed.
  ##
  ## This is NOT the failure-text sniffing this codebase has been
  ## removing. It reads the harness's own structured status marker for a
  ## status it already computed, not free-form diagnostic prose, and it
  ## can only move an outcome from PASS to SKIP — never from FAIL to
  ## anything.

proc wholeBinarySkippedCases(output: string): seq[string] =
  ## Names of the cases a whole-binary run reported as skipped.
  ##
  ## Anchored to the start of the (indented) line, because that is where
  ## the formatter puts the marker: a case inside a ``suite`` is printed
  ## with a two-space prefix and a suite-less one with none. Anchoring
  ## rejects a mid-line mention (``… saw "[SKIPPED] foo" …``).
  ##
  ## It does NOT reject a line-anchored one. A whole binary that prints
  ## its own line beginning ``[SKIPPED] `` — most plausibly a test that
  ## echoes a nested unittest log, which carries the formatter's own
  ## two-space indent — is read as a skip, and no parse of free-form
  ## child stdout can tell that apart from the real thing. Measured: a
  ## one-case fixture that passes and echoes ``  [SKIPPED] x`` is
  ## reported SKIP.
  ##
  ## That residue is bounded by the caller, and bounded on the safe
  ## side. Only a PASS is ever re-read, so the worst outcome is a
  ## passing binary reported as skipped — which a zero-skip gate turns
  ## RED and names. A failure can never be absorbed. Recovering the
  ## remaining fidelity needs the binary to become enumerable, so that
  ## the skip arrives on the result-document channel instead of on
  ## stdout; it does not need a cleverer pattern.
  result = @[]
  for rawLine in output.splitLines():
    let line = rawLine.strip()
    if line.startsWith(WholeBinarySkipMarker):
      result.add(line[WholeBinarySkipMarker.len .. ^1].strip())

proc runWholeBinary(tc: TestCase; resultsDir: string;
                    baseEnv: seq[tuple[key, value: string]];
                    testTimeoutSec: int;
                    history: ptr HistoryReporter = nil;
                    memoryLimitBytes = 0'u64): TestResult =
  result.testCase = tc
  result.status = tsFail
  let t0 = epochTime()
  # M19: one RunQuota lease around this execution. Acquired BEFORE the
  # spawn and finished AFTER the wait, so the spine row's start, finish
  # and duration describe the test rather than the bookkeeping around it.
  var testLease = history.acquireLease(
    (if tc.qualifiedName.len > 0: tc.qualifiedName else: tc.binaryStem),
    memoryBytes = leaseMemoryBytes(memoryLimitBytes))
  var childOutcome: ChildRunOutcome
  var groupRefused = false
  # Wrap the whole spawn-drain-wait sequence so a sporadic
  # ``Bad file descriptor [OSError]`` from the residual fork hazard
  # documented above is reported instead of tearing down the worker
  # thread (and silencing every test the queue would have handed out
  # afterwards). The outcome is ``ERROR``, not ``FAIL``: no verdict about
  # the code under test was produced, and saying otherwise puts a defect
  # report on a tree that may be perfectly healthy.
  var whichPhase = "spawn failed"
  try:
    var childEnv = newStringTable(modeCaseSensitive)
    for (k, v) in baseEnv:
      childEnv[k] = v
    # The skip census below reads the console formatter's status markers,
    # so the two knobs that can suppress them are pinned rather than
    # inherited. ``NIMTEST_OUTPUT_LVL=PRINT_FAILURES`` in an ambient
    # environment would print nothing for a skipped case and silently
    # restore the exact blind spot this exists to close;
    # ``NIMTEST_COLOR=always`` would wrap the marker in escapes. Both
    # values are ``unittest``'s own defaults for a piped child, so
    # pinning them changes no output that was already being produced.
    childEnv["NIMTEST_OUTPUT_LVL"] = "PRINT_ALL"
    childEnv["NIMTEST_COLOR"] = "never"
    history.markStarting(testLease)
    let p = spawnedProcess(tc.binary, args = [], env = childEnv)
    history.markRunning(testLease, uint64(max(p.process.processID, 0)),
      when defined(posix): uint64(max(p.processGroup, 0)) else: 0'u64)
    # Past this point the child exists, so a fault is a collection
    # failure and must not be reported as a spawn failure — mislabelling
    # the phase is what sent the first investigation of this defect at
    # the wrong code.
    whichPhase = "child started but its result could not be collected"
    childOutcome = drainAndWaitWithTimeout(p, testTimeoutSec,
      memoryLimitBytes)
    let output = childOutcome.output
    let exitCode = childOutcome.exitCode
    if childOutcome.memoryExceeded:
      # A FAIL, and one that the spine row will label ``oom_killed``
      # rather than ``exited`` — which is the whole point of recording a
      # termination kind beside an exit status.
      result.status = tsFail
      result.stdout =
        "repro_test_runner: " & childOutcome.timeoutDescription &
        "; SIGKILLed\n" & output
    elif childOutcome.timedOut:
      result.status = tsFail
      result.stdout =
        "repro_test_runner: " & childOutcome.timeoutDescription &
        "; SIGKILLed\n" & output
    else:
      result.stdout = output
      case exitCode
      of 0: result.status = tsPass
      of 2: result.status = tsSkip
      of HarnessErrorExitCode:
        result.status = tsHarnessError
        result.harnessError =
          "child reported harness exit " & $HarnessErrorExitCode &
          " (could not start the test)"
      else: result.status = tsFail
      if result.status == tsPass:
        # A whole binary exits 0 whether every case passed or some case
        # called ``skip()`` — the exit-code-2 skip convention is
        # ``--run``-only (see ``WholeBinarySkipMarker``). Reporting PASS
        # here made ``skip=0`` in the run summary mean "no PER-CASE skip",
        # not "no skip", so a zero-skip gate read green while the console
        # log carried ``[SKIPPED]`` lines nobody was counting.
        #
        # Only PASS is reclassified. A binary that also FAILED stays
        # FAILED: a skip must never be able to absorb a failure.
        let skipped = wholeBinarySkippedCases(output)
        if skipped.len > 0:
          result.status = tsSkip
          result.skipReason =
            "whole-binary run: " & $skipped.len &
            " unittest case(s) skipped: " & skipped.join(", ")
  except ProcessGroupRefusal as e:
    # A verdict WAS reached: the case leaked processes that outlived
    # bounded cleanup. That is a defect in the tree, so it is FAIL and it
    # lands in ``summary.failed`` where a gate looks for defects — not in
    # ``harness_errors``, which is a statement about the run.
    result.status = tsFail
    result.stdout = e.msg
    groupRefused = true
  except OSError as e:
    # NOT a test failure: nothing was observed about the code under test.
    # See ``TestStatus.tsHarnessError``.
    result.status = tsHarnessError
    result.harnessError = whichPhase & ": " & e.msg
    result.stdout = "repro_test_runner: " & whichPhase & ": " & e.msg & "\n"
  except IOError as e:
    result.status = tsHarnessError
    result.harnessError = whichPhase & " (i/o): " & e.msg
    result.stdout =
      "repro_test_runner: " & whichPhase & " (i/o): " & e.msg & "\n"
  result.durationMs = int((epochTime() - t0) * 1000)
  result.stderr = ""
  history.reportExecution(testLease, result, childOutcome, groupRefused)

proc signalName(sig: int): string =
  ## Name for a signal number, or "" when it is not one this runner can
  ## name. The numbers are read from the platform's own headers through
  ## ``std/posix`` rather than hard-coded, because they differ between
  ## Linux and macOS (SIGBUS is 7 on one and 10 on the other) — a
  ## hard-coded table would confidently print the wrong name on one host.
  when defined(posix):
    let s = cint(sig)
    if s == SIGHUP: "SIGHUP"
    elif s == SIGINT: "SIGINT"
    elif s == SIGQUIT: "SIGQUIT"
    elif s == SIGILL: "SIGILL"
    elif s == SIGTRAP: "SIGTRAP"
    elif s == SIGABRT: "SIGABRT"
    elif s == SIGBUS: "SIGBUS"
    elif s == SIGFPE: "SIGFPE"
    elif s == SIGKILL: "SIGKILL"
    elif s == SIGSEGV: "SIGSEGV"
    elif s == SIGPIPE: "SIGPIPE"
    elif s == SIGALRM: "SIGALRM"
    elif s == SIGTERM: "SIGTERM"
    else: ""
  else:
    ""

proc describeChildExit(exitCode: int): string =
  ## Render a per-case child's exit code, naming the signal when the code
  ## carries one.
  ##
  ## The code comes from ``processGroupWrapperMain``'s own
  ## ``waitForExit``, which follows the shell convention: a child killed by
  ## signal N is reported as 128+N. That is the only signal evidence the
  ## runner has — the wrapper records a status integer, not a raw
  ## ``wait`` status word — so the signal is named as an INFERENCE from the
  ## convention rather than asserted as fact. A test that calls
  ## ``quit(139)`` deliberately would be described the same way, and saying
  ## "consistent with" instead of "was" is the difference between a
  ## diagnosis and a fabrication.
  if exitCode > 128 and exitCode <= 128 + 64:
    let sig = exitCode - 128
    let named = signalName(sig)
    let name = if named.len > 0: " (" & named & ")" else: ""
    result = "exit code " & $exitCode & " (128+" & $sig &
      ", consistent with termination by signal " & $sig & name & ")"
  else:
    result = "exit code " & $exitCode

proc missingDocumentDiagnostic(resultFile: string; exitCode: int;
                               present: bool): string =
  ## The diagnosis owed to a non-PASS case whose result document cannot be
  ## read — see the call site for why the runner must synthesise one.
  let whatHappened =
    if present:
      "exists but could not be read as a protocol document"
    else:
      "was never written"
  "repro_test_runner: no readable result document for this case.\n" &
    "  expected at: " & resultFile & "\n" &
    "  document:    " & whatHappened & "\n" &
    "  child:       started, and finished with " &
      describeChildExit(exitCode) & "\n" &
    # Hard-wrapped: this text is printed to the console per failing case,
    # where one 300-column line is not a diagnosis anyone reads.
    "  meaning:     the fork writes this document from testEnded, so a " &
      "case that dies\n" &
    "               first (quit() in the case body, a fatal signal, an " &
      "abort in a\n" &
    "               destructor) leaves no first-hand account. The verdict " &
      "above comes\n" &
    "               from the exit code alone; re-run this one case " &
      "directly to see\n" &
    "               what the child was doing.\n"

proc runOneProtocol(tc: TestCase; resultsDir: string;
                    baseEnv: seq[tuple[key, value: string]];
                    testTimeoutSec: int;
                    history: ptr HistoryReporter = nil;
                    memoryLimitBytes = 0'u64): TestResult =
  result.testCase = tc
  result.status = tsFail
  let resultFile = resultsDir / (tc.binaryStem & "__" &
    tc.qualifiedName.multiReplace([
      ("::", "__"), ("/", "_"), (" ", "_"), ("\t", "_")]) & ".json")
  result.resultFile = resultFile
  # Build a per-child env table that inherits the parent snapshot and
  # overrides only ``NIMTEST_RESULT_FILE``. Doing this per-call keeps
  # each child's env composition thread-local (no shared mutable state)
  # and replaces the old ``putEnv`` global mutation that races between
  # workers under concurrent spawns.
  var childEnv = newStringTable(modeCaseSensitive)
  for (k, v) in baseEnv:
    childEnv[k] = v
  childEnv["NIMTEST_RESULT_FILE"] = resultFile
  let t0 = epochTime()
  # Same spawn-lock + exception-isolation discipline as
  # ``runWholeBinary``. A sibling whole-binary spawn racing this
  # protocol spawn would otherwise leak pipe FDs into the wrong child,
  # and a residual fork-vs-malloc hazard could still raise OSError.
  # The lock covers only ``startProcess``; the drain and exit-code
  # collection run concurrently with other workers.
  var output = ""
  var exitCode = 1
  var spawnFailed = false
    ## "the harness did not obtain an answer", in either phase. Kept as
    ## one flag because both phases have the same consequence: the
    ## runner has no trustworthy verdict for this case.
  var timedOut = false
  var timeoutDescription = ""
  var groupRefused = false
    ## The runner reached a verdict and refused it: this case left
    ## exact-owner-token processes alive after bounded cleanup. Tracked
    ## apart from ``spawnFailed`` because the two have OPPOSITE meanings —
    ## ``spawnFailed`` is "no verdict obtainable" (ERROR), this is "verdict
    ## obtained and it is bad" (FAIL).
  # The spawn and the collect-the-answer phase are caught SEPARATELY.
  #
  # They used to share one ``try``, so every fault in the whole span was
  # labelled "spawn failed" — including faults that happened after the
  # child had already run to completion. That mislabel is not cosmetic:
  # the case in the recorded run whose stdout read
  # ``spawn failed: Bad file descriptor`` had, at 83 ms, already left a
  # complete ``{"status":"PASS"}`` result document on disk, so the child
  # plainly did start. Attributing it to the spawn sent the investigation
  # (and a retry fix) at the wrong phase.
  var phase = ""
  var childStarted = false
  var p: TestProcess
  # M19: the lease spans the execution, so the spine row's start, finish
  # and duration describe the test rather than the queueing around it.
  var testLease = history.acquireLease(
    (if tc.qualifiedName.len > 0: tc.qualifiedName else: tc.binaryStem),
    memoryBytes = leaseMemoryBytes(memoryLimitBytes))
  var childOutcome: ChildRunOutcome
  try:
    history.markStarting(testLease)
    # ``runName`` is the catalog's own ``name``, never a reconstruction.
    p = spawnedProcess(
      tc.binary, args = ["--run", tc.runName], env = childEnv)
    childStarted = true
    history.markRunning(testLease, uint64(max(p.process.processID, 0)),
      when defined(posix): uint64(max(p.processGroup, 0)) else: 0'u64)
  except OSError as e:
    spawnFailed = true
    phase = "spawn failed: " & e.msg
  except IOError as e:
    spawnFailed = true
    phase = "spawn failed (i/o): " & e.msg
  if childStarted:
    try:
      childOutcome = drainAndWaitWithTimeout(p, testTimeoutSec,
        memoryLimitBytes)
      output = childOutcome.output
      exitCode = childOutcome.exitCode
      timedOut = childOutcome.timedOut
      timeoutDescription = childOutcome.timeoutDescription
    except ProcessGroupRefusal as e:
      # Named before the harness-fault handlers so a leaked process group
      # can never be re-absorbed into ERROR.
      groupRefused = true
      output = e.msg
    except OSError as e:
      spawnFailed = true
      phase = "child started but its result could not be collected: " & e.msg
    except IOError as e:
      spawnFailed = true
      phase = "child started but its result could not be collected (i/o): " &
        e.msg
  if spawnFailed:
    result.harnessError = phase
    output = "repro_test_runner: " & phase & "\n" & output
  result.durationMs = int((epochTime() - t0) * 1000)
  if timedOut or childOutcome.memoryExceeded:
    result.stdout =
      "repro_test_runner: " & timeoutDescription &
      "; SIGKILLed\n" & output
  else:
    result.stdout = output
  # Exit-code-derived verdict. It stays the fallback: a spawn failure, a
  # timeout, or a crash before the result document is written leaves no
  # document to read, and the exit code is then the only signal there is.
  if spawnFailed:
    # The harness never obtained a verdict. Reporting FAIL here asserted
    # something about the code under test that nothing observed, and it
    # is indistinguishable in the summary from a failing assertion —
    # which is exactly how a transient ``Bad file descriptor`` at
    # ``--threads=8`` reached a suite report as a test failure.
    result.status = tsHarnessError
  elif groupRefused:
    # The mirror image of the branch above: a verdict WAS observed — the
    # case leaked processes past a bounded kill — so this is a defect in
    # the tree and belongs in ``failed``.
    result.status = tsFail
  elif timedOut or childOutcome.memoryExceeded:
    # A ceiling kill is a FAIL for the same reason a timeout is: the
    # runner observed the case misbehaving. What separates the two on the
    # spine is ``termination``, not the status.
    result.status = tsFail
  else:
    case exitCode
    of 0: result.status = tsPass
    of 2: result.status = tsSkip
    of HarnessErrorExitCode:
      result.status = tsHarnessError
      result.harnessError =
        "child reported harness exit " & $HarnessErrorExitCode &
        " (could not start the test)"
    else: result.status = tsFail
  let exitDerivedStatus = result.status

  # Consume the whole result document, not just ``duration_ms``. The
  # protocol writes ``status``, ``duration_ms``, ``checkpoints``,
  # ``exception`` and — only when non-empty — ``skipReason``. Reading
  # just the duration threw away the case's own account of what
  # happened, which is why a skip's reason never reached any summary.
  #
  # A timed-out or harness-errored child is deliberately excluded: its
  # document, if any, is a stale record from before the kill (or from a
  # previous run of the same case, since the path is derived from the
  # case name and nothing else) and must not be allowed to overturn the
  # runner's own verdict. Reading it would also manufacture a bogus
  # ``status_disagreement`` between a stale PASS document and a harness
  # exit code.
  #
  # This deliberately costs a real answer in one case: a child that ran
  # to completion, wrote a valid document, and then hit a harness fault
  # while its result was being collected. Promoting that document to the
  # verdict would let a runner that lost track of a child still vouch
  # for it, and the runner cannot tell that document apart from a stale
  # one. ERROR is the honest label; it costs one re-run and it is loud.
  #
  # A refused case is excluded for the same reason as a timed-out one: the
  # child may well have written ``{"status":"PASS"}`` before leaking the
  # group, and letting that document overturn the refusal would restore
  # exactly the fail-open the refusal exists to prevent (and would also
  # manufacture a bogus ``status_disagreement``).
  let documentPresent = fileExists(resultFile)
  var documentUnreadable = false
  # A memory-killed child is excluded for exactly the reason a timed-out
  # one is: its document, if any, predates the kill and must not be
  # allowed to overturn the runner's own verdict with a stale PASS.
  if not spawnFailed and not timedOut and not childOutcome.memoryExceeded and
      not groupRefused and
      result.status != tsHarnessError and documentPresent:
    try:
      let doc = parseJson(readFile(resultFile))
      if doc.hasKey("duration_ms"):
        result.durationMs = doc["duration_ms"].getInt(result.durationMs)
      if doc.hasKey("checkpoints") and doc["checkpoints"].kind == JArray:
        result.checkpointCount = doc["checkpoints"].len
        # Keep the text, not just the tally. This is the only place the
        # failed ``check`` expression and its operands exist for a
        # per-case child (see ``TestResult.checkpoints``).
        for entry in doc["checkpoints"]:
          if entry.kind == JString:
            result.checkpoints.add(entry.getStr())
      # ``exception`` is JSON ``null`` when the case raised nothing;
      # ``getStr`` on a non-string node yields the default.
      result.exception = doc{"exception"}.getStr("")
      # Absent for a bare ``skip()`` and for every non-skip outcome.
      # ``{}`` returns nil for a missing key and ``getStr`` tolerates
      # nil, so absence costs nothing and never raises.
      result.skipReason = doc{"skipReason"}.getStr("")
      let reported = doc{"status"}.getStr("")
      if reported.len > 0:
        var documentStatus = exitDerivedStatus
        var recognized = true
        case reported
        of "PASS": documentStatus = tsPass
        of "FAIL": documentStatus = tsFail
        of "SKIP": documentStatus = tsSkip
        else: recognized = false
        if not recognized:
          # An unknown status string is itself a protocol violation.
          # Keep the exit-code verdict and say so.
          result.statusDisagreement =
            "result file reports unrecognized status \"" & reported &
            "\"; keeping exit-code verdict " & $exitDerivedStatus &
            " (exit=" & $exitCode & ")"
        else:
          # The document is the case's first-hand account, so it wins.
          # But the two channels are specified to agree, so a
          # disagreement is a bug in the binary and is recorded rather
          # than quietly smoothed over.
          if documentStatus != exitDerivedStatus:
            result.statusDisagreement =
              "result file status " & $documentStatus &
              " contradicts exit code " & $exitCode &
              " (implies " & $exitDerivedStatus &
              "); using the result file"
          result.status = documentStatus
    except CatchableError as e:
      # A malformed or unreadable document is also a protocol fault.
      # The exit-code verdict stands.
      documentUnreadable = true
      result.statusDisagreement =
        "result file could not be read as a protocol document (" &
        e.msg & "); keeping exit-code verdict " & $exitDerivedStatus
  # ---- the child left no readable account of itself --------------------
  #
  # Everything above reads the case's own document. When there is no
  # readable document, every diagnostic field stays empty — and for a
  # child that CRASHED before ``testEnded`` that produced the worst
  # possible report: ``status = FAIL`` with checkpoints, exception,
  # harness_error and stdout all absent, and a ``result_file`` path
  # naming a file that does not exist. The blanket "no non-PASS entry may
  # be diagnostically empty" invariant was asserted by the suite but not
  # guaranteed by the runner, and triage was left with a case name.
  #
  # So say what IS known, and only that: where the document was expected,
  # that it is not readable there, and how the child finished. The status
  # is deliberately NOT touched. A child that ran and exited non-zero is
  # a FAIL — the harness DID obtain a verdict about the code under test,
  # and a crash mid-case is a defect in the tree, which is precisely what
  # ``failed`` counts. That is a different thing from ``tsHarnessError``,
  # which means no verdict was obtainable at all (spawn faults, collect
  # faults, the wrapper's exit 126); relabelling a crash as ERROR would
  # move a real defect out of the count a gate reads.
  #
  # Scoped to exactly the branch that would have read the document, so a
  # timeout, a refusal and a spawn fault — each of which already writes
  # its own account — are untouched.
  if not spawnFailed and not timedOut and not childOutcome.memoryExceeded and
      not groupRefused and
      result.status != tsHarnessError and result.status != tsPass and
      (not documentPresent or documentUnreadable):
    result.runnerDiagnosis =
      missingDocumentDiagnostic(resultFile, exitCode, documentPresent)
    result.stdout.add(result.runnerDiagnosis)
  if result.statusDisagreement.len > 0:
    result.stdout.add("\nrepro_test_runner: protocol disagreement: " &
      result.statusDisagreement & "\n")
  history.reportExecution(testLease, result, childOutcome, groupRefused)

proc nextCase(queue: ptr Queue; failFast: bool;
              out_case: var TestCase): bool =
  when defined(posix):
    if interruptedSignal.load(moAcquire) != 0:
      return false
  acquire(queue.lock)
  defer: release(queue.lock)
  if failFast and queue.failFastTriggered:
    return false
  if queue.pos >= queue.items.len:
    return false
  out_case = queue.items[queue.pos]
  inc queue.pos
  return true

proc markFailFast(queue: ptr Queue) =
  acquire(queue.lock)
  queue.failFastTriggered = true
  release(queue.lock)

const
  ConsoleCheckpointBudget = 20
    ## Console-only cap on checkpoint lines per case. The summary JSON and
    ## the case's own result document keep every line; this bound exists
    ## so one pathological case cannot bury the other 6800 in the log.

  DefaultHeartbeatIntervalSec = 60
    ## How often the heartbeat restates where the run is. Sixty seconds is
    ## short enough that a stall is visible within a minute and long enough
    ## that a multi-hour log gains a couple of hundred lines, not thousands.
    ## Override with ``REPRO_TEST_RUNNER_HEARTBEAT_SEC`` when watching a run
    ## interactively (and so the runner's own regression can observe a
    ## heartbeat without waiting a minute for one).

  HeartbeatIntervalEnv = "REPRO_TEST_RUNNER_HEARTBEAT_SEC"

  HeartbeatPollMs = 250
    ## Sleep granularity of the heartbeat thread. It wakes often so the run
    ## can join it promptly at the end; it only PRINTS once per configured
    ## interval (see ``heartbeatIntervalSec``).

# ---------------------------------------------------------------------------
# Live progress ledger
# ---------------------------------------------------------------------------
#
# A full run takes hours, and until this existed the only progress signal was
# the per-case line: no denominator, no elapsed, no running failure count, and
# nothing at all while a single slow case held a worker. A run that hit the
# outer ``timeout`` therefore yielded NOTHING a reader could act on — the
# summary JSON is written once, at the end, so a killed run had neither a
# summary nor any way to tell 20% done from 90% done.
#
# Everything below goes to STDERR. Stdout is the machine-readable side of the
# runner's contract (``--list-json`` catalogs and anything a caller pipes), so
# human progress must never be written there.
var
  progressTotal: Atomic[int]
    ## Cases scheduled for this run. Published once, before the first case.
  progressDone: Atomic[int]
  progressFailed: Atomic[int]
    ## Failures AND harness errors: from the console's point of view both are
    ## "this run is not going to be green", which is what a reader watching a
    ## long run needs to know without waiting for the summary.
  progressActive: Atomic[int]
  progressStartEpoch: float
  heartbeatStop: Atomic[bool]

proc formatElapsed(seconds: float): string =
  let total = int(seconds)
  let h = total div 3600
  let m = (total mod 3600) div 60
  let s = total mod 60
  if h > 0:
    $h & "h" & align($m, 2, '0') & "m" & align($s, 2, '0') & "s"
  else:
    $m & "m" & align($s, 2, '0') & "s"

proc progressPrefix(done, total: int): string =
  ## ``[123/1183 10%]`` — the denominator is the whole point: a bare running
  ## count cannot distinguish a run that is nearly finished from one that has
  ## barely started.
  if total > 0:
    "[" & $done & "/" & $total & " " & $(done * 100 div total) & "%] "
  else:
    "[" & $done & "] "

proc emitHeartbeat() =
  let done = progressDone.load(moRelaxed)
  let total = progressTotal.load(moRelaxed)
  let failed = progressFailed.load(moRelaxed)
  let active = progressActive.load(moRelaxed)
  let elapsed = epochTime() - progressStartEpoch
  var msg = "repro_test_runner: " & progressPrefix(done, total) &
    "elapsed=" & formatElapsed(elapsed) &
    " running=" & $active & " failed=" & $failed
  if done > 0 and total > done:
    # A projection, explicitly labelled as one. It assumes the remaining
    # cases cost what the finished ones did, which they will not exactly —
    # but "about two more hours" is the difference between waiting and
    # killing the run, and that judgement is impossible without a number.
    let projected = elapsed / done.float * (total - done).float
    msg.add(" eta~" & formatElapsed(projected))
  msg.add("\n")
  stderr.write(msg)
  stderr.flushFile()

proc heartbeatIntervalSec(): int =
  ## A non-numeric or non-positive override is ignored rather than treated as
  ## "off": losing the heartbeat is exactly the failure mode it exists to
  ## remove, so it must not be switchable by a typo.
  let configured = getEnv(HeartbeatIntervalEnv, "")
  if configured.len == 0:
    return DefaultHeartbeatIntervalSec
  try:
    let parsed = parseInt(configured)
    if parsed > 0: parsed else: DefaultHeartbeatIntervalSec
  except ValueError:
    DefaultHeartbeatIntervalSec

proc heartbeatMain(intervalSec: int) {.thread.} =
  ## Restates the ledger on a fixed interval so a run that is slow, stalled or
  ## about to be killed by the outer ``timeout`` still says where it got to.
  ## Without it a single long case (the suite has one worth ~81 minutes) makes
  ## the log indistinguishable from a wedge.
  var sinceLastMs = 0
  while not heartbeatStop.load(moAcquire):
    sleep(HeartbeatPollMs)
    sinceLastMs += HeartbeatPollMs
    if sinceLastMs >= intervalSec * 1000:
      sinceLastMs = 0
      if not heartbeatStop.load(moAcquire):
        emitHeartbeat()

proc emitProgress(quiet: bool; res: TestResult) =
  # The ledger is maintained even under ``--quiet``: the heartbeat and the
  # end-of-run accounting must not depend on whether per-case lines are being
  # printed, or a quiet run would report zero progress.
  let done = progressDone.fetchAdd(1, moRelaxed) + 1
  if res.status in {tsFail, tsHarnessError}:
    discard progressFailed.fetchAdd(1, moRelaxed)
  if quiet:
    return
  let label = "[" & $res.status & "]"
  let name =
    if res.testCase.protocolAware:
      res.testCase.binaryStem & " " & res.testCase.qualifiedName
    else:
      res.testCase.binaryStem & " (whole-binary)"
  # Show the skip reason inline: the console log is where a reader looks
  # first, and "SKIP" without a reason is exactly the opaque signal this
  # change exists to remove.
  let reason =
    if res.status == tsSkip and res.skipReason.len > 0:
      " — " & res.skipReason
    else:
      ""
  # ONE buffer, ONE write. Progress is emitted outside the results lock
  # from every worker thread, so a diagnosis printed as N separate
  # ``writeLine`` calls would interleave with other workers' lines at
  # ``--threads=8`` and stop being readable as a unit — which is the same
  # way the diagnosis gets lost that this block exists to prevent.
  var msg = progressPrefix(done, progressTotal.load(moRelaxed)) &
    label & " " & name & " (" & $res.durationMs & "ms)" &
    reason & "\n"
  if res.statusDisagreement.len > 0:
    msg.add("  ! protocol disagreement: " & res.statusDisagreement & "\n")
  # The diagnosis, inline, for anything that did not pass.
  #
  # A per-case child is run with ``--run``, and the fork's ``unittest``
  # registers no console formatter in that mode, so the child prints
  # nothing at all: before this, a per-case FAIL reached the log as one
  # bare ``[FAIL] … (5ms)`` line with the reason existing only inside a
  # result document whose path was not printed either. The console is
  # where a reader looks first; making them re-run the case by hand to
  # learn what it asserted defeats the whole per-case cutover.
  if res.status in {tsFail, tsHarnessError}:
    if res.harnessError.len > 0:
      msg.add("  ! harness error: " & res.harnessError & "\n")
    for i, cp in res.checkpoints:
      if i >= ConsoleCheckpointBudget:
        msg.add("  … " & $(res.checkpoints.len - ConsoleCheckpointBudget) &
          " more checkpoint line(s) in the result document\n")
        break
      # Checkpoints are multi-line (a stack trace rides in one entry), so
      # indent every physical line rather than only the first.
      for line in cp.splitLines():
        msg.add("  | " & line & "\n")
    if res.exception.len > 0:
      for line in res.exception.strip(leading = false).splitLines():
        msg.add("  | " & line & "\n")
    # A runner-synthesised diagnosis is the ONLY diagnostic material a
    # case that died before writing its document ever has, so it must
    # reach the console too — otherwise the log still says nothing but
    # ``[FAIL] … (5ms)`` and points at a result document that does not
    # exist.
    if res.runnerDiagnosis.len > 0:
      for line in res.runnerDiagnosis.strip(leading = false).splitLines():
        msg.add("  | " & line & "\n")
    # Always name the artifact holding the full account, so a reader who
    # needs more than the budget above knows where to look without
    # reconstructing the path from the case name.
    if res.resultFile.len > 0:
      msg.add("  → result document: " & res.resultFile & "\n")
  stderr.write(msg)
  stderr.flushFile()

proc workerLoop(args: WorkerArgs) =
  while true:
    var tc: TestCase
    if not nextCase(args.queue, args.failFast, tc):
      break
    discard atomicInc(args.activeCount[])
    discard progressActive.fetchAdd(1, moRelaxed)
    var res: TestResult
    # Defence in depth: ``runOneProtocol`` and ``runWholeBinary`` both
    # catch the spawn-time ``OSError``/``IOError`` paths internally,
    # but any unexpected raise here would otherwise tear down the
    # worker thread and silently lose every test still on the queue.
    # Convert it to a synthetic ERROR so the run completes and the
    # summary reflects what happened. ERROR rather than FAIL: an
    # exception escaping the per-case drivers is the harness failing,
    # not the case.
    try:
      if tc.protocolAware:
        res = runOneProtocol(tc, args.resultsDir, args.baseEnv[],
          args.testTimeoutSec, args.history, args.memoryLimitBytes)
      else:
        res = runWholeBinary(tc, args.resultsDir, args.baseEnv[],
          args.testTimeoutSec, args.history, args.memoryLimitBytes)
    except CatchableError as e:
      res = TestResult(
        testCase: tc,
        status: tsHarnessError,
        durationMs: 0,
        harnessError: "worker exception: " & e.msg,
        stdout: "repro_test_runner: worker exception: " & e.msg & "\n")
    discard atomicDec(args.activeCount[])
    discard progressActive.fetchSub(1, moRelaxed)

    acquire(args.resultsLock[])
    args.results[].add(res)
    release(args.resultsLock[])

    emitProgress(args.quiet, res)
    # A harness error stops scheduling under fail-fast for the same
    # reason a failure does: continuing to hand out work while the
    # harness cannot start children produces a summary that says more
    # about the host than about the tree.
    if args.failFast and res.status in {tsFail, tsHarnessError}:
      markFailFast(args.queue)

proc countStatusDisagreements(results: seq[TestResult]): int =
  ## Single definition of the aggregate's disagreement count, shared by the
  ## summary document and the exit decision so the two can never drift.
  for r in results:
    if r.statusDisagreement.len > 0:
      inc result

proc writeSummary(summaryPath: string; results: seq[TestResult];
                  wallTimeMs: int; threadsUsed: int;
                  selection: SelectionDecision; deselectedCases: int;
                  historyCaptured: bool; historyUncaptured: int) =
  var total = results.len
  var passed = 0
  var failed = 0
  var skipped = 0
  var harnessErrors = 0
  var arr = newJArray()
  for r in results:
    case r.status
    of tsPass: inc passed
    of tsFail: inc failed
    of tsSkip: inc skipped
    of tsHarnessError: inc harnessErrors
    var node = newJObject()
    node["binary"] = %r.testCase.binary
    node["binary_stem"] = %r.testCase.binaryStem
    node["protocol_aware"] = %r.testCase.protocolAware
    # Identity, spelled out. ``qualified_name`` alone forced every
    # consumer to re-split ``suite::name`` — and that split is not
    # round-trip safe (see ``TestCase.runName``), so a gate or triage
    # script reading only this artifact could not reliably name, group or
    # re-run a case and fell back to grepping the console log. All four
    # identity fields are now written verbatim from the catalog:
    #
    #   name            the case's own name, never empty
    #   suite           the case's suite; "" for a suite-less case and
    #                   for a whole-binary entry
    #   qualified_name  display identity (``suite::name``, or the stem)
    #   run_name        the ONLY string that may be passed to ``--run``;
    #                   "" for a whole-binary entry, which takes none
    node["name"] = %r.testCase.name
    node["suite"] = %r.testCase.suite
    node["qualified_name"] = %r.testCase.qualifiedName
    node["run_name"] = %r.testCase.runName
    # The rest of the case's ``--list-json`` row, verbatim. Emitted only
    # for protocol-aware cases: a whole-binary entry has no catalog row,
    # and synthesising zeroed fields for it would state as fact
    # ("threadsRequired: 0") something the producer never said.
    #
    # Which of these are measurements and which are producer constants is
    # documented once, on ``CatalogEntry``. They are written here because
    # dropping a field at the parse site is indistinguishable, to a
    # consumer of this artifact, from the producer never emitting it.
    if r.testCase.protocolAware:
      node["file"] = %r.testCase.meta.file
      node["line"] = %r.testCase.meta.line
      node["column"] = %r.testCase.meta.column
      node["kind"] = %r.testCase.meta.kind
      node["group"] = %r.testCase.meta.group
      node["threads_required"] = %r.testCase.meta.threadsRequired
      # ``xfail`` absent means the producer said nothing (JSON null),
      # which is not the same claim as "false". Absence is preserved.
      if r.testCase.meta.xfail.len > 0:
        node["xfail"] = %r.testCase.meta.xfail
      var tagsNode = newJArray()
      for t in r.testCase.meta.tags:
        tagsNode.add(%t)
      node["tags"] = tagsNode
      node["body_hash"] = %r.testCase.meta.bodyHash
      node["deterministic"] = %r.testCase.meta.deterministic
    node["status"] = %($r.status)
    node["duration_ms"] = %r.durationMs
    node["result_file"] = %r.resultFile
    # Skip reasons are the whole point of reading the result document:
    # a skip census that cannot say *why* is not a census. Emitted only
    # when the case supplied one (a bare ``skip()`` supplies none).
    if r.skipReason.len > 0:
      node["skip_reason"] = %r.skipReason
    if r.exception.len > 0:
      node["exception"] = %r.exception
    if r.checkpointCount > 0:
      node["checkpoint_count"] = %r.checkpointCount
    # The diagnosis itself, for anything that did not pass. A per-case
    # child writes no console output at all (``pmRun`` registers no
    # formatter), so without this the summary recorded that a case failed
    # and nothing whatsoever about WHY — the count said "4 checkpoints
    # exist" and pointed at no channel that carried them.
    if r.status != tsPass and r.checkpoints.len > 0:
      var cps = newJArray()
      for c in r.checkpoints:
        cps.add(%c)
      node["checkpoints"] = cps
    # Why the harness could not run this case. Present iff status is
    # ERROR, so a consumer never has to infer the distinction between a
    # failing assertion and a harness fault from free-form stdout.
    if r.harnessError.len > 0:
      node["harness_error"] = %r.harnessError
    # A protocol-channel contradiction is a defect signal about the test
    # binary, so it rides in the summary rather than only in stdout.
    if r.statusDisagreement.len > 0:
      node["status_disagreement"] = %r.statusDisagreement
    # Include the captured merged stdout/stderr for FAIL entries so
    # the build report carries the failure context (e.g. D6's
    # ``IDLE TIMEOUT after Ns without output; SIGKILLed`` prefix). PASS entries are kept
    # lightweight — their stdout would otherwise blow up the summary
    # file on a 500-test sweep.
    if r.status != tsPass and r.stdout.len > 0:
      node["stdout"] = %r.stdout
    arr.add(node)
  var doc = newJObject()
  var summary = newJObject()
  summary["total"] = %total
  summary["passed"] = %passed
  summary["failed"] = %failed
  summary["skipped"] = %skipped
  # Cases the harness could not run. Kept out of ``failed`` on purpose:
  # ``failed`` is a statement about the tree, ``harness_errors`` is a
  # statement about the run. Merging them makes a flaky host look like a
  # broken tree, and hiding them makes a run that executed nothing look
  # green. Like ``status_disagreements`` this count forces a non-zero
  # aggregate exit.
  summary["harness_errors"] = %harnessErrors
  # A protocol disagreement is a first-class aggregate outcome, not a note
  # in a per-case record. It used to be written per case and influence
  # nothing at all — the run still exited 0. It now decides the exit code,
  # so it is counted here where every other exit-relevant number lives.
  summary["status_disagreements"] = %countStatusDisagreements(results)
  summary["wall_time_ms"] = %wallTimeMs
  summary["threads"] = %threadsUsed
  # M19: whether this run's executions reached RunQuota's observation
  # store. Recorded because a reader of this artifact otherwise cannot
  # tell "the store has no rows for this run because there was no daemon"
  # from "the store lost them" — and an absent history that reads as a
  # complete one is the failure OS-2 is about.
  summary["runquota_history"] = %historyCaptured
  # OS-2: how many executions ran with no lease behind them, because the
  # daemon queued or denied the candidate. A run whose history is thin
  # says how thin rather than presenting the rows it did get as the
  # whole picture.
  summary["runquota_history_uncaptured"] = %historyUncaptured
  # Why this run's case set is the size it is. Without this a reader of
  # the artifact cannot tell a deliberately selected subset from a run
  # that lost cases — the two produce the same shape of document and the
  # same green summary. ``selected_subset`` is the single boolean a gate
  # should read before treating ``total`` as coverage.
  var sel = newJObject()
  sel["requested"] = %selection.enabled
  sel["applied"] = %(selection.enabled and selection.usable)
  sel["selected_subset"] = %(selection.enabled and selection.usable and
                             deselectedCases > 0)
  sel["deselected_unchanged"] = %deselectedCases
  if selection.path.len > 0:
    sel["catalog"] = %selection.path
  if selection.reason.len > 0:
    sel["fell_back_because"] = %selection.reason
  summary["selection"] = sel
  doc["summary"] = summary
  doc["tests"] = arr
  ensureDir(parentDir(summaryPath))
  writeFile(summaryPath, doc.pretty())

# ---- main ------------------------------------------------------------

type
  RunnerOpts = object
    binDir: string
    threads: int
    runBuild: bool
    summaryPath: string
    quiet: bool
    filters: seq[string]
    resultsDir: string
    testTimeoutSec: int
    catalogWritePath: string
      ## ``--catalog-write PATH``: after probing, record every case's
      ## ``bodyHash`` here. Empty means "write nothing".
    catalogReadPath: string
      ## ``--catalog-read PATH``: consult this catalog and skip cases
      ## whose ``bodyHash`` it positively vouches for. Empty means "run
      ## everything", which is the default and always remains available.
    historyEnabled: bool
      ## M19. ON by default and turned off by ``--no-runquota-history``
      ## / ``REPRO_TEST_NO_RUNQUOTA_HISTORY=1``. "On" means "record if a
      ## daemon answers": with no daemon the reporter's ``open`` returns
      ## false and the run proceeds unchanged, because OS-4 says a
      ## missing daemon MUST NOT be reported as an error.
      ##
      ## THIS FLAG DOES NOT GATE THE RUNNER'S CONCURRENCY. See
      ## ``HistoryReporter.acquireLease``: a candidate the daemon queues
      ## is abandoned rather than waited for, so admission never
      ## reorders or delays a test. OS-1 is the reason — "Recording an
      ## observation MUST NOT block ... Losing an observation is always
      ## preferable to perturbing the work being observed" — and the
      ## decision about whether RunQuota should also SCHEDULE this
      ## runner belongs to a later milestone, not to a reporter.
    memoryLimitMb: int
      ## ``--test-memory-limit-mb=N`` (env ``REPRO_TEST_MEMORY_LIMIT_MB``),
      ## 0 = off and the default. The resident size a test's whole
      ## process tree may reach, which is ALSO the memory it reserves
      ## from RunQuota. A test that crosses it is killed and its spine
      ## row reads ``termination = oom_killed`` rather than ``exited``.

proc defaultThreads(): int =
  let env = getEnv("REPRO_TEST_THREADS")
  if env.len > 0:
    try: return parseInt(env)
    except ValueError: discard
  let np = getEnv("NPROC")
  if np.len > 0:
    try: return parseInt(np)
    except ValueError: discard
  result = countProcessors()
  if result <= 0:
    result = 1

proc parseArgs(): RunnerOpts =
  result.binDir = DefaultBinDir
  result.threads = defaultThreads()
  result.runBuild = true
  result.summaryPath = DefaultSummaryPath
  result.quiet = false
  result.filters = @[]
  result.resultsDir = DefaultResultsSubdir
  result.testTimeoutSec = 0
  result.catalogWritePath = ""
  result.catalogReadPath = ""
  result.historyEnabled = getEnv("REPRO_TEST_NO_RUNQUOTA_HISTORY", "") notin
    ["1", "true", "yes"]
  result.memoryLimitMb = 0
  let memoryLimitEnv = getEnv("REPRO_TEST_MEMORY_LIMIT_MB", "")
  if memoryLimitEnv.len > 0:
    try: result.memoryLimitMb = max(0, parseInt(memoryLimitEnv))
    except ValueError: discard
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "threads", "j": result.threads = parseInt(p.val)
      of "bin-dir": result.binDir = p.val
      of "build": result.runBuild = true
      of "no-build": result.runBuild = false
      of "summary-json": result.summaryPath = p.val
      of "results-dir": result.resultsDir = p.val
      of "quiet": result.quiet = true
      of "filter": result.filters.add(p.val)
      of "catalog-write":
        if p.val.len == 0:
          stderr.writeLine "repro_test_runner: --catalog-write requires a path"
          quit(2)
        result.catalogWritePath = p.val
      of "catalog-read":
        if p.val.len == 0:
          stderr.writeLine "repro_test_runner: --catalog-read requires a path"
          quit(2)
        result.catalogReadPath = p.val
      of "test-timeout":
        try:
          result.testTimeoutSec = parseInt(p.val)
        except ValueError:
          stderr.writeLine "repro_test_runner: --test-timeout requires " &
            "an integer (seconds)"
          quit(2)
        if result.testTimeoutSec < 0:
          result.testTimeoutSec = 0
      of "no-runquota-history": result.historyEnabled = false
      of "runquota-history": result.historyEnabled = true
      of "test-memory-limit-mb":
        try:
          result.memoryLimitMb = parseInt(p.val)
        except ValueError:
          stderr.writeLine "repro_test_runner: --test-memory-limit-mb " &
            "requires an integer (megabytes)"
          quit(2)
        if result.memoryLimitMb < 0:
          result.memoryLimitMb = 0
      of "help", "h":
        echo "repro_test_runner — protocol-level parallel test runner"
        # The old text said "default $NPROC". It never was: an absent or
        # non-positive --threads has always been clamped to 1 twenty lines
        # below. Callers that want a host-derived value compute it themselves
        # (scripts/test_parallelism.sh), which is where the nested-build
        # budget lives.
        echo "  --threads N         worker count (default 1)"
        echo "  --bin-dir DIR       scan DIR for test binaries"
        echo "  --no-build          skip ``repro build test`` step"
        echo "  --summary-json P    write per-run JSON summary to P"
        echo "  --results-dir DIR   per-test JSON result file dir"
        echo "  --filter GLOB       only run binaries whose stem matches"
        echo "  --catalog-write P   record every case's bodyHash to P"
        echo "  --catalog-read P    skip cases whose bodyHash P vouches " &
          "for; any doubt runs them"
        echo "                      a catalog is only valid for the " &
          "checkout path and --bin-dir it"
        echo "                      was written under; used anywhere " &
          "else it is refused and all run"
        echo "                      hashes cover compiled sources only, " &
          "not data files read at run"
        echo "                      time, env vars or external tools"
        echo "  --quiet             suppress per-test progress lines " &
          "(the periodic heartbeat stays)"
        echo "  --test-timeout=N    per-test idle timeout; output resets it, " &
          "as does process-group CPU"
        echo "                      progress (so a CPU-starved test is not " &
          "mistaken for a hung one);"
        echo "                      hard ceiling 4xN still kills a livelock " &
          "(seconds, 0=off)"
        echo "  --no-runquota-history"
        echo "                      do not record executions into " &
          "RunQuota's observation store"
        echo "  --test-memory-limit-mb=N"
        echo "                      resident ceiling per test tree, and " &
          "the RunQuota memory reservation;"
        echo "                      a test that crosses it is killed and " &
          "recorded as oom_killed (0=off)"
        quit(0)
      else:
        stderr.writeLine "repro_test_runner: unknown option --" & p.key
        quit(2)
    of cmdArgument:
      stderr.writeLine "repro_test_runner: unexpected positional: " &
        p.key
      quit(2)
  if result.threads <= 0:
    result.threads = 1
  # Child tests routinely invoke ``git -C`` or change their process working
  # directory. Keep both GIT_CONFIG_GLOBAL and protocol result-file paths
  # stable across those operations by resolving the shared results directory
  # once, before any child environment is constructed.
  result.resultsDir = absolutePath(result.resultsDir)

proc matchesFilter(stem: string; filters: seq[string]): bool =
  if filters.len == 0:
    return true
  for f in filters:
    if f.len > 0 and stem.contains(f):
      return true
  false

proc requiresExclusiveExecution(tc: TestCase): bool =
  tc.binaryStem in ExclusiveStems

proc exclusiveRank(tc: TestCase): int =
  ## Latency-sensitive microbenchmarks must run before the heavyweight
  ## self-hosted build cluster. They are exclusive because concurrent load would
  ## pollute the measurement; running them after the build cluster can also
  ## inherit unrelated post-build host settling and daemon cleanup noise.
  if tc.binaryStem == "t_e2e_shell_hook_noop_latency":
    return 0
  result = 10

proc cmpExclusiveTestCase(a, b: TestCase): int =
  result = cmp(exclusiveRank(a), exclusiveRank(b))
  if result == 0:
    result = cmp(a.binaryStem, b.binaryStem)

# Worker threads need plain pointers, not closures, so we use a top-
# level thread proc that receives a ``WorkerArgs`` value.
proc workerMain(args: WorkerArgs) {.thread.} =
  {.cast(gcsafe).}:
    # Test-process registration is synchronized explicitly by
    # activeProcessGroupsLock on POSIX.
    workerLoop(args)

proc findNixStoreLibDir(nameFragment: string; libraryNames: openArray[string]): string =
  ## Return the first already-realized /nix/store library directory whose
  ## basename contains `nameFragment` and that actually contains one of
  ## `libraryNames`. This deliberately avoids picking split `-dev`/`-bin`
  ## outputs that match the package name but cannot satisfy dyld/ld.so.
  if not dirExists("/nix/store"):
    return ""
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir:
      continue
    if path.lastPathPart.contains(nameFragment):
      let libDir = path / "lib"
      if not dirExists(libDir):
        continue
      for libraryName in libraryNames:
        if fileExists(libDir / libraryName):
          return libDir
  ""

proc findLibDirOnEnvPath(pathEnv: string; libraryNames: openArray[string]): string =
  ## Prefer the active dev-shell loader path before scanning /nix/store.
  ## Long-lived workstations often retain older zstd closures; choosing a
  ## random store match can make a newer zstd binary load an older libzstd.
  for dir in pathEnv.split($PathSep):
    if dir.len == 0 or not dirExists(dir):
      continue
    for libraryName in libraryNames:
      if fileExists(dir / libraryName):
        return dir
  ""

proc prependEnvPath(name: string; entries: openArray[string]) =
  var prefix: seq[string]
  for entry in entries:
    if entry.len > 0 and dirExists(entry):
      prefix.add(entry)
  if prefix.len == 0:
    return
  let existing = getEnv(name)
  let sep = $PathSep
  if existing.len > 0:
    putEnv(name, prefix.join(sep) & sep & existing)
  else:
    putEnv(name, prefix.join(sep))

proc ensureNixRuntimeLibraryEnv() =
  let clingoLib =
    if getEnv("CLINGO_LIB").len > 0: getEnv("CLINGO_LIB")
    else:
      let fromEnv = findLibDirOnEnvPath(getEnv("LD_LIBRARY_PATH") & $PathSep &
        getEnv("DYLD_LIBRARY_PATH") & $PathSep &
        getEnv("DYLD_FALLBACK_LIBRARY_PATH"),
        ["libclingo.dylib", "libclingo.so"])
      if fromEnv.len > 0: fromEnv
      else: findNixStoreLibDir("clingo-5.", ["libclingo.dylib", "libclingo.so"])
  let zstdLib =
    if getEnv("ZSTD_LIB").len > 0: getEnv("ZSTD_LIB")
    else:
      let fromEnv = findLibDirOnEnvPath(getEnv("LD_LIBRARY_PATH") & $PathSep &
        getEnv("DYLD_LIBRARY_PATH") & $PathSep &
        getEnv("DYLD_FALLBACK_LIBRARY_PATH"),
        ["libzstd.dylib", "libzstd.so.1", "libzstd.so"])
      if fromEnv.len > 0: fromEnv
      else: findNixStoreLibDir("zstd-1.", ["libzstd.dylib", "libzstd.so.1", "libzstd.so"])
  if clingoLib.len > 0:
    putEnv("CLINGO_LIB", clingoLib)
  if zstdLib.len > 0:
    putEnv("ZSTD_LIB", zstdLib)
  when defined(posix):
    prependEnvPath("DYLD_LIBRARY_PATH", [clingoLib, zstdLib])
    prependEnvPath("DYLD_FALLBACK_LIBRARY_PATH", [clingoLib, zstdLib])
    prependEnvPath("LD_LIBRARY_PATH", [clingoLib, zstdLib])

proc putEnvIfUnsetDir(name, path: string) =
  if getEnv(name).len == 0 and dirExists(path):
    putEnv(name, path)

proc findNixStoreSourceDir(namePart, marker: string): string =
  when defined(posix):
    let storeRoot = "/nix/store"
    if dirExists(storeRoot):
      for kind, path in walkDir(storeRoot):
        if kind == pcDir and namePart in path.lastPathPart and
            fileExists(path / marker):
          return path
  ""

proc ensureWorkspaceSourceEnv(repoRoot: string) =
  ## Nested repro builds compile provider/interface helpers from scratch
  ## projects, often against a /nix/store source snapshot. In that context
  ## config.nims cannot discover developer sibling checkouts via "../...".
  ## Seed the same source-package env vars the dev shell normally carries so
  ## child tests can compile out-of-tree providers without depending on the
  ## runner's launch shell.
  let parent = repoRoot.parentDir
  putEnvIfUnsetDir("REPROBUILD_SOURCE_ROOT", repoRoot)
  putEnvIfUnsetDir("REPRO_TEST_ADAPTERS_SRC",
    parent / "reprobuild-test-adapters" / "src")
  putEnvIfUnsetDir("REPRO_CT_TEST_RUNNER_SRC",
    parent / "reprobuild-ct-test-runner")
  putEnvIfUnsetDir("CODETRACER_SRC", parent / "codetracer" / "src")
  putEnvIfUnsetDir("STACKABLE_HOOKS_SRC",
    parent / "nim-stackable-hooks" / "src")
  putEnvIfUnsetDir("BEARSSL_SRC", parent / "nim-bearssl")
  if getEnv("BEARSSL_SRC").len == 0:
    let bearssl = findNixStoreSourceDir("nim-bearssl-", "bearssl.nim")
    if bearssl.len > 0:
      putEnv("BEARSSL_SRC", bearssl)

proc main() =
  let opts = parseArgs()
  let cwd = getCurrentDir()

  # Catalog discovery executes test binaries, so it needs the same Nix loader
  # environment as the later test-case execution path. Establish it before
  # anything can call probeBinary/runListJson; doing this only before worker
  # creation is too late for every probe in the catalog-building loop below.
  ensureNixRuntimeLibraryEnv()

  if opts.runBuild:
    if not buildEngine(cwd):
      quit(1)

  let binaries = scanTestBinaries(opts.binDir)
  if binaries.len == 0:
    stderr.writeLine "repro_test_runner: no test binaries found under " &
      opts.binDir
    quit(1)

  ensureDir(opts.resultsDir)

  # Build the work queue: one TestCase per protocol test, or one
  # whole-binary TestCase per non-protocol binary.
  var filteredBinaries: seq[string] = @[]
  for binary in binaries:
    let stem = splitFile(binary).name
    if matchesFilter(stem, opts.filters):
      filteredBinaries.add(binary)
  stderr.writeLine "repro_test_runner: probing " &
    $filteredBinaries.len & " of " & $binaries.len & " binaries"
  # Selection is decided BEFORE any case is enqueued, and the decision is
  # recorded. ``selection.usable`` false — for any reason, including the
  # ordinary "there is no catalog yet" — means the catalog subtracts
  # nothing and the run is the full run.
  var selection = SelectionDecision(
    enabled: opts.catalogReadPath.len > 0,
    usable: false,
    reason: "",
    path: opts.catalogReadPath)
  var priorCatalog = RunCatalog(
    hashes: initTable[string, Table[string, string]]())
  if selection.enabled:
    let loaded = loadRunCatalog(opts.catalogReadPath, cwd, opts.binDir)
    priorCatalog = loaded.catalog
    selection.usable = loaded.usable
    selection.reason = loaded.reason
    if not selection.usable:
      # Announced, never silent. A selection mechanism that quietly
      # declines to select is acceptable; one that quietly declines to
      # RUN is not, and the only way to tell them apart from outside is
      # for the runner to say which happened.
      stderr.writeLine "repro_test_runner: --catalog-read not usable — " &
        selection.reason & "; running every case"

  var queue = Queue(items: @[])
  initLock(queue.lock)
  var protocolBinaries = 0
  var opaqueBinaries = 0
  var totalCases = 0
  var deselectedCases = 0
  var probed: seq[tuple[stem: string; protocol: bool;
                        catalog: seq[CatalogEntry]]] = @[]
  for binary in binaries:
    let stem = splitFile(binary).name
    if not matchesFilter(stem, opts.filters):
      continue
    let probe = probeBinary(binary)
    probed.add((stem: stem, protocol: probe.protocol, catalog: probe.catalog))
    if probe.protocol:
      inc protocolBinaries
      for entry in probe.catalog:
        # The one place selection can remove work. Note the asymmetry:
        # a case is dropped only when the catalog positively vouches for
        # it (``caseIsUnchanged``); everything else — unknown binary,
        # unknown case, empty hash on either side, unusable catalog —
        # falls through to enqueue.
        if selection.usable and caseIsUnchanged(priorCatalog, stem, entry):
          inc deselectedCases
          continue
        var tc = TestCase(
          binary: binary,
          binaryStem: stem,
          protocolAware: true,
          suite: entry.suite,
          name: entry.bare,
          # Display/report identity is derived; the execution argument
          # never is. See ``TestCase.runName``.
          qualifiedName: qualifyName(stem, entry.suite, entry.bare),
          runName: entry.runName,
          # The catalog row rides along whole. See ``TestCase.meta``.
          meta: entry)
        queue.items.add(tc)
        inc totalCases
    else:
      # A binary the runner cannot enumerate is never deselected: with no
      # per-case hashes there is nothing to compare, so it runs whole
      # every time. Under-running here would be the exact silent
      # coverage loss the fail-closed rule exists to prevent.
      inc opaqueBinaries
      var tc = TestCase(
        binary: binary,
        binaryStem: stem,
        protocolAware: false,
        suite: "",
        name: stem,
        qualifiedName: stem,
        runName: "")
      queue.items.add(tc)
      inc totalCases

  # Written from what was just probed, so the catalog always describes
  # the binaries as they are NOW — never as a prior catalog said they
  # were. Writing happens whether or not reading did, so
  # ``--catalog-read X --catalog-write X`` refreshes in place.
  if opts.catalogWritePath.len > 0:
    let doc = runCatalogDocument(cwd, opts.binDir, probed)
    try:
      ensureDir(parentDir(absolutePath(opts.catalogWritePath)))
      writeFile(opts.catalogWritePath, doc.pretty())
      stderr.writeLine "repro_test_runner: wrote run catalog for " &
        $probed.len & " binaries to " & opts.catalogWritePath
    except CatchableError as e:
      stderr.writeLine "repro_test_runner: could not write run catalog to " &
        opts.catalogWritePath & " (" & e.msg & ")"
      quit(2)

  stderr.writeLine "repro_test_runner: " & $protocolBinaries &
    " protocol-aware, " & $opaqueBinaries & " whole-binary, " &
    $totalCases & " test cases, " & $opts.threads & " threads"
  if selection.enabled:
    if selection.usable:
      stderr.writeLine "repro_test_runner: hash-difference selection " &
        "against " & selection.path & " deselected " & $deselectedCases &
        " unchanged case(s); " & $totalCases & " selected"
    else:
      stderr.writeLine "repro_test_runner: hash-difference selection " &
        "deselected 0 cases (catalog unusable)"

  # Publish the denominator BEFORE the first case runs. Every progress line
  # from here on carries "done of total", which is the difference between a
  # log a reader can act on and one that only says work is happening.
  progressTotal.store(totalCases, moRelaxed)

  var resultsLock: Lock
  initLock(resultsLock)
  var results: seq[TestResult] = @[]
  var activeCount: int = 0
  let failFast = getEnv("REPRO_TEST_FAIL_FAST") == "1"

  # Hermetic git config for every test process. Tests run real ``git`` (init /
  # commit / push to local remotes), and the host/runner's user or system git
  # config must NOT leak in: a global ``commit.gpgsign = true`` +
  # ``user.signingkey`` (common on dev boxes / CI runners) makes an otherwise-
  # plain test commit try to sign and fail non-deterministically with "gpg:
  # signing failed: No secret key" — depending on whatever the surrounding shell
  # carries. Pin git's config discovery to a controlled file (identity,
  # init.defaultBranch=main, commit/tag gpgsign=false) and ignore the system
  # config, so plain test commits never sign and the suite is reproducible.
  #
  # NOTE: deliberately do NOT override HOME/GNUPGHOME. Pointing GNUPGHOME at an
  # empty dir makes any gpg invocation (a test that explicitly opts into signing)
  # start gpg-agent and block on pinentry — hanging the whole run until the 4h
  # overall timeout. Neutralizing ``commit.gpgsign`` at the git layer fixes the
  # leak without inviting that hang; tests that genuinely sign manage their own
  # keys.
  #
  # Applied with ``putEnv`` on the main thread BEFORE the env snapshot and before
  # any worker spawns, so it is captured by BOTH spawn paths: the protocol path
  # (which clones the snapshot into a per-child env table) AND the whole-binary
  # path (which spawns with ``env = nil``, inheriting this live process env).
  # Mutating the global env here is safe — single-threaded setup phase; the
  # "no ``putEnv`` after snapshot" rule the worker pool follows still holds.
  block hermeticGitConfig:
    let hermeticGitConfigFile = opts.resultsDir / "hermetic-gitconfig"
    writeFile(hermeticGitConfigFile,
      "[user]\n" &
      "\tname = Reprobuild Test\n" &
      "\temail = reprobuild-test@example.invalid\n" &
      "[init]\n" &
      "\tdefaultBranch = main\n" &
      "[commit]\n" &
      "\tgpgsign = false\n" &
      "[tag]\n" &
      "\tgpgsign = false\n" &
      "[safe]\n" &
      "\tdirectory = *\n")
    putEnv("GIT_CONFIG_GLOBAL", hermeticGitConfigFile)
    putEnv("GIT_CONFIG_NOSYSTEM", "1")

  ensureWorkspaceSourceEnv(cwd)

  var exclusiveItems: seq[TestCase] = @[]
  var parallelItems: seq[TestCase] = @[]
  for tc in queue.items:
    if requiresExclusiveExecution(tc):
      exclusiveItems.add(tc)
    else:
      parallelItems.add(tc)
  exclusiveItems.sort(cmpExclusiveTestCase)
  queue.items = parallelItems

  if exclusiveItems.len > 0:
    stderr.writeLine "repro_test_runner: " & $exclusiveItems.len &
      " cases require exclusive execution"

  # Snapshot the process environment exactly once, on the main thread,
  # before any worker is created. From this point on no code in this
  # process touches the global ``environ`` — workers compose per-child
  # env tables by cloning this seq and overriding ``NIMTEST_RESULT_FILE``.
  when defined(posix):
    cleanupTracePath = getEnv(CleanupTraceEnv)
  var baseEnv: seq[tuple[key, value: string]] = @[]
  for (k, v) in envPairs():
    when defined(posix):
      # The optional cleanup trace is runner-only observability. Do not let a
      # test fixture forge the production cleanup events asserted by the
      # integration regression.
      if k != CleanupTraceEnv:
        baseEnv.add((k, v))
    else:
      baseEnv.add((k, v))

  when defined(posix):
    # mkdtemp-backed 0700 namespace prevents stale files from a crashed prior
    # runner (including a reused PID) from impersonating child completion or
    # release records in this invocation.
    processGroupStateDir =
      createTempDir("repro-test-runner-process-groups-", "")
    setFilePermissions(processGroupStateDir,
      {fpUserRead, fpUserWrite, fpUserExec})
    var interruptThread = startInterruptWaiter()

  # ---- M19: open the observation reporter --------------------------------
  #
  # OPENED HERE, ON THE MAIN THREAD, BEFORE ANY WORKER OR EXCLUSIVE CASE
  # RUNS, and closed after every one of them has finished. One session
  # for the whole invocation, so the daemon opens one ``runs`` row for
  # this run rather than one per worker.
  #
  # A FAILURE TO OPEN IS NOT AN ERROR AND IS NOT ANNOUNCED AS ONE (OS-4:
  # "a missing daemon MUST NOT be reported as an error"). The run
  # proceeds with capture off and the summary says so, which is the
  # difference between a quiet degradation and a silent one.
  let memoryLimitBytes =
    if opts.memoryLimitMb > 0: uint64(opts.memoryLimitMb) * 1024'u64 * 1024'u64
    else: 0'u64
  var history: HistoryReporter
  var historyPtr: ptr HistoryReporter = nil
  if opts.historyEnabled:
    if open(addr history):
      historyPtr = addr history

  let wallT0 = epochTime()
  progressStartEpoch = wallT0
  # Started before the exclusive phase, not before the worker pool: the
  # exclusive cases are the slowest in the suite and run one at a time, so
  # they are exactly the stretch where the log would otherwise go quiet.
  var heartbeatThread: Thread[int]
  createThread(heartbeatThread, heartbeatMain, heartbeatIntervalSec())
  var exclusiveFailed = false

  if exclusiveItems.len > 0 and not (failFast and queue.failFastTriggered):
    for tc in exclusiveItems:
      when defined(posix):
        if interruptedSignal.load(moAcquire) != 0:
          break
      discard progressActive.fetchAdd(1, moRelaxed)
      var res: TestResult
      try:
        if tc.protocolAware:
          res = runOneProtocol(tc, opts.resultsDir, baseEnv,
            opts.testTimeoutSec, historyPtr, memoryLimitBytes)
        else:
          res = runWholeBinary(tc, opts.resultsDir, baseEnv,
            opts.testTimeoutSec, historyPtr, memoryLimitBytes)
      except CatchableError as e:
        res = TestResult(
          testCase: tc,
          status: tsHarnessError,
          durationMs: 0,
          harnessError: "exclusive worker exception: " & e.msg,
          stdout: "repro_test_runner: exclusive worker exception: " &
            e.msg & "\n")
      discard progressActive.fetchSub(1, moRelaxed)
      results.add(res)
      emitProgress(opts.quiet, res)
      if failFast and res.status in {tsFail, tsHarnessError}:
        exclusiveFailed = true
        break

  let args = WorkerArgs(
    queue: addr queue,
    resultsLock: addr resultsLock,
    results: addr results,
    resultsDir: opts.resultsDir,
    quiet: opts.quiet,
    failFast: failFast,
    testTimeoutSec: opts.testTimeoutSec,
    activeCount: addr activeCount,
    baseEnv: addr baseEnv,
    history: historyPtr,
    memoryLimitBytes: memoryLimitBytes)

  let nThreads =
    if queue.items.len == 0 or (failFast and exclusiveFailed):
      0
    else:
      min(opts.threads, queue.items.len)
  var threads = newSeq[Thread[WorkerArgs]](nThreads)
  for i in 0 ..< nThreads:
    createThread(threads[i], workerMain, args)
  joinThreads(threads)

  # Joined before the cleanup barrier below so no heartbeat line can interleave
  # with the fatal-cleanup diagnostics or the final summary.
  heartbeatStop.store(true, moRelease)
  joinThread(heartbeatThread)

  when defined(posix):
    # `interruptedSignal` is stored before the waiter starts cleanup. Retaining
    # and joining its handle is the explicit cleanup-complete barrier: the
    # runner cannot publish a summary or return 129/130/143 while TERM/KILL of
    # the registered groups is still in flight.
    if interruptedSignal.load(moAcquire) != 0:
      joinThread(interruptThread)
    # Every normal worker path reaps and unregisters its supervisor. Keep a
    # fail-closed final drain in case a worker aborted between those steps.
    if not reapResidualActiveProcessGroups():
      stderr.writeLine(
        "repro_test_runner: fatal: exact owner-token processes survived " &
        "final bounded cleanup; refusing to emit a summary")
      exitnow(1)

  let wallMs = int((epochTime() - wallT0) * 1000)

  # Closed only after every worker and every exclusive case has finished,
  # so no thread can be holding the socket while the session is torn down.
  let historyCaptured = historyPtr.capturing()
  let historyUncaptured = historyPtr.uncaptured()
  historyPtr.close()

  writeSummary(opts.summaryPath, results, wallMs, nThreads,
    selection, deselectedCases, historyCaptured, historyUncaptured)

  var passed = 0
  var failed = 0
  var skipped = 0
  var harnessErrors = 0
  for r in results:
    case r.status
    of tsPass: inc passed
    of tsFail: inc failed
    of tsSkip: inc skipped
    of tsHarnessError: inc harnessErrors
  let disagreements = countStatusDisagreements(results)

  stderr.writeLine "repro_test_runner: ran " & $results.len &
    " cases in " & $wallMs & "ms — pass=" & $passed &
    " fail=" & $failed & " skip=" & $skipped &
    " error=" & $harnessErrors &
    " disagree=" & $disagreements &
    " (summary at " & opts.summaryPath & ")"
  if harnessErrors > 0:
    stderr.writeLine "repro_test_runner: " & $harnessErrors &
      " case(s) could not be RUN (spawn/harness fault, not a test " &
      "result); the run is FAILED (see harness_error in the summary)"
    for r in results:
      if r.status == tsHarnessError:
        stderr.writeLine "  ! ERROR " & r.testCase.binaryStem & " " &
          r.testCase.qualifiedName & ": " & r.harnessError
  if disagreements > 0:
    stderr.writeLine "repro_test_runner: " & $disagreements &
      " case(s) reported contradictory status channels; the run is " &
      "FAILED regardless of the per-case labels (see " &
      "status_disagreement in the summary)"

  when defined(posix):
    cleanupProcessGroupStateDir()
    let receivedSignal = interruptedSignal.load(moAcquire)
    if receivedSignal != 0:
      # Nim's quit() clamps values above 127; use the POSIX primitive so the
      # caller observes the conventional 128+signal status (130/143).
      exitnow(cint(128 + receivedSignal))

  # The exit decision takes BOTH channels. ``failed`` alone made the runner
  # fail-open: the result document is written from ``testEnded``, i.e.
  # before process exit, so a case that passes and then dies non-zero
  # afterwards (destructor, ``defer``, exit proc, teardown segfault) was
  # labelled PASS, never incremented ``failed``, and the aggregate exited 0.
  # A disagreement is by definition a fault that one of the two channels
  # observed, so it fails the run on its own.
  #
  # A harness error is the same shape of defect from the other end: no
  # channel produced a verdict. Absorbing it into a green exit would mean
  # a run in which nothing could be spawned reports success, so it too
  # fails the run on its own.
  if failed > 0 or disagreements > 0 or harnessErrors > 0:
    quit(1)
  quit(0)

when defined(posix):
  let internalParams = commandLineParams()
  if internalParams.len > 0 and
      internalParams[0] == ProcessGroupWrapperFlag:
    quit(processGroupWrapperMain(internalParams[1 .. ^1]))

# RunQuota-Observation-Store M20 / §17.3: ``stats flaky`` and
# ``stats duration``, answered from the shared observation store.
#
# DISPATCHED BEFORE ``main()`` BECAUSE IT IS NOT A TEST RUN: it starts no
# workers, scans no bin dir and builds nothing. Routing it through the run
# parser would make a query fail on a host with no test binaries, which is the
# ordinary case for somebody asking what has been flaky lately.
#
# THE ANSWER IS RUNNER-BLIND, WHICH IS THE WHOLE REASON IT IS HERE RATHER THAN
# INSIDE THE HISTORY REPORTER. It reads ``ext_test_execution`` and no other
# table, so a row this runner wrote and a row another runner wrote are the
# same input to it — M20's "query indistinguishably", as a property of the
# implementation rather than of the fixture.
block statsDispatch:
  let statsParams = commandLineParams()
  if statsParams.len < 2 or statsParams[0] != "stats":
    break statsDispatch
  var asJson = false
  var hostScope = false
  for arg in statsParams[2 .. ^1]:
    case arg
    of "--json", "--output-format=json": asJson = true
    of "--scope=host": hostScope = true
    else:
      stderr.writeLine "repro_test_runner stats: unknown argument " & arg
      quit(2)
  let answer = runTestStatsQuery(statsParams[1], asJson, hostScope)
  stdout.write(answer.text)
  quit(answer.exitCode)

main()
