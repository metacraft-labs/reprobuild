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

import std/[options, os, strtabs, strutils, tables, unittest]

import repro_build_engine
import repro_core
import repro_depfile
import repro_hash
import repro_local_store
import io_mon/writer
from repro_test_support import testCaseScratchSlug

# One scratch root PER CASE, not per binary.
#
# Every case here calls ``resetTmp()``, which is ``removeDir`` +
# ``createDir`` on this path. As a module-level constant that path was
# shared mutable state the moment the runner began executing this binary
# once per case: eight sibling processes then raced on one directory, and
# a completed 6825-case run recorded exactly the two shapes that race
# produces —
#
#   Unhandled exception: Directory not empty
#     Additional info: build/test-tmp/test_tool_identity_env_plumbing/cache-skip
#   Unhandled exception: sqlite3_exec failed (10): disk I/O error
#     (SQL: PRAGMA journal_mode = WAL)
#
# — the first from one case's ``removeDir`` walking a tree another case
# was repopulating, the second from a case's local store being deleted
# out from under an open sqlite handle. All four affected cases pass
# standalone and at ``--threads=1``, which is the signature of shared
# state rather than a logic defect.
#
# ``testCaseScratchSlug`` keys on the ``--run`` name, so the directory
# set stays bounded and stable across runs and whole-binary execution
# (one process, cases strictly sequential) keeps the single shared
# directory it always had. Same remedy as commit 4b82e936 applied to
# t_adapter_chain and its siblings; this binary was missed there.
let TmpDir = "build" / "test-tmp" / "test_tool_identity_env_plumbing" /
  testCaseScratchSlug()

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc pathSeparator(): string =
  when defined(windows): ";"
  else: ":"

proc envValue(env: openArray[string]; name: string): string =
  for entry in env:
    let prefix = name & "="
    if entry.startsWith(prefix):
      return entry[prefix.len .. ^1]

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
                    resolvedExe = "";
                    libDirs: openArray[string] = []): ResolvedToolIdentity =
  ResolvedToolIdentity(
    binDirs: @binDirs,
    resolvedExecutablePath: resolvedExe,
    libDirs: @libDirs)

proc fingerprintForToken(token: string): ContentDigest =
  casDigest(token.toOpenArrayByte(0, token.high),
            domain = hdActionFingerprint)

proc oneAction(actionId: string;
               refs: seq[string];
               fingerprintToken = "default";
               actionEnv: seq[string] = @[];
               argvOverride: seq[string] = @[]): BuildGraph =
  let argv = if argvOverride.len > 0: argvOverride else: stubArgv()
  var act = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakProcess,
    id: actionId,
    deps: @[],
    inputs: @[],
    outputs: @[],
    argv: argv,
    cwd: getCurrentDir(),
    env: actionEnv,
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
  ## copy a pre-built empty-but-valid iomon there (the engine's evidence
  ## read then succeeds with a complete, zero-record dependency set), then
  ## ``exec`` the real action argv unchanged (preserving the inherited
  ## environment the test asserts on). The iomon template is produced via
  ## io-mon's own ``encodeCanonical(@[])`` so the wrapper stays decoupled
  ## from the iomon wire format.
  let dir = cacheRoot / "monitor-cli"
  createDir(dir)
  let rmdfTemplate = dir / "empty.rmdf"
  writeFile(rmdfTemplate, cast[string](encodeCanonical(@[])))
  when defined(windows):
    result = dir / "passthrough-monitor.cmd"
    # ``%1 %2`` are ``--depfile`` and the depfile path; ``%3`` is ``--``;
    # ``%4`` onward is the real argv. Create the depfile's directory, copy
    # the iomon template there, then invoke the real argv.
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

