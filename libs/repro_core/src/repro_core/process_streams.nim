## Reading a child process's output stream to the END of it.
##
## N51 / M5-R5 / N50 — THE SHORT READ
## ==================================
##
## ``streams.readAll`` is NOT "read until EOF". Its loop is:
##
##     while true:
##       let readBytes = readData(s, addr buffer[0], 1024)
##       if readBytes == 0: break
##       ...
##       if readBytes < 1024: break        # <-- here
##
## so it returns at the first read that does not fill the 1 KiB buffer. For a
## FILE that means EOF. For a PIPE it means "the writer had not got round to
## it yet", which is a completely ordinary thing for a child process to do.
##
## On WINDOWS this bites, because ``osproc.outputStream`` is a raw
## ``FileHandleStream`` whose ``readData`` is one ``ReadFile`` call, and
## ``ReadFile`` on a pipe returns as soon as ANY bytes are available. Measured
## on this host against ``t_n51_drain_process_stream``'s fixture child, which
## writes 5 bytes, flushes, sleeps 900 ms, then writes the remaining 404:
##
##     naive readAll(): bytes=5   exit=7 sawTail=false
##     drain loop     : bytes=409 exit=7 sawTail=true
##
## Five bytes of a 409-byte diagnostic, and the process exit code was right in
## both cases — so nothing about the capture looked wrong. That is the same
## shape M5 reported as its R5 (one byte of a four-line child diagnostic) and
## the same one that recurred as N50, where a truncated observer log made a
## real failure read as an empty one.
##
## On POSIX ``osproc`` hands back a ``FileStream`` over a stdio ``File``, and
## ``fread`` loops internally until the full count or real EOF — so the same
## ``readAll`` is already correct there. The defect is Windows-only; the
## remedy below is not, because writing it once is cheaper than writing
## ``when defined(windows)`` at every call site.
##
## WHAT THIS CHANGES, STATED PLAINLY
## ---------------------------------
##
## ``readAll`` returns EARLY on a slow writer. ``drainStream`` does not: it
## blocks until the write end is CLOSED. For a finite child that exits, those
## differ only in completeness. They differ in KIND for a child that leaks a
## descendant holding the pipe's write handle open — there the early return
## was accidentally load-bearing and this loop would hang. That case is real
## and documented in this tree (``repro_interface_artifacts.runCommand``: on
## Windows ``nim`` exits while ``gcc`` still holds the write handle, which is
## why that path writes to a temp-file sink instead of a pipe). So this is a
## helper to apply after asking whether the child can outlive its own stdout,
## NOT a sweep to run over every ``readAll`` in the tree.
##
## A bounded alternative exists and is deliberately not duplicated here:
## ``tools/test-runner``'s ``drainProbePipe`` polls ``PeekNamedPipe`` /
## non-blocking reads against a deadline. That is the right answer where the
## child is arbitrary and untrusted, and it is ~60 lines of per-platform
## handle code. Sites whose child is a known, finite tool take this instead.

import std/[osproc, streams]

proc drainStream*(s: Stream): string =
  ## Read ``s`` until its write end closes, rather than until the first short
  ## read. A nil stream reads as "".
  ##
  ## The loop is ``9c8a97d6``'s: ``atEnd`` is accurate on both backends
  ## (Nim 2.2's ``hsAtEnd`` is set only on a zero-byte read — the
  ## ``br < bufLen`` variant that would have made this loop useless is
  ## commented out in ``osproc``), so repeating ``readAll`` until ``atEnd``
  ## terminates exactly at EOF.
  if s == nil:
    return ""
  result = ""
  while not s.atEnd():
    result.add(s.readAll())

