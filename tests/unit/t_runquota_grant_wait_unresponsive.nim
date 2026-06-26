## Regression: the queued-grant wait must measure daemon SILENCE, never
## queue time, and must never silently hang.
##
## Root cause (original discovered-issue fix): ``waitForQueuedGrant`` had
## an UNBOUNDED, SILENT inner poll loop:
##
## ```
## block awaitGrant:
##   while true:
##     for decision in session.pollNextGrant(): ...
##     sleep(25)        # polls forever for a grant — no timeout, no output
## ```
##
## When RunQuota was wedged or mid-restart and a queued candidate's grant
## never arrived, the engine froze forever with zero output (observed: a
## full ``just test`` frozen ~2.5h). That violates
## Build-Engine-And-Scheduler.md "RunQuota Discovery" (an unresponsive
## RunQuota MUST fail with a diagnostic, not hang) and
## Interactive-UX-And-Progress.md Principle 1 ("a silent multi-second hang
## is a defect") and Principle 2 ("every failure teaches the remedy").
##
## REJECTED FIRST FIX + WHY IT WAS WRONG (this file is the regression guard
## the review demanded): the first fix added a deadline that accrued on
## every poll that returned no *decision*, resetting only on a grant/deny.
## But the REAL daemon (``runquota_daemon`` ``rqGrantNext`` handler) answers
## every GrantNext poll for a legitimately-queued candidate with an EMPTY
## decision batch — it sends no intermediate "queued"/"denied" decision. So
## under the rejected design every tick of a legitimately-queued candidate
## looked like silence, the clock never reset, and the deadline became a
## HARD CAP on legitimate queue time — spuriously failing any action queued
## behind a >deadline predecessor (realistic for the pinned llvm/mold/wild
## LTO builds). The rejected tests passed only because they modeled denials
## the real daemon never sends during queueing.
##
## CORRECT MODEL (what these tests pin): the deadline measures TRANSPORT
## SILENCE. ANY proof the daemon is alive resets the clock:
##   * ``gpoAliveQueued`` — a received GrantNext frame (an EMPTY batch while
##     queued IS liveness) → reset clock, keep waiting indefinitely.
##   * ``gpoGranted`` / ``gpoDenied`` — end the wait.
##   * ``gpoNoFrame`` — the bounded read saw nothing; the loop runs a
##     liveness probe. ``livAlive`` → reset clock; ``livSilent`` → accrue
##     toward the deadline. Only an unbroken run of ``livSilent`` past
##     ``unresponsiveMs`` raises.
##
## Falsifiability: each "unresponsive" test drives the loop with a stub
## whose poll never frames and whose liveness probe is silent; a real-time
## guard proves the loop is bounded (the OLD loop never returned). The
## "responsive-but-queued-past-deadline" test is the new regression guard:
## it holds the daemon alive (empty-batch frames) for FAR longer than
## ``unresponsiveMs`` of fake wall-clock and asserts the wait does NOT
## raise. It FAILS under the rejected design (which treated empty batches
## as silence) and PASSES under this one.

import std/[os, strutils, times, unittest]

import repro_runquota

proc grantedLease(): RunQuotaLease =
  # A minimally-populated active lease standing in for a real grant.
  RunQuotaLease(active: true)

