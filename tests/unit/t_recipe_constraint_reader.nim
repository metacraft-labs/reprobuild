## The recipe-constraint reader (`repro_cli_support/recipe_constraints`):
## what a `flake.nix` input URL and a `repro.nim` `uses:` entry state about a
## dependency's revision (Unified-Locking-And-Hooks.md §16.2).
##
## WHY. The managed hooks must not compare a repository that a recipe pins by
## exact revision with its sibling checkout (§16.5), and the later consistency
## checks compare each constraint with its lock resolution and the two systems
## with each other, by canonical repository URL (§16.3). All of that rests on
## reading each constraint correctly: an exact revision read as a branch would
## put a release pin back under the stale-sibling comparison, and a branch read
## as a revision would take a floating input out of it.
##
## What is covered:
##   * every flake URL form the hooks meet: `github:o/r/<sha>`,
##     `github:o/r?rev=<sha>`, `git+https://…?ref=…&rev=…`, a branch ref
##     (path and query forms), no ref at all, a short hex that is NOT a
##     revision, `path:`, a registry name and a tarball;
##   * canonical identity: the three spellings §16.3 names as one repository
##     agree, a different repository does not, and identity never comes from
##     an input name;
##   * the `flake.nix` scan: both spellings of an input, the attribute-set form,
##     a `follows`, an interpolated URL (no constraint is invented for it), and
##     the line of each URL literal;
##   * `flake.lock` resolutions: the repository each root input's `locked` node
##     names, in the github and git shapes;
##   * `repro.nim`: `uses:` ranges, exact versions and unconstrained entries,
##     the `versions:` scan, and the exact-version → `sourceRevision` mapping.
##
## Test-double policy: none. These are pure functions over text; every input
## is the literal text a real `flake.nix`, `flake.lock` or `repro.nim` carries.

import std/[strutils, unittest]

import repro_cli_support/recipe_constraints
import repro_interface_artifacts

const
  ShaA = "0123456789abcdef0123456789abcdef01234567"
  ShaB = "fedcba9876543210fedcba9876543210fedcba98"

suite "flake references":

  test "github path revision is an exact pin":
    let p = parseFlakeRef("github:metacraft-labs/reprobuild/" & ShaA)
    check p.kind == frkGitForge
    check p.rev == ShaA
    check p.gitRef == ""
    check p.fetchUrl == "https://github.com/metacraft-labs/reprobuild"

  test "github query revision is an exact pin":
    let p = parseFlakeRef("github:metacraft-labs/reprobuild?rev=" & ShaB)
    check p.kind == frkGitForge
    check p.rev == ShaB
    check p.gitRef == ""

  test "git+https with ref and rev is an exact pin on that branch":
    let p = parseFlakeRef("git+https://github.com/o/r?ref=main&rev=" & ShaA)
    check p.kind == frkGit
    check p.rev == ShaA
    check p.gitRef == "main"
    check p.fetchUrl == "https://github.com/o/r"

  test "a branch reference is not an exact pin":
    let path = parseFlakeRef("github:o/r/release-2.0")
    check path.rev == ""
    check path.gitRef == "release-2.0"
    let query = parseFlakeRef("git+https://github.com/o/r?ref=dev")
    check query.rev == ""
    check query.gitRef == "dev"

  test "no reference at all floats on the default branch":
    let p = parseFlakeRef("github:NixOS/nixpkgs")
    check p.rev == ""
    check p.gitRef == ""
    check p.fetchUrl == "https://github.com/NixOS/nixpkgs"

  test "a short hex path component is a branch name, not a revision":
    let p = parseFlakeRef("github:o/r/abc1234")
    check p.rev == ""
    check p.gitRef == "abc1234"

  test "an explicit rev parameter wins over the path component":
    let p = parseFlakeRef("github:o/r/" & ShaA & "?rev=" & ShaB)
    check p.rev == ShaB

  test "gitlab nested group and custom host":
    let p = parseFlakeRef("gitlab:group%2Fsub/proj?host=git.example.org")
    check p.fetchUrl == "https://git.example.org/group/sub/proj"

  test "git+file, path, registry and tarball forms":
    let f = parseFlakeRef("git+file:///srv/repos/x.git?ref=main")
    check f.kind == frkGit
    check f.fetchUrl == "file:///srv/repos/x.git"
    check f.gitRef == "main"
    check parseFlakeRef("path:/srv/x").kind == frkPath
    check parseFlakeRef("nixpkgs").kind == frkIndirect
    check parseFlakeRef("flake:nixpkgs").kind == frkIndirect
    check parseFlakeRef("https://example.org/x.tar.gz").kind == frkTarball
    check parseFlakeRef("https://example.org/x.tar.gz").fetchUrl == ""

  test "isExactRevision accepts only full commit ids":
    check isExactRevision(ShaA)
    check isExactRevision(ShaA & ShaA[0 ..< 24])      # 64 hex: SHA-256
    check not isExactRevision(ShaA[0 ..< 39])
    check not isExactRevision("main")
    check not isExactRevision(ShaA[0 ..< 39] & "g")

