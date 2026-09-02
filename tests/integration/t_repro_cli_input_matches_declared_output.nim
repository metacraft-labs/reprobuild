## The e2e execute edges must actually depend on the CLI they spawn.
##
## ``repro.nim`` feeds a single constant — ``reproBinaryPath`` — to the
## ``requiredBinaries`` slot of every ``TestSpec`` that carries
## ``requiresReproBinary``. That slot exists to deliver two things: build
## ``build/bin/repro`` BEFORE the test runs, and re-run the test when the CLI
## changes.
##
## Neither is delivered by the slot itself. Both come out of
## ``inferDeclaredActionDeps``
## (``libs/repro_project_dsl/src/repro_project_dsl/runtime_core.nim``), which
## indexes every action by its DECLARED OUTPUT PATH and then matches every
## other action's declared INPUTS against that index by *normalized string
## equality*. A miss is not an error. It is not a warning. The loop simply
## adds no dep, and the edge is published one dependency short — which reads
## exactly like an edge that legitimately has no producer.
##
## That is how the defect this file pins arrived. Once ``nim.c`` started
## appending ``.exe`` on Windows, ``reprobuild.apps.repro`` began declaring
## ``build/bin/repro.exe`` while the constant still said ``build/bin/repro``.
## The lookup missed on every e2e execute edge on Windows, silently, and the
## suite went on spawning whatever stale ``repro.exe`` happened to be sitting
## in ``build/bin`` from some earlier run.
##
## So the invariant is not "the constant mentions .exe". It is: *the path the
## recipe spells as an INPUT is the same string the producing edge declares as
## its OUTPUT*. The two tests below pin that from both ends — statically
## against ``nim.c``'s own declaration, and dynamically against the graph the
## engine actually lowers.

import std/[json, os, osproc, strtabs, strutils, unittest]

import repro_project_dsl
# Imported under an alias on purpose: the `package nim:` block inside that
# module emits a const named `nim`, and a plain `import` would shadow it with
# the module name and break `nim.c(...)` resolution -- the same reason
# reprobuild's own `repro.nim` reaches the const through the `uses:` pass.
import repro_dsl_stdlib/packages/nim as nim_module

const nimTool = nim_module.nim

const RepoMarker = "repro.nim"

## An e2e test that carries ``requiresReproBinary: true`` in
## ``repro_tests.nim``. Any of them would do; this one is already named in
## ``t_b3_test_template_emits_two_edges``'s known-consumer list, so the two
## tests fail together if the flag is ever dropped from it.
const SampleConsumerStem = "t_show_conventions_cli"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc projectText(repoRoot: string): string =
  ## ``repro.nim`` with line endings normalized, so the block scans below
  ## behave the same on a CRLF checkout.
  readFile(repoRoot / RepoMarker).replace("\r\n", "\n")

proc blockAt(text: string; marker: string): string =
  ## The marker's line plus every following line up to the first blank one.
  ## ``repro.nim`` separates top-level declarations with a blank line, so this
  ## is exactly the declaration the marker opens.
  let start = text.find(marker)
  if start < 0:
    return ""
  let stop = text.find("\n\n", start)
  if stop < 0:
    return text[start .. ^1]
  text[start ..< stop]

proc stringLiterals(text: string): seq[string] =
  ## Every double-quoted literal in ``text``. The scanned blocks contain no
  ## escapes, so a plain quote-pair walk is exact here.
  var i = 0
  while i < text.len:
    if text[i] == '"':
      let close = text.find('"', i + 1)
      if close < 0:
        break
      result.add(text[i + 1 ..< close])
      i = close + 1
    else:
      inc i

proc literalAfter(text, marker: string): string =
  ## The first string literal following ``marker``, or "" when the marker is
  ## absent. Returning "" rather than raising keeps the failure ON the
  ## assertion that cares, instead of aborting the whole case.
  let pos = text.find(marker)
  if pos < 0:
    return ""
  let rest = text[pos + marker.len .. ^1]
  let literals = stringLiterals(rest)
  if literals.len == 0: "" else: literals[0]

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  ## ``poStdErrToStdOut`` is deliberately NOT in the option set, unlike
  ## ``execCmdEx``'s default. The engine writes advisory diagnostics to stderr
  ## — on this host, an "MSVC dev-env activation: VsDevCmd.bat exited 255"
  ## notice on every invocation — and merging them into stdout puts non-JSON
  ## text in front of the document ``--format=json`` produced.
  let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin"
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, options = {poEvalCommand, poUsePath}, env = env,
    workingDir = repoRoot)

proc parseGraphJson(output: string): JsonNode =
  ## ``nil`` when ``output`` holds no parseable JSON document. Parsing from
  ## the first ``{`` rather than from position 0 keeps any stray banner line
  ## from costing the whole document.
  let start = output.find('{')
  if start < 0:
    return nil
  try:
    return parseJson(output[start .. ^1])
  except JsonParsingError:
    return nil

