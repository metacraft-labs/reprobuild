## HLX-M8 verification gate
## `integration_hcr_linux_phase_i_refusal_reports_an_applied_patch`.
##
## Design: `reprobuild-specs/HCR/HCR-Overview.md` §13.7 (the event table),
## `HCR/Patch-Loading-Lifecycle.md` §3.1 Phase I step 31.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8 — the residue
## item "a Phase I registration failure is reported as `patchFailed` for a
## patch that IS LIVE".
##
## ---------------------------------------------------------------------------
## THE DECISION THIS GATE HOLDS IN PLACE
##
## Phase I is debugger and unwinder registration, and it runs AFTER the commit.
## `rb_hcr_run_lifecycle`'s own comment said so: "a failure here is reported on
## the wire, but the code IS live and the layouts DID change". What it was
## reported AS was `hcr/patchFailed` — so `repro watch` printed "hcr patch
## failed … falling back to rebuilds" and set `fallbackOnly` for a target whose
## behaviour had already changed, and the coordinator recorded a failure for a
## process running the new code.
##
## Neither "applied" nor "failed" was the whole truth and the protocol had no
## third frame. It is now `hcr/patchApplied` carrying `registrationDegraded`
## and a diagnostic naming the refusal — the same decision, for the same
## reason, as HLX-M9's `textLeftWritable`: a publication that succeeded AND
## degraded the process is reported as both, in the frame whose arrival tells
## the coordinator the code is live. `HCR-Overview.md` §13.7's event table
## gains the rows that were missing.
##
## ---------------------------------------------------------------------------
## WHAT MAKES THIS GATE DISCRIMINATE
##
## THE FAILURE IS REAL, NOT A LEVER. The Phase I refusal is produced by handing
## the agent a `debugObjectPayload` whose `.debug_*` sections are
## `SHF_COMPRESSED` — the compiler's own default output — which
## `repro_hcr_lxu_rebase_elf_debug_object` refuses by name in production code.
## No environment variable, no falsifier define, no injected error.
##
## THE ARMS ARE ONE VARIABLE. The SAME target binary, the SAME patch bytes, the
## SAME `.eh_frame`, the SAME socket transport, differing ONLY in whether the
## debug payload is compressed. One degrades, one does not.
##
## THE DEGRADED ARM ASSERTS THE PATCH WORKED. 11 -> 77 read out of the running
## process, `codeSwapped` true, and `patchFailed` absent from the delivery —
## because the entire decision is that a Phase I refusal is a successful
## publication plus a degradation. An arm in which the patch was refused would
## say nothing about the field's severity.
##
## TWO PRODUCERS, REQUIRED TO AGREE. The agent's `registrationDegraded` field
## on the wire, and the target's own `repro_hcr_rb_last_jit_refused()` read
## in-process from a different code path. A gate reading only the wire could
## not tell a real refusal from an encoder that always sets the flag.
##
## THE PREDICATE IS OBSERVED FLIPPING WITHIN ONE RUN of the same binary. No
## always-true and no always-false implementation can produce that.
##
## WHAT WORLD THIS FAILS IN. Restore the `patchFailed` arm at the end of
## `rb_hcr_run_lifecycle` and the degraded arm goes red on
## `patchApplied.isSome`, on `patchFailed.isNone` and on every
## `registrationDegraded` assertion. Emit `registrationDegraded` as a literal
## `false` and the value assertions go red while `...Reported` stays green,
## which separates presence from value. Drop the named refusal and the
## diagnostic assertion goes red while the boolean stays green.

