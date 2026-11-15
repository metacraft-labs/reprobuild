## Engine side: drain a provider session's stderr while the session runs.
##
## A session provider's stdout carries no recipe output any more
## (``protocol_channel`` points the provider's fd 1 at its stderr), so
## everything a recipe prints arrives on the stderr pipe the engine created
## when it launched the provider. Nothing else reads that pipe during the
## session, and the engine is blocked reading the protocol pipe while the
## recipe runs. Undrained, the pipe fills (64 KiB on Linux) and the provider
## blocks in a ``write`` while the engine waits for its response: a deadlock.
## So a thread drains it for the session's whole life.
##
## The drained bytes serve the two purposes the single-shot provider path
## (``runtime.nim`` ``runProviderProtocol``) gives a provider's output:
##
## * the last ``ProviderStderrTailBytes`` are kept, so a provider failure
##   (Failure-Semantics.md §"Provider Failures") is reported with what the
##   provider said before it died;
## * lines that begin with ``ProviderStartupBodyFailurePrefix`` are forwarded
##   to the engine's stderr as they arrive, so a contained startup-body
##   failure is never silently dropped. No other provider output is
##   forwarded, as in the single-shot path.
##
## The thread ends at end-of-file, or when ``stop`` is called. ``stop`` is
## needed because end-of-file can be arbitrarily late: a process the recipe
## started inherits the provider's stderr and can outlive the provider.

import std/[locks]

import repro_provider_runtime/runtime

when defined(windows):
  import std/[os, winlean]
else:
  import std/posix

const
  ProviderStderrTailBytes* = 16 * 1024
    ## How much of a provider's most recent stderr a failure report quotes.
  ForwardLineBytes = 4096
    ## Longest line prefix kept for the startup-failure prefix match; the
    ## remainder of a longer line is forwarded unseen-but-intact only if the
    ## kept part matched, which is what the prefix test needs.
  PollMillis = 100
  StopDrainBytes = 1024 * 1024
    ## After ``stop`` is requested, at most this much more is read before
    ## the thread ends even if the pipe still has data: a process the recipe
    ## started can hold the pipe open and keep writing for ever, and ``stop``
    ## must not wait for it.

type
  DrainState = object
    lock: Lock
    stopRequested: bool
    tail: array[ProviderStderrTailBytes, char]
    total: int
      ## Bytes ever received; ``total mod ProviderStderrTailBytes`` is the
      ## next write position of the ring.
    line: array[ForwardLineBytes, char]
    lineLen: int
    lineForwarded: bool
      ## The current line matched the prefix and its head was forwarded;
      ## the rest of it is forwarded as it arrives.
    handle: FileHandle

  ProviderStderrDrain* = ref object
    state: ptr DrainState
    thread: Thread[ptr DrainState]
    running: bool

proc lineMatchesPrefix(state: ptr DrainState): bool =
  const prefix = ProviderStartupBodyFailurePrefix
  if state.lineLen < prefix.len:
    return false
  for i in 0 ..< prefix.len:
    if state.line[i] != prefix[i]:
      return false
  true

proc forward(bytes: openArray[char]) =
  if bytes.len > 0:
    discard stderr.writeBuffer(unsafeAddr bytes[0], bytes.len)
    stderr.flushFile()

proc absorb(state: ptr DrainState; buf: openArray[char]) =
  ## Fold ``buf`` into the tail ring and the forwarding line state. Called
  ## with ``state.lock`` held.
  for ch in buf:
    state.tail[state.total mod ProviderStderrTailBytes] = ch
    inc state.total
    if state.lineForwarded:
      forward([ch])
      if ch == '\n':
        state.lineForwarded = false
        state.lineLen = 0
      continue
    if ch == '\n':
      if state.lineMatchesPrefix():
        forward(state.line.toOpenArray(0, state.lineLen - 1))
        forward(['\n'])
      state.lineLen = 0
      continue
    if state.lineLen < ForwardLineBytes:
      state.line[state.lineLen] = ch
      inc state.lineLen
      if state.lineLen == ForwardLineBytes and state.lineMatchesPrefix():
        forward(state.line.toOpenArray(0, state.lineLen - 1))
        state.lineForwarded = true