proc actionOutputs(action: JsonNode): seq[string] =
  var node = action{"outputs"}
  if node.isNil or node.kind == JNull:
    node = action{"evidence"}{"declaredOutputs"}
  if node.isNil or node.kind == JNull:
    return @[]
  for entry in node:
    result.add(entry.getStr().replace('\\', '/'))

suite "the repro CLI input is spelled as its producer declares it":

  test "static: the recipe's CLI input equals what nim.c declares for that edge":
    # Read BOTH ends out of the recipe rather than restating them here: the
    # producing edge's ``binary`` argument, and the constant handed to
    # ``requiredBinaries``. Then ask ``nim.c`` -- the wrapper that actually
    # decides the declared output -- what it makes of that ``binary`` on this
    # host, and require the constant's arm for this host to be that exact
    # string. A test that merely checked for ".exe" would still pass if the
    # suffixing rule moved again.
    let repoRoot = findRepoRoot()
    let text = projectText(repoRoot)

    let appsEdgeStart = text.find("source = \"apps/repro/repro.nim\"")
    check appsEdgeStart >= 0
    let producerBinary =
      if appsEdgeStart < 0: ""
      else: literalAfter(text[appsEdgeStart .. ^1], "binary =")
    checkpoint("producing edge declares binary = " & producerBinary)
    check producerBinary.len > 0

    let constBlock = blockAt(text, "const reproBinaryPath")
    checkpoint("reproBinaryPath block:\n" & constBlock)
    check constBlock.len > 0

    # Two arms, not one. A bare literal -- which is what the constant
    # regressed to -- yields exactly one literal here and fails on the spot,
    # without needing a Windows host to notice.
    let arms = stringLiterals(constBlock)
    checkpoint("reproBinaryPath arms: " & $arms)
    check arms.len == 2

    let windowsArm = literalAfter(constBlock, "when defined(windows):")
    let otherArm = literalAfter(constBlock, "else:")
    checkpoint("windows arm = " & windowsArm & ", else arm = " & otherArm)
    check windowsArm.len > 0
    check otherArm.len > 0
    check windowsArm != otherArm

    resetBuildActionRegistry()
    resetTargetExportRegistry()
    let producer = nimTool.c(
      source = "apps/repro/repro.nim",
      binary = producerBinary,
      actionId = "t_repro_cli_input.producer.probe")
    check producer.outputs.len == 1
    let declared =
      if producer.outputs.len == 1: producer.outputs[0].replace('\\', '/')
      else: ""
    checkpoint("nim.c declares: " & declared)

    # THE ASSERTION. The input the recipe spells for this host must be the
    # output the producer declares for this host.
    when defined(windows):
      check declared == windowsArm
    else:
      check declared == otherArm

  test "engine: an e2e execute edge depends on the action that builds the CLI":
    # The static check pins the strings; this pins the consequence. If the two
    # ever drift again, `inferDeclaredActionDeps` drops the dep without a
    # word, the closure shrinks by one action, and this fails.
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    check fileExists(reproBin)

    block engineArm:
      if not fileExists(reproBin):
        break engineArm

      let executeId = "reprobuild.test_execute." & SampleConsumerStem
      let selector = ".#" & executeId
      let args = @[
        reproBin.quoteShell,
        "graph",
        selector,
        "--tool-provisioning=path",
        "--format=json",
      ]
      let (output, exitCode) = runWithRunquotaOnPath(args.join(" "), repoRoot)
      checkpoint(selector & " graph exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0
      if exitCode != 0:
        break engineArm

      let graph = parseGraphJson(output)
      # ``not graph.isNil`` rather than ``graph != nil``: the `check` macro
      # renders its operands on failure, and ``$`` of a nil ``JsonNode``
      # segfaults, which would replace the diagnostic with a crash.
      if graph.isNil:
        checkpoint("graph output was not JSON:\n" & output)
      check not graph.isNil
      if graph.isNil:
        break engineArm

      let actions = graph{"actions"}
      check not actions.isNil
      if actions.isNil:
        break engineArm

      # The producer is identified by WHAT IT DECLARES, not by its id: the
      # dependency edge is inferred from the declared output path, so that is
      # the thing worth looking up.
      let cliPath = ("build/bin" / addFileExt("repro", ExeExt))
        .replace('\\', '/')
      var producerId = ""
      var executeDeps: seq[string] = @[]
      var sawExecute = false
      for action in actions:
        let id = action{"id"}.getStr()
        if cliPath in actionOutputs(action):
          producerId = id
        if id == executeId:
          sawExecute = true
          let deps = action{"deps"}
          if not deps.isNil and deps.kind != JNull:
            for dep in deps:
              executeDeps.add(dep.getStr())

      checkpoint("execute edge present: " & $sawExecute)
      checkpoint("producer of " & cliPath & ": " &
        (if producerId.len == 0: "<none in closure>" else: producerId))
      checkpoint("execute edge deps: " & $executeDeps)

      check sawExecute
      # Not merely "some action declares it" -- it has to be IN THIS CLOSURE,
      # which is the half that delivers "build the CLI first".
      check producerId.len > 0
      # And the execute edge has to name it, which is the half that delivers
      # "re-run when the CLI changes".
      check producerId in executeDeps
