## M5 "pin the provider-compile toolchain", rule 3: the bootstrap's decision,
## branch by branch.
##
## `decideHandOver` is pure over (pin, store root, running image, own
## version, marker), so every branch is driven here without spawning a
## process. The end-to-end proof that the ENGINE acts on it is
## `tests/integration/t_the_bootstrap_hands_over_to_the_pinned_reprobuild`.
##
## THE BRANCHES, AND THE DEFECT EACH ONE'S TEST CATCHES:
##
##   * no pin -> run here. Catches a bootstrap that refuses to work in every
##     unpinned project;
##   * a different pinned version -> hand over, to `<prefix>/bin/repro`,
##     naming `<prefix>/bin/reprobuild` as the engine. Catches the defect the
##     rule exists for: the bootstrap evaluating a recipe it is not pinned to;
##   * version-equal -> run here (the task's "version-equal case skips the
##     hand-over");
##   * the running image IS the prefix's engine -> run here, even when its
##     compiled version differs from the pin's label. Catches the pinned
##     image handing over to itself forever;
##   * the marker names this prefix but the running image is not it ->
##     refuse with the recursion code. Catches both the loop and the
##     redirected exec that would evaluate the recipe with the wrong image;
##   * a tampered pin -> refuse with the resolution code, never run.
##
## Test-double policy: no mocks. The prefix is realized into a real
## `repro_local_store` by `installSelfImage`, from a tree of plain files.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_core/cli_images
import repro_lock
import repro_selfhost
import repro_selfhost/handover
import repro_selfhost/install

const
  Platform = "amd64-linux"
  Pinned = "0.1.4-pinned"
  Bootstrap = "0.2.2"

proc lockPinning(version: string): string =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  sol.packages["reprobuild"] = version
  var ld = lockedDepsFromSolved(solutionToLock(sol, Platform, ""))
  for i in 0 ..< ld.packages.len:
    ld.packages[i].source = "store"
  ld.deps = lockedDepsFromPackages(ld.packages, Platform)
  serializeLockedDependencies(ld)

type Scenario = object
  root, store, project, bootstrapImage: string
  pin: SelfPin

proc newScenario(install = true): Scenario =
  result.root = createTempDir("repro-m5-handover-", "")
  result.store = result.root / "store"
  result.project = result.root / "proj"
  createDir(result.store)
  createDir(result.project)
  writeFile(result.project / "repro.lock", lockPinning(Pinned))
  if install:
    let tree = result.root / "img"
    createDir(tree / "bin")
    for name in [selfExecutableName(), reprobuildEngineExeName()]:
      writeFile(tree / "bin" / name, "image " & name & "\n")
    discard installSelfImage(result.store, Pinned, Platform, tree)
  createDir(result.root / "boot")
  result.bootstrapImage = result.root / "boot" / reprobuildEngineExeName()
  writeFile(result.bootstrapImage, "bootstrap\n")
  result.pin = selfPinForProject(result.project)

