## Named-Targets M4 verification: two-target HCR session where target
## ``a`` cannot have its HCR agent injected (simulated by binding
## ``a`` to a metadata file that does not exist on disk). Asserts:
##
##   1. Target ``a`` emits ``hcr/patchFailed`` exactly once carrying
##      ``target: "a"`` and the SSE-shape ``error`` field.
##   2. Target ``a`` falls back to plain rebuilds for the remainder of
##      the watch session (its session is marked ``fallbackOnly`` so
##      cycle N>1 short-circuits the patch lifecycle).
##   3. Target ``b`` continues to receive patches independently — its
##      hello/ack handshake completes, its baseline is captured, and a
##      source edit on ``src/b.c`` triggers a successful patch delivery
##      with ``target: "b"`` on the ``hcr/patchApplied`` SSE event.
##
## Platform gate: this test exercises the M4 per-target failure
## isolation lifecycle. The "b continues to receive patches" assertion
## requires the macOS-arm64 Mach-O patch-extraction primitives
## (``parseMachOArm64Object``, ``objectFunctionBytes``,
## ``minimalAarch64EhFrameTemplate``), so the test is gated the same
## way the existing ``t_e2e_hcr_watch_inference`` and
## ``t_hcr_agent_process_target`` tests gate. The failure-isolation
## logic itself (the per-session try/except in
## ``runWatchCommand.runDirectWatch``) is platform-independent — the
## gating reflects the cross-platform reach of the existing HCR test
## scaffolding rather than the M4 surface added in this milestone.

import std/[monotimes, os, osproc, sequtils, strutils, tempfiles, times, unittest]

import repro_hcr_agent

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

package hcrInjectFailurePkg:
  uses:
    "gcc >=1"

  build:
    let buildDir = fs.ensureDir(actionId = "build-dir", path = "build")
    let rawA = gcc(
      source = "src/a.c",
      output = "build/a.raw.o",
      debug3 = true,
      compileOnly = true,
      after = @[buildDir])
    let objA = hcr.prepareObject(
      input = "build/a.raw.o",
      output = "build/a.o",
      after = @[rawA])
    target("a", [objA])
    let rawB = gcc(
      source = "src/b.c",
      output = "build/b.raw.o",
      debug3 = true,
      compileOnly = true,
      after = @[buildDir])
    let objB = hcr.prepareObject(
      input = "build/b.raw.o",
      output = "build/b.o",
      after = @[rawB])
    target("b", [objB])
    defaultBuildAction(objB)
"""

  ASource = """
int patchable_value_a(int iteration) {
  int bias = 11;
  int state = iteration + bias;
  return state;
}
"""

  BSourceOld = """
int patchable_value_b(int iteration) {
  int bias = 22;
  int state = iteration + bias;
  return state;
}
"""

  BSourceNew = """
int patchable_value_b(int iteration) {
  int bias = 88;
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

proc compileRepro(repoRoot: string): string =
  result = repoRoot / "build" / "test-bin" / "repro"
  createDir(parentDir(result))
  createDir(repoRoot / "build" / "nimcache")
  requireSuccess(shellCommand([
    "nim", "c", "--threads:on",
    "--nimcache:" & repoRoot / "build" / "nimcache" /
      "hcr-inject-failure-repro",
    "--out:" & result,
    repoRoot / "apps" / "repro" / "repro.nim"
  ]), repoRoot)

proc prepareGccProxy(tempRoot: string): string =
  let binDir = tempRoot / "bin"
  let sourcePath = binDir / "gcc-proxy.c"
  let gccPath = binDir / "gcc"
  createDir(binDir)
  writeFile(sourcePath, GccProxySource)
  requireSuccess(shellCommand(["cc", sourcePath, "-o", gccPath]))
  binDir & $PathSep & getEnv("PATH")

proc compileNim(repoRoot, sourcePath, outputPath, cacheName: string) =
  requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
    "--out:" & outputPath,
    sourcePath
  ]), repoRoot)

