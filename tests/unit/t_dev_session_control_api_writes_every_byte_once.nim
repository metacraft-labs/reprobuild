## The dev-session control API writes each answer completely, exactly once,
## and gives up on a client that has gone away.
##
## `writeFully` (libs/repro_cli_support/src/repro_cli_support/
## dev_session_access.nim) replaces `std/net`'s `send(socket, string)` for
## every control-API answer, because the pinned Nim's version of that loop
## resends from byte 0 after a short write and spins forever on a reset
## peer. The spin is covered end to end, against the real listener, by
## tests/e2e/dev-env/t_dev_session_control_api_refuses_unauthenticated_and_cross_origin_requests.nim
## ("a client that resets the connection before its answer cannot wedge
## the listener").
##
## Why a scripted writer instead of a real socket: a blocking stream socket
## returns a short count only when a signal interrupts a write that has
## already transferred data, and an interrupted write that transferred
## nothing returns EINTR. Neither can be provoked on demand through a real
## socket, so a test of those two paths through one would pass without
## exercising them. The writer below performs each of those outcomes
## exactly as `send(socket, pointer, size)` reports them: a byte count, or
## -1 with the OS error set.

import std/unittest

import repro_cli_support/dev_session_access

when defined(posix):
  import std/posix

type Script = ref object
  received: string
  calls: int
  chunk: int        ## at most this many bytes accepted per call
  interruptAt: int  ## the call that fails with EINTR, accepting nothing
  failAt: int       ## the call that fails with a hard error
  failWith: cint

proc writer(s: Script): ControlWriter =
  result = proc (data: pointer; size: int): int =
    inc s.calls
    when defined(posix):
      if s.calls == s.interruptAt:
        errno = EINTR
        return -1
      if s.calls == s.failAt:
        errno = s.failWith
        return -1
    let n = min(size, s.chunk)
    if n > 0:
      let start = s.received.len
      s.received.setLen(start + n)
      copyMem(addr s.received[start], data, n)
    n

proc answer(len: int): string =
  ## Distinct bytes at every offset, so a resend from the wrong offset
  ## shows up as a mismatch rather than as a coincidental match.
  result = newString(len)
  for i in 0 ..< len:
    result[i] = char(ord('a') + (i * 7 + i div 26) mod 26)

suite "dev-session control API: each answer is written whole, once":
  test "a short write resumes at the first byte not yet accepted":
    let data = answer(1000)
    let s = Script(chunk: 7)
    writeFully(writer(s), data)
    check s.received == data
    check s.calls == (1000 + 6) div 7

  test "an empty answer writes nothing":
    let s = Script(chunk: 7)
    writeFully(writer(s), "")
    check s.calls == 0
    check s.received == ""

  when defined(posix):
    test "an interrupted write is retried and loses no bytes":
      let data = answer(100)
      let s = Script(chunk: 30, interruptAt: 2)
      writeFully(writer(s), data)
      check s.received == data

    test "a peer that reset its connection ends the exchange":
      for code in [ECONNRESET, EPIPE]:
        let s = Script(chunk: 10, failAt: 3, failWith: code)
        expect OSError:
          writeFully(writer(s), answer(100))
        check s.calls == 3
        check s.received == answer(100)[0 ..< 20]

  test "a connection that accepts nothing is treated as closed":
    let s = Script(chunk: 0)
    expect OSError:
      writeFully(writer(s), "x")
    check s.calls == 1
