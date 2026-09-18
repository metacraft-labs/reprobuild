## HLX-M8 verification gate
## `integration_hcr_linux_rejected_patch_never_fires_before_reload`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md`;
## `reprobuild-specs/HCR/Patch-Loading-Lifecycle.md` §3.1.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8.
##
## The falsifier, stated as the milestone states it: a patch rejected during
## prepare fires NEITHER callback and leaves the process byte-identical,
## satisfying the IsoNim contract that a failed patch never blanks the surface.
##
## `allowed_mocks: none`.
##
## WHAT MAKES THIS GATE DISCRIMINATE.
##
## 1. A POSITIVE CONTROL runs first, on the same binary: an ordinary accepted
##    patch, whose callbacks DO fire. Without it "zero callbacks fired" is a
##    statement a broken instrument makes about every run — the classic shape
##    where a scan that matches nothing satisfies every "must not contain"
##    check written against it.
##
## 2. TWO INDEPENDENT prepare refusals are exercised, not one: an unmanaged
##    layout-changed type (HCR-Overview §7.4) and a symbol the target does not
##    export (design §7.2). They fail in different places for different
##    reasons and must produce the same observable — nothing fired, nothing
##    moved.
##
## 3. A FALSIFIER BUILD measures the `rb_hcr_file_changed` half. The claim is
##    that the introspection window opens only once prepare has SUCCEEDED, so a
##    refused patch must not make `rb_hcr_file_changed` answer true. The same
##    target rebuilt with `REPRO_HCR_FALSIFY_LATCH_ON_REQUEST` latches on the
##    requested patch instead, and the refused arm is measured to answer true —
##    the healthy assertion shown going red.
##
## No silent skips on Linux x86_64. The `skip()` arm exists only for platforms
## that are not Linux x86_64.

