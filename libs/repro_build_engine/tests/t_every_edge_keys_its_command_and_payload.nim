## Every edge's weak fingerprint covers its command line or its payload,
## whatever fingerprint its caller passed.
##
## reprobuild-pm `spec/Caching-Architecture.md` §"BuildXL-Inspired
## Fingerprinting", rider of 2026-11-16 (derived from `Core-Invariants.md`
## §"One Implementation Per Concern"): the ENGINE mixes into every edge's weak
## fingerprint the argv, cwd and tool of a process edge (`keyedOnArgv`) and
## the kind and payload of a builtin. A caller-supplied fingerprint is mixed in
## addition and never replaces those. The payload mix covers the filesystem
## builtins (`PayloadKeyedBuiltinKinds`); the executor-backed kinds await an
## owner decision, and the case below pins what they do meanwhile.
##
## The defect this protects against (reprobuild-pm issue
## `issues/2026-11-16-action-default-weak-fingerprint-is-the-id-alone.md`):
## `action()` and `builtinAction` defaulted the caller fingerprint to
## `weakFingerprintFromText(id)` and mixed in neither the rest of argv, nor the
## cwd, nor a builtin's payload. A direct caller that did not mix them in
## itself — a builtin, an engine-defined edge, a node built through the
## library — got one local record for every command line under one id, so a
## flag change was served the earlier flag's result without launching. With
## portable caching off a process edge's PEER key is that same local weak
## fingerprint (`computePeerCacheQuery`: `peerKey: action.weakFingerprint`),
## so the stale record could also be served to another host: the fingerprint
## cases below are the peer-key cases too.
##
## Falsifier: drop the `keyedOnArgv` mix from `action()`'s `weakFingerprint`,
## or the `keyedOnBuiltinPayload` mix from `builtinAction`'s, and the
## "differs" and "re-runs" cases go red (the run cases with `launched=false`,
## served from the first edge's record).
##
## MOCK POLICY — none. The run cases drive the real `runBuild` scheduler, the
## real per-edge action cache and CAS, a real `sh` subprocess and real files
## in a temporary directory; the fingerprint cases read the real
## `weakFingerprint` the action cache is looked up by.

