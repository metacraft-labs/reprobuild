## Regression test for a named target whose name matches the canonical
## project-file stem. Bare ``repro build repro`` resolves to ``.#repro``;
## that selector must choose the named target rather than loading the entire
## project as though the fragment referred to a separate Nim module.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const fixtureProject = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package projectStemTarget:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    let selected = shell(
      command = "mkdir -p build && printf 'selected\n' > build/selected.txt",
      actionId = "project-stem.selected",
      extraOutputs = @["build/selected.txt"],
      cacheable = false)
    let unrelated = shell(
      command = "mkdir -p build && printf 'unrelated\n' > build/unrelated.txt",
      actionId = "project-stem.unrelated",
      extraOutputs = @["build/unrelated.txt"],
      cacheable = false)
    discard target("repro", selected)
    discard target("other", unrelated)
"""

proc q(value: string): string = quoteShell(value)

suite "named target matching project-file stem":

  test "repro build repro selects only the named target":
    if findExe("sh").len == 0 or not fileExists(reproBinary):
      checkpoint("skipped - sh missing on PATH or repro unbuilt")
      skip()
    else:
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() /
        ("repro-project-stem-target-" & $getCurrentProcessId())
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)
      writeFile(scratch / "repro.nim", fixtureProject)

      let cacheRoot = scratch / "action-cache"
      createDir(cacheRoot)
      let command = q(reproAbs) & " build repro" &
        " --tool-provisioning=path --daemon=off --no-runquota" &
        " --log=actions --progress=quiet --measure=none" &
        " --action-cache-root=" & q(cacheRoot)
      let run = execCmdEx(command, workingDir = scratch)
      checkpoint(run.output)

      check run.exitCode == 0
      check run.output.contains("scheduler: actions=1")
      check fileExists(scratch / "build" / "selected.txt")
      check not fileExists(scratch / "build" / "unrelated.txt")
