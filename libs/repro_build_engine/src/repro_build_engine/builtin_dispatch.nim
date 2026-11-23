## Bounded concurrent dispatch of executor-backed built-in edges.
##
## The engine runs a built-in edge inline, in its scheduling loop, so the
## edges of a wave that only wait on the network -- a catalog generator's
## `refs` and `source` fetches, each one `git` process and a few round trips
## -- ran one at a time whatever ``maxParallelism`` said. An executor can
## instead split itself (``ConcurrentBuiltinExecutor`` in the engine): a
## ``prepare`` and a ``finish`` that run on the scheduler's thread, and
## between them a ``BuiltinWork`` that runs here, on a worker thread, with at
## most ``bound`` of them at a time.
##
## WHAT CROSSES THE THREAD BOUNDARY is a bare code pointer and plain data. A
## ``BuiltinWork`` is a ``{.nimcall, gcsafe.}`` proc: no closure environment,
## so nothing reference-counted is shared (ORC's counts are not atomic). Its
## input and its output are strings, copied by a ``Channel`` each way, so the
## worker owns its copy outright. Anything that needs the executor's own
## state -- a closure, a `ref`, a table it keeps -- stays in ``prepare`` and
## ``finish``, on the scheduler's thread. That is why the worker is ``gcsafe``
## without a cast.
##
## WHAT IT DOES NOT CHANGE. Results are indexed by item, so the caller sees
## them in its own order whatever order they finish in: concurrency changes
## when an edge runs, never which outcome it gets. The workers are joined
## before ``runBuiltinWork`` returns, so the scheduler resumes only when every
## item of the batch has an outcome. The workers do not touch descriptors 0-2,
## the umask or the environment; a work item may start a child process (a
## `git` run), and the scheduler is blocked in this call meanwhile, so no
## hosted monitor spawn (which redirects 0-2) runs alongside it.

type
  BuiltinWork* = proc(input: string): string {.nimcall, gcsafe.}
    ## The part of a built-in edge that runs on a worker thread: plain data
    ## in, plain data out. It may raise; the outcome then carries the
    ## message.

  BuiltinWorkOutcome* = object
    ok*: bool         ## the work returned
    output*: string   ## what it returned
    error*: string    ## when it raised: the exception's message

  IndexedWork = object
    index: int        ## -1 ends a worker
    work: BuiltinWork
    input: string

  IndexedOutcome = object
    index: int
    outcome: BuiltinWorkOutcome

  Channels = tuple[jobs: ptr Channel[IndexedWork];
                   results: ptr Channel[IndexedOutcome]]

proc runOne(item: IndexedWork): BuiltinWorkOutcome {.gcsafe.} =
  try:
    result.output = item.work(item.input)
    result.ok = true
  except CatchableError as e:
    result.error = e.msg

proc worker(c: Channels) {.thread.} =
  while true:
    let item = c.jobs[].recv()
    if item.index < 0: break
    c.results[].send(IndexedOutcome(index: item.index, outcome: runOne(item)))

proc runBuiltinWork*(items: seq[(BuiltinWork, string)]; bound: int):
    seq[BuiltinWorkOutcome] =
  ## Run every item, at most ``bound`` at a time (at least one); one outcome
  ## per item, in the items' order. Returns when all have finished.
  result = newSeq[BuiltinWorkOutcome](items.len)
  if items.len == 0: return
  let n = max(1, min(bound, items.len))
  var jobChan: Channel[IndexedWork]
  var resultChan: Channel[IndexedOutcome]
  jobChan.open()
  resultChan.open()
  defer:
    jobChan.close()
    resultChan.close()
  var threads = newSeq[Thread[Channels]](n)
  # The channels live in this frame, so no worker may outlive it: when the
  # system refuses a thread, the batch runs on the workers already started,
  # and with none it fails before any work is handed out.
  var started = 0
  try:
    for t in threads.mitems:
      createThread(t, worker, (addr jobChan, addr resultChan))
      inc started
  except ResourceExhaustedError:
    if started == 0: raise
  for i, (work, input) in items:
    jobChan.send(IndexedWork(index: i, work: work, input: input))
  for _ in 0 ..< started:
    jobChan.send(IndexedWork(index: -1))
  for _ in 0 ..< items.len:
    let r = resultChan.recv()
    result[r.index] = r.outcome
  for i in 0 ..< started:
    joinThread(threads[i])
