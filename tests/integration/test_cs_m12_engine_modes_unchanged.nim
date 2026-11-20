## The engine's compilations of a recipe give the same results after the DSL
## gained a thin default mode.
##
## ``import reprobuild`` (and ``repro_project_dsl``, ``repro_dsl_stdlib``)
## used to compile the whole DSL whatever the compilation was. Since the thin
## mode became the default, the umbrellas compile the whole DSL only when a
## mode define selects it (``repro_project_dsl/mode``), and every engine
## compilation passes the define of the mode it needs. This test pins what
## those compilations produce for one fixture project
## (``tests/fixtures/cs_m12_engine_modes/repro.nim``, copied to a scratch
## directory so it is a project outside this tree):
##
## * INTERFACE: ``extractInterfaceFromModule``, the engine's interface
##   extraction (``-d:reproInterfaceMode``). Compared: the projected
##   ``ProjectInterface`` and the generated interface stub module.
## * PROVIDER: ``compileProviderBinary``, the engine's provider compile
##   (``-d:reproProviderMode``), then the provider answers a manifest request
##   and the root graph invocation through the single-shot file protocol.
##   Compared: both responses.
## * EVALUATION: a program that imports the recipe, compiled with the
##   consumer path set and ``-d:reproEvalMode`` the way the engine's
##   in-process compilations are, prints every registry the recipe filled at
##   module initialization. Compared: that output.
##
## The goldens under ``tests/fixtures/cs_m12_engine_modes/golden`` were
## recorded from the tree BEFORE the change, with this test in record mode
## (``REPRO_CS_M12_RECORD=1``). They are normalized only for the scratch
## directory, this checkout's location and the content digests derived from
## those paths, and a graph node's binary payload is compared decoded (an
## action, the target-export table) or as its printable strings
## (``printableRuns``), because the length prefixes in it count the bytes of
## those paths. So they do not depend on
## where the test runs. When an
## intended change to the engine's output for this fixture breaks a golden,
## re-record it and review the diff.
##
## The negative control compiles the evaluation program WITHOUT the define.
## Under the thin default that program must not reproduce the evaluation
## golden: it either fails to compile on a name only the full DSL declares,
## or prints something else. If the define stopped mattering, the control
## fails.
##
## What the goldens hold is the fixture's own: the evaluation dump lists only
## the packages the fixture declares or uses, and a
## location in this repository's standard library keeps its file but not its
## line. Editing an unrelated standard-library package does not break them.
##
## This repository's own ``repro.nim`` was compared the same way when the
## modes were introduced, once, by digest of the same three compilations
## before and after. It is not a case here: its output changes with every
## edit to ``repro.nim``, so a golden of it would not stay true.

import std/[algorithm, os, osproc, sequtils, strutils, unittest]

import repro_hash
import repro_interface_artifacts
import repro_project_dsl
import repro_provider_runtime
import repro_test_support

const
  FixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" / "cs_m12_engine_modes"
  GoldenDir = FixtureDir / "golden"
  RecordEnv = "REPRO_CS_M12_RECORD"

let recording = getEnv(RecordEnv) == "1"
let scratchRoot = getTempDir() / ("cs-m12-engine-modes-" & $getCurrentProcessId())
var goldenMismatch = false
  ## Set when an output differs from its golden: the scratch directory, which
  ## holds this run's output, is then kept for the diff.

proc blankDigests(text: string): string =
  ## Every run of 32 or more hexadecimal digits or lower-case base-32 letters
  ## (content digests, Nix store hashes) becomes ``<DIGEST>``.
  const Hashy = HexDigits + {'a' .. 'z'}
  var i = 0
  while i < text.len:
    if text[i] in Hashy and (i == 0 or text[i - 1] notin IdentChars):
      var j = i
      while j < text.len and text[j] in Hashy:
        inc j
      let word = text[i ..< j]
      if word.len >= 32 and (j == text.len or text[j] notin IdentChars) and
          word.anyIt(it in Digits):
        result.add("<DIGEST>")
      else:
        result.add(word)
      i = j
    else:
      result.add(text[i])
      inc i

