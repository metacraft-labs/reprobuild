## The binary an action EXECUTES is an input of that action, and must be in
## its cache key.
##
## "IN ITS CACHE KEY" IS THE PROPERTY; "A RECORDED INPUT" IS ONLY ONE OF THE
## TWO WAYS TO GET THERE, and the file's original title named the way rather
## than the property. That mattered: it is exactly the confusion that let the
## suite pass for six days while the property it names was FALSE for every
## tool on a NixOS host. See the last suite in this file.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler, the real per-edge
## `ActionCache` + CAS in `repro_local_store`, the real graph-built io-monitor
## (`build/bin/repro internal io monitor` + the graph-built shim), a real C
## compiler (`cc`), a real `/bin/sh`, real `execvp` PATH resolution inside
## glibc, and real files in a real temporary directory. The defect class under
## test IS what production records for a real exec; a harness that supplied its
## own evidence or its own records would assert nothing about it.
##
## WHAT WAS MEASURED BEFORE THE FIX
## ---------------------------------------------------------------------
## Four shapes of "this action ran this binary", all on edges that declare no
## tool refs (env-inheritance census: `0 hermetic, 3 inherited, 0 EMPTY`), each
## driven through a real `repro build` and then given an ORDINARY byte+mtime
## replacement of the helper binary:
##
##   shape    helper in the depfile              in key   after the swap
##   -----    -------------------------------    ------   -----------------
##   bare     `mrPathProbe` + `mrProcessExec`     YES      cdRejected, correct
##   abs      `mrProcessExec` ONLY                no       cdHit, STALE
##   argv0    NOTHING AT ALL                      no       cdHit, STALE
##   execvp   unresolved name + failed marker     no       cdHit, STALE
##
## `bare` was covered ONLY BY ACCIDENT: a shell resolving a bare name `stat`s
## every PATH candidate, so the resolved hit lands as an `mrPathProbe`, and
## that arm IS folded. Nothing in the engine referenced `mrProcessExec` at all.
##
## The three uncovered rows have two different causes and therefore two
## different fixes, and this suite gates both plus the accidental coverage:
##
## * `abs` — the record exists and was discarded. Fixed by the `mrProcessExec`
##   arm in `foldOneMonitorRecord`.
## * `argv0` — there is NO record to fold. io-mon's `execve` hook is installed
##   by the preloaded shim's constructor, which runs in the CHILD, after the
##   image is already mapped; the launcher's exec of the action's ROOT image
##   precedes it. `mrProcessExec` covers NESTED execs only. Fixed on the
##   launcher side by `executedToolImagePath`.
## * `execvp` — the record exists but names the binary UNRESOLVED
##   (`path=helper2`), because glibc walks PATH internally after io-mon's
##   `dispatch_execvp` has already emitted. Folding it would send a relative
##   path through `materialPath` and MANUFACTURE `<cwd>/helper2`: a path that
##   does not exist, is not what ran, and is a fabricated dependency layered on
##   top of the gap. This suite pins that the phantom is NOT manufactured. The
##   gap itself is left open, deliberately — see the third test.
##
## Governing spec text:
##
## * Sandbox-And-Monitoring.md:12-19 — the observation set includes "loaded
##   tools and libraries when observable on the platform".
## * Sandbox-And-Monitoring.md:865-870 — "tool identity and loaded helper
##   libraries affect reproducibility".
## * Failure-Semantics.md:11-12 — "Ambiguous correctness failures MUST fail
##   closed: reject cache reuse, rerun, or require review rather than silently
##   accepting stale state." A manufactured path is not failing closed; it is
##   asserting something false, so `execvp` is skipped rather than guessed.
##
## HOW THE SWAP IS DONE, AND WHY IT MATTERS. The helper is REBUILT in place —
## new bytes and a new mtime, exactly what an ordinary rebuild of a tool
## produces. `mtime`-only trickery would be confounded by the default
## `acfpTimestamp` action-cache policy, which keys on timestamp; a byte-only
## swap would be confounded in the other direction. Both new bytes and a new
## mtime is the case a user actually hits.
##
## WHAT THE FIXTURE ABOVE STRUCTURALLY CANNOT REACH
## ---------------------------------------------------------------------
## `makeFixture` compiles the helper into a MUTABLE directory under the
## fixture root, and says so ("a MUTABLE directory, not a content-addressed
## store: on NixOS every tool a normal action runs is an immutable store path,
## which is exactly what masks this hole in day-to-day use"). That comment
## names the masking and then the suite never tests the masked case, so the
## four shapes above grade the recorded-input route and only that route.
##
## For a tool UNDER a content-addressed root the recorded-input route does not
## apply and must not: `cacheInputPaths` elides every observed read under the
## action's own `/nix/store` root as class 1
## (Dependency-Observation-Attribution.md §Class 1). The elision is sound only
## if the root's identity is in the key by some other route — and MEASURED on
## 2026-09-09, under the engine-default weak fingerprint, it was in NO route:
##
##   argv[0] = /nix/store/…-bash-5.2p26/bin/sh   -> publish
##   argv[0] = /nix/store/…-bash-5.3p9/bin/sh    -> cdHit, launched=false
##
## A different binary, and the record published against the first one was
## served without running anything. The final suite below is that case, and
## `keyedOnContentAddressedToolRoot` is what makes it pass.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
import repro_test_support

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false

proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-execdep", "execdep-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("executed-binary-evidence." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

const ReuseDecisions = {cdHit, cdHybridCutoff}

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("gcc")

## The helper. It appends one line naming its generation to the log named by
## `argv[1]`, so both "what ran" and "how many times" are observable out of
## band. It reads no file of its own: the helper binary IS the entire
## discovered input set that matters here.
const HelperSource = """
#include <stdio.h>
#ifndef GEN
#define GEN 1
#endif
int main(int argc, char **argv) {
  if (argc != 2) return 64;
  FILE *log = fopen(argv[1], "a");
  if (!log) return 66;
  fprintf(log, "helper gen=%d\n", GEN);
  fclose(log);
  return 0;
}
"""

## Resolves a BARE name through glibc's `execvp` — not through a shell's
## stat-based PATH walk, and not through the engine's launcher. This is the
## shape whose exec record io-mon can only report unresolved.
const LauncherSource = """
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc != 2) return 64;
  char *a[3];
  a[0] = "execdep_helper";
  a[1] = argv[1];
  a[2] = 0;
  execvp(a[0], a);
  return 65;
}
"""

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  binDir: string
  helperPath: string
  launcherPath: string
  logDir: string

proc logPath(f: Fixture; name: string): string = f.logDir / (name & ".log")

proc runCount(f: Fixture; name: string): int =
  let p = f.logPath(name)
  if not fileExists(p):
    return 0
  p.readFile.splitLines.countIt(it.strip().len > 0)

proc compileHelper(f: Fixture; gen: int) =
  ## Rebuild the helper in place with a different generation: new bytes AND a
  ## new mtime, the ordinary shape of "the tool was rebuilt".
  let cc = ccPath()
  let res = execProcess(cc, args = [
    "-DGEN=" & $gen, "-o", f.helperPath, f.workRoot / "helper.c"
  ], options = {poStdErrToStdOut, poUsePath})
  if not fileExists(f.helperPath):
    raise newException(OSError, "helper was not produced: " & res)

proc isVolatilePrefix(path: string): bool =
  ## Mirrors the engine's `isVolatileMonitorPath`. Kept here as a LOUD
  ## precondition rather than a comment because getting it wrong makes this
  ## whole suite vacuous in the quietest possible way: every path the monitor
  ## records under one of these prefixes is dropped before any arm sees it, so
  ## the helper simply never appears in the input set and all four cases fail
  ## (or, for a differently-shaped assertion, pass) for a reason that has
  ## nothing to do with what they test. Measured: with `TMPDIR=/run/user/<uid>`
  ## — a perfectly ordinary choice on a systemd host, and the one this repo's
  ## own instructions suggest for short socket paths — the recorded input set
  ## was thirteen `/nix/store` library loads and NOTHING under the fixture.
  for prefix in ["/run", "/proc", "/sys", "/dev"]:
    if path == prefix or path.startsWith(prefix & "/"):
      return true
  false

proc nonVolatileTempBase(): string =
  ## `getTempDir()` first, because a suite that pins `TMPDIR` deserves to be
  ## obeyed; `/tmp` only when that would put the fixture somewhere the engine
  ## refuses to fingerprint.
  result = getTempDir()
  if result.isVolatilePrefix():
    result = "/tmp"

proc makeFixture(): Fixture =
  let root = createTempDir("repro-executed-binary-", "",
    dir = nonVolatileTempBase())
  if root.isVolatilePrefix():
    raise newException(IOError,
      "fixture root " & root & " is under a volatile prefix the engine drops " &
      "from evidence; this suite cannot assert anything from there")
  let workRoot = root / "work"
  createDir(workRoot)
  # A MUTABLE directory, not a content-addressed store: on NixOS every tool a
  # normal action runs is an immutable store path, which is exactly what masks
  # this hole in day-to-day use.
  let binDir = workRoot / "bin"
  createDir(binDir)
  let logDir = workRoot / "out"
  createDir(logDir)
  writeFile(workRoot / "helper.c", HelperSource)
  writeFile(workRoot / "launcher.c", LauncherSource)
  result = Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    binDir: binDir,
    helperPath: binDir / "execdep_helper",
    launcherPath: binDir / "execdep_launcher",
    logDir: logDir)
  result.compileHelper(1)
  let cc = ccPath()
  let res = execProcess(cc, args = [
    "-o", result.launcherPath, workRoot / "launcher.c"
  ], options = {poStdErrToStdOut, poUsePath})
  if not fileExists(result.launcherPath):
    raise newException(OSError, "launcher was not produced: " & res)

