## Bootstrap-And-Self-Build B3: each ``TestSpec`` entry expands into
## both a build edge and an execute edge in the engine graph.
##
## The live engine arm uses ``repro graph`` against representative direct
## execute-edge selectors. This avoids rebuilding the whole ``.#test-builds``
## collection inside one integration test while still verifying that the
## selected closure contains the test binary build edge and the matching
## ``reprobuild.test_execute.<stem>`` action.

import std/[json, os, osproc, sequtils, sets, strtabs, strutils, unittest]

import repro_core/process_env

const RepoMarker = "repro.nim"

const SampleStems = [
  "t_dsl_outputs_statement_basic_accepted",
  "t_dsl_outputs_typed_multiple_interfaces",
  "t_engine_action_create_dyndep",
]

const KnownReproBinaryConsumers = [
  "tests/integration/t_b1_apps_action_cache_hit.nim",
  "tests/integration/t_b1_repro_build_apps_byte_equivalent.nim",
  "tests/integration/t_b2_helper_invalidation.nim",
  "tests/integration/t_b2_helpers_built_by_engine.nim",
  "libs/repro_core/tests/t_show_conventions_cli.nim",
]

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

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin"
  # ``inheritedEnvTable`` keeps the host's name semantics. Windows spells the
  # variable ``Path`` and compares names case-insensitively; a case-sensitive
  # copy followed by ``env["PATH"] = …`` held a ``Path`` and a second ``PATH``
  # with the runquota directory alone, so the engine started with a ``PATH``
  # that found neither ``nim`` nor any DLL the caller's ``PATH`` supplied
  # (measured on Windows: ``tool-resolution failed: nim ... was not found in
  # PATH``).
  let env = inheritedEnvTable()
  env.prependPathEntry(runquotaBin)
  execCmdEx(cmd, env = env, workingDir = repoRoot)

proc countOccurrences(haystack, needle: string): int =
  if needle.len == 0:
    return 0
  var idx = 0
  while true:
    let hit = haystack.find(needle, idx)
    if hit < 0: break
    inc result
    idx = hit + needle.len

proc actionOutputs(action: JsonNode): JsonNode =
  result = action{"outputs"}
  if result.isNil or result.kind == JNull:
    result = action{"evidence"}{"declaredOutputs"}
  if result.isNil or result.kind == JNull:
    result = newJArray()

proc graphJsonFor(reproBin, repoRoot, selector: string):
    tuple[doc: JsonNode; output: string; exitCode: int] =
  let args = @[
    reproBin.quoteShell,
    "graph",
    selector,
    "--tool-provisioning=path",
    "--format=json",
  ]
  let (output, exitCode) = runWithRunquotaOnPath(args.join(" "), repoRoot)
  if exitCode == 0:
    try:
      return (parseJson(output), output, exitCode)
    except JsonParsingError:
      return (nil, output, 1)
  (nil, output, exitCode)

const
  ## The two CLI images a ``requiresReproBinary`` execute edge declares.
  ReproImage = "build/bin/" & addFileExt("repro", ExeExt)
  EngineImage = "build/bin/" & addFileExt("reprobuild", ExeExt)
  ## ``repro.nim`` names every Windows runtime-DLL copy edge with this prefix.
  StagePrefix = "reprobuild.apps.stage_"
  ## A single (ungrouped) test that runs the CLI: the route the defect was
  ## observed on.
  SingleCliConsumer = "test_tool_identity_env_plumbing"
  ## A test whose generated row puts it in a group, and whose fixture row
  ## names a third ``build/bin`` image (``repro-peer-cache-admin``). Its
  ## group's execute edge is the union of its members' requirements.
  GroupedCliConsumerSource =
    "libs/repro_peer_cache/tests/t_peer_cache_admin_cli_status.nim"

type ClosureView = object
  ok: bool                       ## ``repro graph`` answered with actions
  stageIds: HashSet[string]      ## staging edges in the closure
  stagedOutputs: HashSet[string] ## the files those edges write
  consumerFound: bool            ## the named execute edge is in the closure
  consumerInputs: seq[string]    ## its declared inputs, ``/``-separated
  consumerDeps: seq[string]      ## the action ids it is ordered after

