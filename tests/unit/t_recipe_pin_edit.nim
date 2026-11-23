## The recipe rewrites `repro lock update` makes, and the name resolution it
## does first (`repro_cli_support/recipe_pin_edit`), as pure functions over
## recipe texts (Unified-Locking-And-Hooks.md §16.4).
##
## WHY a unit test beside the integration case
## (`t_lock_update_rewrites_exact_pin_in_both_recipes`): the integration case
## drives the real binary over `git+file://` flakes, so it can only spell a
## pin as `?ref=main&rev=<sha>`. The other spellings an author writes — the
## path form `github:o/r/<sha>` reprobuild's own `flake.nix` uses, `rev=`
## before `ref=`, a `#fragment` — and the refusals for a pin the rewrite must
## not touch are exercised here, against exact expected bytes.
##
## Test-double policy: none. The functions under test take and return text;
## every input is a literal recipe in the shape authors write.

import std/[strutils, unittest]

import repro_cli_support/recipe_pin_edit

const
  ShaA = "a75c78d9816c19490ca9b574ec6f863dab9b9aff"
  ShaB = "cd1b0f2671941aec80411dbfcf7cd32d9cf68691"
  ShaC = "5a8e43b5e1f2c7d9a0b3c4d5e6f708192a3b4c5d"

proc flakeWith(urls: openArray[(string, string)]): string =
  result = "{\n  description = \"x\";\n\n  inputs = {\n"
  for (name, url) in urls:
    result.add("    " & name & ".url = \"" & url & "\";\n")
  result.add("    nixpkgs.follows = \"other\";\n  };\n\n  outputs = _: { };\n}\n")

