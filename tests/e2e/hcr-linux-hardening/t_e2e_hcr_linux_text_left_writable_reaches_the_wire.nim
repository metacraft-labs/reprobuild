## HLX-M9 verification gate
## `e2e_hcr_linux_text_left_writable_reaches_the_wire`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §5.2.
## Milestones: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M9.
##
## WHAT THIS GATE IS FOR. Both HCR arms have always RECORDED the fact that a
## publication could not restore the target's text mapping to
## `PROT_READ|PROT_EXEC`, and neither has ever REPORTED it: the Linux value
## died in `repro_hcr_lx_last_report.text_left_writable`, read by one probe
## accessor nothing called, and the Apple value in
## `repro_hcr_apple_text_left_writable`, the same. A process in that state is
## carrying writable executable text for the rest of its lifetime and the only
## way to find out was to go looking with a gate. HLX-M9 owns it because this
## milestone's subject is what a host's hardening policy does to the RW->RX
## round trip.
##
## `allowed_mocks: none`. Real GCC, the real patchable build profile, the
## production C agent linked into a real target process, the real agent Unix
## socket, the production `HcrCoordinatorClient`, and real patch bytes
## extracted from a real relocatable object.
##
## TWO ARMS, ONE BINARY, ONE VARIABLE. Both arms run the SAME target
## executable with the SAME patch bytes over the SAME socket transport. They
## differ in exactly one environment variable,
## `REPRO_HCR_TEST_FAIL_TEXT_RESTORE`, which makes the provider skip the
## post-store restore syscall for site 0. It does NOT forge the flag: the
## syscall is not issued, so the page really is left writable, which is what
## makes the second producer below meaningful.
##
## TWO INDEPENDENT PRODUCERS, REQUIRED TO AGREE. The first is the agent's new
## `textLeftWritable` field on the `patchApplied` frame. The second is the
## target's own reading of `/proc/self/maps` for the mapping containing the
## patched entry — written by the KERNEL, through a file the agent never
## touches. Asserting only the first would be asserting the agent's bookkeeping
## against itself (Verification-Harness-Traps §7a). The gate requires
## `textLeftWritable == false` AND `r-xp` in the healthy arm, and
## `textLeftWritable == true` AND a `w` in the permission string in the faulted
## arm, so a provider that set the flag without leaving the page writable — or
## left it writable without setting the flag — fails.
##
## ANTI-VACUITY. The faulted arm asserts the PATCH STILL WORKED (11 -> 77): the
## whole design decision this field embodies is that a failed restore is a
## successful publication plus a degradation, not a refusal. An arm in which
## the patch failed would prove nothing about the field's severity. Both arms
## also assert `patchFailed.isNone`, so neither can be satisfied by a refusal.
##
## NO SILENT SKIP on Linux x86_64. Off-platform prints the loud unsupported
## diagnostic through the shared helper rather than a bare `skip()`.

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

