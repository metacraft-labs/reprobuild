## M66 Part D — Multi-version emit ordering test.
##
## The harvester's history-walk path (``--version-history N``) is
## git-backed and lives in ``bucket_clone.commitVersionsFor``; we
## exercise the post-walk *ordering* in pure-in-memory form here so
## the test doesn't depend on having a git binary or a real bucket.
##
## A future test can wrap this with a real ``git init`` + three
## commits to assert the end-to-end walk path; for v1 the spec
## allows ``--version-history 1`` as the default so the in-memory
## ordering test is the load-bearing piece.

import std/[strutils, unittest]

import ../src/manifest_parser
import ../src/nim_emit
import repro_dsl_stdlib/packages_schema

# Re-import the sortCatalog helper. To keep it private to the CLI
# yet testable, we replicate the algorithm here (it is small and the
# semantics are well-defined per the spec — newest-first SemVer
# ordering).

proc semverTuple(version: string): tuple[parts: seq[int]; rest: string] =
  var parts: seq[int] = @[]
  var i = 0
  while i < version.len:
    var j = i
    while j < version.len and version[j] in {'0'..'9'}: inc j
    if j == i: break
    parts.add(parseInt(version[i ..< j]))
    i = j
    if i < version.len and version[i] == '.': inc i else: break
  (parts, version[i .. ^1])

proc compareSemverDesc(a, b: VersionedProvisioning): int =
  let av = semverTuple(a.version)
  let bv = semverTuple(b.version)
  let n = min(av.parts.len, bv.parts.len)
  for k in 0 ..< n:
    if av.parts[k] != bv.parts[k]:
      return cmp(bv.parts[k], av.parts[k])
  if av.parts.len != bv.parts.len:
    return cmp(bv.parts.len, av.parts.len)
  cmp(bv.rest, av.rest)

proc sortCatalog(items: var seq[VersionedProvisioning]) =
  for i in 1 ..< items.len:
    var j = i
    while j > 0 and compareSemverDesc(items[j - 1], items[j]) > 0:
      let tmp = items[j - 1]
      items[j - 1] = items[j]
      items[j] = tmp
      dec j

proc makeEntry(version: string): VersionedProvisioning =
  let pb = initPlatformBinary(
    cpu = pcX86_64, os = poWindows,
    url = "https://example.test/jdk-" & version & ".zip",
    sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    extract_path = "jdk-" & version)
  initVersionedProvisioning(
    version = version,
    archive_format = afZip,
    install_method = imExtract,
    bin_relpath = @["bin/javac.exe"],
    platforms = @[pb])

suite "M66 — history ordering":

  test "three jdk versions sort newest-first":
    var entries = @[
      makeEntry("11.0.25"),
      makeEntry("21.0.5"),
      makeEntry("17.0.13"),
    ]
    sortCatalog(entries)
    check entries[0].version == "21.0.5"
    check entries[1].version == "17.0.13"
    check entries[2].version == "11.0.25"

  test "emitted catalog header lists versions newest-first":
    var entries = @[makeEntry("11.0.25"), makeEntry("21.0.5"),
      makeEntry("17.0.13")]
    sortCatalog(entries)
    let src = emitCatalogFile("jdk", "ScoopInstaller/Java", entries)
    let line = src.splitLines()[2]  # "## Versions (newest-first): ..."
    check "21.0.5, 17.0.13, 11.0.25" in line

  test "non-numeric suffix preserves ordering":
    var entries = @[
      makeEntry("0.26-1"),
      makeEntry("0.26"),
      makeEntry("0.27"),
    ]
    sortCatalog(entries)
    check entries[0].version == "0.27"
    # 0.26 plain vs 0.26-1: equal numerics, "-1" suffix sorts AFTER
    # "" lexicographically descending, so the suffixed entry comes
    # first.
    check entries[1].version == "0.26-1"
    check entries[2].version == "0.26"
