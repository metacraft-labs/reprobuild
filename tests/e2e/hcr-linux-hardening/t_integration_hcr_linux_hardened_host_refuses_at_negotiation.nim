## HLX-M9 verification gate
## `integration_hcr_linux_hardened_host_refuses_at_negotiation`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §5.1, §5.2, §14.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M9 — the deliverable
## "Capability-time refusal: when the host cannot support patching, say so
## during negotiation with a diagnostic naming the blocking policy."
##
## ---------------------------------------------------------------------------
## WHAT WAS WRONG
##
## Twice. First (HLX-M9, 2026-09-20), the probe ran at agent start but the
## refusal came at the FIRST RELOAD; this gate moved it to negotiation. Second
## (reprobuild-pm issue
## `2026-11-16-linux-hcr-capability-probe-tests-the-retired-mprotect-round-trip.md`),
## the probe and this gate kept testing the `mprotect` RW->RX round trip on a
## scratch page after design §5.1 (2026-10-05) stopped publishing that way:
## target text is now REPLACED by a `memfd` (or anonymous) copy moved over it
## with `mremap(MREMAP_FIXED)`, and is never made writable. Under
## `PR_SET_MDWE` the round trip fails while the `memfd` replacement works, so
## the agent refused hosts it could patch.
##
## ---------------------------------------------------------------------------
## WHAT MAKES THIS GATE DISCRIMINATE
##
## THE HARDENING IS A REAL KERNEL POLICY. The MDWE arms call
## `prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN)` on themselves before the
## agent starts. Nothing is stubbed and no failure is injected.
##
## FOUR ARMS, ONE BINARY: {no MDWE, MDWE} x {memfd backing, memfd disabled by
## the agent's own `REPRO_HCR_TEST_FORCE_ANONYMOUS_CODE_PAGES` lever}.
##
##   - no MDWE, memfd       -> patched 11 -> 77 through the memfd backing.
##   - no MDWE, anonymous   -> patched 11 -> 77 through the anonymous fallback.
##                             The control that makes the last arm's refusal
##                             attributable to MDWE and not to the lever.
##   - MDWE, memfd          -> PATCHED 11 -> 77 through the memfd backing. This
##                             is the arm the round-trip probe got wrong: it
##                             refused this host at negotiation.
##   - MDWE, anonymous      -> REFUSED AT NEGOTIATION, no patch offered, with
##                             a diagnostic naming the replacement, both
##                             backings' answers and `PR_MDWE_REFUSE_EXEC_GAIN`.
##
## THE REFUSAL IS ASSERTED TO BE EARLY: no patch request was sent and no patch
## lifecycle event appears in the transcript.
##
## TWO PRODUCERS. `patchingSupported` is read off the socket by the coordinator
## AND the same answer is read inside the target through
## `repro_hcr_agent_host_supports_direct_patch()`, with the backing that
## completed the probe beside it.
##
## WHAT THE PROVIDER DID TO TEXT. In every arm the target calls the victim
## again after the session (it would fault on a non-executable page), and
## reports how many of the provider's `mprotect`s overlapped its own text
## range (`__executable_start` .. `etext`, from the linker, not the provider)
## and how many `PROT_WRITE|PROT_EXEC` requests the provider refused to issue.
## Both must be 0 (design §14).
##
## WHAT WORLD THIS FAILS IN. Restore the round-trip probe and the MDWE+memfd
## arm is refused at negotiation, so its patch assertions go red (this is the
## reproduction of the issue). Make the probe report success without
## replacing anything and the MDWE+anonymous arm negotiates, so its refusal
## assertions go red. Make `repro_hcr_agent_patching_supported` return 1
## unconditionally and the MDWE+anonymous arm goes red while the others stay
## green.