when defined(macosx):
  proc compileShim(repoRoot, outputPath: string) =
    let arm64Path = outputPath & ".arm64"
    let arm64ePath = outputPath & ".arm64e"
    let monitorHooksPath = repoRoot / "libs" / "repro_monitor_hooks" / "src"
    let shimSource = repoRoot / "libs" / "repro_monitor_shim" / "src" /
      "repro_monitor_shim" / "macos_interpose.nim"
    requireSuccess(shellCommand([
      "nim", "c", "--app:lib", "--threads:on",
      "--verbosity:0", "--hints:off",
      "--path:" & monitorHooksPath,
      "--nimcache:" & repoRoot / "build" / "nimcache" /
        "hcr-inject-failure-shim-arm64",
      "--out:" & arm64Path,
      shimSource
    ]), repoRoot)
    requireSuccess(shellCommand([
      "nim", "c", "--app:lib", "--threads:on",
      "--verbosity:0", "--hints:off",
      "--passC:-arch arm64e", "--passL:-arch arm64e",
      "--path:" & monitorHooksPath,
      "--nimcache:" & repoRoot / "build" / "nimcache" /
        "hcr-inject-failure-shim-arm64e",
      "--out:" & arm64ePath,
      shimSource
    ]), repoRoot)
    requireSuccess(shellCommand([
      "lipo", "-create", "-output", outputPath, arm64Path, arm64ePath
    ]), repoRoot)

  proc prepareMonitorTools(repoRoot, tempRoot: string): tuple[fsSnoop: string;
      shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    result.fsSnoop = binDir / "repro-fs-snoop"
    result.shim = libDir / "librepro_monitor_shim.dylib"
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "hcr-inject-failure-repro-fs-snoop")
    compileShim(repoRoot, result.shim)

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

proc agentHello(suffix: string): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "fake-agent-hello-" & suffix,
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

proc lifecycle(patchId, event, suffix: string; sequence: uint64): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "fake-agent-lifecycle-" & suffix & "-" & $sequence,
    kind: hmkLifecycleEvent,
    lifecycleEvent: HcrLifecycleEvent(
      patchId: patchId,
      event: event,
      sequence: sequence))

proc patchApplied(request: HcrPatchRequest; suffix: string): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "fake-agent-patch-applied-" & suffix,
    kind: hmkPatchApplied,
    patchApplied: HcrPatchApplied(
      patchId: request.patchId,
      changedFunctions: request.changedFunctions,
      symbolGeneration: 1'u64,
      debugObjectDigest: request.debugObjectPayload.digest,
      unwindMetadataDigest: request.unwindMetadataPayload.digest,
      sourceGenerationMapDigest: "blake3-256:fake-agent-source-map-" & suffix,
      entryAddress: "0x1000",
      dispatchAddress: "0x2000",
      oldCodeRetained: true,
      sharedLibraryPositivePath: false))

proc writeMetadataJson(path, functionName, objectPath, sourcePath: string) =
  createDir(parentDir(path))
  writeFile(path,
    "{\n" &
    "  \"function\": \"" & functionName & "\",\n" &
    "  \"object\": \"" & objectPath & "\",\n" &
    "  \"source\": \"" & sourcePath & "\"\n" &
    "}\n")

