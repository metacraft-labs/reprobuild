## An action's ENVIRONMENT must be part of its cache key, split the way
## BuildXL splits it: a DECLARED variable contributes ``NAME=value``, a
## PASSTHROUGH variable contributes ``NAME`` only.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every cache assertion drives the real `runBuild` scheduler in
## `repro_build_engine`, the real per-edge `ActionCache` + CAS in
## `repro_local_store`, a real `sh` subprocess and real files in a real
## temporary directory. The defect under test is that the environment
## reprobuild CONSTRUCTS for an action never reaches the key the action
## cache is looked up by, so a mocked store or a fake executor would make
## the whole file vacuous: the two halves that must disagree are the
## constructed env and the recorded key, and both have to be production.
##
## ## The defect
##
## `repro_build_engine.action()` accepts an `env` argument, hands it to
## the spawn path, and drops it on the floor when it composes the weak
## fingerprint. Two actions that are identical except for the value of a
## variable reprobuild itself sets are therefore ONE cache entry. The
## second one is served the first one's result.
##
## ## Why the split, and why it is not optional
##
## Keying on the whole environment by value is not the fix; it is a
## different defect. `PATH` under `nix develop` is not `PATH` in CI, and
## an action's `PATH` is built by prepending resolved tool directories to
## whatever the host has. If that value entered the key, every edge in
## every graph would invalidate on any host difference — the change would
## read as a correctness fix and land as a total cache wipe.
##
## BuildXL's answer, which this file pins:
##
## * DECLARED    — the build system chose the value. It is part of what
##                 the action IS, so `NAME=value` goes in the key.
## * PASSTHROUGH — the build system admits the HOST's value. The name is
##                 part of what the action is (it says "this action reads
##                 the host's `PATH`"); the value is not. `NAME` alone
##                 goes in the key.
##
## Governing spec text:
##
## * Filesystem-Policy-And-Observed-Inputs.md §"Environment Variables Are
##   Graph-Evaluation Inputs" — env is an input to graph evaluation, not
##   an observed action input. This file does not move that boundary; it
##   makes the graph-evaluation input actually reach the key.
## * Incremental-Invalidation.md §"Validation Criteria": "changing a read
##   input invalidates the action" and "a warm re-run of an unchanged
##   graph still executes zero actions".
##
## ## The properties, and why each one is required
##
## 1. declared value changes            => the edge RE-RUNS.
## 2. passthrough value changes         => the edge does NOT re-run.
## 3. passthrough NAME set changes      => the edge RE-RUNS.
## 4. empty env + empty passthrough     => the fingerprint is UNCHANGED.
## 5. the key is order- and duplicate-canonical.
## 6. the host environment cannot reach the key.
##
## (1) alone would pass against an engine that keys on the whole
## environment by value — the regression described above. (2) is what
## forbids that, and (2) alone would pass against an engine that ignores
## the environment entirely, which is the defect. (3) is what stops (2)
## from being vacuous: the passthrough DECLARATION is still keyed, so
## "this action reads the host's FOO" is a different action from one that
## does not. (4) is what keeps every cache record written before this
## change valid — an edge that declares no environment must fingerprint
## byte-identically to how it did, or landing this is a silent global
## cache wipe. (5) and (6) are the structural halves: a non-canonical
## rendering produces two keys for one environment (a silent miss and a
## duplicated build), and a `getEnv` reachable from the key computation
## is how an ambient value silently and permanently enters a record.

