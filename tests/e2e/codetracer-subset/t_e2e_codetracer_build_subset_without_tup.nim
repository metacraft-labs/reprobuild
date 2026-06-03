import std/[json, os, osproc, sequtils, strutils, tables, tempfiles, unittest]

import repro_tool_profiles
import repro_test_support

const
  NimFirstFlag = "-d:asyncBackend=asyncdispatch"
  NimSubcmdProc = "subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch"
  NimJsSemanticsHash = "02d964fa722450c1"
  TraceObjectFileSemanticsHash = "3d1a52e3befe61cf"

type
  TupRules = object
    variables: Table[string, string]
    macros: Table[string, string]

proc q(value: string): string =
  quoteShell(value)

proc pathHasExecutable(name, pathValue: string): bool =
  when defined(windows):
    findExe(name).len > 0
  else:
    runShell(shellCommand(@["sh", "-c", "command -v " & q(name)],
      @[(name: "PATH", value: pathValue)])).code == 0

when isNixSupported:
  proc nixBuildOutPath(selector: string): string =
    let res = runShell(shellCommand(@[
      "nix", "build", "--no-link", "--print-out-paths", selector
    ]))
    if res.code != 0:
      checkpoint(res.output)
      return ""
    for line in res.output.splitLines:
      let path = line.strip()
      if path.startsWith("/nix/store/"):
        return path
    checkpoint(res.output)
    ""

proc pathWithNixFallbackTools(pathValue: string): string =
  result = pathValue
  when isNixSupported:
    if not pathHasExecutable("node", result):
      let nodePath = nixBuildOutPath("nixpkgs#nodejs")
      if nodePath.len > 0:
        result = nodePath / "bin" & $PathSep & result

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
  if not fileExists(daemonBin):
    raise newException(OSError,
      "runquotad binary missing at " & daemonBin & "; build it via " &
      "the test harness (scripts/run_tests.sh) — the test code must not " &
      "spawn `just build` for the sibling repo")
  let socketPath = "/tmp/repro-m20-rq-" & $getCurrentProcessId() & ".sock"
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "16000",
    "--memory-bytes", "17179869184"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc nimString(value: string): string =
  value.escape()

proc nimSeq(values: openArray[string]): string =
  result = "@["
  for index, value in values:
    if index > 0:
      result.add(", ")
    result.add(nimString(value))
  result.add("]")

proc logicalTupLines(path: string): seq[string] =
  var current = ""
  for rawLine in readFile(path).splitLines:
    let strippedRight = rawLine.strip(leading = false, trailing = true)
    if strippedRight.endsWith("\\"):
      current.add(strippedRight[0 .. ^2].strip() & " ")
    else:
      current.add(strippedRight)
      let logical = current.strip()
      if logical.len > 0 and not logical.startsWith("#"):
        result.add(logical)
      current = ""
  if current.strip().len > 0:
    result.add(current.strip())

proc loadTupRules(path: string): TupRules =
  result.variables = initTable[string, string]()
  result.macros = initTable[string, string]()
  for line in logicalTupLines(path):
    let eq = line.find('=')
    if eq < 0:
      continue
    let key = line[0 ..< eq].strip()
    let value = line[eq + 1 .. ^1].strip()
    if key.startsWith("!"):
      result.macros[key] = value
    elif key.allIt(it.isAlphaNumeric() or it == '_'):
      result.variables[key] = value

proc expandTupVars(value: string; variables: Table[string, string]): string =
  result = value
  for _ in 0 ..< 32:
    let start = result.find("$(")
    if start < 0:
      return
    let finish = result.find(")", start + 2)
    if finish < 0:
      raise newException(ValueError, "unterminated Tup variable in: " & result)
    let name = result[start + 2 ..< finish]
    if not variables.hasKey(name):
      raise newException(ValueError, "unknown Tup variable $(" & name & ")")
    result = result[0 ..< start] & variables[name] & result[finish + 1 .. ^1]
  raise newException(ValueError, "recursive Tup variable expansion: " & value)

proc tupRuleParts(rules: TupRules; name: string): tuple[command: string;
    outputs: seq[string]] =
  if not rules.macros.hasKey(name):
    raise newException(ValueError, "missing Tup macro " & name)
  let macroBody = rules.macros[name]
  let first = macroBody.find("|>")
  let second = macroBody.find("|>", first + 2)
  if first < 0 or second < 0:
    raise newException(ValueError, "Tup macro has no command/output split: " & name)
  var command = macroBody[first + 2 ..< second].strip()
  if command.startsWith("^"):
    let markerEnd = command.find("^", 1)
    if markerEnd < 0:
      raise newException(ValueError, "unterminated Tup display marker: " & name)
    command = command[markerEnd + 1 .. ^1].strip()
  let expanded = expandTupVars(command, rules.variables)
  let outputText = macroBody[second + 2 .. ^1].strip()
  result = (command: expanded, outputs: outputText.splitWhitespace())

