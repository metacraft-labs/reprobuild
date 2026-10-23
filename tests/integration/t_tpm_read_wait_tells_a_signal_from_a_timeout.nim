## A signal delivered while a TPM read is waiting is not a TPM problem.
##
## ## The claim
##
## `readExactly` waits for the endpoint to answer with a bound on it,
## and the refusal it raises when the bound elapses makes a substantive
## claim: that the endpoint is connected and nothing is servicing it,
## because a software TPM's data channel admits one client at a time.
## That sentence is useful precisely because it is specific — whoever
## reads it goes looking for the other conversation.
##
## So it must only be said when it is true. The wait has three outcomes
## and the system call reports them in two values: readable, the bound
## elapsed, or **the wait itself failed** — and `EINTR`, which is what a
## wait answers when any signal at all is delivered to the process, is
## the third. A profiler, an interval timer, a reaped child: none of
## them is evidence about a TPM, and none of them should produce that
## sentence.
##
## The three cases below are the three outcomes:
##
## 1. **A signal does not become a timeout.** Signals arrive while a
##    transaction is waiting, the answer arrives after them, and the
##    transaction completes with the answer. Nothing claims contention.
## 2. **The bound still holds although signals keep arriving.** A wait
##    that resumed on a FRESH bound after every signal would never
##    reach its deadline, which is the unbounded wait the bound exists
##    to prevent. So the resumed wait is checked against the clock: it
##    times out at roughly the bound it was given, however many times
##    it was interrupted.
## 3. **A failed wait says so.** An error that is not `EINTR` raises a
##    message that names the errno and claims nothing about whether the
##    endpoint is being serviced.
##
## ## How the signals get there
##
## A real interval timer (`setitimer(ITIMER_REAL)`) and a real
## `SIGALRM` handler, firing every few tens of milliseconds while the
## wait is blocked. `select(2)` is never restarted after a handler runs
## — regardless of `SA_RESTART`, see signal(7) "Interruption of system
## calls and library functions by signal handlers" — so every one of
## those deliveries really does interrupt the wait:
## https://man7.org/linux/man-pages/man7/signal.7.html
##
## In case 1 the handler is also what delivers the answer, which keeps
## the whole exercise in one thread: two interruptions, then a ten-byte
## TPM response written into the far end of the socket from inside the
## handler, then the timer disarmed so no further signal can land in
## the middle of the `recv` that follows.
##
## ## Mocking
##
## No TPM, and the file says so rather than implying one. The subject is
## the bounded WAIT in the transport, which is below every TPM command
## and knows nothing about them, so a TPM would add a process and a
## minute to the run and not one byte of evidence about this behaviour.
## Everything the wait touches is real: a real Unix stream socket pair
## through the module's own `unix:` constructor, real signals, and a
## real — if minimal — well-formed TPM response, a ten-byte
## `TPM_ST_NO_SESSIONS` header with `TPM_RC_SUCCESS` and no parameters,
## which is the shortest thing a TPM can legitimately answer. What a
## TPM would add is the CONTENT of a response, and no case here reads
## one: live command transactions against a software TPM are covered by
## `t_tpm_quote_comes_from_the_tpm`.

import std/[monotimes, net, os, posix, strutils, times, unittest]

import repro_attest

# `setitimer` and `struct itimerval` are not in `std/posix`, so they are
# taken from the header rather than written as numbers — the struct's
# layout and `ITIMER_REAL`'s value are the platform's to state.
type
  Itimerval {.importc: "struct itimerval", header: "<sys/time.h>",
              pure, final.} = object
    it_interval {.importc: "it_interval".}: Timeval
    it_value {.importc: "it_value".}: Timeval

proc setitimer(which: cint; value, ovalue: ptr Itimerval): cint
  {.importc: "setitimer", header: "<sys/time.h>".}

var ITIMER_REAL_C {.importc: "ITIMER_REAL", header: "<sys/time.h>".}: cint

const
  MinimalTpmResponse = "\x80\x01\x00\x00\x00\x0A\x00\x00\x00\x00"
    ## `tag = TPM_ST_NO_SESSIONS`, `responseSize = 10`,
    ## `responseCode = TPM_RC_SUCCESS`: a response that is complete at
    ## its header, which is what makes it writable from a signal
    ## handler in one `write`.

  DummyCommand = "\x80\x01\x00\x00\x00\x0A\x00\x00\x01\x44"
    ## A `TPM2_Startup` header with no parameters. Never executed by
    ## anything: the far end of this socket is the test, which answers
    ## without reading, so the command's only job is to be the bytes a
    ## transaction sends before it waits.

  ContentionClaim = "one client at a time"
    ## The load-bearing fragment of the genuine-timeout refusal. A case
    ## that only checked "it raised" would pass on the defect this file
    ## is about, because the defect IS a raise — of this sentence, for a
    ## reason that does not support it.

# Written to and read by a signal handler, so both are plain C scalars
# and the handler does nothing an interrupted `malloc` could deadlock
# on: it counts, it writes bytes it did not allocate, and it disarms a
# timer.
var alarmCount: cint = 0
var answerFd: cint = -1
var answerAfterAlarms: cint = 0
var answerBytes: array[MinimalTpmResponse.len, char]

proc onAlarm(sig: cint) {.noconv.} =
  alarmCount.inc
  if answerAfterAlarms > 0 and alarmCount == answerAfterAlarms and
     answerFd >= 0:
    discard posix.write(answerFd, addr answerBytes[0], answerBytes.len)
    # Disarmed from inside the handler, so the `recv` that follows
    # cannot be interrupted too. An interrupted `recv` is a different
    # question from the one this file asks, and leaving it reachable
    # would make the case fail now and then for the wrong reason.
    var off = Itimerval()
    discard setitimer(ITIMER_REAL_C, addr off, nil)

