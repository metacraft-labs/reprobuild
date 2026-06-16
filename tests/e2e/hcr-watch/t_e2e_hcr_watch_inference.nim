import std/[monotimes, os, osproc, sequtils, strutils, tempfiles, times, unittest]

import repro_hcr_agent
from repro_test_support import requireBinary, monitorShimPath

const
  SupportProfile = "macos-arm64-direct-hcr-in-codetracer-v1"

  GccProxySource = r"""
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void read_for_monitor(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return;
  char buffer[4096];
  while (read(fd, buffer, sizeof(buffer)) > 0) {}
  close(fd);
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts("gcc proxy 1.0.0");
    return 0;
  }
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-include") == 0 && i + 1 < argc) {
      read_for_monitor(argv[i + 1]);
      i++;
    } else if (argv[i][0] != '-' && strstr(argv[i], ".c") != NULL) {
      read_for_monitor(argv[i]);
    }
  }
  unsetenv("DYLD_INSERT_LIBRARIES");
  setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
  char **next_argv = calloc((size_t)argc + 1, sizeof(char *));
  if (next_argv == NULL) return 126;
  next_argv[0] = "/usr/bin/gcc";
  for (int i = 1; i < argc; i++) next_argv[i] = argv[i];
  execv("/usr/bin/gcc", next_argv);
  perror("execv /usr/bin/gcc");
  return 127;
}
"""

  ProjectFile = """
import repro_dsl_stdlib

package hcrPlainC:
  uses:
    "gcc >=1"

  build:
    let buildDir = fs.ensureDir(actionId = "build-dir", path = "build")
    let rawObj = gcc(
      source = "src/patchable.c",
      output = "build/patchable.raw.o",
      debug3 = true,
      compileOnly = true,
      after = @[buildDir])
    let obj = hcr.prepareObject(
      input = "build/patchable.raw.o",
      output = "build/patchable.o",
      after = @[rawObj])
    target("patchable-object", [obj])
    defaultBuildAction(obj)
"""

  OldSource = """
int patchable_value(int iteration) {
  int bias = 11;
  int state = iteration + bias;
  return state;
}
"""

  NewSource = """
int patchable_value(int iteration) {
  int bias = 77;
  int state = iteration + bias;
  return state;
}
"""

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(argv: openArray[string]): string =
  argv.mapIt(q(it)).join(" ")

proc requireSuccess(command: string; cwd = getCurrentDir()) =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(ValueError,
      "command failed: " & command & "\n" & res.output)

# Test-Fixtures-In-Build-Graph M1/M3: ``repro`` is a graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``). Assert it exists instead of
# recompiling ``apps/repro/repro.nim`` at test runtime. The same consolidated
# image also serves the fs-snoop role (``repro internal fs-snoop``), so the
# ``REPRO_FS_SNOOP`` driver resolves to this binary too.
proc compileRepro(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc prepareGccProxy(tempRoot: string): string =
  let binDir = tempRoot / "bin"
  let sourcePath = binDir / "gcc-proxy.c"
  let gccPath = binDir / "gcc"
  createDir(binDir)
  writeFile(sourcePath, GccProxySource)
  requireSuccess(shellCommand(["cc", sourcePath, "-o", gccPath]))
  binDir & $PathSep & getEnv("PATH")

when defined(macosx):
  proc prepareMonitorTools(repoRoot, tempRoot: string): tuple[fsSnoop: string;
      shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    # Test-Fixtures-In-Build-Graph M3: the fs-snoop driver is the graph-built
    # ``build/bin/repro`` (reached via ``repro internal fs-snoop``); ``repro``
    # honors ``REPRO_FS_SNOOP`` pointing at this consolidated image. Assert it
    # exists instead of compiling a standalone wrapper at test runtime.
    result.fsSnoop = requireBinary(
      repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
      "reprobuild.apps.repro")
    # Test-Fixtures-In-Build-Graph M2: assert the graph-built monitor shim
    # (edge ``reprobuild.test_fixtures.monitor_shim``) instead of compiling one
    # per test. The host-native single-arch shim is correct: the test process is
    # host-arch, so the former universal (lipo) build is unnecessary.
    result.shim = requireBinary(monitorShimPath(repoRoot),
      "reprobuild.test_fixtures.monitor_shim")

proc waitForLogContains(logPath, needle, context: string; timeoutMs = 30_000) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if fileExists(logPath) and readFile(logPath).contains(needle):
      return
    sleep(50)
  let log =
    if fileExists(logPath): readFile(logPath) else: ""
  raise newException(ValueError,
    "timed out waiting for " & context & ": " & needle & "\n" & log)

proc agentHello(): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "fake-agent-hello-1",
    kind: hmkHello,
    hello: HcrHello(
      supportProfile: SupportProfile,
      agentPid: getCurrentProcessId(),
      capabilities: @[
        "hcr-agent-protocol",
        "direct-patch-injection",
        "debug-object-payloads",
        "unwind-metadata-payloads",
        "source-generation-metadata"] ))

proc lifecycle(patchId, event: string; sequence: uint64): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "fake-agent-lifecycle-" & $sequence,
    kind: hmkLifecycleEvent,
    lifecycleEvent: HcrLifecycleEvent(
      patchId: patchId,
      event: event,
      sequence: sequence))

