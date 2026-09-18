## M5 SELF-HOST — two reprobuild versions live in ONE store, each held by the
## project that pins it, and removing a pin is what makes its version
## collectable.
##
## THE FOUR CLAUSES OF THE MILESTONE GATE, AS PROPERTIES OF THE STORE:
##
##   1. two projects pinning different versions resolve to different prefixes;
##   2. both prefixes are resident in one store at the same time;
##   3. the pin that holds each one is derived from that project's committed
##      `repro.lock` — edit the lock, and the root follows;
##   4. remove a pin, re-derive the roots, and the version it held becomes
##      unreachable, so `gc` quarantines it and names the reclaimed path.
##
## EVERY CLAUSE IS ALSO SHOWN ABLE TO FAIL. Clause 1 would pass by accident if
## both projects resolved the same way, so the two prefixes are required to
## DIFFER before anything else is asserted. Clause 4 would pass vacuously
## against a gc that collects everything, so the case that removes ONE pin
## also asserts the OTHER version survives — and a control case asserts that
## with BOTH pins in place gc collects NOTHING.
##
## Test-double policy: no mocks and no fakes of the store. A real
## `repro_local_store` on a real temp directory, real `repro.lock` documents
## written by the real `repro_lock` writer, real `installSelfImage` /
## `attachPinRoot` / `prunePinRoots` / `Store.gc`. The reprobuild "images"
## are directory trees with a `bin/repro` AND a `bin/reprobuild` file in them:
## this suite never executes one, so their CONTENT is irrelevant and inventing
## a build here would test the Nim compiler rather than the store. The two
## NAMES are not irrelevant — see `makeImage`.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_core/cli_images
import repro_lock
import repro_local_store
import repro_selfhost
import repro_selfhost/install

const Platform = "amd64-linux"

proc lockPinning(version: string): string =
  ## A committed lock pinning `reprobuild <version>` with a store coordinate,
  ## produced by the real writer + the real MO-11 lift.
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  sol.packages["reprobuild"] = version
  var ld = lockedDepsFromSolved(solutionToLock(sol, Platform, ""))
  for i in 0 ..< ld.packages.len:
    if ld.packages[i].name == "reprobuild":
      ld.packages[i].source = "store"
  ld.deps = lockedDepsFromPackages(ld.packages, Platform)
  serializeLockedDependencies(ld)

proc lockPinningNothing(): string =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  sol.packages["nim"] = "2.2.0"
  let ld = lockedDepsFromSolved(solutionToLock(sol, Platform, ""))
  serializeLockedDependencies(ld)

proc makeImage(dir, marker: string): string =
  ## A minimal reprobuild image tree: BOTH `<dir>/bin/repro[.exe]` and
  ## `<dir>/bin/reprobuild[.exe]`, plus a file whose bytes differ per version,
  ## so two images are genuinely two trees.
  ##
  ## BOTH, because the CLI is two images and `installSelfImage` REFUSES a tree
  ## carrying only one of them: `bin/repro` is the thin daemon client and
  ## `bin/reprobuild` is the engine it hands every non-routable invocation to,
  ## so a prefix with only the first realizes cleanly and then cannot run a
  ## single command. A fixture planting only `bin/repro` therefore does not
  ## test a tolerated layout — it makes this whole suite raise out of
  ## `newScenario`, which is exactly what it did until this line named the
  ## second image.
  createDir(dir / "bin")
  for name in [selfExecutableName(), reprobuildEngineExeName()]:
    writeFile(dir / "bin" / name, "image " & marker & " " & name & "\n")
  writeFile(dir / "VERSION", marker & "\n")
  dir

proc residentVersions(storeRoot: string): seq[string] =
  for row in listSelfPrefixes(storeRoot):
    result.add(row.version)

proc prefixDirs(storeRoot: string): seq[string] =
  for row in listSelfPrefixes(storeRoot):
    result.add(row.realizedPath)

type Scenario = object
  root: string
  store: string
  projA: string
  projB: string

proc newScenario(): Scenario =
  result.root = createTempDir("repro-m5-store-", "")
  result.store = result.root / "store"
  result.projA = result.root / "projA"
  result.projB = result.root / "projB"
  createDir(result.store)
  createDir(result.projA)
  createDir(result.projB)
  writeFile(result.projA / "repro.lock", lockPinning("0.1.4"))
  writeFile(result.projB / "repro.lock", lockPinning("0.1.5"))
  discard installSelfImage(result.store, "0.1.4", Platform,
    makeImage(result.root / "img-0.1.4", "0.1.4"))
  discard installSelfImage(result.store, "0.1.5", Platform,
    makeImage(result.root / "img-0.1.5", "0.1.5"))
  doAssert attachPinRoot(result.store, result.projA,
    selfPrefixId(selfPinForProject(result.projA)))
  doAssert attachPinRoot(result.store, result.projB,
    selfPrefixId(selfPinForProject(result.projB)))

