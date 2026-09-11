## `repro input revalidate` must attribute the recorded-input loop and only
## the recorded-input loop, at every site that loop runs from.
##
## WHY THIS COUNTER EXISTS, and therefore what this file is defending. The
## claim it was built to test -- that revalidating recorded inputs is the
## largest remaining term in a warm no-op, and that the ~90% of those inputs
## which do not exist are therefore where the time goes -- was not
## observable before it. `repro cache lookup` reports a whole consultation:
## record decode, environment check, input revalidation and output state
## check together. On the host this was measured on, that row ranges 30-65 ms
## for the same unchanged zlib build from one minute to the next, so no term
## inside it could be attributed and no change to any of them could be
## judged. Two successive attempts to optimise the absent-path probes were
## assessed against that row and it could not tell them apart from noise.
##
## With the rows split out, the zlib warm no-op reads: ~35 ms consultation,
## ~24 ms of it input revalidation, and ~20.9 ms of THAT the `lstat`s of the
## 3,928 recorded inputs that are absent -- about 87% of the loop, at
## ~4.8 us each, priced IN SITU by `repro fs probe` rather than by
## microbenchmark. Three separate microbenchmarks of the same quantity came
## in low by factors of two to seven, every one of them because it re-probed
## the same paths in a loop while the real loop touches each path exactly
## once. `filesystemProbeStats` carries the numbers and what they decided.
##
## MOCK POLICY: no mocks, and none may be added. The subject is wall time
## spent in a real loop over real recorded fingerprints against a real
## filesystem; a fake clock or a fake filesystem would leave nothing to
## measure. Records are built with the same `observeFile` call
## `recordActionResult` uses.
##
## Governing spec text -- Incremental-Invalidation.md §"Hash-function
## strategy" and Action-Cache-Per-Edge-Store.md §5.5, both of which argue
## that a cost claim about a consultation has to be carried by something
## load-independent. This file pins the two properties that make the row
## honest rather than the duration itself, which no assertion can pin on a
## shared machine:
##
##   * every consulted record contributes exactly one sample, so an average
##     over `count` is a per-record average and not a per-build one; and
##   * the row covers the loop WHEREVER it runs, so a consultation that
##     takes a different path through the store is not silently unmeasured.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_local_store

proc recordOver(paths: openArray[string]): ActionResultRecord =
  ## A record whose inputs are exactly `paths`, fingerprinted the way
  ## `recordActionResult` fingerprints them.
  result.policy = ffpTimestamp
  for path in paths:
    result.inputs.add(observeFile(path, ffpTimestamp))

proc absentProbes(dir: string; count: int): seq[string] =
  for i in 0 ..< count:
    result.add(dir / ("libabsent" & $i & ".dylib"))

