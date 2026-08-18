import std/[os, unittest]

import repro_build_engine
from repro_test_support import testCaseScratchSlug

let tmpDir = "build" / "test-tmp" / "test_bypass_argv_fidelity" /
  testCaseScratchSlug()

proc resetTmp() =
  if dirExists(tmpDir):
    removeDir(tmpDir)
  createDir(tmpDir)

suite "RunQuota bypass argv fidelity":
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
