## HLX-M0 verification gate `e2e_hcr_linux_x86_64_single_threaded_direct_patch`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §3, §4.2-§4.5, §5.1-§5.2.
## Milestones: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M0.
##
## The falsifier, stated as the milestone states it: a single-threaded Linux
## x86_64 process calls a patchable function that returns 11; the agent applies
## a direct entry patch; the same call then returns 77. The gate FAILS if the
## second call returns the old value, if the process faults, or if the published
## bytes are not the single aligned 8-byte word the design mandates.
##
## `allowed_mocks: none`. Everything below is real:
##
##   * a real target process, compiled by a real GCC with the real patchable
##     build profile (`-falign-functions=16 -fpatchable-function-entry=16,0
##     -fcf-protection=full`), linking the production C agent;
##   * real `mmap`/`mprotect` (the provider's `mprotect` is a raw syscall);
##   * the real agent Unix socket and the real Content-Length wire protocol,
##     driven by the production `HcrCoordinatorClient`;
##   * real patch bytes extracted from a real ELF relocatable object produced by
##     a real compiler invocation — not a hand-assembled literal.
##
## Shape deliberately mirrors the macOS M27 gate
## (`tests/e2e/hcr-direct-linker/t_e2e_hcr_in_target_link_and_trampoline.nim`)
## so the two are comparable.
##
## No silent skips on Linux x86_64: a missing compiler, a missing sled or a
## missing `__patchable_function_entries` section is a LOUD failure, never an
## early return counted as a pass. The `skip()` arm exists only for platforms
## that are not Linux x86_64.

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_hcr_linker

  import elf_rel_reader

  const
    # Taken from the registry rather than spelled locally, so a drift between
    # the Nim constant and `REPRO_HCR_AGENT_SUPPORT_PROFILE_LINUX_X86_64` in
    # the C agent header shows up as a negotiation failure in this gate.
    SupportProfile = HcrLinuxX86_64DirectSupportProfile
    TargetSymbol = "hcr_lx_m0_entry"
    PatchSymbol = "hcr_lx_m0_patch_body"
    Endbr64Hex = "f30f1efa"

  proc q(value: string): string = quoteShell(value)

  proc shellCommand(args: openArray[string]): string =
    for index, arg in args:
      if index > 0:
        result.add(" ")
      result.add(q(arg))

  proc runSuccess(command: string; cwd: string): string =
    let res = execCmdEx(command, workingDir = cwd)
    if res.exitCode != 0:
      checkpoint("command failed (exit " & $res.exitCode & "): " & command)
      checkpoint(res.output)
    require res.exitCode == 0
    res.output

  proc requireCompiler(name: string) =
    let found = findExe(name)
    if found.len == 0:
      # A missing prerequisite must fail the gate, not silently pass it.
      checkpoint("required compiler not on PATH: " & name)
    require found.len > 0

  proc byteAt(hex: string; index: int): string =
    hex[index * 2 ..< index * 2 + 2]

  suite "e2e_hcr_linux_x86_64_single_threaded_direct_patch":
    test "linux x86_64 target returns 11, is patched over the wire, returns 77":
      requireCompiler("gcc")
      let repoRoot = getCurrentDir()
      let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-direct"
      let workDir = repoRoot / "build" / "hcr-linux-m0"
      let binDir = repoRoot / "build" / "test-bin"
      createDir(workDir)
      createDir(binDir)

      # 1. Build the patch body as a REAL relocatable object and extract its
      #    function bytes from its own section. No hand-assembled literals.
      let patchObj = workDir / "hcr_lx_m0_patch.o"
      discard runSuccess(shellCommand([
        "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
        caseDir / "hcr_lx_m0_patch.c", "-o", patchObj]), repoRoot)
      let obj = parseElfRelObject(patchObj)
      let patchSection = obj.definingSectionName(PatchSymbol)
      check patchSection == ".text." & PatchSymbol
      # The extracted body must be self-contained: a relocation would mean the
      # bytes are not position-independent and cannot be dropped into a
      # provider-owned page as-is.
      check obj.relocationCount(patchSection) == 0
      let patchBytes = obj.functionBytes(PatchSymbol)
      check patchBytes.len > 0
      # `-fcf-protection` gives the body its own landing pad, so the provider
      # does not prepend one (design §4.2, island-reachable bodies).
      check hexBytes(patchBytes).startsWith(Endbr64Hex)
      # `mov $0x4d,%eax` — the 77 the gate is about to observe.
      check hexBytes(patchBytes).contains("b84d000000")

      # 2. Build the real target process with the real patchable build profile,
      #    linking the production C agent.
      let targetBin = binDir / "hcr_lx_m0_target"
      discard runSuccess(shellCommand([
        "gcc", "-O2", "-g",
        "-falign-functions=16",
        "-fpatchable-function-entry=16,0",
        "-fcf-protection=full",
        "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
        "-o", targetBin,
        caseDir / "hcr_lx_m0_target.c",
        repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c",
        "-lpthread"]), repoRoot)
      check fileExists(targetBin)
      # Direct entry patching, not dlopen/dlsym interposition (design §3.1).
      check not fileExists(targetBin & ".so")

      # 3. Real agent socket, real wire protocol.
      let socketPath = workDir / "hcr-lx-m0.sock"
      removeFile(socketPath)
      var listener = listenHcrAgentUnixSocket(socketPath)
      defer: listener.close()

      var env = newStringTable()
      for key, value in envPairs():
        env[key] = value
      env[ReproHcrAgentSocketEnv] = socketPath
      let process = startProcess(targetBin, workingDir = repoRoot,
        env = env, options = {poStdErrToStdOut})

      var connection = acceptHcrAgentConnection(listener)
      var client = initHcrCoordinatorClient(SupportProfile)
      let request = directPatchRequest(
        patchId = "hlx-m0-linux-1",
        supportProfile = SupportProfile,
        changedFunctions = [TargetSymbol],
        targetSymbols = [TargetSymbol],
        directPatchBytes = patchBytes,
        debugObjectBytes = [],
        unwindMetadataBytes = [],
        sourceGenerationMap = [])
      let delivery = client.deliverPatchRequest(connection, request)
      connection.close()

      let output = process.outputStream.readAll()
      let exitCode = process.waitForExit()
      process.close()
      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0

      # 4. Wire-level assertions.
      if delivery.patchFailed.isSome:
        checkpoint("agent refused the patch: " &
          delivery.patchFailed.get().message)
      check delivery.patchFailed.isNone
      require delivery.patchApplied.isSome
      let applied = delivery.patchApplied.get()
      check applied.patchId == "hlx-m0-linux-1"
      check applied.changedFunctions == @[TargetSymbol]
      check applied.oldCodeRetained
      check not applied.sharedLibraryPositivePath
      check delivery.session.lifecycleEvents ==
        @["hcr/patchApplying", "hcr/patchApplied"]
      check delivery.session.agentCapabilities.contains("hcr-agent-protocol")
      check delivery.session.agentCapabilities.contains("direct-patch-injection")
      check delivery.session.agentCapabilities.contains(
        "linux-x86_64-elf-direct-hcr")
      # Design §4.4: SYNC_CORE availability is recorded in the capability
      # report even though a single-threaded gate cannot exercise the hazard.
      check delivery.session.agentCapabilities.contains("membarrier-sync-core")
      check delivery.session.agentCapabilities.contains(
        "text-protection-roundtrip")

      # 5. The observable the milestone names: the target's own return value.
      check not output.contains("dlopen")
      check not output.contains("dlsym")
      let result = parseJson(output.strip())
      check result["schemaId"].getStr() ==
        "reprobuild.hcr.hlx-m0.linux-x86_64-target-result.v1"
      check result["before"].getInt() == 11
      check result["after"].getInt() == 77
      check result["supportProfile"].getStr() == SupportProfile
      check defaultDirectSupportProfile() == SupportProfile
      check result["hostSupportsDirectPatch"].getBool()
      check result["membarrierSyncCore"].getBool()
      check result["startRc"].getInt() == 0
      check result["pollRc"].getInt() == 0

      # 6. The sled came from the runtime-mapped `__patchable_function_entries`
      #    section, not from the symbol address (design §4.2). Under
      #    `-fcf-protection` GCC puts `endbr64` at the entry label and the
      #    section entry already points past it.
      check result["patchableEntryCount"].getInt() > 0
      check result["sledOffsetFromEntry"].getInt() == 4
      let entryAddress = parseHexInt(
        result["entryAddress"].getStr().replace("0x", "")).uint64
      check (entryAddress and 15'u64) == 0'u64 # -falign-functions=16

      # 7. Byte-level proof that exactly one naturally aligned 8-byte window
      #    changed, that `endbr64` survived, and that the old body is retained.
      let beforeHex = result["entryBytesBeforeHex"].getStr()
      let afterHex = result["entryBytesAfterHex"].getStr()
      check beforeHex.len == 64
      check afterHex.len == 64
      # `endbr64` at the entry label, then the sixteen single-byte NOPs of
      # `-fpatchable-function-entry=16,0`, then the original body.
      check beforeHex.startsWith(Endbr64Hex & repeat("90", 16))
      check beforeHex[8 + 32 ..< 8 + 32 + 12] == "b80b000000c3" # mov $11; ret
      # endbr64 preserved.
      check afterHex.startsWith(Endbr64Hex)
      # Bytes 4..7 are still NOPs: the window is at entry+8, not entry+4, and
      # entry+4 is guaranteed misaligned under -falign-functions=16.
      for i in 4 .. 7:
        check byteAt(afterHex, i) == "90"
      # Bytes 8..12 are the published `E9 rel32`; 13..15 are the `90 90 90`
      # tail of the same 8-byte store.
      check byteAt(afterHex, 8) == "e9"
      for i in 13 .. 15:
        check byteAt(afterHex, i) == "90"
      # Nothing outside the 8-byte window moved. This is the "single naturally
      # aligned store, never a straddling write" invariant of design §4.2, and
      # it is also what keeps the old body executable for in-flight frames.
      for i in 0 ..< 32:
        if i >= 8 and i < 16:
          continue
        check byteAt(afterHex, i) == byteAt(beforeHex, i)

      # 8. The rel32 the agent published points at the dispatch address it
      #    reported over the wire.
      let windowAddress = entryAddress + 8'u64
      check (windowAddress and 7'u64) == 0'u64
      var jmpBytes: seq[byte] = @[]
      for i in 8 .. 12:
        jmpBytes.add byte(parseHexInt(byteAt(afterHex, i)))
      let decoded = decodeX86_64JmpRel32Destination(windowAddress, jmpBytes)
      let dispatchAddress = parseHexInt(
        applied.dispatchAddress.replace("0x", "")).uint64
      check decoded == dispatchAddress
      # And the encoder produces exactly those bytes for that pair.
      let plan = x86_64JmpRel32(windowAddress, dispatchAddress, nopSledBytes = 16)
      check plan.kind == tkX86_64JmpRel32
      check plan.bytes == jmpBytes
      check hexBytes(x86_64PublishedWindowBytes(plan)) ==
        afterHex[16 ..< 32]

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m0.linux-inspection.v1")
      inspection["supportProfile"] = newJString(SupportProfile)
      inspection["patchBytesHex"] = newJString(hexBytes(patchBytes))
      inspection["targetResult"] = result
      inspection["patchApplied"] = %*{
        "patchId": applied.patchId,
        "entryAddress": applied.entryAddress,
        "dispatchAddress": applied.dispatchAddress,
        "oldCodeRetained": applied.oldCodeRetained,
        "symbolGeneration": applied.symbolGeneration
      }
      inspection["agentCapabilities"] =
        %delivery.session.agentCapabilities
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(
        logDir / "e2e_hcr_linux_x86_64_single_threaded_direct_patch.json",
        pretty(inspection))

else:
  suite "e2e_hcr_linux_x86_64_single_threaded_direct_patch":
    test "HLX-M0 direct patch gate is linux-x86_64-only":
      skip()