suite "the bootstrap hands over only to a reprobuild it is not":

  test "no pin: run here":
    let s = newScenario()
    defer: removeDir(s.root)
    var sol = UnifiedSolution(variants: initTable[string, string](),
      packages: initTable[string, string](), optimal: true)
    sol.packages["nim"] = "2.2.0"
    writeFile(s.project / "repro.lock", serializeLockedDependencies(
      lockedDepsFromSolved(solutionToLock(sol, Platform, ""))))
    let d = decideHandOver(selfPinForProject(s.project), s.store,
      s.bootstrapImage, Bootstrap, "")
    check d.action == hoaRunHere

  test "a different pinned version: hand over to that prefix":
    let s = newScenario()
    defer: removeDir(s.root)
    check s.pin.state == spsPinned
    let d = decideHandOver(s.pin, s.store, s.bootstrapImage, Bootstrap, "")
    checkpoint(d.reason)
    check d.action == hoaHandOver
    check d.resident
    let prefix = selfPrefixAbsolutePath(s.store, s.pin)
    check d.prefix == prefix
    check d.entryPoint == prefix / "bin" / selfExecutableName()
    check d.engine == prefix / "bin" / reprobuildEngineExeName()
    check d.prefixIdHex == prefixIdHex(selfPrefixId(s.pin))

  test "a pinned version that is not resident is still a hand-over, flagged":
    let s = newScenario(install = false)
    defer: removeDir(s.root)
    let d = decideHandOver(s.pin, s.store, s.bootstrapImage, Bootstrap, "")
    check d.action == hoaHandOver
    check not d.resident

  test "version-equal: run here":
    let s = newScenario()
    defer: removeDir(s.root)
    let d = decideHandOver(s.pin, s.store, s.bootstrapImage, Pinned, "")
    check d.action == hoaRunHere
    check d.reason.contains("own version")

  test "the running image is the prefix's engine: run here, whatever its version":
    let s = newScenario()
    defer: removeDir(s.root)
    let engine = selfPrefixAbsolutePath(s.store, s.pin) / "bin" /
      reprobuildEngineExeName()
    # The marker a real hand-over sets does not change this answer.
    for marker in ["", prefixIdHex(selfPrefixId(s.pin))]:
      let d = decideHandOver(s.pin, s.store, engine, Bootstrap, marker)
      check d.action == hoaRunHere
      check d.reason.contains("running as the pinned image")

  test "the marker names this prefix but the image is not it: refuse, no loop":
    let s = newScenario()
    defer: removeDir(s.root)
    let d = decideHandOver(s.pin, s.store, s.bootstrapImage, Bootstrap,
      prefixIdHex(selfPrefixId(s.pin)))
    check d.action == hoaRefuse
    check d.exitCode == HandOverExitRecursion
    check d.reason.contains(ResolvedEnvVar)

  test "a marker for ANOTHER prefix does not stop a hand-over":
    ## A build action of one pinned project running `repro` in a second
    ## project inherits the first project's marker. The second project's pin
    ## must still be honoured.
    let s = newScenario()
    defer: removeDir(s.root)
    let d = decideHandOver(s.pin, s.store, s.bootstrapImage, Bootstrap,
      "0000000000000000000000000000000000000000000000000000000000000000")
    check d.action == hoaHandOver

  test "a tampered pin: refuse with the resolution code":
    let s = newScenario()
    defer: removeDir(s.root)
    let honest = readFile(s.project / "repro.lock")
    writeFile(s.project / "repro.lock", honest.replace(
      "version = \"" & Pinned & "\"", "version = \"9.9.9\""))
    let d = decideHandOver(selfPinForProject(s.project), s.store,
      s.bootstrapImage, Bootstrap, "")
    check d.action == hoaRefuse
    check d.exitCode == HandOverExitResolutionFailed

suite "the hand-over changes only what it must in the environment":

  test "the marker, the pinned engine, no REPRO_FULL_CLI, and the compiler":
    let s = newScenario()
    defer: removeDir(s.root)
    let d = decideHandOver(s.pin, s.store, s.bootstrapImage, Bootstrap, "")
    let edits = handOverEnvironment(d, "C:/nim/bin/nim.exe")
    var byName = initTable[string, EnvEdit]()
    for e in edits:
      byName[e.name] = e
    check byName.len == 4
    check byName[ResolvedEnvVar].value == d.prefixIdHex
    check byName[PublicCliEnvVar].value == d.engine
    check byName[FullCliEnvVar].remove
    check byName[NimCompilerEnvVar].value == "C:/nim/bin/nim.exe"

  test "without a compiler pin the compiler variable is left alone":
    let s = newScenario()
    defer: removeDir(s.root)
    let d = decideHandOver(s.pin, s.store, s.bootstrapImage, Bootstrap, "")
    for e in handOverEnvironment(d, ""):
      check e.name != NimCompilerEnvVar
