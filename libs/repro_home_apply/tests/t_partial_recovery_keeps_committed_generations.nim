## Partial-apply recovery quarantines only an apply's unfinished generation,
## never a committed one (reprobuild-pm
## `spec/Home-Profile-Generations-And-State.md` §"Partial Apply Recovery").
##
## An apply writes `apply.in-progress` naming its generation before it
## creates anything, commits the generation (`pointer.bin`), moves `current`
## to it and only then removes the marker. A crash after `current` moved
## leaves the marker naming the ACTIVE generation; a crash during a re-apply
## of an earlier profile (A, then B, then A again: generation ids are
## content-addressed) leaves it naming a generation retention already kept.
## Quarantining either takes away a committed generation: the first leaves
## `current` pointing at a directory that is gone, so plan and rollback fail
## closed; the second deletes a rollback target.
##
## The state a crash leaves is built with the production writers
## (`writeMarker`, `writePointerFile`, `writeCurrentGenerationId`) and
## `recoverPartialApply` is the production function the apply runs first.
## No mocks. The crash itself is not reproduced by killing a process: the
## window between `rotateCurrent` and `clearMarker` has no kill hook, and the
## state on disk after a kill there is exactly what these cases write.
##
## Recovery also runs on every apply with no marker present, so its
## sweep of pointerless generations must not mistake a pointer it merely
## cannot read (a newer schema) for an unfinished one.
##
## Recorded from reprobuild-pm
## `issues/2026-11-12-home-apply-moves-current-before-the-generation-is-committed.md`.
##
## The second suite holds recovery to the other half of quarantining: a
## generation set aside under `.aborted/` no longer holds its prefixes. Step
## 9 (`writeGeneration`) registered a `profile` root named by the generation
## id; a kill between the commit and the switch left that root in
## `index.db` for good, so store GC never reclaimed the prefixes although no
## generation under `generations/` accounted for them (reprobuild-pm
## `spec/Home-Profile-Generations-And-State.md` §"Partial Apply Recovery"
## and §"Store GC Interaction"). The generations and the store are written
## with the production writers (`writeGeneration`, `insertPrefixOrIgnore`),
## recovery and the release are the production procs the apply runs
## (`recoverPartialApply` at its start, `releaseQuarantinedRoots` after its
## switch), and the outcome is judged by the production store GC (`gc`).
## No mocks.
## Recorded from reprobuild-pm
## `issues/2026-11-18-quarantined-home-generation-keeps-its-store-root.md`.

import std/[os, strutils, tempfiles, times, unittest]
from repro_core/paths import extendedPath

import repro_home_apply/partial_recovery
import repro_home_generations
import repro_local_store

proc freshStateDir(): string =
  ## A state directory of this case's own, removed when the case ends.
  createTempDir("repro-partial-recovery-", "")

proc idHex(fill: byte): string =
  var g: GenerationId
  for i in 0 ..< GenerationIdSize: g[i] = fill
  generationIdHex(g)

