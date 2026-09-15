## Soundness of skipping revalidation for inputs that were absent inside a
## published package-store output path, and the STRUCTURE of the duration
## rows that now sit beside the recorded-input counts.
##
## The first suite is graded on SOUNDNESS, never on timing. Every case there
## asks "does an input that could change still invalidate", because the
## failure mode of that optimisation is a stale cache hit, not a slow one.
## How much the skip SAVES is a measurement and does not belong in a test.
##
## The second suite does not assert a duration either, and no case in it can
## go red because the machine is busy. It asserts the three things a duration
## row can be wrong about without anyone noticing -- that it is wired at all,
## that it is reset with its count, and that the classes are DISJOINT
## sub-intervals of the loop that encloses them -- which is the same shape of
## guard MAC-3 put behind the record-decode rows, and for the same reason: a
## count that renders a literal `0.0` in the total column reads as "measured,
## and free" when it means "never measured".
##
## No mocks. The store cases run against the real `/nix/store` on this host,
## because the predicate deliberately takes no injection point: honouring an
## ambient store location was a measured hole that permanently poisoned
## records, and a test seam would be the same hole with a different name.
## Where the host has no store the cases `skip()` with that reason rather
## than passing vacuously.

import std/[monotimes, options, os, sets, strutils, times, unittest]

import repro_local_store

proc anExistingStoreOutputPath(): string =
  ## A real published output path on this host, or "" if there is none.
  if not dirExists("/nix/store"):
    return ""
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir:
      continue
    if path.lastPathPart.startsWith("."):
      continue
    # Must itself be listable, so the "absent inside it" case is genuinely
    # absence rather than an unreadable directory.
    try:
      for _, _ in walkDir(path):
        discard
      return path
    except OSError, IOError:
      continue
  ""

proc absentInput(path: string): FileFingerprint =
  FileFingerprint(path: path, policy: ffpTimestamp,
    metadata: FileMetadata(kind: ffkMissing))

proc recordWith(inputs: varargs[FileFingerprint]): ActionResultRecord =
  result = ActionResultRecord(policy: ffpTimestamp)
  for input in inputs:
    result.inputs.add(input)