suite "input revalidation is attributed separately from the consultation":
  test "one consulted record contributes exactly one sample":
    let root = createTempDir("repro-reval-attrib-", "")
    defer: removeDir(root)
    let record = recordOver(absentProbes(root, 64))
    # Denominator: without inputs there is no loop to attribute, and every
    # assertion below would hold vacuously.
    check record.inputs.len == 64
    check record.inputs.allIt(it.metadata.kind == ffkMissing)

    resetOutputStateCheckStats()
    check hotMetadataRecordInputsUnchanged(@[record], nil)
    let one = inputRevalidateStats()
    checkpoint("one record: calls=" & $one.calls & " nanos=" & $one.nanos)
    check one.calls == 1
    check one.nanos > 0

    resetOutputStateCheckStats()
    check hotMetadataRecordInputsUnchanged(@[record, record, record], nil)
    let three = inputRevalidateStats()
    checkpoint("three records: calls=" & $three.calls &
      " nanos=" & $three.nanos)
    # One sample per RECORD, not one per build and not one per input. An
    # implementation that emitted a single cumulative sample made every
    # per-call average wrong by a factor of the record count; the output
    # side carries the same rule and the same reason.
    check three.calls == 3
    check three.nanos > 0

  test "the accumulators are zeroed for each build":
    let root = createTempDir("repro-reval-attrib-", "")
    defer: removeDir(root)
    let record = recordOver(absentProbes(root, 8))
    resetOutputStateCheckStats()
    discard hotMetadataRecordInputsUnchanged(@[record], nil)
    check inputRevalidateStats().calls == 1
    # These are process-global, and the daemon, `repro watch` and every test
    # binary run more than one build per process. Without the reset each
    # build would report its own cost plus every earlier build's.
    resetOutputStateCheckStats()
    let cleared = inputRevalidateStats()
    check cleared.calls == 0
    check cleared.nanos == 0

  test "a record whose input moved is still attributed":
    # The loop exits early on the first changed input. That exit must not
    # escape the measurement: a build that MISSES would otherwise report
    # less revalidation than the build that hit, which inverts the reading
    # exactly when someone is looking for why a miss happened.
    let root = createTempDir("repro-reval-attrib-", "")
    defer: removeDir(root)
    let probes = absentProbes(root, 32)
    let record = recordOver(probes)
    resetOutputStateCheckStats()
    check hotMetadataRecordInputsUnchanged(@[record], nil)
    check inputRevalidateStats().calls == 1

    writeFile(probes[0], "the probe is no longer absent")
    resetOutputStateCheckStats()
    check not hotMetadataRecordInputsUnchanged(@[record], nil)
    let onMiss = inputRevalidateStats()
    checkpoint("on miss: calls=" & $onMiss.calls & " nanos=" & $onMiss.nanos)
    check onMiss.calls == 1
    check onMiss.nanos > 0

  test "first touches are counted, and repeats are not":
    # The population bound. `FileMetadataCache` serves every repeat of a path
    # without a syscall, so a record consulted twice against the SAME cache
    # has its first touches counted once -- and an optimisation of absent
    # probes is bounded by that number, not by the number of times an absent
    # input appears. Counting occurrences instead is what made an earlier
    # attempt's results irreconcilable with its own arithmetic.
    let root = createTempDir("repro-reval-attrib-", "")
    defer: removeDir(root)
    let record = recordOver(absentProbes(root, 40))
    var cache = initFileMetadataCache()
    resetOutputStateCheckStats()
    # Three SEPARATE consultations against one cache, which is the shape a
    # build has: `hotMetadataRecordInputsUnchanged` de-duplicates within a
    # single call, so repeating the record inside one call would not
    # exercise the cache at all.
    for _ in 0 ..< 3:
      check hotMetadataRecordInputsUnchanged(@[record], addr cache)
    let stats = filesystemProbeStats()
    let cacheStats = cache.metadataStats()
    checkpoint("calls=" & $stats.calls &
      " absentFirstTouches=" & $stats.absentFirstTouches &
      " nanos=" & $stats.nanos &
      " currentRunHits=" & $cacheStats.currentRunHits)
    # 120 checks, 40 first touches, 80 served by the cache with no syscall.
    check stats.absentFirstTouches == 40
    check stats.calls == 40
    check cacheStats.currentRunHits == 80
    check stats.nanos > 0

  test "an input that exists is a first touch but not an absent one":
    # The absent counter must not drift into counting everything that
    # reaches the filesystem; the two populations are different sizes and
    # the difference is what any absent-probe optimisation cannot touch.
    let root = createTempDir("repro-reval-attrib-", "")
    defer: removeDir(root)
    let present = root / "exists.txt"
    writeFile(present, "here")
    var paths = absentProbes(root, 12)
    paths.add(present)
    let record = recordOver(paths)
    check record.inputs[^1].metadata.kind == ffkRegular
    resetOutputStateCheckStats()
    check hotMetadataRecordInputsUnchanged(@[record], nil)
    let stats = filesystemProbeStats()
    checkpoint("calls=" & $stats.calls &
      " absentFirstTouches=" & $stats.absentFirstTouches)
    check stats.calls == 13
    check stats.absentFirstTouches == 12

  test "the metadata cache path is attributed too":
    # A consultation that supplies a `FileMetadataCache` takes a different
    # branch per input, and it is the branch a real build takes. Measuring
    # only the cacheless one would report a cost no build pays.
    let root = createTempDir("repro-reval-attrib-", "")
    defer: removeDir(root)
    let record = recordOver(absentProbes(root, 48))
    var cache = initFileMetadataCache()
    resetOutputStateCheckStats()
    check hotMetadataRecordInputsUnchanged(@[record], addr cache)
    let stats = inputRevalidateStats()
    let cacheStats = cache.metadataStats()
    checkpoint("cached: calls=" & $stats.calls & " nanos=" & $stats.nanos &
      " revalidated=" & $cacheStats.warmRevalidated &
      " currentRunHits=" & $cacheStats.currentRunHits)
    check stats.calls == 1
    check stats.nanos > 0
    # Denominator: the cache must actually have been consulted, otherwise
    # this is the previous case under a different name.
    check cacheStats.warmRevalidated == 48
