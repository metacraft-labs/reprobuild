## repro-cmake-dyndep-fragment: turns CMake's module scanner output into a
## ``repro-dynamic-graph-v1`` fragment.
##
## The Reprobuild CMake generator's dyndep wrapper runs it, after
## ``cmake -E cmake_ninja_dyndep``, as
##
##   repro-cmake-dyndep-fragment --out <fragment> --map <map> <ddi>...
##
## ``<map>`` holds one ``<primary-output>\t<action-id>`` line per compile
## action; each ``<ddi>`` is one scanner output (P1689 JSON, version 0 or
## 1). The fragment names, for each compile, the module files it writes
## (``output``) and the compiles of the modules it imports (``dep``).
##
## The command line is the ``cli:`` section of this executable in
## reprobuild's root ``repro.nim``. The program imports that file with no
## mode define, so it compiles in the project DSL's thin mode, which keeps
## only the ``cli:`` sections and none of the engine. It instantiates the
## section with nim-entrypoints' ``cliProgramWithEntryPoint`` and registers
## the self-description entries (``describeProgram``), so
## ``--entrypoint=list`` names them and a package build writes its shell
## completion files from the description. Reprobuild's ``config.nims``
## defines ``reproEvalMode`` for every compile in the tree; the
## ``repro_cmake_dyndep_fragment.nims`` beside this file removes it for this
## program's compiles, and the ``static`` check below refuses a compile in
## any other mode before ``repro.nim`` is imported.
##
## Exit codes: 0 when the fragment is written; 1 when an input is missing or
## malformed (the message on stderr names it); clispec's usage code (2) for
## a command line it rejects, with clispec's error block on stderr; 0 for
## ``--help``, printed on stdout. A successful run prints nothing.

import std/[json, os, strutils, tables]
import repro_project_dsl/mode

static:
  doAssert reproDslMode == rdmThin,
    "repro-cmake-dyndep-fragment must import reprobuild's repro.nim in the " &
    "DSL's thin mode, but this compile is in " & $reproDslMode & ": remove " &
    "the mode define (reprobuild's config.nims defines reproEvalMode; " &
    "repro_cmake_dyndep_fragment.nims undefines it)"

import clispec, entrypoints, entrypoints/[clispec, describe]
import ../../repro
from repro_core/paths import extendedPath

reproCmakeDyndepFragmentCliDescription(cliProgramWithEntryPoint, DyndepArgs)

describeProgram(DyndepArgs)

type
  ScanInfo = object
    actionId: string
    primaryOutput: string
    provides: seq[tuple[name: string; modulePath: string]]
    requires: seq[string]

proc forwardSlash(p: string): string =
  # Windows: CMake emits path strings with `\\` separators in the dyndep
  # output JSON, but the rest of reprobuild's downstream lookups (action
  # map, dynamic graph) treat paths as forward-slash strings so the format
  # is platform-agnostic. Normalize at every read-time boundary so that
  # both writers and readers agree on a single canonical form.
  p.replace('\\', '/')

proc fail(message: string) {.noreturn.} =
  stderr.writeLine("repro-cmake-dyndep-fragment: " & message)
  quit 1

proc parseCommandLine(): DyndepArgs =
  ## The process's command line, parsed from the description. Help is
  ## printed on stdout and ends the process with 0; a usage error is printed
  ## as clispec's error block and ends it with the error's code.
  try:
    result = DyndepArgs.load()
    # `required` makes clispec insist on a value, not on a non-empty one;
    # an empty path is a usage error too, as it always was.
    for (spelling, value) in [("--out", result.out), ("--map", result.map)]:
      if value.len == 0:
        let e = newCliUsageError(cekInvalidValue,
          "repro-cmake-dyndep-fragment", @[], -1, spelling, value,
          "a non-empty path")
        # The usage line and the help hint of the root command (index 0),
        # as the parser adds them to the errors it raises.
        cliAddErrorContext(e, DyndepArgs.cliGrammar, 0)
        raise e
  except CliHelpRequest as e:
    DyndepArgs.printHelp(e)
    quit 0
  except CliUsageError as e:
    DyndepArgs.printError(e)
    quit e.exitCode

