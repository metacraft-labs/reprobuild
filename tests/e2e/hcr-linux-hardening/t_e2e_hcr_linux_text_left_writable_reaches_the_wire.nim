## HLX-M9 verification gate
## `e2e_hcr_linux_text_left_writable_reaches_the_wire`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §5.2.
## Milestones: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M9.
##
## WHAT THIS GATE IS FOR. Both HCR arms have always RECORDED the fact that a
## publication could not restore the target's text mapping to
## `PROT_READ|PROT_EXEC`, and HLX-M9 made the agent REPORT it, as
## `textLeftWritable` on the `patchApplied` frame.
##
## On Linux that state can no longer arise, and this gate now proves it rather
## than provoking it. The provider never makes target text writable: it builds
## the patched page as a separate copy, makes the copy executable, and remaps
## it over the live page (`repro_hcr_lx_replace_text_word`). The step that
## used to leave text writable when it failed — the post-store restore — does
## not exist, and the step that replaced it (making the COPY executable)
## fails BEFORE the target is touched. So the property is: a failed protection
## step is a clean refusal, the target keeps running its original code, and
## its text is executable and not writable throughout.
##
## `allowed_mocks: none`. Real GCC, the real patchable build profile, the
## production C agent linked into a real target process, the real agent Unix
## socket, the production `HcrCoordinatorClient`, and real patch bytes
## extracted from a real relocatable object.
##
## TWO ARMS, ONE BINARY, ONE VARIABLE. Both arms run the SAME target
## executable with the SAME patch bytes over the SAME socket transport. They
## differ in exactly one environment variable,
## `REPRO_HCR_TEST_FAIL_TEXT_RESTORE`, which makes the provider's step that
## turns the replacement page executable fail for site 0. It does not forge an
## outcome: the provider takes its production failure path.
##
## TWO INDEPENDENT PRODUCERS, REQUIRED TO AGREE. The first is the agent's
## frame (`patchApplied` with `textLeftWritable == false`, or `patchFailed`
## naming the protection failure). The second is the target's own reading of
## `/proc/self/maps` for the mapping containing the patched entry — written by
## the KERNEL, through a file the agent never touches. The gate requires
## executable-and-not-writable text in BOTH arms, and the target's own call
## result to show which code ran: the patched body (77) in the healthy arm,
## the original (11) in the faulted one, so a provider that published despite
## reporting a refusal — or refused while leaving a half-done page — fails.
##
## The wire field stays (the Apple arm can still set it), and its protocol
## round trip is still asserted.
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
    test "target text is never left writable, and a failed protection step is a clean refusal":
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

      # The provider could not make its replacement page executable, so it
      # must REFUSE, by name, before touching the target.
      ck faulted.refused
      checkpoint("faulted refusal: " & faulted.refusalMessage)
      ck faulted.refusalMessage.contains("text-protection-failed")
      ck faulted.targetJson["faultLeverSet"].getBool() == true
      ck faulted.targetJson["before"].getInt() == 11
      # The target still runs its ORIGINAL code: nothing was published.
      ck faulted.targetJson["after"].getInt() == 11

      # Second producer again: the kernel says the entry's text is still
      # executable and was not left writable.
      let faultedPerms = faulted.targetJson["entryPermsAfter"].getStr()
      checkpoint("faulted entryPermsAfter=" & faultedPerms)
      ck faultedPerms.contains('x')
      ck not faultedPerms.contains('w')

      # 5. The arms differ in the code that ran, not in the text's protection:
      # asserted directly rather than inferred from two constants
      # (Verification-Harness-Traps §22).
      ck healthy.targetJson["after"].getInt() !=
        faulted.targetJson["after"].getInt()
      ck healthyPerms == faultedPerms

      # 6. The field survives a protocol round trip, so a coordinator that
      # re-emits the frame does not drop it. Built here with the flag set,
      # since the Linux agent can no longer produce that frame.
      var leftWritable = healthy.applied
      leftWritable.textLeftWritable = true
      let reEmitted = parseAgentMessage(agentMessageJson(
        HcrAgentMessage(kind: hmkPatchApplied,
                        patchApplied: leftWritable)))
      ck reEmitted.patchApplied.textLeftWritable
      ck reEmitted.patchApplied.textLeftWritableReported

      expectCount(24)
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