suite "canonical repository identity":

  test "the three spellings of one repository agree":
    let a = canonicalRepositoryUrl("github:o/r")
    let b = canonicalRepositoryUrl("git+https://github.com/o/r")
    let c = canonicalRepositoryUrl("https://github.com/o/r.git")
    check a == "github.com/o/r"
    check a == b
    check b == c

  test "refs, revisions and query strings do not change the identity":
    check canonicalRepositoryUrl("github:o/r/" & ShaA) == "github.com/o/r"
    check canonicalRepositoryUrl("git+https://github.com/o/r?ref=main&rev=" &
      ShaA) == "github.com/o/r"
    check canonicalRepositoryUrl("git@github.com:o/r.git") == "github.com/o/r"

  test "a different repository has a different identity":
    check canonicalRepositoryUrl("github:o/r") !=
      canonicalRepositoryUrl("github:o/r2")
    check canonicalRepositoryUrl("github:o/r") !=
      canonicalRepositoryUrl("gitlab:o/r")

  test "a local origin is one repository however it is spelled":
    check canonicalRepositoryUrl("git+file:///tmp/origin-a.git?ref=main") ==
      canonicalRepositoryUrl("file:///tmp/origin-a.git")

  test "a registry name or tarball input names no repository":
    check canonicalFlakeRefRepository("nixpkgs") == ""
    check canonicalFlakeRefRepository("flake:nixpkgs") == ""
    check canonicalFlakeRefRepository("https://example.org/x.tar.gz") == ""
    check canonicalFlakeRefRepository("tarball+https://example.org/x") == ""
    check canonicalRepositoryUrl("") == ""
    let tarball = flakeInputConstraintOf(FlakeInputDeclaration(name: "t",
      url: "https://example.org/x.tar.gz", urlIsLiteral: true, urlLine: 3))
    check tarball.kind == frkTarball
    check tarball.canonicalRepo == ""
    check tarball.exactRev == ""

const FlakeSource = """{
  description = "constraint reader fixture";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    reprobuild.url = "github:metacraft-labs/reprobuild/""" & ShaA & """";
    lib-src.url = "git+https://github.com/o/lib?ref=main&rev=""" & ShaB & """";
    floating-src.url = "git+https://github.com/o/floating?ref=dev";
    # a comment with a { brace and a "string"
    bundlers = {
      url = "github:o/bundlers";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.follows = "nixpkgs";
    computed.url = "github:o/${"x"}";
  };
  inputs.toplevel.url = "github:o/toplevel?rev=""" & ShaA & """";

  outputs = _: { };
}
"""

proc constraintFor(cs: FlakeRecipeConstraints; input: string):
    FlakeInputConstraint =
  for c in cs.inputs:
    if c.input == input: return c
  checkpoint("no constraint for input " & input)
  check false

proc lineOf(text, needle: string): int =
  var n = 0
  for line in text.splitLines():
    inc n
    if needle in line: return n
  0