suite "repro_runquota grant-wait — liveness vs silence":

  test "responsive-but-queued PAST the deadline does NOT raise (regression)":
    # THE regression the review demanded. The daemon answers every
    # GrantNext poll promptly with an EMPTY decision batch (``gpoAliveQueued``
    # — exactly what the real daemon does for a legitimately-queued
    # candidate). The fake wall-clock is advanced WELL past the
    # unresponsive deadline on every tick, yet because each received frame
    # is liveness the clock resets and the wait keeps going. It finally
    # grants. This MUST NOT raise.
    #
    # Under the REJECTED design (empty batch == accrues toward deadline)
    # this would raise on roughly the third tick.
    var fakeNow = 0
    var ticks = 0
    let unresponsiveMs = 10_000
    var heartbeats = 0
    let res = awaitGrantLoop(
      candidateId = 1'u64, label = "queued-behind-LTO", statsId = "stats-q",
      poll = proc(): GrantPollResult =
        inc ticks
        # 200 polls of "alive but still queued" — 200 * 60_000ms of fake
        # wall-clock = 200 minutes, 20x the 10s deadline — then a grant.
        if ticks < 200: GrantPollResult(outcome: gpoAliveQueued)
        else: GrantPollResult(outcome: gpoGranted, lease: grantedLease()),
      liveness = proc(): LivenessOutcome =
        # Never consulted here (every poll yields a frame), but if it were
        # it would report the daemon alive.
        livAlive,
      heartbeatMs = 5_000,
      unresponsiveMs = unresponsiveMs,
      nowMs = proc(): int = fakeNow,
      # Each tick jumps the clock 60s — 6x the whole deadline — so if
      # ``gpoAliveQueued`` did NOT reset the clock the deadline would trip
      # almost immediately.
      napMs = proc(ms: int) = fakeNow += 60_000,
      heartbeat = proc(label, statsId: string; waitedMs: int) =
        inc heartbeats)
    check res.granted
    check res.lease.active
    check ticks == 200          # it really did wait through the long queue.
    check heartbeats >= 1       # and was never silent while waiting.

  test "no-frame windows but liveness probe alive: also does NOT raise":
    # Variant of the regression: the bounded grant read returns NO frame
    # (``gpoNoFrame``), but the ``daemonStatus`` liveness probe succeeds
    # (``livAlive``) every time. The daemon is alive, just quiet — the
    # clock must reset on each successful probe and the wait must continue
    # past the deadline, then grant.
    var fakeNow = 0
    var ticks = 0
    var probes = 0
    let unresponsiveMs = 10_000
    let res = awaitGrantLoop(
      candidateId = 1'u64, label = "alive-but-quiet", statsId = "stats-quiet",
      poll = proc(): GrantPollResult =
        inc ticks
        if ticks < 150: GrantPollResult(outcome: gpoNoFrame)
        else: GrantPollResult(outcome: gpoGranted, lease: grantedLease()),
      liveness = proc(): LivenessOutcome =
        inc probes
        livAlive,
      heartbeatMs = 5_000,
      unresponsiveMs = unresponsiveMs,
      nowMs = proc(): int = fakeNow,
      napMs = proc(ms: int) = fakeNow += 60_000,
      heartbeat = proc(label, statsId: string; waitedMs: int) = discard)
    check res.granted
    check probes >= 100         # the liveness probe carried the wait.

  test "truly unresponsive daemon (no frames, probe silent) raises within bound":
    # The wedged / mid-restart shape that used to hang forever: the bounded
    # grant read never frames AND the liveness probe never answers. This
    # MUST raise an actionable error within the bounded deadline.
    var fakeNow = 0
    let unresponsiveMs = 30_000
    let realStart = epochTime()
    var polls = 0
    var raised = false
    try:
      discard awaitGrantLoop(
        candidateId = 1'u64, label = "wedged-action", statsId = "stats-1",
        poll = proc(): GrantPollResult =
          inc polls
          GrantPollResult(outcome: gpoNoFrame),
        liveness = proc(): LivenessOutcome = livSilent,
        heartbeatMs = 5_000,
        unresponsiveMs = unresponsiveMs,
        nowMs = proc(): int = fakeNow,
        # napMs advances the fake clock instead of really sleeping, so the
        # deadline is reached in a handful of iterations.
        napMs = proc(ms: int) = fakeNow += 1_000,
        heartbeat = proc(label, statsId: string; waitedMs: int) = discard)
    except ReproRunQuotaError as err:
      raised = true
      # Principle 2: the diagnostic must name the remedy.
      check "runquota=off" in err.msg
      check "restart" in err.msg
      check "wedged" in err.msg
    let elapsed = epochTime() - realStart
    check raised
    # Bounded: the fake clock crosses the deadline in ~30 ticks. If the
    # loop were unbounded (the OLD behaviour) this would never return and
    # the guard below would never be reached.
    check polls >= 2
    check elapsed < 5.0  # real-time guard: the loop terminated promptly.

  test "intermittently-silent-but-eventually-alive does not raise prematurely":
    # The daemon is silent for a stretch shorter than the deadline, then
    # proves alive again (probe succeeds), resetting the clock; it repeats
    # this and finally grants. The deadline must never trip because no
    # single run of silence reaches ``unresponsiveMs``.
    var fakeNow = 0
    var ticks = 0
    let unresponsiveMs = 10_000
    let res = awaitGrantLoop(
      candidateId = 1'u64, label = "flaky-but-alive", statsId = "stats-flaky",
      poll = proc(): GrantPollResult =
        inc ticks
        if ticks >= 40: GrantPollResult(outcome: gpoGranted, lease: grantedLease())
        else: GrantPollResult(outcome: gpoNoFrame),
      liveness = proc(): LivenessOutcome =
        # Silent for 3 ticks then alive, repeating: each silent run is
        # 3 * 2_000ms = 6_000ms < 10_000ms deadline, so it never trips.
        if ticks mod 4 == 0: livAlive else: livSilent,
      heartbeatMs = 5_000,
      unresponsiveMs = unresponsiveMs,
      nowMs = proc(): int = fakeNow,
      napMs = proc(ms: int) = fakeNow += 2_000,
      heartbeat = proc(label, statsId: string; waitedMs: int) = discard)
    check res.granted

  test "dead connection (poll raises) propagates immediately":
    # A closed/dead connection surfaces as ``pollNextGrantBounded`` raising;
    # the loop must propagate it rather than swallow-and-spin.
    var fakeNow = 0
    expect ReproRunQuotaError:
      discard awaitGrantLoop(
        candidateId = 1'u64, label = "dead-conn", statsId = "stats-2",
        poll = proc(): GrantPollResult =
          raise newException(ReproRunQuotaError,
            "daemon closed the RQSP connection"),
        liveness = proc(): LivenessOutcome = livSilent,
        heartbeatMs = 5_000,
        unresponsiveMs = 600_000,
        nowMs = proc(): int = fakeNow,
        napMs = proc(ms: int) = fakeNow += 1_000,
        heartbeat = proc(label, statsId: string; waitedMs: int) = discard)

  test "dead connection surfaced by the liveness probe raising propagates":
    # If the grant read returns no frame and the liveness probe itself
    # raises (a genuinely closed connection), that propagates immediately —
    # we do not wait out the deadline on a connection we know is dead.
    var fakeNow = 0
    expect ReproRunQuotaError:
      discard awaitGrantLoop(
        candidateId = 1'u64, label = "dead-probe", statsId = "stats-2b",
        poll = proc(): GrantPollResult =
          GrantPollResult(outcome: gpoNoFrame),
        liveness = proc(): LivenessOutcome =
          raise newException(ReproRunQuotaError,
            "daemon closed the RQSP connection"),
        heartbeatMs = 5_000,
        unresponsiveMs = 600_000,
        nowMs = proc(): int = fakeNow,
        napMs = proc(ms: int) = fakeNow += 1_000,
        heartbeat = proc(label, statsId: string; waitedMs: int) = discard)

  test "queued then granted succeeds (no regression on the happy path)":
    # The daemon reports "still queued" (empty batch -> gpoAliveQueued) a
    # few times, then grants. Succeeds, and the heartbeat fires while
    # waiting so the wait was never silent.
    var fakeNow = 0
    var ticks = 0
    var heartbeats = 0
    let res = awaitGrantLoop(
      candidateId = 1'u64, label = "queued-action", statsId = "stats-3",
      poll = proc(): GrantPollResult =
        inc ticks
        if ticks < 8: GrantPollResult(outcome: gpoAliveQueued)
        else: GrantPollResult(outcome: gpoGranted, lease: grantedLease()),
      liveness = proc(): LivenessOutcome = livAlive,
      heartbeatMs = 2_000,
      unresponsiveMs = 30_000,
      nowMs = proc(): int = fakeNow,
      napMs = proc(ms: int) = fakeNow += 1_000,
      heartbeat = proc(label, statsId: string; waitedMs: int) =
        inc heartbeats)
    check res.granted
    check res.lease.active
    check ticks == 8
    check heartbeats >= 1

  test "denial ends the wait so the caller can re-offer (denied != broken)":
    # A denial is a terminal decision for this awaitGrantLoop call; the
    # caller re-offers with backoff. The deadline must NOT fire on a
    # denial even if the clock has jumped, because a denial is liveness.
    var fakeNow = 0
    let res = awaitGrantLoop(
      candidateId = 1'u64, label = "denied-action", statsId = "stats-4",
      poll = proc(): GrantPollResult =
        GrantPollResult(outcome: gpoDenied, diagnostic: "shared CPU budget"),
      liveness = proc(): LivenessOutcome = livAlive,
      heartbeatMs = 2_000,
      unresponsiveMs = 10_000,
      nowMs = proc(): int = fakeNow,
      napMs = proc(ms: int) = fakeNow += 5_000,
      heartbeat = proc(label, statsId: string; waitedMs: int) = discard)
    check not res.granted
    check res.denialMessage == "shared CPU budget"

