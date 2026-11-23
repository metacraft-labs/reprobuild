## t_a_producer_recipe_that_does_not_compile_names_its_error -- when a
## cross-repo producer's interface extraction fails, the consumer's build
## says why.
##
## The defect. A CodeTracer build stopped before planning with only
##
##   cross-repo producer "reprobuild" at <root>'s interface could not be
##   loaded to bind the declared executable / library to its output.
##
## The cause, a `nim c` error in the producer's recipe compile (a dev shell
## exported an io-mon older than the engine's SDK, so `io_mon/cli_description`
## could not be opened), was in a failure report inside the consumer's
## `.repro/build` and nowhere in the output. The handler dropped the message of
## the error it caught. It now carries it.
##
## What is graded: a consumer that `uses:` a sibling library whose `repro.nim`
## imports a module that does not exist when it is extracted on its own. The
## build must fail, name the producer's interface as the thing that could not
## load, and print the compiler's `cannot open file` for that module.
##
## MOCK POLICY -- none. The real `build/bin/repro` resolves a real develop
## override and extracts the real producer recipe.

import std/[os, osproc, strutils, tempfiles, unittest]

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))

const MissingModule = "no_such_producer_module_7c1e"

# The producer's recipe compiles when the consumer's own extraction folds it
# in, and fails only in the producer's standalone extraction: there the
# extraction's consumer root is the producer's own directory. That is the
# extraction the handler under test wraps; a recipe that failed in both would
# stop the consumer's extraction first, which prints its error itself.
const ProducerRecipe = """
import std/strutils
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

const reproConsumerRoot {.strdefine.} = ""
when reproConsumerRoot.endsWith("brokenlib"):
  import """ & MissingModule & """

package brokenlib:
  defaultToolProvisioning "path"
  uses:
    "sh"
  library brokenlib:
    kind: static
"""

const ConsumerRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"
  uses:
    "sh"
    "brokenlib"
  build:
    let stamp = shell(
      command = "mkdir -p build && printf ok > build/stamp.txt",
      actionId = "consumer.stamp",
      extraOutputs = @["build/stamp.txt"])
    discard target("stamp", stamp)
"""

const Overrides = """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "brokenlib"
local_path = "../brokenlib"
state = "editable"
created_at = "2026-11-23T00:00:00Z"
"""

suite "a cross-repo producer whose recipe does not compile":
  test "the consumer's build names the producer and the compile error":
    if not fileExists(reproBin):
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      let root = createTempDir("repro-producer-error-", "")
      defer: removeDir(root)
      createDir(root / "brokenlib" / "src")
      writeFile(root / "brokenlib" / "repro.nim", ProducerRecipe)
      writeFile(root / "brokenlib" / "src" / "brokenlib.nim",
        "proc broken*(): int = 1\n")
      let consumer = root / "consumer"
      createDir(consumer / ".repro")
      writeFile(consumer / "repro.nim", ConsumerRecipe)
      writeFile(consumer / ".repro" / "develop-overrides.toml", Overrides)
      createDir(root / "action-cache")
      let res = execCmdEx(quoteShellCommand([reproBin, "build", "stamp",
        "--tool-provisioning=path", "--daemon=off", "--no-runquota",
        "--progress=quiet", "--action-cache-root=" & root / "action-cache"]),
        workingDir = consumer)
      checkpoint("exit=" & $res.exitCode & "\n" & res.output)
      check res.exitCode != 0
      check "interface could not be loaded" in res.output
      check "brokenlib" in res.output
      check "cannot open file: " & MissingModule in res.output
