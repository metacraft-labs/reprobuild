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
## CONDITIONS. The negative controls' ">= 50%" is a statistical claim, and it
## was calibrated on a host that was not saturated: at load 150-215 on 32 CPUs
## it stopped holding while `tier2` stayed clean in every run (reprobuild-pm
## `issues/2026-09-26-hcr-concurrent-patch-gate-verdict-depends-on-host-load.md`).
## So every fixture process is classified by the host load read just before it
## starts, the calibrated checks are judged over the runs started inside
## `m4_verdict.MaxLoadPerCpu`, and a host that never gets inside it produces
## "conditions not met" — an explained skip, plus a `HCR-CONDITIONS-NOT-MET:`
## line the HCR lane reports as NO VERDICT — never a failure and never a pass.
## What would be a regression on any host is asserted over EVERY run, whatever
## the load: `m4_verdict` says which check is which. A §6.3 quiescence timeout
## is retried by the fixture as the defined outcome it is, counted, and checked
## to have written nothing.
##
## `allowed_mocks: none`. Real pthreads, real `tgkill`, real `futex`, real
## signal delivery, real `mprotect`, and the production
## `repro_hcr_lx_apply_direct_patch_at` reached through the probe shim that
## re-exports it. The patch bodies come out of a real `ET_REL` object.

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]
import repro_test_support/reasoned_skip

