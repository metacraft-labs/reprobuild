## HLX-M8 residue gate `integration_hcr_linux_threaded_synchronized_reload`.
##
## Design: `reprobuild-specs/HCR/Patch-Loading-Lifecycle.md` §3.4 (steps 40-43);
## `reprobuild-specs/HCR/HCR-Overview.md` §5.5, §13.1;
## `reprobuild-specs/HCR/Linux-ELF-Provider.md` §6 (quiescence).
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8 residue —
## "Threaded synchronized mode has no gate."
##
## WHAT WAS UNGATED, stated exactly. Synchronized mode itself is implemented and
## its §3.4 step 43 automatic-mode refusal is gated by
## `hcr_rb_application_abi_contract`. What no gate drove is the THREADED shape:
## every HLX-M8 target starts the agent with
## `repro_hcr_agent_start_polling_from_env` and services it from `main`, so the
## agent and the application are the same thread and "the coordinator waits for
## the application" is not a claim about anything. This gate starts the agent
## with `repro_hcr_agent_start_from_env` — a detached agent thread — with four
## worker threads calling the victim throughout, and the application applying
## the reload from its own loop.
##
## `allowed_mocks: none`. One real target process per arm, the production C
## agent compiled in, the real agent Unix socket, the production
## `HcrCoordinatorClient` as the coordinator.
##
## WHAT MAKES THIS GATE DISCRIMINATE. Three independent axes, each of which has
## a measured world where it comes out the other way:
##
## 1. THE COORDINATOR IS BLOCKED FOR AT LEAST THE PARK. The target waits a
##    declared `--park-ms` after `rb_hcr_wants_reload()` answers true and before
##    it calls `rb_hcr_apply_reload()`. The gate times the coordinator's
##    request -> answer round trip from the OTHER SIDE of the socket and
##    requires it to cover that park. The automatic arm — same binary, one argv
##    flag — is measured to answer in well under it, so the assertion separates
##    two worlds rather than describing one. A gate that only checked "the patch
##    arrived" would pass in both.
##
## 2. THE CALLBACKS RUN ON THE APPLICATION'S THREAD, NOT THE AGENT'S. That is
##    the entire point of §3.4 — HCR-Overview §5.5: "its callbacks destroy and
##    recreate live objects and must not run on the agent's thread mid-frame".
##    The target records `pthread_self()` inside each callback and compares it
##    with `main`'s. Synchronized: both true. Automatic: both FALSE, because the
##    detached agent thread ran them. Neither answer is available to a
##    single-threaded target, which is why no existing gate could assert it.
##
## 3. OTHER THREADS WERE RUNNING ACROSS THE PUBLICATION. Each worker records
##    whether it observed the old body, the new body, or neither. Requiring
##    every worker to have seen BOTH is what distinguishes "patched a live
##    multi-threaded process" from "patched a process whose threads happened to
##    be idle". `saw_other` must be zero on every worker: a torn instruction
##    would show up as a value that is neither 11 nor 77.