suite "flake.nix input constraints":

  test "every input is found, in declaration order":
    var names: seq[string]
    for d in scanFlakeInputDeclarations(FlakeSource): names.add(d.name)
    check names == @["nixpkgs", "reprobuild", "lib-src", "floating-src",
      "bundlers", "flake-utils", "computed", "toplevel"]

  test "exact pins are reported with their line and repository":
    let cs = flakeRecipeConstraintsOf(FlakeSource, "/x/flake.nix")
    check cs.ok
    let rb = constraintFor(cs, "reprobuild")
    check rb.exactRev == ShaA
    check rb.line == lineOf(FlakeSource, "reprobuild.url")
    check rb.canonicalRepo == "github.com/metacraft-labs/reprobuild"
    let lib = constraintFor(cs, "lib-src")
    check lib.exactRev == ShaB
    check lib.gitRef == "main"
    check lib.canonicalRepo == "github.com/o/lib"
    let top = constraintFor(cs, "toplevel")
    check top.exactRev == ShaA
    check top.line == lineOf(FlakeSource, "inputs.toplevel.url")
    var pinned: seq[string]
    for p in exactPins(cs): pinned.add(p.input)
    check pinned == @["reprobuild", "lib-src", "toplevel"]
    check describeFlakePin(rb, "/x/flake.nix") ==
      "/x/flake.nix:" & $rb.line & " (rev " & ShaA & ")"

  test "branch and default-branch inputs are not pinned":
    let cs = flakeRecipeConstraintsOf(FlakeSource, "flake.nix")
    let np = constraintFor(cs, "nixpkgs")
    check np.exactRev == ""
    check np.gitRef == "nixos-24.05"
    check constraintFor(cs, "floating-src").exactRev == ""
    check constraintFor(cs, "floating-src").gitRef == "dev"

  test "the attribute-set form carries its url":
    let cs = flakeRecipeConstraintsOf(FlakeSource, "flake.nix")
    let b = constraintFor(cs, "bundlers")
    check b.url == "github:o/bundlers"
    check b.line == lineOf(FlakeSource, "url = \"github:o/bundlers\"")
    check b.canonicalRepo == "github.com/o/bundlers"
    check b.exactRev == ""

  test "a follows input states no revision":
    let cs = flakeRecipeConstraintsOf(FlakeSource, "flake.nix")
    let fu = constraintFor(cs, "flake-utils")
    check fu.follows == "nixpkgs"
    check fu.url == ""
    check fu.exactRev == ""

  test "an interpolated url is not read as a constraint":
    let cs = flakeRecipeConstraintsOf(FlakeSource, "flake.nix")
    let c = constraintFor(cs, "computed")
    check c.url == ""
    check c.exactRev == ""
    check c.canonicalRepo == ""

  test "a missing flake.nix is a diagnostic, not an empty answer":
    let cs = readFlakeRecipeConstraints("/nonexistent/flake/dir")
    check not cs.ok
    check "no flake.nix" in cs.diagnostic

const LockText = """{
  "nodes": {
    "reprobuild": {
      "locked": { "owner": "metacraft-labs", "repo": "reprobuild",
                  "rev": """" & ShaA & """", "type": "github" },
      "original": { "owner": "metacraft-labs", "repo": "reprobuild",
                    "rev": """" & ShaA & """", "type": "github" }
    },
    "lib-src": {
      "locked": { "ref": "main", "rev": """" & ShaB & """", "type": "git",
                  "url": "https://github.com/o/lib" },
      "original": { "ref": "main", "type": "git",
                    "url": "https://github.com/o/lib" }
    },
    "root": { "inputs": { "lib-src": "lib-src", "reprobuild": "reprobuild",
                          "follower": ["reprobuild"] } }
  },
  "root": "root",
  "version": 7
}
"""

