## A deferred dev restart must cost O(1) log lines per unit time, not O(polls).
##
## WHY A WINDOW RATHER THAN A CHANGE-DETECTOR. The guard that stood here
## logged only when the active-session count changed. A developer machine
## still accumulated 949,394 `dev restart deferred` lines -- 93% of an 82 MB
## daemon log.
##
## The cause of THAT flood is not established, and two explanations for it
## were offered and withdrawn after being checked: it was not oscillation
## (one run of 948,900 identical consecutive lines, which a change-detector
## would have suppressed), and it was not competing daemon generations (zero
## daemon starts on three of the four flood days). See
## `deferralLogDue`'s docstring for what the evidence does and does not
## support.
##
## What a window is, therefore, is a strictly TIGHTER BOUND than change
## detection, and that is all these cases claim. It holds under oscillation
## and it holds when several writers share one log; a per-generation memory
## survives neither. It would not help against state that fails to persist,
## because it keeps its own state the same way.
##
## The property every case asserts is lines-per-unit-time, not
## lines-per-change.
##
## NOT ROTATION, deliberately. Rotation would have bounded the file and
## hidden the cause: that 82 MB is the symptom that made 19 session records
## stuck in `state=running` -- every one with a dead writer pid, permanently
## deferring the dev self-restart -- findable at all. The fix must shrink the
## log by saying less, not by discarding what it said.
##
## MOCK POLICY: no mocks, and none needed. `deferralLogDue` takes the clock
## as an argument, so the cases drive it with synthetic millisecond values.
## Those are inputs, not doubles -- there is no clock to fake and no
## filesystem in the subject.

import std/[strutils, unittest]

import repro_daemon_core

const Window = 60_000'i64
const PollMs = 250'i64

proc countLines(state: var DevRestartState; firstMs, spanMs: int64): int =
  ## Poll every 250 ms across `spanMs` and count the lines that would be
  ## emitted, maintaining the window state exactly as the daemon does.
  var now = firstMs
  while now < firstMs + spanMs:
    if state.deferralLogDue(now, Window):
      inc result
    now += PollMs

suite "the dev-restart deferral log is bounded by time, not by polls":
  test "entry into deferral always logs, whatever the clock reads":
    # The transition is the event worth seeing; a bounded log that could
    # swallow it would be worse than the flood.
    #
    # The clock value here is SMALL on purpose. With a large one, `now - 0`
    # already exceeds the window and the elapsed-window branch fires, so the
    # entry case is satisfied by accident and a mutation deleting it reddens
    # nothing -- which is exactly what a first version of this case did.
    # Below the window, only the entry case can answer.
    var fresh = DevRestartState()
    check 500'i64 - 0'i64 < Window
    check fresh.deferralLogDue(500'i64, Window)
    var later = DevRestartState()
    check later.deferralLogDue(1_000_000'i64, Window)

  test "a continuing deferral logs once per window, not once per poll":
    var state = DevRestartState()
    # One hour of deferral at a 250 ms poll: 14,400 polls.
    let polls = 3_600_000'i64 div PollMs
    let lines = countLines(state, 1_000_000'i64, 3_600_000'i64)
    checkpoint("polls=" & $polls & " lines=" & $lines)
    check polls == 14_400
    # One for entry plus one per elapsed window. The point is the ORDER of
    # magnitude: O(hours/window), not O(polls).
    check lines <= 61
    check lines >= 60

  test "the line count does not grow with the poll rate":
    # THE INVARIANT, stated as the thing a change-detector could not give.
    # Polling ten times as often must not log ten times as much.
    var slow = DevRestartState()
    var fast = DevRestartState()
    var now = 1_000_000'i64
    var slowLines = 0
    while now < 1_000_000'i64 + 600_000'i64:
      if slow.deferralLogDue(now, Window): inc slowLines
      now += 1_000'i64
    now = 1_000_000'i64
    var fastLines = 0
    while now < 1_000_000'i64 + 600_000'i64:
      if fast.deferralLogDue(now, Window): inc fastLines
      now += 25'i64
    checkpoint("1000ms poll -> " & $slowLines & " lines; 25ms poll -> " &
      $fastLines & " lines")
    check slowLines == fastLines

  test "oscillation cannot reopen the flood":
    # The failure mode the change-detector had. The window does not consult
    # the count at all, so a count that changes on every poll changes
    # nothing about how often it logs.
    var state = DevRestartState()
    let lines = countLines(state, 1_000_000'i64, 600_000'i64)
    checkpoint("10 minutes of deferral -> " & $lines & " lines")
    check lines <= 11

  test "resolution resets the window so the next deferral logs its entry":
    # A daemon that defers, clears, and defers again must show both entries.
    # Zeroing `deferredLogAtMs` is what the caller does on resolution.
    var state = DevRestartState()
    check state.deferralLogDue(1_000_000'i64, Window)
    check not state.deferralLogDue(1_000_100'i64, Window)
    state.deferredLogAtMs = 0
    check state.deferralLogDue(1_000_200'i64, Window)

  test "suppressed polls are countable, so the log can state them":
    # The suppression must be visible in the log rather than inferred from
    # absence, which is the difference between a quiet log and a lying one.
    var state = DevRestartState()
    discard state.deferralLogDue(1_000_000'i64, Window)
    var now = 1_000_000'i64 + PollMs
    while now < 1_000_000'i64 + Window:
      if not state.deferralLogDue(now, Window):
        inc state.deferralPollsSuppressed
      now += PollMs
    checkpoint("suppressed=" & $state.deferralPollsSuppressed)
    check state.deferralPollsSuppressed == 239
    check state.deferralLogDue(1_000_000'i64 + Window, Window)

  test "a shorter window is honoured, so the cadence is configurable":
    var state = DevRestartState()
    let lines = block:
      var n = 0
      var now = 1_000_000'i64
      while now < 1_000_000'i64 + 10_000'i64:
        if state.deferralLogDue(now, 1_000'i64): inc n
        now += PollMs
      n
    checkpoint("10 s at a 1 s window -> " & $lines & " lines")
    check lines == 10
