## The home generation markers never disappear while they are replaced.
##
## `current` and each generation's `pointer.bin` are authoritative
## operational state (reprobuild-pm `spec/Configuration-Storage-Principles.md`
## §"Authoritative Operational State"): they are the only record of which
## generation is active and of what it realized, and nothing regenerates them.
## Replacing one must therefore leave the old version or the new one in place
## at every instant, so that a crash or kill at any point loses neither. The
## writers used to remove the old marker and then create the new one, and a
## crash between those two steps left no `current` at all.
##
## The test replaces each marker many times while a second thread keeps
## checking that it exists. A remove-then-create writer is caught by the
## observer within a few hundred replacements; an atomic rename is never
## caught. It also checks that no temporary file is left behind, that the
## last write is the one in place, and that the temporary file of a write
## that died before its rename is swept by the next write once it is too old
## to belong to a write in progress, while a fresh one is kept.
##
## No mocks: it drives the library's production writers against the real
## filesystem in a scratch state directory.
##
## Recorded as reprobuild-pm issue
## `issues/2026-11-12-binary-content-is-regenerable-conflicts-with-binary-state-that-is-authoritative.md`.

import std/[os, unittest, atomics, strutils, times]
from repro_core/paths import extendedPath

import repro_home_generations
from repro_test_support import testCaseScratchSlug

const Replacements = 4000

let ScratchRoot = "build/test-tmp/home-generation-markers" / testCaseScratchSlug()

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

var watching: Atomic[bool]
var vanished: Atomic[int]
var observations: Atomic[int]

proc markerPresent(path: string): bool =
  symlinkExists(path) or fileExists(path)

proc watch(path: string) {.thread.} =
  ## Count every observation in which ``path`` does not exist.
  while watching.load:
    if not markerPresent(path):
      vanished.atomicInc
    observations.atomicInc

proc samplePointer(stamp: int64): PointerEnvelope =
  result = PointerEnvelope(schemaVersion: 1'u16,
    activationTimestamp: stamp, hostIdentity: "markers-host")
  for i in 0 ..< 32:
    result.intentSnapshotDigest[i] = byte(i)
    result.activationManifestDigest[i] = byte(0x80 + i)
  result.generationId = computeGenerationId(result.intentSnapshotDigest,
    result.hostIdentity, result.activationTimestamp)

proc leftoverTemps(dir: string): seq[string] =
  for kind, path in walkDir(dir):
    if path.extractFilename.endsWith(".tmp"):
      result.add(path)

proc observeWhile(path: string; replace: proc(i: int)):
    tuple[observations, vanished: int] =
  ## Run ``replace`` `Replacements` times while a thread watches ``path``, and
  ## return how often the thread looked and how often ``path`` was missing.
  ## The caller checks the counts, so a failure is reported by its test.
  vanished.store(0)
  observations.store(0)
  watching.store(true)
  var observer: Thread[string]
  createThread(observer, watch, path)
  for i in 0 ..< Replacements:
    replace(i)
  watching.store(false)
  joinThread(observer)
  (observations.load, vanished.load)

suite "home generation markers are replaced atomically":
  test "current always names a generation while it moves":
    let stateDir = absolutePath(ScratchRoot / "current")
    resetDir(stateDir)
    for gen in ["gen-a", "gen-b"]:
      createDir(extendedPath(generationDir(stateDir, gen)))
    writeCurrentGenerationId(stateDir, "gen-a")
    let current = currentPath(stateDir)
    let seen = observeWhile(current, proc(i: int) =
      writeCurrentGenerationId(stateDir, if i mod 2 == 0: "gen-b" else: "gen-a"))
    checkpoint("current was missing in " & $seen.vanished & " of " &
      $seen.observations & " observations")
    check seen.observations > 0
    check seen.vanished == 0
    check readCurrentGenerationId(stateDir) == "gen-a"
    check leftoverTemps(stateDir).len == 0

  test "pointer.bin is never missing while it is rewritten":
    let dir = absolutePath(ScratchRoot / "pointer")
    resetDir(dir)
    let pointer = dir / PointerFileName
    writePointerFile(pointer, samplePointer(1700000000'i64))
    let seen = observeWhile(pointer, proc(i: int) =
      writePointerFile(pointer, samplePointer(1700000001'i64 + int64(i))))
    checkpoint("pointer.bin was missing in " & $seen.vanished & " of " &
      $seen.observations & " observations")
    check seen.observations > 0
    check seen.vanished == 0
    check readPointerFile(pointer).activationTimestamp ==
      1700000000'i64 + int64(Replacements)
    check leftoverTemps(dir).len == 0

  test "a crashed write's temporary file is swept by the next write":
    let stateDir = absolutePath(ScratchRoot / "sweep")
    resetDir(stateDir)
    createDir(extendedPath(generationDir(stateDir, "gen-a")))
    let current = currentPath(stateDir)
    let pointer = generationDir(stateDir, "gen-a") / PointerFileName
    # What a writer killed between creating its temporary file and renaming
    # it leaves behind, named as `repro_core/durable_replace` names them.
    var stale, fresh: seq[string]
    for marker in [current, pointer]:
      let (dir, name) = splitPath(marker)
      let old = dir / ("." & name & ".1-1-1.tmp")
      let young = dir / ("." & name & ".2-2-2.tmp")
      writeFile(old, "torn")
      writeFile(young, "in progress")
      setLastModificationTime(old, getTime() - initDuration(hours = 2))
      stale.add(old)
      fresh.add(young)
    writeCurrentGenerationId(stateDir, "gen-a")
    writePointerFile(pointer, samplePointer(1700000000'i64))
    for path in stale:
      checkpoint("stale temporary " & path)
      check not fileExists(path)
    for path in fresh:
      checkpoint("fresh temporary " & path)
      check fileExists(path)
    check readCurrentGenerationId(stateDir) == "gen-a"
    check readPointerFile(pointer).activationTimestamp == 1700000000'i64
