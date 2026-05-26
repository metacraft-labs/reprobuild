## Heuristic helpers for the standard provider's diagnostic surface.
##
## At M1 the engine does not yet hand the standard provider a parsed
## ``PackageDef`` (that's M2's work — wiring ``ProjectInterfaceArtifact``
## through). When the dispatch loop fails to find a matching convention
## we still want the error message to name the package's declared
## ``uses:`` list, because that's the single most useful clue for
## diagnosing "why didn't my project match?".
##
## ``readUsesHint`` is a *heuristic* line scan over ``reprobuild.nim`` —
## it does NOT evaluate the DSL. The output is purely diagnostic; the
## convention dispatch logic itself never depends on it. Two failure
## modes are accepted by design:
##
## * No ``reprobuild.nim`` → empty seq (the diagnostic falls back to
##   reporting just the project root).
## * Malformed / unusual ``uses:`` block → best-effort; never raises.
##
## The scan recognises three shapes that cover the bulk of real
## ``reprobuild.nim`` files:
##
##   uses: nim                       # single inline identifier
##   uses: [nim, rust]               # inline list
##   uses:                           # block form
##     nim
##     rust
##
## Anything fancier (multi-line ``[...]``, conditionals, ``when``-blocks)
## is out of scope — the M2 interface artifact will replace this scan
## entirely.

import std/[os, strutils]

const
  UsesHintFile* = "reprobuild.nim"
    ## Filename probed by ``readUsesHint``. Kept as a const so the
    ## diagnostic and the test fixture stay in lockstep.

proc stripComment(line: string): string =
  ## Drop ``# ...`` trailing comments. Naive — doesn't understand
  ## string literals containing ``#`` — but ``uses:`` blocks never
  ## contain those.
  let idx = line.find('#')
  if idx < 0: line
  else: line[0 ..< idx]

proc splitEntries(payload: string): seq[string] =
  ## Split a comma- or whitespace-separated list of identifiers, after
  ## stripping any enclosing brackets or quotes. Empty payload yields
  ## an empty seq.
  var trimmed = payload.strip()
  if trimmed.startsWith("["):
    trimmed = trimmed[1 .. ^1]
  if trimmed.endsWith("]"):
    trimmed = trimmed[0 ..< ^1]
  for raw in trimmed.split({',', ' ', '\t'}):
    let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
    if entry.len > 0:
      result.add(entry)

proc readUsesHint*(projectRoot: string): seq[string] =
  ## Return a best-effort list of the languages / external systems the
  ## project's ``reprobuild.nim`` declares in its ``uses:`` block.
  ##
  ## Returns an empty seq on any error — missing file, IO failure,
  ## malformed block. Callers MUST treat the output as a diagnostic
  ## hint, never as authoritative input to dispatch.
  let path = projectRoot / UsesHintFile
  if not fileExists(path):
    return @[]
  var raw: string
  try:
    raw = readFile(path)
  except CatchableError:
    return @[]

  var inBlock = false
  for rawLine in raw.splitLines():
    let line = stripComment(rawLine)
    let stripped = line.strip()
    if stripped.len == 0:
      # Blank line terminates an in-progress block.
      if inBlock:
        inBlock = false
      continue
    if inBlock:
      # Block form: indented entries until the indentation drops back
      # to column 0. We don't actually track columns — any line that
      # starts with a non-space char and *isn't* an entry marker ends
      # the block.
      let leadingSpace = line.len > 0 and line[0] in {' ', '\t'}
      if not leadingSpace:
        inBlock = false
        # Fall through to inline-form handling below in case this same
        # line is itself a ``uses:`` declaration.
      else:
        for entry in splitEntries(stripped):
          result.add(entry)
        continue
    # Inline form: look for ``uses:`` at the start of the stripped line.
    if stripped.startsWith("uses:"):
      let payload = stripped[5 .. ^1].strip()
      if payload.len == 0:
        inBlock = true
      else:
        for entry in splitEntries(payload):
          result.add(entry)
