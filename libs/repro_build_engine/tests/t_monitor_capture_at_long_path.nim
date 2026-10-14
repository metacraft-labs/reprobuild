## A monitored action whose engine cache root is deep enough that the
## private monitor capture's path exceeds Windows' ``MAX_PATH`` still runs,
## still yields monitor evidence, and still publishes its ``.iomon``.
##
## THE DEFECT THIS PINS (reprobuild-specs issue 2026-10-10, "monitor capture
## file is created without a long-path prefix on Windows"). On the wrapped
## monitor path ``monitoredAction`` creates a private scratch capture beside
## the action's published depfile,
##
##   <cacheRoot>/monitor-depfiles/.<action>.iomon.capture-<rand>.tmp
##
## and the scheduler later folds it, renames it over the depfile, or removes
## it. All of that went through plain paths, so once the capture's path passed
## 260 characters the action failed before it ran, with
## ``cannot create monitor capture: The system cannot find the path
## specified.``. CMake's TryCompile scratch trees put the engine cache about
## 200 characters below a project's binary directory, so a build directory
## only ~55 characters deep was enough.
##
## THE GEOMETRY IS CHOSEN, NOT INCIDENTAL. The cache root is padded so that the
## depfile DIRECTORY stays under the 248-character directory limit and the
## published depfile under 260, while the capture beside it is over 260. A
## regression in the capture's create, in the scheduler's fold of it, in the
## flush's rename of it, or in the cleanup's removal of it is therefore what
## turns this red, and not some unrelated directory the engine creates. The
## precondition is asserted, so a later change to the capture's name cannot
## quietly shrink the case below the limit.
##
## NO MOCKS: a real ``runBuild`` on the wrapped (``mhmNever``) monitor path,
## the graph-built ``repro internal io monitor`` driver and shim, and a real
## monitored child (this binary, in fixture mode) that reads one file and
## writes another.
##
## On POSIX the same case runs and is expected to pass trivially; the path
## lengths only bind on Windows.

import std/[os, strutils, unittest]

import repro_build_engine
from repro_core/dependency_gathering import automaticMonitorGatheringPolicy
from repro_core/paths import extendedPath
from repro_test_support import prepareMonitorTools, testCaseScratchSlug

const FixtureFlag = "--long-path-capture-fixture"

if paramCount() == 1 and paramStr(1) == FixtureFlag:
  # The monitored child. Relative paths: the engine runs it in the action's
  # (shallow) working directory, so only the ENGINE's scratch is deep.
  writeFile("out.txt", readFile("in.txt"))
  quit(0)

const
  ActionId = "long-path-capture"
  DepfileDirTarget = 230
    ## Length of ``<cacheRoot>/monitor-depfiles``: under the 248-character
    ## limit ``CreateDirectoryW`` applies to a plain path, so the directory
    ## itself is creatable without the prefix.
  WindowsMaxPath = 260

proc deepCacheRoot(base: string): string =
  ## ``base`` padded with short segments until ``<result>/monitor-depfiles``
  ## is exactly ``DepfileDirTarget`` characters long (or as close above it as
  ## a deep ``base`` allows).
  result = base
  let suffix = DirSep & "monitor-depfiles"
  while result.len + suffix.len < DepfileDirTarget:
    let room = DepfileDirTarget - suffix.len - result.len - 1
    if room <= 0:
      break
    result = result / repeat('p', min(room, 40))

suite "monitor capture at a long path":
  test "a monitored action runs when its capture path exceeds MAX_PATH":
    let base = absolutePath("build" / "test-tmp" /
      "t_monitor_capture_at_long_path" / testCaseScratchSlug())
    if dirExists(extendedPath(base)):
      removeDir(extendedPath(base))
    let work = base / "work"
    createDir(work)
    writeFile(work / "in.txt", "long-path-capture-marker\n")
    let cacheRoot = deepCacheRoot(base / "cache")
    let depfileDir = cacheRoot / "monitor-depfiles"
    let depfile = depfileDir / (ActionId & ".iomon")
    # ".<action>.iomon.capture-<8 random>.tmp", as ``monitoredAction`` names it.
    let captureLen = depfileDir.len + 1 +
      ("." & ActionId & ".iomon.capture-").len + 8 + ".tmp".len
    when defined(windows):
      # The precondition that makes this case about the capture: the
      # directory and the published depfile fit a plain path, the capture
      # does not.
      check depfileDir.len < 248
      check depfile.len < WindowsMaxPath
      check captureLen > WindowsMaxPath
    else:
      discard captureLen

    let tools = prepareMonitorTools(getCurrentDir(),
      getCurrentDir() / "build" / "test-long-path-capture", "long-path-capture")
    putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
    let config = BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: tools.monitorCliPath,
      monitorCliPath: tools.monitorCliPath,
      monitorCliArgs: tools.monitorCliArgs,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true,
      # The wrapped path is the one that creates a private capture; it is the
      # only path on Windows, and is forced here so POSIX runs it too.
      monitorHosting: mhmNever)

    let run = runBuild(graph([action(ActionId,
      @[getAppFilename(), FixtureFlag],
      cwd = work,
      inputs = @["in.txt", getAppFilename()],
      outputs = ["out.txt"],
      cacheable = false,
      dependencyPolicy = automaticMonitorGatheringPolicy(),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())]),
      config)

    check run.results.len == 1
    if run.results.len == 1:
      let res = run.results[0]
      if res.status != asSucceeded:
        echo "status=", res.status, " exit=", res.exitCode,
          " reason=", res.reason
        echo "stderr: ", res.stderr
      check res.status == asSucceeded
      check fileExists(work / "out.txt")
      # The capture was folded: the monitor saw the fixture read its input.
      var sawInput = false
      for path in res.evidence.monitorReads:
        if path.replace('\\', '/').extractFilename == "in.txt":
          sawInput = true
      if not sawInput:
        echo "monitor reads: ", res.evidence.monitorReads.paths
      check sawInput
    # The capture was published over the depfile, and no scratch capture was
    # left behind in the depfile directory.
    check fileExists(extendedPath(depfile))
    var leftovers: seq[string] = @[]
    if dirExists(extendedPath(depfileDir)):
      for kind, path in walkDir(extendedPath(depfileDir)):
        if ".capture-" in path.extractFilename:
          leftovers.add path
    if leftovers.len > 0:
      echo "capture scratch left behind: ", leftovers
    check leftovers.len == 0
    removeDir(extendedPath(base))
