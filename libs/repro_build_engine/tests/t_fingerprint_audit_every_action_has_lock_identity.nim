## NLF-ID-6 — every action fingerprint carries a governing lock identity.
##
## Named-Lock-Files NLF-M4. Corpus case **NLF-ID-6**
## (`Named-Lock-Files-Test-Corpus.md` §3), verifying design §7.2.
##
## ## What is under test, and why it has to be whole-graph
##
## §7 keys action identity on the governing lock file (design A). §7.1 records
## that design A has one real weakness against path-partitioning (design B):
## "B cannot be applied incompletely. An edge whose outputs are correctly
## rooted is correctly separated. Under A, a single edge whose fingerprint
## forgets the governing lock identity is a **silent** poisoning vector — it
## serves one lock file's artifacts to another and reports success."
##
## The corpus says the same thing about why no other case can catch it: "no
## other case in this corpus detects it, because every other case exercises
## specific edge kinds and this failure is about the one nobody thought to
## exercise. Assert over the **whole graph**, so a newly added edge kind
## cannot quietly opt out."
##
## So the assertions here are deliberately not "action X has an identity".
## They are:
##
##   1. the audit passes on a graph covering EVERY `BuildActionKind`;
##   2. the corpus itself is complete, so (1) cannot silently narrow;
##   3. the mutation — an edge kind whose construction path drops the field —
##      makes the audit FAIL, and the diagnostic NAMES that kind;
##   4. the audit is wired into graph construction, so it is a gate and not a
##      report nobody runs: a graph with a missing identity is refused by
##      `runBuild` before any action executes.
##
## (4) is what makes this a release gate rather than a debug aid, which §7.2
## requires in terms: "The audit is a **release gate**, not a debug aid."
##
## ## The mutation, and why it is expressed in-test as well as in source
##
## The ledger requires NLF-ID-6 be mutation-verified explicitly. The mutation
## the corpus specifies is "remove the field from one edge kind's construction
## path". A source-level mutation of `builtinAction` was run by hand during
## implementation and is recorded in the milestone's evidence; it cannot live
## in the committed suite, because `{.requiresInit.}` on the field makes
## "remove it from a construction path" a COMPILE error — which is the point
## of the compile-time half and also means the committed test cannot express
## it as source.
##
## What the committed test can express, and does, is the surviving hole: a
## construction path that supplies an EMPTY or malformed identity rather than
## omitting the field. The type system cannot see that; the audit must. So the
## mutation below stamps one edge kind's actions with an unusable identity and
## requires the audit to fail naming exactly that kind and no other.
##
## Test-double policy: NO mocks, doubles, or fakes. The graph is built from
## the engine's real constructors, the audit under test is the engine's own
## `auditGoverningLockIdentity`, and the gate assertion runs the real
## `runBuild`.
##
## The corpus read here is `everyEdgeKindActions()` — the NLF-STAT-4 baseline
## graph PLUS the edge kinds introduced after that baseline was recorded
## (NLF-M5's `bakMetadataFetch` / `bakSolveLock`). §7.2's audit is a
## whole-graph property and must cover every kind; the NLF-STAT-4 fixture is a
## frozen recording of the pre-campaign default path and must not grow rows.
## Those are two different obligations over two different graphs, which is why
## `nlf_stat4_baseline_corpus` now exposes both lists.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine

import ./nlf_stat4_baseline_corpus

proc mutateOneEdgeKind(actions: seq[BuildAction];
                       kind: BuildActionKind): seq[BuildAction] =
  ## Model "one edge kind's construction path stopped supplying a usable
  ## governing lock identity" by clearing it on every action of that kind.
  ## Every OTHER kind keeps its identity, so a diagnostic that named more
  ## than the mutated kind would be over-reporting and is caught too.
  result = @[]
  for a in actions:
    var copied = a
    if copied.kind == kind:
      copied.governingLockIdentity = LockIdentity("")
    result.add(copied)