proc parseMap(path: string): Table[string, string] =
  if path.len == 0 or not fileExists(extendedPath(path)):
    fail("action map missing: " & path)
  let lines = readFile(extendedPath(path)).splitLines()
  for lineNo in 0 ..< lines.len:
    let line = lines[lineNo]
    if line.len == 0:
      continue
    let fields = line.split('\t')
    if fields.len != 2:
      fail(path & ":" & $(lineNo + 1) &
        ": expected '<primary-output>\\t<action-id>'")
    # Windows: normalize the lookup key so map writers on Windows and dyndep
    # readers using POSIX-style paths agree.
    result[forwardSlash(fields[0])] = fields[1]

proc stringField(node: JsonNode; name, path: string; required = true): string =
  if not node.hasKey(name):
    if required:
      fail(path & ": missing JSON field '" & name & "'")
    return ""
  if node[name].kind != JString:
    fail(path & ": JSON field '" & name & "' must be a string")
  node[name].getStr()

proc arrayField(node: JsonNode; name, path: string): JsonNode =
  if not node.hasKey(name):
    return newJArray()
  if node[name].kind != JArray:
    fail(path & ": JSON field '" & name & "' must be an array")
  node[name]

proc parseDdi(path: string; actionForOutput: Table[string, string]): ScanInfo =
  if not fileExists(extendedPath(path)):
    fail("scanner output missing: " & path)
  var root: JsonNode
  try:
    root = parseFile(path)
  except JsonParsingError as err:
    fail(path & ": malformed JSON: " & err.msg)
  if root.kind != JObject:
    fail(path & ": scanner output must be a JSON object")
  let version =
    if root.hasKey("version") and root["version"].kind == JInt:
      root["version"].getInt()
    else:
      fail(path & ": missing integer version")
  if version < 0 or version > 1:
    fail(path & ": unsupported scanner output version " & $version)
  let rules = arrayField(root, "rules", path)
  if rules.len != 1:
    fail(path & ": expected exactly one scanner rule")
  let rule = rules[0]
  if rule.kind != JObject:
    fail(path & ": scanner rule must be an object")
  # Windows: CMake emits paths with backslashes in dyndep JSON. Normalize
  # primaryOutput and compiled-module-path strings to forward-slash form so
  # the output dynamic graph is platform-agnostic and matches the action map.
  result.primaryOutput = forwardSlash(stringField(rule, "primary-output", path))
  if not actionForOutput.hasKey(result.primaryOutput):
    fail(path & ": primary output is absent from action map: " &
      result.primaryOutput)
  result.actionId = actionForOutput[result.primaryOutput]
  for item in arrayField(rule, "provides", path):
    if item.kind != JObject:
      fail(path & ": provides item must be an object")
    result.provides.add((
      name: stringField(item, "logical-name", path),
      modulePath: forwardSlash(
        stringField(item, "compiled-module-path", path, required = false))))
  for item in arrayField(rule, "requires", path):
    if item.kind != JObject:
      fail(path & ": requires item must be an object")
    result.requires.add(stringField(item, "logical-name", path))

proc writeFragment(outPath, mapPath: string; ddiPaths: openArray[string]) =
  ## Reads the action map and the scanner outputs and writes the fragment
  ## to ``outPath``; ends the process with 1, naming the input, on the first
  ## one that is missing or malformed.
  let actionForOutput = parseMap(mapPath)
  var scans: seq[ScanInfo] = @[]
  var providerForModule = initTable[string, string]()
  var outputForModule = initTable[string, string]()
  for ddi in ddiPaths:
    let info = parseDdi(ddi, actionForOutput)
    for provide in info.provides:
      if providerForModule.hasKey(provide.name) and
          providerForModule[provide.name] != info.actionId:
        fail(ddi & ": duplicate provider for module " & provide.name)
      providerForModule[provide.name] = info.actionId
      if provide.modulePath.len > 0:
        outputForModule[provide.name] = provide.modulePath
    scans.add(info)

  var text = "repro-dynamic-graph-v1\n"
  for info in scans:
    for provide in info.provides:
      if outputForModule.hasKey(provide.name):
        text.add("output\t" & info.actionId & "\t" &
          outputForModule[provide.name] & "\n")
    for require in info.requires:
      if not providerForModule.hasKey(require):
        fail("module requirement has no provider in selected scanner output: " &
          require)
      let dep = providerForModule[require]
      if dep != info.actionId:
        text.add("dep\t" & info.actionId & "\t" & dep & "\n")
  createDir(extendedPath(parentDir(outPath)))
  writeFile(extendedPath(outPath), text)

main:
  let args = parseCommandLine()
  writeFragment(args.out, args.map, args.ddi)