suite "a flake.nix pin is rewritten in place, and nothing else is":

  test "the rev= query form keeps every other byte of the url and the file":
    let before = flakeWith([
      ("alpha-src", "git+https://example.org/o/alpha?ref=main&rev=" & ShaA),
      ("beta-src", "git+https://example.org/o/beta?ref=main&rev=" & ShaA)])
    let e = rewriteFlakeInputRev(before, "beta-src", ShaA, ShaB)
    check e.ok
    check e.line == 6
    check e.before == "git+https://example.org/o/beta?ref=main&rev=" & ShaA
    check e.after == "git+https://example.org/o/beta?ref=main&rev=" & ShaB
    # alpha-src pins the SAME revision and is not touched.
    check e.text == flakeWith([
      ("alpha-src", "git+https://example.org/o/alpha?ref=main&rev=" & ShaA),
      ("beta-src", "git+https://example.org/o/beta?ref=main&rev=" & ShaB)])

  test "the github path form is rewritten as a path component":
    let before = flakeWith([
      ("hooks-src", "github:metacraft-labs/nim-stackable-hooks/" & ShaA)])
    let e = rewriteFlakeInputRev(before, "hooks-src", ShaA, ShaB)
    check e.ok
    check e.text == flakeWith([
      ("hooks-src", "github:metacraft-labs/nim-stackable-hooks/" & ShaB)])

  test "rev= first, a fragment, and an upper-case revision are all kept":
    let before = flakeWith([
      ("beta-src", "git+file:///w/beta?rev=" & ShaA.toUpperAscii() &
        "&ref=main#pkg")])
    let e = rewriteFlakeInputRev(before, "beta-src", ShaA, ShaB)
    check e.ok
    check e.text == flakeWith([
      ("beta-src", "git+file:///w/beta?rev=" & ShaB & "&ref=main#pkg")])

  test "the attribute-set form is rewritten on its url line":
    let before = "{\n  inputs = {\n    beta-src = {\n      url = \"github:o/beta/" &
      ShaA & "\";\n      inputs.nixpkgs.follows = \"nixpkgs\";\n    };\n  };\n" &
      "  outputs = _: { };\n}\n"
    let e = rewriteFlakeInputRev(before, "beta-src", ShaA, ShaB)
    check e.ok
    check e.line == 4
    check e.text == before.replace("github:o/beta/" & ShaA,
      "github:o/beta/" & ShaB)

  test "a url that does not name the old revision is refused, unchanged":
    let before = flakeWith([
      ("beta-src", "git+https://example.org/o/beta?ref=main&rev=" & ShaC)])
    let e = rewriteFlakeInputRev(before, "beta-src", ShaA, ShaB)
    check not e.ok
    check e.text == before
    check e.diagnostic == "input 'beta-src' (flake.nix:5): the url " &
      "git+https://example.org/o/beta?ref=main&rev=" & ShaC & " does not " &
      "name revision " & ShaA & " exactly once (as rev=" & ShaA & " or as a /" &
      ShaA & " path component)"

  test "the same url in a comment on another line keeps its bytes":
    # A comment quoting the old pin, and a second input on the SAME url and
    # revision on its own line: only the named input's line changes.
    let pinned = "git+https://example.org/o/beta?ref=main&rev=" & ShaA
    let before = "{\n  inputs = {\n    # was \"" & pinned & "\" before\n" &
      "    beta-src.url = \"" & pinned & "\"; # release pin\n" &
      "    beta-old.url = \"" & pinned & "\";\n  };\n  outputs = _: { };\n}\n"
    let e = rewriteFlakeInputRev(before, "beta-src", ShaA, ShaB)
    check e.ok
    check e.line == 4
    check e.text == "{\n  inputs = {\n    # was \"" & pinned & "\" before\n" &
      "    beta-src.url = \"git+https://example.org/o/beta?ref=main&rev=" &
      ShaB & "\"; # release pin\n" &
      "    beta-old.url = \"" & pinned & "\";\n  };\n  outputs = _: { };\n}\n"

  test "one url literal twice on the input's line is refused, not guessed":
    let pinned = "github:o/beta/" & ShaA
    let before = "{\n  inputs = { beta-src.url = \"" & pinned &
      "\"; beta-old.url = \"" & pinned & "\"; };\n  outputs = _: { };\n}\n"
    let e = rewriteFlakeInputRev(before, "beta-src", ShaA, ShaB)
    check not e.ok
    check e.text == before
    check e.diagnostic == "input 'beta-src' (flake.nix:2): line 2 holds \"" &
      pinned & "\" 2 time(s), not exactly once"

  test "a floating url and an undeclared input are refused":
    let before = flakeWith([("beta-src", "github:o/beta")])
    check not rewriteFlakeInputRev(before, "beta-src", ShaA, ShaB).ok
    let missing = rewriteFlakeInputRev(before, "gamma-src", ShaA, ShaB)
    check not missing.ok
    check missing.diagnostic == "flake.nix declares no input 'gamma-src'"

  test "an interpolated url is not edited as text":
    let before = "{\n  inputs.beta-src.url = \"github:o/${x}/" & ShaA &
      "\";\n  outputs = _: { };\n}\n"
    let e = rewriteFlakeInputRev(before, "beta-src", ShaA, ShaB)
    check not e.ok
    check e.text == before

  test "a revision that is not a full commit id is refused":
    check not rewriteFlakeRevInUrl("github:o/r/" & ShaA, ShaA, "main").ok
    check not rewriteFlakeRevInUrl("github:o/r/abc123", "abc123", ShaB).ok

  test "a rev= that is only a prefix of another parameter is not matched":
    # `xrev=<sha>` is not the `rev` parameter.
    let url = "git+https://h/o/r?xrev=" & ShaA & "&ref=main"
    check not rewriteFlakeRevInUrl(url, ShaA, ShaB).ok

