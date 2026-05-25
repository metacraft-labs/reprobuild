import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_core/paths as corepaths
import repro_depfile
import repro_hash
import repro_runquota

const MonitorPolicyKinds = {
  dgAutomaticMonitor,
  dgRecognizedFormatValidatedByMonitor,
  dgPostBuildConverterValidatedByMonitor
}

const FixtureSource = r"""
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *read_all(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) exit(80);
  char buffer[4096];
  ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
  if (count < 0) exit(81);
  close(fd);
  buffer[count] = '\0';
  char *copy = malloc((size_t)count + 1);
  if (copy == NULL) exit(82);
  memcpy(copy, buffer, (size_t)count + 1);
  return copy;
}

static void write_text(const char *path, const char *text) {
  FILE *file = fopen(path, "w");
  if (file == NULL) exit(83);
  fputs(text, file);
  fclose(file);
}

static void append_text(const char *path, const char *text) {
  FILE *file = fopen(path, "a");
  if (file == NULL) exit(84);
  fputs(text, file);
  fclose(file);
}

static void write_output(const char *mode, const char *path,
                         const char *visible, const char *hidden) {
  FILE *file = fopen(path, "w");
  if (file == NULL) exit(85);
  fprintf(file, "mode=%s\nvisible=%shidden=%s", mode, visible, hidden);
  fclose(file);
}

static void write_depfile(const char *path, const char *output,
                          const char *visible, const char *hidden) {
  FILE *file = fopen(path, "w");
  if (file == NULL) exit(86);
  fprintf(file, "%s: %s %s\n", output, visible, hidden);
  fclose(file);
}

static void write_custom(const char *path, const char *kind,
                         const char *visible, const char *hidden) {
  FILE *file = fopen(path, "w");
  if (file == NULL) exit(87);
  fprintf(file, "%s\ninput\t%s\ninput\t%s\n", kind, visible, hidden);
  fclose(file);
}

static void corrupt_monitor_fragment(void) {
  const char *dir = getenv("REPRO_MONITOR_FRAGMENT_DIR");
  if (dir == NULL || dir[0] == '\0') return;
  char path[4096];
  snprintf(path, sizeof(path), "%s/corrupt.rmdf-frag", dir);
  write_text(path, "not an RMDF fragment");
}

int main(int argc, char **argv) {
  if (argc != 7) return 64;
  const char *mode = argv[1];
  const char *visible_path = argv[2];
  const char *hidden_path = argv[3];
  const char *output_path = argv[4];
  const char *sidecar_path = argv[5];
  const char *marker_path = argv[6];

  char *visible = read_all(visible_path);
  char *hidden = read_all(hidden_path);
  append_text(marker_path, "run\n");
  write_output(mode, output_path, visible, hidden);

  if (strcmp(mode, "depfile") == 0) {
    write_depfile(sidecar_path, output_path, visible_path, hidden_path);
  } else if (strcmp(mode, "custom-ok") == 0) {
    write_custom(sidecar_path, "ok", visible_path, hidden_path);
  } else if (strcmp(mode, "custom-fail") == 0) {
    write_custom(sidecar_path, "fail", visible_path, hidden_path);
  } else if (strcmp(mode, "custom-bad-output") == 0) {
    write_custom(sidecar_path, "bad-output", visible_path, hidden_path);
  } else if (strcmp(mode, "corrupt-fragment") == 0) {
    corrupt_monitor_fragment();
  }

  free(visible);
  free(hidden);
  return 0;
}
"""

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

proc shellCommand(args: openArray[string];
                  env: openArray[(string, string)] = []): string =
  var parts: seq[string] = @[]
  for (name, value) in env:
    parts.add(name & "=" & q(value))
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process),
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  let socketPath = "/tmp/repro-m17-rq-" & $getCurrentProcessId() & ".sock"
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

proc compileFixture(sourcePath, outputPath: string) =
  discard requireSuccess(shellCommand(["cc", sourcePath, "-o", outputPath]))

proc compileNim(repoRoot, sourcePath, outputPath, cacheName: string) =
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
    "--out:" & outputPath,
    sourcePath
  ]), repoRoot)