suite "two pinned versions, one store":

  test "two projects pinning different versions resolve to different prefixes":
    let s = newScenario()
    defer: removeDir(s.root)
    let pinA = selfPinForProject(s.projA)
    let pinB = selfPinForProject(s.projB)
    check pinA.state == spsPinned
    check pinB.state == spsPinned
    check pinA.version == "0.1.4"
    check pinB.version == "0.1.5"
    # The clause-1 failure mode: two projects that happen to resolve the same
    # way would satisfy "each got its pin" by accident.
    check selfPrefixRelativePath(pinA) != selfPrefixRelativePath(pinB)
    # Each prefix holds the image installed for THAT version, so the
    # resolution is not merely to two distinct names.
    check readFile(s.store / selfPrefixRelativePath(pinA) / "VERSION").strip() ==
      "0.1.4"
    check readFile(s.store / selfPrefixRelativePath(pinB) / "VERSION").strip() ==
      "0.1.5"

  test "both versions are resident in one store at the same time":
    let s = newScenario()
    defer: removeDir(s.root)
    let resident = residentVersions(s.store)
    check resident.len == 2
    check "0.1.4" in resident
    check "0.1.5" in resident
    # One store: both realized paths sit under the same root, and the index
    # that lists them is one index.
    for path in prefixDirs(s.store):
      check dirExists(s.store / path)

  test "with both pins in place, gc collects nothing":
    ## The control for clause 4. A gc that reclaims regardless of roots would
    ## pass the removal case below and fail here.
    let s = newScenario()
    defer: removeDir(s.root)
    discard prunePinRoots(s.store)
    var store = openStore(s.store)
    let report = store.gc(graceSeconds = 0)
    store.close()
    check report.quarantined.len == 0
    check residentVersions(s.store).len == 2

suite "removing a pin makes its version collectable":

  test "dropping one project's pin reclaims exactly that version":
    let s = newScenario()
    defer: removeDir(s.root)
    let pinB = selfPinForProject(s.projB)
    let bPath = selfPrefixRelativePath(pinB)
    let aPath = selfPrefixRelativePath(selfPinForProject(s.projA))
    check dirExists(s.store / bPath)

    # THE PIN IS REMOVED THE ONLY WAY A PROJECT CAN REMOVE IT: by editing
    # its committed lock. Nothing tells the store; the store finds out by
    # re-reading the lock.
    writeFile(s.projB / "repro.lock", lockPinningNothing())

    let outcomes = prunePinRoots(s.store)
    var droppedForB = false
    var keptForA = false
    for o in outcomes:
      if o.rootId == pinRootIdFor(s.projB):
        check o.action == praDropped
        droppedForB = true
      elif o.rootId == pinRootIdFor(s.projA):
        check o.action == praKept
        keptForA = true
    check droppedForB
    check keptForA

    var store = openStore(s.store)
    let report = store.gc(graceSeconds = 0)
    store.close()
    # Exactly one prefix moved, and it is B's.
    check report.quarantined.len == 1
    check report.quarantined[0].version == "0.1.5"
    check report.reclaimed.len == 1
    check report.reclaimed[0].contains("0.1.5")
    check not dirExists(s.store / bPath)
    # ... and A's survived, so the sweep was selective rather than total.
    check dirExists(s.store / aPath)
    check residentVersions(s.store) == @["0.1.4"]

  test "deleting the project entirely drops its pin root too":
    ## A pin root names a path; a project that is gone pins nothing.
    let s = newScenario()
    defer: removeDir(s.root)
    removeDir(s.projB)
    let outcomes = prunePinRoots(s.store)
    var dropped = false
    for o in outcomes:
      if o.rootId == pinRootIdFor(s.projB):
        check o.action == praDropped
        dropped = true
    check dropped
    var store = openStore(s.store)
    let report = store.gc(graceSeconds = 0)
    store.close()
    check report.quarantined.len == 1
    check report.quarantined[0].version == "0.1.5"

  test "moving a pin to another version repoints the root":
    let s = newScenario()
    defer: removeDir(s.root)
    # B switches from 0.1.5 to the version A already uses.
    writeFile(s.projB / "repro.lock", lockPinning("0.1.4"))
    let outcomes = prunePinRoots(s.store)
    var repointed = false
    for o in outcomes:
      if o.rootId == pinRootIdFor(s.projB):
        check o.action == praRepointed
        check o.prefixIdHex ==
          prefixIdHex(selfPrefixId(selfPinForProject(s.projA)))
        repointed = true
    check repointed
    var store = openStore(s.store)
    let report = store.gc(graceSeconds = 0)
    store.close()
    # 0.1.5 is now held by nobody; 0.1.4 is held by both.
    check report.quarantined.len == 1
    check report.quarantined[0].version == "0.1.5"
    check residentVersions(s.store) == @["0.1.4"]

suite "an installed image is refused when it is not an image":

  test "a source tree with no bin/repro is refused, not realized":
    let root = createTempDir("repro-m5-badimage-", "")
    defer: removeDir(root)
    let store = root / "store"
    createDir(store)
    createDir(root / "empty")
    var refused = false
    try:
      discard installSelfImage(store, "0.1.4", Platform, root / "empty")
    except ValueError as err:
      refused = true
      check err.msg.contains("bin/")
    check refused
    check listSelfPrefixes(store).len == 0
