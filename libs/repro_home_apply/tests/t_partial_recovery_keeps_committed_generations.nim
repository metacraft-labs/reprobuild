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

import std/[os, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_home_apply/partial_recovery
import repro_home_generations

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