suite "absent store inputs skip revalidation":

  test "only a path STRICTLY INSIDE an output path is classified":
    # The bare output path is the case that makes this unsound if dropped:
    # building or substituting the package is exactly what brings it into
    # existence, so its absence is not stable.
    check immutableStoreOutputPath("/nix/store/abc-foo/lib/libx.so") ==
      "/nix/store/abc-foo"
    check immutableStoreOutputPath("/nix/store/abc-foo/lib/") ==
      "/nix/store/abc-foo"
    check immutableStoreOutputPath("/nix/store/abc-foo") == ""
    check immutableStoreOutputPath("/nix/store/") == ""
    check immutableStoreOutputPath("/nix/store") == ""

  test "the class-3 residue is not classified and keeps being probed":
    # Every one of these can come into existence between two builds, and an
    # exclusion that swallowed them would serve a stale hit. This is the
    # exposure a blanket evidence-scope narrowing discards and this change
    # deliberately keeps.
    for path in ["/usr/bin/ld", "/home/someone/.config/nim/nim.cfg",
                 "/home/someone/project/nimble.lock",
                 "/home/someone/project/config.nims",
                 "/opt/homebrew/lib/libz.dylib",
                 "/tmp/nim-parameter-file-12345",
                 "/nix/var/nix/profiles/default/bin/cc",
                 "relative/path/x.h", ""]:
      check immutableStoreOutputPath(path) == ""

  test "a near-miss prefix is not classified":
    # A directory that merely LOOKS like the store must not inherit the
    # store's write discipline.
    check immutableStoreOutputPath("/nix/store-other/abc/x") == ""
    check immutableStoreOutputPath("/home/u/nix/store/abc/x") == ""
    check immutableStoreOutputPath("/nix/stores/abc/x") == ""

  test "an input absent inside an existing output path is skipped":
    let storePath = anExistingStoreOutputPath()
    if storePath.len == 0:
      skip()
    else:
      resetOutputStateCheckStats()
      var cache = initFileMetadataCache()
      let missing = storePath / "definitely-absent-6f3a1c" / "x.h"
      check not fileExists(missing)
      let record = recordWith(absentInput(missing))
      check hotMetadataRecordInputsUnchanged([record], addr cache)
      # The skip happened, and it was not merely a metadata-cache hit.
      check storeAbsenceSkipStats() == 1
      check cache.metadataStats().warmRevalidated == 0

  test "an input absent inside a NON-EXISTENT output path is still probed":
    # The output path can still be built or substituted, and it would bring
    # this path with it. Skipping here would be the stale hit.
    resetOutputStateCheckStats()
    var cache = initFileMetadataCache()
    let missing =
      "/nix/store/0000000000000000000000000000000-absent-pkg/lib/x.h"
    check not fileExists(missing)
    let record = recordWith(absentInput(missing))
    check hotMetadataRecordInputsUnchanged([record], addr cache)
    check storeAbsenceSkipStats() == 0

  test "a PRESENT input inside an output path is still probed":
    # Immutability stops entries being ADDED; it does not stop the whole
    # output path being garbage-collected. A present store input that
    # disappears must invalidate, so it keeps its probe.
    let storePath = anExistingStoreOutputPath()
    if storePath.len == 0:
      skip()
    else:
      # Store paths keep their files under `bin/`, `lib/` and friends, so a
      # top-level-only search skipped this case vacuously and hid the
      # assertion it exists for.
      var present = ""
      for path in walkDirRec(storePath):
        if fileExists(path) and not symlinkExists(path):
          present = path
          break
      if present.len == 0:
        skip()
      else:
        resetOutputStateCheckStats()
        var cache = initFileMetadataCache()
        let record = recordWith(observeFile(present, ffpTimestamp))
        check hotMetadataRecordInputsUnchanged([record], addr cache)
        check storeAbsenceSkipStats() == 0
        check cache.metadataStats().warmRevalidated == 1

  test "an absent input OUTSIDE the store invalidates when it appears":
    # THE MUTATION GUARD. Widening the prefix test to cover a writable
    # directory reddens exactly this case, because the file it creates is
    # precisely what the store's write discipline promises cannot happen.
    let dir = getTempDir() / "repro-absent-outside-store-6f3a1c"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let appears = dir / "appears-later.h"
    check not fileExists(appears)
    let record = recordWith(absentInput(appears))

    resetOutputStateCheckStats()
    var before = initFileMetadataCache()
    check hotMetadataRecordInputsUnchanged([record], addr before)
    check storeAbsenceSkipStats() == 0

    writeFile(appears, "#pragma once\n")
    resetOutputStateCheckStats()
    var after = initFileMetadataCache()
    check not hotMetadataRecordInputsUnchanged([record], addr after)

  test "an absent input inside an output path that APPEARS is still caught":
    # The same guard one level in: the output path itself is created, which
    # the classification refuses to treat as immutable, so the input inside
    # it must be seen to appear.
    let fakeStore = getTempDir() / "repro-fake-store-6f3a1c"
    removeDir(fakeStore)
    createDir(fakeStore)
    defer: removeDir(fakeStore)
    let inside = fakeStore / "abc-pkg" / "lib" / "x.h"
    let record = recordWith(absentInput(inside))
    resetOutputStateCheckStats()
    var cache = initFileMetadataCache()
    check hotMetadataRecordInputsUnchanged([record], addr cache)
    createDir(fakeStore / "abc-pkg" / "lib")
    writeFile(inside, "#pragma once\n")
    var after = initFileMetadataCache()
    check not hotMetadataRecordInputsUnchanged([record], addr after)

