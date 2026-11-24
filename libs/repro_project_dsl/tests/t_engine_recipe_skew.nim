## The skew rule's decision and its diagnostic
## (Cross-Repo-Source-Consumption.md §9.2a), at the layer both the DSL macro
## and the pre-push gate call: `detectEngineRecipeSkew` decides whether a
## producer tree is newer than the compile's DSL, and the refusal's record
## line round-trips through `parseEngineRecipeSkew`.
##
## The end-to-end behaviour (the refusal surfacing from a real recipe compile
## before the sibling is compiled, and the gate's remedy) is covered by
## `tests/integration/t_an_engine_older_than_a_sibling_recipe_names_the_skew.nim`.
##
## No mocks: real directory trees with the files the rule reads.

import std/[os, strutils, tempfiles, unittest]

import repro_core
import repro_project_dsl/engine_recipe_skew

proc makeTree(root, version: string; nimble = true) =
  createDir(root / "libs" / "repro_project_dsl" / "src")
  writeFile(root / ReprobuildSourceTreeMarker, "")
  createDir(root / "libs" / "repro_core" / "src")
  writeFile(root / ReprobuildVersionModule,
    "const ReprobuildVersion* {.strdefine.} = \"" & version & "\"\n")
  if nimble:
    writeFile(root / ReprobuildNimbleFile, "version       = \"" & version &
      "\"\n")

suite "engine recipe skew":
  test "the DSL's version is this tree's own release literal":
    check DslVersion == ReprobuildVersion
    check isReprobuildSourceTree(DslSourceRoot)

  test "versions are ordered semantically":
    check compareVersions("0.2.31", "0.2.27") == (true, 1)
    check compareVersions("0.2.27", "0.2.31") == (true, -1)
    check compareVersions("0.10.0", "0.9.9") == (true, 1)
    check compareVersions("1.0", "1.0.0") == (true, 0)
    check compareVersions("1.0.0-rc1", "1.0.0").order < 0
    check compareVersions("v0.2.31", "0.2.31") == (true, 0)
    check not compareVersions("main", "0.2.31").comparable
    check not compareVersions("", "0.2.31").comparable

  test "a tree states its version in the version module, then the nimble":
    let tmp = createTempDir("repro-skew-", "")
    defer: removeDir(tmp)
    makeTree(tmp / "a", "0.3.0")
    check reprobuildSourceTreeVersion(tmp / "a") == "0.3.0"
    makeTree(tmp / "b", "0.4.0")
    writeFile(tmp / "b" / ReprobuildVersionModule, "## no literal\n")
    check reprobuildSourceTreeVersion(tmp / "b") == "0.4.0"
    createDir(tmp / "plain")
    check reprobuildSourceTreeVersion(tmp / "plain") == ""

  test "only a newer reprobuild tree is a skew":
    let tmp = createTempDir("repro-skew-", "")
    defer: removeDir(tmp)
    makeTree(tmp / "newer", "999.0.0")
    makeTree(tmp / "same", DslVersion)
    makeTree(tmp / "older", "0.0.1")
    createDir(tmp / "plain")
    writeFile(tmp / "plain" / "repro.nim", "")
    let newer = detectEngineRecipeSkew(DslSourceRoot, DslVersion, tmp / "newer")
    check newer.skewed
    check newer.skew.siblingVersion == "999.0.0"
    check newer.skew.engineVersion == DslVersion
    check newer.skew.siblingRoot == tmp / "newer"
    check not detectEngineRecipeSkew(DslSourceRoot, DslVersion,
      tmp / "same").skewed
    check not detectEngineRecipeSkew(DslSourceRoot, DslVersion,
      tmp / "older").skewed
    check not detectEngineRecipeSkew(DslSourceRoot, DslVersion,
      tmp / "plain").skewed
    # The compile's own tree is never newer than itself.
    check not detectEngineRecipeSkew(DslSourceRoot, DslVersion,
      DslSourceRoot).skewed

  test "the refusal names both builds and the remedy, and round-trips":
    let skew = EngineRecipeSkew(engineVersion: "0.2.27",
      engineRevision: "33be1e9964", enginePath: "/nix/store/x/bin/reprobuild",
      engineSourceRoot: "/nix/store/x/share/repro/source",
      siblingVersion: "0.2.31", siblingRevision: "2f7cb5db52",
      siblingRoot: "/ws/reprobuild", selector: "reprobuild",
      consumerRecipe: "/ws/codetracer/repro.nim", workspaceRoot: "/ws")
    let message = engineOlderThanSiblingRecipeMessage(skew)
    for fragment in ["older than the sibling recipe it imports", "0.2.27",
        "0.2.31", "33be1e9964", "2f7cb5db52", "/nix/store/x/bin/reprobuild",
        "/ws/reprobuild/repro.nim", "direnv reload", "nix develop",
        "nix build .#default",
        "<that build>/bin/repro hooks ensure --vcs --re-anchor /ws"]:
      checkpoint(fragment)
      check fragment in message
    check "lock refresh" notin message
    let parsed = parseEngineRecipeSkew("noise before\nError: " & message &
      "\nnoise after")
    check parsed.found
    check parsed.skew == skew
    check not parseEngineRecipeSkew("Error: type mismatch").found

  test "an unknown engine identity is said, not left blank":
    let message = engineOlderThanSiblingRecipeMessage(EngineRecipeSkew(
      engineVersion: "0.2.27", siblingVersion: "0.2.31",
      siblingRoot: "/ws/reprobuild", selector: "reprobuild"))
    check "engine unknown, revision unknown" in message
    check "(revision unknown)" in message
