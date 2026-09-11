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
## SCOPE, RECORDED RATHER THAN GLOSSED. Detection is a frame-pointer walk, not a
## DWARF unwind: `_Unwind_Backtrace` takes a global lock and can allocate on its
## first FDE lookup, which is precisely the deadlock §6.2's allocation rule
## exists to prevent when a thread may be parked inside `malloc`. A frame
## pointer walk is pure aligned memory reads and is async-signal-safe. The cost
## is that it only sees frames compiled with a frame pointer, so the detection
## is a LOWER BOUND on what is on stack — this fixture is built so the frame it
## must find is visible, and a DWARF walk belongs with the `.eh_frame` work in
## HLX-M5.
##
## The gate therefore also asserts the NEGATIVE control: a run in which no
## thread is inside the victim must report zero. Without it, a detector that
## answered "yes" to everything would pass the positive half for free.
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

      # NEGATIVE CONTROL over the same detector. The handshake arm has nine
      # threads and none of them ever enters the victim, so a detector that says
      # "yes" indiscriminately is caught here rather than passing the positive
      # half for free.
      let control = runFixture(binary,
        ["handshake", hex(bodies.a), hex(bodies.b), "4"])
      ck "the control arm exited cleanly", control.exitCode == 0
      ck "the control arm produced a result", control.payload != nil
      ck "the detector reports nothing when nothing is on stack",
        control.payload["onStackDetected"].getInt() == 0
      ck "the control arm really parked threads",
        control.payload["parkedObservations"].getInt() == 4 * 9

      # Evidence, written unconditionally: `checkpoint` output is only flushed
      # on failure, so a green run would otherwise leave no numbers behind.
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "integration_hcr_linux_on_stack_function_reported_skipped.json", pretty(%*{"onstack": o, "control": control.payload}))

      expectCount(asserted, 21)

else:
  suite "integration_hcr_linux_on_stack_function_reported_skipped":
    test "HLX-M4 on-stack gate is linux-x86_64-only":
      skip()