# ---------------------------------------------------------------------------
# Draining stdout and stderr at the same time.
# ---------------------------------------------------------------------------
#
# A child with two pipes has to have BOTH serviced at once: read one to EOF
# before touching the other and a child that fills the second pipe's buffer
# blocks in `write`, never closes the first, and the pair deadlocks. On
# Windows there is no `poll` over anonymous pipes, so the portable shape is a
# second thread that reads one of the streams while the caller reads the
# other. `drainStdoutAndStderr` is that shape, written once.
#
# WHAT THE READER THREAD READS IS NEVER HELD IN A NIM STRING. Under
# `--mm:orc` with `--threads:on` (how every reprobuild binary is built:
# `scripts/build_apps.sh`, and `nim c`'s default) Nim's allocator gives each
# thread its own region -- `var allocator {.rtlThreadVar.}: MemRegion` in
# `system/mmdisp.nim` -- and every chunk records its owning region
# (`chunk.owner`, `system/alloc.nim`). Freeing a block from another thread is
# allowed, but `rawDealloc` does it by pushing the cell onto the OWNER's
# shared free list (`addToSharedFreeList` /
# `addToSharedFreeListBigChunks`), i.e. it writes into the owner's
# `MemRegion`. That region is a thread-local variable, and under ORC nothing
# keeps it alive past its thread (`deallocOsPages` runs at thread exit only
# for the refc-family GCs, `threadimpl.nim`): when the thread ends, its
# thread-local storage is released. So a string built on a reader thread and
# freed after `joinThread` writes into released memory. On Windows, where the
# loader frees a thread's TLS block at thread exit, that is a SIGSEGV inside
# `addToSharedFreeList` with no user frame near it -- the defect recorded in
# reprobuild-pm/issues/2026-10-20-profile-compile-frees-reader-thread-memory-after-the-thread-exits.md.
#
# The alternatives, and why they are not used:
#
# * `allocShared` -- under ORC it is the same per-thread allocator
#   (`allocSharedImpl` calls `allocImpl`), with the same owner.
# * a `Channel` -- under ORC `send` moves the value's bits into the queue
#   (`channels_builtin.rawSend` is a `copyMem` when `usesDestructors`), so the
#   payload is still owned by the sending thread.
# * `isolate` / `move` -- transfer ownership in the type system, not in the
#   allocator: the block still belongs to the region it was allocated from.
# * `-d:useMalloc` -- removes the per-thread regions and with them the
#   crash, but it is a whole-program allocator switch that every binary
#   (and the bundle) would have to carry, for one helper.
# * redirecting stderr to a file -- works, but adds a file inside the
#   monitored edges that call this (the profile compile), and a scratch path
#   every caller would have to own and clean.
#
# So the reader appends what it reads to memory from the C allocator, which
# has one process-wide heap and no owning thread, and the CALLER copies it
# into an ordinary string on its own thread after the join. RunQuota fixed
# the same defect in its own drain the same way
# (`runquota_core/process_owned`); this is the reprobuild-side helper rather
# than a dependency on RunQuota's internals.