import repro_test_support

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl

  # The real ELF relocatable reader HLX-M0 wrote, imported by path rather than
  # copied: a second reader would agree with itself while the first was wrong
  # (Verification-Harness-Traps §30a).
  import "../hcr-linux-direct/elf_rel_reader"

  let PatchableCompileFlags = patchableCompileFlags(ReproHcr())
  let PatchableLinkFlags = patchableLinkFlags(ReproHcr())

  const
    SupportProfile = HcrLinuxX86_64DirectSupportProfile
    TargetSymbol = "hcr_lx_m9_entry"
    PatchSymbol = "hcr_lx_m9_patch_body"

  type ArmResult = object
    targetJson: JsonNode
    applied: HcrPatchApplied
    refused: bool
    refusalMessage: string

  var assertionCount = 0

  template ck(condition: untyped) =
    ## Verification-Harness-Traps §4c. The count is written last, from a run;
    ## an arm that returned early or threw cannot reach `expectCount` with it.
    assertionCount += 1
    check condition

  template expectCount(expected: int) =
    check assertionCount == expected

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

  proc runArm(targetBin, workDir, repoRoot, socketName: string;
              patchBytes: seq[byte]; failRestore: bool): ArmResult =
    let socketPath = workDir / socketName
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()

    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env[ReproHcrAgentSocketEnv] = socketPath
    if failRestore:
      env["REPRO_HCR_TEST_FAIL_TEXT_RESTORE"] = "1"
    else:
      # Inherited environments are a real hazard for a lever keyed on mere
      # presence: `getenv` returns non-NULL for an empty value too.
      env.del("REPRO_HCR_TEST_FAIL_TEXT_RESTORE")

    let process = startProcess(targetBin, workingDir = repoRoot,
      env = env, options = {poStdErrToStdOut})

    var connection = acceptHcrAgentConnection(listener)
    var client = initHcrCoordinatorClient(SupportProfile)
    let request = directPatchRequest(
      patchId = "hlx-m9-" & (if failRestore: "faulted" else: "healthy"),
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
      checkpoint("target exited " & $exitCode & ": " & output)
    require exitCode == 0

    var targetLine = ""
    for line in output.splitLines():
      if line.startsWith("{\"schemaId\":\"reprobuild.hcr.hlx-m9."):
        targetLine = line
    if targetLine.len == 0:
      checkpoint("target printed no result line: " & output)
    require targetLine.len > 0

    result.targetJson = parseJson(targetLine)
    result.refused = delivery.patchFailed.isSome
    if result.refused:
      result.refusalMessage = delivery.patchFailed.get().message
    else:
      require delivery.patchApplied.isSome
      result.applied = delivery.patchApplied.get()

  suite "e2e_hcr_linux_text_left_writable_reaches_the_wire":
    test "a failed text restore is reported on the applied frame, and procfs agrees":
      let found = findExe("gcc")
      if found.len == 0:
        checkpoint("required compiler not on PATH: gcc")
      require found.len > 0

      let repoRoot = getCurrentDir()
      let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-hardening"
      let workDir = repoRoot / "build" / "hcr-linux-m9"
      let binDir = repoRoot / "build" / "test-bin"
      createDir(workDir)
      createDir(binDir)

      # 1. Real patch body from a real relocatable object.
      let patchObj = workDir / "hcr_lx_m9_patch.o"
      discard runSuccess(shellCommand([
        "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
        caseDir / "hcr_lx_m9_patch.c", "-o", patchObj]), repoRoot)
      let obj = parseElfRelObject(patchObj)
      let patchSection = obj.definingSectionName(PatchSymbol)
      ck patchSection == ".text." & PatchSymbol
      ck obj.relocationCount(patchSection) == 0
      let patchBytes = obj.functionBytes(PatchSymbol)
      ck patchBytes.len > 0

      # 2. Real target with the real patchable profile and the production agent.
      let targetBin = binDir / "hcr_lx_m9_target"
      ck PatchableCompileFlags.contains("-fpatchable-function-entry=16,0")
      discard runSuccess(shellCommand(
        @["gcc", "-O2", "-g"] & PatchableCompileFlags &
        @["-fcf-protection=full",
        "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
        "-o", targetBin,
        caseDir / "hcr_lx_m9_target.c",
        repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"] &
        PatchableLinkFlags & @["-lpthread"]), repoRoot)
      ck fileExists(targetBin)

      # 3. HEALTHY ARM — the lever is unset, everything behaves.
      let healthy = runArm(targetBin, workDir, repoRoot, "m9-healthy.sock",
                           patchBytes, failRestore = false)
      ck not healthy.refused
      ck healthy.targetJson["faultLeverSet"].getBool() == false
      ck healthy.targetJson["before"].getInt() == 11
      ck healthy.targetJson["after"].getInt() == 77

      # The field is PRESENT, which is a separate fact from its value: an agent
      # predating this milestone omits it, and `textLeftWritableReported` is
      # how the coordinator tells "reported false" from "never reported".
      ck healthy.applied.textLeftWritableReported
      ck healthy.applied.textLeftWritable == false

      # Second producer: the kernel. Executable, NOT writable.
      let healthyPerms = healthy.targetJson["entryPermsAfter"].getStr()
      checkpoint("healthy entryPermsAfter=" & healthyPerms)
      ck healthyPerms.contains('x')
      ck not healthyPerms.contains('w')

      # 4. FAULTED ARM — one environment variable different, same binary.
      let faulted = runArm(targetBin, workDir, repoRoot, "m9-faulted.sock",
                           patchBytes, failRestore = true)

      # The design decision this field embodies: a failed restore is a
      # SUCCESSFUL publication plus a degradation. An arm in which the patch
      # was refused would say nothing about the field's severity.
      ck not faulted.refused
      ck faulted.targetJson["faultLeverSet"].getBool() == true
      ck faulted.targetJson["before"].getInt() == 11
      ck faulted.targetJson["after"].getInt() == 77

      ck faulted.applied.textLeftWritableReported
      ck faulted.applied.textLeftWritable == true

      # Second producer again, and this is the assertion that makes the flag
      # mean something: the page really is writable, according to procfs.
      let faultedPerms = faulted.targetJson["entryPermsAfter"].getStr()
      checkpoint("faulted entryPermsAfter=" & faultedPerms)
      ck faultedPerms.contains('w')
      ck faultedPerms.contains('x')

      # 5. The two arms must DIFFER, asserted directly rather than inferred
      # from two separate constants (Verification-Harness-Traps §22: a
      # cross-check whose sides come from one expression is an identity).
      ck healthy.applied.textLeftWritable != faulted.applied.textLeftWritable
      ck healthyPerms != faultedPerms

      # 6. The field survives a protocol round trip, so a coordinator that
      # re-emits the frame does not drop it.
      let reEmitted = parseAgentMessage(agentMessageJson(
        HcrAgentMessage(kind: hmkPatchApplied,
                        patchApplied: faulted.applied)))
      ck reEmitted.patchApplied.textLeftWritable
      ck reEmitted.patchApplied.textLeftWritableReported

      expectCount(25)
else:
  suite "e2e_hcr_linux_text_left_writable_reaches_the_wire":
    test "requires linux x86_64":
      # Two mechanisms, deliberately, because they answer to two different
      # readers. `announceHcrUnsupportedHost` is the string HX-S-10's lane
      # runner greps for — one function, three call sites, so a paraphrase
      # cannot silently stop satisfying it. `[platform N/A]` is
      # `check_vacuous_test_cases.py`'s sanctioned marker, which is how an
      # assertionless case earns its exemption VISIBLY instead of being
      # written into a baseline nobody rereads.
      echo "[platform N/A] e2e_hcr_linux_text_left_writable_reaches_the_wire: " &
        "the fault lever is a Linux mprotect/procfs pair; the lane manifest " &
        "declares this gate unsupported on macOS arm64 and Windows x86_64."
      announceHcrUnsupportedHost(
        "e2e_hcr_linux_text_left_writable_reaches_the_wire",
        "Linux x86_64", "the linux-x86_64 HCR lane")
      skip()
