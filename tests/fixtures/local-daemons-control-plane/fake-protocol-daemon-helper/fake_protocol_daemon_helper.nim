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

const MaxAcceptedConnections = 20
const DeadlineSeconds = 20.0
const PollIntervalMs = 200
const MismatchMessage =
  "user daemon protocol mismatch: fake daemon major 99"

proc usage(): string =
  "usage: fake-protocol-daemon-helper <endpoint>\n" &
    "Binds <endpoint>, accepts each client, sends a single\n" &
    "`udkError` frame carrying the canonical mismatch message,\n" &
    "and closes. Exits after " & $MaxAcceptedConnections &
    " clients or the " & $DeadlineSeconds.int & "s deadline."

proc main(): int =
  if paramCount() < 1:
    stderr.writeLine(usage())
    return 2
  let endpoint = paramStr(1)
  try: removeFile(endpoint) except OSError: discard

  var listener = bindIpcListener(endpoint)
  defer: closeIpcListener(listener)

  let deadline = epochTime() + DeadlineSeconds
  var accepted = 0
  let body = errorBody(MismatchMessage)
  while epochTime() < deadline and accepted < MaxAcceptedConnections:
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