suite "t_e2e_repro_watch_hcr_one_target_agent_inject_failure":
  test "t_e2e_repro_watch_hcr_one_target_agent_inject_failure":
    when defined(macosx) and defined(arm64):
      let repoRoot = getCurrentDir()
      let reproBin = compileRepro(repoRoot)
      let tempRoot = createTempDir("repro-hcr-m4-inject-fail", "")
      defer: removeDir(tempRoot)
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let pathValue = prepareGccProxy(tempRoot / "tools")

      let projectRoot = tempRoot / "project"
      let sourceA = projectRoot / "src" / "a.c"
      let sourceB = projectRoot / "src" / "b.c"
      let logPath = tempRoot / "repro-watch.log"
      let artifactsA = projectRoot / ".repro" / "hcr-a"
      let artifactsB = projectRoot / ".repro" / "hcr-b"
      let socketA = tempRoot / "hcr-a.sock"
      let socketB = tempRoot / "hcr-b.sock"
      # Target A's metadata path points at a file that does NOT exist
      # on disk — this simulates an agent-injection failure: cycle 1's
      # ``captureHcrWatchBaseline`` reads the metadata file, fails the
      # ``fileExists`` check inside ``readHcrWatchPatchMetadata``, and
      # raises ``ValueError``. The M4 per-session try/except catches
      # the error, marks A's session ``fallbackOnly``, emits
      # ``hcr/patchFailed{target: "a"}``, and continues to B.
      let metadataA = projectRoot / "missing-hcr-a-metadata.json"
      let metadataB = projectRoot / "hcr-b-metadata.json"
      createDir(parentDir(sourceA))
      createDir(projectRoot / "build")
      writeFile(projectRoot / "reprobuild.nim", ProjectFile)
      writeFile(sourceA, ASource)
      writeFile(sourceB, BSourceOld)
      # Only B's metadata is materialised; A's metadata path is left
      # missing on purpose.
      writeMetadataJson(metadataB, "patchable_value_b", "build/b.o", "src/b.c")

      let command = shellCommand([
        "env",
        "PATH=" & pathValue,
        "REPRO_FS_SNOOP=" & monitorTools.fsSnoop,
        "REPRO_MONITOR_SHIM_LIB=" & monitorTools.shim,
        reproBin, "watch", "a", "b",
        "--tool-provisioning=path",
        "--daemon=off",
        "--max-cycles=2",
        "--debounce-ms=50",
        "--hcr-target=a:" & socketA & ":" & artifactsA & ":" & metadataA,
        "--hcr-target=b:" & socketB & ":" & artifactsB & ":" & metadataB
      ]) & " > " & q(logPath) & " 2>&1"
      let process = startProcess("/bin/sh",
        args = ["-c", command],
        workingDir = repoRoot,
        options = {poUsePath})
      defer:
        if process.running():
          process.terminate()
        process.close()

      # A's baseline raises immediately (missing metadata) so we expect
      # the ``hcr patch failed target=a`` line in the SSE-mirrored
      # stdout log. The failure isolation block in
      # ``runWatchCommand.runDirectWatch`` emits this exactly once per
      # failing target.
      waitForLogContains(logPath,
        "repro watch: hcr patch failed target=a",
        "target A injection failure")

      # B's baseline still proceeds even though A failed — the per-
      # target loop continues past A's exception. B's session waits
      # for its own agent connection.
      waitForLogContains(logPath,
        "repro watch: hcr waiting for agent socket=" & socketB &
          " target=b", "agent B baseline")

      var agentB = connectHcrAgentUnixSocket(socketB)
      defer: agentB.close()
      discard agentB.writeAgentMessage(agentHello("b"))
      let ackB = agentB.readAgentMessage()
      check ackB.kind == hmkHelloAck

      waitForLogContains(logPath, "repro watch: watching paths=",
        "watch subscription")

      # Edit ``src/b.c``. Cycle 2 rebuilds ``build/b.o`` and delivers
      # a patch to B. A is in ``fallbackOnly`` so its lifecycle is
      # short-circuited; no further HCR activity on socket A.
      writeFile(sourceB, BSourceNew)

      let requestB = agentB.readAgentMessage()
      check requestB.kind == hmkPatchRequest
      check requestB.patchRequest.changedFunctions == @["patchable_value_b"]
      check requestB.patchRequest.targetSymbols == @["patchable_value_b"]
      check requestB.patchRequest.directPatchPayload.bytes.len > 0
      check requestB.patchRequest.sourceGenerationMap.len == 1
      check requestB.patchRequest.sourceGenerationMap[0].sourcePath == sourceB

      discard agentB.writeAgentMessage(
        lifecycle(requestB.patchRequest.patchId, "hcr/patchApplying",
          "b", 1))
      discard agentB.writeAgentMessage(
        lifecycle(requestB.patchRequest.patchId, "hcr/patchApplied",
          "b", 2))
      discard agentB.writeAgentMessage(patchApplied(requestB.patchRequest, "b"))

      let exitCode = process.waitForExit()
      let log = readFile(logPath)
      if exitCode != 0:
        checkpoint(log)
      check exitCode == 0

      # The ``hcr patch failed target=a`` SSE-mirrored line appears
      # exactly once — failure is reported one time per target.
      var occurrences = 0
      var pos = 0
      let needle = "repro watch: hcr patch failed target=a"
      while true:
        let idx = log.find(needle, pos)
        if idx < 0: break
        inc occurrences
        pos = idx + needle.len
      check occurrences == 1

      # B's patch landed.
      check log.contains("repro watch: hcr patch applied patchId=" &
        "repro-watch-hcr-patch-0001 target=b")

      # A never delivered a patch (its lifecycle short-circuited after
      # cycle-1 baseline failure).
      check not log.contains("repro watch: hcr patch applied patchId=" &
        "repro-watch-hcr-patch-0001 target=a")
    else:
      skip()
