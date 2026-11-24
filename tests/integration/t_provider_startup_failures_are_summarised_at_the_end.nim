## A provider startup-body failure stays non-fatal and is named again in one
## summary line at the end of the build.
##
## THE GAP. When a package's `build:` body raises during the provider's
## startup pass, the provider reports
##
##   repro project provider: startup body failed: <package>: <error>
##
## and only that package's registrations are lost; the build goes on. In a
## CodeTracer build these lines (`codetracer_ruby_recorder: cannot open:
## version.txt`, `runquota: ... Duplicate test binary name`) scrolled past
## within the first minutes of an hour-long build and were found only by
## reading the whole log. `repro build` now ends with one line that names
## every such package.
##
## WHAT IS GRADED. A consumer that `uses:` a develop-override sibling whose
## `build:` body reads a file that does not exist (the shape of the ruby
## recorder's failure). The build must still succeed and build the consumer's
## own target, print the startup failure, and end with the summary naming the
## sibling exactly once.
##
## MOCK POLICY -- none. The real `build/bin/repro` builds real recipes.

import std/[os, osproc, strutils, tempfiles, unittest]

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))

const ProducerRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package brokenbody:
  defaultToolProvisioning "path"
  uses:
    "sh"
  library brokenbody:
    kind: static
  build:
    discard readFile("no-such-file-for-the-startup-pass-7c1e.txt")
"""

const ConsumerRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"
  uses:
    "sh"
    "brokenbody"
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
package = "brokenbody"
local_path = "../brokenbody"
state = "editable"
created_at = "2026-11-23T00:00:00Z"
"""

suite "provider startup failures are summarised at the end of the build":
  test "the build goes on, and its last lines name the failed package once":
    if not fileExists(reproBin):
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      let root = createTempDir("repro-startup-summary-", "")
      defer: removeDir(root)
      createDir(root / "brokenbody" / "src")
      writeFile(root / "brokenbody" / "repro.nim", ProducerRecipe)
      writeFile(root / "brokenbody" / "src" / "brokenbody.nim",
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
      check res.exitCode == 0
      check fileExists(consumer / "build" / "stamp.txt")
      check "startup body failed: brokenbody" in res.output
      var summary = ""
      for line in res.output.strip().splitLines():
        if line.startsWith("repro: ") and "provider startup failure" in line:
          summary = line
      checkpoint("summary: " & summary)
      check summary.len > 0
      check "brokenbody" in summary
      check summary.count("brokenbody") == 1
      check "1 provider startup failure " in summary
