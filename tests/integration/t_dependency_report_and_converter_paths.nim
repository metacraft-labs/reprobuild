import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_core/paths as corepaths
import repro_depfile
import repro_hash
import repro_runquota

proc q(value: string): string =
  quoteShell(value)

proc runShell(command: string; cwd = getCurrentDir()): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  check res.code == 0
  if res.code != 0:
    checkpoint(res.output)
  res.output

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process), socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  let socketPath = "/tmp/repro-m13-rq-" & $getCurrentProcessId() & ".sock"
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "16000",
    "--memory-bytes", "17179869184"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc writeFixture(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

proc escapeDepPath(path: string): string =
  for ch in path:
    case ch
    of ' ':
      result.add("\\ ")
    of '\\':
      result.add("\\\\")
    of ':':
      result.add("\\:")
    else:
      result.add(ch)

proc fixtureMain(args: seq[string]) =
  if args.len < 2:
    quit 64
  case args[1]
  of "native":
    if args.len != 8:
      quit 64
    let src = args[2]
    let headerA = args[3]
    let headerB = args[4]
    let output = args[5]
    let depfile = args[6]
    let aliasOutput = args[7]
    writeFixture(output,
      "native\n" & readFile(src) & readFile(headerA) & readFile(headerB))
    writeFixture(depfile,
      escapeDepPath(output) & " " & escapeDepPath(aliasOutput) & ": " &
      escapeDepPath(src) & " \\\n  " &
      escapeDepPath(headerA) & " " & escapeDepPath(headerB) & "\n")
  of "custom":
    if args.len != 6:
      quit 64
    let input = args[2]
    let output = args[3]
    let customDeps = args[4]
    let mode = args[5]
    writeFixture(output, "custom\n" & readFile(input))
    writeFixture(customDeps, mode & "\ninput\t" & input & "\n")
  of "missing-report":
    if args.len != 3:
      quit 64
    writeFixture(args[2], "missing report target completed\n")
  of "malformed-report":
    if args.len != 4:
      quit 64
    writeFixture(args[2], "malformed report target completed\n")
    writeFixture(args[3], "this line has no colon\n")
  else:
    quit 64

proc converterMain(args: seq[string]) =
  if args.len != 3:
    quit 64
  let input = args[1]
  let output = args[2]
  let lines = readFile(input).splitLines()
  if lines.len == 0:
    quit 65
  case lines[0]
  of "ok":
    var payload = "repro-pathset-v1\n"
    for i in 1 ..< lines.len:
      if lines[i].len > 0:
        payload.add(lines[i] & "\n")
    writeFixture(output, payload)
  of "bad-output":
    writeFixture(output, "not a path set\n")
  of "fail":
    quit 66
  else:
    quit 67

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("m13.integration." & name)

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

proc cacheRecordsSize(cacheRoot: string): int =
  let path = cacheRoot / "action-cache" / "action-results.records"
  if not fileExists(path):
    return 0
  int(getFileSize(path))

proc reportPolicy(formatName, reportPath: string): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(formatName),
        outputs: @[ExpectedDependencyFile(
          logicalName: "deps",
          path: reportPath,
          required: true)],
        completeness: decComplete)
    ])

proc converterPolicy(app, workRoot, customPath, convertedPath: string):
    DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgPostBuildConverter,
    completeness: decComplete,
    postBuildConverters: @[
      PostBuildDependencyConverterSpec(
        converterProcess: directProcess(
          corepaths.normalizedPath(app),
          ["fixture-converter", customPath, convertedPath],
          corepaths.normalizedPath(workRoot)),
        inputs: @[ExpectedDependencyFile(
          logicalName: "custom-deps",
          path: customPath,
          required: true)],
        outputs: @[ExpectedDependencyFile(
          logicalName: "path-set",
          path: convertedPath,
          required: true)],
        outputKind: dcoReproPathSet,
        outputFormatName: DependencyFormatName(ReproPathSetFormatName),
        completeness: decComplete)
    ])

proc buildOne(action: BuildAction; cacheRoot, app: string): ActionResult =
  let buildResult = runBuild(graph([action]), BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: app,
    maxParallelism: 4'u32,
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024))
  check buildResult.results.len == 1
  buildResult.results[0]

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-action":
    fixtureMain(params)
    quit 0
  if params.len > 0 and params[0] == "fixture-converter":
    converterMain(params)
    quit 0
  if params.len > 0 and params[0] == "__repro-runquota-helper":
    quit runRunQuotaHelperCli(params[1 .. ^1])