when defined(linux) and defined(amd64):
  import m4_fixture
  import m4_verdict
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
      # Set by every failed `ck`. A `skip` overwrites the case's status, so the
      # conditions-not-met skip below is taken only when this is still false.
      var anyFailed = false
      template ck(message: string; condition: untyped) =
        ## Counted `check`, per trap 4c: the count at the end of the test is
        ## asserted against a number a RUN produced, so a silent early return or
        ## a skipped loop body reddens the gate instead of shrinking it.
        inc asserted
        if not (condition):
          checkpoint(message)
          anyFailed = true
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
      #
      # The host condition is read BEFORE each process starts (see
      # `m4_verdict.MaxLoadPerCpu`); a sample started outside it is retried,
      # and EVERY attempt is kept: the unconditional checks judge them all.
      # ---------------------------------------------------------------------
      var samples: seq[SampleRun]
      for attempt in 0 ..< AttemptsPerRun:
        let load = hostLoadPerCpu()
        let r = runFixture(threadsBin, [
          "sample", hexA, hexB, $Workers, $SampleRounds, $ChaosThreads])
        samples.add(SampleRun(exitCode: r.exitCode, payload: r.payload,
                              loadPerCpu: load))
        if inConditions(load):
          break
      let sample = samples[^1]
      let s = if sample.payload != nil: sample.payload else: newJObject()

      # ---------------------------------------------------------------------
      # 2. THE FIVE ARMS.
      # ---------------------------------------------------------------------
      proc runArm(mode: string): ArmResult =
        collectArm(mode, Runs, proc (): ArmRun =
          let load = hostLoadPerCpu()
          let r = runFixture(threadsBin, [
            mode, hexA, hexB, $Workers, $Publications, $ChaosThreads])
          ArmRun(exitCode: r.exitCode, crashed: r.crashed,
                 windowAddress: r.windowAddress, faultPc: r.faultPc,
                 faultSignal: r.faultSignal, stderrText: r.stderrText,
                 payload: r.payload, loadPerCpu: load))

      let tier2 = runArm("tier2")
      let tier1 = runArm("tier1")
      let noAdjust = runArm("tier2-noadjust")
      let torn = runArm("torn")

      for arm in [tier2, tier1, noAdjust, torn]:
        checkpoint(arm.mode & " crashes " & $arm.measured.crashes & "/" &
          $arm.measured.runs & " inside the conditions, " & $arm.all.crashes &
          "/" & $arm.all.runs & " overall (highest load/CPU " &
          formatFloat(arm.maxLoadPerCpu, ffDecimal, 2) & "); fault offsets " &
          $arm.all.faultOffsets & " signals " & $arm.all.faultSignals &
          "; quiescence aborts " & $arm.all.quiesceAborts & ", abandoned " &
          $arm.all.quiesceAbandoned)
        for note in arm.all.notes:
          checkpoint(arm.mode & " " & note)

      let verdict = gateVerdict(samples, tier2, tier1, noAdjust, torn,
        runs = Runs, publications = Publications, sampleRounds = SampleRounds,
        slots = Workers + ChaosThreads, workers = Workers)

      # Evidence, written unconditionally so a reviewer re-reading this
      # milestone has the measured rates and the conditions they were measured
      # under rather than the assertions' verdict. `checkpoint` output is only
      # flushed on failure, so a green run would otherwise leave no numbers.
      proc armEvidence(arm: ArmResult): JsonNode =
        %*{"crashes": arm.measured.crashes, "runs": arm.measured.runs,
           "allCrashes": arm.all.crashes, "allRuns": arm.all.runs,
           "maxLoadPerCpu": arm.maxLoadPerCpu,
           "anomalies": arm.all.anomalies,
           "publications": arm.measured.publications,
           "ipAdjustments": arm.all.adjust,
           "nestedIpAdjustments": arm.all.nested,
           "quiesceAborts": arm.all.quiesceAborts,
           "quiesceBlockedAborts": arm.all.quiesceBlockedAborts,
           "quiesceAbandoned": arm.all.quiesceAbandoned,
           "faultOffsets": arm.all.faultOffsets,
           "faultSignals": arm.all.faultSignals,
           "strayExits": arm.all.strayExits}
      let inWindow = s{"parkedPcInWindow"}.getInt()
      let observations = s{"parkedObservations"}.getInt()
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "e2e_hcr_linux_concurrent_patch_no_torn_instruction.json",
        pretty(%*{
          "schemaId": "reprobuild.hcr.hlx-m4.concurrency-evidence.v2",
          "workers": Workers,
          "publicationsPerRun": Publications,
          "chaosThreads": ChaosThreads,
          "runsPerArm": Runs,
          "sampleRounds": SampleRounds,
          "maxLoadPerCpu": MaxLoadPerCpu,
          "conditionsMet": verdict.conditionsMet,
          "conditionsReason": verdict.conditionsReason,
          "sampleLoadPerCpu": sample.loadPerCpu,
          "sampleAttempts": samples.len,
          "parkedObservations": observations,
          "parkedPcInWindow": inWindow,
          "parkedPcInSled": s{"parkedPcInSled"}.getInt(),
          "inWindowRate":
            if observations > 0: float(inWindow) / float(observations) else: 0.0,
          "chaosSignalsDelivered": s{"chaosSignalsDelivered"}.getInt(),
          "arms": {
            "tier2": armEvidence(tier2),
            "tier1": armEvidence(tier1),
            "tier2-noadjust": armEvidence(noAdjust),
            "torn": armEvidence(torn)
          },
          "sampleResult": s
        }))

      # ---------------------------------------------------------------------
      # 3. THE VERDICT.
      #
      # What would be a regression on any host is asserted ALWAYS, over every
      # run. The negative controls' rates and the completeness checks are
      # calibrated statistics, asserted only when every arm collected its runs
      # inside the conditions; otherwise the case is reported as not having
      # met them — counted by the suite apart from a failure — and says which
      # arm and which readings. See `m4_verdict` for which check is which.
      # ---------------------------------------------------------------------
      ck "the verdict is the full check list",
        verdict.checks.len == GateCheckCount
      for c in verdict.checks:
        if not c.conditional:
          ck c.message, c.ok
      if verdict.conditionsMet:
        for c in verdict.checks:
          if c.conditional:
            ck c.message, c.ok
        expectCount(asserted, 6 + GateCheckCount)
      else:
        expectCount(asserted, 6 + GateUnconditionalCheckCount)
        # `skip` overwrites the case's status, so it must never follow ANY
        # failed check: that would turn a regression into a "conditions not
        # met". The count check above is included in that.
        if not anyFailed and asserted == 6 + GateUnconditionalCheckCount:
          let reason = "conditions not met (HLX-M4 calibrated at load/CPU <= " &
            $MaxLoadPerCpu & "): " & verdict.conditionsReason
          # The line the HCR lane keys on to report NO VERDICT rather than a
          # refusal (`scripts/lib/hcr_lane_verdict.sh`).
          echo "HCR-CONDITIONS-NOT-MET: " &
            "e2e_hcr_linux_concurrent_patch_no_torn_instruction: " & reason
          skip(reason)


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