proc blankSriHashes(text: string): string =
  ## Every ``sha256-<base64>`` hash (a Nix NAR hash) becomes ``<DIGEST>``.
  const Prefix = "sha256-"
  const Base64 = Letters + Digits + {'+', '/'}
  var i = 0
  while i < text.len:
    if text.continuesWith(Prefix, i):
      var j = i + Prefix.len
      while j < text.len and text[j] in Base64:
        inc j
      while j < text.len and text[j] == '=':
        inc j
      if j - i - Prefix.len >= 43:
        result.add("<DIGEST>")
        i = j
        continue
    result.add(text[i])
    inc i

proc blankLibraryLines(text: string): string =
  ## A location in this repository (``"<REPROBUILD>/…", line: 12`` or
  ## ``sourceLine: 12``) keeps its file and loses its line, so the goldens do
  ## not move when a standard-library module gains or loses a line. The
  ## fixture's own locations (``<SCRATCH>``) keep theirs.
  const Mark = "<REPROBUILD>"
  var i = 0
  while i < text.len:
    let at = text.find(Mark, i)
    if at < 0:
      result.add(text[i .. ^1])
      break
    let close = text.find('"', at)
    if close < 0:
      result.add(text[i .. ^1])
      break
    result.add(text[i .. close])
    i = close + 1
    for key in [", line: ", ", sourceLine: "]:
      if text.continuesWith(key, i):
        var j = i + key.len
        while j < text.len and text[j] in Digits:
          inc j
        if j > i + key.len:
          result.add(key & "<LINE>")
          i = j
        break

proc normalized(text, scratch: string): string =
  ## Replace what depends on where the test runs: the scratch directory, this
  ## checkout and the workspace around it, the home directory, and the
  ## content digests (paths go into most of them). Longest prefix first.
  ## Then the lines of locations in this repository (``blankLibraryLines``).
  result = text
  var roots = @[(scratch, "<SCRATCH>"),
    (ReprobuildRepoRoot, "<REPROBUILD>"),
    (ReprobuildRepoRoot.parentDir, "<WORKSPACE>")]
  let home = getHomeDir().strip(leading = false, chars = {'/'})
  if home.len > 1:
    roots.add((home, "<HOME>"))
  roots.sort(proc (a, b: (string, string)): int = cmp(b[0].len, a[0].len))
  for (root, mark) in roots:
    result = result.replace(root, mark)
  result = blankLibraryLines(blankSriHashes(blankDigests(result)))

proc matchesGolden(name, actual: string): bool =
  ## True when ``actual`` equals the golden ``name``. In record mode it writes
  ## the golden instead and answers true.
  let golden = GoldenDir / name
  if recording:
    createDir(GoldenDir)
    writeFile(golden, actual)
    checkpoint("recorded " & golden)
    return true
  if not fileExists(golden):
    checkpoint("no golden " & golden & " (record it with " & RecordEnv & "=1)")
    return false
  result = readFile(golden) == actual
  if not result:
    goldenMismatch = true
    let actualPath = scratchRoot / ("actual-" & name)
    writeFile(actualPath, actual)
    checkpoint(name & " differs from its golden; this run's output is in " &
      actualPath & " (diff it against " & golden & ")")

proc copyFixture(dest: string): string =
  createDir(dest)
  copyFile(FixtureDir / "repro.nim", dest / "repro.nim")
  dest / "repro.nim"

# --------------------------------------------------------------------------
# The three compilations
# --------------------------------------------------------------------------

type EngineResults = object
  interfaceText: string
  stubText: string
  manifestText: string
  rootText: string
  evalText: string

proc interfaceLeg(modulePath, outDir: string;
                  res: var EngineResults): ProjectInterfaceArtifact =
  createDir(outDir)
  let stubPath = outDir / "interface.nim"
  result = extractInterfaceFromModule(modulePath, outDir / "interface.rbsz",
    stubPath, ReprobuildRepoRoot, scratchDir = outDir / "scratch",
    useExtractionCache = false)
  res.interfaceText = $result.projectInterface & "\n"
  res.stubText = readFile(stubPath)