suite "integration_dependency_report_and_converter_paths":
  test "recognized depfiles and converters feed cache invalidation":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m13-dependency-reports", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)

    let src = workRoot / "src" / "main.c"
    let headerA = workRoot / "include" / "space header.h"
    let headerB = workRoot / "include" / "back\\slash.h"
    let nativeOut = workRoot / "native" / "out.txt"
    let nativeAlias = workRoot / "native" / "alias out.txt"
    let nativeDep = workRoot / "native" / "out.d"
    writeFixture(src, "src v1\n")
    writeFixture(headerA, "header a v1\n")
    writeFixture(headerB, "header b v1\n")

    proc nativeAction(): BuildAction =
      action("native-depfile", [app, "fixture-action", "native",
        src, headerA, headerB, nativeOut, nativeDep, nativeAlias],
        cwd = workRoot,
        inputs = [src],
        outputs = ["native/out.txt"],
        cacheable = true,
        weakFingerprint = weak("native"),
        dependencyPolicy = reportPolicy(MakeDepfileFormatName, "native/out.d"),
        commandStatsId = "m13-native")

    var native = buildOne(nativeAction(), cacheRoot, app)
    check native.status == asSucceeded
    check native.launched
    check native.evidence.depfileInputs.find(headerA) >= 0
    check native.evidence.depfileInputs.find(headerB) >= 0
    let nativeV1 = readFile(nativeOut)

    native = buildOne(nativeAction(), cacheRoot, app)
    check native.status in {asCacheHit, asUpToDate}
    check not native.launched
    check readFile(nativeOut) == nativeV1

    writeFixture(headerA, "header a v2\n")
    removeIfExists(nativeOut)
    native = buildOne(nativeAction(), cacheRoot, app)
    check native.status == asSucceeded
    check native.launched
    check readFile(nativeOut).contains("header a v2")

    let customInput = workRoot / "custom" / "input.txt"
    let customOut = workRoot / "custom" / "out.txt"
    let customDeps = "custom/deps.custom"
    let convertedDeps = "custom/deps.rpset"
    writeFixture(customInput, "custom v1\n")

    proc customAction(mode: string): BuildAction =
      action("custom-converter", [app, "fixture-action", "custom",
        customInput, customOut, workRoot / customDeps, mode],
        cwd = workRoot,
        outputs = ["custom/out.txt"],
        cacheable = true,
        weakFingerprint = weak("custom"),
        dependencyPolicy = converterPolicy(app, workRoot, customDeps, convertedDeps),
        commandStatsId = "m13-custom")

    var custom = buildOne(customAction("ok"), cacheRoot, app)
    check custom.status == asSucceeded
    check custom.launched
    check custom.evidence.monitorReads.find(customInput) >= 0
    let customV1 = readFile(customOut)

    custom = buildOne(customAction("ok"), cacheRoot, app)
    check custom.status in {asCacheHit, asUpToDate}
    check not custom.launched
    check readFile(customOut) == customV1

    writeFixture(customInput, "custom v2\n")
    removeIfExists(customOut)
    custom = buildOne(customAction("ok"), cacheRoot, app)
    check custom.status == asSucceeded
    check custom.launched
    check readFile(customOut).contains("custom v2")

    let failCacheRoot = tempRoot / ".repro-fail-cache"
    let beforeFailures = cacheRecordsSize(failCacheRoot)
    let missingDep = buildOne(action("missing-report",
      [app, "fixture-action", "missing-report", workRoot / "fail" / "missing.txt"],
      cwd = workRoot,
      outputs = ["fail/missing.txt"],
      cacheable = true,
      weakFingerprint = weak("missing-report"),
      dependencyPolicy = reportPolicy(NinjaDepfileFormatName, "fail/missing.d"),
      commandStatsId = "m13-missing"), failCacheRoot, app)
    check missingDep.status == asFailed
    check missingDep.launched
    check missingDep.stderr.contains("dependency report missing")
    check cacheRecordsSize(failCacheRoot) == beforeFailures

    let malformedDep = buildOne(action("malformed-report",
      [app, "fixture-action", "malformed-report",
        workRoot / "fail" / "malformed.txt", workRoot / "fail" / "malformed.d"],
      cwd = workRoot,
      outputs = ["fail/malformed.txt"],
      cacheable = true,
      weakFingerprint = weak("malformed-report"),
      dependencyPolicy = reportPolicy(MakeDepfileFormatName, "fail/malformed.d"),
      commandStatsId = "m13-malformed"), failCacheRoot, app)
    check malformedDep.status == asFailed
    check malformedDep.stderr.contains("dependency report invalid")
    check cacheRecordsSize(failCacheRoot) == beforeFailures

    let converterFail = buildOne(action("converter-fail",
      [app, "fixture-action", "custom",
        customInput, workRoot / "fail" / "converter.txt",
        workRoot / "fail" / "converter.custom", "fail"],
      cwd = workRoot,
      outputs = ["fail/converter.txt"],
      cacheable = true,
      weakFingerprint = weak("converter-fail"),
      dependencyPolicy = converterPolicy(app, workRoot,
        "fail/converter.custom", "fail/converter.rpset"),
      commandStatsId = "m13-converter-fail"), failCacheRoot, app)
    check converterFail.status == asFailed
    check converterFail.stderr.contains("dependency converter")
    check cacheRecordsSize(failCacheRoot) == beforeFailures

    let converterBad = buildOne(action("converter-bad-output",
      [app, "fixture-action", "custom",
        customInput, workRoot / "fail" / "converter-bad.txt",
        workRoot / "fail" / "converter-bad.custom", "bad-output"],
      cwd = workRoot,
      outputs = ["fail/converter-bad.txt"],
      cacheable = true,
      weakFingerprint = weak("converter-bad-output"),
      dependencyPolicy = converterPolicy(app, workRoot,
        "fail/converter-bad.custom", "fail/converter-bad.rpset"),
      commandStatsId = "m13-converter-bad"), failCacheRoot, app)
    check converterBad.status == asFailed
    check converterBad.stderr.contains("converted dependency report invalid")
    check cacheRecordsSize(failCacheRoot) == beforeFailures
