## HLX-M8 verification gate
## `integration_hcr_linux_managed_type_layout_change_lifecycle`.
##
## Design: `reprobuild-specs/HCR/HCR-Overview.md` §7.4, §13;
## `reprobuild-specs/HCR/Patch-Loading-Lifecycle.md` §3.1, §3.4.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8.
##
## The falsifier, stated as the milestone states it: a layout change to a
## REGISTERED managed type runs the save/patch/restore lifecycle; the SAME
## change to an unregistered type is rejected with `IncompatibleChange` naming
## the unmanaged type and leaves the process untouched.
##
## `allowed_mocks: none`. Real target process compiled by a real GCC with the
## real patchable build profile, linking the production C agent; real agent
## Unix socket and real wire protocol driven by the production
## `HcrCoordinatorClient`; real patch bytes extracted from a real ELF
## relocatable object.
##
## WHAT MAKES THIS GATE DISCRIMINATE, which is the thing worth reading.
##
## 1. The two arms are ONE binary and differ by ONE argv flag
##    (`--managed=HcrM8State`), and they have opposite outcomes. Nothing else
##    about the run changes — same patch bytes, same wire request, same
##    callbacks — so the acceptance rule is the only variable.
##
## 2. The callbacks do not count; they OBSERVE. Each one calls the victim
##    function and dumps its entry bytes. `Patch-Loading-Lifecycle.md` §3.1
##    puts before-reload at Phase E, where nothing is loaded and no prologue is
##    overwritten, and after-reload at Phase H, after Phase G's publishing
##    store. So the before-callback must see 11 and the after-callback must see
##    77, from the SAME process, in the SAME reload. A gate that asserted only
##    "both callbacks fired" would be green under either ordering — which is
##    exactly the defect that made the first version of IsoNim's stub agent
##    wrong, and the reason its four gates proved nothing.
##
## 3. A FALSIFIER BUILD measures point 2 rather than asserting it. The same
##    target is rebuilt against an agent with
##    `REPRO_HCR_FALSIFY_BEFORE_RELOAD_AFTER_SWAP` defined — the ordering
##    IsoNim's design doc asked for and §3.1 forbids — the same accepted arm is
##    run, and the before-callback is measured to see 77 instead of 11. That is
##    the healthy assertion shown going red.
##
## No silent skips on Linux x86_64: a missing compiler is a loud failure. The
## `skip()` arm exists only for platforms that are not Linux x86_64.

