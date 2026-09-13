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
  ## than chosen. `contentAddressedRoot` — the single function both the elision
  ## (`toolInputRoots`) and the key mix (`keyedOnContentAddressedToolRoot`)
  ## consult — recognizes the literal prefix `/nix/store/` and reprobuild's own
  ## CAS store, and nothing else, so a synthesized "store-like" directory under
  ## the fixture root would be elided by neither and this suite would assert
  ## nothing while reading green. That is precisely the failure mode the file's
  ## original fixture had. The repro-store arm below builds its fixture out of
  ## the store's own naming contract and points `$REPRO_STORE_ROOT` at it, for
  ## the same reason: a directory the resolver does not recognise would be
  ## graded by neither side.
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

proc coreutilsPrograms(shim: string): seq[string] =
  ## `[<coreutils>/bin/cat, <coreutils>/bin/head]` from ONE `/nix/store`
  ## derivation, or an empty seq.
  ##
  ## The granularity case needs the opposite fixture from
  ## `contentAddressedShells`: two programs sharing one root, rather than one
  ## program under two roots. Both probes are the same ones that suite needs
  ## and for the same reasons — a derivation built for another machine format,
  ## and a bootstrap derivation the shim cannot be preloaded into, are both
  ## real conditions with nothing to do with caching.
  for entry in walkDir("/nix/store"):
    if entry.kind != pcDir:
      continue
    if not entry.path.extractFilename.contains("-coreutils"):
      continue
    let cat = entry.path / "bin" / "cat"
    let head = entry.path / "bin" / "head"
    if not fileExists(cat) or not fileExists(head):
      continue
    var usable = true
    for prog in [cat, head]:
      if execShellCmd(prog & " /dev/null >/dev/null 2>&1") != 0 or
          execShellCmd(InjectionVariableForHost & "=" & shim & " " & prog &
            " /dev/null >/dev/null 2>&1") != 0:
        usable = false
        break
    if usable:
      return @[cat, head]
  @[]

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

      # The root the elision subtracts at, asked for from both ends of it.
      # `<hash>-<name>` is the granularity: a path inside it answers the root,
      # and the ROOT DIRECTORY ITSELF answers itself. The second is a separate
      # arm — there is no further `/` to cut at, so the whole normalised path
      # is the answer — and it is not academic: `isUnderAnyRoot` compares a
      # candidate against the root by equality as well as by prefix, and a
      # store root is a perfectly ordinary thing for an action to `stat`.
      check contentAddressedRoot(shA) == rootA
      check contentAddressedRoot(rootA) == rootA

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

  test "a tool under REPROBUILD'S OWN store is in the key just like a Nix one":
    ## THE OTHER CONTENT-ADDRESSED ROOT, and it was the more dangerous of the
    ## two because the symmetry that made it look safe is not sufficient.
    ##
    ## While `contentAddressedRoot` recognised the literal `/nix/store/` and
    ## nothing else, a repro-store tool was elided by neither side and mixed by
    ## neither side. Rule 7 held — same set both sides — so the ELISION hole
    ## stayed shut, and the tool survived as an ordinary recorded input. That
    ## is not enough, and MEASURED (2026-09-09) with two byte-different bashes
    ## under this exact fixture layout it fails outright:
    ##
    ##     PROBE weak(A)==weak(B): true
    ##     PROBE after the CAS tool swap: decision=cdHit launched=false runs=1
    ##
    ## Revalidation only re-checks the paths a record already NAMES. `<A>/sh`
    ## still existed and still hashed the same; nothing noticed `argv[0]` had
    ## moved to `<B>/sh`. **A content-addressed store expresses a tool change
    ## as a new PATH, so recording the old path cannot catch it — only keying
    ## on it can.**
    ##
    ## THE FIXTURE IS BUILT FROM THE STORE'S OWN NAMING CONTRACT
    ## (`prefixRelativePath` / `realizationDirName`) and the resolver is
    ## pointed at it through `$REPRO_STORE_ROOT`, the same precedence every
    ## other store consumer uses. Inventing a plausible-looking prefix instead
    ## would be recognised by nothing and this case would read green while
    ## asserting nothing — the failure mode the suite header names.
    let repoRoot = findRepoRoot()
    let shells =
      if ccPath().len == 0: newSeq[string]()
      else: contentAddressedShells(monitorTools(repoRoot).shim)
    if ccPath().len == 0 or shells.len < 2:
      skip()
    else:
      let f = makeFixture()
      defer: removeDir(f.root)

      let storeRoot = f.root / "store"
      var digestA: PrefixIdBytes
      var digestB: PrefixIdBytes
      for i in 0 ..< 32:
        digestA[i] = byte(0xA0 or (i and 0x0F))
        digestB[i] = byte(0xB0 or (i and 0x0F))
      let dirA = storeRoot / prefixRelativePath("bash", "5.2", digestA)
      let dirB = storeRoot / prefixRelativePath("bash", "5.3", digestB)
      createDir(dirA / "bin")
      createDir(dirB / "bin")
      let toolA = dirA / "bin" / "sh"
      let toolB = dirB / "bin" / "sh"
      copyFileWithPermissions(shells[0], toolA)
      copyFileWithPermissions(shells[1], toolB)
      # THE DENOMINATOR. Two store paths must be two different programs, or
      # "the edge re-ran" would be a statement about nothing.
      check readFile(toolA) != readFile(toolB)

      let previousStoreRoot = getEnv(StoreRootEnvVar)
      putEnv(StoreRootEnvVar, storeRoot)
      defer:
        if previousStoreRoot.len > 0: putEnv(StoreRootEnvVar, previousStoreRoot)
        else: delEnv(StoreRootEnvVar)

      # The resolver recognises the realization directory, and stops there:
      # `<store>/prefixes` is not content-addressed and must never be elided.
      check contentAddressedRoot(toolA) == dirA
      check contentAddressedRoot(toolB) == dirB
      check contentAddressedRoot(storeRoot / "prefixes" / "bash").len == 0

      let src = f.workRoot / "repro-store-src.txt"
      writeFile(src, "generation-1\n")
      let log = f.logPath("repro-store")

      proc storeEdge(tool: string): BuildAction =
        ## ONE id, ONE command; only `argv[0]` differs. Reading a workspace
        ## file gives the edge a genuine class-2 input, so the empty-key guard
        ## does not decide the case first.
        f.monitoredEdge("execdep/repro-store",
          [tool, "-c", "cat " & src & " >> " & log])

      let edgeA = storeEdge(toolA)
      let edgeB = storeEdge(toolB)
      checkpoint("weakA=" & toHex(edgeA.weakFingerprint.bytes) &
        " weakB=" & toHex(edgeB.weakFingerprint.bytes))
      check edgeA.weakFingerprint != edgeB.weakFingerprint

      let config = monitoredConfig(repoRoot, f.cacheRoot)

      let first = runBuild(graph([edgeA]), config)
      let r0 = first.byId(edgeA.id)
      checkpoint("A first: status=" & $r0.status & " stderr=" & r0.stderr)
      check r0.status == asSucceeded
      check r0.launched
      check f.runCount("repro-store") == 1

      # The elision applies to this root exactly as it does to a Nix one, so
      # the tool is NOT a recorded input and revalidation cannot see the swap.
      # That is what makes the key the only thing standing between the two.
      let inputs = f.recordedInputs(edgeA)
      checkpoint("A recorded inputs: " & $inputs.len)
      check inputs.len > 0
      check not inputs.anyIt(it.path == toolA)
      check not inputs.anyIt(it.path.startsWith(dirA & "/"))

      let warm = runBuild(graph([edgeA]), config)
      checkpoint("A warm: decision=" & $warm.byId(edgeA.id).cacheDecision)
      check warm.byId(edgeA.id).cacheDecision in ReuseDecisions
      check f.runCount("repro-store") == 1

      let swapped = runBuild(graph([edgeB]), config)
      let r1 = swapped.byId(edgeB.id)
      checkpoint("after the CAS tool swap: decision=" & $r1.cacheDecision &
        " launched=" & $r1.launched & " reason=" & r1.reason)
      check r1.cacheDecision notin ReuseDecisions
      check r1.launched
      check f.runCount("repro-store") == 2

      # ... and it is a re-key, not a blanket invalidation.
      let backToA = runBuild(graph([edgeA]), config)
      checkpoint("back to A: decision=" &
        $backToA.byId(edgeA.id).cacheDecision)
      check backToA.byId(edgeA.id).cacheDecision in ReuseDecisions
      check f.runCount("repro-store") == 2

  test "a MUTABLE directory inside the store is neither elided nor keyed as content-addressed":
    ## THE PREDICATE, not the scope — rule 8 one level down.
    ##
    ## `reproStoreRootPath` is the only place `contentAddressedRoot` reads
    ## CONFIGURATION, and its own comment gives the entire justification for
    ## letting it: "What the env var still could do is nominate a MUTABLE tree
    ## as content-addressed within one consistent setting, and that is what
    ## `isRealizationDirName` bounds: the only thing elided under this root is
    ## a directory whose own name states a 16-hex realization digest."
    ##
    ## That bound was graded by NOTHING. MEASURED (2026-09-09): with
    ## `isRealizationDirName`'s body replaced by `true` — the two shape checks
    ## deleted, the trailing literal left — every other case in this file
    ## stays green and only this one reddens, and the same mutation was
    ## measured leaving `t_zero_evidence_edge_is_not_cacheable` at 21/21 with
    ## no skips. The two guards on that env read are not equally covered: the
    ## required `prefixes` segment is graded by the case above, whose fixture
    ## is a real realization directory; the SHAPE check had a scope and no
    ## predicate.
    ##
    ## AND THAT SHAPE CHECK IS ITSELF A CONJUNCTION OF TWO INDEPENDENT ARMS, so
    ## a fixture that reaches one of them grades half a predicate:
    ##
    ##     if name.len < 17 or name[name.len - 17] != '-': return false  # arm 1
    ##     for i in name.len - 16 ..< name.len:                          # arm 2
    ##       if name[i] notin {'0' .. '9', 'a' .. 'f'}: return false
    ##
    ## MEASURED (2026-09-09) while `latest` was this case's only alias:
    ## deleting arm 2 and keeping arm 1 left this file at 13/13 and
    ## `t_zero_evidence_edge_is_not_cacheable` at 21/21, no skips. `latest` is
    ## six characters, so arm 1 rejects it on its own and arm 2 never runs —
    ## the fixture could not reach the half of the predicate that does the
    ## DIGEST work, which is the half the quoted justification above rests on.
    ## Probed through the shipped `contentAddressedRoot`:
    ##
    ##     segment                   shipped   arm 2 deleted
    ##     5.2-c0c1c2c3c4c5c6c7      CA root   CA root
    ##     bash-mutable-checkout     ""        CA ROOT
    ##     latest                    ""        ""
    ##
    ## So EACH ARM GETS ITS OWN ALIAS below, and every alias is graded at all
    ## four levels this case grades — the predicate, the key mix, the elision,
    ## and the end-to-end repoint:
    ##
    ## * `latest` — six characters, rejected by arm 1's LENGTH half. The
    ##   ordinary mutable version alias, and the shape this case started from.
    ## * `c0c1c2c3c4c5c6c7c8c9dadbdcdddedf` — 32 hex characters. PASSES arm 2
    ##   and is rejected by arm 1, because what sits at `len - 17` is another
    ##   hex digit rather than the separator. This is a directory named by a
    ##   bare content digest with the store's `<version>-` prefix dropped: it
    ##   carries a digest but not the SHAPE `realizationDirName` states, and
    ##   the separator is the only thing that tells the two apart. It grades
    ##   arm 1 on a WRONG ANSWER — with arm 1 deleted, arm 2 accepts it —
    ##   rather than on the IndexDefect a name shorter than 16 would raise
    ##   from `name.len - 16` going negative.
    ## * `bash-mutable-checkout` — 21 characters with a `-` exactly 17 from the
    ##   end and a tail of `mutable-checkout` that is not hex. PASSES arm 1,
    ##   rejected only by arm 2. A working checkout a person would plausibly
    ##   drop beside the realizations, whose name merely LOOKS versioned; with
    ##   arm 2 gone it is elided from the recorded set and keyed as if its path
    ##   named its own content — the same defect `latest` was written for,
    ##   reached one arm over.
    ##
    ## Neither arm is subsumed by the other, and the two aliases are the
    ## witness in both directions: `bash-mutable-checkout` is accepted by arm 1
    ## and rejected by arm 2, the bare digest is accepted by arm 2 and rejected
    ## by arm 1. MEASURED (2026-09-09) with the aliases below in place, each
    ## mutation applied on its own to the shipped engine and the file rebuilt
    ## between them: deleting arm 2 reddens ONLY this case (12 [OK], 1
    ## [FAILED], 0 [SKIPPED], exit 1) at all four levels, ending in
    ## `after the repoint: decision=cdHit launched=false` — a hit served
    ## against a byte-different binary; deleting arm 1 reddens ONLY this case
    ## the same way on the bare digest and then aborts on `latest`'s
    ## IndexDefect. Restored, the file is 13/13, 0 skips, exit 0.
    ##
    ## THE FIXTURE IS THE SHAPE THAT ACTUALLY OCCURS. `<store>/prefixes/<pkg>/`
    ## is a package directory whose CHILDREN are realizations, so it is exactly
    ## where a mutable alias lands. With the shape check gone such an alias
    ## becomes a content-addressed root, and BOTH halves of class 1's licence
    ## are then false for it:
    ##
    ## * it is not content-addressed, so the elision drops an observation that
    ##   nothing else accounts for — no recorded input names the tool; and
    ## * its path is STABLE across a repoint, so the key does not move when the
    ##   alias comes to name different bytes.
    ##
    ## Together those are a hit served against a different binary, which is the
    ## same failure §"S2 and S3, settled" measured for the Nix store — reached
    ## here through configuration rather than through a missing key component.
    ##
    ## Every alias differs from the realization in exactly ONE thing, and the
    ## denominator beside them is what makes that a statement rather than a
    ## hope: the real realization is built by the store's own
    ## `prefixRelativePath` under the same root, so an assertion below cannot
    ## be satisfied by `$REPRO_STORE_ROOT` failing to take. Three aliases
    ## differ only in the SHAPE of one segment's name; two differ only in
    ## WHERE a segment of exactly the right name sits.
    let repoRoot = findRepoRoot()
    let shells =
      if ccPath().len == 0: newSeq[string]()
      else: contentAddressedShells(monitorTools(repoRoot).shim)
    if ccPath().len == 0 or shells.len < 2:
      skip()
    else:
      let f = makeFixture()
      defer: removeDir(f.root)

      let storeRoot = f.root / "store"
      var digest: PrefixIdBytes
      for i in 0 ..< 32:
        digest[i] = byte(0xC0 or (i and 0x0F))
      # A REAL realization beside the aliases, built from the store's own
      # naming contract. It is the denominator: without it a `""` for an alias
      # would be indistinguishable from `$REPRO_STORE_ROOT` never having taken,
      # and this case would read green while asserting nothing.
      let realDir = storeRoot / prefixRelativePath("bash", "5.2", digest)
      createDir(realDir / "bin")
      let realTool = realDir / "bin" / "sh"
      copyFileWithPermissions(shells[0], realTool)

      # ONE ALIAS PER ARM that can reject a directory under this store root.
      # `tag` only names the edge and its log; the entire property under test
      # lives in `relDir`, which is a path RELATIVE TO THE STORE ROOT because
      # two of the arms are about DEPTH and cannot be expressed by a name.
      #
      #   relDir                                      rejected by
      #   prefixes/bash/<32 hex>                      the separator arm
      #   prefixes/bash/bash-mutable-checkout         the hex-digit arm
      #   prefixes/bash/latest/tmp/<realization>      the `prefixes` DEPTH arm
      #   scratch/prefixes/x/latest/build/<realiz.>   the `prefixes` DEPTH arm
      #   prefixes/bash/latest                        the length arm
      #
      # THE TWO DEPTH WITNESSES CARRY A REAL REALIZATION NAME — literally the
      # `realizationDirName` composed for the realization above, the same
      # string — so `isRealizationDirName` ACCEPTS their last segment and
      # nothing about the NAME rejects them. What rejects them is that the
      # name does not sit exactly two segments below a `prefixes` segment.
      #
      # MEASURED (2026-09-09) before they existed: deleting `parts[i] !=
      # "prefixes"` from `reproStoreRealizationRoot`, keeping the bounds check
      # beside it, left this file at 13/13 and exit 0 — because every fixture
      # here was already at the right depth, so the only arm that had ever
      # been asked about the segment was the `contains("/prefixes/")`
      # rejection above it, which is a performance guard that decides nothing.
      # The requirement is not "a `prefixes` segment appears somewhere in the
      # path"; it is "the realization sits exactly two segments below one".
      #
      # The second depth witness nests `prefixes` one level down on purpose.
      # The store really does nest one inside itself — tools live under
      # `<store>/tool-store/prefixes/<package>/<version>-<hash>` — so the
      # segment has to be SEARCHED for, and "require it at depth 1" is not an
      # available fix. What is required is that the match be positional
      # relative to that segment wherever it is found.
      #
      # ORDER MATTERS, and only for what a failure is legible AS. A `check`
      # failure is recorded and the loop carries on, but an EXCEPTION aborts
      # the whole case — and `latest` raises one when the length arm is
      # deleted, because `name.len - 16` goes to -10 and the digit arm indexes
      # out of bounds. Put it last and that mutation reads as wrong ANSWERS
      # about the aliases before it and only then an IndexDefect; put it first
      # and the IndexDefect is all you get, which says far less about what the
      # arm is FOR. MEASURED both ways.
      let realization = realizationDirName("5.2", digest)
      let aliases = @[
        (relDir: "prefixes/bash/c0c1c2c3c4c5c6c7c8c9dadbdcdddedf",
         tag: "bare-digest"),
        (relDir: "prefixes/bash/bash-mutable-checkout", tag: "checkout"),
        (relDir: "prefixes/bash/latest/tmp/" & realization, tag: "too-deep"),
        (relDir: "scratch/prefixes/x/latest/build/" & realization,
         tag: "nested-too-deep"),
        (relDir: "prefixes/bash/latest", tag: "latest")]
      var aliasDirs: seq[string]
      var aliasTools: seq[string]
      for a in aliases:
        let dir = storeRoot / a.relDir
        createDir(dir / "bin")
        copyFileWithPermissions(shells[0], dir / "bin" / "sh")
        aliasDirs.add(dir)
        aliasTools.add(dir / "bin" / "sh")

      # THE DENOMINATOR for the repoints below: the two bashes must really be
      # two different programs, or "the edge re-ran" says nothing.
      check readFile(shells[0]) != readFile(shells[1])

      let previousStoreRoot = getEnv(StoreRootEnvVar)
      putEnv(StoreRootEnvVar, storeRoot)
      defer:
        if previousStoreRoot.len > 0: putEnv(StoreRootEnvVar, previousStoreRoot)
        else: delEnv(StoreRootEnvVar)

      # The realization name is recognised ...
      check contentAddressedRoot(realTool) == realDir
      let seed = weakFingerprintFromText("execdep/store-alias")
      # ... and for a recognised root the mix MOVES the fingerprint. Asserted
      # once, here, so that each alias's identity below is a statement about
      # the predicate rather than about a mix that never does anything.
      check keyedOnContentAddressedToolRoot(seed, [realTool]) != seed

      let config = monitoredConfig(repoRoot, f.cacheRoot)

      for i, a in aliases:
        let aliasDir = aliasDirs[i]
        let aliasTool = aliasTools[i]
        let name = "store-alias-" & a.tag

        # THE PREDICATE. Every alias sits under the same store root as the
        # recognised realization and carries a `prefixes` segment, so the only
        # thing that can decide it is the predicate — asked at the tool and at
        # the directory itself, because the directory is what the elision
        # subtracts at.
        checkpoint(a.relDir & ": root(tool)=" &
          contentAddressedRoot(aliasTool) & " root(dir)=" &
          contentAddressedRoot(aliasDir))
        check contentAddressedRoot(aliasTool).len == 0
        check contentAddressedRoot(aliasDir).len == 0

        # NOT KEYED AS CONTENT-ADDRESSED. The realization moved the
        # fingerprint above; for a mutable alias the mix must be the identity.
        # A moved fingerprint here would be the worse half of the defect: it
        # would state "this path names its own content" about a path that does
        # not.
        check keyedOnContentAddressedToolRoot(seed, [aliasTool]) == seed

        # NOT ELIDED, end to end. The command runs the mutable helper so the
        # edge has a class-2 input of its own and `gradeKeyedInputSet` does not
        # decide the case before the property under test gets a turn.
        let edge = f.monitoredEdge("execdep/" & name,
          [aliasTool, "-c", f.helperPath & " " & f.logPath(name)])

        let first = runBuild(graph([edge]), config)
        let r0 = first.byId(edge.id)
        checkpoint(a.relDir & " first: status=" & $r0.status &
          " stderr=" & r0.stderr)
        check r0.status == asSucceeded
        check r0.launched
        check f.runCount(name) == 1

        let inputs = f.recordedInputs(edge)
        let aliasRecorded = inputs.anyIt(it.path == aliasTool)
        checkpoint(a.relDir & " recorded inputs: " & $inputs.len &
          "; alias tool among them: " & $aliasRecorded)
        check inputs.len > 0
        # A mutable tree has only the ordinary recorded-input route, and it
        # must still be open. This is the assertion the elision closes.
        check aliasRecorded

        let warm = runBuild(graph([edge]), config)
        checkpoint(a.relDir & " warm: decision=" &
          $warm.byId(edge.id).cacheDecision)
        check warm.byId(edge.id).cacheDecision in ReuseDecisions
        check not warm.byId(edge.id).launched
        check f.runCount(name) == 1

        # THE REPOINT — what makes an alias an alias. The SAME path comes to
        # name different bytes, which a content-addressed root cannot do and is
        # precisely why treating one as the other is unsound. The edge value is
        # unchanged, so its weak fingerprint is unchanged: the only thing that
        # can catch this is the recorded input asserted above.
        #
        # Unlink first: a store copy carries the store's read-only mode, so
        # writing THROUGH the old entry fails with EACCES. Replacing the entry
        # is also what a repoint actually is.
        removeFile(aliasTool)
        copyFileWithPermissions(shells[1], aliasTool)
        let after = runBuild(graph([edge]), config)
        let r1 = after.byId(edge.id)
        checkpoint(a.relDir & " after the repoint: decision=" &
          $r1.cacheDecision & " launched=" & $r1.launched &
          " reason=" & r1.reason)
        check r1.cacheDecision notin ReuseDecisions
        check r1.launched
        check f.runCount(name) == 2

        # ... and the new state is reusable, so this is revalidation working
        # rather than the edge having become a permanent miss.
        let settled = runBuild(graph([edge]), config)
        checkpoint(a.relDir & " settled: decision=" &
          $settled.byId(edge.id).cacheDecision)
        check settled.byId(edge.id).cacheDecision in ReuseDecisions
        check not settled.byId(edge.id).launched
        check f.runCount(name) == 2

  test "only the store root the resolver names exempts anything":
    ## THE THREE ARMS BETWEEN `$REPRO_STORE_ROOT` AND A RECOGNISED ROOT, none
    ## of which any fixture above can reach, because every one of them builds
    ## its paths under a store root that resolves and then asks about paths
    ## inside it. Each arm below is measured by a witness that ONLY it
    ## rejects.
    ##
    ## THE LAYOUT IS BUILT WITH THE STORE'S OWN `prefixRelativePath` on BOTH
    ## sides of every comparison, and only the ROOT moves. A layout no
    ## resolver recognises can demonstrate a hole and cannot demonstrate its
    ## fix, so the recognised half is always present as the denominator.
    ##
    ## No `cc` and no shells, deliberately: every arm here is decided by a
    ## predicate over a string, and a case that skips on hosts without a
    ## compiler would prove nothing on exactly those hosts.
    let root = createTempDir("repro-store-root-arms-", "",
      dir = nonVolatileTempBase())
    defer: removeDir(root)

    var digest: PrefixIdBytes
    for i in 0 ..< 32:
      digest[i] = byte(0xD0 or (i and 0x0F))
    let storeRoot = root / "store"
    let inside = storeRoot / prefixRelativePath("bash", "5.2", digest)
    # THE SAME LAYOUT, ONE DIRECTORY OVER: byte-for-byte the same realization
    # name, the same `prefixes` segment, the same depth below its own parent.
    # The ONLY difference is which root it hangs off, so nothing but the
    # containment arm can tell these two apart.
    let elsewhere = root / "elsewhere" /
      prefixRelativePath("bash", "5.2", digest)
    createDir(inside / "bin")
    createDir(elsewhere / "bin")
    let insideTool = inside / "bin" / "sh"
    let elsewhereTool = elsewhere / "bin" / "sh"

    let previousStoreRoot = getEnv(StoreRootEnvVar)
    defer:
      if previousStoreRoot.len > 0: putEnv(StoreRootEnvVar, previousStoreRoot)
      else: delEnv(StoreRootEnvVar)

    let seed = weakFingerprintFromText("execdep/store-root-arms")
    putEnv(StoreRootEnvVar, storeRoot)

    # THE DENOMINATOR. With the variable pointed here this layout IS
    # recognised, so every `""` below is a statement about a path rather than
    # about the variable having failed to take.
    check contentAddressedRoot(insideTool) == inside
    check keyedOnContentAddressedToolRoot(seed, [insideTool]) != seed

    # OUTSIDE THE ROOT, and the failure is worse than "recognised something it
    # should not have". The segment split is taken at the store root's LENGTH,
    # so without the containment arm a path that merely happens to be as long
    # is cut in the wrong place and the answer is a directory that does not
    # exist and never did — `<root>/store` and `<root>/elsewhere` differ in
    # length, and the answer for the second is assembled out of the first's
    # prefix. Asserting the answer is a PREFIX of what was asked about is what
    # a fabricated root cannot satisfy, and it is the assertion that survives
    # any future change to the layout's spelling.
    let outsideRoot = contentAddressedRoot(elsewhereTool)
    checkpoint("outside the store root: [" & outsideRoot & "]")
    check outsideRoot.len == 0
    check elsewhereTool.startsWith(outsideRoot)
    check keyedOnContentAddressedToolRoot(seed, [elsewhereTool]) == seed

    # SHALLOWER THAN A REALIZATION. `<store>/prefixes` and
    # `<store>/prefixes/<package>` are directories the store really has, and
    # neither is content-addressed — packages come and go under the first,
    # versions under the second. Two segments after `prefixes` is what the
    # naming contract puts the digest in, so anything shorter has no digest to
    # read and the bounds arm is what stops the segment being read off the end
    # of the split.
    check contentAddressedRoot(storeRoot / "prefixes").len == 0
    check contentAddressedRoot(storeRoot / "prefixes" / "bash").len == 0

    # A ROOT OF `/` EXEMPTS NOTHING AT ALL, including paths that ARE named
    # like realizations — which is stronger than `reproStoreRootPath`'s own
    # comment claims for it, and is the behaviour worth pinning because it is
    # the safe direction. `resolveStoreRoot` may legitimately answer `/`; the
    # trailing-slash strip turns that into the empty string, and the arm that
    # refuses an empty root is the only thing between that and
    # `startsWith(root & "/")` matching every absolute path on the machine.
    putEnv(StoreRootEnvVar, "/")
    checkpoint("root=/: inside=[" & contentAddressedRoot(insideTool) &
      "] elsewhere=[" & contentAddressedRoot(elsewhereTool) & "]")
    check contentAddressedRoot(insideTool).len == 0
    check contentAddressedRoot(elsewhereTool).len == 0
    check keyedOnContentAddressedToolRoot(seed, [insideTool]) == seed

    # A ROOT THAT CANNOT BE RESOLVED AT ALL is the same answer, not a raised
    # exception. `resolveStoreRoot` RAISES a `StoreError` when it falls back to
    # the per-user default and neither `$XDG_CACHE_HOME` nor `$HOME` is set,
    # and this predicate runs inside `action()` for every edge in the graph
    # and once per `PATH` entry of every one of them. Letting that escape
    # would turn an unset variable into a build failure instead of into "this
    # path is under no store root", which is the same answer for the same
    # reason as every other line in this case.
    let previousXdg = getEnv("XDG_CACHE_HOME")
    let previousHome = getEnv("HOME")
    var unresolved = ""
    try:
      delEnv(StoreRootEnvVar)
      delEnv("XDG_CACHE_HOME")
      delEnv("HOME")
      unresolved = contentAddressedRoot(insideTool)
    except CatchableError as e:
      unresolved = "<raised " & $e.name & ">"
    finally:
      if previousHome.len > 0: putEnv("HOME", previousHome)
      if previousXdg.len > 0: putEnv("XDG_CACHE_HOME", previousXdg)
    checkpoint("unresolvable store root: [" & unresolved & "]")
    check unresolved.len == 0

  test "a store root reached through PATH or NODE_PATH is elided too":
    ## `argv[0]` IS NOT THE ONLY WAY A ROOT GETS SUBTRACTED. `toolInputRoots`
    ## also reads `PATH` and `NODE_PATH` out of the action's DECLARED
    ## environment, and the soundness argument for those two is different from
    ## the one for `argv[0]`: no `keyedOnContentAddressedToolRoot` covers them,
    ## `keyedOnActionEnvironment` does — it mixes every declared name AND
    ## value, so a value that yields a root here is a value that is in the key
    ## there. That claim was written down and graded by nothing; every fixture
    ## in this file until now put its store root in `argv[0]`.
    ##
    ## `argv[0]` here is the host's ordinary `/bin/sh`, under no
    ## content-addressed root at all, so the `argv[0]` arm contributes nothing
    ## and the two roots below can only be subtracted through the environment.
    ##
    ## RULE 7 IS ASSERTED IN BOTH DIRECTIONS, which is what keeps this case
    ## from passing vacuously. "Not in the recorded inputs" is also satisfied
    ## by the monitor never having seen the read at all — so the monitor's own
    ## set is asserted to CONTAIN each path before the record's set is asserted
    ## not to.
    let repoRoot = findRepoRoot()
    if ccPath().len == 0:
      skip()
    else:
      let f = makeFixture()
      defer: removeDir(f.root)

      let storeRoot = f.root / "store"
      var digestP: PrefixIdBytes
      var digestN: PrefixIdBytes
      for i in 0 ..< 32:
        digestP[i] = byte(0xE0 or (i and 0x0F))
        digestN[i] = byte(0xF0 or (i and 0x0F))
      let dirP = storeRoot / prefixRelativePath("toolpath", "1.0", digestP)
      let dirN = storeRoot / prefixRelativePath("nodepath", "1.0", digestN)
      createDir(dirP / "bin")
      createDir(dirN / "lib")
      let readP = dirP / "bin" / "data"
      let readN = dirN / "lib" / "data"
      writeFile(readP, "path-root\n")
      writeFile(readN, "node-root\n")

      let previousStoreRoot = getEnv(StoreRootEnvVar)
      putEnv(StoreRootEnvVar, storeRoot)
      defer:
        if previousStoreRoot.len > 0: putEnv(StoreRootEnvVar, previousStoreRoot)
        else: delEnv(StoreRootEnvVar)

      # THE DENOMINATOR for the elision: these two really are recognised
      # roots, and they are two DIFFERENT ones, so neither assertion below can
      # be satisfied by the other's subtraction.
      check contentAddressedRoot(readP) == dirP
      check contentAddressedRoot(readN) == dirN
      check dirP != dirN

      let log = f.logPath("env-roots")
      # THE FIRST DECLARED ENTRY IS NEITHER OF THE TWO NAMES, and that is
      # load-bearing rather than decoration. `envValue` walks `action.env`
      # looking for `<name>=`; with an unrelated variable in front, a lookup
      # that returned the first entry regardless of its name would answer
      # `EXECDEP_ROOTS=`'s value for both `PATH` and `NODE_PATH` and subtract
      # nothing. Put `PATH` first and that mistake is invisible for `PATH`.
      let act = action("execdep/env-roots",
        ["/bin/sh", "-c",
         "cat " & readP & " " & readN & " > /dev/null; " &
         f.helperPath & " " & log],
        cwd = f.workRoot,
        inputs = [],
        outputs = [],
        env = ["EXECDEP_ROOTS=env-roots",
               "PATH=" & dirP / "bin" & PathSep & f.childPath(),
               "NODE_PATH=" & dirN / "lib"],
        cacheable = true,
        weakFingerprint = weak("execdep/env-roots"),
        actionCachePolicy = ffpHybrid,
        dependencyPolicy = automaticMonitorGatheringPolicy(),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())

      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let first = runBuild(graph([act]), config)
      let r0 = first.byId(act.id)
      checkpoint("env-roots first: status=" & $r0.status &
        " stderr=" & r0.stderr & " reads=" & $r0.evidence.monitorReads.len)
      check r0.status == asSucceeded
      check r0.launched
      check f.runCount("env-roots") == 1

      # THE MONITOR SAW BOTH READS. Without this the two `not anyIt` below
      # would be satisfied by an action that never opened the files.
      let sawP = r0.evidence.monitorReads.anyIt(it == readP)
      let sawN = r0.evidence.monitorReads.anyIt(it == readN)
      checkpoint("monitor saw: PATH root read=" & $sawP &
        " NODE_PATH root read=" & $sawN)
      check sawP
      check sawN

      # ... AND THE RECORD CARRIES NEITHER, because both live under a
      # content-addressed root the declared environment names.
      let inputs = f.recordedInputs(act)
      checkpoint("env-roots recorded inputs: " & $inputs.len &
        "; under the PATH root: " &
        $inputs.countIt(it.path.startsWith(dirP & "/")) &
        "; under the NODE_PATH root: " &
        $inputs.countIt(it.path.startsWith(dirN & "/")))
      # The edge published something real — the helper is a mutable class-2
      # input of its own — so "nothing under either root" is a statement about
      # the elision rather than about an empty record.
      check inputs.len > 0
      check inputs.anyIt(it.path == f.helperPath)
      check not inputs.anyIt(it.path.startsWith(dirP & "/"))
      check not inputs.anyIt(it.path.startsWith(dirN & "/"))

  test "swapping the PROGRAM inside one derivation also re-runs the edge":
    ## THE GRANULARITY CASE, and it was a live hit rather than a hypothetical.
    ## `cacheInputPaths` subtracts at the ROOT, so the root must be in the key
    ## (rule 7) — but the first version of the mix stopped THERE, on the
    ## reasoning that keying on more "would key on something the elision does
    ## not bound". That has the argument inverted: keying on more than you
    ## elide is the safe direction. MEASURED (2026-09-09) before the repair,
    ## one coreutils derivation, `argv[0]` swapped `bin/cat` -> `bin/head`:
    ## **`cdHit`, `launched = false`**. One derivation, two programs, one cache
    ## entry.
    ##
    ## A derivation holding two programs with DIFFERENT observable behaviour is
    ## what makes the case legible: `cat` and `head` on a 12-line file produce
    ## different stdout, so "the same entry was served" is visible in the
    ## result and not only in the decision.
    let repoRoot = findRepoRoot()
    let progs =
      if ccPath().len == 0: newSeq[string]()
      else: coreutilsPrograms(monitorTools(repoRoot).shim)
    if progs.len < 2:
      skip()
    else:
      let catPath = progs[0]
      let headPath = progs[1]
      # THE DENOMINATOR for this case: one root, two programs.
      check contentAddressedRoot(catPath) == contentAddressedRoot(headPath)
      check contentAddressedRoot(catPath).len > 0

      let f = makeFixture()
      defer: removeDir(f.root)
      let src = f.workRoot / "lines.txt"
      var body = ""
      for i in 1 .. 12:
        body.add("line-" & $i & "\n")
      writeFile(src, body)

      proc programEdge(prog: string): BuildAction =
        ## ONE id, ONE argument; only the PROGRAM changes, and both live under
        ## the same store root. Reading a workspace file gives the edge a
        ## genuine class-2 input, so `gradeKeyedInputSet` does not decide the
        ## case before the property under test gets a turn.
        f.monitoredEdge("execdep/program", [prog, src])

      let edgeCat = programEdge(catPath)
      let edgeHead = programEdge(headPath)
      checkpoint("weak(cat)=" & toHex(edgeCat.weakFingerprint.bytes) &
        " weak(head)=" & toHex(edgeHead.weakFingerprint.bytes))
      check edgeCat.weakFingerprint != edgeHead.weakFingerprint

      let config = monitoredConfig(repoRoot, f.cacheRoot)

      let first = runBuild(graph([edgeCat]), config)
      let r0 = first.byId(edgeCat.id)
      checkpoint("cat first: status=" & $r0.status & " stderr=" & r0.stderr)
      check r0.status == asSucceeded
      check r0.launched
      check r0.stdout.contains("line-12")

      let warm = runBuild(graph([edgeCat]), config)
      checkpoint("cat warm: decision=" & $warm.byId(edgeCat.id).cacheDecision)
      check warm.byId(edgeCat.id).cacheDecision in ReuseDecisions
      check not warm.byId(edgeCat.id).launched

      let swapped = runBuild(graph([edgeHead]), config)
      let r1 = swapped.byId(edgeHead.id)
      checkpoint("after the program swap: decision=" & $r1.cacheDecision &
        " launched=" & $r1.launched & " stdout=" & r1.stdout)
      check r1.cacheDecision notin ReuseDecisions
      check r1.launched
      # `head` defaults to ten lines, so serving `cat`'s entry would have
      # returned the whole file.
      check not r1.stdout.contains("line-12")

      # ... and going back to `cat` serves `cat`'s own record, so this is a
      # re-key and not a blanket invalidation.
      let backToCat = runBuild(graph([edgeCat]), config)
      checkpoint("back to cat: decision=" &
        $backToCat.byId(edgeCat.id).cacheDecision)
      check backToCat.byId(edgeCat.id).cacheDecision in ReuseDecisions
      check not backToCat.byId(edgeCat.id).launched

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
    # THE ROOT IS IN THE KEY BECAUSE RULE 7 REQUIRES IT, AND THE PATH IS IN
    # THE KEY BECAUSE NOTHING FORBIDS IT. `cacheInputPaths` subtracts at the
    # ROOT, so the root must be in the key or the elision drops what the key
    # does not carry. That bounds the key from BELOW. It says nothing about
    # the other direction: keying on MORE than the elision drops is always
    # safe, because every subtracted path is still covered by the root
    # component, and it is the ONLY way to tell two programs of one
    # derivation apart. The first version of this assertion pinned the root
    # ALONE and gave the reason as "splitting them would key on something the
    # elision does not bound" — which has the argument inverted, and cost a
    # real hit: MEASURED (2026-09-09), one coreutils derivation with `argv[0]`
    # swapped `bin/cat` -> `bin/head`, `cdHit`, `launched = false`.
    #
    # Two binaries under one store root are therefore TWO key components ...
    let sameRootOtherProgram = keyedOnContentAddressedToolRoot(digest,
      ["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bash-5.2p26/bin/bash"])
    check sameRootOtherProgram != a
    check sameRootOtherProgram != digest
    # ... while the ROOT still participates, so the same program name under
    # two different derivations is still two keys. Without this the mix would
    # have degenerated into "the path", and the root's own contribution — the
    # half rule 7 actually demands — would be untested.
    check keyedOnContentAddressedToolRoot(digest,
      ["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x-1.0/bin/sh"]) !=
      keyedOnContentAddressedToolRoot(digest,
        ["/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-x-1.0/bin/sh"])

