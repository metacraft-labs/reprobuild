import std/[os, times, unittest]

import repro_build_engine
from repro_test_support import testCaseScratchSlug

when defined(windows):
  import std/winlean

  proc processCpuSeconds(): float =
    var creationTime, exitTime, kernelTime, userTime: FILETIME
    doAssert getProcessTimes(getCurrentProcess(), creationTime, exitTime,
      kernelTime, userTime) != 0
    float(rdFileTime(kernelTime) + rdFileTime(userTime)) / 10_000_000.0

if paramCount() == 1 and paramStr(1) == "--sleep-child":
  sleep(1200)
  quit(0)

let tmpDir = "build" / "test-tmp" / "test_bypass_argv_fidelity" /
  testCaseScratchSlug()

proc resetTmp() =
  if dirExists(tmpDir):
    removeDir(tmpDir)
  createDir(tmpDir)

suite "RunQuota bypass argv fidelity":
  when defined(windows):
    test "scheduler waits without spinning on a direct child":
      resetTmp()
      let cacheRoot = absolutePath(tmpDir / "wait-cache")
      createDir(cacheRoot)

      let buildAction = action(
        "wait-without-spin",
        @[getAppFilename(), "--sleep-child"],
        cacheable = false)
      var config = defaultBuildEngineConfig(cacheRoot)
      config.bypassRunQuota = true
      config.maxParallelism = 1

      let cpuStarted = processCpuSeconds()
      let wallStarted = epochTime()
      let buildResult = runBuild(graph([buildAction]), config)
      let cpuElapsed = processCpuSeconds() - cpuStarted
      let wallElapsed = epochTime() - wallStarted

      check buildResult.results.len == 1
      check buildResult.results[0].status == asSucceeded
      check wallElapsed >= 1.0
      check cpuElapsed < 0.5

  test "shell scripts reach the child without cmd expansion":
    resetTmp()
    let workDir = absolutePath(tmpDir / "work")
    let cacheRoot = absolutePath(tmpDir / "cache")
    createDir(workDir)
    createDir(cacheRoot)

    const FilePayload =
      "format=%s\n" &
      "percent=100%literal%\n" &
      "caret=^left^right\n" &
      "slashes=C:\\tmp\\zlib\n" &
      "quoted=\"value\"\n" &
      "tab=left\tright\n"
    const StdoutPayload = "stdout=%s|100%literal%|^caret^|C:\\tmp\\zlib"
    const Script =
      "printf '%s\\n' " &
      "'format=%s' " &
      "'percent=100%literal%' " &
      "'caret=^left^right' " &
      "'slashes=C:\\tmp\\zlib' " &
      "'quoted=\"value\"' " &
      "'tab=left\tright' > argv.txt; " &
      "printf '%s' '" & StdoutPayload & "'"

    let outputPath = workDir / "argv.txt"
    let buildAction = action(
      "argv-fidelity",
      @["sh", "-c", Script],
      cwd = workDir,
      outputs = @[outputPath],
      cacheable = false)
    var config = defaultBuildEngineConfig(cacheRoot)
    config.bypassRunQuota = true
    config.maxParallelism = 1

    let buildResult = runBuild(graph([buildAction]), config)

    check buildResult.results.len == 1
    check buildResult.results[0].status == asSucceeded
    check readFile(outputPath) == FilePayload
    check buildResult.results[0].stdout == StdoutPayload
    check readFile(cacheRoot / "actions" /
      "argv-fidelity.stdout.log") == StdoutPayload
