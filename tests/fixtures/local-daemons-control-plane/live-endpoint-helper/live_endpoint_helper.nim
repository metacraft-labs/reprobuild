## ``live-endpoint-helper`` — accept-and-close server for the
## stale-discovery-repair tests (M2 / M11).
##
## The tests in ``tests/integration/t_local_daemons_control_plane_m{2,11}.nim``
## need a process that BINDS the daemon endpoint without speaking the
## actual `repro-daemon` protocol — that way they can validate that
## the daemon's stale-discovery logic distinguishes "the endpoint is
## a stale, never-bound file" from "the endpoint is held by something
## else live." Previously this was a Python script that called
## ``socket.socket(socket.AF_UNIX, ...)``; that form is POSIX-only.
##
## With the M0 Named-Pipe port, ``repro_daemon_core/ipc`` already
## exposes a portable bind/accept surface — using it here means the
## helper compiles on Windows + Linux + macOS with no
## ``when defined(...)`` carve-outs in the test code itself.

import std/[os, strutils, times]

import repro_daemon_core

const MaxAcceptedConnections = 8
const DeadlineSeconds = 15.0
const PollIntervalMs = 200

proc usage(): string =
  "usage: live-endpoint-helper <endpoint>\n" &
    "Binds <endpoint> (an AF_UNIX path on POSIX or a `\\.\\pipe\\`\n" &
    "name on Windows), accepts and immediately closes up to " &
    $MaxAcceptedConnections & " clients (or stops at the " &
    $DeadlineSeconds.int & "s deadline), then exits 0."

proc main(): int =
  if paramCount() < 1:
    stderr.writeLine(usage())
    return 2
  let endpoint = paramStr(1)

  # Remove a stale file at the endpoint path so bind succeeds. The
  # IPC abstraction's POSIX path also unlinks but is permissive about
  # missing files; calling it here mirrors the prior Python helper's
  # try/except pattern.
  try: removeFile(endpoint) except OSError: discard

  var listener = bindIpcListener(endpoint)
  defer: closeIpcListener(listener)

  let deadline = epochTime() + DeadlineSeconds
  var accepted = 0
  while epochTime() < deadline and accepted < MaxAcceptedConnections:
    let pollMs = max(1, min(PollIntervalMs,
      int((deadline - epochTime()) * 1000.0)))
    if not listener.waitForClient(pollMs):
      continue
    var client = listener.acceptIpc()
    accepted.inc
    client.closeIpcConn()

  0

quit(main())
