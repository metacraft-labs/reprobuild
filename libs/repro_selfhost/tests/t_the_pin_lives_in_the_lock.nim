## M5 SELF-HOST — the reprobuild a project runs is decided by its committed
## `repro.lock` and by nothing else.
##
## THE PROPERTY, AND WHY IT NEEDS A TEST RATHER THAN A README. The milestone's
## gate says twice that the pin must go through the standard dependency
## pinning and that "no `.reprobuild-version`-style file exists". A grep for
## such a file is the weak form of that claim: it passes against an
## implementation that reads a side channel nobody thought to grep for, and it
## passes vacuously against one that reads nothing at all. The strong form is
## the one below — resolution is a pure function of the lock BYTES, so:
##
##   * change the pinned version in the lock and the answer changes;
##   * change the platform in the lock and the answer changes;
##   * offer a lock that pins reprobuild with no coordinate and resolution
##     REFUSES, naming the remedy, rather than guessing;
##   * offer a lock that pins no reprobuild at all and resolution refuses
##     differently, because the two situations have different remedies;
##   * put a file called `.reprobuild-version` next to the lock and it makes
##     no difference whatsoever.
##
## The last case is the one that would catch a side channel added later. It is
## written as a real file on disk with a real version string in it, next to a
## real lock, so "the launcher ignores it" is measured rather than assumed.
##
## Test-double policy: no mocks. The locks are written by the real
## `repro_lock` writer (`serializeLockedDependencies` over a
## `LockedDependencies` built by the real `solutionToLock` +
## `lockedDepsFromPackages` lift), which is exactly what `repro lock refresh`
## emits. The store paths come from the real `repro_local_store` naming
## contract.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_lock
import repro_local_store/prefix_paths
import repro_local_store/realization_hash
import repro_selfhost

proc lockBytes(packages: openArray[(string, string, string)];
               platform: string): string =
  ## A real committed lock pinning `packages` as (name, version, source).
  ## `solutionToLock` builds the solved half; `lockedDepsFromPackages`
  ## performs the MO-11 lift that turns a store-sourced package into a
  ## `LockedDep` with coordinates — the same two calls `repro lock refresh`
  ## makes through `repro_lock_gen.renderLockDocument`.
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version, _) in packages:
    sol.packages[name] = version
  let solved = solutionToLock(sol, platform, "")
  var ld = lockedDepsFromSolved(solved)
  # `solutionToLock` stamps `source: name` (the bare definition identity).
  # Overwrite with the provenance the scenario declares, exactly as the
  # generation path's MO-11 overlay does.
  for i in 0 ..< ld.packages.len:
    for (name, _, source) in packages:
      if ld.packages[i].name == name:
        ld.packages[i].source = source
  ld.deps = lockedDepsFromPackages(ld.packages, platform)
  serializeLockedDependencies(ld)

const Platform = "amd64-linux"

suite "the reprobuild pin is an ordinary locked dependency":

  test "a store-sourced reprobuild package resolves to a store prefix":
    let text = lockBytes(
      [("nim", "2.2.0", "nim"), ("reprobuild", "0.1.4", "store")], Platform)
    # The lock the writer produced really does carry the coordinate; if it
    # did not, everything below would be asserting about a lock shape that
    # never occurs.
    check text.contains("coord_kind = \"store\"")
    check text.contains("name = \"reprobuild\"")

    let pin = pinFromLockText(text, "/w/repro.lock", "/w")
    check pin.state == spsPinned
    check pin.version == "0.1.4"
    check pin.platform == Platform
    check pin.storeHash == solvedPackageStoreHash("reprobuild", "0.1.4",
      Platform)
    check pin.integrity == "blake3:" & pin.storeHash

    # The resolved location is the STORE's own arithmetic, not a private
    # scheme: recompute it here from `repro_local_store` directly.
    let expectedId = computeRealizationHash("reprobuild", "0.1.4",
      "reprobuild-self", "blake3:" & pin.storeHash, "bin/" &
      selfExecutableName())
    check selfPrefixRelativePath(pin) ==
      prefixRelativePath("reprobuild", "0.1.4", expectedId)
    check selfPrefixRelativePath(pin).startsWith("prefixes/reprobuild/0.1.4-")

  test "a different pinned version resolves somewhere else":
    ## The discriminating half. A resolver that ignored the lock and answered
    ## a constant would pass every assertion above.
    let a = pinFromLockText(
      lockBytes([("reprobuild", "0.1.4", "store")], Platform), "/w/repro.lock",
      "/w")
    let b = pinFromLockText(
      lockBytes([("reprobuild", "0.1.5", "store")], Platform), "/w/repro.lock",
      "/w")
    check a.state == spsPinned
    check b.state == spsPinned
    check a.version != b.version
    check a.storeHash != b.storeHash
    check selfPrefixRelativePath(a) != selfPrefixRelativePath(b)

  test "the same version on a different platform resolves somewhere else":
    let a = pinFromLockText(
      lockBytes([("reprobuild", "0.1.4", "store")], "amd64-linux"),
      "/w/repro.lock", "/w")
    let b = pinFromLockText(
      lockBytes([("reprobuild", "0.1.4", "store")], "amd64-windows"),
      "/w/repro.lock", "/w")
    check a.storeHash != b.storeHash
    check selfPrefixRelativePath(a) != selfPrefixRelativePath(b)

  test "a bare definition identity is REFUSED, with the remedy named":
    ## The failure this milestone is most likely to produce silently: the
    ## project declares `uses: "reprobuild >=X"` but never declares where the
    ## artifact comes from, so the lock records a version and no coordinate.
    ## Resolving that by guessing a store path would exec whatever happened
    ## to be at the guessed address.
    let text = lockBytes([("reprobuild", "0.1.4", "reprobuild")], Platform)
    check not text.contains("coord_kind = \"store\"")
    let pin = pinFromLockText(text, "/w/repro.lock", "/w")
    check pin.state == spsNotAddressable
    check pin.version == "0.1.4"
    check pin.detail.contains("packageSource")
    check pin.detail.contains("repro lock refresh")

  test "a lock that pins no reprobuild says so differently":
    let text = lockBytes([("nim", "2.2.0", "nim")], Platform)
    let pin = pinFromLockText(text, "/w/repro.lock", "/w")
    check pin.state == spsNoPin
    check pin.detail.contains("does not pin reprobuild")

  test "unreadable lock bytes refuse rather than resolving to anything":
    let pin = pinFromLockText("not a lock at all\n", "/w/repro.lock", "/w")
    check pin.state == spsNoProject
    check pin.detail.contains("could not be read")

