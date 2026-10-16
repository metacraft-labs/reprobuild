## GM6: `repro home compare` reports, per category, exactly the differences
## between a Nix-side and a Reprobuild-side host-facts document.
##
## `e2e_compare_reports_each_category` compares the fixture pair
## `tests/fixtures/host-facts/{nix,reprobuild}.json` (README there): exactly
## one known difference per category, each of a different status, beside
## `same` entries and informational fields (`origin`, `version`) that differ
## freely. The JSON report must list exactly those four differences -- the
## status, the id and, for `different`, exactly the differing field -- and
## nothing else; the exit status is 1, and the text report names each.
##
## Negative control: the Nix document compared with itself relabelled as the
## Reprobuild side (identical facts) reports no difference and exits 0; so
## does the pair with its arguments swapped and the four differences
## allowlisted (order of `--facts` is irrelevant; `side` decides).
##
## Vacuity guard: every category of the schema has at least one entry in
## each fixture document, and at least one `same` entry in the report.
##
## No mocks: the real `build/bin/repro` (compare_support.nim).

import std/[json, os, sequtils, strutils, unittest]

import ./compare_support

const Categories = ["packages", "files", "environment", "services"]

suite "GM6: repro home compare":

  test "e2e_compare_reports_each_category":
    let nixDoc = fixture("nix.json")
    let reproDoc = fixture("reprobuild.json")
    # Vacuity: the fixture covers every category on both sides.
    for c in Categories:
      check nixDoc["categories"][c].len > 0
      check reproDoc["categories"][c].len > 0
    check nixDoc["categories"].len == Categories.len

    let dir = newScratch("each-category")
    defer: removeDir(dir)
    let nixPath = dir.writeDoc("nix.json", nixDoc)
    let reproPath = dir.writeDoc("reprobuild.json", reproDoc)

    let run = runCompare(["--facts", nixPath, "--facts", reproPath,
      "--format", "json"])
    check run.exitCode == 1
    let report = parseJson(run.stdout)
    check report["failing"].getInt == 4

    # Exactly the known differences, per category and status.
    let expected = {
      "packages": @[("only-in-nix", "jq")],
      "files": @[("different", "~/.zshrc")],
      "environment": @[("only-in-reprobuild", "var:GM6_EDITOR")],
      "services": @[("different", "systemd:gm6.service")]}
    for (category, diffs) in expected:
      var got: seq[(string, string)]
      for status in ["only-in-nix", "only-in-reprobuild", "different"]:
        for id in report.statusIds(category, status):
          got.add (status, id)
      check got == diffs
      # Vacuity: the category also has a `same` entry.
      check report.statusIds(category, "same").len >= 1

    # `different` names exactly the differing field, with both values;
    # informational fields never appear.
    let zshrc = report["categories"]["files"]["different"][0]
    check zshrc["fields"].len == 1
    check zshrc["fields"][0]["field"].getStr == "digest"
    check zshrc["fields"][0]["nix"].getStr.startsWith("sha256:1111")
    check zshrc["fields"][0]["reprobuild"].getStr.startsWith("sha256:e3dd")
    let unit = report["categories"]["services"]["different"][0]
    check unit["fields"].len == 1
    check unit["fields"][0]["field"].getStr == "enabled"
    check unit["fields"][0]["nix"] == %false
    check unit["fields"][0]["reprobuild"] == %true
    check "bash" in report.statusIds("packages", "same")   # versions differ

    # The text report names every difference as not allowed.
    let text = runCompare(["--facts", nixPath, "--facts", reproPath])
    check text.exitCode == 1
    for id in ["jq", "~/.zshrc", "var:GM6_EDITOR", "systemd:gm6.service"]:
      check text.stdout.splitLines.anyIt(it.contains(id) and
        it.contains("NOT ALLOWED"))
    check text.stdout.contains("result: 4 difference(s) not allowlisted")

    # Negative control 1: identical facts.
    let selfPath = dir.writeDoc("self.json", nixDoc.asSide("reprobuild"))
    let same = runCompare(["--facts", nixPath, "--facts", selfPath,
      "--format", "json"])
    check same.exitCode == 0
    let sameReport = parseJson(same.stdout)
    check sameReport["failing"].getInt == 0
    for c in Categories:
      for status in ["only-in-nix", "only-in-reprobuild", "different"]:
        check sameReport.statusIds(c, status).len == 0
      check sameReport.statusIds(c, "same").len ==
        nixDoc["categories"][c].len

    # Negative control 2: swapped arguments, every difference allowlisted.
    let allow = dir.writeText("allow.toml", """
[[allow]]
category = "packages"
status = "only-in-nix"
id = "jq"
reason = "fixture: jq is installed by Home Manager only"

[[allow]]
category = "files"
id = "~/.zshrc"
reason = "fixture: the two sides write different shell init"

[[allow]]
category = "environment"
status = "only-in-reprobuild"
reason = "fixture: Reprobuild-only variables"
milestone = "GM6"

[[allow]]
category = "services"
status = "different"
hosts = ["gm6-host"]
reason = "fixture: Home Manager does not enable the unit"
""")
    let allowed = runCompare(["--facts", reproPath, "--facts", nixPath,
      "--allow", allow])
    check allowed.exitCode == 0
    check allowed.stdout.contains("result: 0 difference(s) not allowlisted, " &
      "0 stale allowlist row(s); exit 0")
    check not allowed.stdout.contains("NOT ALLOWED")
