## HLX-M2 verification gate `integration_hcr_linux_island_exhaustion_refuses`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.2, §4.3, §12 item 1.
## Milestones: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M2.
##
## THE PROPERTY: when the +/-2 GiB region around the publication window holds no
## free page, there is nowhere to put an island, and the provider REFUSES the
## function by name and reports it in `skippedFunctions`. It does not fall back
## to a 13- or 14-byte in-text write — the encoding `Trampoline-Mechanics.md`
## §6's unamended ladder selects at that point, and the one thing this milestone
## exists to make unselectable, because it is not atomically publishable.
##
## `allowed_mocks: none`. The exhaustion is real: the target reads its own
## `/proc/self/maps` and fills every gap in [window-2GiB, window+2GiB] with real
## `PROT_NONE` `MAP_FIXED_NOREPLACE` mappings before the patch request arrives.
##
## DISCRIMINATION. A refusal is the easiest result in the world to produce by
## accident — an unpatchable target, a missing sled, a broken socket all look
## the same from here. Two things keep it honest:
##
##   * the POSITIVE CONTROL runs THE SAME BINARY in `plain` mode and must return
##     77. So the function is patchable, in this build, in this process shape,
##     and only the reservation is different.
##   * the reservation's own counters are asserted non-trivial. A reservation
##     that filled nothing would make the refusal meaningless and the gate
##     vacuous — Verification-Harness-Traps.md trap 4's empty-set pass, arriving
##     through a `/proc/self/maps` parse that matched nothing.

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl

  import "../hcr-linux-direct/elf_rel_reader"

  const
    SupportProfile = HcrLinuxX86_64DirectSupportProfile
    TargetSymbol = "hcr_lx_m2_far_entry"
    PatchSymbol = "hcr_lx_m0_patch_body"
    OneGiB = 1024 * 1024 * 1024

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

  type RunOutcome = object
    output: string
    exitCode: int
    applied: Option[HcrPatchApplied]
    failed: Option[HcrPatchFailed]

  suite "integration_hcr_linux_island_exhaustion_refuses":
    test "an exhausted +/-2 GiB region refuses by name and writes nothing":
      let repoRoot = getCurrentDir()
      let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-far"
      let directDir = repoRoot / "tests" / "e2e" / "hcr-linux-direct"
      let workDir = repoRoot / "build" / "hcr-linux-m2-exhaust"
      let agentDir = repoRoot / "libs" / "repro_hcr_agent" / "c"
      createDir(workDir)

      ck "gcc is on PATH", findExe("gcc").len > 0
      let compileFlags = patchableCompileFlags(ReproHcr())
      let linkFlags = patchableLinkFlags(ReproHcr())
      ck "the profile asks for a 16-NOP patchable entry",
        compileFlags.contains("-fpatchable-function-entry=16,0")

      let patchObj = workDir / "hcr_lx_m2_patch.o"
      discard runSuccess(shellCommand([
        "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
        directDir / "hcr_lx_m0_patch.c", "-o", patchObj]), repoRoot)
      let obj = parseElfRelObject(patchObj)
      let patchBytes = obj.functionBytes(PatchSymbol)
      ck "the patch body has bytes", patchBytes.len > 0

      let targetBin = workDir / "hcr_lx_m2_exhaust_target"
      discard runSuccess(shellCommand(
        @["gcc", "-O2", "-g"] & compileFlags &
        @["-fcf-protection=full", "-I", agentDir, "-o", targetBin,
          caseDir / "hcr_lx_m2_far_target.c",
          agentDir / "repro_hcr_agent.c"] & linkFlags & @["-lpthread"]),
        repoRoot)
      ck "the target was built", fileExists(targetBin)

      proc runCase(mode, patchId: string): RunOutcome =
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

      # ---------------------------------------------------------------------
      # 1. POSITIVE CONTROL — same binary, no reservation.
      # ---------------------------------------------------------------------
      let controlRun = runCase("plain", "hlx-m2-exhaust-control")
      if controlRun.exitCode != 0:
        checkpoint(controlRun.output)
      ck "the control exited cleanly", controlRun.exitCode == 0
      if controlRun.failed.isSome:
        checkpoint("the control was refused: " &
          controlRun.failed.get().message)
      ck "the control was applied", controlRun.failed.isNone
      let control = parseJson(controlRun.output.strip())
      ck "the control returned 11 before", control["before"].getInt() == 11
      ck "the control returns 77 after — this function IS patchable",
        control["after"].getInt() == 77
      ck "the control reserved nothing",
        control["reservationGapsFilled"].getInt() == 0

      # ---------------------------------------------------------------------
      # 2. THE EXHAUSTED RUN.
      # ---------------------------------------------------------------------
      let exhaustRun = runCase("exhaust", "hlx-m2-exhaust")
      if exhaustRun.exitCode != 0:
        checkpoint(exhaustRun.output)
      ck "the exhausted target exited cleanly", exhaustRun.exitCode == 0
      let exhaust = parseJson(exhaustRun.output.strip())

      # The reservation is the gate's subject; assert it happened before
      # asserting anything about what it caused.
      ck "the reservation filled at least one gap",
        exhaust["reservationGapsFilled"].getInt() > 0
      ck "the reservation covered at least 1 GiB",
        exhaust["reservationBytes"].getBiggestInt() >= OneGiB
      ck "no MAP_FIXED_NOREPLACE in the reservation failed",
        exhaust["reservationMapFailures"].getInt() == 0
      # 4 GiB, give or take the page-alignment of the two outer bounds.
      ck "the reserved region spans the full +/-2 GiB rel32 reach",
        parseHexInt(exhaust["reservationHigh"].getStr().replace("0x", "")) -
          parseHexInt(exhaust["reservationLow"].getStr().replace("0x", "")) >=
          0x100000000

      if exhaustRun.failed.isNone:
        checkpoint("the provider APPLIED a patch with no page free within " &
          "+/-2 GiB — either the reservation missed, or the store was widened")
      ck "the provider refused", exhaustRun.failed.isSome
      require exhaustRun.failed.isSome
      let failed = exhaustRun.failed.get()
      ck "the refusal is named island-unplaceable",
        failed.message.contains("island-unplaceable")
      ck "the refusal is NOT patch-memory-unavailable",
        not failed.message.contains("patch-memory-unavailable")
      ck "the provider's own report names island-unplaceable",
        exhaust["agentRefusal"].getStr() == "island-unplaceable"

      # The deliverable says `skippedFunctions`, so assert the structured field
      # and not only the message.
      ck "skippedFunctions carries exactly one entry",
        failed.skippedFunctions.len == 1
      if failed.skippedFunctions.len == 1:
        ck "skippedFunctions names the function",
          failed.skippedFunctions[0].function == TargetSymbol
        ck "skippedFunctions names the reason",
          failed.skippedFunctions[0].reason == "island-unplaceable"
        ck "skippedFunctions carries the window address",
          failed.skippedFunctions[0].windowAddress.startsWith("0x") and
            failed.skippedFunctions[0].windowAddress != "0x0"
      else:
        ck "skippedFunctions names the function", false
        ck "skippedFunctions names the reason", false
        ck "skippedFunctions carries the window address", false

      # ---------------------------------------------------------------------
      # 3. NOTHING WAS WRITTEN. This is the half that matters: a refusal that
      #    had already widened the store would still be a refusal.
      # ---------------------------------------------------------------------
      ck "the function still returns 11", exhaust["after"].getInt() == 11
      let beforeHex = exhaust["entryBytesBeforeHex"].getStr()
      let afterHex = exhaust["entryBytesAfterHex"].getStr()
      ck "32 bytes were dumped", beforeHex.len == 64 and afterHex.len == 64
      ck "the entry is byte-identical after the refusal", afterHex == beforeHex
      ck "no jmp [rip+0] was written into the text",
        not afterHex.contains("ff2500000000")
      ck "no movabs %r11 was written into the text",
        not afterHex.contains("49bb")
      ck "no E9 was written into the text", not afterHex.contains("e9")
      ck "no island was allocated",
        exhaust["agentIslandAllocCount"].getInt() == 0
      # Trampoline-Mechanics §5.1 names TWO placement strategies, and a refusal
      # that only proves the outward probe failed would say nothing about the
      # second. Assert the `/proc/self/maps` gap finder was asked — twice, once
      # for the body page and once for the island — and found nothing both
      # times. Without the first half, "no gap was found" and "nobody looked"
      # are the same report.
      ck "the /proc/self/maps gap finder ran",
        exhaust["agentGapScanCount"].getInt() >= 2
      ck "the gap finder placed nothing in the exhausted region",
        exhaust["agentGapHitCount"].getInt() == 0
      ck "the control needed no gap scan at all — the outward probe sufficed",
        control["agentGapScanCount"].getInt() == 0

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m2.island-exhaustion-inspection.v1")
      inspection["control"] = control
      inspection["exhausted"] = exhaust
      inspection["refusalMessage"] = newJString(failed.message)
      inspection["skippedFunctions"] = %*[
        {"function": failed.skippedFunctions[0].function,
         "reason": failed.skippedFunctions[0].reason,
         "windowAddress": failed.skippedFunctions[0].windowAddress}]
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "integration_hcr_linux_island_exhaustion_refuses.json",
        pretty(inspection))

      if asserted != 32:
        checkpoint("assertion count is " & $asserted)
      check asserted == 32

else:
  suite "integration_hcr_linux_island_exhaustion_refuses":
    test "HLX-M2 island exhaustion gate is linux-x86_64-only":
      skip()
