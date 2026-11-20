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
##
## The third suite holds the release to its own state directory. Generation
## ids are content-addressed and name no state directory, so two state
## directories that use one store and apply the same profile have the same
## id. Each holds the generation through a `profile` root of its own
## (`profileRootId`): when one of them quarantines the id and releases its
## root, the generation the other still has as current keeps its prefixes
## through store GC (reprobuild-pm
## `spec/Home-Profile-Generations-And-State.md` §"Store GC Interaction").
## The state directory is named by a key it carries
## (`<state-dir>/store-root-key`), not by its path, so it keeps its roots
## when it is moved. The suite also covers what a build that named roots by
## the bare id left: the apply gives such a generation its own root
## (`ensureGenerationRoots`) and never deletes the bare one. Same production writers, procs and GC as the
## second suite; a bare-id root is written with the store's `registerRoot`,
## as the earlier `writeGeneration` did. No mocks.
## Recorded from reprobuild-pm
## `issues/2026-11-18-home-profile-store-roots-are-shared-by-state-directories-that-share-a-store.md`.

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
                         prefix: PrefixIdBytes;
                         more: seq[PrefixIdBytes] = @[]): string =
  ## What apply step 9 writes: `pointer.bin`, plus the `profile` root named
  ## by the state directory and the generation id (`profileRootId`), holding
  ## the generation's realized prefixes.
  var envelope = PointerEnvelope(schemaVersion: 1'u16,
    activationTimestamp: 1_794_960_000'i64, hostIdentity: "test-host")
  for i in 0 ..< GenerationIdSize: envelope.generationId[i] = fill
  var d: Digest256
  for i in 0 ..< 32: d[i] = prefix[i]
  envelope.realizedPrefixIds = @[d]
  for extra in more:
    for i in 0 ..< 32: d[i] = extra[i]
    envelope.realizedPrefixIds.add(d)
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
    check profileRootId(stateDir, fresh) notin rootIds(storeRoot)
    check profileRootId(stateDir, previous) in rootIds(storeRoot)
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

    check profileRootId(stateDir, stale) notin rootIds(storeRoot)
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

    check profileRootId(stateDir, again) in rootIds(storeRoot)
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

    check profileRootId(stateDir, fresh) in rootIds(storeRoot)
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

    check profileRootId(stateDir, other) in rootIds(storeRoot)

proc applyReconcilesRoots(stateDir, storeRoot: string) =
  ## What the apply runs after its switch and on its no-op exit.
  var store = openStore(storeRoot)
  defer: store.close()
  discard ensureGenerationRoots(stateDir, store)
  discard releaseQuarantinedRoots(stateDir, store)

proc quarantineCommitted(stateDir, storeRoot: string; fill: byte;
                         prefix: PrefixIdBytes): string =
  ## An apply of generation `fill` killed between its commit (step 9) and
  ## its switch (step 10), then the next apply's recovery.
  result = idHex(fill)
  writeMarker(stateDir, result, "in-progress", preexisting = false)
  var store = openStore(storeRoot)
  doAssert writeHeldGeneration(stateDir, store, fill, prefix) == result
  store.close()
  doAssert recoverPartialApply(stateDir).len == 1

suite "state directories that share a store hold their own generations":

  test "one state directory quarantining an id leaves the other's hold":
    # Both state directories applied the same profile: one generation id,
    # one prefix. It is current in `keeper`; `crasher` was killed between
    # its commit and its switch, and its next apply releases what it
    # quarantined.
    let base = freshStateDir()
    defer: removeDir(base)
    let storeRoot = base / "store"
    let keeper = base / "keeper"
    let crasher = base / "crasher"
    var store = openStore(storeRoot)
    let shared = seedPrefix(store, 0x21)
    let same = writeHeldGeneration(keeper, store, 0xB1, shared)
    writeCurrentGenerationId(keeper, same)
    let previous = writeHeldGeneration(crasher, store, 0xB2,
      seedPrefix(store, 0x22))
    writeCurrentGenerationId(crasher, previous)
    store.close()
    check quarantineCommitted(crasher, storeRoot, 0xB1, shared) == same

    applyReconcilesRoots(crasher, storeRoot)

    check profileRootId(crasher, same) notin rootIds(storeRoot)
    check profileRootId(keeper, same) in rootIds(storeRoot)
    check (not reclaimed(storeRoot, shared))

  test "the prefix is reclaimed once every state directory dropped the id":
    # The hold is per state directory, not a leak: when the second one
    # quarantines the id too, nothing holds the prefix.
    let base = freshStateDir()
    defer: removeDir(base)
    let storeRoot = base / "store"
    let first = base / "first"
    let second = base / "second"
    var store = openStore(storeRoot)
    let shared = seedPrefix(store, 0x23)
    for dir in [first, second]:
      let previous = writeHeldGeneration(dir, store, 0xB3,
        seedPrefix(store, 0x24))
      writeCurrentGenerationId(dir, previous)
    store.close()

    discard quarantineCommitted(first, storeRoot, 0xB4, shared)
    discard quarantineCommitted(second, storeRoot, 0xB4, shared)
    applyReconcilesRoots(first, storeRoot)
    check (not reclaimed(storeRoot, shared))
    applyReconcilesRoots(second, storeRoot)

    check reclaimed(storeRoot, shared)

  test "a state directory keeps its roots when it is moved":
    # The key is in the directory, not derived from its path: after a move
    # the generations hold through the same roots, and a generation
    # quarantined after the move has its root released.
    let base = freshStateDir()
    defer: removeDir(base)
    let storeRoot = base / "store"
    let before = base / "before"
    let after = base / "after"
    var store = openStore(storeRoot)
    let kept = seedPrefix(store, 0x29)
    let dropped = seedPrefix(store, 0x2A)
    let current = writeHeldGeneration(before, store, 0xBA, kept)
    writeCurrentGenerationId(before, current)
    store.close()
    let rootBefore = profileRootId(before, current)

    moveDir(extendedPath(before), extendedPath(after))
    writeCurrentGenerationId(after, current)
    let gone = quarantineCommitted(after, storeRoot, 0xBB, dropped)
    applyReconcilesRoots(after, storeRoot)

    check profileRootId(after, current) == rootBefore
    check rootIds(storeRoot) == @[rootBefore]
    check profileRootId(after, gone) notin rootIds(storeRoot)
    check reclaimed(storeRoot, dropped)
    check (not reclaimed(storeRoot, kept))

  test "two state directories never share a key":
    let base = freshStateDir()
    defer: removeDir(base)
    let one = stateDirRootKey(base / "one")
    check one.len == StoreRootKeyHexLen
    check stateDirRootKey(base / "one") == one
    check stateDirRootKey(base / "two") != one
    check profileRootId(base / "one", idHex(0xB5)) ==
      "home/" & one & "/" & idHex(0xB5)

  test "a state directory without a key releases nothing and gets no key":
    # It registered no root under a key, so it has none to delete; the
    # release never creates the key.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let bare = idHex(0xBC)
    store.registerRoot(bare, rkProfile)
    createDir(extendedPath(abortedDir(stateDir) / (bare & "-in-progress-1")))

    check releaseQuarantinedRoots(stateDir, store).len == 0
    store.close()

    check (not fileExists(storeRootKeyPath(stateDir)))
    check rootIds(storeRoot) == @[bare]

  test "re-committing a generation keeps the holds its root already has":
    # A re-apply of an earlier profile commits an id whose root is there.
    # Replacing the root row would drop every hold until each is attached
    # again, a window another state directory's store GC can run in. The
    # extra hold stands for any hold the root had: it survives only if the
    # row was not replaced.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let held = seedPrefix(store, 0x2B)
    let extra = seedPrefix(store, 0x2C)
    let again = writeHeldGeneration(stateDir, store, 0xBD, held)
    store.attachPrefixToRoot(profileRootId(stateDir, again), extra)

    check writeHeldGeneration(stateDir, store, 0xBD, held) == again

    check store.prefixesHeldByRoot(profileRootId(stateDir, again)).len == 2
    store.close()

  test "a generation naming a prefix the store no longer indexes gets its root":
    # The hold on the missing prefix is skipped; the one after it is
    # attached.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    var missing: PrefixIdBytes
    for i in 0 ..< 32: missing[i] = 0x2D
    let present = seedPrefix(store, 0x2E)
    let orphaned = writeHeldGeneration(stateDir, store, 0xBE, missing,
      @[present])
    writeCurrentGenerationId(stateDir, orphaned)
    store.deleteRoot(profileRootId(stateDir, orphaned))
    store.close()

    applyReconcilesRoots(stateDir, storeRoot)

    store = openStore(storeRoot)
    check store.prefixesHeldByRoot(profileRootId(stateDir, orphaned)) ==
      @[present]
    store.close()
    check (not reclaimed(storeRoot, present))

  test "a malformed key is moved aside, not overwritten":
    # The key is not regenerable: what the file held is kept, and the
    # release, which never creates a key, leaves it alone.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    writeFile(extendedPath(storeRootKeyPath(stateDir)), "not a key\n")

    check existingStateDirRootKey(stateDir) == ""
    check readFile(extendedPath(storeRootKeyPath(stateDir))) == "not a key\n"

    let key = stateDirRootKey(stateDir)

    check key.len == StoreRootKeyHexLen
    check existingStateDirRootKey(stateDir) == key
    var aside: seq[string]
    for kind, entry in walkDir(stateDir, relative = true):
      if entry.startsWith(StoreRootKeyFileName & ".malformed-"):
        aside.add(entry)
    check aside.len == 1
    check readFile(extendedPath(stateDir / aside[0])) == "not a key\n"

  test "a generation an earlier build committed gets its own root":
    # An earlier build named the root by the bare generation id. The apply
    # registers the state directory's own root beside it, with the
    # generation's prefixes, and leaves the bare one.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let held = seedPrefix(store, 0x25)
    let legacy = writeHeldGeneration(stateDir, store, 0xB6, held)
    writeCurrentGenerationId(stateDir, legacy)
    store.deleteRoot(profileRootId(stateDir, legacy))
    store.registerRoot(legacy, rkProfile)
    store.attachPrefixToRoot(legacy, held)
    store.close()

    applyReconcilesRoots(stateDir, storeRoot)

    store = openStore(storeRoot)
    check store.prefixesHeldByRoot(profileRootId(stateDir, legacy)) == @[held]
    check legacy in rootIds(storeRoot)
    store.deleteRoot(legacy)
    store.close()
    check (not reclaimed(storeRoot, held))

  test "a bare-id root is not released for a quarantined id":
    # Another state directory that has not run this build yet may hold the
    # same generation through nothing but the bare-id root.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let shared = seedPrefix(store, 0x26)
    let previous = writeHeldGeneration(stateDir, store, 0xB7,
      seedPrefix(store, 0x27))
    writeCurrentGenerationId(stateDir, previous)
    let same = idHex(0xB8)
    store.registerRoot(same, rkProfile)
    store.attachPrefixToRoot(same, shared)
    store.close()
    check quarantineCommitted(stateDir, storeRoot, 0xB8, shared) == same

    applyReconcilesRoots(stateDir, storeRoot)

    check profileRootId(stateDir, same) notin rootIds(storeRoot)
    check same in rootIds(storeRoot)
    check (not reclaimed(storeRoot, shared))

  test "a root left without its holds is completed":
    # A kill between the root row and its holds.
    let stateDir = freshStateDir()
    defer: removeDir(stateDir)
    let storeRoot = stateDir / "store"
    var store = openStore(storeRoot)
    let held = seedPrefix(store, 0x28)
    let torn = writeHeldGeneration(stateDir, store, 0xB9, held)
    writeCurrentGenerationId(stateDir, torn)
    store.deleteRoot(profileRootId(stateDir, torn))
    store.registerRoot(profileRootId(stateDir, torn), rkProfile)
    store.close()

    applyReconcilesRoots(stateDir, storeRoot)

    check (not reclaimed(storeRoot, held))
