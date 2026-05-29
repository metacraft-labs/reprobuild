## String helpers for user profile authors.
##
## - `unindent` strips the common leading whitespace from every
##   non-empty line. The argument is intended to be a triple-quoted
##   multi-line string used as content for a `fs.userFile` or similar
##   resource.
## - `interpolate` substitutes `${var}` markers in a template against a
##   variable table.
##
## Both are runtime procs (compileTime callable too); users invoke
## them inside their profile bodies to build content fragments.

import std/[strutils, tables]

proc countLeadingSpaces(line: string): int =
  ## Count the number of leading space characters (ASCII 0x20). Tabs
  ## are NOT counted as multi-column for this purpose; if a line uses
  ## tabs the minimum is computed per-character. We treat any non-
  ## space whitespace as the boundary -- consistent with how Nim's
  ## triple-quoted strings tend to be used (space-only indent).
  result = 0
  while result < line.len and line[result] == ' ':
    inc result

proc isBlank(line: string): bool =
  for c in line:
    if c notin {' ', '\t', '\r'}:
      return false
  true

proc unindent*(s: string): string =
  ## Strip the common leading whitespace from every non-empty line.
  ##
  ## Rules:
  ## - Single-line input is returned with a leading newline trimmed
  ##   plus its own leading whitespace stripped (so a single-line
  ##   triple-quoted string still gets sensibly un-indented).
  ## - Multi-line input: compute the minimum leading-space count
  ##   across non-blank lines and strip exactly that many spaces from
  ##   every line.
  ## - Leading and trailing fully-blank lines are dropped.
  let lines = s.splitLines()

  # Drop leading + trailing blank lines while collecting indices.
  var firstIdx = 0
  while firstIdx < lines.len and isBlank(lines[firstIdx]):
    inc firstIdx
  var lastIdx = lines.len - 1
  while lastIdx >= firstIdx and isBlank(lines[lastIdx]):
    dec lastIdx

  if firstIdx > lastIdx:
    return ""

  # Compute the minimum leading-space across non-blank lines.
  var minIndent = int.high
  for i in firstIdx .. lastIdx:
    if isBlank(lines[i]):
      continue
    let indent = countLeadingSpaces(lines[i])
    if indent < minIndent:
      minIndent = indent
  if minIndent == int.high:
    minIndent = 0

  var stripped: seq[string] = @[]
  for i in firstIdx .. lastIdx:
    let line = lines[i]
    if line.len <= minIndent:
      stripped.add ""
    else:
      stripped.add line[minIndent .. ^1]

  result = stripped.join("\n")

proc interpolate*(tmpl: string; vars: Table[string, string]): string =
  ## Replace `${var}` markers in `tmpl` with table lookups.
  ##
  ## Raises `KeyError` if a marker references a variable that is not
  ## in `vars`. Literal `$$` is the escape for a single `$`.
  result = newStringOfCap(tmpl.len)
  var i = 0
  while i < tmpl.len:
    let c = tmpl[i]
    if c == '$' and i + 1 < tmpl.len and tmpl[i + 1] == '$':
      result.add '$'
      inc i, 2
      continue
    if c == '$' and i + 1 < tmpl.len and tmpl[i + 1] == '{':
      let closeIdx = tmpl.find('}', i + 2)
      if closeIdx < 0:
        raise newException(ValueError,
          "interpolate: unterminated ${...} marker at position " & $i)
      let varName = tmpl[i + 2 ..< closeIdx]
      if varName notin vars:
        raise newException(KeyError,
          "interpolate: variable '" & varName &
          "' referenced by template is not declared")
      result.add vars[varName]
      i = closeIdx + 1
      continue
    result.add c
    inc i