suite "flake.lock resolutions":

  test "each root input resolves to the repository its locked node names":
    let rs = flakeLockResolutions(LockText)
    check rs.len == 2
    check rs[0].input == "lib-src"
    check rs[0].lockedRev == ShaB
    check rs[0].originalRev == ""
    check rs[0].canonicalRepo == "github.com/o/lib"
    check rs[1].input == "reprobuild"
    check rs[1].lockedRev == ShaA
    check rs[1].originalRev == ShaA
    check rs[1].canonicalRepo == canonicalRepositoryUrl(
      "https://github.com/metacraft-labs/reprobuild.git")

  test "an unreadable lock yields no resolutions":
    check flakeLockResolutions("not json").len == 0

suite "repro.nim uses: constraints":

  test "an exact version":
    for raw in ["lib ==1.4.0", "lib =1.4.0", "lib 1.4.0", "lib v1.4.0"]:
      let c = parseReproUsesConstraint(raw, "repro.nim", 12)
      checkpoint(raw)
      check c.selector == "lib"
      check c.kind == uckExact
      check c.exactVersion == "1.4.0"
      check c.line == 12
      check c.admits("1.4.0")
      check not c.admits("1.4.1")

  test "a range":
    let c = parseReproUsesConstraint("nim >=2.2 <3.0")
    check c.selector == "nim"
    check c.kind == uckRange
    check c.rangeText == ">=2.2 <3.0"
    check c.admits("2.2.4")
    check not c.admits("3.0.0")
    check parseReproUsesConstraint("x ^1.5.0").kind == uckRange
    check parseReproUsesConstraint("x ~2.1").kind == uckRange
    # A range that happens to admit one version is still a range.
    check parseReproUsesConstraint("x >=1.2.3 <1.2.4").kind == uckRange

  test "an unconstrained entry admits every version":
    let c = parseReproUsesConstraint("git")
    check c.kind == uckUnconstrained
    check c.selector == "git"
    check c.admits("0.0.1")

  test "an unparseable version is reported, not admitted":
    let c = parseReproUsesConstraint("x >=banana")
    check c.kind == uckUnparseable
    check c.diagnostic.len > 0
    check not c.admits("1.0.0")

  test "uses carried by an extracted interface keep their recipe line":
    let uses = @[
      InterfaceToolUse(rawConstraint: "lib ==1.4.0", packageSelector: "lib",
        location: SourceLocation(file: "/w/app/repro.nim", line: 7)),
      InterfaceToolUse(rawConstraint: "nim >=2.2", packageSelector: "nim",
        location: SourceLocation(file: "/w/app/repro.nim", line: 8))]
    let cs = reproUsesConstraints(uses)
    check cs.len == 2
    check cs[0].kind == uckExact
    check cs[0].file == "/w/app/repro.nim"
    check cs[0].line == 7
    check cs[1].kind == uckRange

const ProducerRecipe = """
package lib:
  versions:
    "1.3.0":
      sourceRevision = "refs/tags/v1.3.0"
    # a comment between entries
    "1.4.0":
      sourceChecksum = "sha256-x"
      sourceRevision = """" & ShaA & """"
    "1.5.0":
      sourceRevision = LibNextRevision
  build:
    discard
"""

suite "repro.nim versions: source revisions":

  test "every versions: entry is read with its line":
    let vs = reproRecipeVersions(ProducerRecipe)
    check vs.len == 3
    check vs[0].version == "1.3.0"
    check vs[0].sourceRevision == "refs/tags/v1.3.0"
    check vs[1].version == "1.4.0"
    check vs[1].sourceRevision == ShaA
    check vs[1].sourceRevisionIsLiteral
    check vs[1].line == lineOf(ProducerRecipe, "\"1.4.0\":")

  test "a non-literal sourceRevision is not guessed":
    let vs = reproRecipeVersions(ProducerRecipe)
    check vs[2].version == "1.5.0"
    check vs[2].sourceRevision == ""
    check not vs[2].sourceRevisionIsLiteral

  test "an exact uses: version maps to its sourceRevision":
    let vs = reproRecipeVersions(ProducerRecipe)
    let hit = exactSourceRevision(parseReproUsesConstraint("lib ==1.4.0"), vs)
    check hit.found
    check hit.entry.sourceRevision == ShaA
    check not exactSourceRevision(parseReproUsesConstraint("lib ==9.9.9"),
      vs).found
    check not exactSourceRevision(parseReproUsesConstraint("lib >=1.0"),
      vs).found