proc patchApplied(request: HcrPatchRequest): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "fake-agent-patch-applied-1",
    kind: hmkPatchApplied,
    patchApplied: HcrPatchApplied(
      patchId: request.patchId,
      changedFunctions: request.changedFunctions,
      symbolGeneration: 1'u64,
      debugObjectDigest: request.debugObjectPayload.digest,
      unwindMetadataDigest: request.unwindMetadataPayload.digest,
      sourceGenerationMapDigest: "blake3-256:fake-agent-source-map",
      entryAddress: "0x1000",
      dispatchAddress: "0x2000",
      oldCodeRetained: true,
      sharedLibraryPositivePath: false))

suite "HCR watch inference E2E":
  test "repro watch infers HCR patch metadata without fixture JSON":
    when defined(macosx) and defined(arm64):
      let repoRoot = getCurrentDir()
      let reproBin = compileRepro(repoRoot)
      let tempRoot = createTempDir("repro-hcr-watch-e2e", "")
      defer: removeDir(tempRoot)
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let pathValue = prepareGccProxy(tempRoot / "tools")

      let projectRoot = tempRoot / "project"
      let sourcePath = projectRoot / "src" / "patchable.c"
      let logPath = tempRoot / "repro-watch.log"
      let artifacts = projectRoot / ".repro" / "hcr"
      let socketPath = tempRoot / "hcr-agent.sock"
      createDir(parentDir(sourcePath))
      createDir(projectRoot / "build")
      writeFile(projectRoot / "reprobuild.nim", ProjectFile)
      writeFile(sourcePath, OldSource)
      check not OldSource.contains("repro_hcr_agent")
      check not OldSource.contains("section(")
      check not OldSource.contains("REPROBUILD_HCR")

      let command = shellCommand([
        "env",
        "PATH=" & pathValue,
        "REPRO_FS_SNOOP=" & monitorTools.fsSnoop,
        "REPRO_MONITOR_SHIM_LIB=" & monitorTools.shim,
        reproBin, "watch", projectRoot & "#patchable-object",
        "--tool-provisioning=path",
        "--max-cycles=2",
        "--debounce-ms=50",
        "--hcr-agent-socket=" & socketPath,
        "--hcr-artifacts=" & artifacts
      ]) & " > " & q(logPath) & " 2>&1"
      let process = startProcess("/bin/sh",
        args = ["-c", command],
        workingDir = repoRoot,
        options = {poUsePath})
      defer:
        if process.running():
          process.terminate()
        process.close()

      waitForLogContains(logPath, "repro watch: hcr waiting for agent socket=",
        "HCR baseline")
      var agent = connectHcrAgentUnixSocket(socketPath)
      defer: agent.close()
      discard agent.writeAgentMessage(agentHello())
      let ack = agent.readAgentMessage()
      check ack.kind == hmkHelloAck

      waitForLogContains(logPath, "repro watch: watching paths=",
        "watch subscription")
      writeFile(sourcePath, NewSource)

      let request = agent.readAgentMessage()
      check request.kind == hmkPatchRequest
      check request.patchRequest.changedFunctions == @["patchable_value"]
      check request.patchRequest.targetSymbols == @["patchable_value"]
      check request.patchRequest.directPatchPayload.bytes.len > 0
      check request.patchRequest.debugObjectPayload.bytes.len > 0
      check request.patchRequest.sourceGenerationMap.len == 1
      check request.patchRequest.sourceGenerationMap[0].sourcePath == sourcePath

      discard agent.writeAgentMessage(
        lifecycle(request.patchRequest.patchId, "hcr/patchApplying", 1))
      discard agent.writeAgentMessage(
        lifecycle(request.patchRequest.patchId, "hcr/patchApplied", 2))
      discard agent.writeAgentMessage(patchApplied(request.patchRequest))

      let exitCode = process.waitForExit()
      let log = readFile(logPath)
      if exitCode != 0:
        checkpoint(log)
      check exitCode == 0
      check log.contains("repro watch: hcr baseline inferred objects=1")
      check log.contains("repro watch: hcr inferred changed function=patchable_value")
      check log.contains("repro hcr prepare-object: output=build/patchable.o")
      check not log.contains("--hcr-metadata")
    else:
      skip()