suite "resolution reads the lock and no other file":

  test "a .reprobuild-version file beside the lock changes nothing":
    ## The gate's "no `.reprobuild-version`-style file exists" clause, in its
    ## strong form. Two candidate side channels are planted with a DIFFERENT
    ## version from the lock's; if the resolver consulted either one the
    ## answer would move.
    let ws = createTempDir("repro-m5-sidechannel-", "")
    defer: removeDir(ws)
    writeFile(ws / "repro.lock",
      lockBytes([("reprobuild", "0.1.4", "store")], Platform))

    let fromLockAlone = selfPinForProject(ws)
    check fromLockAlone.state == spsPinned
    check fromLockAlone.version == "0.1.4"

    writeFile(ws / ".reprobuild-version", "9.9.9\n")
    writeFile(ws / ".tool-versions", "reprobuild 9.9.9\n")
    let withSideChannels = selfPinForProject(ws)
    check withSideChannels.state == spsPinned
    check withSideChannels.version == "0.1.4"
    check withSideChannels.storeHash == fromLockAlone.storeHash

    # ... and editing the LOCK does move it, so the test is not merely
    # observing a resolver that ignores everything.
    writeFile(ws / "repro.lock",
      lockBytes([("reprobuild", "0.1.5", "store")], Platform))
    let afterLockEdit = selfPinForProject(ws)
    check afterLockEdit.version == "0.1.5"
    check afterLockEdit.storeHash != fromLockAlone.storeHash

  test "the project root is the nearest enclosing lock":
    let ws = createTempDir("repro-m5-walkup-", "")
    defer: removeDir(ws)
    createDir(ws / "a" / "b" / "c")
    writeFile(ws / "repro.lock",
      lockBytes([("reprobuild", "0.1.4", "store")], Platform))
    writeFile(ws / "a" / "b" / "repro.lock",
      lockBytes([("reprobuild", "0.1.5", "store")], Platform))
    check selfPinFrom(ws / "a" / "b" / "c").version == "0.1.5"
    check selfPinFrom(ws / "a").version == "0.1.4"

  test "no enclosing lock is reported as no project":
    let ws = createTempDir("repro-m5-nolock-", "")
    defer: removeDir(ws)
    createDir(ws / "deep")
    # A directory with a recipe but no lock is NOT a resolvable project: the
    # pin lives in the lock, so a recipe alone has nothing to resolve.
    writeFile(ws / "repro.nim", "## not a lock\n")
    let pin = selfPinFrom(ws / "deep")
    check pin.state == spsNoProject