when defined(macosx) or defined(linux):
  proc compileShim(repoRoot, outputPath: string) =
    var args = @[
      "nim", "c", "--app:lib", "--threads:on", "--verbosity:0", "--hints:off",
      "--nimcache:" & repoRoot / "build" / "nimcache" / "m17-shim",
      "--out:" & outputPath
    ]
    when defined(macosx):
      args.add("--path:" & repoRoot / "libs" / "repro_monitor_hooks" / "src")
      args.add(repoRoot / "libs" / "repro_monitor_shim" / "src" /
        "repro_monitor_shim" / "macos_interpose.nim")
    else:
      args.add(repoRoot / "libs" / "repro_monitor_shim" / "src" /
        "repro_monitor_shim" / "linux_preload.nim")
    discard requireSuccess(shellCommand(args), repoRoot)

  proc prepareMonitorTools(repoRoot, tempRoot: string): tuple[fsSnoop: string;
      shim: string] =
    let binDir = tempRoot / "monitor-bin"
    let libDir = tempRoot / "monitor-lib"
    createDir(binDir)
    createDir(libDir)
    result.fsSnoop = binDir / "repro-fs-snoop"
    result.shim =
      when defined(linux):
        libDir / "librepro_monitor_shim.so"
      else:
        libDir / "librepro_monitor_shim.dylib"
    compileShim(repoRoot, result.shim)
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "m17-repro-fs-snoop")

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
  weakFingerprintFromText("m17.integration." & name)

proc cacheRecordsSize(cacheRoot: string): int =
  let path = cacheRoot / "action-cache" / "action-results.records"
  if not fileExists(path):
    return 0
  int(getFileSize(path))

proc reportPolicy(kind: DependencyGatheringKind;
                  reportPath: string): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: kind,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(MakeDepfileFormatName),
        outputs: @[ExpectedDependencyFile(
          logicalName: "deps",
          path: reportPath,
          required: true)],
        completeness: decComplete)
    ])

