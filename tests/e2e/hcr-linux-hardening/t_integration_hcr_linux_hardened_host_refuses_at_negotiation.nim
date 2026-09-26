## HLX-M9 verification gate
## `integration_hcr_linux_hardened_host_refuses_at_negotiation`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §5.2, §14.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M9 — the deliverable
## "Capability-time refusal: when the host cannot support patching, say so
## during negotiation with a diagnostic naming the blocking policy."
##
## ---------------------------------------------------------------------------
## WHAT WAS WRONG
##
## The host capability probe has run at agent start since HLX-M0 and the
## provider has refused an unsupported host since HLX-M4 — but it refused in
## `repro_hcr_lx_txn_prepare`, i.e. at the FIRST RELOAD, under the name
## `REPRO_HCR_LX_REFUSED_UNSUPPORTED_HOST`. A developer on a hardened host
## learned that HCR cannot work there by editing a file, waiting for a
## rebuild, and receiving a refusal that named a symptom and no policy. The
## coordinator, told nothing at negotiation, went on offering a patch per edit.
##
## ---------------------------------------------------------------------------
## WHAT MAKES THIS GATE DISCRIMINATE
##
## THE HARDENING IS A REAL KERNEL POLICY. The faulted arm calls
## `prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN)` on itself before the agent
## starts. Nothing is stubbed, no environment variable is read, and no failure
## is injected — the kernel refuses `mprotect(PROT_READ|PROT_EXEC)` on a
## mapping that has been writable, which is exactly the policy class §5.2
## describes. Measured independently on this host (Linux 6.12.85): with MDWE
## set, `mprotect(RW)` answers 0 and `mprotect(RX)` answers `-EACCES`; without
## it, both answer 0.
##
## TWO ARMS, ONE BINARY, ONE ARGV FLAG. The healthy arm negotiates, receives a
## patch and goes 11 -> 77. The hardened arm is REFUSED AT NEGOTIATION, before
## any patch is sent.
##
## THE REFUSAL IS ASSERTED TO BE EARLY, not merely to exist. The hardened arm
## asserts that `hcr/patchApplying` never appears in the session transcript and
## that no patch request was ever sent — which is the difference between this
## and the pre-existing behaviour, where the refusal arrived after a patch had
## been built and delivered.
##
## THE DIAGNOSTIC NAMES THE POLICY. The refusal message must contain
## `host-text-protection-roundtrip-refused`, the two measured `mprotect`
## results, AND `PR_MDWE_REFUSE_EXEC_GAIN` — the last is what distinguishes
## "MDWE is set and that is why" from "MDWE is not set and something else is",
## which the provider establishes with `PR_GET_MDWE` rather than by guessing.
## A gate asserting only that *a* message was produced would pass against the
## generic `unsupported-host` string this deliverable exists to replace.
##
## TWO PRODUCERS. `patchingSupported` is read off the socket by the coordinator
## AND the same underlying answer is read inside the target process through
## `repro_hcr_agent_host_supports_direct_patch()`, which never touches the
## socket. A transport that rewrote the frame, or a decoder that defaulted the
## field, could not satisfy both.
##
## THE HARDENED TARGET IS ASSERTED STILL EXECUTABLE. It calls the victim again
## after the session and exits 0. That is §14's own acceptance criterion: had
## the refusal come after the RW step, the call would fault.
##
## WHAT WORLD THIS FAILS IN. Delete the `patchingSupportedReported` branch in
## `observeHello` and the hardened arm negotiates and then fails later, so the
## early-refusal assertions go red. Make `repro_hcr_agent_patching_supported`
## return 1 unconditionally and every hardened-arm assertion goes red while the
## healthy arm stays green. Replace the named diagnostic with the old generic
## sentence and only the policy-naming assertions go red.

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl
  import "../hcr-linux-direct/elf_rel_reader"
  import "../hcr-linux-prepare/prepare_fixture"

  const Gate = "integration_hcr_linux_hardened_host_refuses_at_negotiation"

  type Arm = object
    node: JsonNode
    negotiationError: string
    transcriptEvents: seq[string]
    patchSent: bool

  proc runArm(repoRoot, targetBin, socketPath: string; mdwe: bool;
              patchBytes: seq[byte]): Arm =
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()
    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env[ReproHcrAgentSocketEnv] = socketPath
    var args: seq[string] = @[]
    if mdwe: args.add "--mdwe"
    let process = startProcess(targetBin, workingDir = repoRoot, args = args,
      env = env, options = {poStdErrToStdOut})
    var connection = acceptHcrAgentConnection(listener)
    var client = initHcrCoordinatorClient(HcrLinuxX86_64DirectSupportProfile)
    let request = directPatchRequest(
      patchId = "hlx-m9-mdwe-" & $getCurrentProcessId(),
      supportProfile = HcrLinuxX86_64DirectSupportProfile,
      changedFunctions = [VictimSymbol],
      targetSymbols = [VictimSymbol],
      directPatchBytes = patchBytes,
      debugObjectBytes = [],
      unwindMetadataBytes = [],
      sourceGenerationMap = [],
      changedFiles = ["src/patchable.c"],
      changedTypes = [])
    result.patchSent = false
    try:
      let delivery = client.deliverPatchRequest(connection, request)
      result.patchSent = true
      for entry in delivery.transcript:
        result.transcriptEvents.add kindName(entry.message.kind)
    except CatchableError as err:
      result.negotiationError = err.msg
      for entry in client.transcript:
        result.transcriptEvents.add kindName(entry.message.kind)
    connection.close()
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    process.close()
    if code != 0:
      raise newException(IOError,
        "target exited " & $code & " (mdwe=" & $mdwe & "):\n" & output)
    result.node = targetJson(output)

  suite Gate:
    test "a host that cannot regain PROT_EXEC is refused during negotiation":
      let repoRoot = getCurrentDir()
      let workDir = repoRoot / "build" / "hcr-linux-mdwe"
      createDir(workDir)
      let repro = repoRoot / "build" / "bin" / "repro".addFileExt(ExeExt)
      if not fileExists(repro):
        raise newException(IOError,
          Gate & " requires the built `repro` binary at " & repro &
          ". Remedy: run `just build` in this checkout.")

      let oldPath = workDir / "patchable_old.c"
      let newPath = workDir / "patchable_new.c"
      writeFile(oldPath, OldSource)
      writeFile(newPath, NewSource)

      # ONE binary. The two arms differ by one argv flag and nothing else.
      let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-hardening"
      let compileFlags = patchableCompileFlags(ReproHcr())
      let linkFlags = patchableLinkFlags(ReproHcr())
      doAssert "-fpatchable-function-entry=16,0" in compileFlags
      doAssert "-Wl,--build-id=sha1" in linkFlags
      let target = workDir / "hcr_lx_m9_mdwe_target"
      discard runOrFail(shellCommand(
        @["gcc", "-O2", "-g"] & @compileFlags &
        @["-fcf-protection=full",
          "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
          "-o", target,
          caseDir / "hcr_lx_m9_mdwe_target.c",
          oldPath,
          repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"] &
        @linkFlags & @["-lpthread"]), repoRoot)

      let raw = compilePatchObject(workDir, newPath, "patchable.raw.o")
      let prepared = workDir / "patchable.prepared.o"
      removeFile(prepared)
      discard runOrFail(shellCommand([
        repro, "hcr", "prepare-object",
        "--input", raw, "--output", prepared,
        "--function", VictimSymbol, "--segment", "__HCR"]), repoRoot)
      let patchBytes = parseElfRelObject(prepared).functionBytes(VictimSymbol)
      check patchBytes.len > 0

      # ==================================================================
      # THE CONTROL. Without the kernel policy this host patches normally, so
      # the refusal below is attributable to the policy and not to the fixture.
      # ==================================================================
      let healthy = runArm(repoRoot, target, workDir / "healthy.sock",
        mdwe = false, patchBytes = patchBytes)
      check healthy.negotiationError.len == 0
      check healthy.patchSent
      check healthy.node["mdwe"].getBool() == false
      check healthy.node["before"].getInt() == OriginalValue
      check healthy.node["after"].getInt() == PatchedValue
      check healthy.node["codeSwapped"].getBool()
      check healthy.node["hostSupportsDirectPatch"].getBool()

      # ==================================================================
      # THE HARDENED ARM. Same binary, `--mdwe`.
      # ==================================================================
      let hardened = runArm(repoRoot, target, workDir / "hardened.sock",
        mdwe = true, patchBytes = patchBytes)
      check hardened.node["mdwe"].getBool()

      # ---- REFUSED, and refused AT NEGOTIATION.
      check hardened.negotiationError.len > 0
      check not hardened.patchSent
      check hardened.negotiationError.contains(
        "agent reports this host cannot be patched")
      # Nothing was offered. This is the assertion that separates the new
      # behaviour from the old one, where a patch was built, sent, and refused.
      check "patchRequest" notin hardened.transcriptEvents
      check "patchApplied" notin hardened.transcriptEvents
      check "patchFailed" notin hardened.transcriptEvents
      check hardened.node["codeSwapped"].getBool() == false
      check hardened.node["dispatchAddress"].getStr() == "0x0"

      # ---- THE DIAGNOSTIC NAMES THE POLICY, not the symptom.
      check hardened.negotiationError.contains(
        "host-text-protection-roundtrip-refused")
      check hardened.negotiationError.contains("PR_MDWE_REFUSE_EXEC_GAIN")
      # The measurement that established it: the RW step SUCCEEDED and only the
      # PROT_EXEC restore failed, which is this policy class's signature.
      check hardened.negotiationError.contains(
        "mprotect(PROT_READ|PROT_WRITE) answered 0")
      check hardened.negotiationError.contains(
        "mprotect(PROT_READ|PROT_EXEC) answered -13")

      # ---- SECOND PRODUCER: the provider's own capability answer, reached
      # inside the target process without going near the socket.
      check hardened.node["hostSupportsDirectPatch"].getBool() == false

      # ---- §14's ACCEPTANCE CRITERION: the target's text is still
      # executable. It called the victim again after the session and returned.
      check hardened.node["before"].getInt() == OriginalValue
      check hardened.node["after"].getInt() == OriginalValue
      check hardened.node["textStillExecutable"].getBool()

      # ---- the two arms are asserted to DIFFER directly.
      check healthy.node["hostSupportsDirectPatch"].getBool() !=
        hardened.node["hostSupportsDirectPatch"].getBool()
      check healthy.node["after"].getInt() != hardened.node["after"].getInt()

      writeEvidence(repoRoot, Gate, %*{
        "schemaId": "reprobuild.hcr.hlx-m9.hardened-negotiation.v1",
        "healthyArm": healthy.node,
        "hardenedArm": hardened.node,
        "hardenedNegotiationError": hardened.negotiationError,
        "hardenedTranscript": hardened.transcriptEvents})

else:
  suite "integration_hcr_linux_hardened_host_refuses_at_negotiation":
    test "the hardened-host negotiation gate is linux-x86_64-only":
      skip()