proc commitGeneration(stateDir: string; fill: byte): string =
  ## A committed generation: its directory with a valid `pointer.bin`.
  result = idHex(fill)
  var envelope = PointerEnvelope(schemaVersion: 1'u16,
    activationTimestamp: 1_794_960_000'i64, hostIdentity: "test-host")
  for i in 0 ..< GenerationIdSize: envelope.generationId[i] = fill
  createDir(extendedPath(generationDir(stateDir, result)))
  writePointerFile(pointerPath(stateDir, result), envelope)

suite "partial-apply recovery keeps committed generations":

  test "a crash after current moved keeps the active generation":
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    writeCurrentGenerationId(stateDir, commitGeneration(stateDir, 0x11))
    let fresh = idHex(0x22)
    # The apply writes its marker before it creates the directory...
    writeMarker(stateDir, fresh, "in-progress",
      preexisting = dirExists(extendedPath(generationDir(stateDir, fresh))))
    # ...commits the generation, moves `current`, and dies before it
    # removes the marker.
    discard commitGeneration(stateDir, 0x22)
    writeCurrentGenerationId(stateDir, fresh)

    let quarantined = recoverPartialApply(stateDir)

    check quarantined.len == 0
    check readCurrentGenerationId(stateDir) == fresh
    check fileExists(extendedPath(pointerPath(stateDir, fresh)))
    check (not readMarker(stateDir).present)

  test "a crashed re-apply keeps the earlier generation it re-applied":
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let a = commitGeneration(stateDir, 0x33)
    let b = commitGeneration(stateDir, 0x44)
    writeCurrentGenerationId(stateDir, b)
    # Applying profile A again: A's directory is already there.
    writeMarker(stateDir, a, "in-progress",
      preexisting = dirExists(extendedPath(generationDir(stateDir, a))))

    let quarantined = recoverPartialApply(stateDir)

    check quarantined.len == 0
    check fileExists(extendedPath(pointerPath(stateDir, a)))
    check readCurrentGenerationId(stateDir) == b
    check (not readMarker(stateDir).present)

  test "a crash before current moved still quarantines the new generation":
    # The control: what recovery is for. A generation this apply created
    # and never made current is quarantined, committed or not.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let previous = commitGeneration(stateDir, 0x55)
    writeCurrentGenerationId(stateDir, previous)
    let fresh = idHex(0x66)
    writeMarker(stateDir, fresh, "in-progress",
      preexisting = dirExists(extendedPath(generationDir(stateDir, fresh))))
    discard commitGeneration(stateDir, 0x66)

    let quarantined = recoverPartialApply(stateDir)

    check quarantined.len == 1
    check (not dirExists(extendedPath(generationDir(stateDir, fresh))))
    check readCurrentGenerationId(stateDir) == previous
    check (not readMarker(stateDir).present)

  test "a crashed re-apply of the current generation keeps it":
    # Drift made the apply re-run under the id `current` already names; it
    # died before its commit. The generation was current all along.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let active = commitGeneration(stateDir, 0x77)
    writeCurrentGenerationId(stateDir, active)
    writeMarker(stateDir, active, "in-progress",
      preexisting = dirExists(extendedPath(generationDir(stateDir, active))))

    let quarantined = recoverPartialApply(stateDir)

    check quarantined.len == 0
    check fileExists(extendedPath(pointerPath(stateDir, active)))
    check readCurrentGenerationId(stateDir) == active
    check (not readMarker(stateDir).present)

  test "an unreadable pointer is quarantined, except under current":
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let active = commitGeneration(stateDir, 0x88)
    writeCurrentGenerationId(stateDir, active)
    let torn = commitGeneration(stateDir, 0x99)
    writeFile(extendedPath(pointerPath(stateDir, torn)), "not an envelope")

    let quarantined = recoverPartialApply(stateDir)

    check quarantined.len == 1
    check (not dirExists(extendedPath(generationDir(stateDir, torn))))
    check dirExists(extendedPath(generationDir(stateDir, active)))

  test "a pointer from a newer schema is kept, not quarantined":
    # A newer `repro` wrote this generation; going back to an older build
    # must not move every rollback target aside. Only a torn or corrupt
    # pointer marks an unfinished generation.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let active = commitGeneration(stateDir, 0xAA)
    writeCurrentGenerationId(stateDir, active)
    let newer = commitGeneration(stateDir, 0xBB)
    var raw = readFile(extendedPath(pointerPath(stateDir, newer)))
    # Bytes 4..5 are the little-endian schema version after the magic.
    raw[4] = char(PointerSchemaVersion.int + 1)
    raw[5] = '\0'
    writeFile(extendedPath(pointerPath(stateDir, newer)), raw)

    let quarantined = recoverPartialApply(stateDir)

    check quarantined.len == 0
    check dirExists(extendedPath(generationDir(stateDir, newer)))

proc seedPrefix(store: var Store; tag: byte): PrefixIdBytes =
  ## A realized prefix: its directory under the store and its index row.
  for i in 0 ..< 32: result[i] = tag
  let relative = prefixRelativePath("pkg-" & $tag, "1.0", result)
  let abs = store.absolutePrefixPath(relative)
  createDir(extendedPath(abs))
  writeFile(extendedPath(abs / "payload"), "x")
  discard store.insertPrefixOrIgnore(PrefixRow(prefixId: result,
    packageName: "pkg-" & $tag, version: "1.0",
    realizedPath: relative.replace('\\', '/'), adapter: "tarball",
    receiptDigest: result, createdAtUnix: getTime().toUnix))

proc writeHeldGeneration(stateDir: string; store: var Store; fill: byte;
                         prefix: PrefixIdBytes): string =
  ## What apply step 9 writes: `pointer.bin`, plus the `profile` root named
  ## by the generation id holding the generation's realized prefixes.
  var envelope = PointerEnvelope(schemaVersion: 1'u16,
    activationTimestamp: 1_794_960_000'i64, hostIdentity: "test-host")
  for i in 0 ..< GenerationIdSize: envelope.generationId[i] = fill
  var d: Digest256
  for i in 0 ..< 32: d[i] = prefix[i]
  envelope.realizedPrefixIds = @[d]
  writeGeneration(stateDir, envelope, [fill], [fill, 1'u8], [fill, 2'u8],
    store)
  generationIdHex(envelope.generationId)

proc rootIds(storeRoot: string): seq[string] =
  var store = openStore(storeRoot)
  defer: store.close()
  for row in store.listRoots(): result.add(row.rootId)

proc reclaimed(storeRoot: string; prefix: PrefixIdBytes): bool =
  ## Whether store GC takes the prefix: true once no root holds it.
  var store = openStore(storeRoot)
  defer: store.close()
  let report = store.gc(graceSeconds = 0)
  for row in report.quarantined:
    if row.prefixId == prefix: return true
  false

proc recoverThenRelease(stateDir, storeRoot: string):
    seq[AbortedGenerationRecord] =
  ## What the apply runs: recovery at its start, the release after its
  ## switch.
  result = recoverPartialApply(stateDir)
  var store = openStore(storeRoot)
  defer: store.close()
  discard releaseQuarantinedRoots(stateDir, store)

suite "partial-apply recovery releases the store roots it quarantines":

  test "a generation committed but never switched to stops holding its prefixes":
    # Killed between step 9 (commit) and step 10 (switch).
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let kept = seedPrefix(store, 0x01)
    let orphan = seedPrefix(store, 0x02)
    let previous = writeHeldGeneration(stateDir, store, 0x11, kept)
    writeCurrentGenerationId(stateDir, previous)
    let fresh = idHex(0x22)
    writeMarker(stateDir, fresh, "in-progress", preexisting = false)
    check writeHeldGeneration(stateDir, store, 0x22, orphan) == fresh
    store.close()

    let quarantined = recoverThenRelease(stateDir, storeRoot)

    check quarantined.len == 1
    check fresh notin rootIds(storeRoot)
    check previous in rootIds(storeRoot)
    check reclaimed(storeRoot, orphan)
    check (not reclaimed(storeRoot, kept))

  test "a root an earlier recovery left behind is released":
    # A generation quarantined by a build without this step, or a kill
    # between the move and the release: the directory is under `.aborted/`
    # and the root is still registered. No marker is present.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let orphan = seedPrefix(store, 0x03)
    let previous = writeHeldGeneration(stateDir, store, 0x33,
      seedPrefix(store, 0x04))
    writeCurrentGenerationId(stateDir, previous)
    let stale = writeHeldGeneration(stateDir, store, 0x44, orphan)
    store.close()
    createDir(extendedPath(abortedDir(stateDir)))
    moveDir(extendedPath(generationDir(stateDir, stale)),
      extendedPath(abortedDir(stateDir) / (stale & "-in-progress-1")))

    discard recoverThenRelease(stateDir, storeRoot)

    check stale notin rootIds(storeRoot)
    check reclaimed(storeRoot, orphan)

  test "an id applied again since it was quarantined keeps its root":
    # Generation ids are content-addressed: the same profile applied
    # successfully after the crash recreates the directory and re-registers
    # the same root, which now holds a live generation's prefixes.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let held = seedPrefix(store, 0x05)
    let previous = writeHeldGeneration(stateDir, store, 0x55,
      seedPrefix(store, 0x06))
    writeCurrentGenerationId(stateDir, previous)
    let again = writeHeldGeneration(stateDir, store, 0x66, held)
    store.close()
    createDir(extendedPath(abortedDir(stateDir) / (again & "-in-progress-1")))

    discard recoverThenRelease(stateDir, storeRoot)

    check again in rootIds(storeRoot)
    check (not reclaimed(storeRoot, held))

  test "recovery alone keeps the root until the apply has switched":
    # Running the same profile again after the crash reproduces the id. The
    # apply re-uses the generation's prefixes, so they stay held from
    # recovery until its step 9 re-registers the root.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let held = seedPrefix(store, 0x07)
    let previous = writeHeldGeneration(stateDir, store, 0x77,
      seedPrefix(store, 0x08))
    writeCurrentGenerationId(stateDir, previous)
    let fresh = idHex(0x88)
    writeMarker(stateDir, fresh, "in-progress", preexisting = false)
    check writeHeldGeneration(stateDir, store, 0x88, held) == fresh
    store.close()

    check recoverPartialApply(stateDir).len == 1

    check fresh in rootIds(storeRoot)
    check (not reclaimed(storeRoot, held))

  test "a symlink is neither a quarantined generation nor a live one":
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let previous = writeHeldGeneration(stateDir, store, 0x99,
      seedPrefix(store, 0x09))
    writeCurrentGenerationId(stateDir, previous)
    let other = writeHeldGeneration(stateDir, store, 0xAA,
      seedPrefix(store, 0x0A))
    store.close()
    createDir(extendedPath(abortedDir(stateDir)))
    createSymlink(generationDir(stateDir, other),
      abortedDir(stateDir) / (other & "-in-progress-1"))

    discard recoverThenRelease(stateDir, storeRoot)

    check other in rootIds(storeRoot)