proc tupCommandTemplate(rules: TupRules; name: string): seq[string] =
  tupRuleParts(rules, name).command.splitWhitespace()

proc tupOutputPatterns(rules: TupRules; name: string): seq[string] =
  tupRuleParts(rules, name).outputs

proc replaceTupPlaceholders(token, sourcePath, outputPath: string): string =
  token.replace("%f", sourcePath).replace("%o", outputPath)

proc tupCommand(rules: TupRules; name, sourcePath, outputPath: string): seq[string] =
  for token in tupCommandTemplate(rules, name):
    result.add(replaceTupPlaceholders(token, sourcePath, outputPath))

proc nimCfgPathArgs(codeTracerRoot: string): seq[string] =
  for line in readFile(codeTracerRoot / "nim.cfg").splitLines:
    let stripped = line.strip()
    if stripped.startsWith("path:\"") and stripped.endsWith("\""):
      let relativePath = stripped["path:\"".len .. ^2]
      result.add("--path:" & codeTracerRoot / relativePath)

proc withNimConfigPathContext(command: openArray[string];
                              codeTracerRoot: string): seq[string] =
  for item in command:
    result.add(item)
  let jsIndex = result.find("js")
  if jsIndex < 0:
    raise newException(ValueError, "!nim_js command has no js subcommand")
  for index, pathArg in nimCfgPathArgs(codeTracerRoot):
    result.insert(pathArg, jsIndex + index)

proc stableHash64(text: string): string =
  var hash = 0xcbf29ce484222325'u64
  for ch in text:
    hash = hash xor uint64(ord(ch))
    hash = hash * 0x100000001b3'u64
  result = hash.toHex(16).toLowerAscii()

proc tupSemanticsHash(rules: TupRules; name: string): string =
  let parts = tupRuleParts(rules, name)
  stableHash64(parts.command.splitWhitespace().join("\n") &
    "\noutputs\n" & parts.outputs.join("\n"))

proc assertCommittedTupSemantics(rules: TupRules) =
  check tupOutputPatterns(rules, "!nim_js") == @["%B.js"]
  check tupOutputPatterns(rules, "!trace_object_file") == @["%o"]
  check tupCommandTemplate(rules, "!nim_js")[0 .. 1] == @["nim", NimFirstFlag]
  check tupCommandTemplate(rules, "!trace_object_file")[0 .. 3] ==
    @["gcc", "-fPIC", "-g3", "-c"]
  check tupSemanticsHash(rules, "!nim_js") == NimJsSemanticsHash
  check tupSemanticsHash(rules, "!trace_object_file") ==
    TraceObjectFileSemanticsHash

proc actionArgs(command: openArray[string]): seq[string] =
  if command.len < 2:
    raise newException(ValueError, "command must include executable and subcommand")
  command[2 .. ^1]

proc generatedHeaderCCommand(traceCommand: openArray[string];
                             headerPath, outputPath: string): seq[string] =
  result = @[]
  var inserted = false
  var index = 0
  while index < traceCommand.len:
    if not inserted and traceCommand[index] == "-o":
      result.add("-include")
      result.add(headerPath)
      inserted = true
    if traceCommand[index] == "build/c/main.tup.o":
      result.add(outputPath)
    else:
      result.add(traceCommand[index])
    inc index
  if not inserted:
    raise newException(ValueError, "trace_object_file command has no -o flag")

proc copySelectedCodeTracerFiles(codeTracerRoot, projectRoot: string) =
  createDir(projectRoot / "src" / "frontend" / "tests")
  createDir(projectRoot / "src" / "frontend" / "index")
  createDir(projectRoot / "src" / "frontend" / "lib")
  createDir(projectRoot / "src" / "c")
  copyFile(codeTracerRoot / "src" / "frontend" / "tests" /
    "ipc_registry_test.nim",
    projectRoot / "src" / "frontend" / "tests" / "ipc_registry_test.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "index" /
    "ipc_registry.nim",
    projectRoot / "src" / "frontend" / "index" / "ipc_registry.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "lib" / "jslib.nim",
    projectRoot / "src" / "frontend" / "lib" / "jslib.nim")
  copyFile(codeTracerRoot / "test-programs" / "c_sudoku_solver" / "main.c",
    projectRoot / "src" / "c" / "main.c")