suite "NLF-ID-6 whole-graph governing-lock-identity audit":

  test "the audit corpus covers every edge kind":
    # Guard on the guard. If a kind is added to `BuildActionKind` and the
    # corpus is not extended, the audit below would pass over a graph that
    # never exercised it — the precise "edge kind nobody thought to
    # exercise" the case exists to prevent.
    check assertEveryEdgeKindCovered() == ""

  test "every action in a fully constructed graph carries an identity":
    let actions = everyEdgeKindActions()
    check actions.len > 0
    let findings = auditGoverningLockIdentity(graph(actions))
    if findings.len > 0:
      checkpoint(formatLockIdentityAudit(findings))
    check findings.len == 0

  test "clearing the field on ONE edge kind fails the audit naming that kind":
    # The mutation, run against every kind in turn rather than one chosen
    # kind. A per-kind loop is what makes this a whole-graph assertion: an
    # audit that happened to notice `bakProcess` and skip the built-ins would
    # pass a single-kind mutation test and fail this one.
    let clean = everyEdgeKindActions()
    for kind in BuildActionKind:
      let mutated = mutateOneEdgeKind(clean, kind)
      let findings = auditGoverningLockIdentity(graph(mutated))

      # It fails …
      check findings.len == 1
      if findings.len != 1:
        checkpoint("kind " & $kind & ": expected exactly one finding, got " &
          $findings.len)
        continue

      # … naming that kind …
      check findings[0].kind == kind
      check findings[0].actionIds.len > 0

      # … and the rendered diagnostic says the kind out loud, because a
      # finding object nobody reads is not a diagnostic.
      let rendered = formatLockIdentityAudit(findings)
      check rendered.contains($kind)
      check rendered.contains("governing lock identity missing")
      for id in findings[0].actionIds:
        check rendered.contains(id)

      # … and only that kind. Over-reporting would make the diagnostic
      # useless for locating the construction path at fault.
      for other in BuildActionKind:
        if other != kind:
          check not rendered.contains("edge kind " & $other & ":")

  test "a whitespace identity is rejected, not merely a missing one":
    # §7.2 asks for "a real check from a lint". A length check would accept
    # `" "` and a truncated hex fragment, both of which are just as unusable
    # as a key as an empty string.
    for bogus in ["", " ", "blake3:", "not-a-multihash", "blake3:zzzz"]:
      var actions = everyEdgeKindActions()
      actions[0].governingLockIdentity = LockIdentity(bogus)
      let findings = auditGoverningLockIdentity(graph(actions))
      check findings.len == 1
      if findings.len == 1:
        check findings[0].actionIds == @[actions[0].id]

  test "the audit gates graph construction — runBuild refuses the graph":
    # §7.2: "The audit is a release gate, not a debug aid." A gate that only
    # reports is the convention §7.2 refuses to rely on, so this asserts the
    # engine REFUSES to run a graph that fails the audit, before any action
    # executes.
    let tempRoot = createTempDir("repro-nlf-id6-gate", "")
    defer: removeDir(tempRoot)
    let cacheRoot = tempRoot / "cache"
    createDir(cacheRoot)
    let outPath = absolutePath(tempRoot / "out.txt")

    var offending = builtinAction(bakWriteText, "nlf-id6-gate",
      outputs = [outPath], text = "written\n",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    offending.governingLockIdentity = LockIdentity("")

    var cfg = defaultBuildEngineConfig(cacheRoot)
    cfg.maxParallelism = 1
    cfg.bypassRunQuota = true
    cfg.deferLocalOutputBlobs = false

    var raised = false
    var diagnostic = ""
    try:
      discard runBuild(graph(@[offending]), cfg)
    except BuildEngineError as err:
      raised = true
      diagnostic = err.msg

    check raised
    check diagnostic.contains("governing lock identity missing")
    check diagnostic.contains("bakWriteText")
    check diagnostic.contains("nlf-id6-gate")
    # The refusal happens BEFORE execution: the action's output must not
    # exist. A gate that ran the graph and then complained would have
    # already served the wrong artifact.
    check not fileExists(outPath)

  test "the same graph with a real identity passes the gate and runs":
    # The control. Without it, the previous case passes against an engine
    # that refuses every graph.
    let tempRoot = createTempDir("repro-nlf-id6-control", "")
    defer: removeDir(tempRoot)
    let cacheRoot = tempRoot / "cache"
    createDir(cacheRoot)
    let outPath = absolutePath(tempRoot / "out.txt")

    let good = builtinAction(bakWriteText, "nlf-id6-control",
      outputs = [outPath], text = "written\n",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check good.governingLockIdentity.isValid()

    var cfg = defaultBuildEngineConfig(cacheRoot)
    cfg.maxParallelism = 1
    cfg.bypassRunQuota = true
    cfg.deferLocalOutputBlobs = false

    discard runBuild(graph(@[good]), cfg)
    check fileExists(outPath)
    check readFile(outPath) == "written\n"
