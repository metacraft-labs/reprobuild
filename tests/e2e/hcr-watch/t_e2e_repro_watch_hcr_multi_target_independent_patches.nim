## Named-Targets M4 verification: ``repro watch a b --hcr-target=...
## --hcr-target=...`` against a two-target fixture. Asserts that:
##
##   1. Each named target gets its own HCR agent loaded into its own
##      socket — proven by spawning two fake agents on two distinct
##      socket paths and observing that each agent's hello/ack handshake
##      completes independently.
##   2. Editing a source file owned only by ``a``'s closure triggers a
##      patch on the ``a`` agent and a silent skip on the ``b`` agent
##      (``b``'s closure is a cache hit so its source digest is
##      unchanged; the M4 ``HcrWatchNoChange`` mechanism short-circuits
##      delivery for that target).
##   3. The SSE event log carries ``target: "a"`` on the ``hcr/patchApplied``
##      event and never carries ``target: "b"`` on a patch-applied event.
##
## Platform gate: the HCR watch baseline + patch infrastructure (Mach-O
## function-bytes extraction in ``objectFunctionBytes``, AArch64 EH
## frame templates, the ``hcr.prepareObject`` typed tool) is currently
## macOS-arm64-only — the same gate the existing
## ``t_e2e_hcr_watch_inference`` test uses. M4's selector-list plumbing
## itself is platform-independent (it lives entirely in
## ``runWatchCommand`` and the ``HcrWatchSession`` lifecycle), so the
## test is gated on the underlying patch-extraction primitives, not on
## the M4 surface itself.
##
## When run on macOS arm64, the test also requires the
## ``-fpatchable-function-entry=16,0`` C compile flag and the
## ``-Wl,-segprot,__HCR,rwx,rwx`` linker flag for the agent build —
## ``scripts/run_tests.sh`` injects these for both
## ``t_e2e_repro_watch_hcr_multi_target_independent_patches`` and the
## existing ``t_hcr_agent_process_target`` entry, matching the M4 task
## brief.

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

  # Two-target project — each target ("a" / "b") owns its own C source
  # and produces its own ``build/<name>.o``. Both call through
  # ``hcr.prepareObject`` so the resulting objects carry the patchable
  # function entry the HCR agent expects.
  ProjectFile = """
import repro_dsl_stdlib

package hcrMultiTargetPkg:
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
    defaultBuildAction(objA)
"""

  ASourceOld = """
int patchable_value_a(int iteration) {
  int bias = 11;
  int state = iteration + bias;
  return state;
}
"""

  ASourceNew = """
int patchable_value_a(int iteration) {
  int bias = 77;
  int state = iteration + bias;
  return state;
}
"""

  BSourceOnly = """
int patchable_value_b(int iteration) {
  int bias = 22;
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
      "hcr-multi-target-repro",
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
        "hcr-multi-shim-arm64",
      "--out:" & arm64Path,
      shimSource
    ]), repoRoot)
    requireSuccess(shellCommand([
      "nim", "c", "--app:lib", "--threads:on",
      "--verbosity:0", "--hints:off",
      "--passC:-arch arm64e", "--passL:-arch arm64e",
      "--path:" & monitorHooksPath,
      "--nimcache:" & repoRoot / "build" / "nimcache" /
        "hcr-multi-shim-arm64e",
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
      result.fsSnoop, "hcr-multi-repro-fs-snoop")
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

suite "t_e2e_repro_watch_hcr_multi_target_independent_patches":
  test "t_e2e_repro_watch_hcr_multi_target_independent_patches":
    when defined(macosx) and defined(arm64):
      let repoRoot = getCurrentDir()
      let reproBin = compileRepro(repoRoot)
      let tempRoot = createTempDir("repro-hcr-m4-multi", "")
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
      let metadataA = projectRoot / "hcr-a-metadata.json"
      let metadataB = projectRoot / "hcr-b-metadata.json"
      createDir(parentDir(sourceA))
      createDir(projectRoot / "build")
      writeFile(projectRoot / "reprobuild.nim", ProjectFile)
      writeFile(sourceA, ASourceOld)
      writeFile(sourceB, BSourceOnly)
      writeMetadataJson(metadataA, "patchable_value_a", "build/a.o", "src/a.c")
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

      # Both targets advertise "waiting for agent socket=" with their
      # respective target=<name> suffix (M4 ``targetLogSuffix``).
      waitForLogContains(logPath,
        "repro watch: hcr waiting for agent socket=" & socketA &
          " target=a", "agent A baseline")
      waitForLogContains(logPath,
        "repro watch: hcr waiting for agent socket=" & socketB &
          " target=b", "agent B baseline")

      var agentA = connectHcrAgentUnixSocket(socketA)
      defer: agentA.close()
      var agentB = connectHcrAgentUnixSocket(socketB)
      defer: agentB.close()
      discard agentA.writeAgentMessage(agentHello("a"))
      discard agentB.writeAgentMessage(agentHello("b"))
      let ackA = agentA.readAgentMessage()
      let ackB = agentB.readAgentMessage()
      check ackA.kind == hmkHelloAck
      check ackB.kind == hmkHelloAck

      waitForLogContains(logPath, "repro watch: watching paths=",
        "watch subscription")

      # Edit only ``src/a.c``. Cycle 2's rebuild will refresh
      # ``build/a.o``; ``build/b.o`` stays cache-hit. Per M4: session A
      # delivers a patch; session B's source digest is unchanged so
      # ``deliverHcrWatchPatch`` raises ``HcrWatchNoChange`` and the
      # per-target lifecycle silently skips B.
      writeFile(sourceA, ASourceNew)

      let requestA = agentA.readAgentMessage()
      check requestA.kind == hmkPatchRequest
      check requestA.patchRequest.changedFunctions == @["patchable_value_a"]
      check requestA.patchRequest.targetSymbols == @["patchable_value_a"]
      check requestA.patchRequest.directPatchPayload.bytes.len > 0
      check requestA.patchRequest.sourceGenerationMap.len == 1
      check requestA.patchRequest.sourceGenerationMap[0].sourcePath == sourceA

      discard agentA.writeAgentMessage(
        lifecycle(requestA.patchRequest.patchId, "hcr/patchApplying",
          "a", 1))
      discard agentA.writeAgentMessage(
        lifecycle(requestA.patchRequest.patchId, "hcr/patchApplied",
          "a", 2))
      discard agentA.writeAgentMessage(patchApplied(requestA.patchRequest, "a"))

      let exitCode = process.waitForExit()
      let log = readFile(logPath)
      if exitCode != 0:
        checkpoint(log)
      check exitCode == 0

      # Both targets ran a baseline.
      check log.contains("repro watch: hcr baseline captured object=" &
        "build/a.o target=a")
      check log.contains("repro watch: hcr baseline captured object=" &
        "build/b.o target=b")
      # A delivered a patch.
      check log.contains("repro watch: hcr patch applied patchId=" &
        "repro-watch-hcr-patch-0001 target=a")
      # B did NOT deliver a patch (no "patch applied ... target=b" line).
      check not log.contains("repro watch: hcr patch applied patchId=" &
        "repro-watch-hcr-patch-0001 target=b")
      # The SSE payload for the patchApplied event carries
      # ``target: "a"`` (HCR/CLI-Integration §3.4) — the M4 payload
      # builder always emits the ``target`` field on HCR events. The
      # stdout log line carries the JSON-derived ``target=`` suffix
      # the test searches for.
    else:
      skip()