proc childPath(f: Fixture): string =
  f.binDir & PathSep & getEnv("PATH")

proc monitoredEdge(f: Fixture; id: string; argv: openArray[string]): BuildAction =
  ## NOTE what is NOT here: the helper is not in `inputs`, and no tool ref is
  ## declared. Under `dgAutomaticMonitor` — the policy a real test-execute edge
  ## uses — the executed binary has to come from the monitor, from the
  ## launcher, or from nowhere.
  action(id, argv,
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    env = ["PATH=" & f.childPath()],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc absEdge(f: Fixture): BuildAction =
  ## `abs` — an ABSOLUTE path in a shell command. io-mon records the exec with
  ## the resolved path; nothing else in the depfile names the helper, because a
  ## shell handed an absolute path performs no PATH walk and therefore leaves
  ## no probe.
  f.monitoredEdge("execdep/abs", ["/bin/sh", "-c",
    f.helperPath & " " & f.logPath("abs")])

proc bareEdge(f: Fixture): BuildAction =
  ## `bare` — the shape that was already covered, by accident. Present as a
  ## REGRESSION guard: the fix must not disturb it.
  f.monitoredEdge("execdep/bare", ["/bin/sh", "-c",
    "execdep_helper " & f.logPath("bare")])

proc argv0Edge(f: Fixture): BuildAction =
  ## `argv0` — the action's OWN root image, a bare name with no shell in the
  ## picture at all. The launcher resolves it; io-mon's hook does not exist
  ## yet when it does.
  f.monitoredEdge("execdep/argv0", ["execdep_helper", f.logPath("argv0")])

proc execvpEdge(f: Fixture): BuildAction =
  ## `execvp` — a bare name resolved by glibc, inside a binary the shell
  ## exec'd by absolute path. Two execs: the launcher (absolute, recorded) and
  ## the helper (bare, recorded UNRESOLVED).
  f.monitoredEdge("execdep/execvp", ["/bin/sh", "-c",
    f.launcherPath & " " & f.logPath("execvp")])

proc monitoredConfig(repoRoot, cacheRoot: string): BuildEngineConfig =
  let tools = monitorTools(repoRoot)
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32
  result.monitorCliPath = tools.monitorCliPath
  result.monitorCliArgs = tools.monitorCliArgs

proc recordedInputs(f: Fixture; edge: BuildAction): seq[FileFingerprint] =
  var cache = openActionCache(f.cacheRoot / "action-cache")
  let hot = cache.readHotRecord(edge.weakFingerprint)
  if not hot.found:
    return @[]
  hot.record.inputs

proc exerciseShape(f: Fixture; repoRoot: string; edge: BuildAction;
                   name: string) =
  ## One shape, end to end: run it, prove the helper is IN the recorded input
  ## set, prove a warm run reuses, swap the helper for new bytes at a new
  ## mtime, prove the edge RE-RUNS with the new helper, and prove the new state
  ## is itself reusable so the fix did not simply make the edge a permanent
  ## miss.
  let g = graph([edge])
  let config = monitoredConfig(repoRoot, f.cacheRoot)

  let first = runBuild(g, config)
  let r0 = first.byId(edge.id)
  checkpoint(name & " first: status=" & $r0.status & " stderr=" & r0.stderr &
    " monitorReads=" & $r0.evidence.monitorReads.len)
  check r0.status == asSucceeded
  check r0.launched
  check f.runCount(name) == 1
  check f.logPath(name).readFile.contains("gen=1")

  # The denominator, and the whole point: the helper must be IN the recorded
  # input set. Without this the invalidation below could pass for an unrelated
  # reason (a directory probe, a sibling file).
  let inputs = f.recordedInputs(edge)
  let recorded = inputs.anyIt(it.path == f.helperPath)
  checkpoint(name & " recorded inputs: " & $inputs.len &
    "; helper among them: " & $recorded)
  check inputs.len > 0
  check recorded

  let warm = runBuild(g, config)
  checkpoint(name & " warm: decision=" & $warm.byId(edge.id).cacheDecision)
  check warm.byId(edge.id).cacheDecision in ReuseDecisions
  check not warm.byId(edge.id).launched
  check f.runCount(name) == 1

  f.compileHelper(2)

  let after = runBuild(g, config)
  let r = after.byId(edge.id)
  checkpoint(name & " after the swap: status=" & $r.status &
    " cacheDecision=" & $r.cacheDecision & " launched=" & $r.launched &
    " reason=" & r.reason)
  check r.cacheDecision notin ReuseDecisions
  check r.launched
  check f.runCount(name) == 2
  check f.logPath(name).readFile.contains("gen=2")

  let settled = runBuild(g, config)
  checkpoint(name & " settled: decision=" &
    $settled.byId(edge.id).cacheDecision)
  check settled.byId(edge.id).cacheDecision in ReuseDecisions
  check not settled.byId(edge.id).launched
  check f.runCount(name) == 2

suite "the binary an action executes is a recorded input":

  test "abs: an absolute exec inside a shell command is in the cache key":
    if ccPath().len == 0:
      skip()
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      f.exerciseShape(repoRoot, f.absEdge(), "abs")

  test "argv0: the action's own root image is in the cache key":
    if ccPath().len == 0:
      skip()
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      f.exerciseShape(repoRoot, f.argv0Edge(), "argv0")

  test "bare: the pre-existing accidental coverage still holds":
    if ccPath().len == 0:
      skip()
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      f.exerciseShape(repoRoot, f.bareEdge(), "bare")

  test "execvp: an unresolved exec name is never materialised against cwd":
    ## THE NEGATIVE GATE. io-mon records this exec as `path=execdep_helper`,
    ## with no directory, because glibc does the PATH walk internally after the
    ## hook has already emitted. `materialPath` would join that onto the
    ## action's cwd and produce `<workRoot>/execdep_helper` — a file that does
    ## not exist and was never executed. Recording it would be a MANUFACTURED
    ## dependency on top of the existing gap, which is strictly worse than the
    ## gap: the gap serves a stale result, the phantom asserts a false fact
    ## about what the action depends on and would make the edge's key depend on
    ## whether an unrelated file of that name ever appears in its work
    ## directory.
    ##
    ## What IS asserted positively: the launcher, exec'd by the shell with an
    ## absolute path, IS recorded. So the same edge shows the arm working and
    ## the arm correctly declining, and the two cannot be confused.
    ##
    ## The remaining gap — the helper reached through `execvp` is still not in
    ## the key — is left open ON PURPOSE and is not a defect this suite hides:
    ## closing it needs the resolution done where the search PATH is known to
    ## be the child's, which is not this fold.
    if ccPath().len == 0:
      skip()
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      let edge = f.execvpEdge()
      let g = graph([edge])
      let config = monitoredConfig(repoRoot, f.cacheRoot)

      let first = runBuild(g, config)
      let r0 = first.byId(edge.id)
      checkpoint("execvp first: status=" & $r0.status & " stderr=" & r0.stderr)
      check r0.status == asSucceeded
      check f.runCount("execvp") == 1

      let inputs = f.recordedInputs(edge)
      let phantom = f.workRoot / "execdep_helper"
      let phantomRecorded = inputs.anyIt(it.path == phantom)
      let launcherRecorded = inputs.anyIt(it.path == f.launcherPath)
      checkpoint("execvp recorded inputs: " & $inputs.len &
        "; launcher recorded: " & $launcherRecorded &
        "; phantom '" & phantom & "' recorded: " & $phantomRecorded)
      check inputs.len > 0
      # The arm works ...
      check launcherRecorded
      # ... and it declines rather than guessing.
      check not phantomRecorded
      check not fileExists(phantom)

# ---------------------------------------------------------------------------
# The tool UNDER a content-addressed root.
# ---------------------------------------------------------------------------

proc contentAddressedShells(shim: string): seq[string] =
  ## Distinct `/nix/store/<hash>-bash-…` roots, each supplying a `bin/sh` this
  ## host can execute UNDER THE MONITOR. Up to two; fewer means the suite below
  ## skips.
  ##
  ## THE HOST'S REAL STORE, not a fixture directory, and that is forced rather
  ## than chosen. `nixStoreRoot` — the single function both the elision
  ## (`toolInputRoots`) and the key mix (`keyedOnContentAddressedToolRoot`)
  ## consult — recognizes the literal prefix `/nix/store/` and nothing else, so
  ## a synthesized "store-like" directory under the fixture root would be
  ## elided by neither and this suite would assert nothing while reading green.
  ## That is precisely the failure mode the file's original fixture had.
  ##
  ## BOTH PROBES BELOW EARNED THEIR PLACE ON THIS HOST, and each rejects a
  ## candidate that would fail the edge for a reason with nothing to do with
  ## caching:
  ##
  ## * plain execution — the first candidate a bare name scan returned was a
  ##   bash derivation built for another machine format: "cannot execute
  ##   binary file: Exec format error".
  ## * execution WITH THE SHIM INJECTED — `bash-5.2p26` here is a
  ##   `bootstrap-stage0` derivation whose loader and libc come from
  ##   `bootstrap-stage0-glibc-bootstrapFiles`. It runs perfectly on its own
  ##   and dies as `libm.so.6: cannot open shared object file` the moment the
  ##   monitor shim is preloaded into it, because the shim is linked against
  ##   the dev shell's glibc and that closure is not reachable from the
  ##   bootstrap loader. A tool the monitor cannot inject into is a real and
  ##   separate condition (io-mon reports it as event loss); it is not the
  ##   condition this suite is about, so it is filtered out here rather than
  ##   diagnosed as a cache defect at the assertion.
  var roots: seq[string] = @[]
  for entry in walkDir("/nix/store"):
    if entry.kind != pcDir:
      continue
    let name = entry.path.extractFilename
    if not name.contains("-bash-5") or name.contains("interactive"):
      continue
    let sh = entry.path / "bin" / "sh"
    if not fileExists(sh):
      continue
    if execShellCmd(sh & " -c true >/dev/null 2>&1") != 0:
      continue
    if execShellCmd(InjectionVariableForHost & "=" & shim & " " & sh &
        " -c true >/dev/null 2>&1") != 0:
      continue
    roots.add(sh)
    if roots.len >= 2:
      break
  roots

proc storeToolEdge(f: Fixture; sh: string): BuildAction =
  ## ONE edge id, ONE command, ONE declared environment — the only thing that
  ## varies between the two calls this suite makes is `argv[0]`. Everything
  ## the engine's default weak fingerprint covers (the id, the governing lock,
  ## the environment declaration) is therefore held constant, which is what
  ## makes the decision after the swap attributable to the tool and to nothing
  ## else.
  ##
  ## The command runs the MUTABLE helper, so the edge has a genuine class-2
  ## input of its own. Without one the record's input set would be empty and
  ## `gradeKeyedInputSet` would refuse the publish — a correct refusal, but it
  ## would decide this case before the property under test got a chance to.
  f.monitoredEdge("execdep/store-tool",
    [sh, "-c", f.helperPath & " " & f.logPath("store-tool")])

suite "a tool under a content-addressed root is in the cache key without being a recorded input":

  test "swapping the store-resolved argv[0] re-runs the edge, and each tool keeps its own record":
    let repoRoot = findRepoRoot()
    let shells =
      if ccPath().len == 0: newSeq[string]()
      else: contentAddressedShells(monitorTools(repoRoot).shim)
    if ccPath().len == 0 or shells.len < 2:
      skip()
    else:
      let shA = shells[0]
      let shB = shells[1]
      let rootA = shA.parentDir.parentDir
      # THE DENOMINATOR. Two different store paths must be two different
      # programs, or "the edge re-ran" would be a statement about nothing.
      check readFile(shA) != readFile(shB)

      let f = makeFixture()
      defer: removeDir(f.root)

      let edgeA = f.storeToolEdge(shA)
      let edgeB = f.storeToolEdge(shB)
      # The mechanism, named: the two edges differ ONLY in `argv[0]`, and the
      # engine's constructor is what turns that into two keys. An assertion on
      # the decision alone would also pass if some unrelated component of the
      # fingerprint happened to move.
      checkpoint("weakA=" & toHex(edgeA.weakFingerprint.bytes) &
        " weakB=" & toHex(edgeB.weakFingerprint.bytes))
      check edgeA.weakFingerprint != edgeB.weakFingerprint

      let config = monitoredConfig(repoRoot, f.cacheRoot)

      let first = runBuild(graph([edgeA]), config)
      let r0 = first.byId(edgeA.id)
      checkpoint("A first: status=" & $r0.status & " stderr=" & r0.stderr)
      check r0.status == asSucceeded
      check r0.launched
      check f.runCount("store-tool") == 1

      let inputs = f.recordedInputs(edgeA)
      let toolRecorded = inputs.anyIt(it.path == shA)
      let underOwnRoot = inputs.filterIt(
        it.path == rootA or it.path.startsWith(rootA & "/"))
      let helperRecorded = inputs.anyIt(it.path == f.helperPath)
      checkpoint("A recorded inputs: " & $inputs.len &
        "; tool recorded: " & $toolRecorded &
        "; under own store root: " & $underOwnRoot.len &
        "; helper recorded: " & $helperRecorded)
      # The edge published something real ...
      check inputs.len > 0
      check helperRecorded
      # ... and the tool is NOT part of it. This is the class-1 elision doing
      # its job, and it is why the swap below cannot be caught by input
      # revalidation: there is no recorded input naming the tool to revalidate.
      check not toolRecorded
      check underOwnRoot.len == 0

      let warm = runBuild(graph([edgeA]), config)
      checkpoint("A warm: decision=" & $warm.byId(edgeA.id).cacheDecision)
      check warm.byId(edgeA.id).cacheDecision in ReuseDecisions
      check not warm.byId(edgeA.id).launched
      check f.runCount("store-tool") == 1

      # THE SWAP. A different store path is what a content change to a
      # nix-built tool looks like; the store cannot mutate one in place.
      let swapped = runBuild(graph([edgeB]), config)
      let r1 = swapped.byId(edgeB.id)
      checkpoint("after the tool swap: decision=" & $r1.cacheDecision &
        " launched=" & $r1.launched & " reason=" & r1.reason)
      check r1.cacheDecision notin ReuseDecisions
      check r1.launched
      check f.runCount("store-tool") == 2

      # ... and the new state is itself reusable, so the fix is a re-key
      # rather than a permanent miss.
      let settled = runBuild(graph([edgeB]), config)
      checkpoint("B settled: decision=" & $settled.byId(edgeB.id).cacheDecision)
      check settled.byId(edgeB.id).cacheDecision in ReuseDecisions
      check not settled.byId(edgeB.id).launched
      check f.runCount("store-tool") == 2

      # THE KEY DISTINGUISHES, IT DOES NOT MERELY MOVE. Going back to tool A
      # serves A's own record without executing anything. An implementation
      # that invalidated on every build — the cheap way to make the swap
      # assertion above pass — fails here.
      let backToA = runBuild(graph([edgeA]), config)
      checkpoint("back to A: decision=" & $backToA.byId(edgeA.id).cacheDecision)
      check backToA.byId(edgeA.id).cacheDecision in ReuseDecisions
      check not backToA.byId(edgeA.id).launched
      check f.runCount("store-tool") == 2

  test "an argv[0] outside any content-addressed root does not move the key":
    ## THE IDENTITY CASE, and it is a requirement rather than a nicety: a
    ## correctness fix that shifted every fingerprint would ship as a total
    ## cache wipe for every user who does not build on NixOS. NLF-STAT-4's
    ## recorded baseline corpus uses `/usr/bin/cc`, so this is also what keeps
    ## those bytes where they are.
    let digest = weakFingerprintFromText("execdep/identity-case")
    check keyedOnContentAddressedToolRoot(digest, ["/usr/bin/cc", "-c"]) ==
      digest
    check keyedOnContentAddressedToolRoot(digest, ["/bin/sh", "-c"]) == digest
    check keyedOnContentAddressedToolRoot(digest, []) == digest
    # ... while a store path does move it, and two different store roots move
    # it to two different places.
    let a = keyedOnContentAddressedToolRoot(digest,
      ["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bash-5.2p26/bin/sh"])
    let b = keyedOnContentAddressedToolRoot(digest,
      ["/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bash-5.3p9/bin/sh"])
    check a != digest
    check b != digest
    check a != b
    # The mix is over the ROOT, not the full path, because the ROOT is the
    # granularity `cacheInputPaths` subtracts at. Two binaries in the same
    # store root are covered by one key component; splitting them would key on
    # something the elision does not bound.
    check keyedOnContentAddressedToolRoot(digest,
      ["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bash-5.2p26/bin/bash"]) == a