import std/[algorithm, os, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

## Both decisions mean "the recorded result is still valid, do not
## re-execute" (Incremental-Invalidation.md §"File Fingerprint Policies").
const ReuseDecisions = {cdHit, cdHybridCutoff}

const DeclaredVar = "REPRO_TEST_DECLARED_ENV"
const PassthroughVar = "REPRO_TEST_PASSTHROUGH_ENV"

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("declared-env-in-cache-key." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  runLogPath: string

proc runCount(f: Fixture): int =
  ## Out-of-band evidence: how many times the child process actually ran.
  ## "not launched" must not be merely the engine's bookkeeping agreeing
  ## with itself.
  if not fileExists(f.runLogPath):
    return 0
  for line in readFile(f.runLogPath).splitLines():
    if line.strip().len > 0:
      inc result

proc runLog(f: Fixture): string =
  if fileExists(f.runLogPath): readFile(f.runLogPath) else: ""

proc makeFixture(): Fixture =
  let root = createTempDir("repro-declared-env-key-", "")
  let workRoot = root / "work"
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  writeFile(workRoot / "src" / "fixture.txt", "fixture-generation-1\n")
  Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    runLogPath: workRoot / "out" / "runs.log")

proc envEdge(sh, workRoot: string;
             env: openArray[string] = [];
             envPassthrough: openArray[string] = []): BuildAction =
  ## The edge under test. It records BOTH variables into the run log, so
  ## a re-run is visible out of band and the value the child actually
  ## received is checkable.
  action("env/run",
    [sh, "-c",
     "printf '%s|%s\\n' \"${" & DeclaredVar & "-}\" \"${" &
       PassthroughVar & "-}\" >> out/runs.log; " &
     "printf 'run.stamp: src/fixture.txt\\n' > out/run.d"],
    cwd = workRoot,
    inputs = ["src/fixture.txt"],
    outputs = [],
    depfile = "out/run.d",
    cacheable = true,
    weakFingerprint = weak("env/run"),
    actionCachePolicy = ffpHybrid,
    env = env,
    envPassthrough = envPassthrough,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc warmConfig(cacheRoot: string): BuildEngineConfig =
  ## Exactly the mode `repro build` runs in.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 2'u32

proc shPath(): string = findExe("sh")

suite "an action's declared environment is part of its cache key":

  test "1. a changed DECLARED value re-runs the edge":
    let sh = shPath()
    if sh.len == 0:
      skip()
    else:
      let f = makeFixture()
      defer: removeDir(f.root)
      let config = warmConfig(f.cacheRoot)

      let alpha = graph([envEdge(sh, f.workRoot,
        env = [DeclaredVar & "=alpha"])])
      let first = runBuild(alpha, config)
      check first.byId("env/run").status == asSucceeded
      check first.byId("env/run").launched
      check f.runCount() == 1
      # The child really did receive the declared value.
      check f.runLog().contains("alpha|")

      # Warm: nothing moved, so nothing re-runs.
      let warm = runBuild(alpha, config)
      check warm.byId("env/run").cacheDecision in ReuseDecisions
      check not warm.byId("env/run").launched
      check f.runCount() == 1

      # Only the DECLARED value moves. Same id, same argv, same inputs,
      # same caller-supplied fingerprint text.
      let beta = graph([envEdge(sh, f.workRoot,
        env = [DeclaredVar & "=beta"])])
      let after = runBuild(beta, config)
      let r = after.byId("env/run")
      checkpoint("after declared-env change: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check r.cacheDecision notin ReuseDecisions
      check r.launched
      check f.runCount() == 2
      check f.runLog().contains("beta|")

      # ... and the new state is itself cacheable.
      check not runBuild(beta, config).byId("env/run").launched
      check f.runCount() == 2

      # ... and going back to the old value hits the OLD record rather
      # than re-running: the two environments are two cache entries, not
      # one entry that keeps getting overwritten.
      let back = runBuild(alpha, config)
      check back.byId("env/run").cacheDecision in ReuseDecisions
      check not back.byId("env/run").launched
      check f.runCount() == 2

  test "2. a changed PASSTHROUGH value does NOT re-run the edge":
    # This is the anti-regression half. An implementation that keys on
    # the constructed environment by value passes test 1 and fails here,
    # and that implementation would invalidate every edge in every graph
    # the moment PATH differs between a dev shell and CI.
    let sh = shPath()
    if sh.len == 0:
      skip()
    else:
      let f = makeFixture()
      defer: removeDir(f.root)
      let config = warmConfig(f.cacheRoot)

      # The graph is REBUILT after every host change, and that is
      # load-bearing rather than tidiness. A fingerprint is computed
      # when the action is constructed, so a test that constructs the
      # graph once and then mutates the host environment cannot observe
      # the host value entering the key even if it does — it would pass
      # against the very implementation it exists to forbid. (Measured:
      # with a hoisted graph this case survived a mutation that renders
      # `getEnv(name)` into the passthrough slot.)
      proc freshGraph(): BuildGraph =
        graph([envEdge(sh, f.workRoot, envPassthrough = [PassthroughVar])])

      putEnv(PassthroughVar, "host-value-one")
      defer: delEnv(PassthroughVar)

      check runBuild(freshGraph(), config).byId("env/run").launched
      check f.runCount() == 1
      # The host's value really did reach the child — the variable is
      # passed through, not merely named.
      check f.runLog().contains("|host-value-one")

      check not runBuild(freshGraph(), config).byId("env/run").launched
      check f.runCount() == 1

      # Change the HOST's value. The declaration is unchanged.
      putEnv(PassthroughVar, "host-value-two-which-is-longer")
      let after = runBuild(freshGraph(), config)
      let r = after.byId("env/run")
      checkpoint("after passthrough-value change: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check r.cacheDecision in ReuseDecisions
      check not r.launched
      check f.runCount() == 1
      check not f.runLog().contains("host-value-two")

  test "3. a changed PASSTHROUGH NAME SET re-runs the edge":
    # What stops test 2 from being vacuous. "This action reads the host's
    # FOO" is part of what the action is, so acquiring or losing a
    # passthrough name is a different action.
    let sh = shPath()
    if sh.len == 0:
      skip()
    else:
      let f = makeFixture()
      defer: removeDir(f.root)
      let config = warmConfig(f.cacheRoot)

      let without = graph([envEdge(sh, f.workRoot)])
      check runBuild(without, config).byId("env/run").launched
      check f.runCount() == 1
      check not runBuild(without, config).byId("env/run").launched
      check f.runCount() == 1

      let with = graph([envEdge(sh, f.workRoot,
        envPassthrough = [PassthroughVar])])
      let after = runBuild(with, config)
      let r = after.byId("env/run")
      checkpoint("after passthrough-name-set change: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check r.cacheDecision notin ReuseDecisions
      check r.launched
      check f.runCount() == 2

suite "the environment key rendering is canonical and host-independent":

  test "4. an edge that declares no environment fingerprints unchanged":
    # The compatibility property, and the reason it is stated as a test
    # rather than assumed: if an empty environment perturbed the key,
    # landing this change would silently invalidate every action-cache
    # record in existence — a correctness fix that ships as a total cache
    # wipe. `keyedOnActionEnvironment` must be the identity on the empty
    # declaration.
    let base = weakFingerprintFromText("some-edge")
    check keyedOnActionEnvironment(base, [], []) == base
    # And the constructor must agree: an action built with no env has the
    # same fingerprint as the pre-change constructor produced, which is
    # exactly `keyedOnGoverningLock(base, identity)`.
    let identity = lockIdentityOutsideSolvedGraph()
    let a = action("id", ["/bin/true"], weakFingerprint = base,
      governingLockIdentity = identity)
    check a.weakFingerprint == keyedOnGoverningLock(base, identity)

  test "5. the rendering is order- and duplicate-canonical":
    let base = weakFingerprintFromText("some-edge")
    # Order of declared entries is not information.
    check keyedOnActionEnvironment(base, ["A=1", "B=2"], []) ==
      keyedOnActionEnvironment(base, ["B=2", "A=1"], [])
    # Order of passthrough names is not information.
    check keyedOnActionEnvironment(base, [], ["A", "B"]) ==
      keyedOnActionEnvironment(base, [], ["B", "A"])
    # Duplicate declarations resolve last-write-wins, which is what the
    # spawn-time overlay does. A key that disagreed with the spawn would
    # be keying on something the action does not experience.
    check keyedOnActionEnvironment(base, ["A=1", "A=2"], []) ==
      keyedOnActionEnvironment(base, ["A=2"], [])
    check keyedOnActionEnvironment(base, ["A=1", "A=2"], []) !=
      keyedOnActionEnvironment(base, ["A=1"], [])
    # Name and value are separately framed: no concatenation ambiguity
    # can make two distinct environments collide.
    check keyedOnActionEnvironment(base, ["AB=C"], []) !=
      keyedOnActionEnvironment(base, ["A=BC"], [])
    check keyedOnActionEnvironment(base, ["A=1", "B="], []) !=
      keyedOnActionEnvironment(base, ["A=1"], ["B"])

  test "6. a declared value is keyed; a passthrough value is not":
    let base = weakFingerprintFromText("some-edge")
    # Declared: value is information.
    check keyedOnActionEnvironment(base, ["FOO=1"], []) !=
      keyedOnActionEnvironment(base, ["FOO=2"], [])
    # Passthrough: the NAME is information, the value is not. A variable
    # listed as passthrough contributes its name whatever value happens
    # to sit beside it.
    check keyedOnActionEnvironment(base, ["FOO=1"], ["FOO"]) ==
      keyedOnActionEnvironment(base, ["FOO=2"], ["FOO"])
    check keyedOnActionEnvironment(base, [], ["FOO"]) !=
      keyedOnActionEnvironment(base, [], [])
    # ... and a passthrough variable is NOT the same action as a
    # declared one that happens to carry the host's current value.
    check keyedOnActionEnvironment(base, ["FOO=1"], ["FOO"]) !=
      keyedOnActionEnvironment(base, ["FOO=1"], [])

  test "7. the host environment cannot reach the key":
    # The structural half. PR #96's `NIX_STORE_DIR` defect was a
    # transient ambient value silently and permanently entering a record
    # because a key computation called `getEnv`. The same shape here
    # would be `PATH`: an action's PATH is built by prepending resolved
    # tool directories to the host's, so a key that read it would differ
    # between a `nix develop` shell and CI for every edge in the graph.
    let base = weakFingerprintFromText("some-edge")
    let declaration = ["PATH=/tool/bin"]
    let passthrough = ["PATH", PassthroughVar]

    putEnv("PATH", "/host/a:/host/b")
    putEnv(PassthroughVar, "one")
    let underHostA = keyedOnActionEnvironment(base, declaration, passthrough)

    putEnv("PATH", "/completely/different:/host/c:/host/d")
    putEnv(PassthroughVar, "two-and-longer")
    let underHostB = keyedOnActionEnvironment(base, declaration, passthrough)
    delEnv(PassthroughVar)

    check underHostA == underHostB

  test "8. the key computation's CODE never reads the environment":
    # Belt and braces for test 7, which can only ever sample two host
    # environments. `keyedOnActionEnvironment` and the rendering it
    # delegates to are pure functions of their arguments, and the check
    # that keeps them pure is that neither body contains a call that can
    # reach the ambient environment at all.
    #
    # Comment lines are stripped before the scan on purpose: the doc
    # comments on those procedures DISCUSS the banned calls (that is
    # where the rationale lives), and a scan that could not tell an
    # explanation from a call would force the rationale out of the
    # source to stay green.
    proc codeOf(text, name: string): string =
      let start = text.find("\nproc " & name)
      check start >= 0
      let stop = text.find("\nproc ", start + 1)
      check stop > start
      for line in text[start ..< stop].splitLines():
        if line.strip().startsWith("#"):
          continue
        result.add(line & "\n")

    let source = currentSourcePath().parentDir.parentDir /
      "src" / "repro_build_engine.nim"
    check fileExists(source)
    let text = readFile(source)
    let body = codeOf(text, "actionEnvironmentKeyText") &
      codeOf(text, "keyedOnActionEnvironment")
    checkpoint("scanned " & $body.splitLines().len & " code lines")
    # The scan must actually have found code, not an empty slice.
    check body.contains("passthrough")
    for banned in ["getEnv", "existsEnv", "envPairs", "getAllEnv",
                   "putEnv", "delEnv"]:
      checkpoint("banned call: " & banned)
      check not body.contains(banned)

  test "9. the rendering distinguishes the two classes explicitly":
    # A cache key that cannot be explained cannot be debugged. The
    # canonical text is what an operator diffs when two hosts disagree,
    # so it must keep the two classes apart rather than flattening them
    # into one list of strings.
    #
    # This is also where this rendering deliberately diverges from
    # BuildXL. BuildXL writes the literal `"Pass-through"` into the
    # VALUE slot with no separate class field
    # (`PipFingerprinter.cs:360-375`), so a declared variable whose
    # value renders to exactly that string collides with a passthrough
    # variable of the same name. Here the class is its own framed field.
    type Record = tuple[name, class, value: string]
    proc parse(text: string): seq[Record] =
      for record in text.split("\x1e"):
        if record.len == 0:
          continue
        let f = record.split("\x1f")
        check f.len == 5
        # Length framing is present and honest — that is what makes the
        # rendering injective.
        check f[0] == $f[1].len
        check f[3] == $f[4].len
        result.add((name: f[1], class: f[2], value: f[4]))

    let records = parse(actionEnvironmentKeyText(
      ["B=2", "A=1", "A=3"], ["Z", "A"]))
    check records.len == 3
    check records.mapIt(it.name) == @["A", "B", "Z"]
    # Sorted by name, so a diff between two hosts is a diff of the
    # environment and not of an iteration order.
    check records.mapIt(it.name) == records.mapIt(it.name).sorted()
    # `A` is passthrough, so NEITHER of its declared values survives.
    check records[0].class == "passthrough"
    check records[0].value == ""
    # `B` is declared, so its value is present verbatim.
    check records[1] == (name: "B", class: "declared", value: "2")
    # `Z` is passthrough with no declared value at all.
    check records[2].class == "passthrough"
    # Deterministic: same declaration, same text, every time, whatever
    # order the caller happened to assemble it in.
    check actionEnvironmentKeyText(["B=2", "A=1", "A=3"], ["Z", "A"]) ==
      actionEnvironmentKeyText(["A=3", "B=2", "A=1"], ["A", "Z"])
    # Malformed entries carry no environment and must not become key
    # material by accident.
    check actionEnvironmentKeyText(["no-equals-sign", "=novalue"], []) == ""
