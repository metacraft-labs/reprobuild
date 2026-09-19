## HLX-M4 verification gate
## `integration_hcr_linux_on_stack_function_reported_skipped`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §6.2 step 5, §6.1 point 3.
##
## A thread is deliberately parked INSIDE the function being patched — it has
## entered `hcr_lx_m4_q_victim_onstack` and is blocked in a callee, so the
## victim's frame is live on its stack. The gate asserts all four properties the
## milestone names:
##
##   * the on-stack function is detected while every thread is parked;
##   * the trampoline is still installed (the publication is not refused);
##   * the in-flight frame completes in the RETAINED old body, returning the
##     old value (§6.1 point 3 — the old body is never overwritten and its
##     pages are never unmapped);
##   * the NEXT call runs the new body.
##
## SCOPE, DECIDED RATHER THAN DEFERRED (2026-09-19). Detection is a
## frame-pointer walk, not a DWARF unwind, and that is the SHIPPED ANSWER on
## Linux x86_64 rather than an interim one. `_Unwind_Backtrace` takes a global
## lock and can allocate on its first FDE lookup, which is precisely the
## deadlock §6.2's allocation rule exists to prevent when a thread may be
## parked inside `malloc`; a frame-pointer walk is pure aligned memory reads
## and is async-signal-safe. HLX-M4's residue assigned the DWARF walk to
## HLX-M5 in prose, HLX-M5 landed without it, and the assignment was unsound
## on HLX-M4's own terms — `.eh_frame` registration makes an unwinder able to
## DESCRIBE a patch body, not this handler able to CALL one. The assignment is
## therefore closed by REFUSING it, with the reason above, not by moving it to
## a fourth milestone.
##
## THE COST IS NOW REPORTED INSTEAD OF ASSUMED AWAY. The walk sees only frames
## compiled with a frame pointer, so it is a LOWER BOUND. A lower bound of zero
## is the statement "this walk found nothing", not "nothing is on stack", and
## the walk's own header has always instructed callers to treat a short walk as
## unknown while the caller returned a determinate 0. It returns -1 — NOT
## DETERMINED — when the answer is zero and any parked thread's chain merely
## STOPPED rather than ENDED.
##
## THREE ARMS, and the middle one is a repair. The positive arm parks a thread
## inside the victim. The negative control is nine threads none of which ever
## enters it — that arm's detector call did not exist until 2026-09-19 and its
## zero was the C initialiser travelling untouched to the printf, so the
## control could never have caught the detector it was written to catch. The
## third arm is the SAME fixture with ONE extra flag, `-fomit-frame-pointer`,
## where the walk is blind and the answer must be -1.
##
## `allowed_mocks: none`.

import std/[json, os, unittest]