import std/[json, options, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import m8_fixture

  proc byteAt(hex: string; index: int): string =
    hex[index * 2 ..< index * 2 + 2]

  suite "integration_hcr_linux_managed_type_layout_change_lifecycle":
    test "a managed layout change runs the lifecycle; an unmanaged one is refused":
      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let target = buildTarget(repoRoot, "hcr_lx_m8_target")

      # ---------------------------------------------------------------------
      # ARM A — the type IS registered as managed. §7.4: "If all layout-changed
      # types in a patch are managed, the patch is accepted."
      # ---------------------------------------------------------------------
      let accepted = runReload(repoRoot, target, "m8-managed.sock",
        m8PatchRequest("hlx-m8-managed-1", bodies.normal,
                       changedTypes = [managedTypeChange()]),
        managedTypes = [ProbeManagedType])

      check accepted.delivery.patchFailed.isNone
      require accepted.delivery.patchApplied.isSome
      check accepted.delivery.session.lifecycleEvents ==
        @["hcr/patchApplying", "hcr/patchApplied"]

      let a = accepted.targetJson
      # Synchronized mode is mandatory for a layout-changing patch (§3.4 step
      # 43) and the target opted in, so `rb_hcr_wants_reload` must have been
      # true before the application drove the reload and false after it.
      check a["synchronizedMode"].getBool()
      check a["wantsReloadBeforeApply"].getBool()
      check not a["wantsReloadAfterApply"].getBool()
      check a["applyReloadCalls"].getInt() == 1

      # The observable the milestone names: the target's own return value.
      check a["before"].getInt() == OriginalValue
      check a["after"].getInt() == PatchedValue
      check a["codeSwapped"].getBool()
      check a["rejection"].getStr() == ""
      check a["unmanagedTypes"].getStr() == ""

      # The NORMATIVE phase order, spelled as the trace §3.1 numbers.
      check a["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,trampolines,after"

      # Registration is idempotent on (callback, user_data): the target
      # registers each callback twice and a third with different user_data
      # which it then removes. Exactly one dispatch each.
      check a["agentBeforeFired"].getInt() == 1
      check a["agentAfterFired"].getInt() == 1
      check a["beforeUserData"].getStr() == "0x8100"
      check a["afterUserData"].getStr() == "0x8200"

      let observedBefore = observation(accepted, "observedInBefore")
      let observedAfter = observation(accepted, "observedInAfter")
      check observedBefore["fired"].getInt() == 1
      check observedAfter["fired"].getInt() == 1

      # ---- the phase-order observation, from inside the process ----------
      # Phase E: OLD code is still the only code. Phase H: NEW code is live.
      check observedBefore["victim"].getInt() == OriginalValue
      check observedAfter["victim"].getInt() == PatchedValue
      # And the second, independent witness: the entry bytes themselves.
      check observedBefore["entryHex"].getStr() ==
        a["entryBytesBeforeHex"].getStr()
      check observedAfter["entryHex"].getStr() ==
        a["entryBytesAfterHex"].getStr()
      check observedBefore["entryHex"].getStr() !=
        observedAfter["entryHex"].getStr()

      # §13.3: both callback sets receive the SAME RbHcrReloadInfo, with the
      # layout delta the coordinator computed in Phase C.
      for observed in [observedBefore, observedAfter]:
        check observed["changedFilesCount"].getInt() == 1
        check observed["firstFile"].getStr() == ProbeChangedFile
        check observed["changedTypesCount"].getInt() == 1
        check observed["firstType"].getStr() == ProbeManagedType
        check observed["firstTypeOldSize"].getInt() == 24
        check observed["firstTypeNewSize"].getInt() == 40
        # §13.6's own usage example calls these inside a before-reload
        # callback, so the introspection window is open by Phase E.
        check observed["fileChangedProbe"].getBool()
        check not observed["fileChangedAbsent"].getBool()
        check observed["typeChangedProbe"].getBool()

      check a["fileChangedProbeAtEnd"].getBool()
      check not a["fileChangedAbsentAtEnd"].getBool()
      check a["typeChangedProbeAtEnd"].getBool()

      # Byte-level: exactly one naturally aligned 8-byte window changed and
      # `endbr64` survived — HLX-M0's invariant, re-asserted here because the
      # lifecycle now runs through a split prepare/commit and must not have
      # widened the store.
      let beforeHex = a["entryBytesBeforeHex"].getStr()
      let afterHex = a["entryBytesAfterHex"].getStr()
      check beforeHex.startsWith(Endbr64Hex)
      check afterHex.startsWith(Endbr64Hex)
      check byteAt(afterHex, 8) == "e9"
      for i in 0 ..< 32:
        if i >= 8 and i < 16:
          continue
        check byteAt(afterHex, i) == byteAt(beforeHex, i)

      # ---------------------------------------------------------------------
      # ARM B — the SAME patch, the SAME binary, the type NOT registered.
      # §7.4: "if any are unmanaged, the patch is rejected with
      # IncompatibleChange listing the unmanaged types."
      # ---------------------------------------------------------------------
      let refused = runReload(repoRoot, target, "m8-unmanaged.sock",
        m8PatchRequest("hlx-m8-unmanaged-1", bodies.normal,
                       changedTypes = [managedTypeChange()]))

      check refused.delivery.patchApplied.isNone
      require refused.delivery.patchFailed.isSome
      let message = refused.delivery.patchFailed.get().message
      check message.contains("IncompatibleChange")
      check message.contains(ProbeManagedType)
      # No `hcr/patchApplying` at all: the refusal happened in prepare, before
      # the agent committed to applying anything.
      check refused.delivery.session.lifecycleEvents == @["hcr/patchFailed"]

      let b = refused.targetJson
      check b["before"].getInt() == OriginalValue
      check b["after"].getInt() == OriginalValue
      check not b["codeSwapped"].getBool()
      check b["lifecycleTrace"].getStr() == "prepare,reject"
      check b["rejection"].getStr().contains("IncompatibleChange")
      check b["unmanagedTypes"].getStr() == ProbeManagedType

      # HLX-M8's never-blank-the-surface deliverable: NEITHER callback fired
      # and the process is byte-identical.
      check b["agentBeforeFired"].getInt() == 0
      check b["agentAfterFired"].getInt() == 0
      check observation(refused, "observedInBefore")["fired"].getInt() == 0
      check observation(refused, "observedInAfter")["fired"].getInt() == 0
      check b["entryBytesAfterHex"].getStr() == b["entryBytesBeforeHex"].getStr()

      # A refused patch was never APPLIED, so the introspection window did not
      # move. This is HLX-M8's `rb_hcr_file_changed` deliverable: conflating
      # requested with applied tells a program to migrate state it does not
      # have.
      check not b["fileChangedProbeAtEnd"].getBool()
      check not b["typeChangedProbeAtEnd"].getBool()

      # ---------------------------------------------------------------------
      # FALSIFIER — the phase order, measured rather than asserted.
      # ---------------------------------------------------------------------
      let falsifiedTarget = buildTarget(repoRoot,
        "hcr_lx_m8_target_before_after_swap",
        defines = ["-DREPRO_HCR_FALSIFY_BEFORE_RELOAD_AFTER_SWAP"])
      let falsified = runReload(repoRoot, falsifiedTarget,
        "m8-falsify-order.sock",
        m8PatchRequest("hlx-m8-falsify-order", bodies.normal,
                       changedTypes = [managedTypeChange()]),
        managedTypes = [ProbeManagedType])
      let f = falsified.targetJson
      # Under the inverted ordering the patch still applies and both callbacks
      # still fire — which is why counting them proves nothing …
      check f["after"].getInt() == PatchedValue
      check f["agentBeforeFired"].getInt() == 1
      check f["agentAfterFired"].getInt() == 1
      # … and the before-callback now observes the NEW body, so the healthy
      # arm's assertion above is red here. That is the discrimination.
      check observation(falsified, "observedInBefore")["victim"].getInt() ==
        PatchedValue
      check falsified.targetJson["lifecycleTrace"].getStr() ==
        "prepare,latch,load,trampolines,before,after"

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m8.managed-type-lifecycle.v1")
      inspection["accepted"] = a
      inspection["refused"] = b
      inspection["falsifiedOrdering"] = f
      inspection["patchBodyBytes"] = %bodies.normal.len
      writeInspection(repoRoot,
        "integration_hcr_linux_managed_type_layout_change_lifecycle",
        inspection)

else:
  suite "integration_hcr_linux_managed_type_layout_change_lifecycle":
    test "HLX-M8 managed-type lifecycle gate is linux-x86_64-only":
      skip()
