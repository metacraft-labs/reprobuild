import std/[json, os, strutils, tables]
from repro_core/paths import extendedPath

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

proc usage() {.noreturn.} =
  fail("usage: repro-cmake-dyndep-fragment --out <fragment> --map <map> <ddi>...")

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

proc main() =
  var outPath = ""
  var mapPath = ""
  var ddiPaths: seq[string] = @[]
  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--out":
      inc i
      if i > paramCount():
        usage()
      outPath = paramStr(i)
    of "--map":
      inc i
      if i > paramCount():
        usage()
      mapPath = paramStr(i)
    else:
      if arg.startsWith("--"):
        usage()
      ddiPaths.add(arg)
    inc i
  if outPath.len == 0 or mapPath.len == 0 or ddiPaths.len == 0:
    usage()

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

main()