proc declaresFile(inputs: seq[string]; repoRelative: string): bool =
  ## An input may be spelled repo-relative or absolute.
  inputs.anyIt(it == repoRelative or it.endsWith("/" & repoRelative))

proc closureView(reproBin, repoRoot, selector,
    consumerId: string): ClosureView =
  result.stageIds = initHashSet[string]()
  result.stagedOutputs = initHashSet[string]()
  let (graph, output, exitCode) = graphJsonFor(reproBin, repoRoot, selector)
  checkpoint(selector & " graph exit=" & $exitCode)
  if exitCode != 0 or graph.isNil:
    checkpoint(output)
    return
  let actions = graph{"actions"}
  if actions.isNil or actions.kind != JArray:
    return
  result.ok = true
  for action in actions:
    let id = action{"id"}.getStr()
    if id == consumerId:
      result.consumerFound = true
      let inputs = action{"inputs"}
      if not inputs.isNil and inputs.kind == JArray:
        for input in inputs:
          result.consumerInputs.add(input.getStr().replace('\\', '/'))
      let deps = action{"deps"}
      if not deps.isNil and deps.kind == JArray:
        for dep in deps:
          result.consumerDeps.add(dep.getStr())
    if id.startsWith(StagePrefix):
      result.stageIds.incl(id)
      for outputPath in actionOutputs(action):
        result.stagedOutputs.incl(outputPath.getStr().replace('\\', '/'))

proc groupOfSource(repoRoot, source: string): string =
  ## The ``group:`` of ``source``'s row in the generated ``repro_tests.nim``,
  ## or "" for a single test. Read rather than spelled here, because the
  ## grouping plan is regenerated and group names move with it.
  let text = readFile(repoRoot / "repro_tests.nim")
  let rowPos = text.find("source: \"" & source & "\"")
  if rowPos < 0:
    raise newException(ValueError, source & " has no row in repro_tests.nim")
  let nextRow = text.find("source: \"", rowPos + 1)
  const GroupField = "group: \""
  let groupPos = text.find(GroupField, rowPos)
  if groupPos < 0 or (nextRow >= 0 and groupPos > nextRow):
    return ""
  let start = groupPos + GroupField.len
  text[start ..< text.find('"', start)]

proc startInMinimalEnvironment(image: string): tuple[output: string;
    exitCode: int] =
  ## Start ``image --version`` with nothing from the caller's environment that
  ## could locate a library for it: no ``PATH`` entry outside the system
  ## directories on Windows (where ``PATH`` is the last DLL search location),
  ## no ``PATH`` and no ``LD_LIBRARY_PATH`` / ``DYLD_*`` elsewhere. So it
  ## starts only if every library it loads sits where the image itself says:
  ## beside it on Windows, behind its link-time RPATH on Linux and macOS.
  let env = newEnvTable()
  when defined(windows):
    let systemRoot = getEnv("SystemRoot", r"C:\Windows")
    env["SystemRoot"] = systemRoot
    env["PATH"] = systemRoot / "System32" & ";" & systemRoot
  else:
    env["PATH"] = "/nonexistent-minimal-path"
  execCmdEx(image.quoteShell & " --version", env = env,
    workingDir = getTempDir())

