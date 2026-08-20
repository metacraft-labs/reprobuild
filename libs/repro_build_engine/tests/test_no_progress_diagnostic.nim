## M2a — the "build graph made no progress" raise path must NAME the
## terminal failures (failed action ids + their reason/stderr and the
## cascaded blocked descendants), not collapse to an EMPTY pending list.
##
## Background: when an action fails and ``blockClosure`` cascades its
## dependents to ``asBlocked``, a code path that advances ``completed``
## by only counting the failed action (``inc completed`` instead of
## ``completed = terminalCount()``) leaves the scheduler with nothing
## pending / ready / running yet ``completed < total`` — so the engine
## reaches the "no progress" raise with EVERY survivor already
## ``asFailed``/``asBlocked`` and an EMPTY ``asPending`` set. The old
## diagnostic printed only that empty pending list, hiding the real
## cause (this is exactly what ``repro shell`` hit on io-mon's dev-env
## provisioning). See the sibling regression at
## ``test_elevated_inline_exec_hook.nim`` line ~249.
##
## This test drives a deterministic instance of that stall — a failing
## built-in action with a dependent — and pins that the raised
## ``BuildEngineError`` now names the failing action id AND carries its
## reason, and lists the blocked dependent, rather than an empty
## "pending actions:" tail.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

const TmpDir = "build/test-tmp/test_no_progress_diagnostic"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc fingerprintFor(text: string): ContentDigest =
  casDigest(text.toOpenArrayByte(0, text.high),
            domain = hdActionFingerprint)

suite "M2a — no-progress diagnostic surfaces terminal failures":

  test "a failing action's reason is surfaced instead of an empty pending list":
    resetTmp()
    let cacheRoot = TmpDir / "cache"
    createDir(cacheRoot)
    # A ``bakCopyFile`` built-in with ZERO inputs deterministically
    # fails inside ``executeBuiltinAction`` ("copyFile action requires
    # exactly one input and one output"), which sets the result to
    # ``asFailed`` with that message on ``stderr``. It declares one
    # output so it is a valid producer node; the output path is never
    # created, so nothing short-circuits it as up-to-date.
    let badOut = absolutePath(TmpDir / "outputs" / "bad.out")
    let depOut = absolutePath(TmpDir / "outputs" / "dep.out")
    let failing = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakCopyFile,
      id: "provision-tool",
      inputs: @[],                 # <- wrong arity => raises => asFailed
      outputs: @[badOut],
      cacheable: false,
      actionCachePolicy: ffpTimestamp,
      weakFingerprint: fingerprintFor("provision-tool|m2a"))
    # A dependent that can only run after the failing action — it gets
    # cascaded to ``asBlocked`` and must be named as such.
    let dependent = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText,
      id: "activate-dev-env",
      outputs: @[depOut],
      builtinText: "activated\n",
      deps: @["provision-tool"],
      cacheable: false,
      actionCachePolicy: ffpTimestamp,
      weakFingerprint: fingerprintFor("activate-dev-env|m2a"))

    let g = graph(@[failing, dependent], newSeq[BuildPool]())
    var cfg = defaultBuildEngineConfig(cacheRoot)
    cfg.maxParallelism = 1
    cfg.bypassRunQuota = true
    cfg.deferLocalOutputBlobs = false

    var raised = false
    var diagnostic = ""
    try:
      discard runBuild(g, cfg)
    except BuildEngineError as err:
      raised = true
      diagnostic = err.msg

    check raised
    # Historical prefix preserved (existing consumers still match).
    check diagnostic.contains("build graph made no progress")
    # The failing action is NAMED and its reason is surfaced — NOT an
    # empty pending list.
    check diagnostic.contains("provision-tool")
    check diagnostic.contains("copyFile action requires exactly one input")
    check diagnostic.contains("failed actions:")
    # The cascaded dependent is reported as blocked by the failure.
    check diagnostic.contains("activate-dev-env")
    check diagnostic.contains("blocked actions:")
    # The regression we are fixing: the OLD diagnostic was exactly
    # "build graph made no progress; pending actions: " with an empty
    # tail (all survivors were failed/blocked, none pending). The new
    # message must NOT collapse to that — the failed/blocked segments
    # lead, so it no longer starts straight into an empty pending list.
    check not diagnostic.startsWith("build graph made no progress; pending actions:")
    # And the failure detail must precede the (empty) pending segment.
    let pendingAt = diagnostic.find("pending actions:")
    check pendingAt > 0
    check diagnostic[0 ..< pendingAt].contains("provision-tool")
