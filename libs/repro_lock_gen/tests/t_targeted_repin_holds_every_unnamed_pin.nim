## The two rules of a targeted re-pin, tested as the library procs that hold
## them: which pins the solve is given (`holdCommittedPins`), and which lock
## entries the result may change (`mergeRepinnedLock`).
##
## Spec: reprobuild-pm/spec/Locking-And-Solver.md §"Targeted re-pin". Issue:
## reprobuild-pm/issues/2026-10-14-declaring-a-sibling-producer-imports-its-
## toolchain-floor-into-the-consumers-committed-lock-solve.md.
##
## The end-to-end path (real CLI, real provider, real solve) is
## `tests/integration/t_lock_refresh_repin_clears_a_conflict_from_a_newly_
## declared_producer.nim`. This file covers the edges that fixture does not
## reach cheaply: a gated edge, a develop-observed package, a held variant, a
## committed entry the current solve no longer has, a lifted store dep, and a
## certificate-policy snapshot.
##
## Test-double policy: NO mocks, doubles, or fakes. Real `PackageDecl` /
## `VariantDecl` values from the solver's own constructors, and real lock
## documents through the real `repro_lock` writer and reader.

import std/[strutils, unittest]

import repro_lock
import repro_lock_gen
import repro_solver

proc lockWith(packages: openArray[(string, string)];
              variants: openArray[(string, string)] = [];
              deps: seq[LockedDep] = @[];
              policy = ""): LockedDependencies =
  result = LockedDependencies(schema: SolvedGraphLockSchemaV2,
    platform: "arm64-macosx", optimal: true, inputsDigest: "fnv1a64:old",
    deps: deps, certificatePolicySection: policy)
  for (name, version) in packages:
    result.packages.add(LockedPackage(name: name, version: version,
      source: name, selection: ssSelected))
  for (name, value) in variants:
    result.variants.add(LockedVariant(name: name, value: value))

proc vcsDep(name, path, revision: string): LockedDep =
  LockedDep(name: name, path: path,
    coordinates: Coordinates(kind: ckVcs, revision: revision),
    integrity: "git-sha1:" & revision, visibility: "public")

proc storeDep(name, version, hash: string): LockedDep =
  LockedDep(name: name, coordinates: Coordinates(kind: ckStore,
    storeHash: hash), integrity: "blake3:" & hash, version: version)

proc pinnedVersion(req: LockGenerationRequest; name: string): string =
  for p in req.packages:
    if p.name == name and p.pinned: return p.versions[0]
  ""

proc noCrossRepo(pkg: string): bool = false

suite "holdCommittedPins":

  test "every committed pin is held except the named ones":
    var req = LockGenerationRequest(
      variants: @[newBoolVariant("releaseBuild")],
      packages: @[
        newPackage("app", ["0.1.0"], [newDependency("nim", ">=1.6 <3.0"),
          newDependency("bash", ">=4")]),
        newPackage("bash", ["4.0.0", "5.0.0"]),
        newPackage("nim", ["1.6.0", "2.2.0"])])
    let committed = lockWith({"app": "0.1.0", "bash": "4.0.0",
      "nim": "1.6.0"}, {"releaseBuild": "false"})
    holdCommittedPins(req, committed, ["nim"], "/x/repro.lock", noCrossRepo)
    check req.pinnedVersion("bash") == "4.0.0"
    check req.pinnedVersion("app") == "0.1.0"
    # The named package is left to the solve, with its candidates intact.
    check req.pinnedVersion("nim") == ""
    for p in req.packages:
      if p.name == "nim": check p.versions == @["1.6.0", "2.2.0"]
    check req.variants[0].pinnedValue == "false"

  test "a held pin contradicting an unconditional range is its conflict":
    var req = LockGenerationRequest(packages: @[
      newPackage("producer_pkg", ["0.1.0"], [newDependency("bash", ">=5")]),
      newPackage("bash", ["4.0.0", "5.0.0"]),
      newPackage("nim", ["1.6.0", "2.2.0"])])
    let committed = lockWith({"bash": "4.0.0", "nim": "1.6.0"})
    var message = ""
    try:
      holdCommittedPins(req, committed, ["nim"], "/x/repro.lock",
        proc (pkg: string): bool = pkg == "producer_pkg")
    except ELockConflict as err:
      message = err.msg
    checkpoint(message)
    check "'bash'" in message
    check "/x/repro.lock" in message
    check "repro lock refresh --repin=bash" in message
    check "cross-repo producer" in message

  test "a gated range and a develop-observed package are not checked":
    # A gated arm may be off BECAUSE of the pin; a develop checkout's version
    # is observed and layers above the lock. Neither is a conflict, and the
    # observed version is not overwritten by the lock's.
    var req = LockGenerationRequest(packages: @[
      newPackage("app", ["0.1.0"], [
        newConditionalDependency("bash", ">=5", "useNewBash", "true"),
        newDependency("producer", ">=9")]),
      newPackage("bash", ["4.0.0", "5.0.0"]),
      newPinnedPackage("producer", "0.3.0")])
    let committed = lockWith({"bash": "4.0.0", "producer": "0.0.0"})
    holdCommittedPins(req, committed, ["nim"], "/x/repro.lock", noCrossRepo)
    check req.pinnedVersion("bash") == "4.0.0"
    check req.pinnedVersion("producer") == "0.3.0"

  test "a held variant outside its declared universe is refused":
    var req = LockGenerationRequest(variants: @[
      newEnumVariant("mode", ["fast", "safe"])])
    let committed = lockWith([], {"mode": "turbo"})
    expect ELockConflict:
      holdCommittedPins(req, committed, ["nim"], "/x/repro.lock", noCrossRepo)