suite "an exact repro.nim uses: version is rewritten in place":

  test "the operator and the selector are kept; only the version changes":
    let before = "import repro_project_dsl\n\npackage app:\n  uses:\n" &
      "    \"beta ==1.0.0\"\n    \"gamma >=2\"\n"
    let e = rewriteUsesExactVersion(before, 5, "beta ==1.0.0", "1.0.0",
      "2.0.0")
    check e.ok
    check e.before == "beta ==1.0.0"
    check e.after == "beta ==2.0.0"
    check e.text == before.replace("\"beta ==1.0.0\"", "\"beta ==2.0.0\"")

  test "a v-prefixed bare version keeps its prefix":
    check exactConstraintWithVersion("lib v1.4.0", "1.4.0", "1.5.0") ==
      (true, "lib v1.5.0")
    check exactConstraintWithVersion("lib =1.4.0", "1.4.0", "1.5.0") ==
      (true, "lib =1.5.0")

  test "the wrong line, or a literal twice on the line, is refused":
    let before = "  uses:\n    \"beta ==1.0.0\"\n"
    let wrong = rewriteUsesExactVersion(before, 1, "beta ==1.0.0", "1.0.0",
      "2.0.0")
    check not wrong.ok
    check wrong.text == before
    let twice = "  uses: \"beta ==1.0.0\" # \"beta ==1.0.0\"\n"
    check not rewriteUsesExactVersion(twice, 1, "beta ==1.0.0", "1.0.0",
      "2.0.0").ok

suite "a dependency name resolves to one repository, or is refused":

  let candidates = @[
    DependencyCandidate(kind: dckFlakeInput, name: "beta-src",
      identity: "example.org/o/beta", where: "/w/app/flake.nix:6"),
    DependencyCandidate(kind: dckReproLockDep, name: "beta",
      identity: "example.org/o/beta", where: "/w/app/repro.lock"),
    DependencyCandidate(kind: dckWorkspaceRepo, name: "beta",
      identity: "example.org/o/beta", where: "workspace repo at /w/beta"),
    DependencyCandidate(kind: dckReproLockDep, name: "gamma",
      identity: "example.org/o/gamma", where: "/w/app/repro.lock"),
    DependencyCandidate(kind: dckWorkspaceRepo, name: "gamma",
      identity: "example.org/o/other-gamma", where: "workspace repo at /w/g")]

  test "two names for one repository resolve together":
    let r = resolveDependencyName("beta", candidates)
    check r.ok
    check r.identity == "example.org/o/beta"
    check r.matches.len == 2
    check resolveDependencyName("beta-src", candidates).identity ==
      "example.org/o/beta"

  test "one name for two repositories is AMBIGUOUS, with every candidate":
    let r = resolveDependencyName("gamma", candidates)
    check not r.ok
    check r.diagnostic == "'gamma' is AMBIGUOUS: it names 2 things that " &
      "are not one repository — dep:gamma (/w/app/repro.lock, repository " &
      "example.org/o/gamma); repo:gamma (workspace repo at /w/g, repository " &
      "example.org/o/other-gamma). Name one of them by its qualified " &
      "spelling (dep:gamma, repo:gamma)"

  test "a qualified name picks one kind":
    let r = resolveDependencyName("dep:gamma", candidates)
    check r.ok
    check r.identity == "example.org/o/gamma"
    check resolveDependencyName("repo:gamma", candidates).identity ==
      "example.org/o/other-gamma"

  test "an unknown name is refused, listing what is known":
    let r = resolveDependencyName("delta", candidates)
    check not r.ok
    check r.diagnostic == "'delta' names no flake input, repro.lock " &
      "dependency or workspace repo of this repository; known: " &
      "input:beta-src, dep:beta, repo:beta, dep:gamma, repo:gamma"

  test "a match with no repository URL beside one with a URL is ambiguous":
    let r = resolveDependencyName("beta", candidates & @[
      DependencyCandidate(kind: dckFlakeInput, name: "beta",
        where: "/w/app/flake.nix:9")])
    check not r.ok
    check r.diagnostic.startsWith("'beta' is AMBIGUOUS")
    let alone = resolveDependencyName("input:beta", candidates & @[
      DependencyCandidate(kind: dckFlakeInput, name: "beta",
        where: "/w/app/flake.nix:9")])
    check not alone.ok
    check alone.diagnostic == "'input:beta' names input:beta " &
      "(/w/app/flake.nix:9, no repository URL), which resolves to no " &
      "repository URL this command can identify, so no other resolution of " &
      "it can be found"
