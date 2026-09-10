import std/[os, tempfiles]

const producerRecipe* = """
import repro_project_dsl
import recipe_value

package probeSource:
  build:
    let materialize = fs.copyFile(source = inputName,
      output = ".repro/output/install/usr/lib/libprobe.so",
      actionId = "probe.materialize")
    defaultBuildAction(materialize)
"""

const consumerRecipe* = """
import repro_project_dsl

package consumer:
  usesImportPath "stubs"
  buildDeps:
    "probe"
  build:
    let copy = buildAction(id = "consumer.copy",
      call = publicCliCall("reprobuild.builtin", "fs", "copyFile",
        "reprobuild.builtin.fs.copyFile", @[
          inputArg("source", "../catalog/probe/.repro/output/install/usr/lib/libprobe.so"),
          outputArg("output", "build/result.txt")]),
      inputs = @["../catalog/probe/.repro/output/install/usr/lib/libprobe.so"],
      outputs = @["build/result.txt"], toolIdentityRefs = @["probe"])
    defaultBuildAction(copy)
"""

proc createSourceFixture*(): string =
  result = createTempDir("source-revalidation-", "")
  let producer = result / "catalog/probe"
  for path in [producer, result / "consumer", result / "stubs"]:
    createDir(path)
  writeFile(result / "config.nims", "switch(\"path\", thisDir())\n")
  writeFile(result / "stubs/probe.nim",
    "import repro_project_dsl\npackage probe:\n  discard\n")
  writeFile(producer / "recipe_value.nim", "const inputName* = \"one.txt\"\n")
  writeFile(producer / "one.txt", "implementation-one\n")
  writeFile(producer / "two.txt", "implementation-two\n")
  writeFile(producer / "repro.nim", producerRecipe)
  writeFile(result / "consumer/repro.nim", consumerRecipe)

proc sourceFixtureEnv*(root: string): seq[(string, string)] =
  @[("REPRO_FROM_SOURCE_ROOT", root / "catalog"),
    ("REPROBUILD_WORK_ROOT", root / "work"),
    ("REPROBUILD_ACTION_CACHE_ROOT", root / "action-cache"),
    ("REPRO_LOCAL_STORE", root / "store"),
    ("REPRO_CACHE_DISABLE", "1")]