suite "a lock whose coordinate disagrees with its content is refused":
  ## THE GAP THIS CLOSES. `ckStore` is content-addressed: `store_hash` is a
  ## BLAKE3 over (name, version, platform) and `integrity` is that same value
  ## tagged with its algorithm. Reading those two fields without checking
  ## them against the identity they claim to address is not reading a
  ## content-addressed coordinate — and the failure it leaves behind is
  ## misdiagnosed rather than absent. A hand-edited version used to reach the
  ## store as a perfectly well-formed pin, miss, and be reported as "that
  ## version is not installed", which points the reader at `repro self
  ## install` when the real defect is in the lock in front of them. On a host
  ## that happened to hold a prefix at the forged address it would not even
  ## have missed.
  ##
  ## Each case below tampers ONE field of a lock that is otherwise exactly
  ## what `repro lock refresh` wrote, and the first case asserts the
  ## untampered bytes still resolve — so these are assertions about the edit,
  ## not about a reader that refuses everything.

  proc honest(version = "0.1.4"; platform = Platform): string =
    lockBytes([("reprobuild", version, "store")], platform)

  test "the untampered lock this suite edits does resolve":
    let pin = pinFromLockText(honest(), "/w/repro.lock", "/w")
    check pin.state == spsPinned
    check pin.version == "0.1.4"

  test "editing the version by hand is refused, not resolved":
    ## The exact edit the gate performs with `sed`, and the one a user is
    ## most likely to make: change the number, expect the pin to move.
    let text = honest().replace("version = \"0.1.4\"", "version = \"0.1.9\"")
    check text.contains("0.1.9")
    let pin = pinFromLockText(text, "/w/repro.lock", "/w")
    check pin.state == spsTampered
    check pin.version == "0.1.9"
    # The refusal NAMES the defect, and names it differently from the
    # "prefix not installed" sentence it used to be reported as.
    check pin.detail.contains("was not written by `repro lock refresh`")
    check not pin.detail.contains("not installed")
    # Both the address it carries and the address that identity really has
    # are in the message, because a reader cannot act on either alone.
    check pin.detail.contains(
      solvedPackageStoreHash("reprobuild", "0.1.4", Platform))
    check pin.detail.contains(
      solvedPackageStoreHash("reprobuild", "0.1.9", Platform))

  test "forging the store address is refused":
    let real = solvedPackageStoreHash("reprobuild", "0.1.4", Platform)
    let forged = "00000000000000000000000000000000" &
                 "00000000000000000000000000000000"
    check real.len == forged.len
    let text = honest().replace(
      "store_hash = \"" & real & "\"", "store_hash = \"" & forged & "\"")
    check text.contains(forged)
    let pin = pinFromLockText(text, "/w/repro.lock", "/w")
    check pin.state == spsTampered
    check pin.storeHash == forged

  test "an integrity that does not match its own store hash is refused":
    ## The address and the integrity are the SAME value in this coordinate
    ## kind, so a lock in which they differ is self-contradictory even before
    ## the identity is recomputed. Checked separately because a reader that
    ## only recomputed the address would accept this one.
    let real = solvedPackageStoreHash("reprobuild", "0.1.4", Platform)
    let text = honest().replace(
      "integrity = \"blake3:" & real & "\"",
      "integrity = \"blake3:" & solvedPackageStoreHash(
        "reprobuild", "0.1.5", Platform) & "\"")
    let pin = pinFromLockText(text, "/w/repro.lock", "/w")
    check pin.state == spsTampered
    check pin.storeHash == real

  test "re-stamping the platform is refused":
    ## A lock solved on one platform, re-labelled as another. The address is
    ## the one the original platform produced, so it no longer addresses the
    ## identity the document now claims.
    let text = honest().replace(
      "platform = \"" & Platform & "\"", "platform = \"amd64-windows\"")
    let pin = pinFromLockText(text, "/w/repro.lock", "/w")
    check pin.state == spsTampered
    check pin.platform == "amd64-windows"

  test "a coordinate for a DIFFERENT version is refused rather than followed":
    ## The dangerous shape: both halves of the document are internally
    ## plausible — a real version, a real store address — but they belong to
    ## different solves. Nothing about the resulting directory would look
    ## wrong, and the image found there would be the wrong reprobuild.
    let text = honest().replace(
      solvedPackageStoreHash("reprobuild", "0.1.4", Platform),
      solvedPackageStoreHash("reprobuild", "0.1.5", Platform))
    let pin = pinFromLockText(text, "/w/repro.lock", "/w")
    check pin.state == spsTampered
    check pin.version == "0.1.4"
    check pin.storeHash ==
      solvedPackageStoreHash("reprobuild", "0.1.5", Platform)

  test "every honest version and platform this suite can write still resolves":
    ## The control that keeps the check from being a blanket refusal: the
    ## same writer, over a spread of identities, must produce locks that all
    ## pass.
    for version in ["0.1.4", "0.1.5", "1.0.0", "0.2.0-rc1"]:
      for platform in ["amd64-linux", "amd64-windows", "arm64-macos"]:
        let pin = pinFromLockText(honest(version, platform),
          "/w/repro.lock", "/w")
        check pin.state == spsPinned
        check pin.version == version
        check pin.platform == platform
