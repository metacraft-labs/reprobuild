## Real provider-mode tagging must not authorize entry-file-only package keys.

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]

import repro_binary_cache_client/cache_key
import repro_project_dsl/source_cache_identity
import repro_provider_runtime

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

  test "the STARTUP pass tags nothing, and reports no failure for doing so":
    ## `maybeTagPublicInterface` runs twice per provider binary: once
    ## during the DSL's startup pass over every `build:` body, and again
    ## for the real invocation. The first has no project root, and the
    ## identity constructor refuses one — correctly, since an identity
    ## derived from an absent root is a cache key that carries no recipe.
    ##
    ## There is no skip, and this comment used to say there was one. What
    ## this case actually measures is that the startup pass never reaches
    ## the identity constructor for a public-interface recipe, so the
    ## refusal does not turn the pass into a reported package failure.
    ##
    ## The assertion has to be an ABSENCE for that reason: if the pass DID
    ## reach the constructor, it would raise, the startup-pass containment
    ## would catch it, and every assertion in the case above would still
    ## hold — the runner would report a broken recipe and the gate would be
    ## green anyway. What a contained failure leaves behind is a line, so
    ## the line is what is asserted, paired with the positive control below
    ## so the absence is an absence of failures rather than of output.
    ##
    ## There is nothing to tag during the pass in any event: the pass
    ## registers nothing that survives, because `buildPackageFragment`
    ## resets the action registry before the real invocation rebuilds it —
    ## which is why the rows above are unaffected.
    let root = createTempDir("nim-public-interface-startup-", "")
    defer: removeDir(root)
    let ran = execCmdEx(quoteShellCommand(@[compileRunner(root), FixtureDir]))
    check ran.exitCode == 0
    checkpoint(ran.output)
    check ProviderStartupBodyFailurePrefix notin ran.output
    # The negative control: the runner really did do its work, so the
    # absence above is an absence of failures and not an absence of output.
    check ran.output.contains("publicTool")

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