suite "Bootstrap-And-Self-Build B3: test template emits two edges":

  test "structural: repro.nim + repro_tests.nim declare two-edge emission per TestSpec":
    let repoRoot = findRepoRoot()
    let reproNim = repoRoot / "repro.nim"
    let reproTests = repoRoot / "repro_tests.nim"
    check fileExists(reproNim)
    check fileExists(reproTests)

    let reproNimText = readFile(reproNim)
    let reproTestsText = readFile(reproTests)

    check "buildNimUnittest.build(" in reproNimText
    check "edge.testBinary.run(" in reproNimText
    let buildIdx = reproNimText.find("buildNimUnittest.build(")
    let execIdx = reproNimText.find("edge.testBinary.run(")
    check buildIdx >= 0
    check execIdx >= 0
    check execIdx > buildIdx

    check "reprobuild.test_execute." in reproNimText
    check "reproTestExecuteId" in reproNimText
    check "collect(\"test\", reprobuildTestExecuteActions" in reproNimText
    check "collect(\"test-builds\", reprobuildTestBuildActions" in reproNimText
    check "reprobuildTestBuildActions" in reproNimText
    check "reprobuildTestExecuteActions" in reproNimText
    check "spec.requiresReproBinary" in reproNimText
    check "requiredBinaries" in reproNimText
    check "reproBinaryPath" in reproNimText
    check "build/bin/repro" in reproNimText
    check "Bootstrap-And-Self-Build B3" in reproNimText

    check "requiresReproBinary*: bool" in reproTestsText
    check "requiresReproBinary:" in reproTestsText
    let sourceCount = countOccurrences(reproTestsText, "source:")
    checkpoint("repro_tests.nim source rows: " & $sourceCount)
    check sourceCount >= 520

    let trueCount = countOccurrences(reproTestsText,
      "requiresReproBinary: true")
    checkpoint("repro_tests.nim requiresReproBinary: true count: " &
      $trueCount)
    check trueCount >= 5

    var unflagged: seq[string] = @[]
    for source in KnownReproBinaryConsumers:
      let marker = "source: \"" & source & "\""
      let pos = reproTestsText.find(marker)
      if pos < 0:
        checkpoint("known consumer not in table: " & source)
        unflagged.add(source)
        continue
      let limit = min(reproTestsText.len, pos + 400)
      let slice = reproTestsText[pos ..< limit]
      if "requiresReproBinary: true" notin slice:
        unflagged.add(source)
    if unflagged.len > 0:
      checkpoint("known repro-binary consumers missing the flag: " &
        unflagged.join(", "))
    check unflagged.len == 0

  test "engine: direct execute-edge graphs contain build and execute edges":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    check fileExists(reproBin)

    if fileExists(reproBin):
      var missingBuild = initHashSet[string]()
      var missingExecute = initHashSet[string]()
      var missingLaunch = initHashSet[string]()

      for stem in SampleStems:
        let selector = ".#reprobuild.test_execute." & stem
        let (graph, output, exitCode) =
          graphJsonFor(reproBin, repoRoot, selector)
        checkpoint(selector & " graph exit=" & $exitCode)
        if exitCode != 0:
          checkpoint(output)
        check exitCode == 0
        # NOT ``check graph != nil``: on failure ``check`` stringifies its
        # operands, and ``$`` on a nil ``JsonNode`` segfaults, so a failed
        # ``repro graph`` killed this case (SIGSEGV, no result document)
        # instead of reporting the graph error checkpointed above.
        check not graph.isNil

        # The compile writes ``<stem>.exe`` on Windows and declares exactly
        # that; the execute edge must name the same file, or nothing orders
        # the compile before it and the edge launches a path no edge
        # produces (reprobuild-pm issue 2026-11-17-windows-test-execute-
        # edge-launches-the-test-binary-without-its-exe-suffix).
        let binaryPath = "build/test-bin/" & addFileExt(stem, ExeExt)
        var sawBuild = false
        var sawExecute = false
        var launchesBuilt = false
        if graph != nil:
          let actions = graph{"actions"}
          check not actions.isNil
          if not actions.isNil:
            for action in actions:
              let id = action{"id"}.getStr()
              if id == "reprobuild.test_execute." & stem:
                sawExecute = true
                # The program the edge starts is argv[0], spelled absolute
                # (and with `\` on Windows) by the lowering.
                let argv = action{"argv"}
                if not argv.isNil and argv.kind == JArray and argv.len > 0:
                  let program = argv[0].getStr().replace('\\', '/')
                  checkpoint(stem & " execute argv[0]: " & program)
                  launchesBuilt = program.endsWith("/" & binaryPath)
              for outputPath in actionOutputs(action):
                if outputPath.getStr() == binaryPath:
                  sawBuild = true
        if not launchesBuilt:
          missingLaunch.incl(stem)

        if not sawBuild:
          missingBuild.incl(stem)
        if not sawExecute:
          missingExecute.incl(stem)

      checkpoint("missing build stems: " & $toSeq(missingBuild))
      checkpoint("missing execute stems: " & $toSeq(missingExecute))
      checkpoint("execute edges launching another path: " &
        $toSeq(missingLaunch))
      check missingBuild.len == 0
      check missingExecute.len == 0
      check missingLaunch.len == 0

  test "engine: a test that runs a build/bin image gets the libraries it loads":
    # The property: the closure of an execute edge that runs a ``build/bin``
    # image is enough to START that image. On Windows the images load
    # ``clingo.dll``, ``libzstd.dll``, ``sqlite3*.dll`` and the OpenSSL pair
    # from their own directory, and ``repro.nim`` stages each one it can
    # resolve with a ``reprobuild.apps.stage_*`` copy edge. Those edges were
    # members of ``.#apps`` only, so ``repro build '.#test#<name>'`` in a
    # fresh checkout built a ``build\bin\repro.exe`` that failed with
    # ``could not load: libcrypto-3-x64.dll`` (reprobuild-pm issue
    # 2026-11-17-windows-test-closure-builds-a-repro-exe-that-cannot-load-
    # openssl). On Linux and macOS the images carry an RPATH instead, and
    # there are no staging edges.
    #
    # Three parts, each meaningful on every host:
    #
    #   1. The two CLI images in this tree start with ``--version`` in a
    #      minimal environment, so nothing outside what the build put in
    #      place (beside the image, or in its RPATH) supplies a library. Run
    #      through ``repro build '.#test#t_b3_test_template_emits_two_edges'``
    #      the images are this test's own closure's, so on Windows before the
    #      fix this part failed in a fresh checkout.
    #   2. Two consumers -- a single test and a GROUP edge -- declare both CLI
    #      images as inputs (the group through its member's fixture row as
    #      well), so part 3 checks edges that really run them.
    #   3. Every staging edge ``.#apps`` has on this host is a direct dep of
    #      each consumer's execute edge (so a narrow selection stages it
    #      first), and every file it writes is a declared input of that edge
    #      (so a different DLL re-runs the test).
    #      On Windows the reference is not empty: the engine is linked with
    #      ``--define:ssl``, so a host that compiled it has the OpenSSL pair.
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / ReproImage
    let engineBin = repoRoot / EngineImage
    check fileExists(reproBin)
    check fileExists(engineBin)

    if fileExists(reproBin) and fileExists(engineBin):
      for image in [reproBin, engineBin]:
        let (output, exitCode) = startInMinimalEnvironment(image)
        checkpoint(image & " --version in a minimal environment: exit=" &
          $exitCode & "\n" & output)
        check exitCode == 0

      let apps = closureView(reproBin, repoRoot, ".#apps", "")
      check apps.ok
      checkpoint("staging edges in .#apps: " & $toSeq(apps.stageIds))
      when defined(windows):
        check apps.stageIds.len > 0
        when defined(amd64):
          check (StagePrefix & "libcrypto_3_x64") in apps.stageIds
          check (StagePrefix & "libssl_3_x64") in apps.stageIds

      let peerGroup = groupOfSource(repoRoot, GroupedCliConsumerSource)
      checkpoint(GroupedCliConsumerSource & " group: " & peerGroup)
      check peerGroup.len > 0
      let consumers = [
        (id: "reprobuild.test_execute." & SingleCliConsumer,
          fixture: ""),
        (id: "reprobuild.test_execute." & peerGroup,
          fixture: "build/bin/" &
            addFileExt("repro-peer-cache-admin", ExeExt))]
      for consumer in consumers:
        let view = closureView(reproBin, repoRoot, ".#" & consumer.id,
          consumer.id)
        check view.ok
        check view.consumerFound
        checkpoint(consumer.id & " inputs: " & $view.consumerInputs)
        check view.consumerInputs.declaresFile(ReproImage)
        check view.consumerInputs.declaresFile(EngineImage)
        if consumer.fixture.len > 0:
          check view.consumerInputs.declaresFile(consumer.fixture)
        var missingIds: seq[string] = @[]
        for stageId in apps.stageIds:
          if stageId notin view.consumerDeps or stageId notin view.stageIds:
            missingIds.add(stageId)
        var undeclared: seq[string] = @[]
        for staged in apps.stagedOutputs:
          if not view.consumerInputs.declaresFile(staged):
            undeclared.add(staged)
        checkpoint(consumer.id & " is not ordered after staging edges: " &
          $missingIds)
        checkpoint(consumer.id & " does not declare staged files: " &
          $undeclared)
        check missingIds.len == 0
        check undeclared.len == 0
