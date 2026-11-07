## GM6: an entry with no logical id is reported `unmapped` and does not fail
## `repro home compare` on its own (spec §Identity across ecosystems: a Nix
## entry no contribution claims is catalog work, never a configuration
## difference).
##
## `e2e_compare_unmapped_is_not_different`: the fixture Nix document's
## `unmapped` package (`hello-2.12.2`, no catalog attribute claims `hello`)
## against a Reprobuild document with otherwise identical categories. The
## comparison exits 0, the report lists the entry under the packages
## category's `unmapped` with its side and reason, and the entry appears
## under no compared status. Uncategorized entries (a dconf key on each
## side) are listed and never compared either.
##
## Control arm: the same package given a logical id on the Nix side only
## (the catalog claiming it) is `only-in-nix` and exits 1 -- so the exit 0
## above is the unmapped rule, not a comparison that ignores packages.
##
## No mocks: the real `build/bin/repro` (compare_support.nim).

import std/[json, os, strutils, unittest]

import ./compare_support

suite "GM6: unmapped entries":

  test "e2e_compare_unmapped_is_not_different":
    let nixDoc = fixture("nix.json")
    check nixDoc["unmapped"].len == 1
    let unmappedId = nixDoc["unmapped"][0]["id"].getStr
    check unmappedId == "hello-2.12.2"

    # The Reprobuild side: the Nix categories verbatim, nothing unmapped.
    var reproDoc = nixDoc.asSide("reprobuild")
    reproDoc["uncategorized"] = fixture("reprobuild.json")["uncategorized"]

    let dir = newScratch("unmapped")
    defer: removeDir(dir)
    let nixPath = dir.writeDoc("nix.json", nixDoc)
    let reproPath = dir.writeDoc("reprobuild.json", reproDoc)

    let run = runCompare(["--facts", nixPath, "--facts", reproPath,
      "--format", "json"])
    check run.exitCode == 0
    let report = parseJson(run.stdout)
    check report["failing"].getInt == 0
    let listed = report["categories"]["packages"]["unmapped"]
    check listed.len == 1
    check listed[0]["id"].getStr == unmappedId
    check listed[0]["side"].getStr == "nix"
    check listed[0]["reason"].getStr.contains("hello")
    for status in ["same", "only-in-nix", "only-in-reprobuild", "different"]:
      check unmappedId notin report.statusIds("packages", status)
    check report["uncategorized"].len == 2

    let text = runCompare(["--facts", nixPath, "--facts", reproPath])
    check text.exitCode == 0
    check text.stdout.contains("unmapped (nix) " & unmappedId)
    check text.stdout.contains("[uncategorized] 2 entries")

    # Control arm: the same package with a logical id on one side.
    var mappedNix = nixDoc.copy()
    mappedNix["unmapped"] = newJArray()
    mappedNix["categories"]["packages"].add %*{"id": "hello",
      "origin": "home.packages hello-2.12.2 (nixpkgs#hello)"}
    let mappedPath = dir.writeDoc("mapped.json", mappedNix)
    let control = runCompare(["--facts", mappedPath, "--facts", reproPath,
      "--format", "json"])
    check control.exitCode == 1
    check "hello" in parseJson(control.stdout).statusIds("packages",
      "only-in-nix")