proc writeProject(path: string; nimJsCommand, traceObjectCommand,
                  generatedHeaderCCommand: openArray[string]) =
  createDir(path.splitPath.head)
  let headerScript =
    "set -eu\n" &
    "out=$1\n" &
    "mkdir -p \"$(dirname \"$out\")\" build/c\n" &
    "cat > \"$out\" <<'EOF'\n" &
    "#ifndef REPROBUILD_CT_SUBSET_CONFIG_H\n" &
    "#define REPROBUILD_CT_SUBSET_CONFIG_H\n" &
    "#define REPROBUILD_CT_SUBSET_GENERATED 1\n" &
    "#endif\n" &
    "EOF\n"
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package codeTracerSubset:\n" &
    "  uses:\n" &
    "    \"nim >=2.0\"\n" &
    "    \"node >=20\"\n" &
    "    \"gcc >=1\"\n" &
    "    \"sh >=1\"\n\n" &
    "  executable nimTool:\n" &
    "    name \"nim\"\n" &
    "    cli:\n" &
    "      subcmd " & nimString(NimFirstFlag) & ":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "  executable gccTool:\n" &
    "    name \"gcc\"\n" &
    "    cli:\n" &
    "      subcmd \"-fPIC\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n" &
    "      discard buildAction(\"generate-config-header\",\n" &
    "        codeTracerSubset.executable(\"sh\").subcmd_2d_c(\n" &
    "          args = @[" & nimString(headerScript) & ", " &
      nimString("sh") & ", " & nimString("build/generated/ct_config.h") & "]),\n" &
    "        outputs = @[" & nimString("build/generated/ct_config.h") & "])\n" &
    "      discard buildAction(\"nim-js-ipc-registry-test\",\n" &
    "        codeTracerSubset.executable(\"nim\")." & NimSubcmdProc & "(\n" &
    "          args = " & nimSeq(actionArgs(nimJsCommand)) & "),\n" &
    "        inputs = @[" &
      nimString("src/frontend/tests/ipc_registry_test.nim") & ", " &
      nimString("src/frontend/index/ipc_registry.nim") & ", " &
      nimString("src/frontend/lib/jslib.nim") & "],\n" &
    "        outputs = @[" & nimString("tests/ipc_registry_test.js") & "])\n" &
    "      discard buildAction(\"c-sudoku-object-tup\",\n" &
    "        codeTracerSubset.executable(\"gcc\").subcmd_2d_fPIC(\n" &
    "          args = " & nimSeq(actionArgs(traceObjectCommand)) & "),\n" &
    "        inputs = @[" & nimString("src/c/main.c") & "],\n" &
    "        outputs = @[" & nimString("build/c/main.tup.o") & "])\n" &
    "      discard buildAction(\"c-sudoku-object-with-generated-header\",\n" &
    "        codeTracerSubset.executable(\"gcc\").subcmd_2d_fPIC(\n" &
    "          args = " & nimSeq(actionArgs(generatedHeaderCCommand)) & "),\n" &
    "        deps = @[" & nimString("generate-config-header") & "],\n" &
    "        inputs = @[" &
      nimString("src/c/main.c") & ", " &
      nimString("build/generated/ct_config.h") & "],\n" &
    "        outputs = @[" & nimString("build/c/main.with-header.o") & "])\n")

proc build(reproBin, target, repoRoot, pathValue: string): string =
  # Pass `--log=actions` so the per-action `action: ID status=... ` evidence
  # lines appear in captured stdout. The default summary log only emits the
  # `progress: bpkActionCompleted ...` markers plus the `scheduler:` /
  # `providerInvocations:` / `buildReport:` headers; the assertions below
  # that key on the per-action shape need the action-level log.
  requireSuccess(shellCommand(@[reproBin, "build", target,
    "--tool-provisioning=path", "--log=actions"],
    @[(name: "PATH", value: pathValue)]), repoRoot)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc reportAction(report: JsonNode; id: string): JsonNode =
  for item in report{"actions"}:
    if item{"id"}.getStr() == id:
      return item
  newJNull()

proc assertAction(report: JsonNode; id, status: string; launched: bool) =
  let action = reportAction(report, id)
  check action.kind != JNull
  check action{"status"}.getStr() == status
  check action{"launched"}.getBool() == launched

