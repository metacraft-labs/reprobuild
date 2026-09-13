## Real provider-mode tagging must not authorize entry-file-only package keys.

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]

import repro_binary_cache_client/cache_key
import repro_project_dsl/source_cache_identity

const FixtureDir = currentSourcePath().parentDir.parentDir /
  "fixtures" / "l3-build-block-publish"

proc compileRunner(root: string): string =
  result = root / "runner"
  let compiled = execCmdEx(quoteShellCommand(@["nim", "c", "--verbosity:0", "--hints:off",
    "-d:reproProviderMode", "--nimcache:" & root / "nimcache", "--out:" & result,
    FixtureDir / "runner.nim"]))
  doAssert compiled.exitCode == 0, compiled.output

proc inspect(binary, recipeDir: string): Table[string, JsonNode] =
  let ran = execCmdEx(quoteShellCommand(@[binary, recipeDir]))
  doAssert ran.exitCode == 0, ran.output
  result = initTable[string, JsonNode]()
  for line in ran.output.splitLines():
    if line.startsWith("{"):
      let row = parseJson(line)
      result[row["action"].getStr()] = row

suite "provider-mode public-interface cache identity":
  test "automatic and explicit publication tags retain the incomplete identity guard":
    let root = createTempDir("nim-public-interface-", "")
    defer: removeDir(root)
    let rows = inspect(compileRunner(root), FixtureDir)
    for (action, member) in [("publicTool", "publicTool"), ("forcedTool", "forcedTool"),
                             ("customNamedTool", "renamedTool")]:
      let row = rows[action]
      let convention = sourceCacheEntryIdentity(FixtureDir, member, "", "nim")
      check row["publish"].getBool()
      check row["packageName"].getStr() == member
      check row["toolchain"].getStr() == "nim"
      check row["providerRevision"].getStr() == convention.providerRevision
      check row["keyHex"].getStr() == ""
      check row["identityError"].getStr() == cacheEntryIdentityError(convention)
      expect CacheKeyError:
        discard deriveCacheEntryKeyHex(convention)
    for name in ["optedOutTool", "internalHelper"]:
      check not rows[name]["publish"].getBool()
      check rows[name]["keyHex"].getStr() == ""

  test "implementation edits cannot alias under an unchanged entry recipe":
    let root = createTempDir("nim-implementation-identity-", "")
    defer: removeDir(root)
    let recipe = root / "recipe"
    createDir(recipe / "src")
    copyFile(FixtureDir / "repro.nim", recipe / "repro.nim")
    let program = recipe / "src" / "publicTool.nim"
    writeFile(program, "echo 1\n")
    let runner = compileRunner(root)
    let before = inspect(runner, recipe)["publicTool"]
    writeFile(program, "echo 2\n")
    let after = inspect(runner, recipe)["publicTool"]
    check before["providerRevision"] == after["providerRevision"]
    check before["publish"].getBool() and after["publish"].getBool()
    for row in [before, after]:
      check row["keyHex"].getStr() == ""
      check row["identityError"].getStr().startsWith("incomplete binary-cache identity")