import std/[json, options, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import "../hcr-linux-direct/elf_rel_reader"
  import "./prepare_fixture"

  const Gate = "integration_hcr_linux_phase_i_refusal_reports_an_applied_patch"

  suite Gate:
    test "a Phase I registration refusal reports an applied patch, not a failed one":
      let repoRoot = getCurrentDir()
      let workDir = repoRoot / "build" / "hcr-linux-phase-i"
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

      let target = buildWireTarget(repoRoot, workDir, oldPath,
        "hcr_lx_phase_i_target")

      # The DEGRADING payload is the compiler's own default output. The
      # HEALTHY one is the same object through the real `prepare-object`.
      let raw = compilePatchObject(workDir, newPath, "patchable.raw.o")
      let prepared = workDir / "patchable.prepared.o"
      removeFile(prepared)
      discard runOrFail(shellCommand([
        repro, "hcr", "prepare-object",
        "--input", raw, "--output", prepared,
        "--function", VictimSymbol, "--segment", "__HCR"]), repoRoot)

      let parsedPrepared = parseElfRelObject(prepared)
      let patchBytes = parsedPrepared.functionBytes(VictimSymbol)
      check patchBytes.len > 0
      let ehFrame = parsedPrepared.sectionBytes(".eh_frame")
      check ehFrame.len > 0

      let degraded = deliverPatch(repoRoot, target, workDir / "degraded.sock",
        patchBytes, fileBytes(raw), ehFrame)
      let healthy = deliverPatch(repoRoot, target, workDir / "healthy.sock",
        patchBytes, fileBytes(prepared), ehFrame)

      # ==================================================================
      # THE DEGRADED ARM. This is the whole decision.
      # ==================================================================
      # The frame is `patchApplied`. Before this change it was `patchFailed`.
      check degraded.delivery.patchApplied.isSome
      check degraded.delivery.patchFailed.isNone

      # …and the code really IS live, which is why `patchFailed` was false.
      check degraded.node["before"].getInt() == OriginalValue
      check degraded.node["after"].getInt() == PatchedValue
      check degraded.node["codeSwapped"].getBool()
      check degraded.node["dispatchAddress"].getStr() != "0x0"

      # …and the degradation is REPORTED rather than swallowed.
      let degradedApplied = degraded.delivery.patchApplied.get()
      check degradedApplied.registrationDegradedReported
      check degradedApplied.registrationDegraded
      # NAMED, not generic. "JIT debug object registration failed" was one
      # sentence for three unrelated causes; the name is what tells a reader
      # what to change (Verification-Harness-Traps §20).
      check degradedApplied.registrationDiagnostic.contains(
        "debug-object-compressed-debug-section")

      # SECOND PRODUCER: the target's own in-process reading, from a code path
      # the wire never touches.
      check degraded.node["jitRefused"].getBool()
      check not degraded.node["jitRegistered"].getBool()

      # The `.eh_frame` half is INDEPENDENT of the JIT half and must still have
      # registered — the old code shared one `ok` flag and skipped it.
      check degraded.node["ehFrameRegistered"].getBool()

      # ==================================================================
      # THE HEALTHY ARM — same binary, one variable.
      # ==================================================================
      check healthy.delivery.patchApplied.isSome
      check healthy.delivery.patchFailed.isNone
      check healthy.node["after"].getInt() == PatchedValue
      let healthyApplied = healthy.delivery.patchApplied.get()
      check healthyApplied.registrationDegradedReported
      check not healthyApplied.registrationDegraded
      check healthyApplied.registrationDiagnostic.len == 0
      check healthy.node["jitRegistered"].getBool()
      check not healthy.node["jitRefused"].getBool()

      # The two arms are asserted to DIFFER directly.
      check degradedApplied.registrationDegraded !=
        healthyApplied.registrationDegraded
      check degraded.node["jitRefused"].getBool() !=
        healthy.node["jitRefused"].getBool()

      # ==================================================================
      # THE FIELD SURVIVES A RE-ENCODE. A coordinator that re-emits the frame
      # must not drop it, which is what an encoder gated on the wrong flag
      # would do.
      # ==================================================================
      let reEmitted = parseAgentMessage(agentMessageJson(
        HcrAgentMessage(kind: hmkPatchApplied, patchApplied: degradedApplied)))
      check reEmitted.patchApplied.registrationDegraded
      check reEmitted.patchApplied.registrationDegradedReported
      check reEmitted.patchApplied.registrationDiagnostic ==
        degradedApplied.registrationDiagnostic

      # An agent PREDATING this change omits the key, and "omitted" must not
      # collapse into "reported false" — for this field the difference is not
      # cosmetic, because such an agent would have sent `patchFailed` instead.
      let legacy = parseAgentMessage(agentMessageJson(
        HcrAgentMessage(kind: hmkPatchApplied,
          patchApplied: HcrPatchApplied(
            patchId: degradedApplied.patchId,
            changedFunctions: degradedApplied.changedFunctions,
            symbolGeneration: degradedApplied.symbolGeneration,
            debugObjectDigest: degradedApplied.debugObjectDigest,
            unwindMetadataDigest: degradedApplied.unwindMetadataDigest,
            sourceGenerationMapDigest:
              degradedApplied.sourceGenerationMapDigest))))
      check not legacy.patchApplied.registrationDegradedReported
      check not legacy.patchApplied.registrationDegraded

      writeEvidence(repoRoot, Gate, %*{
        "schemaId": "reprobuild.hcr.hlx-m8.phase-i-degraded-publication.v1",
        "degradedArm": degraded.node,
        "degradedDiagnostic": degradedApplied.registrationDiagnostic,
        "degradedFrameKind": "patchApplied",
        "healthyArm": healthy.node})

else:
  suite "integration_hcr_linux_phase_i_refusal_reports_an_applied_patch":
    test "the Phase I degraded-publication gate is linux-x86_64-only":
      skip()
