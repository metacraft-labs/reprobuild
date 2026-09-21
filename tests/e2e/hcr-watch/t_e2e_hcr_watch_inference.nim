## HLX-M8 residue, 2026-09-18: this gate used to be guarded
## `when defined(macosx) and defined(arm64)` IN ITS ENTIRETY, and the reason
## recorded in its sibling gates was "the HCR watch patch-extraction primitives
## are Mach-O". That premise is obsolete. `objectFunctionBytes` and
## `hcrUnwindMetadataFor` have been profile-conditional since HLX-M1 and parse
## ELF when the negotiated profile is the Linux one, and `defaultObjectSymbol`
## has been host-derived for as long. Nothing left in the body was macOS-
## specific except the gcc proxy, which exists only because SIP strips
## `DYLD_INSERT_LIBRARIES` from `/usr/bin/gcc` and so the io-monitor shim cannot
## observe the compiler's reads on that host. Linux has no such restriction:
## `LD_PRELOAD` reaches the real compiler, so the proxy is macOS-only rather
## than the test being macOS-only.
##
## The gate therefore runs on Linux x86_64 and macOS arm64, and it is the only
## place `repro watch --hcr`'s PRODUCTION wire is driven on Linux at all.

import std/[json, monotimes, os, osproc, sequtils, strutils, tempfiles, times, unittest]

import repro_hcr_agent
import repro_hcr_linkgraph/elf_decompress
from repro_test_support import requireBinary, monitorShimPath

