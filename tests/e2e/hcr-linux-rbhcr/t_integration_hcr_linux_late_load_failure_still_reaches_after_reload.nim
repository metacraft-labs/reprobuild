## HLX-M8 verification gate
## `integration_hcr_linux_late_load_failure_still_reaches_after_reload`.
##
## Design: `reprobuild-specs/HCR/Patch-Loading-Lifecycle.md` §3.1, §3.2,
## §3.3 **step 38**.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8.
## Cross-repo twin: IsoNim's
## `test_late_load_failure_still_reaches_after_reload_and_changes_nothing`,
## which asserts the same obligation against the stub agent.
##
## Step 38, quoted: "If `dlopen` / `LoadLibrary` fails (Phase F step 16), the
## agent reports the error. Before-reload callbacks have already fired — the
## agent **must** still invoke after-reload callbacks so the application can
## restore its state (the callbacks receive an `RbHcrReloadInfo` with zero
## `changed_types`, indicating the patch failed and no migration occurred)."
##
## In Direct Patch Injection mode §3.2 replaces Phase F's library load with the
## in-memory link. So the failure this gate provokes is a REAL in-memory link
## refusal: a patch body larger than one page, which
## `repro_hcr_lx_txn_prepare_site` refuses before writing anything to target
## text. The body is real compiler output from a real oversized function — not
## a lever, not a forced return code. Its size is measured in the fixture.
##
## `allowed_mocks: none`.
##
## WHAT MAKES THIS GATE DISCRIMINATE.
##
## 1. A CONTROL ARM with the small body runs the same binary through the same
##    request shape and reaches Phase G. So "after-reload fired" is not a thing
##    this instrument says about every run, and "zero changed_types" is
##    contrasted with a run that carries one.
##
## 2. The failing arm asserts on FOUR independent observables, not one: the
##    callback counts, the `changed_types` count the application actually
##    received, the victim's return value, and the victim's entry bytes.
##
## 3. A FALSIFIER BUILD with `REPRO_HCR_FALSIFY_SKIP_STEP38` removes exactly
##    the obligation under test — the Phase F failure path no longer reaches
##    the after-reload callbacks — and the failing arm is measured to report
##    zero after-callbacks. The healthy assertion, shown going red.
##
## Recorded here because it constrains what an application may conclude:
## `OPEN-5`. Zero `changed_types` is ALSO what the control arm's ordinary
## no-layout-change patch carries, `RbHcrReloadInfo` has no status field, and
## `rb_hcr_file_changed` answers false in both cases. Step 38 gives the AGENT
## an obligation; it does not give the application a discriminator. This gate
## asserts the obligation and asserts the indistinguishability rather than
## papering over it.