proc makeDepfilePolicy(path: string): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(MakeDepfileFormatName),
        outputs: @[
          ExpectedDependencyFile(
            logicalName: "deps",
            path: path,
            required: false)
        ],
        completeness: decComplete)
    ])

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M9.N Batch B — engine tool-identity env plumbing":

  test "core runtimes stay linkable without entering loader paths":
    resetTmp()
    let nixGlibcLib =
      "/nix/store/0123456789abcdefghijklmnopqrstuv-glibc-2.40/lib"
    let sourceGlibcLib =
      "/work/recipes/packages/source/glibc/.repro/output/install/usr/lib64"
    let federatedGlibcLib =
      "/work/reprobuild-packages/packages/source/glibc/.repro/output/install/usr/lib64"
    let nixPythonLib =
      "/nix/store/abcdefghijklmnopqrstuvwxyz012345-python3-3.13.9/lib"
    let sourcePythonLib =
      "/work/recipes/packages/source/python3/.repro/output/install/usr/lib"
    let sourcePythonBundleLib =
      "/work/recipes/packages/source/python3-with-modules/.repro/output/install/usr/lib"
    let sourceReadlineLib =
      "/work/recipes/packages/source/readline/.repro/output/install/usr/lib"
    let nixReadlineLib =
      "/nix/store/0123456789abcdefghijklmnopqrstuv-readline-8.2p13/lib"
    let compilerBootstrapLib = absolutePath(TmpDir / "compiler-bootstrap-lib")
    createDir(compilerBootstrapLib)
    writeFile(compilerBootstrapLib / "libc.so.6", "synthetic bootstrap libc")
    let dependencyLib = "/nix/store/vutsrqponmlkjihgfedcba9876543210-libfoo-1.0/lib"
    let paths = ResolvedAuxPaths(
      libDirs: @[nixGlibcLib, sourceGlibcLib, federatedGlibcLib, nixPythonLib,
        sourcePythonLib, sourcePythonBundleLib, compilerBootstrapLib,
        sourceReadlineLib, nixReadlineLib, dependencyLib])

    let argvEnv = applyResolvedAuxPathsArgv(
      @["LIBRARY_PATH=/existing/link", "LD_LIBRARY_PATH=/existing/runtime"],
      paths)
    check envValue(argvEnv, "LIBRARY_PATH").split(pathSeparator()) ==
      @[nixGlibcLib, sourceGlibcLib, federatedGlibcLib, nixPythonLib,
        sourcePythonLib,
        sourcePythonBundleLib, compilerBootstrapLib, sourceReadlineLib,
        nixReadlineLib, dependencyLib,
        "/existing/link"]
    check envValue(argvEnv, "LD_LIBRARY_PATH").split(pathSeparator()) ==
      @[dependencyLib, "/existing/runtime"]

    let tableEnv = newStringTable(modeCaseSensitive)
    tableEnv["LIBRARY_PATH"] = "/existing/link"
    tableEnv["LD_LIBRARY_PATH"] = "/existing/runtime"
    applyResolvedAuxPathsTable(tableEnv, paths)
    check tableEnv["LIBRARY_PATH"].split(pathSeparator()) ==
      @[nixGlibcLib, sourceGlibcLib, federatedGlibcLib, nixPythonLib,
        sourcePythonLib,
        sourcePythonBundleLib, compilerBootstrapLib, sourceReadlineLib,
        nixReadlineLib, dependencyLib,
        "/existing/link"]
    check tableEnv["LD_LIBRARY_PATH"].split(pathSeparator()) ==
      @[dependencyLib, "/existing/runtime"]

  when defined(posix):
    test "explicit action loader env wins at process launch":
      resetTmp()
      let cacheRoot = TmpDir / "cache-loader-override"
      createDir(cacheRoot)
      var table = initTable[string, ResolvedToolIdentity]()
      table["readline"] = mockedIdentity(@[],
        libDirs = @["/synthetic/source/readline/lib"])
      let resolver = makeResolver(table)
      let g = oneAction("loader-override", @["readline"],
        fingerprintToken = "loader-override",
        actionEnv = @["LD_LIBRARY_PATH="],
        argvOverride = @["sh", "-c", "printf %s \"$LD_LIBRARY_PATH\""])

      let res = runBuild(g, runnerCfg(cacheRoot, resolver))

      check res.results.len == 1
      check res.results[0].status == asSucceeded
      check readBypassStdout(cacheRoot, "loader-override") == ""

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

  test "explicit tool bins precede transitive bins from earlier refs":
    resetTmp()
    let cacheRoot = TmpDir / "cache-direct-before-transitive"
    createDir(cacheRoot)

    let mesonBin = absolutePath(TmpDir / "mock-store" / "meson" / "bin")
    let basePythonBin =
      absolutePath(TmpDir / "mock-store" / "python3" / "bin")
    let modulePythonBin =
      absolutePath(TmpDir / "mock-store" / "python3-modules" / "bin")
    for path in [mesonBin, basePythonBin, modulePythonBin]:
      createDir(path)
    let executableSuffix = when defined(windows): ".exe" else: ""
    var table = initTable[string, ResolvedToolIdentity]()
    table["meson"] = mockedIdentity(@[mesonBin, basePythonBin],
      resolvedExe = mesonBin / ("meson" & executableSuffix))
    table["python3-with-modules"] =
      mockedIdentity(@[modulePythonBin, basePythonBin],
        resolvedExe = modulePythonBin /
          ("python3-with-modules" & executableSuffix))
    let resolver = makeResolver(table)

    let g = oneAction("direct-before-transitive",
      @["meson", "python3-with-modules"],
      fingerprintToken = "direct-before-transitive")
    let res = runBuild(g, runnerCfg(cacheRoot, resolver))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    let captured = stripPathPrefix(
      readBypassStdout(cacheRoot, "direct-before-transitive"))
    let entries = captured.split(pathSeparator())
    check entries.len >= 3
    check entries[0 .. 2] == @[mesonBin, modulePythonBin, basePythonBin]

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

  test "non-cacheable recognized-report actions execute even when outputs exist":
    resetTmp()
    let cacheRoot = TmpDir / "cache-noncacheable-recognized"
    createDir(cacheRoot)
    let depfilePath = TmpDir / "missing-optional.d"
    let act = action("noncacheable-recognized",
      stubArgv(),
      cwd = getCurrentDir(),
      cacheable = false,
      dependencyPolicy = makeDepfilePolicy(depfilePath),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph(@[act], newSeq[BuildPool]())

    let first = runBuild(g, runnerCfg(cacheRoot, nil))
    check first.results.len == 1
    check first.results[0].status == asSucceeded
    check first.results[0].launched

    let second = runBuild(g, runnerCfg(cacheRoot, nil))
    check second.results.len == 1
    check second.results[0].status == asSucceeded
    check second.results[0].launched