proc startAlarms(everyMs: int) =
  ## Deliver `SIGALRM` every `everyMs` until `stopAlarms`.
  alarmCount = 0
  posix.signal(SIGALRM, onAlarm)
  var every = Itimerval()
  every.it_value.tv_sec = posix.Time(0)
  every.it_value.tv_usec = Suseconds(everyMs * 1000)
  every.it_interval = every.it_value
  doAssert setitimer(ITIMER_REAL_C, addr every, nil) == 0,
    "the interval timer would not start, so nothing below would be " &
    "interrupted and the cases would prove nothing: " & $strerror(errno)

proc stopAlarms() =
  var off = Itimerval()
  discard setitimer(ITIMER_REAL_C, addr off, nil)
  posix.signal(SIGALRM, SIG_DFL)

proc elapsedMs(since: MonoTime): int64 =
  (getMonoTime() - since).inMilliseconds

type
  SocketPair = object
    ## A transport, and the far end of its connection held in this
    ## process so the test can answer — or decline to answer — by hand.
    dir: string
    transport: Tpm2Transport
    listener: Socket
    peer: Socket

proc closePair(p: var SocketPair) =
  if p.transport != nil:
    try: p.transport.transportClose()
    except CatchableError: discard
    p.transport = nil
  if p.peer != nil:
    try: p.peer.close()
    except CatchableError: discard
    p.peer = nil
  if p.listener != nil:
    try: p.listener.close()
    except CatchableError: discard
    p.listener = nil
  if p.dir.len > 0:
    try: removeDir(p.dir)
    except CatchableError: discard
    p.dir = ""

proc connectedPair(): SocketPair =
  ## One `unix:` transport built by the module under test, connected to
  ## a socket this process holds.
  ##
  ## Built through `newTpm2Transport` rather than by hand so the
  ## transport is configured exactly as a daemon's would be — the same
  ## unbuffered socket and the same read bound.
  result.dir = getTempDir() / ("repro-tpm-wait-" & $getCurrentProcessId() &
                               "-" & $getMonoTime().ticks)
  removeDir(result.dir)
  createDir(result.dir)
  let path = result.dir / "tpm-data.sock"
  result.listener = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                              Protocol.IPPROTO_IP, buffered = false)
  result.listener.bindUnix(path)
  result.listener.listen()
  result.transport = newTpm2Transport("unix:" & path)
  result.peer = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                          Protocol.IPPROTO_IP, buffered = false)
  result.listener.accept(result.peer)

suite "a TPM read tells a signal from a timeout":

  test "signals during a transaction do not become a contention claim":
    var p = connectedPair()
    try:
      for i in 0 ..< answerBytes.len:
        answerBytes[i] = MinimalTpmResponse[i]
      answerFd = cint(p.peer.getFd())
      # After the second interruption, so the wait is known to have
      # resumed at least once before the answer it returns.
      answerAfterAlarms = 2

      let started = getMonoTime()
      startAlarms(40)
      var answer = ""
      var refusal = ""
      try:
        answer = p.transport.transportTransact(DummyCommand)
      except Tpm2TransportError as err:
        refusal = err.msg
      stopAlarms()
      let took = elapsedMs(started)

      # The premise first: without deliveries there is nothing to
      # resume across and a pass would mean nothing.
      check alarmCount >= answerAfterAlarms

      check refusal == ""
      # Named explicitly as well, because this is the sentence the
      # defect produced: a signal reported as socket contention.
      check ContentionClaim notin refusal
      check answer == MinimalTpmResponse

      # It neither failed fast nor hung: the answer arrived after the
      # interruptions, and well inside the transport's own bound.
      check took >= 40
      check took < 10_000
    finally:
      stopAlarms()
      answerFd = -1
      answerAfterAlarms = 0
      closePair(p)

  test "an interrupted wait still times out at its own bound":
    # Nothing ever answers here, and the signals keep coming. A wait
    # that restarted on a fresh bound after each one would outlive the
    # deadline by a factor of however many signals arrived; this one
    # spends what is left of the bound and no more.
    var p = connectedPair()
    try:
      answerAfterAlarms = 0
      let bound = 400
      let started = getMonoTime()
      startAlarms(25)
      let outcome = waitForReadable(p.peer.getFd(), bound,
                                    "unix:a-socket-nobody-answers")
      stopAlarms()
      let took = elapsedMs(started)

      check alarmCount >= 4
      check outcome == twTimedOut
      # Not `>= bound` exactly: each resume asks for the remaining time
      # in whole milliseconds, so a wait interrupted a dozen times can
      # come back a few milliseconds early. The claim is that it spent
      # its bound rather than returning on the first signal, and a
      # tolerance of a few tens of milliseconds says that without
      # depending on the interval chosen above.
      check took >= bound - 50
      # Generous against a loaded host and still far below `bound`
      # times the number of interruptions, which is what a fresh bound
      # per resume would have cost.
      check took < bound * 3
    finally:
      stopAlarms()
      closePair(p)

  test "a wait that fails names the errno and claims nothing else":
    # A descriptor that was closed: the wait fails immediately with
    # `EBADF`, which is an error and not a bound that elapsed.
    let doomed = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                           Protocol.IPPROTO_IP, buffered = false)
    let fd = doomed.getFd()
    doomed.close()

    var refusal = ""
    try:
      discard waitForReadable(fd, 1_000, "unix:a-closed-descriptor")
    except Tpm2TransportError as err:
      refusal = err.msg
    check refusal.len > 0
    check "unix:a-closed-descriptor" in refusal
    check ("errno " & $int(EBADF)) in refusal
    # The whole point: a failed wait does not borrow the timeout's
    # claim about what is holding the endpoint.
    check ContentionClaim notin refusal