proc assertActionCacheEffective(report: JsonNode; id: string) =
  ## "Cache was effective for this action on this build" — accepts
  ## either `asCacheHit` (cache decision hit + outputs had to be
  ## restored from CAS) or `asUpToDate` (cache decision hit + outputs
  ## already present, no restoration). Both are defined in
  ## `libs/repro_build_engine/.../repro_build_engine.nim` `ActionStatus`
  ## and both mean "this action did not rerun on this build"
  ## (`launched == false` in either case). The narrower `assertAction`
  ## remains in use for `asSucceeded`/`launched=true` checks where the
  ## precise status matters. Mirrors the helper M51 introduced after
  ## the May-2026 engine cache-decision protocol split.
  let action = reportAction(report, id)
  check action.kind != JNull
  check action{"status"}.getStr() in ["asCacheHit", "asUpToDate"]
  check action{"launched"}.getBool() == false

proc runNode(path, cwd, pathValue: string): string =
  requireSuccess(shellCommand(@["node", path],
    @[(name: "PATH", value: pathValue)]), cwd)

proc directOracle(projectRoot, outputPath: string; command: openArray[string];
                  pathValue: string) =
  createDir(projectRoot / outputPath.splitPath.head)
  discard requireSuccess(shellCommand(@command,
    @[(name: "PATH", value: pathValue)]), projectRoot)

proc mainSymbol(path, cwd: string): string =
  let output = requireSuccess(shellCommand(["nm", "-g", path]), cwd)
  for line in output.splitLines:
    if line.endsWith(" T _main") or line.endsWith(" T main"):
      return line.strip()
  output

proc jsonStringSet(node: JsonNode): seq[string] =
  for item in node.getElems():
    result.add(item.getStr())

