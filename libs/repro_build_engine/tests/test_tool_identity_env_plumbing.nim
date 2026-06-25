## M9.N Batch B — engine-side tool-identity env plumbing.
##
## Verifies that the engine's new ``ToolIdentityResolver`` closure seam
## fires exactly when:
##
##   * ``BuildAction.toolIdentityRefs`` is non-empty AND
##   * ``BuildEngineConfig.toolIdentityResolver`` is non-nil AND
##   * the resolver returns ``some(ResolvedToolIdentity)`` with at
##     least one non-empty ``binDirs`` entry for the requested ref.
##
## All other combinations leave PATH unchanged.
##
## The action's argv runs a tiny stub that captures the inherited
## PATH into a side-channel file so the test can byte-compare the
## prefix. The stub is the platform shell (``cmd /C`` on Windows,
## ``sh -c`` on POSIX) — no external tool dependencies, no host-PATH
## assumptions.
##
## See ``libs/repro_build_engine/src/repro_build_engine.nim``
## §resolvedToolBinDirs + §launchChildEnv + ``ResolvedToolIdentity`` /
## ``ToolIdentityResolver`` / ``BuildEngineConfig.toolIdentityResolver``
## for the seam under test.

import std/[options, os, strutils, tables, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
import io_mon/writer

const TmpDir = "build/test-tmp/test_tool_identity_env_plumbing"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc pathSeparator(): string =
  when defined(windows): ";"
  else: ":"

proc stubArgv(): seq[string] =
  ## Build a platform-appropriate shell argv that prints ``$PATH``
  ## (``%PATH%`` on Windows) to stdout then exits 0. The bypass-runquota
  ## path captures stdout into ``<cacheRoot>/actions/<id>.stdout.log``
  ## which the test then reads. The stub touches no external binaries
  ## beyond the shell itself, so the test does not depend on
  ## host-PATH content.
  ##
  ## Windows note: ``cmd.exe set PATH`` prints ``PATH=<value>`` to
  ## stdout — the test strips the ``PATH=`` prefix when reading the
  ## stdout log. A single ``set NAME`` invocation avoids the
  ## quoting / pipeline pitfalls of nested ``cmd /C "echo|..."``
  ## wrappers when the engine's bypass path re-wraps the argv with
  ## its own ``cmd /D /C`` redirection.
  when defined(windows):
    @["cmd", "/D", "/C", "set", "PATH"]
  else:
    @["sh", "-c", "printf %s \"$PATH\""]

proc stripPathPrefix(captured: string): string =
  ## Extract the ``PATH=<value>`` line from ``cmd.exe set PATH`` output
  ## (which prints every env var whose name starts with ``PATH``,
  ## including ``PATHEXT``). Return just the ``PATH``'s value. POSIX
  ## stubs print bare PATH so this is a no-op there.
  when defined(windows):
    for raw in captured.splitLines:
      let line = raw.strip()
      if line.startsWith("PATH="):
        return line[5 .. ^1]
    return captured
  else:
    result = captured

proc readBypassStdout(cacheRoot, actionId: string): string =
  let p = cacheRoot / "actions" / (actionId & ".stdout.log")
  if not fileExists(p):
    return ""
  result = readFile(p).strip()

proc makeResolver(table: Table[string, ResolvedToolIdentity]):
    ToolIdentityResolver =
  ## Wrap an in-memory lookup table into the resolver closure shape.
  ## Refs absent from the table resolve to ``none`` — the engine's
  ## "leave PATH alone for this ref" branch.
  ##
  ## M9.R.7: the resolver receives a per-ref ``DepKind`` to route the
  ## materialization cache lookup against the correct platform-tagged
  ## cache key. This test ignores the kind — the env-plumbing
  ## contract under test is invariant across kinds.
  let captured = table
  result = proc(name: string; kind: DepKind): Option[ResolvedToolIdentity]
      {.gcsafe, closure.} =
    if captured.hasKey(name):
      some(captured[name])
    else:
      none(ResolvedToolIdentity)

proc mockedIdentity(binDirs: openArray[string];
                    resolvedExe = ""): ResolvedToolIdentity =
  ResolvedToolIdentity(
    binDirs: @binDirs,
    resolvedExecutablePath: resolvedExe)

proc fingerprintForToken(token: string): ContentDigest =
  casDigest(token.toOpenArrayByte(0, token.high),
            domain = hdActionFingerprint)

proc oneAction(actionId: string;
               refs: seq[string];
               fingerprintToken = "default"): BuildGraph =
  let argv = stubArgv()
  var act = BuildAction(
    kind: bakProcess,
    id: actionId,
    deps: @[],
    inputs: @[],
    outputs: @[],
    argv: argv,
    cwd: getCurrentDir(),
    cacheable: false,
    weakFingerprint: fingerprintForToken(actionId & "|" & fingerprintToken),
    actionCachePolicy: ffpTimestamp,
    cpuMilli: 1000,
    memoryBytes: 0,
    # Automatic monitoring is the spec baseline for opaque tools
    # (Reprobuild-Development M17). This test exercises env plumbing, not
    # the dependency-gathering kind, and the action is already marked
    # ``cacheable: false`` above, so the policy choice doesn't affect what
    # it asserts.
    dependencyPolicy: DependencyGatheringPolicy(
      kind: dgAutomaticMonitor,
      completeness: decComplete),
    toolIdentityRefs: refs)
  graph(@[act], newSeq[BuildPool]())

proc passthroughMonitorCli(cacheRoot: string): string =
  ## The actions in this suite use ``dgAutomaticMonitor`` — automatic
  ## monitoring is the spec baseline for opaque tools
  ## (Reprobuild-Development M17), and an automatic-monitor action with
  ## no monitor CLI wired now FAILS by design (Monitor-Hook-Shim.md:501:
  ## "injection failure MUST fail the monitored action or make it
  ## non-cacheable"). This test is about env plumbing, not monitor
  ## evidence, so it wires a passthrough fake-monitor: parse ``--depfile``,
  ## copy a pre-built empty-but-valid RMDF there (the engine's evidence
  ## read then succeeds with a complete, zero-record dependency set), then
  ## ``exec`` the real action argv unchanged (preserving the inherited
  ## environment the test asserts on). The RMDF template is produced via
  ## io-mon's own ``encodeCanonical(@[])`` so the wrapper stays decoupled
  ## from the RMDF wire format.
  let dir = cacheRoot / "monitor-cli"
  createDir(dir)
  let rmdfTemplate = dir / "empty.rmdf"
  writeFile(rmdfTemplate, cast[string](encodeCanonical(@[])))
  when defined(windows):
    result = dir / "passthrough-monitor.cmd"
    # ``%1 %2`` are ``--depfile`` and the depfile path; ``%3`` is ``--``;
    # ``%4`` onward is the real argv. Create the depfile's directory, copy
    # the RMDF template there, then invoke the real argv.
    writeFile(result,
      "@echo off\r\n" &
      "for %%I in (\"%~2\") do if not exist \"%%~dpI\" mkdir \"%%~dpI\"\r\n" &
      "copy /Y \"" & rmdfTemplate & "\" %~2 >nul\r\n" &
      "%4 %5 %6 %7 %8 %9\r\n")
  else:
    result = dir / "passthrough-monitor.sh"
    writeFile(result,
      "#!/bin/sh\n" &
      "depfile=\"\"\n" &
      "while [ \"$#\" -gt 0 ]; do\n" &
      "  case \"$1\" in\n" &
      "    --depfile) depfile=\"$2\"; shift 2;;\n" &
      "    --) shift; break;;\n" &
      "    *) shift;;\n" &
      "  esac\n" &
      "done\n" &
      "if [ -n \"$depfile\" ]; then\n" &
      "  mkdir -p \"$(dirname \"$depfile\")\"\n" &
      "  cp \"" & rmdfTemplate & "\" \"$depfile\"\n" &
      "fi\n" &
      "exec \"$@\"\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc runnerCfg(cacheRoot: string;
               resolver: ToolIdentityResolver = nil): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.deferLocalOutputBlobs = false
  # Inline-runquota bypass: this test only cares about env plumbing,
  # not RunQuota daemon round-trips. The bypass path layers PATH the
  # same way the daemon path does (via ``launchChildEnv`` ->
  # ``mergeActionEnvWithMsvc`` -> ``envTableFromArgvStyle``), so the
  # assertion surface is identical.
  result.bypassRunQuota = true
  # Wire the passthrough monitor so the ``dgAutomaticMonitor`` actions run
  # (see ``passthroughMonitorCli``); without a monitor CLI they would fail
  # the fail-safe, which is the correct behaviour but not what this suite
  # exercises.
  result.monitorCliPath = passthroughMonitorCli(cacheRoot)
  result.toolIdentityResolver = resolver

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M9.N Batch B — engine tool-identity env plumbing":

  test "PATH is prepended with the resolved bin dir when ref + resolver are set":
    resetTmp()
    let cacheRoot = TmpDir / "cache-plumbed"
    createDir(cacheRoot)

    let mockBin = absolutePath(TmpDir / "mock-store" / "meson" / "bin")
    createDir(mockBin)
    var table = initTable[string, ResolvedToolIdentity]()
    table["meson"] = mockedIdentity(@[mockBin],
      resolvedExe = mockBin / (when defined(windows): "meson.exe" else: "meson"))
    let resolver = makeResolver(table)

    let g = oneAction("plumbed", @["meson"],
      fingerprintToken = "plumbed")
    let res = runBuild(g, runnerCfg(cacheRoot, resolver))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    let captured = stripPathPrefix(readBypassStdout(cacheRoot, "plumbed"))
    check captured.len > 0
    # First entry of PATH must be the mocked bin dir.
    check captured.startsWith(mockBin)
    # Inherited PATH still appears AFTER the prepended bin dir.
    let sep = pathSeparator()
    check captured.contains(sep)

  test "PATH carries no resolver contribution when the action has no refs":
    resetTmp()
    let cacheRoot = TmpDir / "cache-norefs"
    createDir(cacheRoot)

    let suspectBin = absolutePath(TmpDir / "should-not-appear" / "bin")
    var table = initTable[string, ResolvedToolIdentity]()
    table["meson"] = mockedIdentity(@[suspectBin])
    let resolver = makeResolver(table)

    let g = oneAction("norefs", @[],
      fingerprintToken = "norefs")
    let res = runBuild(g, runnerCfg(cacheRoot, resolver))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    let captured = stripPathPrefix(readBypassStdout(cacheRoot, "norefs"))
    # The resolver was set but the action carries no refs: the engine
    # MUST NOT walk the resolver, so the suspect bin dir MUST NOT
    # appear in PATH. (PATH still carries MSVC + host content from
    # ``mergeActionEnvWithMsvc``, which is independent of M9.N Batch B.)
    check captured.len > 0
    check not captured.contains(suspectBin)

  test "PATH carries no resolver contribution when the resolver closure is nil":
    resetTmp()
    let cacheRoot = TmpDir / "cache-noresolver"
    createDir(cacheRoot)

    let g = oneAction("noresolver", @["meson", "gcc"],
      fingerprintToken = "noresolver")
    # No resolver set on the engine config — the engine must skip the
    # PATH-override block even when the action carries refs. The PATH
    # value isn't byte-equal to ``getEnv("PATH")`` because MSVC env
    # is layered on top regardless, but the contract Batch B owns is
    # "no synthetic resolver bin dirs land in PATH when the resolver
    # is nil".
    let res = runBuild(g, runnerCfg(cacheRoot, nil))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    let captured = stripPathPrefix(readBypassStdout(cacheRoot, "noresolver"))
    check captured.len > 0
    # No catalog dir was contributed because no resolver was set.
    check not captured.contains("mock-store")

  test "Multiple refs prepend bin dirs in declaration order":
    resetTmp()
    let cacheRoot = TmpDir / "cache-multi"
    createDir(cacheRoot)

    let mesonBin = absolutePath(TmpDir / "mock-store" / "meson" / "bin")
    let gccBin = absolutePath(TmpDir / "mock-store" / "gcc" / "bin")
    createDir(mesonBin)
    createDir(gccBin)
    var table = initTable[string, ResolvedToolIdentity]()
    table["meson"] = mockedIdentity(@[mesonBin])
    table["gcc"] = mockedIdentity(@[gccBin])
    let resolver = makeResolver(table)

    let g = oneAction("multi", @["meson", "gcc"],
      fingerprintToken = "multi")
    let res = runBuild(g, runnerCfg(cacheRoot, resolver))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    let captured = stripPathPrefix(readBypassStdout(cacheRoot, "multi"))
    let sep = pathSeparator()
    # meson's bin dir is leftmost; gcc's bin dir is to the right of it
    # but BEFORE the inherited PATH.
    let mesonPos = captured.find(mesonBin)
    let gccPos = captured.find(gccBin)
    check mesonPos == 0
    check gccPos > mesonPos
    # The boundary between the two is the platform separator.
    check captured.contains(mesonBin & sep & gccBin)

  test "An unresolved ref is silently skipped, others still contribute":
    resetTmp()
    let cacheRoot = TmpDir / "cache-skip"
    createDir(cacheRoot)

    let mesonBin = absolutePath(TmpDir / "mock-store" / "meson" / "bin")
    createDir(mesonBin)
    var table = initTable[string, ResolvedToolIdentity]()
    table["meson"] = mockedIdentity(@[mesonBin])
    # Note: no entry for "nonexistent" — the resolver returns ``none``
    # for it and the engine MUST leave PATH alone for that ref.
    let resolver = makeResolver(table)

    let g = oneAction("skip", @["nonexistent", "meson"],
      fingerprintToken = "skip")
    let res = runBuild(g, runnerCfg(cacheRoot, resolver))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    let captured = stripPathPrefix(readBypassStdout(cacheRoot, "skip"))
    # meson's bin dir is still prepended (leftmost) — the
    # ``nonexistent`` ref contributed nothing but did NOT block the
    # other refs from contributing.
    check captured.startsWith(mesonBin)
