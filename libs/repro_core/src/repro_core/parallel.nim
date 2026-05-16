type
  ParallelStrategy* = enum
    psSequential
    psCpuBound

  ParallelOptions* = object
    strategy*: ParallelStrategy
    maxWorkers*: int

  ParallelTask*[T] = object
    name*: string
    value*: T

proc defaultParallelOptions*(): ParallelOptions =
  ParallelOptions(strategy: psSequential, maxWorkers: 1)

proc mapParallel*[T, U](items: openArray[T]; options: ParallelOptions;
                        worker: proc(item: T): U {.closure.}): seq[U] =
  discard options
  result = newSeqOfCap[U](items.len)
  for item in items:
    result.add(worker(item))