import std/[json, os, osproc, streams, strtabs, strutils, unittest]
# Agent sockets go in a short directory under /tmp, not under the scratch
# tree: on a runner whose work directory is long (the persistent benchmark
# runner's `/var/lib/github-runner-work/mcl-bench-001/...`) a socket under
# `build/` exceeds the 107-byte sun_path limit and the gate fails before it
# asserts anything (process_fixtures.shortSocketDirAtProcessExit says why).
when defined(posix):
  from repro_test_support/process_fixtures import shortSocketDirAtProcessExit

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
              forceAnonymous: bool; patchBytes: seq[byte]): Arm =
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()
    var env = newStringTable()
    for key, value in envPairs():
      if key != "REPRO_HCR_TEST_FORCE_ANONYMOUS_CODE_PAGES":
        env[key] = value
    env[ReproHcrAgentSocketEnv] = socketPath
    if forceAnonymous:
      env["REPRO_HCR_TEST_FORCE_ANONYMOUS_CODE_PAGES"] = "1"
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
        "target exited " & $code & " (mdwe=" & $mdwe & ", forceAnonymous=" &
        $forceAnonymous & "):\n" & output)
    result.node = targetJson(output)

  const
    BackingNone = 0
    BackingMemfd = 1
    BackingAnonymous = 2

  ## Every arm, whatever it decided: the victim still runs, and the provider
  ## neither re-protected target text nor asked for a writable-and-executable
  ## mapping (design §14).
  proc checkTextUntouched(arm: Arm) =
    check arm.node["textStillExecutable"].getBool()
    check arm.node["mprotectsOnText"].getInt() == 0
    check arm.node["wxRequestsRefused"].getInt() == 0

  proc checkPatched(arm: Arm; backing: int) =
    check arm.negotiationError.len == 0
    check arm.patchSent
    check "patchApplied" in arm.transcriptEvents
    check arm.node["before"].getInt() == OriginalValue
    check arm.node["after"].getInt() == PatchedValue
    check arm.node["codeSwapped"].getBool()
    check arm.node["hostSupportsDirectPatch"].getBool()
    check arm.node["textReplacementBacking"].getInt() == backing
    checkTextUntouched(arm)

  suite Gate:
    test "a host is refused at negotiation only when neither text-replacement backing completes":
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

      # ONE binary. The arms differ by one argv flag and one environment
      # variable and nothing else.
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

      let sockets = shortSocketDirAtProcessExit("hcr-")

      # ==================================================================
      # THE CONTROLS. Without the kernel policy this host patches through
      # either backing, so what the MDWE arms decide is attributable to the
      # policy and not to the fixture or the lever.
      # ==================================================================
      let healthy = runArm(repoRoot, target, sockets / "healthy.sock",
        mdwe = false, forceAnonymous = false, patchBytes = patchBytes)
      check healthy.node["mdwe"].getBool() == false
      checkPatched(healthy, BackingMemfd)

      let healthyAnonymous = runArm(repoRoot, target,
        sockets / "healthy-anon.sock",
        mdwe = false, forceAnonymous = true, patchBytes = patchBytes)
      check healthyAnonymous.node["mdwe"].getBool() == false
      checkPatched(healthyAnonymous, BackingAnonymous)
      # The anonymous fallback finalizes its copies with `mprotect` — of its
      # own pages. The log is non-empty here and still names no text page,
      # which is what shows the text check above can see an `mprotect` at all.
      check healthyAnonymous.node["mprotectIssued"].getInt() > 0

      # ==================================================================
      # MDWE, memfd backing: PUBLISHED. The round-trip probe refused this
      # host at negotiation (the issue's reproduction).
      # ==================================================================
      let hardenedMemfd = runArm(repoRoot, target,
        sockets / "hardened-memfd.sock",
        mdwe = true, forceAnonymous = false, patchBytes = patchBytes)
      check hardenedMemfd.node["mdwe"].getBool()
      checkPatched(hardenedMemfd, BackingMemfd)
      check not hardenedMemfd.negotiationError.contains(
        "host-text-protection-roundtrip-refused")

      # ==================================================================
      # MDWE, memfd backing disabled: REFUSED AT NEGOTIATION.
      # ==================================================================
      let hardened = runArm(repoRoot, target, sockets / "hardened.sock",
        mdwe = true, forceAnonymous = true, patchBytes = patchBytes)
      check hardened.node["mdwe"].getBool()

      check hardened.negotiationError.len > 0
      check not hardened.patchSent
      check hardened.negotiationError.contains(
        "agent reports this host cannot be patched")
      # Nothing was offered.
      check "patchRequest" notin hardened.transcriptEvents
      check "patchApplied" notin hardened.transcriptEvents
      check "patchFailed" notin hardened.transcriptEvents
      check hardened.node["codeSwapped"].getBool() == false
      check hardened.node["dispatchAddress"].getStr() == "0x0"

      # ---- THE DIAGNOSTIC NAMES THE MECHANISM AND THE POLICY.
      check hardened.negotiationError.contains("host-text-replacement-refused")
      check hardened.negotiationError.contains("PR_MDWE_REFUSE_EXEC_GAIN")
      # What the probe measured: the memfd backing was not tried (the lever),
      # and the anonymous fallback's copy could not become executable — the
      # kernel's `EACCES`, MDWE's signature — at step 4, i.e. BEFORE the move
      # (step 5), which is what design §14 requires. The step is named by the
      # provider; `-13` alone could equally be an `mremap` refusal.
      check hardened.negotiationError.contains(
        "the memfd backing answered: disabled")
      check hardened.negotiationError.contains(
        "the anonymous fallback answered: refused at step 4 " &
        "(finalizing the copy, before the move) with -13")
      check not hardened.negotiationError.contains("mprotect(PROT_READ|PROT_WRITE)")

      # ---- SECOND PRODUCER, inside the target.
      check hardened.node["hostSupportsDirectPatch"].getBool() == false
      check hardened.node["textReplacementBacking"].getInt() == BackingNone

      # ---- §14: text still executable, never re-protected, no W|X request.
      check hardened.node["before"].getInt() == OriginalValue
      check hardened.node["after"].getInt() == OriginalValue
      checkTextUntouched(hardened)

      # ---- the two MDWE arms are asserted to DIFFER directly.
      check hardenedMemfd.node["hostSupportsDirectPatch"].getBool() !=
        hardened.node["hostSupportsDirectPatch"].getBool()
      check hardenedMemfd.node["after"].getInt() != hardened.node["after"].getInt()

      writeEvidence(repoRoot, Gate, %*{
        "schemaId": "reprobuild.hcr.hlx-m9.hardened-negotiation.v2",
        "healthyArm": healthy.node,
        "healthyAnonymousArm": healthyAnonymous.node,
        "hardenedMemfdArm": hardenedMemfd.node,
        "hardenedArm": hardened.node,
        "hardenedNegotiationError": hardened.negotiationError,
        "hardenedTranscript": hardened.transcriptEvents})

else:
  suite "integration_hcr_linux_hardened_host_refuses_at_negotiation":
    test "the hardened-host negotiation gate is linux-x86_64-only":
      skip()
