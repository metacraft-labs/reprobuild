{.define: reproSourceRevalidationTest.}

import std/[os, sets, strutils, unittest]
import repro_cli_support
import source_producer_fixture

suite "source producer invocation scope":
  test "later builds in the same process revalidate producers":
    when defined(windows):
      skip()
    else:
      let binary = absolutePath("build/bin/repro")
      require fileExists(binary)
      let root = createSourceFixture()
      defer: removeDir(root)
      let originalDir = getCurrentDir()
      var saved: seq[tuple[key, value: string, present: bool]]
      for (key, value) in sourceFixtureEnv(root):
        saved.add((key, getEnv(key), existsEnv(key)))
        putEnv(key, value)
      setCurrentDir(root / "consumer")
      defer:
        setCurrentDir(originalDir)
        for item in saved:
          if item.present: putEnv(item.key, item.value)
          else: delEnv(item.key)
      let args = @["--daemon=off", "--tool-provisioning=from-source",
        "--progress=quiet", "--log=quiet"]
      require runSourceRevalidationBuildForTest(args, binary) == 0
      check readFile("build/result.txt") == "implementation-one\n"
      check fromSourceResolvedRecipes.len == 0
      writeFile(root / "catalog/probe/repro.nim",
        producerRecipe.replace("source = inputName", "source = \"two.txt\""))
      require runSourceRevalidationBuildForTest(args, binary) == 0
      check readFile("build/result.txt") == "implementation-two\n"
      check fromSourceResolvedRecipes.len == 0