suite "mergeRepinnedLock":

  test "only named entries change; additions are added; nothing is removed":
    let root = vcsDep("app", ".", "aaaa")
    let sibling = vcsDep("producer", "../producer", "bbbb")
    let committed = lockWith(
      {"app": "0.1.0", "bash": "4.0.0", "gone": "1.0.0", "nim": "1.6.0"},
      {"releaseBuild": "false"},
      @[root, sibling, storeDep("nim", "1.6.0", "old")],
      policy = "[certificate_policy]\nname = \"p\"\n")
    let freshRoot = vcsDep("app", ".", "cccc")
    let generated = lockWith(
      {"app": "0.1.0", "bash": "5.0.0", "nim": "2.2.0",
       "producer_pkg": "0.1.0"},
      {"releaseBuild": "false", "newFlag": "true"},
      @[freshRoot, vcsDep("producer", "../producer", "dddd"),
        storeDep("nim", "2.2.0", "new")])
    let merged = mergeRepinnedLock(committed, generated, ["nim"])
    var versions: seq[string]
    for p in merged.packages: versions.add(p.name & "=" & p.version)
    check versions == @["app=0.1.0", "bash=4.0.0", "gone=1.0.0",
      "nim=2.2.0", "producer_pkg=0.1.0"]
    var variants: seq[string]
    for v in merged.variants: variants.add(v.name & "=" & v.value)
    check variants == @["newFlag=true", "releaseBuild=false"]
    check merged.inputsDigest == generated.inputsDigest
    check merged.certificatePolicySection == committed.certificatePolicySection
    # The sibling revision pin is carried even though the solve observed a
    # different revision; the root's own entry and the re-pinned package's
    # lifted store entry follow the solve.
    var deps: seq[string]
    for d in merged.deps:
      case d.coordinates.kind
      of ckVcs: deps.add(d.name & "@" & d.coordinates.revision)
      of ckStore: deps.add(d.name & "#" & d.coordinates.storeHash)
      else: deps.add(d.name)
    check deps == @["app@cccc", "producer@bbbb", "nim#new"]

  test "a sibling the committed lock does not pin is added, not dropped":
    # The issue's case: the producer was declared after the lock was written,
    # so the lock holds no revision pin for it. The re-pin must record one,
    # or a lock-pinned build has no revision to fetch the producer at.
    let committed = lockWith({"app": "0.1.0", "nim": "1.6.0"}, [],
      @[vcsDep("app", ".", "aaaa"), vcsDep("other", "../other", "eeee")])
    let generated = lockWith(
      {"app": "0.1.0", "nim": "2.2.0", "producer_pkg": "0.1.0"}, [],
      @[vcsDep("app", ".", "aaaa"), vcsDep("other", "../other", "ffff"),
        vcsDep("producer", "../producer", "dddd")])
    let merged = mergeRepinnedLock(committed, generated, ["nim"])
    var deps: seq[string]
    for d in merged.deps: deps.add(d.name & "@" & d.coordinates.revision)
    # `other` is carried at its committed revision; `producer` is added.
    check deps == @["app@aaaa", "other@eeee", "producer@dddd"]

  test "a sibling recorded under another name or path is not added again":
    # Name OR path identifies a committed pin: a renamed checkout at the same
    # path, or the same repo at a moved path, is the committed sibling, held
    # at its committed revision rather than recorded a second time. The root
    # entry is refreshed, never duplicated.
    let committed = lockWith({"app": "0.1.0", "nim": "1.6.0"}, [],
      @[vcsDep("app", ".", "aaaa"), vcsDep("other", "../other", "eeee"),
        vcsDep("tools", "../tools", "1111")])
    let generated = lockWith({"app": "0.1.0", "nim": "2.2.0"}, [],
      @[vcsDep("app", ".", "cccc"), vcsDep("other-renamed", "../other", "ffff"),
        vcsDep("tools", "../moved/tools", "2222"),
        vcsDep("producer", "../producer", "dddd"),
        vcsDep("producer", "../producer", "dddd")])
    let merged = mergeRepinnedLock(committed, generated, ["nim"])
    var deps: seq[string]
    for d in merged.deps:
      deps.add(d.name & ":" & d.path & "@" & d.coordinates.revision)
    check deps == @["app:.@cccc", "other:../other@eeee",
      "tools:../tools@1111", "producer:../producer@dddd"]
