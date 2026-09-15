## HLX-M2 verification gate `e2e_hcr_linux_shared_library_sled_patch`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.2, §7.2, §7.3.
## Milestones: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M2 — the
## shared-library sled deliverable added to that block on 2026-09-15 from
## HLX-M1's recorded residue.
##
## THE QUESTION IT ANSWERS: can a function inside a `dlopen`ed `.so` be patched?
## Before this milestone it could not. HLX-M1's symbol pipeline spanned shared
## objects, so the function RESOLVED; sled discovery did not, because it read
## `__start___patchable_function_entries`, which names exactly one image — the
## one the agent was linked into. The refusal was `absent-sled`, and HLX-M1's
## residue recorded it as owned by HLX-M2.
##
## `allowed_mocks: none`. Everything is real: a real shared library built by a
## real GCC with the real patchable profile taken from `repro_project_dsl`, a
## real `dlopen` at runtime, real patch bytes extracted from a real relocatable
## object, the real agent Unix socket and the real wire protocol driven by the
## production `HcrCoordinatorClient`, and the real provider.
##
## DISCRIMINATION, because a green run here would otherwise be satisfiable by a
## provider that still read the executable's table. Both images in the process
## are patchable and both carry a non-empty `__patchable_function_entries`; the
## gate asserts the two ranges are disjoint, that BOTH are non-empty (the
## positive twin trap 4a asks for), and that the sled the provider used is
## inside the LIBRARY's. It then rebuilds the provider with
## `-DREPRO_HCR_HLX_M2_FALSIFY_MAIN_EXECUTABLE_ONLY_SLED`, which restores the
## pre-M2 reach, and asserts the SAME patch request is refused — measured fresh
## on every run, so an arm that stops discriminating cannot sit unnoticed
## (Verification-Harness-Traps.md trap 10).
##
## No silent skips on Linux x86_64: a missing compiler, a missing table or a
## missing sled is a LOUD failure. The `skip()` arm exists only for platforms
## that are not Linux x86_64.

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl

  import "../hcr-linux-direct/elf_rel_reader"

  const
    SupportProfile = HcrLinuxX86_64DirectSupportProfile
    TargetSymbol = "hcr_lx_m2_so_entry"
    PatchSymbol = "hcr_lx_m0_patch_body"
    Endbr64Hex = "f30f1efa"

  var asserted = 0
  template ck(message: string; condition: untyped) =
    ## Counted `check` (Verification-Harness-Traps.md 4c). The count is asserted
    ## at the end, so a silent early return or a skipped branch reddens the run
    ## on the spot instead of reporting fewer assertions with no failures.
    inc asserted
    if not (condition):
      checkpoint(message)
    check condition

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

  proc hexToUint(value: string): uint64 =
    parseHexInt(value.replace("0x", "")).uint64

  proc byteAt(hex: string; index: int): string =
    hex[index * 2 ..< index * 2 + 2]

  type RunOutcome = object
    output: string
    exitCode: int
    applied: Option[HcrPatchApplied]
    failed: Option[HcrPatchFailed]
    capabilities: seq[string]

  suite "e2e_hcr_linux_shared_library_sled_patch":
    test "a function inside a dlopen'd .so is patched: 11 -> 77":
      let repoRoot = getCurrentDir()
      let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-shared"
      let directDir = repoRoot / "tests" / "e2e" / "hcr-linux-direct"
      let workDir = repoRoot / "build" / "hcr-linux-m2-shared"
      let agentDir = repoRoot / "libs" / "repro_hcr_agent" / "c"
      createDir(workDir)

      let gcc = findExe("gcc")
      ck "gcc is on PATH", gcc.len > 0

      # 1. The patchable profile, from the DSL rather than retyped. A profile
      #    that emitted nothing would build a NON-patchable library that then
      #    refused `absent-sled` — indistinguishable, from the outside, from
      #    the very defect this gate exists to prove fixed.
      let compileFlags = patchableCompileFlags(ReproHcr())
      let linkFlags = patchableLinkFlags(ReproHcr())
      ck "the profile asks for a 16-NOP patchable entry",
        compileFlags.contains("-fpatchable-function-entry=16,0")
      ck "the profile asks for 16-byte function alignment",
        compileFlags.contains("-falign-functions=16")
      ck "the profile asks the linker for a build-id",
        linkFlags.contains("-Wl,--build-id=sha1")

      # 2. Real patch bytes out of a real relocatable object.
      let patchObj = workDir / "hcr_lx_m2_patch.o"
      discard runSuccess(shellCommand([
        "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
        directDir / "hcr_lx_m0_patch.c", "-o", patchObj]), repoRoot)
      let obj = parseElfRelObject(patchObj)
      ck "the patch body is self-contained (no relocations)",
        obj.relocationCount(".text." & PatchSymbol) == 0
      let patchBytes = obj.functionBytes(PatchSymbol)
      ck "the patch body has bytes", patchBytes.len > 0
      ck "the patch body carries its own endbr64 landing pad",
        hexBytes(patchBytes).startsWith(Endbr64Hex)
      ck "the patch body contains mov $0x4d,%eax",
        hexBytes(patchBytes).contains("b84d000000")

      # 3. The real shared library, and the real target that dlopens it.
      let libPath = workDir / "libhcr_lx_m2.so"
      discard runSuccess(shellCommand(
        @["gcc", "-O2", "-g", "-fPIC", "-shared"] & compileFlags &
        @["-fcf-protection=full", "-o", libPath,
          caseDir / "hcr_lx_m2_library.c"] & linkFlags), repoRoot)
      ck "the shared library was built", fileExists(libPath)
      # It must be patchable-SHAPED, asserted against the file rather than
      # assumed from the flags: section present, symbol table present,
      # build-id present.
      let readelfSections = runSuccess(
        shellCommand(["readelf", "-SW", libPath]), repoRoot)
      ck "the library carries __patchable_function_entries",
        readelfSections.contains("__patchable_function_entries")
      ck "the library carries a .symtab", readelfSections.contains(".symtab")
      let readelfNotes = runSuccess(
        shellCommand(["readelf", "-nW", libPath]), repoRoot)
      ck "the library carries a GNU build-id",
        readelfNotes.contains("Build ID")

      proc buildTarget(name: string; extraDefines: seq[string]): string =
        result = workDir / name
        discard runSuccess(shellCommand(
          @["gcc", "-O2", "-g"] & compileFlags &
          @["-fcf-protection=full", "-I", agentDir, "-o", result,
            caseDir / "hcr_lx_m2_so_target.c",
            agentDir / "repro_hcr_agent.c"] & extraDefines & linkFlags &
          @["-ldl", "-lpthread"]), repoRoot)

      proc runCase(targetBin: string; patchId: string): RunOutcome =
        let socketPath = workDir / (patchId & ".sock")
        removeFile(socketPath)
        var listener = listenHcrAgentUnixSocket(socketPath)
        defer: listener.close()
        var env = newStringTable()
        for key, value in envPairs():
          env[key] = value
        env[ReproHcrAgentSocketEnv] = socketPath
        let process = startProcess(targetBin, workingDir = repoRoot,
          args = @[libPath], env = env, options = {poStdErrToStdOut})
        var connection = acceptHcrAgentConnection(listener)
        var client = initHcrCoordinatorClient(SupportProfile)
        let request = directPatchRequest(
          patchId = patchId,
          supportProfile = SupportProfile,
          changedFunctions = [TargetSymbol],
          targetSymbols = [TargetSymbol],
          directPatchBytes = patchBytes,
          debugObjectBytes = [],
          unwindMetadataBytes = [],
          sourceGenerationMap = [])
        let delivery = client.deliverPatchRequest(connection, request)
        connection.close()
        result.output = process.outputStream.readAll()
        result.exitCode = process.waitForExit()
        process.close()
        result.applied = delivery.patchApplied
        result.failed = delivery.patchFailed
        result.capabilities = delivery.session.agentCapabilities

      let targetBin = buildTarget("hcr_lx_m2_so_target", @[])
      ck "the target was built", fileExists(targetBin)
      let run = runCase(targetBin, "hlx-m2-shared-1")
      if run.exitCode != 0:
        checkpoint(run.output)
      ck "the target exited cleanly", run.exitCode == 0
      if run.failed.isSome:
        checkpoint("agent refused the patch: " & run.failed.get().message)
      ck "the agent did not refuse the patch", run.failed.isNone
      require run.applied.isSome
      let applied = run.applied.get()
      ck "the wire reports the changed function",
        applied.changedFunctions == @[TargetSymbol]
      ck "the agent negotiated the linux direct-hcr profile",
        run.capabilities.contains("linux-x86_64-elf-direct-hcr")
      ck "direct patch injection was advertised",
        run.capabilities.contains("direct-patch-injection")

      let result = parseJson(run.output.strip())
      ck "the target emitted its schema",
        result["schemaId"].getStr() ==
          "reprobuild.hcr.hlx-m2.shared-library-target-result.v1"
      ck "the agent handshake succeeded", result["startRc"].getInt() == 0
      ck "the agent poll succeeded", result["pollRc"].getInt() == 0

      # 4. THE OBSERVABLE the deliverable names: the library's own return value.
      ck "the library returned 11 before the patch",
        result["before"].getInt() == 11
      ck "the library returns 77 after the patch",
        result["after"].getInt() == 77

      # 5. The function really is in the library and not in the executable.
      #    Two independent witnesses, because one of them could be wrong.
      ck "dl_iterate_phdr found an owning object",
        result["ownerFound"].getBool()
      ck "the owning object is the .so, not the main executable",
        result["ownerName"].getStr().endsWith("libhcr_lx_m2.so")
      ck "the .so has a non-zero load bias",
        hexToUint(result["ownerBias"].getStr()) != 0'u64
      ck "dladdr agrees", result["dladdrOk"].getBool()
      ck "dladdr names the same .so",
        result["dladdrObject"].getStr().endsWith("libhcr_lx_m2.so")

      # 6. TWO tables, both non-empty, disjoint — and the sled came from the
      #    library's. The two non-emptiness assertions are the positive twins:
      #    without them "the sled is not in the executable's range" is
      #    satisfied by an executable with no table at all (trap 4a).
      let exeStart = hexToUint(result["exeTableStart"].getStr())
      let exeStop = hexToUint(result["exeTableStop"].getStr())
      let libStart = hexToUint(result["libTableStart"].getStr())
      let libStop = hexToUint(result["libTableStop"].getStr())
      ck "the main executable has a non-empty patchable table",
        result["exeTableCount"].getInt() > 0
      ck "the library has a non-empty patchable table",
        result["libTableCount"].getInt() > 0
      ck "the two tables are disjoint", exeStop <= libStart or libStop <= exeStart
      let agentSection = hexToUint(result["agentSledSectionStart"].getStr())
      ck "the provider read the LIBRARY's table, not the executable's",
        agentSection >= libStart and agentSection < libStop
      ck "the provider did not read the executable's table",
        agentSection < exeStart or agentSection >= exeStop
      ck "the provider's own entry count matches the library's",
        result["agentSledEntryCount"].getInt() ==
          result["libTableCount"].getInt()
      ck "the provider names the library as the sled's object",
        result["agentSledObject"].getStr().endsWith("libhcr_lx_m2.so")
      ck "the provider did not call it the main executable",
        not result["agentSledIsMainExecutable"].getBool()
      ck "the provider's load bias equals the loader's",
        hexToUint(result["agentSledLoadBias"].getStr()) ==
          hexToUint(result["ownerBias"].getStr())
      ck "the provider reports no refusal",
        result["agentRefusal"].getStr() == "ok"
      # A near body needs no island; the far case is the other gate's subject.
      ck "the body was reached directly by rel32, with no island",
        result["agentTrampolineKind"].getInt() == 0

      # 7. Byte-level proof: one aligned 8-byte window changed, endbr64 lived.
      let beforeHex = result["entryBytesBeforeHex"].getStr()
      let afterHex = result["entryBytesAfterHex"].getStr()
      ck "32 bytes were dumped before", beforeHex.len == 64
      ck "32 bytes were dumped after", afterHex.len == 64
      ck "the entry was endbr64 + 16 NOPs before the patch",
        beforeHex.startsWith(Endbr64Hex & repeat("90", 16))
      ck "the old body returned 11",
        beforeHex[8 + 32 ..< 8 + 32 + 12] == "b80b000000c3"
      ck "endbr64 survived", afterHex.startsWith(Endbr64Hex)
      let entryAddress = hexToUint(result["entryAddress"].getStr())
      ck "the entry is 16-byte aligned", (entryAddress and 15'u64) == 0'u64
      ck "the published window starts with E9", byteAt(afterHex, 8) == "e9"
      for i in 4 .. 7:
        ck "byte " & $i & " is still a NOP", byteAt(afterHex, i) == "90"
      for i in 13 .. 15:
        ck "byte " & $i & " is the NOP tail of the 8-byte store",
          byteAt(afterHex, i) == "90"
      var outsideWindowIdentical = true
      for i in 0 ..< 32:
        if i >= 8 and i < 16:
          continue
        if byteAt(afterHex, i) != byteAt(beforeHex, i):
          outsideWindowIdentical = false
      ck "nothing outside the 8-byte window moved", outsideWindowIdentical

      # 8. FALSIFIER ARM. Rebuild the provider with the pre-M2 reach restored
      #    and assert the same request is refused. This is measured on every
      #    run, not recorded once: an arm whose causal path has been superseded
      #    keeps building and stops discriminating (trap 10).
      let falsifiedBin = buildTarget("hcr_lx_m2_so_target_falsified",
        @["-DREPRO_HCR_HLX_M2_FALSIFY_MAIN_EXECUTABLE_ONLY_SLED"])
      ck "the falsifier arm was built", fileExists(falsifiedBin)
      ck "the falsifier arm is a different binary from the plain one",
        getFileSize(falsifiedBin) != getFileSize(targetBin) or
          readFile(falsifiedBin) != readFile(targetBin)
      let falsified = runCase(falsifiedBin, "hlx-m2-shared-falsify")
      ck "the falsifier arm's target exited cleanly", falsified.exitCode == 0
      if falsified.failed.isNone:
        checkpoint("ARM-FAIL: the pre-M2 provider still applied the patch — " &
          "this gate is not reading the library's own sled table")
      ck "ARM: the pre-M2 provider REFUSES the shared-library patch",
        falsified.failed.isSome
      if falsified.failed.isSome:
        ck "ARM: the refusal is absent-sled, named",
          falsified.failed.get().message.contains("absent-sled")
        ck "ARM: and it names the cause as no owning object",
          falsified.failed.get().message.contains("sled-object-not-found")
      else:
        ck "ARM: the refusal is absent-sled, named", false
        ck "ARM: and it names the cause as no owning object", false
      let falsifiedResult = parseJson(falsified.output.strip())
      ck "ARM: the library still returns 11 under the pre-M2 provider",
        falsifiedResult["after"].getInt() == 11
      ck "ARM: not one byte of the library's entry changed",
        falsifiedResult["entryBytesAfterHex"].getStr() ==
          falsifiedResult["entryBytesBeforeHex"].getStr()

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m2.shared-library-inspection.v1")
      inspection["targetResult"] = result
      inspection["falsifierResult"] = falsifiedResult
      inspection["falsifierRefusal"] = newJString(
        if falsified.failed.isSome: falsified.failed.get().message else: "")
      inspection["patchBytesHex"] = newJString(hexBytes(patchBytes))
      inspection["patchableCompileFlags"] = %compileFlags
      inspection["patchableLinkFlags"] = %linkFlags
      inspection["agentCapabilities"] = %run.capabilities
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "e2e_hcr_linux_shared_library_sled_patch.json",
        pretty(inspection))

      # Trap 4c: the count is written from a run, and a silent skip cannot
      # reach the end of the check with it.
      if asserted != 62:
        checkpoint("assertion count is " & $asserted)
      check asserted == 62

else:
  suite "e2e_hcr_linux_shared_library_sled_patch":
    test "HLX-M2 shared-library sled gate is linux-x86_64-only":
      skip()
