## Windows-Build-Correctness M6 — an unblessed tool that reads entropy must
## not be cached; a blessed one must be.
##
## io-mon reports THAT a monitored process consumed randomness and refuses to
## say what it means: `mrNonDeterministic` deliberately does not force
## `mcIncomplete`, because the read WAS observed — nothing is missing from the
## capture — and io-mon's own type declaration hands the decision to "caller
## policy". Until this milestone reprobuild had no such policy: the record
## landed in `foldMonitorDepFileEvidence`'s `else: discard` arm and an action
## that drew randomness published a cache entry exactly like one that did not.
##
## The cases below drive the real `runBuild` and assert on the artefact that
## decides the next build: the published action-cache record. Asserting on a
## diagnostic string would pass against an implementation that complained and
## cached anyway, which is the failure being fixed.
##
## Three properties beyond "blessed caches, unblessed does not":
##
##   * `caller=system` IS CONSEQUENTIAL. io-mon's Windows attribution token
##     means "not the main EXE image", which covers ntdll's startup baseline
##     AND a program's own bundled DLL — libcrypto, a compiler plugin, a
##     native extension under an interpreter host. Excusing it would grade an
##     unblessed program deterministic on the strength of a distinction that
##     cannot make it. Measured: `powershell -NoProfile -Command 1+1` under
##     the M5 shim reports ProcessPrng, RtlGenRandom and CryptGenRandom, all
##     `caller=system`.
##
##   * ABSENCE OF EVIDENCE IS NOT EVIDENCE OF ABSENCE. A capture from a
##     backend that cannot observe entropy contains no `mrNonDeterministic`
##     records for the same reason a clean run does. The unblessed action must
##     be treated as if it had read entropy, or the whole policy is defeated
##     by an older shim.
##
##   * THE BLAST RADIUS IS ONE ACTION. Randomness in one edge must not make
##     the rest of the build uncacheable, and the action must still SUCCEED —
##     nothing here says its outputs are wrong, only that they may not be
##     reproducible.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 909, threadId: 909, path: path, detail: "")

proc entropyRead(source, caller: string): MonitorRecord =
  ## The shape `io_mon/shim/windows_interpose.emitNonDeterministic` writes:
  ## the entry point in `path`, `entropy source=<fn> caller=<program|system>`
  ## in `detail`.
  MonitorRecord(kind: mrNonDeterministic, observationKind: moNonDeterministic,
    osPid: 909, threadId: 909, path: source,
    detail: "entropy source=" & source & " caller=" & caller)

proc unattributedEntropyRead(source: string): MonitorRecord =
  ## The macOS / Linux shape. Those arms attribute at the HOOK and emit a
  ## record only for the program's own use, so their details carry no
  ## `caller=` token at all — absence there means "already filtered", not
  ## "unknown".
  MonitorRecord(kind: mrNonDeterministic, observationKind: moNonDeterministic,
    osPid: 909, threadId: 909, path: source,
    detail: "non-deterministic entropy source")

proc observingProfileRecords(): seq[MonitorRecord] =
  ## The preamble a real capture opens with, from the host backend's own
  ## declaration: the profile record plus one gap record per unsupported
  ## capability. On every shipped backend this advertises `non-determinism`
  ## (io-mon M5 closed it on Windows and it was already present on macOS and
  ## Linux), so silence about entropy in these captures is real information.
  profileRecords(defaultHooksMonitorProfile())

proc nonDeterminismGap(): MonitorCapabilityGap =
  MonitorCapabilityGap(
    backendFamily: defaultHooksMonitorProfile().backendFamily,
    capability: mcapNonDeterminism,
    required: false,
    inputChannel: false,
    reason: "entropy and clock sources are not hooked, so a randomness or " &
      "time read leaves no evidence")

