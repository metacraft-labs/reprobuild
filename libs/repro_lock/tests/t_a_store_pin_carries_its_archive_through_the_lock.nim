## A store-sourced lock entry carries the upstream archive it is realized
## from -- URL, SHA-256, archive type, binary or source -- through a write and
## a read of the committed lock, and an entry without one is written exactly
## as before.
##
## Reprobuild-specs Distribution-And-Packaging.milestones.org, M5 "pin the
## provider-compile toolchain": a pinned Nim of any released version is
## provisioned automatically, verified against a digest that is part of the
## pin. The digest is only part of the pin if the lock keeps it.
##
## THE PROPERTIES, EACH WITH THE DEFECT IT CATCHES:
##
##   * an archive pin survives serialize -> parse field for field, and a
##     second serialize is byte-identical. Catches a writer that emits a key
##     the reader does not read (the pin silently lost on the next refresh)
##     and nondeterministic output;
##   * an entry WITHOUT an archive writes no `archive_` key, so a lock
##     committed before archive pins existed re-serializes byte-identically.
##     Catches every existing lock acquiring a diff on its next write;
##   * the archive is not part of the lock identity. Catches a lock identity
##     that moves when only the acquisition record does;
##   * the store coordinate's own tamper check is unchanged by it.
##
## Test-double policy: no mocks. Every document is produced by the real
## `repro_lock` writer and read by the real reader.

import std/[strutils, tables, unittest]

import repro_lock

const Platform = "amd64-windows"

proc solvedLock(packages: openArray[(string, string, string)]):
    LockedDependencies =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version, _) in packages:
    sol.packages[name] = version
  result = lockedDepsFromSolved(solutionToLock(sol, Platform, ""))
  for i in 0 ..< result.packages.len:
    for (name, _, source) in packages:
      if result.packages[i].name == name:
        result.packages[i].source = source
  result.deps = lockedDepsFromPackages(result.packages, Platform)

const Archive = LockedArchive(
  url: "https://nim-lang.org/download/nim-2.2.8_x64.zip",
  sha256: "11fe2415a64a791b899cc78e2eeacdde93b5f122f2fabc447db36d38002bfb8c",
  archiveType: "zip",
  build: LockedArchiveBinary)

proc depNamed(ld: LockedDependencies; name: string): LockedDep =
  for d in ld.deps:
    if d.name == name:
      return d
  raise newException(KeyError, "no dep " & name)

suite "an archive pin round-trips through the committed lock":

  test "every field survives a write and a read, and rewrites identically":
    var ld = solvedLock([("nim", "2.2.8", "store")])
    check ld.deps.len == 1
    ld.deps[0].archive = Archive
    let once = serializeLockedDependencies(ld)
    check once.contains("archive_url = \"" & Archive.url & "\"")
    check once.contains("archive_sha256 = \"" & Archive.sha256 & "\"")
    check once.contains("archive_type = \"zip\"")
    check once.contains("archive_build = \"binary\"")
    let back = parseLockedDependencies(once)
    let dep = back.depNamed("nim")
    check dep.archive == Archive
    check dep.archive.isPinned
    check dep.coordinates.kind == ckStore
    check dep.coordinates.storeHash ==
      solvedPackageStoreHash("nim", "2.2.8", Platform)
    check serializeLockedDependencies(back) == once

  test "a source archive pin round-trips with its build kind":
    var ld = solvedLock([("nim", "2.0.16", "store")])
    ld.deps[0].archive = LockedArchive(
      url: "https://nim-lang.org/download/nim-2.0.16.tar.xz",
      sha256: "0".repeat(64), archiveType: "tar.xz",
      build: LockedArchiveSource)
    let back = parseLockedDependencies(serializeLockedDependencies(ld))
    check back.depNamed("nim").archive.build == LockedArchiveSource
    check back.depNamed("nim").archive.archiveType == "tar.xz"

  test "an entry without an archive is written exactly as before":
    let ld = solvedLock([("nim", "2.2.8", "store"),
                         ("reprobuild", "0.2.9", "store")])
    let text = serializeLockedDependencies(ld)
    check not text.contains("archive_")
    let back = parseLockedDependencies(text)
    check not back.depNamed("nim").archive.isPinned
    check serializeLockedDependencies(back) == text
    # The exact pre-archive spelling of a store entry: the last key is
    # still `tags`, closed by the brace.
    check text.contains("participation = \"\", depends = \"\", tags = \"\" }")

  test "the archive does not move the lock identity":
    var pinned = solvedLock([("nim", "2.2.8", "store")])
    let bare = pinned
    pinned.deps[0].archive = Archive
    check lockIdentityOf(pinned) == lockIdentityOf(bare)
    check lockIdentityOf(parseLockedDependencies(
      serializeLockedDependencies(pinned))) == lockIdentityOf(bare)

  test "the archive sits beside an unchanged content-addressed coordinate":
    var ld = solvedLock([("nim", "2.2.8", "store")])
    ld.deps[0].archive = Archive
    let dep = parseLockedDependencies(serializeLockedDependencies(ld)).
      depNamed("nim")
    check dep.integrity == solvedPackageStoreIntegrity("nim", "2.2.8",
      Platform)
