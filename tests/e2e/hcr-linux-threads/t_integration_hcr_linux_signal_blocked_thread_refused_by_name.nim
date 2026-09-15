## HLX-M4 verification gate
## `integration_hcr_linux_signal_blocked_thread_refused_by_name`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §6.2, §6.3.
##
## THE FINDING THIS EXISTS FOR. Quiescence is a `SIGRTMIN+3` handshake. A thread
## created with that signal BLOCKED can never run the handler, so it can never
## park — and before the signal-mask census the provider reported
## that as `quiescence-timeout`, which is the wrong diagnosis with the wrong
## remedy attached: "timeout" invites a longer deadline, and no deadline can
## help a thread the kernel will never deliver the signal to.
##
## It is not hypothetical. Mesa creates its driver threads with `sigfillset`
## minus `SIGSYS` (`u_thread_create`), so ANY process that has loaded a Mesa
## driver carries threads in exactly this state — measured on a Godot process
## rendering through lavapipe, `llvmpipe-0` and `<proc>:disk$0` both with
## `SigBlk=fffffffe3ffbfaff`, bit 36 set, and bit 36 is signal 37.
##
## WHAT IS ASSERTED, and why each line has teeth:
##
##   * the refusal is NAMED `quiescence-signal-blocked` and not a timeout;
##   * the handshake still HAPPENED and was still bounded and still released —
##     four signals delivered, three threads parked, three resumed, a ~120 ms
##     wait. The census explains a refusal; it must not replace the handshake,
##     because `SigBlk` is transiently set by any thread running any signal
##     handler and a pre-flight version of this check was measured losing 9 of
##     192 publications in the concurrency gate;
##   * THE CENSUS ACTUALLY READ SOMETHING. `sigmaskReadOk` must equal the
##     number of unresponsive threads. A census that read nothing would report
##     zero blocked threads — byte-for-byte what a healthy process reports —
##     which is trap 4 of
##     `codetracer-specs/Testing/Verification-Harness-Traps.md` wearing a
##     `/proc` read;
##   * the tid, the NAME and the MASK it reports are the deaf thread's, and the
##     mask really does have the quiescence signal's bit set. Not "some number
##     was printed";
##   * the target's text is byte-identical and is still the untouched sled, and
##     no SYNC_CORE was issued, because nothing was published.
##
## THE CONTROL ARM IS IN THE SIBLING GATE, and it is what stops this one from
## being vacuous: `integration_hcr_linux_quiescence_timeout_aborts_without_
## writing` runs the SAME fixture with the SAME deaf thread and the census
## turned off and the SAME 120 ms deadline, and still measures
## `quiescence-timeout`. Same input, same deadline, one lever, two outcomes —
## so the new status cannot be something the fixture would have produced
## anyway.
##
## `allowed_mocks: none`. A real pthread with a real `pthread_sigmask`, a real
## `/proc` read, and the production `repro_hcr_lx_quiesce_begin`.

import std/[json, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import m4_fixture

  template expectCount(actual, expected: int) =
    if actual != expected:
      checkpoint("assertion count is " & $actual & ", expected " & $expected)
    check actual == expected

  suite "integration_hcr_linux_signal_blocked_thread_refused_by_name":
    test "a thread that blocks the quiescence signal is refused by NAME, not as a timeout":
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
        ["signal-blocked", hex(bodies.a), hex(bodies.b), "1"])
      ck "the signal-blocked arm exited cleanly", run.exitCode == 0
      ck "the signal-blocked arm produced a result", run.payload != nil
      let t = run.payload

      ck "the fixture created the deaf thread and three others",
        t["threadsCreated"].getInt() == 4
      ck "every thread is in the slot table", t["slotCount"].getInt() == 4

      # The named outcome. This is the whole point of the milestone item.
      ck "quiescence reported SIGNAL-BLOCKED, not a timeout",
        t["lastStatusName"].getStr() == "quiescence-signal-blocked"

      # The handshake still ran in full: the census renames a refusal, it does
      # not skip the rendezvous.
      ck "every slot was still signalled", t["signalledCount"].getInt() == 4
      ck "the three reachable threads still parked",
        t["parkedObservations"].getInt() == 3
      ck "every parked thread was still released",
        t["resumedObservations"].getInt() == 3

      # Bounded, exactly as the sibling timeout gate requires.
      let parkNs = t["parkNsMax"].getInt()
      ck "the wait was bounded above", parkNs < 400_000_000
      ck "the wait actually waited", parkNs >= 120_000_000

      # The census read something. Without this the whole check is vacuous.
      ck "the census read every unresponsive thread's mask",
        t["sigmaskReadOk"].getInt() == t["unresponsiveCount"].getInt()
      ck "no thread's mask was unreadable",
        t["sigmaskReadFailed"].getInt() == 0

      # And it identified the RIGHT thread, by tid, by name and by mask.
      ck "exactly one thread was reported as blocking the signal",
        t["blockedCount"].getInt() == 1
      ck "the fixture recorded which thread it made deaf",
        t["deafTid"].getInt() > 0
      ck "the blocked tid is the deaf thread",
        t["blockedTid"].getInt() == t["deafTid"].getInt()
      ck "the blocked thread is the one named in the unresponsive list",
        t["unresponsiveCount"].getInt() == 1 and
        t["unresponsiveTid"].getInt() == t["deafTid"].getInt()
      # A NAME, and one that is safe to put on the wire. `comm` is 15 bytes
      # chosen by whoever created the thread, and this string is pasted into a
      # JSON string field with no escaping — measured once as a coordinator
      # that died with `JsonParsingError: } expected` instead of reporting the
      # refusal it had been handed.
      ck "the census reported a thread NAME, not just a number",
        t["blockedName"].getStr().len > 0
      ck "the reported name carries nothing that would break the JSON it travels in",
        not t["blockedName"].getStr().contains({'"', '\\'})

      # The mask is not decoration: the quiescence signal's own bit must be set
      # in it. `signo` is read from the provider, so this cannot drift if
      # `SIGRTMIN` moves.
      let signo = t["quiesceSignal"].getInt()
      ck "the quiescence signal is a real-time signal", signo >= 32
      let mask = fromHex[uint64](t["blockedMask"].getStr())
      ck "the reported mask really does block the quiescence signal",
        (mask and (1'u64 shl (signo - 1))) != 0'u64

      # Nothing was written. Safety here is by construction: the refusal happens
      # during prepare, before a single byte of target text is touched.
      ck "no publication was attempted", t["publications"].getInt() == 0
      ck "the target window is byte-identical",
        t["windowBefore"].getStr() == t["windowAfter"].getStr()
      ck "the target window is still the untouched NOP sled",
        t["windowAfter"].getStr() == "0x9090909090909090"
      ck "no SYNC_CORE was issued, because nothing was published",
        t["membarrierIssuedCount"].getInt() == 0

      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "integration_hcr_linux_signal_blocked_thread_refused_by_name.json",
        pretty(%*{"signalBlocked": t}))

      expectCount(asserted, 25)

else:
  suite "integration_hcr_linux_signal_blocked_thread_refused_by_name":
    test "HLX-M4 signal-blocked quiescence gate is linux-x86_64-only":
      skip()