when compileOption("threads"):
  proc cRealloc(p: pointer; size: csize_t): pointer {.importc: "realloc",
    header: "<stdlib.h>".}
  proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

  type
    ProcessOwnedText = object
      ## Bytes in C-heap memory, so the thread that frees them does not
      ## matter. A plain object with a raw pointer and no hooks: copying it
      ## is a bit copy, and the one owner calls `release` exactly once.
      bytes: ptr UncheckedArray[char]
      len: int
      cap: int

    StreamDrainState = object
      ## Shared between the caller and the reader thread through a `ptr` to
      ## the caller's stack frame, which outlives the thread because the
      ## caller joins it before returning on every path. The reader writes
      ## `text`, `readFailed`, `failure` and `outOfMemory`; the caller reads
      ## them only after `joinThread`, which is the synchronisation.
      stream: Stream
        ## Created on the CALLER's thread (osproc builds `errorStream`
        ## lazily, so the caller must touch it before the thread starts, or
        ## the stream object itself would be reader-owned).
      process: Process
        ## The child, so a reader whose read FAILS can stop it (see
        ## `stopChild`). Only passed to `kill`, which takes no reference
        ## and allocates nothing.
      text: ProcessOwnedText
      readFailed: bool
        ## Set on a read failure even when `failure` could not hold the
        ## message, so a failure is never mistaken for end of input.
      failure: ProcessOwnedText
      outOfMemory: bool

  proc stopChild(p: Process) =
    ## Best-effort SIGKILL / `TerminateProcess`. `kill` rather than
    ## `terminate`: a SIGTERM the child handles or ignores would leave it
    ## alive and writing to a pipe nobody drains. Errors are swallowed: the
    ## child having already exited is the common reason, and the caller is
    ## already on a failure path whose own error is the one to report.
    try:
      p.kill()
    except CatchableError:
      discard

  proc stopAndReap(p: Process) =
    ## Caller-side: stop the child, then wait for it, so a failure path
    ## leaves neither a writer blocked on a pipe nor a zombie.
    stopChild(p)
    try:
      discard p.waitForExit()
    except CatchableError:
      discard

  proc append(t: var ProcessOwnedText; data: pointer; n: int): bool =
    ## Append `n` bytes; false (and `t` unchanged) when the C allocator has
    ## nothing to give.
    if n <= 0:
      return true
    if t.len + n > t.cap:
      var cap = max(t.cap * 2, 64 * 1024)
      while cap < t.len + n:
        cap = cap * 2
      let grown = cRealloc(t.bytes, csize_t(cap))
      if grown == nil:
        return false
      t.bytes = cast[ptr UncheckedArray[char]](grown)
      t.cap = cap
    copyMem(addr t.bytes[t.len], data, n)
    t.len += n
    true

  proc release(t: var ProcessOwnedText) =
    if t.bytes != nil:
      cFree(t.bytes)
    t = ProcessOwnedText()

  proc toCallerString(t: ProcessOwnedText): string =
    ## A copy allocated on the CALLING thread's heap, so the caller frees
    ## it on the thread that owns it.
    result = newString(t.len)
    if t.len > 0:
      copyMem(addr result[0], t.bytes, t.len)

  proc drainToProcessOwned(state: ptr StreamDrainState) {.thread.} =
    ## The reader thread. Reads to end of input -- a zero-byte read, the
    ## same stop condition as `drainStream` (`hsReadData` sets `atTheEnd`
    ## exactly when `ReadFile` returns 0 bytes; POSIX `fread` returns 0 only
    ## at EOF). Every Nim allocation made here (an exception and its
    ## message) is also freed here.
    ##
    ## `Stream`'s methods carry no gcsafe annotation; the stream is used by
    ## this thread alone until the caller joins it.
    {.cast(gcsafe).}:
      # On this thread's stack, not its heap: nothing to hand back.
      var chunk: array[32 * 1024, char]
      try:
        while true:
          let n = state.stream.readData(addr chunk[0], chunk.len)
          if n <= 0:
            break
          # On allocation failure keep READING and drop the bytes: a reader
          # that stopped would leave the child blocked on a full pipe and
          # the caller's own drain waiting on it forever.
          if not state.outOfMemory and not state.text.append(addr chunk[0], n):
            state.outOfMemory = true
      except CatchableError as err:
        # A reader that stops here leaves the stderr pipe undrained: a child
        # with more to write would block on it, never close stdout, and the
        # caller's stdout drain (and so the join) would wait forever. Stop
        # the child so its pipes close; the caller reaps it after the join.
        state.readFailed = true
        stopChild(state.process)
        let what = if err.msg.len > 0: err.msg else: "read failed"
        discard state.failure.append(unsafeAddr what[0], what.len)

  proc drainStdoutAndStderr*(p: Process): tuple[output, errorOutput: string] =
    ## Read `p`'s stdout and stderr to the end AT THE SAME TIME and return
    ## both, without waiting for the process. Stdout is drained on the
    ## calling thread (`drainStream`), stderr on a short-lived reader thread
    ## whose bytes never live on its own heap (see the comment above).
    ##
    ## For a process started WITHOUT `poStdErrToStdOut`: with it, both
    ## streams wrap one pipe and two readers would split its bytes.
    ##
    ## Raises `IOError` when either stream could not be read. On every
    ## failure path the child is killed and reaped before this returns, so
    ## it cannot stay blocked on a pipe nobody reads and the join cannot
    ## hang on it; the caller still owns `close()`. (A grandchild that
    ## inherited one of the pipes keeps it open past the child's death; that
    ## is outside what killing the child can reach, here as in
    ## `drainStream`.)
    var state = StreamDrainState(stream: p.errorStream, process: p)
    var reader: Thread[ptr StreamDrainState]
    try:
      createThread(reader, drainToProcessOwned, addr state)
    except CatchableError, Defect:
      stopAndReap(p)
      raise
    var stdoutFailed = false
    var stderrReadFailed = false
    var stderrFailure = ""
    var stderrOutOfMemory = false
    try:
      try:
        result.output = drainStream(p.outputStream)
      except CatchableError, Defect:
        # Stop the writer before joining: the reader is waiting for EOF on
        # a pipe the child keeps open, and the child may be blocked writing
        # to the stdout pipe we stopped draining. Reaped after the join.
        stdoutFailed = true
        stopChild(p)
        raise
    finally:
      # Join on every path, then copy out and free the C-heap bytes. Nothing
      # here raises a recoverable error, so an exception already in flight
      # (the stdout failure above) is the one the caller sees.
      joinThread(reader)
      stderrReadFailed = state.readFailed
      stderrFailure = state.failure.toCallerString()
      stderrOutOfMemory = state.outOfMemory
      result.errorOutput = state.text.toCallerString()
      state.text.release()
      state.failure.release()
      # Reap on every failure path, and only AFTER the join: until the
      # reader has exited it may still `kill` the child, and on POSIX a
      # child reaped before that could have its pid recycled. An
      # out-of-memory reader kept draining, so that child may still be
      # running; it is stopped too rather than handed back live on an error
      # path.
      if stdoutFailed or stderrReadFailed or stderrOutOfMemory:
        stopAndReap(p)
    if stderrReadFailed:
      raise newException(IOError, "reading child stderr: " &
        (if stderrFailure.len > 0: stderrFailure else: "read failed"))
    if stderrOutOfMemory:
      raise newException(IOError, "reading child stderr: out of memory " &
        "after " & $result.errorOutput.len & " bytes")