proc blindProfileRecords(): seq[MonitorRecord] =
  ## A capture from a backend that CANNOT observe entropy — a pre-M5 Windows
  ## shim, or any future backend that has not wired the hooks. This is the
  ## case the policy must fail closed on.
  ##
  ## A real capture states this TWICE: the capability is absent from the
  ## profile's `supported=` list AND a gap record names it (io-mon
  ## `profileRecords` emits one record per declared gap). Both are present
  ## here because both are present in life; the two helpers below split them
  ## so each signal is tested on its own, since a capture carrying both would
  ## pass with either check removed.
  ##
  ## Built by mutating the real profile rather than hand-writing a detail
  ## string, so the records stay in whatever format io-mon actually emits.
  var profile = defaultHooksMonitorProfile()
  profile.supportedCapabilities.excl mcapNonDeterminism
  profile.gaps.add nonDeterminismGap()
  profileRecords(profile)

proc profileOnlyBlindRecords(): seq[MonitorRecord] =
  ## Only the `supported=` list says entropy is unobservable; no gap record.
  var profile = defaultHooksMonitorProfile()
  profile.supportedCapabilities.excl mcapNonDeterminism
  profileRecords(profile)

proc gapOnlyBlindRecords(): seq[MonitorRecord] =
  ## Only a gap record says so; the profile's `supported=` list still names
  ## the capability. A capture cannot really disagree with itself like this,
  ## which is exactly why it isolates the gap-record arm.
  var profile = defaultHooksMonitorProfile()
  profile.gaps.add nonDeterminismGap()
  profileRecords(profile)

proc writeRmdf(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

type Scenario = object
  root: string
  cacheRoot: string
  workRoot: string
  sourcePath: string
  outputPath: string
  rmdfPath: string

proc setupScenario(name: string): Scenario =
  result.root = createTempDir("repro-m6-" & name, "")
  result.cacheRoot = result.root / "cache"
  result.workRoot = result.root / "work"
  result.sourcePath = result.workRoot / "src" / "input.txt"
  result.outputPath = result.workRoot / "out" / "product.txt"
  result.rmdfPath = result.root / "action.rdep"
  createDir(result.workRoot / "src")
  createDir(result.workRoot / "out")
  writeFile(result.sourcePath, "payload\n")

proc scenarioAction(scenario: Scenario;
                    blessing: NonDeterminismPolicy;
                    justification = ""): BuildAction =
  result = builtinAction(bakCopyFile, "produce",
    cwd = scenario.workRoot,
    inputs = ["src/input.txt"],
    outputs = ["out/product.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.monitorDepfile = scenario.rmdfPath
  result.nonDeterminism = blessing
  result.nonDeterminismJustification = justification

proc published(scenario: Scenario; act: BuildAction): bool =
  ## Did the action publish an action-cache record? This is the whole
  ## consequence under test: the file the NEXT build's lookup reads.
  fileExists(dependencyEvidencePath(scenario.cacheRoot, act.id))

suite "M6 an unblessed tool's entropy costs it its cache entry":

  test "entropy from the program's own image blocks publication":
    let scenario = setupScenario("prog")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      entropyRead("BCryptGenRandom", "program")])

    let act = scenarioAction(scenario, ndpUnblessed)
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))

    # The action SUCCEEDS. Nothing about this evidence says its output is
    # wrong — only that it may not be reproducible — and failing the build
    # would be a far bigger hammer than the problem.
    check run.results[0].status == asSucceeded
    check fileExists(scenario.outputPath)
    # ...and it is not remembered.
    check not scenario.published(act)

  test "entropy reported from OUTSIDE the main image blocks it too":
    ## The load-bearing case, and the one a plausible-looking implementation
    ## gets wrong. io-mon's `caller=system` reads as "the system did it", so
    ## the tempting policy is to filter it out as the loader's startup
    ## baseline. It is not that: `callerInProgram` tests membership of the
    ## MAIN EXE IMAGE, so a program whose randomness arrives through its own
    ## bundled DLL lands here and is indistinguishable from ntdll. Filtering
    ## it would silently grade that program deterministic, which is a false
    ## clean over exactly the non-determinism the blessing model exists to
    ## make explicit.
    let scenario = setupScenario("sys")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      entropyRead("ProcessPrng", "system")])

    let act = scenarioAction(scenario, ndpUnblessed)
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check run.results[0].status == asSucceeded
    check not scenario.published(act)

  test "an unattributed (macOS/Linux) entropy record blocks it too":
    ## Those shims filter at the hook, so a record with no `caller=` token
    ## means the program's own use — the strongest form of the evidence, not
    ## the weakest.
    let scenario = setupScenario("posix")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      unattributedEntropyRead("getentropy")])

    let act = scenarioAction(scenario, ndpUnblessed)
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check run.results[0].status == asSucceeded
    check not scenario.published(act)

  test "the reason is stated, naming the source and the origin":
    ## A permanent cache miss that says nothing reads as a caching bug and
    ## gets "fixed" by someone disabling the check.
    let scenario = setupScenario("diag")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      entropyRead("RtlGenRandom", "system")])

    let act = scenarioAction(scenario, ndpUnblessed)
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    var reported = false
    for diagnostic in run.results[0].evidence.diagnostics:
      if "RtlGenRandom" in diagnostic and "not blessed" in diagnostic and
          "caller=system" in diagnostic:
        reported = true
    check reported

