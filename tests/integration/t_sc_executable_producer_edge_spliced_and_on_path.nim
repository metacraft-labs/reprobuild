## Cross-Repo-Source-Consumption SC-2 — producer graph load + splice
## (executable channel). A consumer whose build action invokes a sibling
## PRODUCER project's declared ``executable`` by bare name builds that sibling
## FROM SOURCE first and finds the freshly-built binary on ``PATH`` — no
## prebuilt binary planted, no ``cd ../sib && just build``, no ``direnv``.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §4.2 (producer graph load +
## splice, executable channel) + §7.1 (the runquota example). Milestone:
## ``Cross-Repo-Source-Consumption.milestones.org`` §SC-2.
##
## Fixture (built ``./build/bin/repro``, black-box; every path in a fresh
## tempdir so nothing touches $HOME):
##
##   <scratch>/
##     prod/                         the sibling PRODUCER project repo
##       repro.nim                   declares ``executable prod`` + a build edge
##                                   that WRITES an executable to build/bin/prod
##     consumer/                     the CONSUMER project repo
##       repro.nim                   ``uses: "prod"`` + a shell build action that
##                                   invokes ``prod`` by bare name and captures
##                                   its output to build/consumed.txt
##       .repro/develop-overrides.toml   develop override: prod -> ../prod
##
## The develop override maps the consumer's ``uses: "prod"`` selector to the
## sibling checkout (§5.1). ``repro build`` on the consumer must, via the SC-2
## pre-pass, load ``../prod/repro.nim``, build its declared ``executable``'s
## producing edge from source (recursively, in-process), realize
## ``../prod/build/bin/prod``, and splice that ``bin`` dir onto the consuming
## action's ``PATH`` so the consumer's ``sh -c "prod ..."`` action resolves the
## freshly-built binary.
##
## Assertions:
##   1. ``repro build`` on the consumer exits 0.
##   2. The producer binary ``../prod/build/bin/prod`` was materialized BY THIS
##      RUN (it was removed before the build; nothing planted it on PATH).
##   3. The consumer's action ran the freshly-built producer binary: the marker
##      file ``consumer/build/consumed.txt`` carries the producer's unique
##      stamp (proving the bare ``prod`` name resolved to the sibling's binary,
##      i.e. the splice put its bin dir on PATH — not a host ``prod``, which
##      does not exist).
##
## Falsifiability (reproduced by the implementation agent): editing the SC-2
## pre-pass so it SKIPS the ``putEnv("PATH", ...)`` splice (leaving the producer
## bin dir off the process PATH) makes the consumer's ``sh -c "prod ..."``
## action fail to find ``prod`` — the build exits non-zero (assertion 1 trips)
## and the marker file is never written (assertion 3 trips). Reverting the edit
## restores green.
##
## Skip rule: ``sh`` missing on PATH, or ``./build/bin/repro`` unbuilt.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

# The producer's UNIQUE stamp — the built ``prod`` binary echoes exactly this.
# It cannot appear unless the sibling was built from source AND its binary ran.
const producerStamp = "SC2-PRODUCER-STAMP-9f2c1a"

# The producer sibling repo. ``executable prod`` is the declared consumable
# executable (name matches the package + the ``uses: "prod"`` selector so the
# path-mode identity resolver binds the built binary to the ref). The build
# edge is a real ``shell(...)`` action that writes an executable script to the
# canonical ``build/bin/<name>`` output layout every producing edge uses.
const producerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package prod:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable prod:
    name: "prod"

  build:
    discard shell(
      command = "mkdir -p build/bin && " &
        "printf '#!/bin/sh\necho """ & producerStamp & """\n' > build/bin/prod && " &
        "chmod +x build/bin/prod",
      actionId = "prod.build.prod",
      extraOutputs = @["build/bin/prod"])
"""

# The consumer repo. ``uses: "prod"`` names the sibling producer; the develop
# override maps it to ../prod. The shell action invokes ``prod`` by BARE NAME
# (no path) so it only resolves if the SC-2 splice put ../prod/build/bin on the
# action PATH, and captures the output so the test can prove which binary ran.
const consumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "prod"

  build:
    discard shell(
      command = "mkdir -p build && prod > build/consumed.txt",
      actionId = "consumer.build.consume",
      extraOutputs = @["build/consumed.txt"])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

suite "SC-2: executable producer edge spliced and on PATH":

  test "t_sc_executable_producer_edge_spliced_and_on_path":
    let shBin = findExe("sh")
    if shBin.len == 0 or not fileExists(reproBinary):
      checkpoint("skipped — sh missing on PATH or repro unbuilt")
      skip()
    else:
      let repoRoot = getCurrentDir()
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc2-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- The sibling PRODUCER project. ----
      let prodRoot = absolutePath(scratch / "prod")
      createDir(prodRoot)
      writeFile(prodRoot / "repro.nim", producerRepro)

      # ---- The CONSUMER project + its develop override for the producer. ----
      let consumerRoot = absolutePath(scratch / "consumer")
      createDir(consumerRoot)
      writeFile(consumerRoot / "repro.nim", consumerRepro)
      createDir(consumerRoot / ".repro")
      writeFile(consumerRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "prod"
local_path = "../prod"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
""")

      # Nothing prebuilt: the producer binary must NOT exist before the build,
      # so assertion (2) measures whether THIS run produced it.
      let producerBinary = prodRoot / "build" / "bin" /
        addFileExt("prod", ExeExt)
      check not fileExists(producerBinary)
      let consumedMarker = consumerRoot / "build" / "consumed.txt"
      if fileExists(consumedMarker):
        removeFile(consumedMarker)

      # Assert there is NO host ``prod`` that could satisfy the bare name by
      # accident — the only way the consumer action can find ``prod`` is via the
      # SC-2 splice of the sibling's freshly-built bin dir.
      check findExe("prod").len == 0

      # ---- Build the consumer. The SC-2 pre-pass must build ../prod first and
      # splice its bin dir onto PATH so the consumer's ``sh -c "prod ..."``
      # action resolves the freshly-built producer binary. ----
      let cmd = q(reproAbs) & " build " & q(consumerRoot / "repro.nim") &
        " --tool-provisioning=path --daemon=off --log=quiet" &
        " --progress=quiet --report=none"
      checkpoint("running: " & cmd)
      let (code, output) = run(cmd, repoRoot)
      checkpoint("exit=" & $code)
      checkpoint(output)

      # (1) The consumer build succeeds.
      check code == 0

      # (2) The producer binary was materialized from source BY THIS RUN.
      check fileExists(producerBinary)

      # (3) The consumer action ran the freshly-built producer binary: the
      # marker file carries the producer's unique stamp. This is only possible
      # if the bare ``prod`` name resolved to ../prod/build/bin/prod, i.e. the
      # SC-2 splice put the producer bin dir on the consuming action's PATH.
      check fileExists(consumedMarker)
      if fileExists(consumedMarker):
        let consumed = readFile(consumedMarker).strip()
        checkpoint("consumed.txt=" & consumed)
        check consumed == producerStamp