import std/[json, options, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import m8_fixture

  suite "integration_hcr_linux_late_load_failure_still_reaches_after_reload":
    test "a Phase F failure after before-reload still reaches after-reload":
      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let target = buildTarget(repoRoot, "hcr_lx_m8_target")

      # ---------------------------------------------------------------------
      # CONTROL — the same request shape with a body that DOES link.
      # ---------------------------------------------------------------------
      let control = runReload(repoRoot, target, "m8-step38-control.sock",
        m8PatchRequest("hlx-m8-step38-control", bodies.normal,
                       changedTypes = [managedTypeChange()]),
        managedTypes = [ProbeManagedType])
      require control.delivery.patchApplied.isSome
      let c = control.targetJson
      check c["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,trampolines,after"
      check c["codeSwapped"].getBool()
      check c["after"].getInt() == PatchedValue
      check observation(control, "observedInAfter")["changedTypesCount"].getInt() == 1
      check c["fileChangedProbeAtEnd"].getBool()

      # ---------------------------------------------------------------------
      # STEP 38 — the same everything, with a body the in-memory link refuses.
      # ---------------------------------------------------------------------
      let late = runReload(repoRoot, target, "m8-step38-fail.sock",
        m8PatchRequest("hlx-m8-step38-fail", bodies.oversize,
                       changedTypes = [managedTypeChange()]),
        managedTypes = [ProbeManagedType])
      require late.delivery.patchFailed.isSome
      check late.delivery.patchFailed.get().message.contains("direct patch")
      # The failure came AFTER the agent committed to applying: `patchApplying`
      # went out, which is what distinguishes a Phase F failure from a prepare
      # refusal on the wire.
      check late.delivery.session.lifecycleEvents ==
        @["hcr/patchApplying", "hcr/patchFailed"]

      let s = late.targetJson
      # The phase order, and the point at which it stopped.
      check s["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,load-failed,after"
      # Before-reload HAD already fired …
      check s["agentBeforeFired"].getInt() == 1
      check observation(late, "observedInBefore")["fired"].getInt() == 1
      # … so after-reload MUST still fire. This is the obligation.
      check s["agentAfterFired"].getInt() == 1
      check observation(late, "observedInAfter")["fired"].getInt() == 1
      # With ZERO changed_types, per step 38's parenthesis.
      check observation(late, "observedInAfter")["changedTypesCount"].getInt() == 0
      # The before-callback, which ran before the failure, DID see the layout
      # delta — the zero is specific to the after-callback on this path.
      check observation(late, "observedInBefore")["changedTypesCount"].getInt() == 1

      # No code was swapped and nothing is marked applied.
      check not s["codeSwapped"].getBool()
      check s["before"].getInt() == OriginalValue
      check s["after"].getInt() == OriginalValue
      check observation(late, "observedInAfter")["victim"].getInt() ==
        OriginalValue
      check s["entryBytesAfterHex"].getStr() == s["entryBytesBeforeHex"].getStr()

      # "any introspection window latched before Phase E has to be rolled
      # back": the window was latched at prepare-success and un-latched when
      # the load failed, so `rb_hcr_file_changed` must not answer true for a
      # reload that never happened.
      check not s["fileChangedProbeAtEnd"].getBool()
      check not s["typeChangedProbeAtEnd"].getBool()
      # And it was open DURING the before-callback, which is the only reason
      # un-latching is necessary at all.
      check observation(late, "observedInBefore")["fileChangedProbe"].getBool()
      check not observation(late, "observedInAfter")["fileChangedProbe"].getBool()

      # OPEN-5, asserted rather than described: what the after-callback
      # received on the FAILING path is indistinguishable from what an ordinary
      # no-layout-change patch delivers. The control above carried one changed
      # type; a plain patch carries none, exactly like this failure.
      #
      # SCOPE OF THIS ASSERTION, stated exactly, because "byte-identical
      # payloads" would be a stronger claim than the two `check`s below make.
      # `RbHcrReloadInfo` has four members; the two pointer members cannot be
      # compared at all (`rb_hcr_fire` points them at stack-local arrays, so
      # their addresses differ per invocation by construction). What is
      # compared is the two COUNTS the application reads — which is the whole
      # of what step 38's parenthesis talks about — and the `changed_files`
      # list is equal by construction rather than by measurement, since both
      # arms send the same `changedFiles`.
      let plain = runReload(repoRoot, target, "m8-step38-plain.sock",
        m8PatchRequest("hlx-m8-step38-plain", bodies.normal))
      require plain.delivery.patchApplied.isSome
      check observation(plain, "observedInAfter")["changedTypesCount"].getInt() ==
        observation(late, "observedInAfter")["changedTypesCount"].getInt()
      check observation(plain, "observedInAfter")["changedFilesCount"].getInt() ==
        observation(late, "observedInAfter")["changedFilesCount"].getInt()
      # A PORTABLE application cannot tell them apart from the callback
      # payload; the only thing that differs is whether the code actually
      # changed, which the `rb_hcr_*` ABI does not report. (This provider's own
      # header additionally exports `repro_hcr_rb_last_code_swapped` and
      # `repro_hcr_rb_lifecycle_trace`, which DO distinguish the two — but they
      # are Linux-provider-specific evidence, not part of the ten portable
      # functions IsoNim binds, so they do not close OPEN-5.) That is the open
      # question, measured.
      check plain.targetJson["after"].getInt() == PatchedValue
      check s["after"].getInt() == OriginalValue

      # ---------------------------------------------------------------------
      # FALSIFIER — remove step 38 and watch the arm go red.
      # ---------------------------------------------------------------------
      let skipTarget = buildTarget(repoRoot, "hcr_lx_m8_target_skip_step38",
        defines = ["-DREPRO_HCR_FALSIFY_SKIP_STEP38"])
      let skipped = runReload(repoRoot, skipTarget, "m8-falsify-step38.sock",
        m8PatchRequest("hlx-m8-falsify-step38", bodies.oversize,
                       changedTypes = [managedTypeChange()]),
        managedTypes = [ProbeManagedType])
      require skipped.delivery.patchFailed.isSome
      let k = skipped.targetJson
      check k["agentBeforeFired"].getInt() == 1
      check k["agentAfterFired"].getInt() == 0
      check observation(skipped, "observedInAfter")["fired"].getInt() == 0
      check k["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,load-failed"

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m8.step38-late-load-failure.v1")
      inspection["oversizeBodyBytes"] = %bodies.oversize.len
      inspection["control"] = c
      inspection["lateLoadFailure"] = s
      inspection["plainNoLayoutChange"] = plain.targetJson
      inspection["falsifiedSkipStep38"] = k
      writeInspection(repoRoot,
        "integration_hcr_linux_late_load_failure_still_reaches_after_reload",
        inspection)

else:
  suite "integration_hcr_linux_late_load_failure_still_reaches_after_reload":
    test "HLX-M8 step-38 gate is linux-x86_64-only":
      skip()
