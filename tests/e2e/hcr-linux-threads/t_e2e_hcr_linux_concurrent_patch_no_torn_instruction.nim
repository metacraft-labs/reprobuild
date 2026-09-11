## HLX-M4 verification gate `e2e_hcr_linux_concurrent_patch_no_torn_instruction`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.2, §4.4, §6.1, §6.2.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M4.
##
## WHAT THIS GATE IS FOR, and why it is not the Godot demo again.
##
## The demo patched a function five kernel threads were executing and saw no
## torn value across 150 observations. The agent that measured it said the
## honest thing: one run cannot distinguish "safe" from "did not lose the race".
## This gate is built to lose the race — many publications, a dozen hot threads,
## a continuous signal storm — and, crucially, to be ABLE to report losing it.
##
## FIVE ARMS, and the milestone's verdict comes from the pattern across them,
## not from any one of them being green:
##
##   tier2           the shippable configuration. MUST NOT crash, MUST see no
##                   third value.
##   tier1           publication with no quiescence, which is what the campaign
##                   has called "the intended default". MUST crash — if it ever
##                   stops crashing, either the hazard has been fixed somewhere
##                   or this harness has lost its teeth, and both need a human.
##   tier2-noadjust  quiescence WITHOUT the §6.2 step 6 IP adjustment. MUST
##                   crash. This is what proves the adjustment is load-bearing
##                   rather than decorative — a quiescence path that silently
##                   no-opped would otherwise pass every safety check for free.
##   torn            the same eight bytes published NON-atomically. MUST crash.
##                   The positive control: it is the only arm that proves the
##                   detector can fire at all, and without it a green `tier2` is
##                   worth nothing.
##   sample          no patching; quiescence used purely to MEASURE how often a
##                   hot thread's PC is inside the eight bytes a publication
##                   overwrites. This is the number the statistical claim rests
##                   on, and it is measured rather than assumed.
##
## `allowed_mocks: none`. Real pthreads, real `tgkill`, real `futex`, real
## signal delivery, real `mprotect`, and the production
## `repro_hcr_lx_apply_direct_patch_at` reached through the probe shim that
## re-exports it. The patch bodies come out of a real `ET_REL` object.

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