import std/[options, os, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

import repro_build_engine
import repro_hash
import repro_local_store
from repro_test_support import removeDirEventually

const ReuseDecisions = {cdHit, cdHybridCutoff}

proc lock(): LockIdentity = lockIdentityOutsideSolvedGraph()

proc proc1(argv: openArray[string]; cwd = "/work";
           weak = none(ContentDigest)): BuildAction =
  ## A direct `action()` caller. With `weak` unset it passes no fingerprint
  ## at all, which is the engine default under test.
  if weak.isSome:
    action("direct/compile", argv, cwd = cwd, outputs = ["a.o"],
      cacheable = true, weakFingerprint = weak.get,
      governingLockIdentity = lock())
  else:
    action("direct/compile", argv, cwd = cwd, outputs = ["a.o"],
      cacheable = true, governingLockIdentity = lock())

proc text1(kind: BuildActionKind; text: string;
           entries: openArray[string] = []): BuildAction =
  builtinAction(kind, "direct/write", cwd = "/work", outputs = ["out.txt"],
    text = text, entries = entries, governingLockIdentity = lock())

suite "a process edge's weak fingerprint covers its command line":

  test "the same command keys the same":
    check proc1(["/usr/bin/cc", "-O0", "-c", "a.c"]).weakFingerprint ==
      proc1(["/usr/bin/cc", "-O0", "-c", "a.c"]).weakFingerprint

  test "a changed flag is another key under the default fingerprint":
    check proc1(["/usr/bin/cc", "-O0", "-c", "a.c"]).weakFingerprint !=
      proc1(["/usr/bin/cc", "-O2", "-c", "a.c"]).weakFingerprint

  test "an added argument is another key":
    check proc1(["/usr/bin/cc", "-c", "a.c"]).weakFingerprint !=
      proc1(["/usr/bin/cc", "-c", "a.c", "-DX"]).weakFingerprint

  test "another tool outside any store is another key":
    check proc1(["/usr/bin/cc", "-c", "a.c"]).weakFingerprint !=
      proc1(["/usr/bin/clang", "-c", "a.c"]).weakFingerprint

  test "another cwd is another key":
    check proc1(["/usr/bin/cc", "-c", "a.c"], cwd = "/work/a").weakFingerprint !=
      proc1(["/usr/bin/cc", "-c", "a.c"], cwd = "/work/b").weakFingerprint

  test "argv is framed, not concatenated":
    check proc1(["/bin/sh", "-c", "a b"]).weakFingerprint !=
      proc1(["/bin/sh", "-c", "a", "b"]).weakFingerprint

  test "a caller fingerprint adds to the argv key and cannot replace it":
    let weak = some(weakFingerprintFromText("caller computed this"))
    check proc1(["/usr/bin/cc", "-O0", "-c", "a.c"], weak = weak).weakFingerprint !=
      proc1(["/usr/bin/cc", "-O2", "-c", "a.c"], weak = weak).weakFingerprint
    # ...and it still adds: another caller fingerprint is another key.
    check proc1(["/usr/bin/cc", "-c", "a.c"], weak = weak).weakFingerprint !=
      proc1(["/usr/bin/cc", "-c", "a.c"],
        weak = some(weakFingerprintFromText("other"))).weakFingerprint

suite "a relocatable edge keys its command line relocation-safely":

  proc reloc(root, flag: string): BuildAction =
    action("direct/reloc", ["/opt/anchor/tool", flag, root / "src" / "a.c"],
      cwd = root, outputs = ["a.o"], cacheable = true,
      relocatable = true, relocationAnchors = ["/opt/anchor"],
      governingLockIdentity = lock())

  test "a byte-identical tree elsewhere at the same depth keys the same":
    check reloc("/work/alpha", "-O0").weakFingerprint ==
      reloc("/work/beta", "-O0").weakFingerprint

  test "a changed flag is still another key":
    check reloc("/work/alpha", "-O0").weakFingerprint !=
      reloc("/work/alpha", "-O2").weakFingerprint

  test "an argv path relative to the tree is keyed by that relative name":
    # `src/a.c` under the cwd, wherever the tree is: another file in the
    # tree is another key.
    let other = action("direct/reloc",
      ["/opt/anchor/tool", "-O0", "/work/alpha/src/b.c"], cwd = "/work/alpha",
      outputs = ["a.o"], cacheable = true, relocatable = true,
      relocationAnchors = ["/opt/anchor"], governingLockIdentity = lock())
    check reloc("/work/alpha", "-O0").weakFingerprint != other.weakFingerprint

suite "a builtin's weak fingerprint covers its kind and payload":

  test "the same payload keys the same":
    check text1(bakWriteText, "v1\n").weakFingerprint ==
      text1(bakWriteText, "v1\n").weakFingerprint

  test "another text is another key under the default fingerprint":
    check text1(bakWriteText, "v1\n").weakFingerprint !=
      text1(bakWriteText, "v2\n").weakFingerprint

  test "other entries are another key":
    check text1(bakEnsureSnippet, "x", ["a", "b"]).weakFingerprint !=
      text1(bakEnsureSnippet, "x", ["a", "c"]).weakFingerprint
    check text1(bakEnsureSnippet, "x", ["a b"]).weakFingerprint !=
      text1(bakEnsureSnippet, "x", ["a", "b"]).weakFingerprint

  test "another kind with the same payload is another key":
    check text1(bakWriteText, "v1\n").weakFingerprint !=
      text1(bakStamp, "v1\n").weakFingerprint

  test "a caller fingerprint adds to the payload key and cannot replace it":
    let weak = weakFingerprintFromText("caller computed this")
    proc withWeak(text: string): BuildAction =
      builtinAction(bakWriteText, "direct/write", cwd = "/work",
        outputs = ["out.txt"], text = text, weakFingerprint = weak,
        governingLockIdentity = lock())
    check withWeak("v1\n").weakFingerprint != withWeak("v2\n").weakFingerprint

suite "an executor-backed builtin keeps its constructor's key":

  test "its payload is not mixed in, pending the owner decision":
    # Documented behaviour, not the rule's end state: `PayloadKeyedBuiltinKinds`
    # leaves these kinds to their constructors, whose payloads carry fields
    # their designs keep out of the key (a git clone's reference path and
    # depth). A change here is the owner decision landing, and this case is
    # where to say so.
    let weak = weakFingerprintFromText("constructor key")
    proc vcs(text: string): BuildAction =
      builtinAction(bakWorkspaceVcs, "direct/vcs", text = text,
        weakFingerprint = weak, governingLockIdentity = lock())
    check vcs("depth=0").weakFingerprint == vcs("depth=1").weakFingerprint
    check bakWorkspaceVcs notin PayloadKeyedBuiltinKinds
    check bakWriteText in PayloadKeyedBuiltinKinds

proc runConfig(cacheRoot: string): BuildEngineConfig =
  ## The mode `repro build` runs in.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc describe(item: ActionResult): string =
  "status=" & $item.status & " cache=" & $item.cacheDecision &
    " launched=" & $item.launched & " reason=" & item.reason

proc flagEdge(sh, work, flag: string): BuildAction =
  ## A direct caller with no fingerprint of its own: same id, and an argv
  ## that differs only in `flag`, which the child writes to its output.
  action("direct/flag",
    [sh, "-c", "printf '%s\\n' \"$1\" > out.txt; " &
      "printf 'out.txt:\\n' > out.d", "probe", flag],
    cwd = work, outputs = ["out.txt"], depfile = "out.d",
    cacheable = true, actionCachePolicy = ffpHybrid,
    governingLockIdentity = lock())

suite "one local action cache, two edges that differ only in what they do":

  test "a process edge whose flag changed re-runs":
    let sh = findExe("sh")
    if sh.len == 0:
      skip("sh not on PATH; the edge under test runs a shell command")
    else:
      let root = createTempDir("repro-argv-key-", "")
      defer: removeDirEventually(root)
      let work = root / "work"
      createDir(work)
      let config = runConfig(root / "cache")
      let first = runBuild(graph([flagEdge(sh, work, "-O0")]), config)
      require first.byId("direct/flag").status == asSucceeded
      require first.byId("direct/flag").launched
      # Control: unchanged, so served.
      let warm = runBuild(graph([flagEdge(sh, work, "-O0")]), config)
      checkpoint("warm: " & warm.byId("direct/flag").describe)
      require warm.byId("direct/flag").cacheDecision in ReuseDecisions
      let second = runBuild(graph([flagEdge(sh, work, "-O2")]), config)
      let item = second.byId("direct/flag")
      checkpoint("flag changed: " & item.describe)
      check item.launched
      check item.cacheDecision notin ReuseDecisions
      check readFile(work / "out.txt").strip() == "-O2"

  test "a write-text builtin whose text changed re-runs":
    let root = createTempDir("repro-payload-key-", "")
    defer: removeDirEventually(root)
    let work = root / "work"
    createDir(work)
    let config = runConfig(root / "cache")
    proc edge(text: string): BuildAction =
      builtinAction(bakWriteText, "direct/write", cwd = work,
        outputs = ["out.txt"], text = text, cacheable = true,
        actionCachePolicy = ffpChecksum, governingLockIdentity = lock())
    let first = runBuild(graph([edge("first\n")]), config)
    require first.byId("direct/write").status == asSucceeded
    let warm = runBuild(graph([edge("first\n")]), config)
    checkpoint("warm: " & warm.byId("direct/write").describe)
    require warm.byId("direct/write").cacheDecision in ReuseDecisions
    let second = runBuild(graph([edge("second\n")]), config)
    let item = second.byId("direct/write")
    checkpoint("text changed: " & item.describe)
    check item.cacheDecision notin ReuseDecisions
    check readFile(work / "out.txt") == "second\n"