const
  SupportProfile = defaultDirectSupportProfile()
    ## Host-derived, not pinned to the macOS string. The session rejects a
    ## profile mismatch during negotiation, so a hard-coded macOS profile is
    ## exactly what made this gate unrunnable anywhere else.

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
# image also serves the io-monitor role through ``repro internal io monitor``.
proc compileRepro(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc prepareGccProxy(tempRoot: string): string =
  ## macOS only. `/usr/bin/gcc` is SIP-protected, so `DYLD_INSERT_LIBRARIES` is
  ## stripped before it starts and the io-monitor shim never sees its reads.
  ## The proxy is an ordinary binary, so the shim DOES attach to it, and it
  ## performs the reads the dependency scan needs before handing off. On Linux
  ## `LD_PRELOAD` reaches the real compiler and no proxy is needed; installing
  ## one there would be a fixture that hides the mechanism under test.
  when defined(macosx):
    let binDir = tempRoot / "bin"
    let sourcePath = binDir / "gcc-proxy.c"
    let gccPath = binDir / "gcc"
    createDir(binDir)
    writeFile(sourcePath, GccProxySource)
    requireSuccess(shellCommand(["cc", sourcePath, "-o", gccPath]))
    binDir & $PathSep & getEnv("PATH")
  else:
    discard tempRoot
    getEnv("PATH")

proc prepareMonitorTools(repoRoot, tempRoot: string): tuple[shim: string] =
  discard tempRoot
  # Test-Fixtures-In-Build-Graph M2: assert the graph-built monitor shim
  # (edge ``reprobuild.test_fixtures.monitor_shim``) instead of compiling one
  # per test. The host-native single-arch shim is correct: the test process is
  # host-arch, so the former universal (lipo) build is unnecessary.
  # ``monitorShimPath`` has always named the host artefact
  # (``librepro_monitor_shim.so`` on Linux); only this proc's ``when
  # defined(macosx)`` guard kept the Linux one out of reach.
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
    when (defined(macosx) and defined(arm64)) or
         (defined(linux) and defined(amd64)):
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

      # The baseline cycle compiles the project provider from scratch when the
      # shared action cache has never seen this project shape. Measured cold on
      # Linux x86_64 that is minutes, not seconds; the 30 s default this used to
      # take was a warm-cache number and it is the only reason the first Linux
      # run of this gate reported "timed out waiting for HCR baseline" while the
      # same command completed fine by hand.
      waitForLogContains(logPath, "repro watch: hcr waiting for agent socket=",
        "HCR baseline", timeoutMs = 600_000)
      var agent = connectHcrAgentUnixSocket(socketPath)
      defer: agent.close()
      discard agent.writeAgentMessage(agentHello())
      let ack = agent.readAgentMessage()
      check ack.kind == hmkHelloAck

      waitForLogContains(logPath, "repro watch: watching paths=",
        "watch subscription")
      writeFile(sourcePath, NewSource)

      # Loud, with the transcript in hand. When the watch process dies before it
      # sends a patch this read fails with "unexpected EOF while reading HCR
      # agent IPC header", which names the socket and says nothing at all about
      # WHY the producer stopped. The watch log is the only place that answer
      # exists, so it travels with the failure.
      let request =
        try:
          agent.readAgentMessage()
        except CatchableError as err:
          raise newException(IOError,
            "no patch request arrived from `repro watch --hcr` (" & err.msg &
            ").\n--- repro watch log ---\n" &
            (if fileExists(logPath): readFile(logPath) else: "<no log>"))
      check request.kind == hmkPatchRequest
      check request.patchRequest.changedFunctions == @["patchable_value"]
      check request.patchRequest.targetSymbols == @["patchable_value"]
      check request.patchRequest.directPatchPayload.bytes.len > 0
      check request.patchRequest.debugObjectPayload.bytes.len > 0
      check request.patchRequest.sourceGenerationMap.len == 1
      check request.patchRequest.sourceGenerationMap[0].sourcePath == sourcePath
      # HLX-M8 residue: `changedFiles` is what `rb_hcr_file_changed` answers
      # over once the reload is applied. Until 2026-09-18 this command sent it
      # EMPTY on every host, so a watch-driven reload told every application
      # that no source file had changed. Asserted here as a NON-EMPTY list
      # naming the file the watcher actually observed being edited — an
      # assertion an empty payload cannot satisfy, which is the failure this
      # gate exists to make impossible.
      check request.patchRequest.changedFiles == @[sourcePath]
      # Inference mode has nothing to infer layout deltas from, and the empty
      # answer is asserted rather than left unstated: a non-empty
      # `changedTypes` here would be invented, and §7.4's acceptance rule runs
      # on this set. The metadata-mode arm of
      # `t_e2e_repro_watch_hcr_multi_target_independent_patches` is where a
      # NON-EMPTY `changedTypes` crosses this wire.
      check request.patchRequest.changedTypes.len == 0

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
      check not log.contains("--hcr-metadata")

      # The `hcr.prepareObject` edge ran, asserted on its ARTIFACT rather than
      # on its log line. Action stdout is not forwarded into the watch log on
      # Linux — measured, `repro build patchable-object` prints none of the
      # subprocess's output — so the log assertion this used to make could only
      # ever be host-specific. The artifact is the thing the watch session then
      # reads its patch bytes out of, so asserting it is the stronger claim.
      let preparedObject = projectRoot / "build" / "patchable.o"
      let rawObject = projectRoot / "build" / "patchable.raw.o"
      check fileExists(preparedObject)
      when defined(linux):
        # HLX-M8, 2026-09-20. This USED to assert the two objects were
        # byte-identical, because the ELF arm of `prepare-object` was a
        # passthrough — `Linux-ELF-Provider.md` §5.1's Mach-O `__HCR` segment
        # rewrite has no ELF counterpart. The assertion is now the opposite,
        # and the change is deliberate rather than a relaxation: the ELF arm
        # EXPANDS `SHF_COMPRESSED` `.debug_*`, which this project's
        # `gcc(debug3 = true)` edge emits by default and which the agent
        # refuses by name, so the prepared object is a strictly larger object
        # with the same sections uncompressed.
        #
        # The premise is asserted before the consequence: if this toolchain
        # stopped compressing by default, `elfHasCompressedSections(rawObject)`
        # goes red rather than the size comparison silently becoming an
        # equality nobody re-read.
        check elfHasCompressedSections(rawObject)
        check not elfHasCompressedSections(preparedObject)
        check readFile(preparedObject).len > readFile(rawObject).len
      else:
        # The macOS arm rewrites `section_64.segname`, so the two objects are
        # the same size and NOT the same bytes. Asserting the inequality keeps
        # the passthrough assertion above from being copied onto a host where
        # it would be wrong.
        check readFile(preparedObject) != readFile(rawObject)
        check log.contains("repro hcr prepare-object: output=build/patchable.o")

      # ---- AND THE SESSION SENT THE PREPARED ONE, which is a different claim
      # from "the edge wrote it".
      #
      # HLX-M8, 2026-09-20. It did not, on any platform, until this date:
      # `hcrWatchObjectCandidatesFromReport` matched only actions whose inputs
      # contain a C/C++ SOURCE, so the `.o`-to-`.o` `hcr.prepareObject` edge
      # was never a candidate and the session always cut its patch from the
      # COMPILER's object. The whole pass was decorative on the wire — on
      # macOS the `__HCR` segment rewrite never reached the agent either. The
      # assertion above could not see it because the edge really does write
      # the file; what was missing was an assertion about the bytes SENT.
      let baseline = parseJson(readFile(artifacts / "hcr-watch-baseline.json"))
      check baseline["mode"].getStr() == "inferred"
      check baseline["objects"].len == 1
      let inferredObject = baseline["objects"][0]["object"].getStr()
      check inferredObject.endsWith("patchable.o")
      check not inferredObject.endsWith("patchable.raw.o")
    else:
      skip("host is neither macOS arm64 nor Linux x86-64 — HCR watch inference runs only on those")