suite "repro_runquota grant-wait — config defaults and env overrides":

  test "defaults are generous and heartbeat is enabled":
    putEnv("REPRO_RUNQUOTA_GRANT_TIMEOUT", "")
    putEnv("REPRO_RUNQUOTA_GRANT_HEARTBEAT", "")
    putEnv("REPRO_RUNQUOTA_GRANT_READ_TIMEOUT", "")
    # 10-minute default deadline, 5-second default heartbeat, ~1.5s read.
    check grantUnresponsiveMs() == 600_000
    check grantHeartbeatMs() == 5_000
    check grantBoundedReadMs() == 1_500

  test "env overrides are honoured":
    putEnv("REPRO_RUNQUOTA_GRANT_TIMEOUT", "1234")
    putEnv("REPRO_RUNQUOTA_GRANT_HEARTBEAT", "77")
    putEnv("REPRO_RUNQUOTA_GRANT_READ_TIMEOUT", "333")
    check grantUnresponsiveMs() == 1234
    check grantHeartbeatMs() == 77
    check grantBoundedReadMs() == 333
    putEnv("REPRO_RUNQUOTA_GRANT_TIMEOUT", "")
    putEnv("REPRO_RUNQUOTA_GRANT_HEARTBEAT", "")
    putEnv("REPRO_RUNQUOTA_GRANT_READ_TIMEOUT", "")

  test "malformed / non-positive env values fall back to defaults":
    putEnv("REPRO_RUNQUOTA_GRANT_TIMEOUT", "not-a-number")
    putEnv("REPRO_RUNQUOTA_GRANT_HEARTBEAT", "0")
    putEnv("REPRO_RUNQUOTA_GRANT_READ_TIMEOUT", "-9")
    check grantUnresponsiveMs() == 600_000
    check grantHeartbeatMs() == 5_000
    check grantBoundedReadMs() == 1_500
    putEnv("REPRO_RUNQUOTA_GRANT_TIMEOUT", "")
    putEnv("REPRO_RUNQUOTA_GRANT_HEARTBEAT", "")
    putEnv("REPRO_RUNQUOTA_GRANT_READ_TIMEOUT", "")