suite "M6 a blessed tool's entropy is a non-issue":

  test "the same capture publishes normally when the tool is blessed":
    ## Same RMDF, same action, one field different. If this failed, the
    ## milestone would have shipped a rule that makes every tool uncacheable
    ## rather than a blessing.
    let scenario = setupScenario("blessed")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      entropyRead("BCryptGenRandom", "program"),
      entropyRead("ProcessPrng", "system")])

    let act = scenarioAction(scenario, ndpEntropyBlessed,
      "temp-file names only; never reaches the output")
    let config = defaultBuildEngineConfig(scenario.cacheRoot)
    let first = runBuild(graph([act]), config)
    check first.results[0].status == asSucceeded
    check scenario.published(act)

    # And the entry is USABLE, not merely written: the second build hits it.
    # A record that existed but never matched would satisfy the assertion
    # above while delivering none of the benefit the blessing exists for.
    removeFile(scenario.outputPath)
    let second = runBuild(graph([act]), config)
    check second.results[0].cacheDecision == cdHit
    check fileExists(scenario.outputPath)

  test "the blessing's stated reason is carried into the diagnostics":
    ## The blessing is a claim someone made. It has to be quotable at the
    ## point it takes effect, or "why is this cached despite reading
    ## randomness?" is answerable only by grepping package specs.
    let scenario = setupScenario("why")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      entropyRead("BCryptGenRandom", "program")])

    let act = scenarioAction(scenario, ndpEntropyBlessed,
      "seeds a hash table; the output is named from argv")
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    var quoted = false
    for diagnostic in run.results[0].evidence.diagnostics:
      if "seeds a hash table" in diagnostic:
        quoted = true
    check quoted

  test "a blessed tool that read NO entropy is unremarkable":
    ## The blessing must not become a second, silent code path. A clean run
    ## caches for the ordinary reason and says nothing about entropy.
    let scenario = setupScenario("quiet")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath)])

    let act = scenarioAction(scenario, ndpEntropyBlessed, "justified above")
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check scenario.published(act)
    for diagnostic in run.results[0].evidence.diagnostics:
      check "entropy" notin diagnostic

