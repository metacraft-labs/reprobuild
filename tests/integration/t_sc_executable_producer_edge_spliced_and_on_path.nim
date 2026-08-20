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
## sibling checkout (§5.1). The fixture first builds a producer-independent
## target, then selects the producer-consuming target. The SC-2 pre-pass must
## load ``../prod/repro.nim``, build its declared executable from source,
## realize ``../prod/build/bin/prod``, and splice that ``bin`` dir onto only the
## consuming action's ``PATH``. The shared base action must retain its cache key.
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
##   4. The base action cache-hits when the second target introduces ``prod``;
##      producer selection must not perturb unrelated action fingerprints.
##
## Falsifiability: omitting the explicit producer profile prevents identity
## resolution or action launch. Resolving it through a process-wide PATH
## overlay changes the base tool profile and makes assertion 4 report
## ``cdMiss`` instead of ``cdHit``.
##
## Skip rule: ``sh`` missing on PATH, or ``./build/bin/repro`` unbuilt.

import std/[json, os, osproc, strutils, unittest]

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

proc withToolIdentities(action: BuildActionDef;
                        tools: openArray[string]): BuildActionDef =
  appendRegisteredActionToolIdentityRefs(action.id, tools)
  action

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "prod"

  build:
    let base = shell(
      command = "mkdir -p build && printf 'base\n' > build/base.txt",
      actionId = "consumer.build.base",
      extraOutputs = @["build/base.txt"])
    let consume = shell(
      command = "mkdir -p build && prod > build/consumed.txt",
      actionId = "consumer.build.consume",
      deps = @[base.id],
      extraOutputs = @["build/consumed.txt"]).withToolIdentities(["prod"])
    let baseTarget = target("base", [base])
    discard target("consume", [base, consume])
    discard collect("test", actions = @[consume])
    defaultTarget(baseTarget)
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

      # ---- Build the producer-independent target first, then select the
      # producer-consuming target. The shared base action must retain the same
      # fingerprint when the second target adds the producer identity. ----
      # Hermetic action-cache root: this heavy test drives ``repro build``, which
      # otherwise shares the developer's ``~/.cache/repro/action-cache``. A
      # co-tenant-bloated shared cache (multi-GB) makes the build wedge on a
      # full-file scan. Point ``repro build`` at a fresh empty cache under this
      # test's scratch (highest-precedence ``--action-cache-root`` flag,
      # ``repro_cli_support.nim:377``) so the test is immune to that bloat and
      # does not pollute the shared cache. Test hygiene only; no production
      # cache-behavior change.
      let cacheRoot = absolutePath(scratch / "action-cache-root")
      createDir(cacheRoot)
      let baseCmd = q(reproAbs) & " build base" &
        " --tool-provisioning=path --daemon=off --log=quiet" &
        " --progress=quiet --measure=none" &
        " --action-cache-root=" & q(cacheRoot)
      checkpoint("running: " & baseCmd)
      let (baseCode, baseOutput) = run(baseCmd, consumerRoot)
      checkpoint("base exit=" & $baseCode)
      checkpoint(baseOutput)
      check baseCode == 0
      check not fileExists(producerBinary)

      let reportPath = absolutePath(scratch / "consume-report.json")
      let consumeCmd = q(reproAbs) & " build consume" &
        " --tool-provisioning=path --daemon=off --log=quiet" &
        " --progress=quiet --measure=all" &
        " --write-report=" & q(reportPath) &
        " --action-cache-root=" & q(cacheRoot)
      checkpoint("running: " & consumeCmd)
      let (code, output) = run(consumeCmd, consumerRoot)
      checkpoint("consume exit=" & $code)
      checkpoint(output)

      # (1) The consumer build succeeds.
      check code == 0

      # Producer identity resolution is scoped to the consuming action, so the
      # shared producer-independent action cache-hits.
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        var foundBase = false
        for action in report{"actions"}:
          checkpoint("reported action=" & action{"id"}.getStr() &
            " cacheDecision=" & action{"cacheDecision"}.getStr() &
            " status=" & action{"status"}.getStr() &
            " reason=" & action{"reason"}.getStr())
          if action{"id"}.getStr() == "base":
            foundBase = true
            checkpoint("base cacheDecision=" &
              action{"cacheDecision"}.getStr())
            check action{"cacheDecision"}.getStr() == "cdHit"
        check foundBase

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

      # Graph inspection runs in a fresh process, so it cannot inherit the
      # producer splice recorded by the build above. It must rediscover the
      # already-materialized public output from the producer contract instead
      # of falling through to host PATH or the package recipe catalog.
      let graphCmd = q(reproAbs) & " graph consume" &
        " --tool-provisioning=path --format=json" &
        " --action-cache-root=" & q(cacheRoot)
      checkpoint("running: " & graphCmd)
      let (graphCode, graphOutput) = run(graphCmd, consumerRoot)
      checkpoint("graph exit=" & $graphCode)
      checkpoint(graphOutput)
      check graphCode == 0
      if graphCode == 0:
        let braceIdx = graphOutput.find('{')
        check braceIdx >= 0
        if braceIdx >= 0:
          let payload = parseJson(graphOutput[braceIdx .. ^1])
          let inspectionPath = payload{"toolInspectionPath"}.getStr("")
          check inspectionPath.len > 0
          check fileExists(inspectionPath)
          if fileExists(inspectionPath):
            let inspection = parseFile(inspectionPath)
            var resolvedProducer = ""
            for profile in inspection{"profiles"}:
              if profile{"executableName"}.getStr("") == "prod":
                resolvedProducer =
                  profile{"resolvedExecutablePath"}.getStr("")
                break
            checkpoint("graph resolved prod=" & resolvedProducer)
            check normalizedPath(resolvedProducer) ==
              normalizedPath(producerBinary)
