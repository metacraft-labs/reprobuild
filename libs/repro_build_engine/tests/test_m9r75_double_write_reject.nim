## M9.R.75 — R7 (double-write reject) engine graph-time detection.
##
## Verifies that two CONCURRENT actions whose ``declaredOutputs``
## overlap (equality or directory-prefix containment) are rejected by
## the engine's ``validateGraph`` pass before execution.
##
## Spec cite: reprobuild-specs Filesystem-Policy-And-Observed-Inputs.md
## §"Double Writes" (lines 246-262): "double writes are errors" is the
## shipping default.
##
## The pre-M9.R.75 engine had a strict string-equality check on
## ``BuildAction.outputs`` (the stamp / artefact set); convention
## authors typically declare a unique per-action stamp file there so
## the check never fired for two actions writing into the same DESTDIR.
## M9.R.75 adds ``declaredOutputs`` (the write ROOT declaration) and a
## dependency-aware pairwise intersection pass in ``validateGraph``
## that catches:
##   * equal roots on two concurrent actions;
##   * proper directory-prefix containment on two concurrent actions;
##   * both directions (the pairwise pass is symmetric).
##
## Dependency-aware relaxation: when B transitively depends on A, they
## are SEQUENTIAL — B's writes happen strictly after A's, so a shared
## write scope is legitimate sequencing (configure → compile → install
## all writing under the same buildDir is the canonical pattern). The
## check therefore only fires when neither action reaches the other
## via ``deps``.
##
## Non-overlapping siblings (``$b/build`` vs ``$b/install``) MUST NOT
## trip the check. Actions that leave ``declaredOutputs`` empty MUST
## roll forward with pre-M9.R.75 behaviour (no false-positive on
## legacy graphs).

import std/[os, strutils, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

const TmpDir = "build/test-tmp/test_m9r75_double_write_reject"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc stubDigest(text: string): ContentDigest =
  casDigest(text.toOpenArrayByte(0, text.high),
            domain = hdActionFingerprint)

proc twoActionsWithRoots(idA, rootA, idB, rootB: string;
                         chain = false): BuildGraph =
  ## Constructs a two-action graph whose stamp outputs differ (so the
  ## legacy string-equality check on ``outputs`` never fires) but whose
  ## ``declaredOutputs`` are as supplied by the caller so the R7
  ## pairwise-intersection pass can be graded.
  ##
  ## When ``chain = true``, action B declares ``deps = [idA]`` so the
  ## pairwise pass sees B → A as sequential and skips the check — the
  ## canonical configure → compile → install pattern.
  let stampA = absolutePath(TmpDir / (idA & ".stamp"))
  let stampB = absolutePath(TmpDir / (idB & ".stamp"))
  let actionA = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: idA,
    outputs: @[stampA],
    cacheable: false,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: stubDigest(idA),
    builtinText: "a\n",
    declaredOutputs: @[rootA])
  let actionB = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: idB,
    deps: if chain: @[idA] else: @[],
    outputs: @[stampB],
    cacheable: false,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: stubDigest(idB),
    builtinText: "b\n",
    declaredOutputs: @[rootB])
  graph(@[actionA, actionB], newSeq[BuildPool]())

proc engineErr(cb: proc()): string =
  try:
    cb()
    ""
  except BuildEngineError as e:
    e.msg
  except CatchableError as e:
    "unexpected: " & e.msg