suite "M6 absence of evidence is not evidence of absence":

  test "a backend that cannot observe entropy does not read as 'no entropy'":
    ## The capture contains NO `mrNonDeterministic` records — exactly like a
    ## clean run — but its own backend profile says entropy is not
    ## observable. An unblessed action must be treated as if it had read
    ## entropy, because the two silences are the same silence. Without this,
    ## the entire policy is defeated by running against an older shim.
    let scenario = setupScenario("blind")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, blindProfileRecords() & @[
      fileRead(scenario.sourcePath)])

    let act = scenarioAction(scenario, ndpUnblessed)
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check run.results[0].status == asSucceeded
    check not scenario.published(act)

  test "the profile's supported= list alone is enough to fail closed":
    ## Isolates one of the two signals a blind capture carries. With both
    ## present, removing either check leaves the case passing.
    let scenario = setupScenario("blindprof")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, profileOnlyBlindRecords() & @[
      fileRead(scenario.sourcePath)])

    let act = scenarioAction(scenario, ndpUnblessed)
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check run.results[0].status == asSucceeded
    check not scenario.published(act)

  test "a non-determinism capability GAP alone is enough to fail closed":
    ## Isolates the other signal: the profile still advertises the
    ## capability, and only the gap record contradicts it. The conservative
    ## reading has to win, or a backend that advertised optimistically and
    ## then declared the gap honestly would be trusted.
    let scenario = setupScenario("blindgap")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, gapOnlyBlindRecords() & @[
      fileRead(scenario.sourcePath)])

    let act = scenarioAction(scenario, ndpUnblessed)
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check run.results[0].status == asSucceeded
    check not scenario.published(act)

  test "the SAME blind capture publishes when the tool is blessed":
    ## The distinguishing half. The rule above must be the fail-closed arm of
    ## the blessing policy, not a blanket "old backends cannot cache": a tool
    ## whose randomness is vouched for does not care whether the monitor
    ## could have seen it.
    let scenario = setupScenario("blindok")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, blindProfileRecords() & @[
      fileRead(scenario.sourcePath)])

    let act = scenarioAction(scenario, ndpEntropyBlessed, "vouched for")
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check scenario.published(act)

  test "an observing backend with no entropy records publishes normally":
    ## The other distinguishing half, and the guard against the cheapest
    ## wrong implementation: "unblessed cacheable monitored action never
    ## publishes". A capture from a backend that CAN see entropy and saw none
    ## is real evidence of absence, and must cache — otherwise M6 would have
    ## made every unblessed tool in the tree permanently uncacheable, which
    ## is the cardinal sin in its other direction.
    let scenario = setupScenario("clean")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      fileRead(scenario.sourcePath)])

    let act = scenarioAction(scenario, ndpUnblessed)
    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check scenario.published(act)