suite "the duration rows beside the recorded-input counts":
  ## `repro file metadata current-run hit`, `cold stat`, `warm revalidate` and
  ## `repro store absence skips` were counts with a literal `0.0` total, and
  ## ~18 ms of a warm no-op's `repro cache lookup` was attributed to them for
  ## two milestones by SUBTRACTION -- nothing in the table could contradict
  ## the figure. These cases guard the instrument that replaced the
  ## subtraction, not the numbers it reports.

  proc presentInput(path: string): FileFingerprint =
    observeFile(path, ffpTimestamp)

  test "each class row is wired and is reset with its count":
    # One record per class, so every accumulator is exercised in a state
    # where its count is known. Dropping any one `metadataProbeClass`
    # assignment, or any one `attributeMetadataProbe` arm, reddens here.
    let dir = getTempDir() / "repro-mac4-classes-6f3a1c"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let present = dir / "present.h"
    writeFile(present, "#pragma once\n")

    resetOutputStateCheckStats()
    # Before any check. If `resetOutputStateCheckStats` stopped clearing the
    # loop accumulator this is where it shows: the suite above has already
    # run thousands of checks in this process, so a surviving value is large
    # and this check is nowhere near a boundary.
    check recordedInputRevalidateStats().checks == 0
    check recordedInputRevalidateStats().nanos == 0
    check storeAbsenceSkipNanoStats() == 0

    var cache = initFileMetadataCache()
    # A COLD stat: first touch of this path in this process. Goes through
    # `fingerprintMetadata`, not the recorded path, which is the only caller
    # that can reach the `coldStats` arm.
    discard observeFile(present, ffpTimestamp, addr cache)
    check cache.metadataStats().coldStats == 1
    check cache.metadataStats().coldStatNanos > 0

    # A WARM revalidation: a recorded input, not in this cache's table.
    var revalidateCache = initFileMetadataCache()
    let record = recordWith(presentInput(present))
    check hotMetadataRecordInputsUnchanged([record], addr revalidateCache)
    check revalidateCache.metadataStats().warmRevalidated == 1
    check revalidateCache.metadataStats().warmRevalidateNanos > 0

    # A CURRENT-RUN hit: the same input a second time, same cache.
    check hotMetadataRecordInputsUnchanged([record], addr revalidateCache)
    check revalidateCache.metadataStats().currentRunHits == 1
    check revalidateCache.metadataStats().currentRunHitNanos > 0

    # The enclosing loop ran and was counted.
    check recordedInputRevalidateStats().checks == 2
    check recordedInputRevalidateStats().nanos > 0

    # And it all goes back to zero, so a reading after a build describes THAT
    # build rather than that build plus every earlier one in the process.
    resetOutputStateCheckStats()
    check recordedInputRevalidateStats().checks == 0
    check recordedInputRevalidateStats().nanos == 0

  test "the store-absence skip row is wired and is reset with its count":
    ## The skip's duration lives in a process-global beside its process-global
    ## COUNT, unlike the other three, which live in the cache object beside
    ## theirs. Asserted separately because that difference is exactly the kind
    ## of thing a later edit unifies "for consistency", at which point the
    ## duration would describe two caches while the count described one.
    let storePath = anExistingStoreOutputPath()
    if storePath.len == 0:
      skip()
    else:
      resetOutputStateCheckStats()
      check storeAbsenceSkipNanoStats() == 0
      var cache = initFileMetadataCache()
      let missing = storePath / "definitely-absent-6f3a1c" / "x.h"
      let record = recordWith(absentInput(missing))
      check hotMetadataRecordInputsUnchanged([record], addr cache)
      check storeAbsenceSkipStats() == 1
      check storeAbsenceSkipNanoStats() > 0
      # ONE check, not two. The skip arm probes the OUTPUT PATH to establish
      # its condition 2, and that nested probe must not be timed on its own
      # account: its nanoseconds are already inside this skip's interval, so
      # counting it again would credit the same time to two classes and the
      # decomposition would stop summing. Removing the `metadataProbeDepth`
      # guard leaves every other case in this file green -- the double count
      # is ~100 ns against a loop of milliseconds, far inside the slack the
      # disjointness sum allows -- so this equality is the only thing that
      # catches it.
      check recordedInputRevalidateStats().checks == 1
      resetOutputStateCheckStats()
      check storeAbsenceSkipNanoStats() == 0

  test "the four classes are disjoint sub-intervals of the loop":
    ## The hazard this closes is a one-line edit: crediting a check to two
    ## classes, or letting the store-absence arm's nested condition-2 probe be
    ## timed a second time on its own account. Nothing about the resulting
    ## numbers looks wrong -- every row stays positive and plausible -- and
    ## the decomposition silently stops summing, which is the error that sends
    ## a milestone after a term twice.
    ##
    ## The check is arithmetic, not a threshold: the class accumulators are
    ## timed over sub-intervals of the revalidation loop below, and disjoint
    ## sub-intervals of an interval cannot sum to more than it. It therefore
    ## cannot go red on a slow machine -- only on an overlap.
    ##
    ## The record carries a mixture of all the reachable classes and 400
    ## inputs, so the classes are a LARGE share of the loop; with a handful of
    ## inputs the loop's own machinery would dominate and double-counting
    ## would still fit inside it.
    let dir = getTempDir() / "repro-mac4-disjoint-6f3a1c"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)

    var inputs: seq[FileFingerprint] = @[]
    for i in 0 ..< 200:
      let p = dir / ("present" & $i & ".h")
      writeFile(p, "#pragma once // " & $i & "\n")
      inputs.add(observeFile(p, ffpTimestamp))
    # Absent paths OUTSIDE the store, so they take the warm-revalidate arm,
    # and absent paths INSIDE one, so they take the skip arm.
    for i in 0 ..< 100:
      inputs.add(absentInput(dir / ("absent" & $i & ".h")))
    let storePath = anExistingStoreOutputPath()
    if storePath.len > 0:
      for i in 0 ..< 100:
        inputs.add(absentInput(storePath / "absent-6f3a1c" / ("x" & $i & ".h")))
    var record = ActionResultRecord(policy: ffpTimestamp)
    record.inputs = inputs

    resetOutputStateCheckStats()
    var cache = initFileMetadataCache()
    let started = getMonoTime()
    # TWICE, over the same cache. The second pass is what makes the
    # current-run-hit arm a real share of the loop; repeating the inputs
    # inside ONE record does not, because `hotMetadataRecordInputsUnchanged`
    # de-duplicates them before the check and they never reach the cache.
    check hotMetadataRecordInputsUnchanged([record], addr cache)
    check hotMetadataRecordInputsUnchanged([record], addr cache)
    let elapsed = (getMonoTime() - started).inNanoseconds

    let stats = cache.metadataStats()
    # The premise: this loop really did take every arm. Without it the sum
    # below is trivially satisfied.
    check stats.warmRevalidated > 0
    check stats.currentRunHits > 0
    check stats.warmRevalidateNanos > 0
    check stats.currentRunHitNanos > 0
    if storePath.len > 0:
      check storeAbsenceSkipStats() > 0
      check storeAbsenceSkipNanoStats() > 0

    let loop = recordedInputRevalidateStats()
    # Exactly the OUTERMOST checks: every input, twice, and nothing else. The
    # store-absence arm makes a nested probe per skip, and if those were
    # timed on their own account the sum below would double-count them --
    # at ~100 ns each against a loop of milliseconds, comfortably inside the
    # slack, so the sum alone cannot see it and this equality must.
    check loop.checks == record.inputs.len * 2
    let classSum = stats.currentRunHitNanos + stats.coldStatNanos +
      stats.warmRevalidateNanos + storeAbsenceSkipNanoStats()
    # Disjoint classes inside the loop, and the loop inside the call.
    check classSum <= loop.nanos
    check loop.nanos <= elapsed

  test "the slow-probe tail row is wired and is reset":
    ## The row that stops the average being read as the population. On the
    ## fixture this milestone was measured on, ONE probe of 4,659 carried
    ## 87% of the revalidation loop, and `total / count` reported 4 us for a
    ## population whose worst member was 16 ms. `> 0` on the max is all that
    ## can be asserted without asserting a duration; the threshold row is
    ## asserted to be EMPTY here, because a local temp-directory probe must
    ## never reach a millisecond and a test that expected it to would be the
    ## duration assertion this file refuses to make.
    let dir = getTempDir() / "repro-mac4-slow-6f3a1c"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let present = dir / "present.h"
    writeFile(present, "#pragma once\n")

    resetOutputStateCheckStats()
    check slowMetadataProbeStats().slowestNanos == 0
    check slowMetadataProbeStats().slowestPath.len == 0
    check slowMetadataProbeStats().slowProbes == 0

    var cache = initFileMetadataCache()
    let record = recordWith(presentInput(present))
    check hotMetadataRecordInputsUnchanged([record], addr cache)
    let slow = slowMetadataProbeStats()
    # Wired: a monotonic clock cannot report zero across a real `lstat`.
    check slow.slowestNanos > 0
    # And it names the path, which is the whole point of a max over an
    # average: a duration with no identity cannot be acted on.
    check slow.slowestPath == present
    check slow.slowProbes == 0

    resetOutputStateCheckStats()
    check slowMetadataProbeStats().slowestNanos == 0
    check slowMetadataProbeStats().slowestPath.len == 0