proc printableRuns(payload: string): string =
  ## The runs of three or more printable characters in a binary payload,
  ## joined by `` | ``. A node's payload is an encoded record whose strings
  ## carry length prefixes, and a path in it has a length that depends on
  ## where the test runs; normalizing the path's text would leave its length
  ## behind. The strings themselves are what is compared.
  var run = ""
  proc flush(acc: var string; run: var string) =
    if run.len >= 3:
      if acc.len > 0: acc.add(" | ")
      acc.add(run)
    run = ""
  for ch in payload:
    if ch in {' ' .. '~'}:
      run.add(ch)
    else:
      flush(result, run)
  flush(result, run)

proc readable(response: ProviderGraphResponse): ProviderGraphResponse =
  ## Each graph node's binary payload decoded where the DSL has a decoder for
  ## it (an action, the target-export table), otherwise as its printable
  ## strings.
  result = response
  for node in result.fragment.nodes.mitems:
    var bytes = newSeq[byte](node.payload.len)
    for i, ch in node.payload:
      bytes[i] = byte(ch)
    node.payload =
      if node.payload.startsWith("RBAP"): $decodeBuildActionPayload(bytes)
      elif node.payload.startsWith("RTET"): $decodeTargetExportTablePayload(bytes)
      else: printableRuns(node.payload)

proc runProvider(binary, workDir, outDir: string;
                 request: ProviderGraphRequest): ProviderGraphResponse =
  ## ``workDir`` is the project's root (for reprobuild's own leg, this
  ## checkout), so the request and response files go to ``outDir``.
  let requestPath = outDir / ("request-" & $request.kind & ".rbsz")
  let responsePath = outDir / ("response-" & $request.kind & ".rbsz")
  writeProviderRequestFile(requestPath, request)
  let (output, code) = execCmdEx(quoteShellCommand([binary,
    "--repro-provider-request", requestPath,
    "--repro-provider-response", responsePath]), workingDir = workDir)
  if code != 0:
    raise newException(IOError, "provider " & binary & " exited " & $code &
      ":\n" & output)
  readProviderResponseFile(responsePath)

proc providerLeg(modulePath, packageName, outDir: string;
                 artifact: ProjectInterfaceArtifact;
                 res: var EngineResults) =
  createDir(outDir)
  let binPath = outDir / "provider"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, ReprobuildRepoRoot,
    scratchDir = outDir / "scratch")
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, outDir / "provider-compile.rbsz",
    ReprobuildRepoRoot, scratchDir = outDir / "scratch",
    useFreshnessCache = false)
  let artifactId = toHex(plan.providerArtifactId.bytes)
  let projectRoot = modulePath.parentDir
  let manifest = runProvider(compiled.outputBinaryPath, projectRoot, outDir,
    ProviderGraphRequest(kind: prkManifest, providerArtifactId: artifactId))
  res.manifestText = $readable(manifest) & "\n"
  let root = runProvider(compiled.outputBinaryPath, projectRoot, outDir,
    ProviderGraphRequest(kind: prkGraphInvocation,
      providerArtifactId: artifactId,
      entryPointId: packageName & ".root",
      entryPointBodyHash: packageName & ".build.v1",
      reason: girColdStart,
      arguments: projectRoot,
      namespace: packageName,
      lockSliceId: "cs-m12-lock",
      activity: "default"))
  res.rootText = $readable(root) & "\n"

const EvalProgram = """
import std/[algorithm, sequtils]
import "@MODULE@"
import reprobuild

proc show[T](label: string; items: seq[T]) =
  echo "== ", label, " (", items.len, ")"
  var lines = items.mapIt($it)
  lines.sort()
  for line in lines:
    echo line

# The fixture's package and the tool packages its `uses:` names; the
# standard library registers many more, which are not the fixture's.
show("packages", registeredPackages().filterIt(
  it.packageName in ["csm12tool", "sh", "mkdir", "printf"]))
show("build actions", registeredBuildActions())
show("build targets", registeredBuildTargets())
show("aggregates", registeredAggregates())
show("collections", registeredCollections())
show("build pools", registeredBuildPools())
show("workspace deps", registeredWorkspaceDeps())
echo "== default build action"
echo registeredDefaultBuildAction()
"""