when defined(linux) and defined(amd64):
  import m4_fixture

  template expectCount(actual, expected: int) =
    if actual != expected:
      checkpoint("assertion count is " & $actual & ", expected " & $expected)
    check actual == expected

  suite "integration_hcr_linux_on_stack_function_reported_skipped":
    test "a frame inside the patched function is detected and completes in the old body":
      var asserted = 0
      template ck(message: string; condition: untyped) =
        inc asserted
        if not (condition):
          checkpoint(message)
        check condition

      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let binary = buildFixture(repoRoot, "hcr_lx_m4_quiesce.c", "m4_quiesce")
      ck "the quiescence fixture was built", fileExists(binary)

      let run = runFixture(binary,
        ["onstack", hex(bodies.a), hex(bodies.b), "1"])
      ck "the on-stack arm exited cleanly", run.exitCode == 0
      ck "the on-stack arm produced a result", run.payload != nil
      let o = run.payload

      ck "the fixture created the on-stack thread and two spinners",
        o["threadsCreated"].getInt() == 3
      ck "every thread is in the slot table", o["slotCount"].getInt() == 3
      ck "quiescence succeeded", o["lastStatusName"].getStr() == "ok"
      ck "every thread parked", o["parkedObservations"].getInt() == 3
      ck "every parked thread published a PC",
        o["parkedPcsNonZero"].getInt() == 3
      ck "every parked thread was released",
        o["resumedObservations"].getInt() == 3

      # 1. Detected.
      ck "exactly one thread was found with the victim on its stack",
        o["onStackDetected"].getInt() == 1

      # 2. The trampoline was still installed — detection reports, it does not
      #    veto. §6.2 step 5 populates `skippedFunctions`; it does not refuse.
      ck "the publication was applied, not refused",
        o["publications"].getInt() == 1
      ck "no refusal was recorded", o["lastRefusal"].getStr() == "ok"
      ck "the window really changed",
        o["windowBefore"].getStr() != o["windowAfter"].getStr()
      ck "the window started as an untouched NOP sled",
        o["windowBefore"].getStr() == "0x9090909090909090"
      ck "the SYNC_CORE for that publication was issued",
        o["membarrierIssuedCount"].getInt() == 1

      # 3. The in-flight frame completed in the RETAINED old body.
      ck "the in-flight call returned the OLD value",
        o["onStackInFlightValue"].getInt() == 33

      # 4. The next call ran the new body.
      ck "the next call returned the NEW value",
        o["onStackNextValue"].getInt() == ValueA

      ck "the positive arm's walks all ENDED, so its answer is determinate",
        o["onStackIncompleteWalks"].getInt() == 0

      # NEGATIVE CONTROL over the same detector. The handshake arm has nine
      # threads and none of them ever enters the victim, so a detector that says
      # "yes" indiscriminately is caught here rather than passing the positive
      # half for free.
      #
      # CORRECTED 2026-09-19, and the correction is the reason this block is
      # worth reading. Until now the detector was NEVER CALLED in this arm:
      # `repro_hcr_lx_probe_quiesce_threads_on_stack_in` appeared only inside
      # the fixture's `onstack` branch, so the zero asserted below was
      # `int onstack_detected = 0;` — the initialiser — printed untouched. The
      # control was a constant wearing a negation (Verification-Harness-Traps
      # §7b), and it would have stayed green over a detector that answered
      # "yes" to everything, which is precisely the failure it was written to
      # catch. The fixture now runs the detector over the SAME victim range in
      # this arm, and `onStackDetectorCalls` is asserted so "answered 0" and
      # "was not asked" can never again be the same observation.
      let control = runFixture(binary,
        ["handshake", hex(bodies.a), hex(bodies.b), "4"])
      ck "the control arm exited cleanly", control.exitCode == 0
      ck "the control arm produced a result", control.payload != nil
      ck "the detector was actually CALLED in the control arm, once per round",
        control.payload["onStackDetectorCalls"].getInt() == 4
      ck "the detector reports nothing when nothing is on stack",
        control.payload["onStackDetected"].getInt() == 0
      ck "the control arm's zero is DETERMINATE, not a blind walk",
        control.payload["onStackIncompleteWalks"].getInt() == 0
      ck "the control arm really parked threads",
        control.payload["parkedObservations"].getInt() == 4 * 9

      # DETERMINACY ARM — the HLX-M4 repair of 2026-09-19, and the arm that
      # makes the two zeros above mean something.
      #
      # THE DECISION THIS ARM RECORDS. The frame-pointer lower bound IS the
      # shipped answer on Linux x86_64. The DWARF walk that HLX-M4's residue
      # assigned to HLX-M5 in prose is REFUSED, not deferred a third time:
      # `_Unwind_Backtrace` is not async-signal-safe — libgcc's unwinder takes
      # a global lock and can allocate on its first FDE lookup — this walk runs
      # in a signal handler with every other thread parked, and HLX-M4's own
      # third deliverable forbids allocating anywhere between the signal and
      # the release. HLX-M5 landed `.eh_frame` REGISTRATION, which makes an
      # unwinder able to DESCRIBE a patch body; it does not make this handler
      # able to CALL one safely.
      #
      # What changes instead is the REPORT. A lower bound of zero is not the
      # statement "nothing is on stack"; it is "this walk found nothing", and
      # the header's own contract has always said a short walk must be treated
      # as unknown while the caller returned a determinate 0. It now returns
      # -1 when the answer is zero AND any parked thread's chain merely
      # STOPPED rather than ENDED.
      #
      # ONE FLAG between this build and the one above: `-fomit-frame-pointer`,
      # which is what an ordinary `-O2` target ships with. A control differing
      # in more than one thing explains nothing.
      let blindBinary = buildFixture(repoRoot, "hcr_lx_m4_quiesce.c",
        "m4_quiesce_nofp", ["-fomit-frame-pointer"])
      ck "the frame-pointer-less fixture was built", fileExists(blindBinary)
      let blind = runFixture(blindBinary,
        ["handshake", hex(bodies.a), hex(bodies.b), "4"])
      ck "the blind arm exited cleanly", blind.exitCode == 0
      ck "the blind arm produced a result", blind.payload != nil
      ck "the blind arm parked the same nine threads, so the difference is the walk",
        blind.payload["parkedObservations"].getInt() == 4 * 9
      ck "the blind arm's walks STOPPED rather than ENDED",
        blind.payload["onStackIncompleteWalks"].getInt() > 0
      ck "a blind walk answers NOT DETERMINED, not zero",
        blind.payload["onStackDetected"].getInt() == -1
      # And the pair, asserted directly: same fixture, same arm, same thread
      # set, opposite answers.
      ck "the two builds disagree, which is what makes -1 informative",
        blind.payload["onStackDetected"].getInt() !=
          control.payload["onStackDetected"].getInt()

      # Evidence, written unconditionally: `checkpoint` output is only flushed
      # on failure, so a green run would otherwise leave no numbers behind.
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "integration_hcr_linux_on_stack_function_reported_skipped.json", pretty(%*{"onstack": o, "control": control.payload, "blind": blind.payload}))

      expectCount(asserted, 31)

else:
  suite "integration_hcr_linux_on_stack_function_reported_skipped":
    test "HLX-M4 on-stack gate is linux-x86_64-only":
      skip()
