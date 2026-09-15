## ``fake-protocol-daemon-helper`` — bind the daemon endpoint and
## reply with a hard-coded protocol-mismatch frame so the M11
## regression can exercise the "live but incompatible" branch of
## the daemon discovery code.
##
## The previous shape was a Python script using
## ``socket.socket(socket.AF_UNIX, ...)`` plus a hand-rolled
## ``RBUD`` frame. That form was POSIX-only; on Windows the test
## file failed to even compile.
##
## With the M0 Named-Pipe port we can write the same thing in Nim
## using ``repro_daemon_core/ipc`` (portable) and the framing
## protocol exposed by ``repro_daemon_core/protocol`` — that way
## the frame is constructed by the same code the production daemon
## uses, so we can't drift if the protocol layout changes later.

import std/[os, strutils, times]

import repro_daemon_core

## LIFETIME IS THE CALLER'S TO STATE, NOT A CONSTANT IN HERE.
## The deadline and the connection budget used to be fixed at 20 and 20 s,
## which is shorter than a single cold ``repro build`` in the case that drives
## this fixture (``t_local_daemons_control_plane_m11``, measured at 1295 s for
## one case). The helper was therefore dead by minutes before the later arms
## ran, and the "live but protocol-incompatible daemon" branch those arms exist
## to cover was not under test at all: with the endpoint gone, ``repro`` simply
## auto-started a REAL daemon and the ``--daemon=require`` gate it was supposed
## to trip never fired. Both bounds are now optional arguments so the test that
## owns the fixture says how long it needs it, and the defaults are unchanged
## for any caller that does not care.
const DefaultMaxAcceptedConnections = 20
const DefaultDeadlineSeconds = 20.0
const PollIntervalMs = 200
const MismatchMessage =
  "user daemon protocol mismatch: fake daemon major 99"

proc usage(): string =
  "usage: fake-protocol-daemon-helper <endpoint> " &
    "[deadline-seconds] [max-connections]\n" &
    "Binds <endpoint>, accepts each client, sends a single\n" &
    "`udkError` frame carrying the canonical mismatch message,\n" &
    "and closes. Exits after max-connections clients (default " &
    $DefaultMaxAcceptedConnections & ") or the deadline (default " &
    $DefaultDeadlineSeconds.int & "s)."

proc main(): int =
  if paramCount() < 1 or paramCount() > 3:
    stderr.writeLine(usage())
    return 2
  let endpoint = paramStr(1)
  var deadlineSeconds = DefaultDeadlineSeconds
  var maxAcceptedConnections = DefaultMaxAcceptedConnections
  try:
    if paramCount() >= 2:
      deadlineSeconds = parseFloat(paramStr(2))
    if paramCount() >= 3:
      maxAcceptedConnections = parseInt(paramStr(3))
  except ValueError:
    stderr.writeLine(usage())
    return 2
  if deadlineSeconds <= 0.0 or maxAcceptedConnections <= 0:
    stderr.writeLine(usage())
    return 2
  try: removeFile(endpoint) except OSError: discard

  var listener = bindIpcListener(endpoint)
  defer: closeIpcListener(listener)

  let deadline = epochTime() + deadlineSeconds
  var accepted = 0
  let body = errorBody(MismatchMessage)
  while epochTime() < deadline and accepted < maxAcceptedConnections:
    let pollMs = max(1, min(PollIntervalMs,
      int((deadline - epochTime()) * 1000.0)))
    if not listener.waitForClient(pollMs):
      continue
    var client = listener.acceptIpc()
    accepted.inc
    try:
      client.writeFrame(udkError, body)
    except CatchableError:
      discard
    client.closeIpcConn()

  0

quit(main())