suite "the comment beside a pin (Unified-Locking-And-Hooks.md §16.6)":

  test "trailing, block above, above the opener, and none":
    let flake = "{\n" &                                              # 1
      "  inputs = {\n" &                                             # 2
      "    a-src.url = \"github:o/a/" & "1".repeat(40) &
        "\"; # trailing reason\n" &                                  # 3
      "    # first line of a reason\n" &                             # 4
      "    #\n" &                                                    # 5
      "    ## second line\n" &                                       # 6
      "    b-src.url = \"github:o/b/" & "2".repeat(40) & "\";\n" &  # 7
      "    # above the opener\n" &                                   # 8
      "    c-src = {\n" &                                            # 9
      "      url = \"git+https://h/o/c?rev=" & "3".repeat(40) &
        "\";\n" &                                                    # 10
      "    };\n" &                                                   # 11
      "    d-src = { # on the opener\n" &                            # 12
      "      url = \"github:o/d/" & "4".repeat(40) & "\";\n" &      # 13
      "    };\n" &                                                   # 14
      "    e-src.url = \"git+https://h/o/e?ref=a#b&rev=" &
        "5".repeat(40) & "\";\n" &                                   # 15
      "  };\n}\n"
    check recipePinComment(flake, 3) == "trailing reason"
    check recipePinComment(flake, 7) ==
      "first line of a reason second line"
    check recipePinComment(flake, 10) == "above the opener"
    check recipePinComment(flake, 13) == "on the opener"
    # A `#` inside the url string is not a comment, and nothing is above.
    check recipePinComment(flake, 15) == ""
    check recipePinComment(flake, 0) == ""
    check recipePinComment(flake, 999) == ""
    # Two adjacent pinned inputs: each keeps its own comment, and an input
    # without one never inherits its neighbour's (trailing or above).
    let adjacent = "{\n" &                                           # 1
      "  # Inputs of the fixture.\n" &                               # 2
      "  inputs = {\n" &                                             # 3
      "    p-src.url = \"github:o/p/" & "6".repeat(40) & "\";\n" &  # 4
      "    # reason for q\n" &                                       # 5
      "    q-src.url = \"github:o/q/" & "7".repeat(40) &
        "\"; # q trailing\n" &                                       # 6
      "    r-src.url = \"github:o/r/" & "8".repeat(40) & "\";\n" &  # 7
      "    s-src = {\n" &                                            # 8
      "      url = \"github:o/s/" & "9".repeat(40) & "\";\n" &      # 9
      "    };\n" &                                                   # 10
      "    t-src = {\n" &                                            # 11
      "      url = \"github:o/t/" & "a".repeat(40) & "\";\n" &      # 12
      "      # about t's flake attribute, not its pin\n" &           # 13
      "      flake = false;\n" &                                     # 14
      "    };\n" &                                                   # 15
      "  };\n}\n"
    # The comment above `inputs = {` describes the block, not its first pin.
    check recipePinComment(adjacent, 4) == ""
    # The trailing comment wins over the block above.
    check recipePinComment(adjacent, 6) == "q trailing"
    # r follows q's line directly: q's trailing comment is not r's.
    check recipePinComment(adjacent, 7) == ""
    # s's opener follows r's line, which carries no comment.
    check recipePinComment(adjacent, 9) == ""
    check recipePinComment(adjacent, 12) == ""
    let nim = "package app:\n  uses:\n" &
      "    \"delta ==1.0.0\"  # the 1.x protocol\n" &
      "    \"beta ==2.0.0\"\n"
    check recipePinComment(nim, 3) == "the 1.x protocol"
    check recipePinComment(nim, 4) == ""
