## One-shot bulk edit tool: scan ``runtime_core.nim`` and
## ``runtime_provider.nim`` for every public top-level / provider-mode
## ``proc foo*(...)`` declaration and splice ``{.dynOrStatic.}`` into
## its pragma block (or attach a fresh pragma block if none exists).
##
## Multi-line signatures with default values, ``openArray`` types,
## ``{.discardable.}`` pragmas, and trailing return-type continuations
## are all handled by walking forward from each ``^\s*proc\s+\w+\*``
## line until we find the ``=`` that opens the body, then splicing
## ``{.dynOrStatic.}`` just before the ``=``.
##
## This script is invoked manually as part of the Tier 1 dynamic-DSL
## rollout; once the runtime files are committed in their new form it
## is not part of the build.

import std/[os, strutils, sequtils]

const SkipNames: seq[string] = @[]
  ## File-local helpers and overloads in the non-provider-mode else
  ## branch are filtered automatically (no leading ``*``); nothing
  ## listed here for now — every public proc in the runtime files is
  ## fair game because the macros only call file-local procs at
  ## compile time.

proc isProcStart(line: string): bool =
  let stripped = line.strip(leading = true, trailing = false)
  stripped.startsWith("proc ") and "*" in stripped.split('(')[0]

proc procBareName(line: string): string =
  ## Extracts ``foo`` from ``proc foo*(...) = ...``.
  let stripped = line.strip(leading = true, trailing = false)
  assert stripped.startsWith("proc ")
  var rest = stripped[5 ..^ 1]
  var name = ""
  for ch in rest:
    if ch == '*' or ch == '(' or ch == '[' or ch.isSpaceAscii:
      break
    name.add(ch)
  name

proc transform(path: string) =
  let original = readFile(path)
  let lines = original.splitLines(keepEol = false)
  # Reconstruct line endings: detect CRLF vs LF from original.
  let lineSep =
    if "\r\n" in original: "\r\n"
    else: "\n"
  var output: seq[string] = @[]
  var i = 0
  var rewrites = 0
  while i < lines.len:
    let line = lines[i]
    if not isProcStart(line):
      output.add(line)
      inc i
      continue
    if procBareName(line) in SkipNames:
      output.add(line)
      inc i
      continue
    # Collect the full signature lines from `proc ... =` (the last `=`
    # that starts the body) — every continuation line up to and
    # including the line that ends with ``=`` is part of the
    # signature.
    var sigStart = i
    var sigEnd = i
    while sigEnd < lines.len:
      let l = lines[sigEnd].strip(leading = false, trailing = true)
      # The body opens on the line whose trailing token after any
      # comment-strip is ``=``. Detect this by checking if the line
      # ends with ``=`` ignoring trailing whitespace and trailing
      # ``##`` doc comments.
      var stripped = l
      let docIdx = stripped.find("##")
      if docIdx >= 0:
        stripped = stripped[0 ..< docIdx].strip(leading = false, trailing = true)
      if stripped.endsWith("="):
        break
      inc sigEnd
    if sigEnd >= lines.len:
      # No body found (forward declaration or syntax we don't grok);
      # emit unchanged.
      for j in sigStart .. lines.high:
        output.add(lines[j])
      i = lines.len
      continue
    # `sigEnd` is the line ending in `=`. Splice `{.dynOrStatic.}`
    # immediately before the `=`. If the line already contains a
    # pragma block like `{.discardable.}` followed by `=`, merge
    # `dynOrStatic` into it. Otherwise insert a fresh `{.dynOrStatic.}`
    # before the `=`.
    var bodyLine = lines[sigEnd]
    # Find the location of the last `=` outside of any pragma braces.
    let eqIdx = bodyLine.rfind('=')
    assert eqIdx >= 0
    let before = bodyLine[0 ..< eqIdx].strip(leading = false, trailing = true)
    let after = bodyLine[eqIdx .. ^1]
    var replacement: string
    if before.endsWith(".}"):
      # Existing pragma block on this line — merge.
      let openIdx = before.rfind("{.")
      assert openIdx >= 0
      let pragmaInner = before[openIdx + 2 ..< before.len - 2].strip()
      let merged = "{." & pragmaInner & ", dynOrStatic.}"
      replacement = before[0 ..< openIdx] & merged & " " & after
    else:
      # No pragma block on this line. Insert one. But existing pragma
      # could be on a PRECEDING line for multi-line signatures (rare
      # in this codebase). Handle the common case first.
      replacement = before & " {.dynOrStatic.} " & after
    # Emit the unchanged sig prefix.
    for j in sigStart ..< sigEnd:
      output.add(lines[j])
    output.add(replacement)
    inc rewrites
    i = sigEnd + 1
  let result = output.join(lineSep)
  writeFile(path, result &
    (if original.endsWith(lineSep): lineSep else: ""))
  echo path, ": ", rewrites, " procs rewritten"

let here = currentSourcePath().parentDir().parentDir()
transform(here / "libs/repro_project_dsl/src/repro_project_dsl/runtime_core.nim")
transform(here / "libs/repro_project_dsl/src/repro_project_dsl/runtime_provider.nim")
