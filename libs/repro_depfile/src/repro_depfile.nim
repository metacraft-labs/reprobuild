import std/[os, strutils]
from repro_core/paths import extendedPath

type
  DependencyReportErrorKind* = enum
    dreMissingFile
    dreUnsupportedFormat
    dreMalformed

  DependencyReportError* = object of CatchableError
    kind*: DependencyReportErrorKind

  DependencyPathSet* = object
    inputs*: seq[string]
    outputs*: seq[string]
    probes*: seq[string]
    diagnostics*: seq[string]

const
  MakeDepfileFormatName* = "make-depfile"
  NinjaDepfileFormatName* = "ninja-depfile"
  ReproPathSetFormatName* = "repro-pathset"
  MsvcShowIncludesFormatName* = "msvc-show-includes"
  ClangScanDepsJsonFormatName* = "clang-scan-deps-json"

proc raiseReport(kind: DependencyReportErrorKind; message: string) {.noreturn.} =
  var err = newException(DependencyReportError, message)
  err.kind = kind
  raise err

proc addUnique(values: var seq[string]; value: string) =
  if value.len == 0:
    return
  if values.find(value) < 0:
    values.add(value)

proc normalizeContinuations(text: string): string =
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    if text[i] == '\\':
      if i + 1 < text.len and text[i + 1] == '\n':
        result.add(' ')
        i += 2
        continue
      if i + 2 < text.len and text[i + 1] == '\r' and text[i + 2] == '\n':
        result.add(' ')
        i += 3
        continue
    result.add(text[i])
    inc i

proc flushToken(tokens: var seq[string]; token: var string) =
  if token.len > 0:
    tokens.add(token)
    token.setLen(0)

proc appendRule(pathSet: var DependencyPathSet; path: string;
                lineNo: int; targets, deps: seq[string]) =
  if targets.len == 0:
    raiseReport(dreMalformed, path & ":" & $lineNo & ": depfile rule has no outputs")
  for target in targets:
    pathSet.outputs.addUnique(target)
  for dep in deps:
    pathSet.inputs.addUnique(dep)

proc parseMakeLikeText(path, text: string): DependencyPathSet =
  let normalized = normalizeContinuations(text)
  var parsed: DependencyPathSet
  var token = ""
  var targets: seq[string] = @[]
  var deps: seq[string] = @[]
  var inDeps = false
  var sawRuleText = false
  var lineNo = 1
  var i = 0

  proc finishLine() =
    if inDeps:
      flushToken(deps, token)
    else:
      flushToken(targets, token)
    if targets.len > 0 or deps.len > 0 or inDeps or sawRuleText:
      if not inDeps:
        raiseReport(dreMalformed, path & ":" & $lineNo & ": depfile rule is missing ':'")
      parsed.appendRule(path, lineNo, targets, deps)
    targets.setLen(0)
    deps.setLen(0)
    token.setLen(0)
    inDeps = false
    sawRuleText = false

  while i < normalized.len:
    let ch = normalized[i]
    case ch
    of '\\':
      # GNU Make's depfile escape rules: ``\`` only escapes the next char
      # when it would otherwise be a Make meta-character (space, tab, the
      # depfile separators, ``$``, ``#``, or another ``\``). When the
      # next char is anything else — notably an alphanumeric, as in
      # Windows paths like ``D:\m\dev\foo`` — the backslash is a literal
      # path separator and must be preserved.
      # Without this distinction the parser silently drops ``\m``,
      # ``\d``, etc. from cargo/rustc-emitted ``.d`` depfiles on Windows,
      # mangling every input path and breaking the engine's
      # cache-invalidation logic.
      if i + 1 >= normalized.len:
        token.add('\\')
      elif normalized[i + 1] in {' ', '\t', ':', '\\', '#', '$'}:
        inc i
        token.add(normalized[i])
        sawRuleText = true
      else:
        token.add('\\')
        sawRuleText = true
    of '$':
      if i + 1 < normalized.len and normalized[i + 1] == '$':
        token.add('$')
        inc i
      else:
        token.add(ch)
      sawRuleText = true
    of '#':
      while i < normalized.len and normalized[i] notin {'\n', '\r'}:
        inc i
      dec i
    of ':':
      # Drive-letter heuristic for Windows depfiles. cargo + rustc emit
      # absolute Windows paths like ``D:\foo\target.d: D:\src\lib.rs``
      # without any escaping. A bare ``:`` whose token is a single
      # letter AND whose next char is a path separator is part of a
      # drive prefix, NOT the make-rule target/deps separator.
      # Without this, the parser would chop ``D:`` off both sides:
      # ``D`` becomes the first target and ``\foo\target.d: D:\src\…``
      # appears as the deps section.
      let isDriveColon =
        token.len == 1 and token[0] in {'A'..'Z', 'a'..'z'} and
          i + 1 < normalized.len and normalized[i + 1] in {'\\', '/'}
      if isDriveColon:
        token.add(ch)
        sawRuleText = true
      elif inDeps:
        token.add(ch)
      else:
        flushToken(targets, token)
        inDeps = true
      sawRuleText = true
    of ' ', '\t', '\v', '\f':
      if inDeps:
        flushToken(deps, token)
      else:
        flushToken(targets, token)
    of '\r':
      if i + 1 < normalized.len and normalized[i + 1] == '\n':
        inc i
      finishLine()
      inc lineNo
    of '\n':
      finishLine()
      inc lineNo
    else:
      token.add(ch)
      sawRuleText = true
    inc i
  finishLine()
  if parsed.outputs.len == 0:
    raiseReport(dreMalformed, path & ": depfile contains no rules")
  parsed

proc readRecognizedDependencyReport*(formatName, path: string): DependencyPathSet =
  if path.len == 0 or not fileExists(extendedPath(path)):
    raiseReport(dreMissingFile, "dependency report is missing: " & path)
  case formatName
  of MakeDepfileFormatName, NinjaDepfileFormatName:
    parseMakeLikeText(path, readFile(extendedPath(path)))
  of MsvcShowIncludesFormatName, ClangScanDepsJsonFormatName:
    raiseReport(dreUnsupportedFormat,
      "recognized dependency format is not implemented yet: " & formatName)
  else:
    raiseReport(dreUnsupportedFormat,
      "unknown dependency report format: " & formatName)

proc readReproPathSet*(path: string): DependencyPathSet =
  if path.len == 0 or not fileExists(extendedPath(path)):
    raiseReport(dreMissingFile, "path-set report is missing: " & path)
  let lines = readFile(extendedPath(path)).splitLines()
  if lines.len == 0 or lines[0] != "repro-pathset-v1":
    raiseReport(dreMalformed, path & ": missing repro-pathset-v1 header")
  for lineNo in 1 ..< lines.len:
    let line = lines[lineNo]
    if line.len == 0:
      continue
    let tab = line.find('\t')
    if tab <= 0:
      raiseReport(dreMalformed, path & ":" & $(lineNo + 1) &
        ": path-set record must be '<kind>\\t<path>'")
    let kind = line[0 ..< tab]
    let value = line[tab + 1 .. ^1]
    if value.len == 0:
      raiseReport(dreMalformed, path & ":" & $(lineNo + 1) &
        ": path-set record has empty path")
    case kind
    of "input":
      result.inputs.addUnique(value)
    of "output":
      result.outputs.addUnique(value)
    of "probe":
      result.probes.addUnique(value)
    of "diagnostic":
      result.diagnostics.add(value)
    else:
      raiseReport(dreMalformed, path & ":" & $(lineNo + 1) &
        ": unknown path-set record kind: " & kind)