when defined(linux) and defined(amd64):
  import m4_fixture
  import repro_hcr_agent

  const
    Workers = 12
    Publications = 8
    ChaosThreads = 2
    Runs = 24
    SampleRounds = 200

  template expectCount(actual, expected: int) =
    ## Trap 4c: promote the assertion-count fingerprint into the check itself,
    ## so a silent skip reddens the run on the spot instead of being visible
    ## only to somebody diffing two transcripts.
    if actual != expected:
      checkpoint("assertion count is " & $actual & ", expected " & $expected)
    check actual == expected

  suite "e2e_hcr_linux_concurrent_patch_no_torn_instruction":
    test "tier-2 publication survives concurrent execution; tier-1 does not":
      var asserted = 0
      template ck(message: string; condition: untyped) =
        ## Counted `check`, per trap 4c: the count at the end of the test is
        ## asserted against a number a RUN produced, so a silent early return or
        ## a skipped loop body reddens the gate instead of shrinking it.
        inc asserted
        if not (condition):
          checkpoint(message)
        check condition

      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      ck "patch body A is non-empty", bodies.a.len > 0
      ck "patch body B is non-empty", bodies.b.len > 0
      # `mov $0x4d,%eax` / `mov $0x63,%eax`: the 77 and 99 the workers will see.
      ck "body A really returns 77", hex(bodies.a).contains("b84d000000")
      ck "body B really returns 99", hex(bodies.b).contains("b863000000")

      let threadsBin = buildFixture(repoRoot, "hcr_lx_m4_threads.c",
                                    "m4_threads")
      ck "the threads fixture was built", fileExists(threadsBin)

      let hexA = hex(bodies.a)
      let hexB = hex(bodies.b)

      # ---------------------------------------------------------------------
      # 1. ADVERSARIAL PRESSURE, MEASURED.
      #
      # Park every worker at 200 random instants and count how many are
      # standing inside the eight bytes a publication would overwrite. Without
      # this number the rest of the gate is an anecdote: "no tear was observed"
      # means nothing unless the window was actually occupied.
      # ---------------------------------------------------------------------
      let sample = runFixture(threadsBin, [
        "sample", hexA, hexB, $Workers, $SampleRounds, $ChaosThreads])
      ck "the sampling arm exited cleanly", sample.exitCode == 0
      ck "the sampling arm produced a result", sample.payload != nil
      let s = sample.payload
      ck "every sampling round reached quiescence",
        s["quiesceRounds"].getInt() == SampleRounds
      ck "no sampling round failed to quiesce",
        s["quiesceFailures"].getInt() == 0
      # Complete-dump rule: the observation count must equal rounds x slots, not
      # merely be positive. A truncated sample would satisfy every threshold
      # below it.
      ck "the parked-observation dump is complete",
        s["parkedObservations"].getInt() ==
          SampleRounds * (Workers + ChaosThreads)
      ck "threads really were caught inside the publication window",
        s["parkedPcInWindow"].getInt() > 0
      ck "threads really were caught inside the sled",
        s["parkedPcInSled"].getInt() >= s["parkedPcInWindow"].getInt()
      ck "all twelve workers ran", s["distinctWorkerTids"].getInt() == Workers
      ck "the signal storm delivered", s["chaosSignalsDelivered"].getInt() > 0
      ck "the host has SYNC_CORE", s["membarrierSyncCore"].getBool()
      ck "the host permits a RW|EXEC transient",
        s["textRwxTransition"].getBool()

      let inWindow = s["parkedPcInWindow"].getInt()
      let observations = s["parkedObservations"].getInt()
      checkpoint("in-window PC rate: " & $inWindow & " / " & $observations)

      # ---------------------------------------------------------------------
      # 2. THE FIVE ARMS.
      # ---------------------------------------------------------------------
      # Arm tallies. `crashes` counts ONLY the fault we are looking for; a run
      # that exits non-zero any other way lands in `strayExits` and is asserted
      # to be empty. Merging the two — which this harness used to do — lets a
      # build failure, an OOM or a fixture `HCR-M4-FATAL` masquerade as the
      # hazard, which is trap 1 exactly: it makes the arms that MUST crash
      # satisfiable by something that is not a crash.
      type ArmResult = object
        crashes, runs, anomalies, publications, adjust, nested: int
        strayExits: seq[int]
        inWindowFaults, outOfWindowFaults, missingWindow: int
        faultOffsets: seq[int]
        faultSignals: seq[int]

      proc runArm(mode: string): ArmResult =
        for i in 0 ..< Runs:
          let r = runFixture(threadsBin, [
            mode, hexA, hexB, $Workers, $Publications, $ChaosThreads])
          result.runs += 1
          if r.exitCode != 0:
            if r.crashed:
              # Exit code CrashExitCode AND an `HCR-M4-CRASH` record. Both, not
              # either: a die-before-output wearing the right code is
              # indistinguishable from a fault unless the record is there too.
              result.crashes += 1
              if r.windowAddress == 0'u64:
                result.missingWindow += 1
              else:
                let offset = int(r.faultPc.int64 - r.windowAddress.int64)
                result.faultOffsets.add(offset)
                result.faultSignals.add(r.faultSignal)
                # THE REASON, not just the fact. Design §6.1 point 4 is
                # specifically a thread resuming at a byte offset INSIDE the
                # eight bytes the publication overwrites. A crash anywhere else
                # is a different bug and must not be allowed to satisfy an arm
                # whose whole job is to demonstrate this one.
                if offset >= 0 and offset < 8:
                  result.inWindowFaults += 1
                else:
                  result.outOfWindowFaults += 1
                  checkpoint(mode & " run " & $i & " faulted at window+" &
                    $offset & ", outside the 8-byte window, signal " &
                    $r.faultSignal)
            else:
              result.strayExits.add(r.exitCode)
              checkpoint(mode & " run " & $i & " exited " & $r.exitCode &
                " without an rc-" & $CrashExitCode & " crash record: " &
                r.stderrText)
          if r.payload != nil:
            result.anomalies += r.payload["anomalies"].getInt()
            result.publications += r.payload["publicationsApplied"].getInt()
            result.adjust += r.payload["quiesceAdjustCount"].getInt()
            result.nested += r.payload["quiesceNestedAdjustCount"].getInt()

      let tier2 = runArm("tier2")
      let tier1 = runArm("tier1")
      let noAdjust = runArm("tier2-noadjust")
      let torn = runArm("torn")

      checkpoint("tier2 crashes " & $tier2.crashes & "/" & $tier2.runs &
        "; tier1 " & $tier1.crashes & "/" & $tier1.runs &
        "; tier2-noadjust " & $noAdjust.crashes & "/" & $noAdjust.runs &
        "; torn " & $torn.crashes & "/" & $torn.runs)

      # -- every failing run failed the way we claim it did -------------------
      # Asserted BEFORE the counts, because a count of crashes is only evidence
      # about §6.1 point 4 if each one is that fault. Three separate properties,
      # each of which the harness previously only asserted in prose:
      #   1. no arm exited non-zero by any route other than the fault handler;
      #   2. every fault announced its window, so the offset is knowable;
      #   3. every fault's PC lies strictly inside the eight published bytes.
      for (name, arm) in {"tier1": tier1, "tier2-noadjust": noAdjust,
                          "torn": torn, "tier2": tier2}:
        ck name & ": no run exited non-zero without an rc-" &
          $CrashExitCode & " crash record",
          arm.strayExits.len == 0
        ck name & ": every faulting run announced its publication window",
          arm.missingWindow == 0
        ck name & ": every fault landed INSIDE the 8-byte window",
          arm.outOfWindowFaults == 0
        ck name & ": in-window faults account for every crash",
          arm.inWindowFaults == arm.crashes

      checkpoint("tier1 fault offsets " & $tier1.faultOffsets &
        " signals " & $tier1.faultSignals)
      checkpoint("tier2-noadjust fault offsets " & $noAdjust.faultOffsets &
        " signals " & $noAdjust.faultSignals)
      checkpoint("torn fault offsets " & $torn.faultOffsets &
        " signals " & $torn.faultSignals)

      # -- the positive control, asserted FIRST ------------------------------
      # If a non-atomic publication of the same word does not kill the process,
      # nothing below discriminates and the green arms are vacuous.
      ck "EVERY non-atomic publication was detected (positive control)",
        torn.crashes == torn.runs

      # -- tier 1 is unsafe, and this gate says so out loud ------------------
      ck "tier-1 publication fails under concurrent execution",
        tier1.crashes > 0
      ck "tier-1 fails often, not marginally",
        tier1.crashes * 2 >= tier1.runs

      # -- the IP adjustment is load-bearing ---------------------------------
      ck "removing the §6.2 step 6 IP adjustment restores the failure",
        noAdjust.crashes > 0
      ck "the adjustment's removal fails often, not marginally",
        noAdjust.crashes * 2 >= noAdjust.runs

      # -- the shippable configuration ---------------------------------------
      ck "no tier-2 run faulted", tier2.crashes == 0
      ck "no tier-2 run observed a third return value", tier2.anomalies == 0
      ck "every tier-2 run published everything it was asked to",
        tier2.publications == Runs * Publications
      # The mechanism ENGAGED. A quiescence that adjusted nothing across 24 runs
      # would pass the two checks above for free, which is this campaign's
      # dominant failure mode.
      ck "the IP adjustment engaged at least once", tier2.adjust > 0
      ck "the nested-signal-frame adjustment engaged at least once",
        tier2.nested > 0

      # Evidence, written unconditionally so a reviewer re-reading this
      # milestone has the measured rates rather than the assertions' verdict.
      # `checkpoint` output is only flushed on failure, so a green run would
      # otherwise leave no numbers behind at all.
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "e2e_hcr_linux_concurrent_patch_no_torn_instruction.json",
        pretty(%*{
          "schemaId": "reprobuild.hcr.hlx-m4.concurrency-evidence.v1",
          "workers": Workers,
          "publicationsPerRun": Publications,
          "chaosThreads": ChaosThreads,
          "runsPerArm": Runs,
          "sampleRounds": SampleRounds,
          "parkedObservations": s["parkedObservations"].getInt(),
          "parkedPcInWindow": inWindow,
          "parkedPcInSled": s["parkedPcInSled"].getInt(),
          "inWindowRate": float(inWindow) / float(observations),
          "chaosSignalsDelivered": s["chaosSignalsDelivered"].getInt(),
          "arms": {
            "tier2": {"crashes": tier2.crashes, "runs": tier2.runs,
                      "anomalies": tier2.anomalies,
                      "publications": tier2.publications,
                      "ipAdjustments": tier2.adjust,
                      "nestedIpAdjustments": tier2.nested},
            "tier1": {"crashes": tier1.crashes, "runs": tier1.runs,
                      "faultOffsets": tier1.faultOffsets,
                      "faultSignals": tier1.faultSignals,
                      "strayExits": tier1.strayExits},
            "tier2-noadjust": {"crashes": noAdjust.crashes,
                               "runs": noAdjust.runs,
                               "faultOffsets": noAdjust.faultOffsets,
                               "faultSignals": noAdjust.faultSignals,
                               "strayExits": noAdjust.strayExits},
            "torn": {"crashes": torn.crashes, "runs": torn.runs,
                     "faultOffsets": torn.faultOffsets,
                     "faultSignals": torn.faultSignals,
                     "strayExits": torn.strayExits}
          },
          "sampleResult": s
        }))

      expectCount(asserted, 42)

    test "the AGENT chooses tier 2 over the wire for a multithreaded target":
      ## The in-process arms above prove the publication is safe under
      ## quiescence. This one proves the production agent ACTUALLY QUIESCES —
      ## the branch in `repro_hcr_apply_direct_patch` that counts threads and
      ## decides. HLX-M0's wire gate cannot show it, because its target polls
      ## the agent on its only thread and is correctly left on tier 1.
      var asserted = 0
      template ck(message: string; condition: untyped) =
        inc asserted
        if not (condition):
          checkpoint(message)
        check condition

      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let caseDir = m4CaseDir(repoRoot)
      let workDir = m4WorkDir(repoRoot)
      let targetBin = workDir / "m4_wire_target"
      discard runOrFail(shellCommand([
        "gcc", "-O2", "-g",
        "-falign-functions=16",
        "-fpatchable-function-entry=16,0",
        "-fcf-protection=full",
        # HLX-M1 makes build-id verification MANDATORY (design §7.3): without
        # a `.note.gnu.build-id` the resolver refuses with
        # `elf-build-id-absent` and never reaches the patch path. The nix
        # toolchain does not pass it by default, and the refusal is correct —
        # so the gate supplies it, exactly as the patchable build profile a
        # real target uses must.
        "-Wl,--build-id",
        "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
        "-o", targetBin,
        caseDir / "hcr_lx_m4_wire_target.c",
        repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c",
        "-lpthread"]), repoRoot)
      ck "the wire target was built", fileExists(targetBin)

      let socketPath = workDir / "hcr-lx-m4.sock"
      removeFile(socketPath)
      var listener = listenHcrAgentUnixSocket(socketPath)
      defer: listener.close()

      var env = newStringTable()
      for key, value in envPairs():
        env[key] = value
      env[ReproHcrAgentSocketEnv] = socketPath
      let process = startProcess(targetBin, workingDir = repoRoot, env = env,
        options = {poStdErrToStdOut})

      var connection = acceptHcrAgentConnection(listener)
      var client = initHcrCoordinatorClient(
        HcrLinuxX86_64DirectSupportProfile)
      let request = directPatchRequest(
        patchId = "hlx-m4-linux-wire-1",
        supportProfile = HcrLinuxX86_64DirectSupportProfile,
        changedFunctions = ["hcr_lx_m4_wire_victim"],
        targetSymbols = ["hcr_lx_m4_wire_victim"],
        directPatchBytes = bodies.a,
        debugObjectBytes = [],
        unwindMetadataBytes = [],
        sourceGenerationMap = [])
      let delivery = client.deliverPatchRequest(connection, request)
      connection.close()

      let output = process.outputStream.readAll()
      let exitCode = process.waitForExit()
      process.close()
      if exitCode != 0:
        checkpoint(output)
      ck "the multithreaded target exited cleanly", exitCode == 0

      if delivery.patchFailed.isSome:
        checkpoint("agent refused: " & delivery.patchFailed.get().message)
      ck "the agent did not refuse", delivery.patchFailed.isNone
      ck "the agent reported a patch", delivery.patchApplied.isSome

      let result = parseJson(output.strip())
      ck "the result is the expected schema",
        result["schemaId"].getStr() ==
          "reprobuild.hcr.hlx-m4.wire-target-result.v1"
      ck "the target had twelve worker threads",
        result["distinctWorkerTids"].getInt() == 12
      ck "the workers really ran across the patch",
        result["totalCalls"].getInt() > 1_000_000
      ck "the victim returned 11 before", result["before"].getInt() == 11
      ck "the victim returns 77 after", result["after"].getInt() == ValueA
      ck "no worker observed a third value", result["anomalies"].getInt() == 0
      # THE POINT OF THIS ARM.
      ck "the agent published at TIER 2, because the target is multithreaded",
        result["publicationTier"].getInt() == 2
      ck "quiescence is installed on a real-time signal",
        result["quiescenceSignal"].getInt() >= 34
      # -1 would mean the extent was unknown and on-stack detection never ran;
      # a real answer (0 or more) means §6.2 step 5 was reached with a symbol
      # size from the ELF resolver.
      ck "on-stack detection produced a determinate answer",
        result["onStackThreads"].getInt() >= 0

      expectCount(asserted, 13)

else:
  suite "e2e_hcr_linux_concurrent_patch_no_torn_instruction":
    test "HLX-M4 concurrency gate is linux-x86_64-only":
      skip()
