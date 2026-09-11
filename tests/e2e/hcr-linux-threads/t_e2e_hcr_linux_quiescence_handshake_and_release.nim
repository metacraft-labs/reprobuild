## HLX-M4 verification gate `e2e_hcr_linux_quiescence_handshake_and_release`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §6.2.
##
## Asserts the milestone's own wording: every thread parks, each parked PC is
## captured, the patch is applied set-wide, all threads are released, and
## threads blocked in restartable syscalls resume without observable `EINTR`.
##
## Two things this gate does that a weaker version of it would not:
##
##  * It asserts the parked-observation COUNT equals rounds x slots, and that
##    slots equals the threads the fixture actually created. A handshake that
##    parked six of nine threads would otherwise report "everyone parked"
##    truthfully about the six it knew about — which is exactly what an earlier
##    draft of the fixture did, because three reader threads had died on a bad
##    file descriptor before the first signal was sent.
##  * It separates the two `EINTR` populations. `SA_RESTART` covers `read(2)`
##    and CANNOT cover `nanosleep(2)`, which the kernel never restarts because
##    it has a remaining-time out-parameter. Folding them into one counter turns
##    a documented, unavoidable cost into what looks like an `SA_RESTART`
##    failure — or, worse, hides a real one behind an expected number.
##
## Set-wide atomicity (§6.1's closing paragraph: tier 1 gives per-function
## atomicity, never set-wide) is proven against its own control: the same two
## functions published under ONE quiescence versus under TWO. If the split arm
## does not produce mixed observations, the joint arm's zero proves nothing.
##
## `allowed_mocks: none`.

import std/[json, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import m4_fixture

  const
    Rounds = 16
    HandshakeThreads = 9   # 4 spinning, 3 blocked in read(2), 2 in nanosleep

  template expectCount(actual, expected: int) =
    if actual != expected:
      checkpoint("assertion count is " & $actual & ", expected " & $expected)
    check actual == expected

  suite "e2e_hcr_linux_quiescence_handshake_and_release":
    test "every thread parks, publishes its PC, and is released":
      var asserted = 0
      template ck(message: string; condition: untyped) =
        inc asserted
        if not (condition):
          checkpoint(message)
        check condition

      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let hexA = hex(bodies.a)
      let hexB = hex(bodies.b)
      let binary = buildFixture(repoRoot, "hcr_lx_m4_quiesce.c", "m4_quiesce")
      ck "the quiescence fixture was built", fileExists(binary)

      # ------------------------------------------------------------------ 1
      let run = runFixture(binary, ["handshake", hexA, hexB, $Rounds])
      ck "the handshake arm exited cleanly", run.exitCode == 0
      ck "the handshake arm produced a result", run.payload != nil
      let h = run.payload

      ck "the fixture started the threads it says it did",
        h["threadsCreated"].getInt() == HandshakeThreads
      # The slot table is what the handshake actually signals. If it disagrees
      # with the thread count, threads exited before the measurement and every
      # "all parked" claim below is about a smaller population.
      ck "every created thread is in the slot table",
        h["slotCount"].getInt() == HandshakeThreads
      ck "every slot was signalled",
        h["signalledCount"].getInt() == HandshakeThreads
      ck "every round reached quiescence", h["roundsOk"].getInt() == Rounds
      ck "the last round reported ok", h["lastStatusName"].getStr() == "ok"
      # Complete dump, not `> 0`.
      ck "every thread parked in every round",
        h["parkedObservations"].getInt() == Rounds * HandshakeThreads
      ck "every parked thread published a userspace PC",
        h["parkedPcsNonZero"].getInt() == Rounds * HandshakeThreads
      ck "every parked thread was released",
        h["resumedObservations"].getInt() == Rounds * HandshakeThreads
      ck "no thread appeared after enumeration",
        h["straySignals"].getInt() == 0
      ck "the enumeration loop converged",
        h["enumerationRounds"].getInt() >= 2
      ck "no thread was left unresponsive",
        h["unresponsiveCount"].getInt() == 0

      # SA_RESTART: the restartable population must be untouched...
      ck "threads blocked in read(2) observed no EINTR",
        h["eintrRestartable"].getInt() == 0
      # ...and the non-restartable one must be non-empty, or the arm above is
      # satisfied by a run in which no signal ever interrupted anything.
      ck "the nanosleep threads WERE interrupted, so the run is not vacuous",
        h["eintrNanosleep"].getInt() > 0

      ck "no publication happened in the handshake arm",
        h["publications"].getInt() == 0
      ck "the target text is unchanged by a handshake alone",
        h["windowBefore"].getStr() == h["windowAfter"].getStr()
      ck "the quiescence signal is a real-time signal",
        h["quiesceSignal"].getInt() >= 34

      let parkNs = h["parkNsMax"].getInt()
      let releaseNs = h["releaseNsMax"].getInt()
      checkpoint("worst park " & $parkNs & " ns, worst release " &
        $releaseNs & " ns over " & $Rounds & " rounds of " &
        $HandshakeThreads & " threads")
      # §6.3's default bound is 250 ms; a handshake that needed more than that
      # would time out in production rather than merely be slow here.
      ck "the handshake stayed inside the §6.3 bound", parkNs < 250_000_000

      # ------------------------------------------------------------------ 2
      # Set-wide atomicity, and its control.
      let joint = runFixture(binary, ["setwide", hexA, hexB, $Rounds])
      ck "the set-wide arm exited cleanly", joint.exitCode == 0
      ck "the set-wide arm produced a result", joint.payload != nil
      let j = joint.payload
      ck "both functions were published in every round",
        j["publications"].getInt() == Rounds * 2
      ck "the checker really observed both states",
        j["setWideBothOld"].getInt() > 0 and j["setWideBothNew"].getInt() > 0
      ck "no observation saw the set half-applied",
        j["setWideMixed"].getInt() == 0
      ck "the checker classified every sample",
        j["setWideOther"].getInt() == 0

      let split = runFixture(binary, ["setwide-split", hexA, hexB, $Rounds])
      ck "the split control exited cleanly", split.exitCode == 0
      ck "the split control produced a result", split.payload != nil
      let sp = split.payload
      ck "the split control published both functions",
        sp["publications"].getInt() == 2
      # THE CONTROL. Publishing the two functions under separate quiescences
      # must produce the mixture the joint arm reports zero of. Without this the
      # joint arm's zero is indistinguishable from a checker that cannot see a
      # mixture at all.
      ck "the split control DOES observe a half-applied set",
        sp["setWideMixed"].getInt() > 0

      checkpoint("set-wide mixed: joint " & $j["setWideMixed"].getInt() &
        " of " & $(j["setWideBothOld"].getInt() + j["setWideBothNew"].getInt()) &
        "; split " & $sp["setWideMixed"].getInt() & " of " &
        $(sp["setWideBothOld"].getInt() + sp["setWideBothNew"].getInt()))

      # Evidence, written unconditionally: `checkpoint` output is only flushed
      # on failure, so a green run would otherwise leave no numbers behind.
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "e2e_hcr_linux_quiescence_handshake_and_release.json", pretty(%*{"handshake": h, "setwide": j, "setwideSplit": sp}))

      expectCount(asserted, 30)

else:
  suite "e2e_hcr_linux_quiescence_handshake_and_release":
    test "HLX-M4 quiescence gate is linux-x86_64-only":
      skip()