suite "which argument is the image the action executes":
  ## `executedImageArgvIndex` is the single answer three consumers ask for —
  ## the elision (`toolInputRoots`), the key mix
  ## (`keyedOnContentAddressedToolRoot`) and the launcher's root-image fold
  ## (`executedToolImagePath`). Until this suite existed NOTHING in the tree
  ## referenced it outside the engine, so its behaviour was graded only
  ## indirectly, through edges whose payloads happened to contain no `--`.
  ##
  ## THE DEFECT IT WAS HIDING. `monitorPayloadArgIndex` located the payload by
  ## scanning the WHOLE argv for the LAST `--`. `monitoredAction` prepends
  ## `<repro> internal io monitor … --`, so for any payload carrying a `--` of
  ## its own the answer was the argument after the ACTION's separator instead
  ## of the wrapper's. MEASURED (2026-09-09) on the production key builder,
  ## payload `/usr/bin/env runner -- /nix/store/…-data-1.0/input.txt`:
  ##
  ##     UNWRAPPED  index=0   -> /usr/bin/env
  ##     WRAPPED    index=12  -> /nix/store/…-data-1.0/input.txt
  ##
  ## The elision then dropped every read under a root the weak fingerprint
  ## carries nothing about — the wrapper argv is composed long after that
  ## fingerprint is computed — which is
  ## Dependency-Observation-Attribution.md rule 9 in a new shape, introduced
  ## by the commit that closed the old one.
  ##
  ## THE PROPERTY, stated once and applied to every shape: wrapping an argv
  ## for the monitor must not change WHICH argument is the tool. A payload's
  ## own `--` is the action's business and belongs to nobody upstream.

  const WrapperPrefix = @["/usr/bin/repro", "internal", "io", "monitor",
                          "--depfile", "/tmp/d.iomon",
                          "--interest", "file,proc,lib", "--"]

  proc bothIndexes(payload: seq[string]):
      tuple[unwrapped, wrapped: int, unwrappedTool, wrappedTool: string] =
    let wrapped = WrapperPrefix & payload
    result.unwrapped = executedImageArgvIndex(payload)
    result.wrapped = executedImageArgvIndex(wrapped)
    result.unwrappedTool =
      if result.unwrapped >= 0: payload[result.unwrapped] else: "<none>"
    result.wrappedTool =
      if result.wrapped >= 0: wrapped[result.wrapped] else: "<none>"

  test "a payload carrying its own `--` still names the payload's argv[0]":
    ## The three real shapes a build graph produces, plus the one the
    ## measurement above used. Each names a DIFFERENT tool so a scan that
    ## collapsed to a constant would be visible.
    let shapes = @[
      ("cargo",
       @["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-cargo-1.0/bin/cargo",
         "test", "--", "--nocapture", "--test-threads=1"]),
      ("sh -c",
       @["/bin/sh", "-c", "run_it \"$@\"", "--",
         "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-data-1.0/in.txt"]),
      ("git",
       @["/usr/bin/git", "log", "--oneline", "--",
         "/nix/store/cccccccccccccccccccccccccccccccc-src-1.0/f.c"]),
      ("env",
       @["/usr/bin/env", "runner", "--",
         "/nix/store/dddddddddddddddddddddddddddddddd-data-1.0/in.txt"])
    ]
    for (name, payload) in shapes:
      let r = bothIndexes(payload)
      checkpoint(name & ": unwrapped index=" & $r.unwrapped & " -> " &
        r.unwrappedTool & "; wrapped index=" & $r.wrapped & " -> " &
        r.wrappedTool)
      # The tool is `argv[0]` of the payload in every one of these ...
      check r.unwrapped == 0
      # ... and the wrapper must not move the answer to a different string.
      check r.wrappedTool == r.unwrappedTool
      # The wrapped index is the payload's position, which is what makes the
      # equality above a statement about the SCAN and not about two copies of
      # one string that happen to match.
      check r.wrapped == WrapperPrefix.len

  test "a payload with no `--` of its own is unaffected":
    ## The regression guard for the shapes that always worked. A fix that
    ## simply stopped scanning would pass the case above and fail here.
    let r = bothIndexes(@["/usr/bin/cc", "-c", "a.c", "-o", "a.o"])
    checkpoint("unwrapped=" & $r.unwrapped & " wrapped=" & $r.wrapped)
    check r.unwrapped == 0
    check r.wrapped == WrapperPrefix.len
    check r.wrappedTool == "/usr/bin/cc"

  test "an argv that only RESEMBLES the wrapper is an ordinary command":
    ## THE FOUR TOKENS THAT SAY "THIS IS THE ENGINE'S OWN WRAPPER", one
    ## witness per token plus one for the length, because the tokens are a
    ## conjunction and a conjunction is graded one conjunct at a time.
    ##
    ## The cost of getting any of them wrong runs in both directions and both
    ## are bad. Too permissive, and an ordinary command whose arguments happen
    ## to read `… io monitor … -- …` has its `argv[0]` mistaken for a
    ## launcher: the edge is then keyed on an argument the recipe chose rather
    ## than on the program it runs, and the reads under the real tool's root
    ## are elided against a root nothing keyed. Too strict, and a real wrapper
    ## is not recognised, `argv[0]` is the `repro` binary, and the elision
    ## drops everything beside it in the store.
    ##
    ## The same four tokens are checked TWICE — once in
    ## `monitorPayloadArgIndex`, which locates the payload, and once in
    ## `executedImageArgvIndex`, which decides that a monitor-shaped argv with
    ## no locatable payload names NOTHING rather than index 0. Both copies are
    ## live and each fails differently, so each witness below is exercised
    ## against a long argv (which reaches the first) and the verdicts are
    ## stated as the ANSWER, which is where the two agree.
    ##
    ## ORDER MATTERS here for the reason it matters in the store-alias case
    ## above: a `check` failure continues the loop, an EXCEPTION ends the case.
    ## The last two rows are the ones that raise when a bounds arm is deleted
    ## (`argv[1]` on a one-element argv), so they come last and everything
    ## before them is graded as wrong ANSWERS first.
    let nearMisses = @[
      ("argv[1] is not `internal`",
       @["/usr/bin/env", "repro", "io", "monitor", "--depfile", "d", "--",
         "/bin/sh"], 0),
      ("argv[2] is not `io`",
       @["/usr/bin/repro", "internal", "cache", "monitor", "--depfile", "d",
         "--", "/bin/sh"], 0),
      ("argv[3] is not `monitor`",
       @["/usr/bin/repro", "internal", "io", "record", "--depfile", "d", "--",
         "/bin/sh"], 0),
      # SHORTER THAN THE CANONICAL WRAPPER. `repro internal io monitor
      # --depfile <f> -- <cmd>` is eight arguments at its shortest, so a
      # four-token prefix with a `--` after it is not a wrapper this engine
      # composed. It is monitor-SHAPED, though, so the answer is "no image"
      # rather than "argv[0]" — naming `/usr/bin/repro` here would key the
      # edge on the engine binary.
      ("monitor-shaped but shorter than the canonical wrapper",
       @["/usr/bin/repro", "internal", "io", "monitor", "--", "/bin/sh"], -1),
      # TOO SHORT TO CARRY THE FOUR TOKENS AT ALL. Reading `argv[1]` of this
      # raises, which is why the length is tested before the tokens rather
      # than beside them.
      ("a one-argument command", @["/bin/true"], 0)]
    for (name, argv, expected) in nearMisses:
      let got = executedImageArgvIndex(argv)
      checkpoint(name & ": [" & argv.join(" ") & "] -> " & $got &
        " (expected " & $expected & ")")
      check got == expected

  test "the key and the elision move together on a wrapped argv":
    ## THE CONSEQUENCE, not just the index. `keyedOnContentAddressedToolRoot`
    ## and `toolInputRoots` both read this one function, so naming the wrong
    ## argument keys on one root while eliding another. Asking the key builder
    ## directly is the cheapest statement of "they agree".
    let digest = weakFingerprintFromText("execdep/argv-index")
    let payload = @["/bin/sh", "-c", "run",
                    "--", "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-d-1.0/x"]
    # `/bin/sh` is under no content-addressed root, so the mix is the
    # IDENTITY — and it must stay the identity through the wrapper. Before the
    # repair the wrapped form keyed on the store path after the action's own
    # `--` instead.
    check keyedOnContentAddressedToolRoot(digest, payload) == digest
    check keyedOnContentAddressedToolRoot(digest, WrapperPrefix & payload) ==
      digest

  test "a monitor-shaped argv whose payload cannot be located names nothing":
    ## `-1`, not `0`. Index 0 on a wrapper argv is the ENGINE'S OWN binary,
    ## and naming it would key the edge on reprobuild and elide the reads of
    ## everything beside it in the store.
    check executedImageArgvIndex(@["/usr/bin/repro", "internal", "io",
      "monitor", "--depfile", "/tmp/d.iomon", "--interest", "all"]) == -1
    check executedImageArgvIndex(@[]) == -1
    # A trailing `--` with nothing after it is the same "cannot be located".
    check executedImageArgvIndex(WrapperPrefix) == -1

    # ... AND THE TWO CONSUMERS MUST SURVIVE THAT ANSWER, not just receive it.
    # `-1` is a legal answer here, so both the key mix and the elision have to
    # treat it as "no image" rather than index `argv` with it. The key mix runs
    # inside `action()`, so getting this wrong raises while the graph is being
    # BUILT — before any edge has run, with no action to attribute it to.
    let unlocatable = @["/usr/bin/repro", "internal", "io", "monitor",
                        "--depfile", "/tmp/d.iomon", "--interest", "all"]
    let seed = weakFingerprintFromText("execdep/unlocatable-image")
    check keyedOnContentAddressedToolRoot(seed, unlocatable) == seed
    # The elision's side of the same answer: an action whose image cannot be
    # named subtracts NOTHING, so an observed read survives into the key. The
    # read is under a real `/nix/store` root on purpose — it is exactly what
    # WOULD be subtracted if this returned index 0 and found the `repro`
    # binary there.
    let noImage = action("execdep/unlocatable-image", unlocatable,
      cwd = getCurrentDir(),
      inputs = [],
      outputs = [],
      cacheable = false,
      weakFingerprint = seed,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    const observed = "/nix/store/ffffffffffffffffffffffffffffffff-d-1.0/x"
    let keyed = noImage.cacheInputPaths(
      PathSetEvidence(monitorReads: @[observed]))
    checkpoint("unlocatable image, keyed inputs: " & $keyed)
    check keyed == @[observed]
