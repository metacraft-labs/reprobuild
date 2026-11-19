## Bounded concurrent downloads from configured mirrors (NPC-AREQ29 claim 2:
## a cold fetch downloads its source objects in parallel).
##
## `getAll` runs at most ``workers`` HTTPS GETs at a time, each on a worker
## thread as one blocking `httpsRequestWith`, and writes each `200` answer's
## body to the file its job names. The caller resolves (and dials) every
## address on its own thread before it hands a job over, so the policy's
## resolver and dialer closures never leave that thread.
##
## What crosses a thread boundary is plain data copied by a `Channel`: the
## URL's parts, the trust-anchor path, the limits, the address and the
## destination path one way; the status, the byte count and a failure text
## the other. No closure and no `ref` is shared, so the worker is gcsafe
## without a cast. A body goes to a file rather than through the channel, so
## memory holds at most ``workers`` bodies at once.
##
## Results are indexed by job, so the caller sees them in its own order
## whatever order the transfers finish in: concurrency changes when a byte
## arrives, never which answer a job gets. Nothing here verifies a body; the
## caller checks each object against its digest as before.
##
## The workers start no process and change no process-wide state (no
## descriptor 0-2, no umask, no environment): they connect, read and write
## one new file each. They are joined before `getAll` returns.

import std/net

import repro_nimble_generator/egress

import ./https_get

type
  GetJob* = object
    url*: OriginUrl
    connectTo*: IpAddress ## already resolved and dialed by the caller
    caFile*: string
    limits*: EgressLimits
    maxBytes*: int64
    dest*: string         ## where a `200` answer's body is written

  GetOutcome* = object
    answered*: bool  ## an HTTP answer was read; `status` holds its code
    status*: int
    bytes*: int64    ## the body written to the job's `dest` (`200` only)
    refused*: bool   ## `failure` is an egress refusal (size, stall, time)
    failure*: string ## why there is no answer

  IndexedJob = object
    index: int       ## -1 ends a worker
    job: GetJob

  IndexedOutcome = object
    index: int
    outcome: GetOutcome

  Channels = tuple[jobs: ptr Channel[IndexedJob];
                   results: ptr Channel[IndexedOutcome]]

const DefaultParallelDownloads* = 8
  ## Concurrent mirror downloads of one fetch when its configuration does
  ## not say.

proc runJob(job: GetJob): GetOutcome {.gcsafe.} =
  try:
    let a = httpsRequestWith(job.caFile, job.limits, "GET", job.url,
      job.connectTo, job.maxBytes)
    result.answered = true
    result.status = a.status
    if a.status == 200:
      writeFile(job.dest, a.body)
      result.bytes = int64(a.body.len)
  except EgressError as e:
    result.refused = true
    result.failure = e.msg
  except CatchableError as e:
    result.failure = e.msg

proc worker(c: Channels) {.thread.} =
  while true:
    let item = c.jobs[].recv()
    if item.index < 0: break
    c.results[].send(IndexedOutcome(index: item.index,
      outcome: runJob(item.job)))

proc getAll*(jobs: seq[GetJob]; workers: int): seq[GetOutcome] =
  ## Run ``jobs``, at most ``workers`` at a time; one outcome per job, in
  ## the jobs' order.
  result = newSeq[GetOutcome](jobs.len)
  if jobs.len == 0: return
  let n = max(1, min(workers, jobs.len))
  var jobChan: Channel[IndexedJob]
  var resultChan: Channel[IndexedOutcome]
  jobChan.open()
  resultChan.open()
  var threads = newSeq[Thread[Channels]](n)
  for t in threads.mitems:
    createThread(t, worker, (addr jobChan, addr resultChan))
  for i, j in jobs:
    jobChan.send(IndexedJob(index: i, job: j))
  for _ in 0 ..< n:
    jobChan.send(IndexedJob(index: -1))
  for _ in 0 ..< jobs.len:
    let r = resultChan.recv()
    result[r.index] = r.outcome
  joinThreads(threads)
  jobChan.close()
  resultChan.close()