suite "M9.R.75 — R7 double-write reject at graph-validation time":

  test "identical declared write roots on two actions → error":
    resetTmp()
    let g = twoActionsWithRoots(
      "action-a", TmpDir / "shared" / "build",
      "action-b", TmpDir / "shared" / "build")
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check msg.len > 0
    check msg.contains("double-write reject (R7): concurrent")
    check msg.contains("action-a")
    check msg.contains("action-b")

  test "one action's declared write root contains the other's → error":
    resetTmp()
    let outer = TmpDir / "outer" / "build"
    let inner = outer / "subdir"
    let g = twoActionsWithRoots(
      "outer-configure", outer,
      "inner-configure", inner)
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check msg.len > 0
    check msg.contains("double-write reject (R7): concurrent")
    check msg.contains("outer-configure")
    check msg.contains("inner-configure")

  test "sibling directories (no containment) do NOT trip the check":
    resetTmp()
    let g = twoActionsWithRoots(
      "sib-a", TmpDir / "shared" / "build",
      "sib-b", TmpDir / "shared" / "install")
    # The graph is valid at the R7 layer; execution may still fail for
    # unrelated reasons (missing cache dirs etc.) but the R7 error must
    # not surface.
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check not msg.contains("double-write reject (R7): concurrent")

  test "prefix look-alike is NOT treated as containment":
    ## Regression: ``"$b/build"`` must NOT be treated as a prefix of
    ## ``"$b/buildkit"``. The intersection predicate uses a ``/``
    ## boundary so directory names that share a text prefix but are
    ## disjoint siblings survive the check.
    resetTmp()
    let g = twoActionsWithRoots(
      "look-a", TmpDir / "shared" / "build",
      "look-b", TmpDir / "shared" / "buildkit")
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check not msg.contains("double-write reject (R7): concurrent")

  test "empty declaredOutputs on both actions preserves legacy behaviour":
    ## Legacy actions that don't opt in to declaredOutputs must round
    ## forward as no-op — the R7 pass must NOT fire on either action's
    ## empty seq.
    resetTmp()
    let stampA = absolutePath(TmpDir / "legacy-a.stamp")
    let stampB = absolutePath(TmpDir / "legacy-b.stamp")
    let actionA = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText,
      id: "legacy-a",
      outputs: @[stampA],
      cacheable: false,
      actionCachePolicy: ffpTimestamp,
      weakFingerprint: stubDigest("legacy-a"),
      builtinText: "a\n")
    let actionB = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText,
      id: "legacy-b",
      outputs: @[stampB],
      cacheable: false,
      actionCachePolicy: ffpTimestamp,
      weakFingerprint: stubDigest("legacy-b"),
      builtinText: "b\n")
    let g = graph(@[actionA, actionB], newSeq[BuildPool]())
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check not msg.contains("double-write reject (R7): concurrent")

  test "self-overlap on the same action does NOT trip the check":
    ## The pairwise pass must skip pairs where both entries belong to
    ## the SAME action id. Otherwise an action that declares nested
    ## write roots (unusual but legal) would false-fail against itself.
    resetTmp()
    let stamp = absolutePath(TmpDir / "self.stamp")
    let action = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText,
      id: "self",
      outputs: @[stamp],
      cacheable: false,
      actionCachePolicy: ffpTimestamp,
      weakFingerprint: stubDigest("self"),
      builtinText: "s\n",
      declaredOutputs: @[
        TmpDir / "shared" / "build",
        TmpDir / "shared" / "build" / "sub"])
    let g = graph(@[action], newSeq[BuildPool]())
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check not msg.contains("double-write reject (R7): concurrent")

  test "trailing slash normalisation — equal roots differ only in trailing '/'":
    resetTmp()
    let root = TmpDir / "shared" / "build"
    let g = twoActionsWithRoots(
      "slash-a", root,
      "slash-b", root & "/")
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check msg.len > 0
    check msg.contains("double-write reject (R7): concurrent")

  test "sequential actions (dep chain) sharing a write root are allowed":
    ## The canonical configure → compile → install pattern: three
    ## actions declare the same buildDir as their write root, but each
    ## depends on the previous. The pairwise pass MUST treat these as
    ## sequential (not double-write) and let the graph through. This
    ## is what makes the R7 check usable by DSL constructors that
    ## naturally declare a shared buildDir.
    resetTmp()
    let buildDir = TmpDir / "shared" / "build"
    let g = twoActionsWithRoots(
      "configure", buildDir,
      "compile", buildDir,
      chain = true)
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check not msg.contains("double-write reject (R7): concurrent")

  test "transitive dep chain relaxes the R7 check":
    ## configure → compile → install: install and configure share the
    ## same install-mirror path but there is a transitive dep chain
    ## (install → compile → configure). The pairwise pass MUST walk
    ## the deps graph and treat all three as sequential.
    resetTmp()
    let scope = TmpDir / "shared" / "root"
    let stampCfg = absolutePath(TmpDir / "cfg.stamp")
    let stampCmp = absolutePath(TmpDir / "cmp.stamp")
    let stampIns = absolutePath(TmpDir / "ins.stamp")
    let cfg = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText, id: "cfg", outputs: @[stampCfg],
      cacheable: false, actionCachePolicy: ffpTimestamp,
      weakFingerprint: stubDigest("cfg"), builtinText: "c\n",
      declaredOutputs: @[scope])
    let cmp = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText, id: "cmp", deps: @["cfg"], outputs: @[stampCmp],
      cacheable: false, actionCachePolicy: ffpTimestamp,
      weakFingerprint: stubDigest("cmp"), builtinText: "m\n",
      declaredOutputs: @[scope])
    let ins = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText, id: "ins", deps: @["cmp"], outputs: @[stampIns],
      cacheable: false, actionCachePolicy: ffpTimestamp,
      weakFingerprint: stubDigest("ins"), builtinText: "i\n",
      declaredOutputs: @[scope])
    let g = graph(@[cfg, cmp, ins], newSeq[BuildPool]())
    let msg = engineErr(proc() =
      discard runBuild(g, defaultBuildEngineConfig(TmpDir / "cache")))
    check not msg.contains("double-write reject (R7): concurrent")
