## The pattern-scoped enumeration name, its matcher and its two digests.
##
## WHY. A pattern-scoped enumeration keys an edge on the entries of a
## directory that match one glob component (`pattern_scoped_enumeration.nim`,
## `Incremental-Invalidation.md` §"Validation Criteria"). Its soundness rests
## on three properties graded here directly:
##   * the matcher never rejects a name glob(3) could have matched, so the key
##     is a superset of glob's dependency (a rejected match is a dependency
##     left out, i.e. a false hit);
##   * the name round-trips, and to code that does not know the convention it
##     reads as the directory itself, whose full listing is the superset key;
##   * the local digest and the portable one filter the same names, so the two
##     keys cannot disagree about what the scan depended on.
## The engine test `t_pattern_scoped_enumeration_keys_only_matching_entries`
## grades the same keys through real builds.
##
## Mocks: none; real directories under the build tree.

import std/[os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_local_store

let TmpDir = absolutePath(
  "build/test-tmp/t_pattern_scoped_enumeration_names-" & testCaseScratchSlug())

suite "pattern-scoped enumeration names":

  test "the matcher accepts what glob matches":
    check globComponentMatches("*.nimble", "proj.nimble")
    check globComponentMatches("*.nimble", ".nimble")
    check globComponentMatches("*", "")
    check globComponentMatches("a?c", "abc")
    check globComponentMatches("lit", "lit")
    check globComponentMatches("*a*b*", "xaybz")

  test "the matcher rejects what glob cannot match":
    check not globComponentMatches("*.nimble", "proj.nimble.bak")
    check not globComponentMatches("*.nimble", "unused.nim")
    check not globComponentMatches("a?c", "ac")
    check not globComponentMatches("lit", "lit2")
    check not globComponentMatches("?", "")

  test "the matcher errs toward more names where glob depends on context":
    # glob skips a hidden name unless the pattern starts with `.`.
    check globComponentMatches("*.nimble", ".hidden.nimble")
    # `?` is one CHARACTER; in a UTF-8 locale that is several bytes.
    check globComponentMatches("?.nimble", "é.nimble")
    check globComponentMatches("x?y", "x\xe2\x82\xacy")

  test "the name round-trips and keeps one spelling per directory":
    for dir in ["/a/b", "/a/b/", "/a/b//", "rel/dir"]:
      let name = patternScopedEnumerationPath(dir, "*.nimble")
      check name.isPatternScopedEnumeration()
      check splitPatternScopedEnumeration(name) ==
        (dir.strip(leading = false, chars = {'/'}), "*.nimble")
      check name.patternScopedBase() ==
        dir.strip(leading = false, chars = {'/'})
    check patternScopedEnumerationPath("/a/b", "*") ==
      patternScopedEnumerationPath("/a/b/", "*")
    let root = patternScopedEnumerationPath("/", "*")
    check splitPatternScopedEnumeration(root) == ("/", "*")
    check splitPatternScopedEnumeration("/plain/dir") == ("/plain/dir", "")
    check not "/plain/dir".isPatternScopedEnumeration()

  test "the local digest covers matching entries and fails safe without them":
    let dir = TmpDir / "local"
    removeDir(dir)
    createDir(dir / "sub")
    writeFile(dir / "a.nimble", "")
    writeFile(dir / "unused.nim", "")
    let scoped = patternScopedEnumerationPath(dir, "*.nimble")
    let before = fingerprintDirectoryMembership(scoped)
    check before.membershipTrackedDirectory()
    check before != fingerprintDirectoryMembership(dir)
    writeFile(dir / "another.nim", "")
    check fingerprintDirectoryMembership(scoped) == before
    writeFile(dir / "b.nimble", "")
    check fingerprintDirectoryMembership(scoped) != before
    # A reader that does not know the convention: the path ends at the NUL,
    # so it lists the directory itself.
    var walked = 0'i64
    check directoryMembershipDigest(scoped, walked) ==
      directoryMembershipDigest(dir, walked)
    # When every entry matches, the scoped and full keys coincide, which is
    # the one case where such a reader hits, and it is right to.
    let all = TmpDir / "all"
    removeDir(all)
    createDir(all)
    writeFile(all / "a.nimble", "")
    check fingerprintDirectoryMembership(
      patternScopedEnumerationPath(all, "*.nimble")) ==
      fingerprintDirectoryMembership(all)
    # No match at all is still a tracked state, distinct from "not tracked".
    let none = TmpDir / "none"
    removeDir(none)
    createDir(none)
    writeFile(none / "x.txt", "")
    check fingerprintDirectoryMembership(
      patternScopedEnumerationPath(none, "*.nimble")).
      membershipTrackedDirectory()

  test "the portable digest filters the same names":
    let dir = TmpDir / "portable"
    removeDir(dir)
    createDir(dir / "pkg.nimble")
    writeFile(dir / "a.nimble", "")
    writeFile(dir / "unused.nim", "")
    let scoped = patternScopedEnumerationPath(dir, "*.nimble")
    check membershipHex(scoped) ==
      membershipHexOfNames(@["a.nimble", "pkg.nimble/"])
    check namesMatchingScope(@["a.nimble", "pkg.nimble/", "unused.nim"],
      "*.nimble") == @["a.nimble", "pkg.nimble/"]
    check namesMatchingScope(@["x", "y/"], "") == @["x", "y/"]
    check membershipHex(dir) ==
      membershipHexOfNames(@["a.nimble", "pkg.nimble/", "unused.nim"])

  test "a scoped listing above a portable root is implied, like a full one":
    # Nim's compiler globs `*.nimble` in every directory above a module, so
    # every Nim compile carries scoped listings of the project's ancestors.
    # A full listing of an ancestor contributes nothing to the portable
    # identity (it says where this host keeps the checkout); a scoped one
    # must not instead make the action non-portable.
    let above = TmpDir / "above"
    removeDir(above)
    let project = above / "work" / "proj"
    createDir(project / "src")
    writeFile(project / "src" / "main.nim", "echo 1\n")
    let roots = @[
      LogicalRoot(label: "project", path: project, kind: lrkTracked)]
    let ancestor = patternScopedEnumerationPath(above / "work", "*.nimble")
    let scoped = computePortableFingerprint(roots, @["nim"], project, @[],
      @[], reads = @[project / "src" / "main.nim"], probes = @[ancestor],
      enumerations = @[ancestor])
    let bare = computePortableFingerprint(roots, @["nim"], project, @[],
      @[], reads = @[project / "src" / "main.nim"], probes = @[],
      enumerations = @[])
    checkpoint(scoped.reason)
    check scoped.portable
    check scoped.strongHex == bare.strongHex
