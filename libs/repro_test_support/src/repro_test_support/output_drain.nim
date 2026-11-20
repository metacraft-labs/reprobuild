## Read a child's output while the test waits for something else.
##
## A test that starts a process with ``startProcess`` and then polls a file,
## a socket or a status record before reading ``outputStream`` deadlocks as
## soon as the child writes more than the pipe holds: the child blocks in
## ``write`` and never reaches the state the test is waiting for. The pipe
## is not reliably 64 KiB. Linux gives a new pipe a single page once the
## user's pipe buffers pass ``fs.pipe-user-pages-soft`` (pipe(7)), which a
## busy CI host does reach. On 2026-11-16 a ``repro up`` blocked after 8 KiB
## of dev-env progress lines, and two dev-session tests hung on it.
##
## ``startOutputDrain`` reads the stream to its end on a thread of its own
## from the moment the process starts; ``collect`` joins that thread and
## returns everything the child wrote.
##
##   # `up` is the Process the test started
##   let drain = startOutputDrain(up)
##   ... wait for whatever the test needs ...
##   discard up.waitForExit()
##   let output = drain.collect()   # before up.close()
##
## ``collect`` returns once every holder of the pipe's write end has closed
## it. Usually that is the child exiting, but a grandchild that inherited
## the pipe also counts. So call it after the child has exited or been
## terminated, and always before ``close`` on the process (closing the
## stream under a reading thread is undefined).

import std/[osproc, streams]

type
  OutputDrainObj = object
    stream: Stream
    output: string
    thread: Thread[ptr OutputDrainObj]
    joined: bool
  OutputDrain* = ref OutputDrainObj
    ## A child's merged output, being read on a thread of its own.

proc drainLoop(target: ptr OutputDrainObj) {.thread.} =
  ## The owning thread does not touch ``target`` until it joins this one.
  {.cast(gcsafe).}:
    target.output = target.stream.readAll()

proc startOutputDrain*(process: Process): OutputDrain =
  ## Start reading ``process.outputStream`` to its end in the background.
  result = OutputDrain(stream: process.outputStream)
  createThread(result.thread, drainLoop, addr result[])

proc collect*(drain: OutputDrain): string =
  ## Wait for the child's output to end and return all of it. Safe to call
  ## more than once.
  if not drain.joined:
    joinThread(drain.thread)
    drain.joined = true
  drain.output