import std/[json, options, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import m8_fixture

  const
    ParkMs = 400
      ## Long enough to dwarf process startup jitter, short enough that two
      ## arms cost under a second of waiting between them.
    ThreadedSchemaId =
      "reprobuild.hcr.hlx-m8.linux-threaded-sync-target-result.v1"

  suite "integration_hcr_linux_threaded_synchronized_reload":
    test "a threaded agent parks the patch until the application applies it":
      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let target = buildTarget(repoRoot, "hcr_lx_m8_threaded_target",
        source = "hcr_lx_m8_threaded_target.c")

      # ---------------------------------------------------------------------
      # SYNCHRONIZED ARM — the agent thread parks, the application applies.
      # ---------------------------------------------------------------------
      let sync = runReloadTimed(repoRoot, target, "m8-threaded-sync.sock",
        m8PatchRequest("hlx-m8-threaded-sync", bodies.normal),
        argv = ["--park-ms=" & $ParkMs],
        schemaId = ThreadedSchemaId)
      require sync.run.delivery.patchApplied.isSome
      let s = sync.run.targetJson

      check s["synchronizedMode"].getBool()
      check not s["automatic"].getBool()
      # The patch was PARKED and handed across a thread boundary: the agent
      # thread wrote `rb_hcr_pending`, the application thread read it.
      check s["wantsReloadObserved"].getBool()
      # And consumed: §13.1 says nothing is pending once the reload completes.
      check not s["wantsReloadAfterApply"].getBool()
      check s["applyReloadCalls"].getInt() == 1
      # The full §3.1 lifecycle ran, on the application's thread.
      check s["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,trampolines,after"
      check s["agentBeforeFired"].getInt() == 1
      check s["agentAfterFired"].getInt() == 1
      check s["codeSwapped"].getBool()
      check s["victimAtEnd"].getInt() == PatchedValue
      check s["fileChangedAtEnd"].getBool()
      # Phase E saw the old body, Phase H the new one — the §3.1 phase order,
      # re-asserted here because this is the first time it is measured with the
      # callbacks running on a thread the agent does not own.
      check s["beforeVictim"].getInt() == OriginalValue
      check s["afterVictim"].getInt() == PatchedValue

      # AXIS 2 — the callbacks ran on the application's thread.
      check s["beforeRanOnMainThread"].getBool()
      check s["afterRanOnMainThread"].getBool()

      # AXIS 3 — the other threads were running across the publication.
      check s["workerCount"].getInt() == 4
      check s["workerCalls"].getInt() > 100
      check s["workersThatSawOld"].getInt() == 4
      check s["workersThatSawNew"].getInt() == 4
      check s["workersThatSawOther"].getInt() == 0

      # AXIS 1 — the coordinator was blocked for at least the park. Measured on
      # the coordinator's clock, not reported by the target.
      check sync.coordinatorWaitMs >= ParkMs

      # ---------------------------------------------------------------------
      # AUTOMATIC ARM — the SAME binary, one argv flag apart. §3.4's other
      # mode: the agent thread runs the whole lifecycle itself.
      # ---------------------------------------------------------------------
      let auto = runReloadTimed(repoRoot, target, "m8-threaded-auto.sock",
        m8PatchRequest("hlx-m8-threaded-auto", bodies.normal),
        argv = ["--automatic", "--park-ms=" & $ParkMs],
        schemaId = ThreadedSchemaId)
      require auto.run.delivery.patchApplied.isSome
      let a = auto.run.targetJson

      check not a["synchronizedMode"].getBool()
      # Nothing is ever parked in automatic mode, so the application's poll of
      # `rb_hcr_wants_reload()` never answers true and `rb_hcr_apply_reload()`
      # is never called. §13.1 says exactly this.
      check not a["wantsReloadObserved"].getBool()
      check a["applyReloadCalls"].getInt() == 0
      # The patch still landed, and it landed with the same phase order.
      check a["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,trampolines,after"
      check a["codeSwapped"].getBool()
      check a["victimAtEnd"].getInt() == PatchedValue
      check a["workersThatSawOld"].getInt() == 4
      check a["workersThatSawNew"].getInt() == 4
      check a["workersThatSawOther"].getInt() == 0

      # AXIS 2, the other way round: the callbacks ran on the AGENT's detached
      # thread. This is the hazard §3.4 exists to let an application avoid, and
      # a gate that could not observe it could not claim synchronized mode
      # avoids anything.
      check not a["beforeRanOnMainThread"].getBool()
      check not a["afterRanOnMainThread"].getBool()

      # AXIS 1, the other way round: no park, so the coordinator's round trip
      # does not cover one. Asserted with a margin rather than against ParkMs
      # exactly, because what is being separated is "waited for the
      # application" from "did not", not a latency budget.
      check auto.coordinatorWaitMs < ParkMs

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m8.threaded-synchronized.v1")
      inspection["parkMs"] = newJInt(ParkMs)
      inspection["synchronized"] = s
      inspection["automatic"] = a
      inspection["coordinatorWaitMs"] = %*{
        "synchronized": sync.coordinatorWaitMs,
        "automatic": auto.coordinatorWaitMs
      }
      writeInspection(repoRoot,
        "integration_hcr_linux_threaded_synchronized_reload", inspection)

else:
  suite "integration_hcr_linux_threaded_synchronized_reload":
    test "HLX-M8 threaded synchronized-mode gate is linux-x86_64-only":
      skip()