suite "M6 the blast radius is one action":

  test "a sibling action still publishes when its neighbour read entropy":
    ## One tool's randomness must not disable the session's cache. The
    ## mechanism matters here, not just the outcome: the policy sets
    ## `disableCacheHits` on THIS action and deliberately leaves
    ## `monitorStatus` alone, because the scheduler flips a session-wide
    ## `sessionCachePublishDisabled` bit off `mesUnknownScopeLoss`. Routing
    ## entropy through the monitor-loss ladder would have been the obvious
    ## implementation and would have turned one non-deterministic edge into a
    ## whole build's worth of re-runs.
    let scenario = setupScenario("sibling")
    defer: removeDir(scenario.root)

    let dirtyRmdf = scenario.root / "dirty.rdep"
    let cleanRmdf = scenario.root / "clean.rdep"
    writeRmdf(dirtyRmdf, observingProfileRecords() & @[
      fileRead(scenario.sourcePath),
      entropyRead("BCryptGenRandom", "program")])
    writeRmdf(cleanRmdf, observingProfileRecords() & @[
      fileRead(scenario.sourcePath)])

    var dirty = builtinAction(bakCopyFile, "dirty",
      cwd = scenario.workRoot,
      inputs = ["src/input.txt"],
      outputs = ["out/dirty.txt"],
      cacheable = true,
      actionCachePolicy = ffpChecksum,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    dirty.monitorDepfile = dirtyRmdf

    # ``clean`` DEPENDS on ``dirty`` so the ordering is fixed rather than
    # scheduler-dependent: the entropy action always completes first, and its
    # effect (or absence of one) on the session is already in place when the
    # clean action's cache lookup happens.
    var clean = builtinAction(bakCopyFile, "clean",
      cwd = scenario.workRoot,
      deps = ["dirty"],
      inputs = ["src/input.txt"],
      outputs = ["out/clean.txt"],
      cacheable = true,
      actionCachePolicy = ffpChecksum,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    clean.monitorDepfile = cleanRmdf

    let config = defaultBuildEngineConfig(scenario.cacheRoot)
    let first = runBuild(graph([dirty, clean]), config)
    for item in first.results:
      check item.status == asSucceeded
    check not fileExists(dependencyEvidencePath(scenario.cacheRoot, dirty.id))
    check fileExists(dependencyEvidencePath(scenario.cacheRoot, clean.id))

    # The second build is where the mechanism shows. ``dirty`` has no cache
    # entry so it re-runs; if its entropy had been reported as an
    # unknown-scope MONITOR LOSS instead of a policy decision, the
    # scheduler's ``sessionCachePublishDisabled`` bit would now be set and
    # ``clean``'s lookup would be forced to a miss. One tool's randomness
    # must not cost every later action in the build its cache hit.
    let second = runBuild(graph([dirty, clean]), config)
    var cleanDecision = cdNotCacheable
    for item in second.results:
      if item.id == clean.id:
        cleanDecision = item.cacheDecision
    check cleanDecision == cdHit

  test "a NON-cacheable action is untouched and says nothing":
    ## An action that never publishes has nothing to withhold. Emitting the
    ## diagnostic anyway would put an "action-cache publish skipped" line on
    ## every fetch edge in every build, which is how a real signal gets
    ## trained out of a reader.
    let scenario = setupScenario("noncache")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath, observingProfileRecords() & @[
      entropyRead("BCryptGenRandom", "program")])

    var act = builtinAction(bakCopyFile, "produce",
      cwd = scenario.workRoot,
      inputs = ["src/input.txt"],
      outputs = ["out/product.txt"],
      cacheable = false,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.monitorDepfile = scenario.rmdfPath

    let run = runBuild(graph([act]), defaultBuildEngineConfig(scenario.cacheRoot))
    check run.results[0].status == asSucceeded
    for diagnostic in run.results[0].evidence.diagnostics:
      check "action-cache publish skipped" notin diagnostic

suite "M6 evidence classification, in isolation":

  test "caller attribution is read one-way and fails closed on ambiguity":
    ## Only a single `caller=program` token may be read as "the main image".
    ## A duplicated token is attacker-shaped evidence — io-mon's
    ## `trustedDetailToken` refuses to resolve one for the same reason — and
    ## here the safe answer is the one that keeps the observation
    ## consequential, since both non-`program` cases block publication.
    check entropyCallerOrigin("entropy source=X caller=program") == ecoMainImage
    check entropyCallerOrigin("entropy source=X caller=system") ==
      ecoOutsideMainImage
    check entropyCallerOrigin("non-deterministic entropy source") ==
      ecoUnattributed
    # BOTH orderings, because a mutation that keeps the LAST token still
    # answers correctly for one of them. The property is "a duplicate is
    # ambiguous", not "the second one wins".
    check entropyCallerOrigin("entropy source=X caller=program caller=system") ==
      ecoOutsideMainImage
    check entropyCallerOrigin("entropy source=X caller=system caller=program") ==
      ecoOutsideMainImage
    check entropyCallerOrigin("entropy source=X caller=program caller=program") ==
      ecoOutsideMainImage
    check entropyCallerOrigin("entropy source=X caller=") == ecoOutsideMainImage
    # A `caller=` that is part of a longer word is not a token.
    check entropyCallerOrigin("entropy source=X notcaller=program") ==
      ecoUnattributed

  test "the capability declaration is read from supported=, not required=":
    ## `required` says only which capabilities the CALLER asked for — io-mon
    ## makes the same point about the gap record's `required` flag. Keying on
    ## it would answer "nobody demanded entropy observation" when the
    ## question is "could this backend have produced the record".
    let supported = "backend=windows-interpose-hooks;supported=file-read," &
      "non-determinism,ipc-connect;required=file-read;evidenceComplete=true"
    let unsupported = "backend=windows-interpose-hooks;supported=file-read," &
      "ipc-connect;required=file-read,non-determinism;evidenceComplete=true"
    check monitorProfileSupportsNonDeterminism(supported)
    check not monitorProfileSupportsNonDeterminism(unsupported)
    # A prefix must not match: `non-determinism-lite` is not the capability.
    let lookalike = "backend=x;supported=non-determinism-lite;" &
      "required=;evidenceComplete=true"
    check not monitorProfileSupportsNonDeterminism(lookalike)

  test "a non-determinism capability gap is recognised by path and by detail":
    check capabilityGapIsNonDeterminism("non-determinism", "")
    check capabilityGapIsNonDeterminism("",
      "backend=x;capability=non-determinism;required=false;input=false;reason=r")
    check not capabilityGapIsNonDeterminism("rename",
      "backend=x;capability=rename;required=false;input=false;reason=r")
