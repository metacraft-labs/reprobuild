## HLX-M2 verification gate `e2e_hcr_linux_far_target_island_patch`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.2, §4.3, §12 item 1,
## `HCR/Trampoline-Mechanics.md` §1.2, §5.1, §6.
## Milestones: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M2.
##
## THE PROPERTY: a patch body outside +/-2 GiB of the publication window is
## still published with ONE naturally aligned 8-byte store containing a 5-byte
## `E9 rel32`. The 14 bytes that reach the far address live in an island in
## provider-owned memory, not in the target's text — because a 14-byte in-text
## write is not atomically publishable, and `Trampoline-Mechanics.md` §6's
## unamended ladder would have selected exactly that.
##
## `allowed_mocks: none`. Real target process built with the real patchable
## profile from `repro_project_dsl`, real patch bytes from a real relocatable
## object, real agent socket and wire protocol, real `mmap`/`mprotect`.
##
## WHAT IS AND IS NOT SIMULATED, stated plainly. The body's DISTANCE is real and
## is measured by this gate from the addresses the process reports; the 2 GiB
## gap is a real gap in a real address space. What the `far` mode removes is the
## near-first PREFERENCE that would otherwise make the far case unreachable in a
## process with free address space. Two arms keep that honest:
##
##   * `-DREPRO_HCR_HLX_M2_FALSIFY_ISLAND_DISABLED` removes the island and
##     nothing else. If the body were not genuinely out of reach, this arm would
##     publish anyway and stay green. It must go RED with
##     `patch-body-out-of-rel32-range`.
##   * the target writes a 14-byte `FF 25 00 00 00 00; .quad` over an UNTOUCHED
##     decoy's sled — the widened store — so this gate's byte predicates are
##     seen to reject that shape rather than merely accept the real one.

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl

  import "../hcr-linux-direct/elf_rel_reader"

  const
    SupportProfile = HcrLinuxX86_64DirectSupportProfile
    TargetSymbol = "hcr_lx_m2_far_entry"
    PatchSymbol = "hcr_lx_m0_patch_body"
    Endbr64Hex = "f30f1efa"
    Rel32Reach = 0x7fffffff'i64

  var asserted = 0
  template ck(message: string; condition: untyped) =
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

  suite "e2e_hcr_linux_far_target_island_patch":
    test "a body beyond 2 GiB is reached through an island, store still 5 bytes":
      let repoRoot = getCurrentDir()
      let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-far"
      let directDir = repoRoot / "tests" / "e2e" / "hcr-linux-direct"
      let workDir = repoRoot / "build" / "hcr-linux-m2-far"
      let agentDir = repoRoot / "libs" / "repro_hcr_agent" / "c"
      createDir(workDir)

      ck "gcc is on PATH", findExe("gcc").len > 0

      let compileFlags = patchableCompileFlags(ReproHcr())
      let linkFlags = patchableLinkFlags(ReproHcr())
      ck "the profile asks for a 16-NOP patchable entry",
        compileFlags.contains("-fpatchable-function-entry=16,0")
      ck "the profile asks the linker for a build-id",
        linkFlags.contains("-Wl,--build-id=sha1")

      let patchObj = workDir / "hcr_lx_m2_patch.o"
      discard runSuccess(shellCommand([
        "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
        directDir / "hcr_lx_m0_patch.c", "-o", patchObj]), repoRoot)
      let obj = parseElfRelObject(patchObj)
      ck "the patch body is self-contained",
        obj.relocationCount(".text." & PatchSymbol) == 0
      let patchBytes = obj.functionBytes(PatchSymbol)
      ck "the patch body has bytes", patchBytes.len > 0

      proc buildTarget(name: string; defines: seq[string]): string =
        result = workDir / name
        discard runSuccess(shellCommand(
          @["gcc", "-O2", "-g"] & compileFlags &
          @["-fcf-protection=full", "-I", agentDir, "-o", result,
            caseDir / "hcr_lx_m2_far_target.c",
            agentDir / "repro_hcr_agent.c"] & defines & linkFlags &
          @["-lpthread"]), repoRoot)

      proc runCase(targetBin, mode, patchId: string): RunOutcome =
        let socketPath = workDir / (patchId & ".sock")
        removeFile(socketPath)
        var listener = listenHcrAgentUnixSocket(socketPath)
        defer: listener.close()
        var env = newStringTable()
        for key, value in envPairs():
          env[key] = value
        env[ReproHcrAgentSocketEnv] = socketPath
        let process = startProcess(targetBin, workingDir = repoRoot,
          args = @[mode], env = env, options = {poStdErrToStdOut})
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

      let targetBin = buildTarget("hcr_lx_m2_far_target", @[])
      ck "the target was built", fileExists(targetBin)

      # ---------------------------------------------------------------------
      # 1. The NEAR control, same binary. It establishes that this function is
      #    patchable at all and that the near path still selects a direct
      #    rel32 — so the far run's island is attributable to the distance and
      #    not to something else about the target.
      # ---------------------------------------------------------------------
      let nearRun = runCase(targetBin, "plain", "hlx-m2-near")
      if nearRun.exitCode != 0:
        checkpoint(nearRun.output)
      ck "the near control exited cleanly", nearRun.exitCode == 0
      ck "the near control was applied", nearRun.failed.isNone
      let near = parseJson(nearRun.output.strip())
      ck "the near control returned 11 first", near["before"].getInt() == 11
      ck "the near control returns 77", near["after"].getInt() == 77
      ck "the near control used a direct rel32, no island",
        near["agentTrampolineKind"].getInt() == 0
      ck "the near control allocated no island",
        hexToUint(near["agentIslandAddress"].getStr()) == 0'u64
      ck "the near control's body IS within rel32 reach",
        abs(near["agentBodyDisplacement"].getBiggestInt()) <= Rel32Reach

      # ---------------------------------------------------------------------
      # 2. THE FAR RUN.
      # ---------------------------------------------------------------------
      let farRun = runCase(targetBin, "far", "hlx-m2-far")
      if farRun.exitCode != 0:
        checkpoint(farRun.output)
      ck "the far target exited cleanly", farRun.exitCode == 0
      if farRun.failed.isSome:
        checkpoint("agent refused: " & farRun.failed.get().message)
      ck "the far patch was applied", farRun.failed.isNone
      require farRun.applied.isSome
      let far = parseJson(farRun.output.strip())
      ck "the far run emitted its schema",
        far["schemaId"].getStr() ==
          "reprobuild.hcr.hlx-m2.far-target-result.v1"
      ck "the agent handshake succeeded", far["startRc"].getInt() == 0
      ck "the agent poll succeeded", far["pollRc"].getInt() == 0

      # The distance is MEASURED, not asserted from the lever's name.
      let displacement = far["agentBodyDisplacement"].getBiggestInt()
      if abs(displacement) <= Rel32Reach:
        checkpoint("the body was NOT out of rel32 reach: displacement = " &
          $displacement)
      ck "the body really is beyond rel32 reach",
        abs(displacement) > Rel32Reach
      let windowAddress = hexToUint(far["agentWindowAddress"].getStr())
      let dispatchAddress = hexToUint(far["agentDispatchAddress"].getStr())
      let islandAddress = hexToUint(far["agentIslandAddress"].getStr())
      ck "an island was allocated", islandAddress != 0'u64
      ck "the provider recorded the island trampoline kind",
        far["agentTrampolineKind"].getInt() == 1
      ck "exactly one island was allocated in this process",
        far["agentIslandAllocCount"].getInt() == 1

      # The island is within +/-2 GiB of the WINDOW — that is the whole point.
      let islandDisplacement =
        int64(islandAddress) - int64(windowAddress + 5'u64)
      ck "the island is inside rel32 reach of the window",
        abs(islandDisplacement) <= Rel32Reach

      # 3. The observable.
      ck "the far target returned 11 before", far["before"].getInt() == 11
      ck "the far target returns 77 after", far["after"].getInt() == 77

      # 4. THE PUBLISHED STORE IS STILL 5 BYTES OF `E9 rel32` IN ONE WORD.
      let beforeHex = far["entryBytesBeforeHex"].getStr()
      let afterHex = far["entryBytesAfterHex"].getStr()
      ck "32 bytes were dumped before", beforeHex.len == 64
      ck "32 bytes were dumped after", afterHex.len == 64
      ck "the entry was endbr64 + 16 NOPs",
        beforeHex.startsWith(Endbr64Hex & repeat("90", 16))
      ck "endbr64 survived", afterHex.startsWith(Endbr64Hex)
      let entryAddress = hexToUint(far["entryAddress"].getStr())
      ck "the window is 8-byte aligned", (windowAddress and 7'u64) == 0'u64
      let windowOffset = int(windowAddress - entryAddress)
      ck "the window lies inside the dumped bytes",
        windowOffset >= 0 and windowOffset + 8 <= 32
      ck "the published word starts with E9",
        byteAt(afterHex, windowOffset) == "e9"
      ck "the published word is NOT the 14-byte FF 25 form",
        byteAt(afterHex, windowOffset) & byteAt(afterHex, windowOffset + 1) !=
          "ff25"
      for i in 5 .. 7:
        ck "byte " & $i & " of the window is the 0x90 tail",
          byteAt(afterHex, windowOffset + i) == "90"
      var outsideWindowIdentical = true
      for i in 0 ..< 32:
        if i >= windowOffset and i < windowOffset + 8:
          continue
        if byteAt(afterHex, i) != byteAt(beforeHex, i):
          outsideWindowIdentical = false
      ck "nothing outside the 8-byte window moved", outsideWindowIdentical

      # 5. The target followed the jump ITSELF. These are the assertions that
      #    do not go through the provider's bookkeeping.
      ck "the target could read the island", far["islandReadable"].getBool()
      ck "the rel32 the target decoded points at the island",
        hexToUint(far["rel32Destination"].getStr()) == islandAddress
      let islandHex = far["islandBytesHex"].getStr()
      ck "the island is jmp *0(%rip) with a zero displacement",
        islandHex.startsWith("ff2500000000")
      ck "the island's .quad is the patch body",
        hexToUint(far["islandTarget"].getStr()) == dispatchAddress
      ck "the island is exactly 14 bytes", islandHex.len == 28

      # ---------------------------------------------------------------------
      # 6. ARM A — the widened store, written by the target over an untouched
      #    decoy. The gate's own byte predicates must REJECT it. Without this,
      #    "the published word starts with E9" is a check that has never been
      #    seen to fail.
      # ---------------------------------------------------------------------
      ck "the widened-store demonstration was written",
        far["widenWritten"].getBool()
      let decoyBefore = far["decoyBytesBeforeHex"].getStr()
      let decoyAfter = far["decoyBytesAfterHex"].getStr()
      ck "the decoy was endbr64 + NOPs before",
        decoyBefore.startsWith(Endbr64Hex & repeat("90", 16))
      ck "ARM: a widened store does NOT start with E9",
        byteAt(decoyAfter, 8) != "e9"
      ck "ARM: a widened store starts with FF 25",
        byteAt(decoyAfter, 8) & byteAt(decoyAfter, 9) == "ff25"
      var decoyOutsideWindowMoved = false
      for i in 0 ..< 32:
        if i >= 8 and i < 16:
          continue
        if byteAt(decoyAfter, i) != byteAt(decoyBefore, i):
          decoyOutsideWindowMoved = true
      ck "ARM: a widened store moves bytes OUTSIDE the 8-byte window",
        decoyOutsideWindowMoved

      # ---------------------------------------------------------------------
      # 7. ARM B — islands removed. The far body then has no publishable
      #    encoding, which is only true if it really is out of reach.
      # ---------------------------------------------------------------------
      let armBin = buildTarget("hcr_lx_m2_far_target_no_island",
        @["-DREPRO_HCR_HLX_M2_FALSIFY_ISLAND_DISABLED"])
      ck "the island-disabled arm was built", fileExists(armBin)
      let armRun = runCase(armBin, "far", "hlx-m2-far-arm")
      ck "the arm's target exited cleanly", armRun.exitCode == 0
      if armRun.failed.isNone:
        checkpoint("ARM-FAIL: the far body published with islands disabled — " &
          "it was never out of rel32 reach and this gate proves nothing")
      ck "ARM: with islands removed the far body is REFUSED",
        armRun.failed.isSome
      if armRun.failed.isSome:
        ck "ARM: the refusal is named patch-body-out-of-rel32-range",
          armRun.failed.get().message.contains("patch-body-out-of-rel32-range")
      else:
        ck "ARM: the refusal is named patch-body-out-of-rel32-range", false
      let arm = parseJson(armRun.output.strip())
      ck "ARM: the function still returns 11", arm["after"].getInt() == 11
      ck "ARM: not one byte of the entry changed",
        arm["entryBytesAfterHex"].getStr() ==
          arm["entryBytesBeforeHex"].getStr()

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m2.far-target-inspection.v1")
      inspection["nearControl"] = near
      inspection["farRun"] = far
      inspection["islandDisabledArm"] = arm
      inspection["islandDisabledRefusal"] = newJString(
        if armRun.failed.isSome: armRun.failed.get().message else: "")
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "e2e_hcr_linux_far_target_island_patch.json",
        pretty(inspection))

      if asserted != 53:
        checkpoint("assertion count is " & $asserted)
      check asserted == 53

else:
  suite "e2e_hcr_linux_far_target_island_patch":
    test "HLX-M2 island gate is linux-x86_64-only":
      skip()