suite "e2e_codetracer_build_subset_without_tup":
  test "real CodeTracer sources build through DSL, provider, RunQuota, cache, and committed Tup command semantics":
    let repoRoot = getCurrentDir()
    let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
    let tupRulesPath = codeTracerRoot / "src" / "Tuprules.tup"
    check fileExists(tupRulesPath)
    let tupRules = loadTupRules(tupRulesPath)
    assertCommittedTupSemantics(tupRules)
    let nimJsActionCommand = withNimConfigPathContext(
      tupCommand(tupRules, "!nim_js",
        "src/frontend/tests/ipc_registry_test.nim", "tests/ipc_registry_test.js"),
      codeTracerRoot)
    let nimJsOracleCommand = withNimConfigPathContext(
      tupCommand(tupRules, "!nim_js",
        "src/frontend/tests/ipc_registry_test.nim", "oracle/ipc_registry_test.js"),
      codeTracerRoot)
    let traceObjectActionCommand = tupCommand(tupRules, "!trace_object_file",
      "src/c/main.c", "build/c/main.tup.o")
    let traceObjectOracleCommand = tupCommand(tupRules, "!trace_object_file",
      "src/c/main.c", "oracle/main.o")
    let generatedHeaderCommand = generatedHeaderCCommand(
      traceObjectActionCommand, "build/generated/ct_config.h",
      "build/c/main.with-header.o")

    let tempRoot = createTempDir("repro-m20-codetracer-subset", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = tempRoot / "repro"
    discard requireSuccess(shellCommand([
      "nim", "c", "--verbosity:0", "--hints:off",
      "--nimcache:" & (tempRoot / "nimcache-repro"),
      "--out:" & reproBin,
      repoRoot / "apps" / "repro" / "repro.nim"
    ]), repoRoot)

    let projectRoot = tempRoot / "project"
    createDir(projectRoot)
    copySelectedCodeTracerFiles(codeTracerRoot, projectRoot)
    writeProject(projectRoot / "reprobuild.nim", nimJsActionCommand,
      traceObjectActionCommand, generatedHeaderCommand)
    let target = projectRoot
    let pathValue = pathWithNixFallbackTools(getEnv("PATH"))

    let first = build(reproBin, target, repoRoot, pathValue)
    check first.contains("provisioning-disabled mode active")
    check first.contains("providerCompile:")
    check first.contains("providerGraphSnapshot:")
    check first.contains("scheduler: actions=4")
    check first.contains("action: generate-config-header status=asSucceeded launched=true")
    check first.contains("action: nim-js-ipc-registry-test status=asSucceeded launched=true")
    check first.contains("action: c-sudoku-object-tup status=asSucceeded launched=true")
    check first.contains("action: c-sudoku-object-with-generated-header status=asSucceeded launched=true")
    check fileExists(projectRoot / "build" / "generated" / "ct_config.h")
    check fileExists(projectRoot / "tests" / "ipc_registry_test.js")
    check fileExists(projectRoot / "build" / "c" / "main.tup.o")
    check fileExists(projectRoot / "build" / "c" / "main.with-header.o")

    let identity = readPathOnlyBuildIdentity(valueAfter(first, "toolIdentity:"))
    check identity.profiles.len == 4
    check identity.profiles.allIt(it.installMethod == "path")
    check identity.profiles.allIt(it.cachePortability == cpLocalOnly)
    check identity.profiles.anyIt(it.executableName == "nim")
    check identity.profiles.anyIt(it.executableName == "node")
    check identity.profiles.anyIt(it.executableName == "gcc")
    check identity.profiles.anyIt(it.executableName == "sh")

    let firstReport = parseFile(valueAfter(first, "buildReport:"))
    assertAction(firstReport, "generate-config-header", "asSucceeded", true)
    assertAction(firstReport, "nim-js-ipc-registry-test", "asSucceeded", true)
    assertAction(firstReport, "c-sudoku-object-tup", "asSucceeded", true)
    assertAction(firstReport, "c-sudoku-object-with-generated-header",
      "asSucceeded", true)
    check reportAction(firstReport, "generate-config-header"){"runQuotaBackend"}.
      getStr().len > 0
    let tupCInputs = jsonStringSet(reportAction(firstReport, "c-sudoku-object-tup"){
      "evidence"}{"declaredInputs"})
    check tupCInputs.anyIt(it.endsWith("src/c/main.c"))
    check not tupCInputs.anyIt(it.endsWith("build/generated/ct_config.h"))
    let generatedHeaderCInputs = jsonStringSet(reportAction(firstReport,
      "c-sudoku-object-with-generated-header"){
      "evidence"}{"declaredInputs"})
    check generatedHeaderCInputs.anyIt(it.endsWith("src/c/main.c"))
    check generatedHeaderCInputs.anyIt(it.endsWith("build/generated/ct_config.h"))

    directOracle(projectRoot, "oracle/ipc_registry_test.js",
      nimJsOracleCommand, pathValue)
    check runNode("tests/ipc_registry_test.js", projectRoot, pathValue) ==
      runNode("oracle/ipc_registry_test.js", projectRoot, pathValue)
    check runNode("tests/ipc_registry_test.js", projectRoot, pathValue).contains(
      "[OK] handlers still invoked after reconnect")

    directOracle(projectRoot, "oracle/main.o", traceObjectOracleCommand,
      pathValue)
    check mainSymbol("build/c/main.tup.o", projectRoot) ==
      mainSymbol("oracle/main.o", projectRoot)
    check mainSymbol("build/c/main.with-header.o", projectRoot) ==
      mainSymbol("oracle/main.o", projectRoot)

    let second = build(reproBin, target, repoRoot, pathValue)
    let secondReport = parseFile(valueAfter(second, "buildReport:"))
    assertActionCacheEffective(secondReport, "generate-config-header")
    assertActionCacheEffective(secondReport, "nim-js-ipc-registry-test")
    assertActionCacheEffective(secondReport, "c-sudoku-object-tup")
    assertActionCacheEffective(secondReport,
      "c-sudoku-object-with-generated-header")

    writeFile(projectRoot / "src" / "c" / "main.c",
      readFile(projectRoot / "src" / "c" / "main.c") &
        "\n/* reprobuild m20 selected-source edit */\n")
    let cChanged = build(reproBin, target, repoRoot, pathValue)
    let cChangedReport = parseFile(valueAfter(cChanged, "buildReport:"))
    assertActionCacheEffective(cChangedReport, "generate-config-header")
    assertActionCacheEffective(cChangedReport, "nim-js-ipc-registry-test")
    assertAction(cChangedReport, "c-sudoku-object-tup", "asSucceeded", true)
    assertAction(cChangedReport, "c-sudoku-object-with-generated-header",
      "asSucceeded", true)

    removeFile(projectRoot / "build" / "generated" / "ct_config.h")
    let headerDeleted = build(reproBin, target, repoRoot, pathValue)
    let headerDeletedReport = parseFile(valueAfter(headerDeleted, "buildReport:"))
    assertAction(headerDeletedReport, "generate-config-header", "asSucceeded", true)
    assertActionCacheEffective(headerDeletedReport, "nim-js-ipc-registry-test")
    assertActionCacheEffective(headerDeletedReport, "c-sudoku-object-tup")
    assertAction(headerDeletedReport, "c-sudoku-object-with-generated-header",
      "asSucceeded", true)

    let noFlag = requireFailure(shellCommand([reproBin, "build", target]), repoRoot)
    check noFlag.contains("refusing implicit PATH fallback")