proc converterPolicy(app, cwd, customPath, convertedPath: string;
                     kind: DependencyGatheringKind): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: kind,
    completeness: decComplete,
    postBuildConverters: @[
      PostBuildDependencyConverterSpec(
        converterProcess: directProcess(
          corepaths.normalizedPath(app),
          ["fixture-converter", customPath, convertedPath],
          corepaths.normalizedPath(cwd)),
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

proc runOne(action: BuildAction; cacheRoot, app: string;
            monitorCli = ""): BuildRunResult =
  runBuild(graph([action]), BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: app,
    monitorCliPath: monitorCli,
    maxParallelism: 4'u32,
    stdoutLimit: 512 * 1024,
    stderrLimit: 512 * 1024))

proc singleResult(run: BuildRunResult): ActionResult =
  check run.results.len == 1
  run.results[0]

proc traceHasPolicy(run: BuildRunResult; actionId: string;
                    kind: DependencyGatheringKind): bool =
  for event in run.trace:
    if event.actionId == actionId and event.event == "dependency-policy" and
        event.detail == $kind:
      return true

proc addUnique(values: var seq[string]; value: string) =
  if value.len > 0 and values.find(value) < 0:
    values.add(value)

proc evidenceInputs(evidence: PathSetEvidence): seq[string] =
  for path in evidence.declaredInputs:
    result.addUnique(path)
  for path in evidence.depfileInputs:
    result.addUnique(path)
  for path in evidence.monitorReads:
    result.addUnique(path)
  for path in evidence.monitorProbes:
    result.addUnique(path)

proc requirePolicyCase(name, mode: string; policy: DependencyGatheringPolicy;
                       declaredHidden: bool; cacheRoot, workRoot, fixtureBin,
                       app: string; monitorCli = ""; shim = "") =
  let caseDir = workRoot / name
  createDir(caseDir)
  let visible = caseDir / "visible.txt"
  let hidden = caseDir / "hidden.txt"
  let output = caseDir / "out.txt"
  let marker = caseDir / "runs.txt"
  let sidecar =
    if policy.kind in {dgRecognizedFormat, dgRecognizedFormatValidatedByMonitor}:
      caseDir / "deps.d"
    elif policy.kind in {dgPostBuildConverter,
        dgPostBuildConverterValidatedByMonitor}:
      caseDir / "deps.custom"
    else:
      caseDir / "unused.sidecar"
  writeFixture(visible, "visible v1\n")
  writeFixture(hidden, "hidden v1\n")

  let declaredInputs =
    if declaredHidden:
      @[visible, hidden]
    else:
      @[visible]
  let env =
    if shim.len > 0:
      @["REPRO_MONITOR_SHIM_LIB=" & shim]
    else:
      @[]

  proc makeAction(): BuildAction =
    action(name, [fixtureBin, mode, visible, hidden, output, sidecar, marker],
      cwd = caseDir,
      inputs = declaredInputs,
      outputs = ["out.txt"],
      cacheable = true,
      weakFingerprint = weak(name),
      dependencyPolicy = policy,
      commandStatsId = "m17-" & name,
      env = env)

  let before = cacheRecordsSize(cacheRoot)
  let firstRun = runOne(makeAction(), cacheRoot, app, monitorCli)
  let first = firstRun.singleResult()
  if first.status != asSucceeded:
    checkpoint(first.stderr)
  check first.status == asSucceeded
  check first.launched
  check first.cacheDecision == cdMiss
  check first.dependencyPolicyKind == policy.kind
  check traceHasPolicy(firstRun, name, policy.kind)
  check evidenceInputs(first.evidence).find(hidden) >= 0
  if policy.kind in MonitorPolicyKinds:
    check first.monitorDepfilePath.len > 0
    check fileExists(first.monitorDepfilePath)
    check readFile(first.monitorDepfilePath)[0 .. 3] == "RMDF"
  let afterFirst = cacheRecordsSize(cacheRoot)
  check afterFirst > before
  let outputV1 = readFile(output)
  let markerV1 = readFile(marker)

  let second = runOne(makeAction(), cacheRoot, app, monitorCli).singleResult()
  check second.status == asCacheHit
  check not second.launched
  check second.dependencyPolicyKind == policy.kind
  check evidenceInputs(second.evidence).find(hidden) >= 0
  check readFile(output) == outputV1
  check readFile(marker) == markerV1
  check cacheRecordsSize(cacheRoot) == afterFirst

  writeFixture(hidden, "hidden v2\n")
  let thirdRun = runOne(makeAction(), cacheRoot, app, monitorCli)
  let third = thirdRun.singleResult()
  if third.status != asSucceeded:
    checkpoint(third.stderr)
  check third.status == asSucceeded
  check third.launched
  check third.cacheDecision == cdMiss
  check third.dependencyPolicyKind == policy.kind
  check traceHasPolicy(thirdRun, name, policy.kind)
  check readFile(output).contains("hidden=hidden v2")
  check readFile(marker).splitLines().len >= 2
  check cacheRecordsSize(cacheRoot) > afterFirst

proc requireFailureNoPublish(action: BuildAction; cacheRoot, app: string;
                             expected: string; monitorCli = "") =
  let before = cacheRecordsSize(cacheRoot)
  let result = runOne(action, cacheRoot, app, monitorCli).singleResult()
  check result.status == asFailed
  check result.cacheDecision == cdMiss
  if expected.len > 0:
    check result.stderr.contains(expected)
  check cacheRecordsSize(cacheRoot) == before

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-converter":
    converterMain(params)
    quit 0
  if params.len > 0 and params[0] == "__repro-runquota-helper":
    quit runRunQuotaHelperCli(params[1 .. ^1])

suite "integration_scheduler_dependency_gathering_policies":
  test "dependency evidence paths include hash suffixes for sanitized id collisions":
    let cacheRoot = "/tmp/repro-cache"
    let first = dependencyEvidencePath(cacheRoot, "compile:main")
    let second = dependencyEvidencePath(cacheRoot, "compile/main")
    check first != second
    check first.parentDir == cacheRoot / "dependency-evidence"
    check second.parentDir == cacheRoot / "dependency-evidence"
    check first.endsWith(".rbar")
    check second.endsWith(".rbar")

  test "declared, recognized, and converted dependency evidence share cache invalidation":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m17-policy-basic", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let app = getAppFilename()
    let fixtureSource = tempRoot / "policy_fixture.c"
    let fixtureBin = tempRoot / "policy-fixture"
    writeFile(fixtureSource, FixtureSource)
    compileFixture(fixtureSource, fixtureBin)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)

    requirePolicyCase("declared-only", "plain", declaredOnlyPolicy(),
      declaredHidden = true, cacheRoot, workRoot, fixtureBin, app)

    requirePolicyCase("recognized-report", "depfile",
      reportPolicy(dgRecognizedFormat, "deps.d"),
      declaredHidden = false, cacheRoot, workRoot, fixtureBin, app)

    requirePolicyCase("post-build-converter", "custom-ok",
      converterPolicy(app, workRoot / "post-build-converter",
        "deps.custom", "deps.rpset", dgPostBuildConverter),
      declaredHidden = false, cacheRoot, workRoot, fixtureBin, app)

    let failRoot = tempRoot / ".repro-fail-cache"
    let failDir = workRoot / "failures"
    createDir(failDir)
    let visible = failDir / "visible.txt"
    let hidden = failDir / "hidden.txt"
    writeFixture(visible, "visible\n")
    writeFixture(hidden, "hidden\n")

    requireFailureNoPublish(action("missing-recognized-report",
      [fixtureBin, "plain", visible, hidden, failDir / "missing.txt",
        failDir / "missing.d", failDir / "missing.runs"],
      cwd = failDir,
      inputs = [visible],
      outputs = ["missing.txt"],
      cacheable = true,
      weakFingerprint = weak("missing-recognized-report"),
      dependencyPolicy = reportPolicy(dgRecognizedFormat, "missing.d"),
      commandStatsId = "m17-missing-report"), failRoot, app,
      "dependency report missing")

    requireFailureNoPublish(action("converter-failure",
      [fixtureBin, "custom-fail", visible, hidden, failDir / "converter.txt",
        failDir / "converter.custom", failDir / "converter.runs"],
      cwd = failDir,
      inputs = [visible],
      outputs = ["converter.txt"],
      cacheable = true,
      weakFingerprint = weak("converter-failure"),
      dependencyPolicy = converterPolicy(app, failDir,
        "converter.custom", "converter.rpset", dgPostBuildConverter),
      commandStatsId = "m17-converter-failure"), failRoot, app,
      "dependency converter")

    requireFailureNoPublish(action("converter-malformed-output",
      [fixtureBin, "custom-bad-output", visible, hidden,
        failDir / "converter-bad.txt", failDir / "converter-bad.custom",
        failDir / "converter-bad.runs"],
      cwd = failDir,
      inputs = [visible],
      outputs = ["converter-bad.txt"],
      cacheable = true,
      weakFingerprint = weak("converter-malformed-output"),
      dependencyPolicy = converterPolicy(app, failDir,
        "converter-bad.custom", "converter-bad.rpset", dgPostBuildConverter),
      commandStatsId = "m17-converter-malformed"), failRoot, app,
      "converted dependency report invalid")

  when defined(macosx) or defined(linux):
    test "automatic and hybrid monitor policies use real fs-snoop evidence":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m17-policy-monitor", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let app = getAppFilename()
      let fixtureSource = tempRoot / "policy_fixture.c"
      let fixtureBin = tempRoot / "policy-fixture"
      writeFile(fixtureSource, FixtureSource)
      compileFixture(fixtureSource, fixtureBin)
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot)

      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / ".repro-cache"
      createDir(workRoot)

      requirePolicyCase("automatic-monitor", "plain",
        DependencyGatheringPolicy(
          kind: dgAutomaticMonitor,
          completeness: decComplete),
        declaredHidden = false, cacheRoot, workRoot, fixtureBin, app,
        monitorTools.fsSnoop, monitorTools.shim)

      requirePolicyCase("recognized-validated-by-monitor", "depfile",
        reportPolicy(dgRecognizedFormatValidatedByMonitor, "deps.d"),
        declaredHidden = false, cacheRoot, workRoot, fixtureBin, app,
        monitorTools.fsSnoop, monitorTools.shim)

      requirePolicyCase("converter-validated-by-monitor", "custom-ok",
        converterPolicy(app, workRoot / "converter-validated-by-monitor",
          "deps.custom", "deps.rpset",
          dgPostBuildConverterValidatedByMonitor),
        declaredHidden = false, cacheRoot, workRoot, fixtureBin, app,
        monitorTools.fsSnoop, monitorTools.shim)

      let failRoot = tempRoot / ".repro-monitor-fail-cache"
      let failDir = workRoot / "monitor-failures"
      createDir(failDir)
      let visible = failDir / "visible.txt"
      let hidden = failDir / "hidden.txt"
      writeFixture(visible, "visible\n")
      writeFixture(hidden, "hidden\n")

      requireFailureNoPublish(action("corrupt-monitor-evidence",
        [fixtureBin, "corrupt-fragment", visible, hidden,
          failDir / "corrupt.txt", failDir / "unused.sidecar",
          failDir / "corrupt.runs"],
        cwd = failDir,
        inputs = [visible],
        outputs = ["corrupt.txt"],
        cacheable = true,
        weakFingerprint = weak("corrupt-monitor-evidence"),
        dependencyPolicy = DependencyGatheringPolicy(
          kind: dgAutomaticMonitor,
          completeness: decComplete),
        env = ["REPRO_MONITOR_SHIM_LIB=" & monitorTools.shim],
        commandStatsId = "m17-corrupt-monitor"), failRoot, app,
        "", monitorTools.fsSnoop)
  else:
    test "automatic monitor policies are unsupported on this platform":
      skip()