proc evalCompile(modulePath, outDir: string;
                 defines: openArray[string]): tuple[ok: bool; output: string] =
  ## Compile and run a program that imports the recipe, as the engine's
  ## in-process compilations do. ``ok`` is false when it does not compile.
  createDir(outDir)
  let programPath = outDir / "cs_m12_eval_dump.nim"
  writeFile(programPath,
    EvalProgram.replace("@MODULE@", modulePath.changeFileExt("")))
  var command = @["nim", "c", "--hints:off", "--warnings:off",
    "--parallelBuild:4", "--nimcache:" & (outDir / "nimcache"),
    "--out:" & (outDir / "eval-dump")]
  for d in defines:
    command.add("--define:" & d)
  command.add(consumerCompilePathFlags(ReprobuildRepoRoot))
  command.add(programPath)
  let (compileOutput, compileCode) = execCmdEx(quoteShellCommand(command),
    workingDir = outDir)
  if compileCode != 0:
    return (false, compileOutput)
  let (output, code) = execCmdEx(quoteShellCommand([outDir / "eval-dump"]),
    workingDir = modulePath.parentDir)
  if code != 0:
    raise newException(IOError, "eval dump exited " & $code & ":\n" & output)
  (true, output)

proc engineResults(modulePath, packageName, outDir: string): EngineResults =
  let artifact = interfaceLeg(modulePath, outDir / "interface", result)
  providerLeg(modulePath, packageName, outDir / "provider", artifact, result)
  let evaluated = evalCompile(modulePath, outDir / "eval", ["reproEvalMode"])
  if not evaluated.ok:
    raise newException(IOError, "the evaluation compile failed:\n" &
      evaluated.output)
  result.evalText = evaluated.output

# --------------------------------------------------------------------------

removeDir(scratchRoot)
createDir(scratchRoot)

suite "test_cs_m12_engine_modes_unchanged":

  let fixtureModule = copyFixture(scratchRoot / "project")
  let fixture = engineResults(fixtureModule, "csm12tool", scratchRoot / "out")

  test "interface extraction of the fixture is unchanged":
    check matchesGolden("interface.txt",
      normalized(fixture.interfaceText, scratchRoot))
    check matchesGolden("interface-stub.nim.txt",
      normalized(fixture.stubText, scratchRoot))

  test "the fixture's provider answers as before":
    check matchesGolden("provider-manifest.txt",
      normalized(fixture.manifestText, scratchRoot))
    check matchesGolden("provider-root.txt",
      normalized(fixture.rootText, scratchRoot))

  test "in-process evaluation of the fixture is unchanged":
    check matchesGolden("evaluation.txt",
      normalized(fixture.evalText, scratchRoot))

  test "negative control: without the define the evaluation is not reproduced":
    if recording:
      checkpoint("record mode: the control compares against the golden")
    else:
      let golden = readFile(GoldenDir / "evaluation.txt")
      let bare = evalCompile(fixtureModule, scratchRoot / "out" / "eval-bare", [])
      checkpoint("compiled: " & $bare.ok)
      if not bare.ok:
        checkpoint(bare.output.splitLines.filterIt("Error" in it).join("\n"))
      # A failed compile counts only when it failed for the reason the thin
      # mode gives: a name of the full DSL is not declared (today the first
      # is in the standard library's `sh` package, which the fixture imports
      # and whose helpers use the full DSL's types). A module that cannot be
      # found would make the control pass without testing the define.
      if bare.ok:
        check normalized(bare.output, scratchRoot) != golden
      else:
        check "Error: undeclared identifier" in bare.output
        check "cannot open file" notin bare.output

if not recording and not goldenMismatch and
    getEnv("REPRO_CS_M12_KEEP") != "1":
  removeDirEventually(scratchRoot)