proc stopRequested(state: ptr DrainState): bool =
  withLock state.lock:
    result = state.stopRequested

proc drainLoop(state: ptr DrainState) {.thread.} =
  ## Read until end-of-file, or until ``stop`` is requested and either the
  ## pipe has nothing more to give right now or ``StopDrainBytes`` more have
  ## been read. The stop request is checked on every pass, not only when the
  ## pipe is idle, so a writer that never pauses cannot keep the thread (and
  ## the ``stop`` that joins it) alive.
  var buf: array[8192, char]
  var afterStop = 0
  while true:
    let stopping = state.stopRequested()
    if stopping and afterStop >= StopDrainBytes:
      break
    when defined(windows):
      var avail: int32 = 0
      if peekNamedPipe(Handle(state.handle), lpTotalBytesAvail = addr avail) ==
          false:
        break  # broken pipe: every writer closed it
      if avail == 0:
        if stopping:
          break
        sleep(PollMillis div 5)
        continue
      var got: int32 = 0
      let want = int32(min(int(avail), buf.len))
      if readFile(Handle(state.handle), addr buf[0], want, addr got,
          nil) == 0 or got <= 0:
        break
      if stopping:
        afterStop += int(got)
      withLock state.lock:
        state.absorb(buf.toOpenArray(0, int(got) - 1))
    else:
      var pfd = TPollfd(fd: cint(state.handle), events: POLLIN)
      let ready = poll(addr pfd, 1, if stopping: 0 else: PollMillis)
      if ready < 0:
        if errno == EINTR:
          continue
        break
      if ready == 0:
        if stopping:
          break
        continue
      let got = posix.read(cint(state.handle), addr buf[0], buf.len)
      if got < 0:
        if errno == EINTR:
          continue
        break
      if got == 0:
        break  # end-of-file: every writer closed it
      if stopping:
        afterStop += got
      withLock state.lock:
        state.absorb(buf.toOpenArray(0, got - 1))

proc startProviderStderrDrain*(handle: FileHandle): ProviderStderrDrain =
  ## Start draining ``handle`` (the read end of a provider's stderr pipe,
  ## as ``osproc.errorHandle`` returns it). The caller keeps ownership of
  ## the handle and must ``stop`` the drain before closing it.
  result = ProviderStderrDrain(state: createShared(DrainState))
  initLock(result.state.lock)
  result.state.handle = handle
  createThread(result.thread, drainLoop, result.state)
  result.running = true

proc stop*(drain: ProviderStderrDrain) =
  ## Collect what is still readable and end the thread. Waits at most about
  ## one poll interval, plus the time to read ``StopDrainBytes``, even when
  ## a process the recipe started keeps writing. Idempotent.
  if drain == nil or not drain.running:
    return
  withLock drain.state.lock:
    drain.state.stopRequested = true
  joinThread(drain.thread)
  drain.running = false

proc tail*(drain: ProviderStderrDrain): string =
  ## The most recent stderr bytes, oldest first (at most
  ## ``ProviderStderrTailBytes``). Safe to call while the drain runs.
  if drain == nil or drain.state == nil:
    return ""
  withLock drain.state.lock:
    let total = drain.state.total
    let kept = min(total, ProviderStderrTailBytes)
    result = newString(kept)
    for i in 0 ..< kept:
      result[i] = drain.state.tail[(total - kept + i) mod
        ProviderStderrTailBytes]

proc release*(drain: ProviderStderrDrain) =
  ## Stop the drain and free its shared state. ``tail`` returns "" after.
  if drain == nil or drain.state == nil:
    return
  drain.stop()
  deinitLock(drain.state.lock)
  freeShared(drain.state)
  drain.state = nil