import std/[json, options, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import m8_fixture

  const AbsentSymbol = "hcr_lx_m8_symbol_that_does_not_exist"

  proc absentSymbolRequest(patchId: string;
                           body: openArray[byte]): HcrPatchRequest =
    directPatchRequest(
      patchId = patchId,
      supportProfile = SupportProfile,
      changedFunctions = [AbsentSymbol],
      targetSymbols = [AbsentSymbol],
      directPatchBytes = body,
      debugObjectBytes = [],
      unwindMetadataBytes = [],
      sourceGenerationMap = [],
      changedFiles = [ProbeChangedFile],
      changedTypes = [])

  suite "integration_hcr_linux_rejected_patch_never_fires_before_reload":
    test "a patch refused in prepare fires no callback and moves no byte":
      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let target = buildTarget(repoRoot, "hcr_lx_m8_target")

      # ---------------------------------------------------------------------
      # POSITIVE CONTROL — the instrument can say something other than zero.
      # ---------------------------------------------------------------------
      let control = runReload(repoRoot, target, "m8-reject-control.sock",
        m8PatchRequest("hlx-m8-reject-control", bodies.normal))
      require control.delivery.patchApplied.isSome
      let c = control.targetJson
      check c["agentBeforeFired"].getInt() == 1
      check c["agentAfterFired"].getInt() == 1
      check c["before"].getInt() == OriginalValue
      check c["after"].getInt() == PatchedValue
      check c["entryBytesAfterHex"].getStr() != c["entryBytesBeforeHex"].getStr()
      check c["fileChangedProbeAtEnd"].getBool()
      # A patch with no layout change carries no `changedTypes`, and the
      # callbacks see that. Worth asserting because it is the case OPEN-5 says
      # an application cannot tell apart from a step-38 failure.
      check observation(control, "observedInAfter")["changedTypesCount"].getInt() == 0
      check observation(control, "observedInBefore")["victim"].getInt() ==
        OriginalValue
      check observation(control, "observedInAfter")["victim"].getInt() ==
        PatchedValue

      # ---------------------------------------------------------------------
      # REFUSAL 1 — HCR-Overview §7.4, an unmanaged layout-changed type.
      # ---------------------------------------------------------------------
      let unmanaged = runReload(repoRoot, target, "m8-reject-unmanaged.sock",
        m8PatchRequest("hlx-m8-reject-unmanaged", bodies.normal,
                       changedTypes = [managedTypeChange()]))
      require unmanaged.delivery.patchFailed.isSome
      check unmanaged.delivery.patchFailed.get().message.contains(
        "IncompatibleChange")

      # ---------------------------------------------------------------------
      # REFUSAL 2 — design §7.2, a symbol this process does not export.
      # ---------------------------------------------------------------------
      let unresolved = runReload(repoRoot, target, "m8-reject-symbol.sock",
        absentSymbolRequest("hlx-m8-reject-symbol", bodies.normal))
      require unresolved.delivery.patchFailed.isSome
      check unresolved.delivery.patchFailed.get().message.contains("symbol")

      for refused in [unmanaged, unresolved]:
        let r = refused.targetJson
        # Nothing fired. Both the agent's count and the application's own
        # observation say so — two witnesses, because the agent's counter could
        # be wrong in exactly the way the callback would reveal.
        check r["agentBeforeFired"].getInt() == 0
        check r["agentAfterFired"].getInt() == 0
        check observation(refused, "observedInBefore")["fired"].getInt() == 0
        check observation(refused, "observedInAfter")["fired"].getInt() == 0
        # Nothing moved.
        check r["before"].getInt() == OriginalValue
        check r["after"].getInt() == OriginalValue
        check not r["codeSwapped"].getBool()
        check r["entryBytesAfterHex"].getStr() ==
          r["entryBytesBeforeHex"].getStr()
        # The refusal happened in prepare: no `hcr/patchApplying` was ever
        # sent, and the lifecycle trace never reached the latch.
        check refused.delivery.session.lifecycleEvents == @["hcr/patchFailed"]
        check r["lifecycleTrace"].getStr() == "prepare,reject"
        check r["rejection"].getStr().len > 0
        # Requested is not applied.
        check not r["fileChangedProbeAtEnd"].getBool()
        check not r["typeChangedProbeAtEnd"].getBool()

      # ---------------------------------------------------------------------
      # FALSIFIER — the "applied, not requested" latch, measured.
      # ---------------------------------------------------------------------
      let latchTarget = buildTarget(repoRoot,
        "hcr_lx_m8_target_latch_on_request",
        defines = ["-DREPRO_HCR_FALSIFY_LATCH_ON_REQUEST"])
      let latched = runReload(repoRoot, latchTarget, "m8-falsify-latch.sock",
        m8PatchRequest("hlx-m8-falsify-latch", bodies.normal,
                       changedTypes = [managedTypeChange()]))
      require latched.delivery.patchFailed.isSome
      let l = latched.targetJson
      # Still refused, still nothing fired, still byte-identical …
      check l["agentBeforeFired"].getInt() == 0
      check l["entryBytesAfterHex"].getStr() == l["entryBytesBeforeHex"].getStr()
      # … but the introspection window moved for a reload that never happened,
      # so the healthy assertion two blocks up is red here. An application
      # reading this would migrate state it does not have.
      check l["fileChangedProbeAtEnd"].getBool()
      check l["typeChangedProbeAtEnd"].getBool()

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m8.rejected-patch.v1")
      inspection["control"] = c
      inspection["refusedUnmanagedType"] = unmanaged.targetJson
      inspection["refusedUnresolvedSymbol"] = unresolved.targetJson
      inspection["falsifiedLatchOnRequest"] = l
      inspection["wireMessages"] = %*{
        "unmanaged": unmanaged.delivery.patchFailed.get().message,
        "unresolved": unresolved.delivery.patchFailed.get().message
      }
      writeInspection(repoRoot,
        "integration_hcr_linux_rejected_patch_never_fires_before_reload",
        inspection)

else:
  suite "integration_hcr_linux_rejected_patch_never_fires_before_reload":
    test "HLX-M8 rejected-patch gate is linux-x86_64-only":
      skip()
