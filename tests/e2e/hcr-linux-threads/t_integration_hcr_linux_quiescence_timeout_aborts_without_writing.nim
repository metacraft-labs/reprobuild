## HLX-M4 verification gate
## `integration_hcr_linux_quiescence_timeout_aborts_without_writing`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §6.3.
##
## A thread blocks the quiescence signal with `pthread_sigmask` and spins, which
## is the only way to manufacture §6.3's failure from user space — a thread in
## uninterruptible `D` state cannot be arranged on demand.
##
## The gate asserts the defined outcome in full: the wait is BOUNDED, the
## threads that did park are released anyway, the target's text is
## BYTE-IDENTICAL, and the diagnostic NAMES the unresponsive tid rather than
## reporting a generic failure.
##
## The tid assertion is the one that has teeth. §6.3 does not merely require a
## failure; it requires "a diagnostic naming the unresponsive `tid`s", and the
## gate checks that the reported tid is the tid of the thread the fixture
## deliberately made deaf — not merely that some number was printed.
##
## Safety here is by CONSTRUCTION, not by cleanup: quiescence is acquired during
## prepare, which touches no target memory, so an aborted quiescence cannot
## leave a partial patch because no byte was ever written. The byte-identity
## check is the evidence for that claim, and it is compared against the SAME
## word read before the attempt.
##
## `allowed_mocks: none`.

import std/[json, os, unittest]

when defined(linux) and defined(amd64):
  import m4_fixture

  template expectCount(actual, expected: int) =
    if actual != expected:
      checkpoint("assertion count is " & $actual & ", expected " & $expected)
    check actual == expected

  suite "integration_hcr_linux_quiescence_timeout_aborts_without_writing":
    test "an unresponsive thread aborts the patch and changes nothing":
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
        ["timeout", hex(bodies.a), hex(bodies.b), "1"])
      ck "the timeout arm exited cleanly", run.exitCode == 0
      ck "the timeout arm produced a result", run.payload != nil
      let t = run.payload

      ck "the fixture created the deaf thread and three others",
        t["threadsCreated"].getInt() == 4
      ck "every thread is in the slot table", t["slotCount"].getInt() == 4
      ck "every slot was signalled", t["signalledCount"].getInt() == 4

      # The named outcome, not a generic failure.
      ck "quiescence reported a TIMEOUT",
        t["lastStatusName"].getStr() == "quiescence-timeout"
      ck "no round succeeded", t["roundsOk"].getInt() == 0

      # Bounded: the fixture asks for 120 ms and the observed wall time must sit
      # just above it, never unbounded and never suspiciously below it.
      let parkNs = t["parkNsMax"].getInt()
      ck "the wait was bounded above", parkNs < 400_000_000
      ck "the wait actually waited", parkNs >= 120_000_000

      # Everyone who parked was released, or the process would have deadlocked
      # on join — which it plainly did not, since it exited 0.
      ck "three of the four threads parked",
        t["parkedObservations"].getInt() == 3
      ck "every parked thread was released",
        t["resumedObservations"].getInt() == 3

      # The diagnostic names the tid, and it is the RIGHT tid.
      ck "exactly one thread was unresponsive",
        t["unresponsiveCount"].getInt() == 1
      ck "the fixture recorded which thread it made deaf",
        t["deafTid"].getInt() > 0
      ck "the named unresponsive tid is the deaf thread",
        t["unresponsiveTid"].getInt() == t["deafTid"].getInt()

      # Nothing was written.
      ck "no publication was attempted", t["publications"].getInt() == 0
      ck "the target window is byte-identical",
        t["windowBefore"].getStr() == t["windowAfter"].getStr()
      # And it is identical to the UNPATCHED pre-state, not merely to itself —
      # a window that was already patched would satisfy the line above.
      ck "the target window is still the untouched NOP sled",
        t["windowAfter"].getStr() == "0x9090909090909090"
      ck "no SYNC_CORE was issued, because nothing was published",
        t["membarrierIssuedCount"].getInt() == 0

      # Evidence, written unconditionally: `checkpoint` output is only flushed
      # on failure, so a green run would otherwise leave no numbers behind.
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "integration_hcr_linux_quiescence_timeout_aborts_without_writing.json", pretty(%*{"timeout": t}))

      expectCount(asserted, 19)

else:
  suite "integration_hcr_linux_quiescence_timeout_aborts_without_writing":
    test "HLX-M4 quiescence timeout gate is linux-x86_64-only":
      skip()
