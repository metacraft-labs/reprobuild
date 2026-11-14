## Reading the ReproOS Add-On Mode spec's §13 decision numbers out of
## source text, for the unit tests that hold the code to citing only
## decisions the spec records under that number (reprobuild-pm
## ``spec/ReproOS-Add-On-Mode.md`` §13, the notes "*Numbers 82 to 85 are
## not used*" and "*Numbers 111 to 113*": an old citation must never land
## on an unrelated decision).
##
## Used by ``t_addon_floor_round12`` (every decision a tracked floor file
## cites is one §13 records, read from the spec itself) and ``t_addon_review_round8`` (A11's round-9 decisions are cited as
## 111 to 113, never by the Arch track's numbers).
##
## Not a test file (no ``t_`` prefix).

import std/[os, osproc, streams, strutils]

proc citedDecisions*(text: string): seq[int] =
  ## Every number cited as a "decision" in ``text``: ``decision N``,
  ## ``decisions N, M and K``, across comment-marker line breaks
  ## (``(§13 decision\n  ## 82)``), as the add-on code, its tests and the
  ## scripts beside them cite §13 (a shell comment's ``#`` is a comment
  ## marker too).
  var flat = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    if text[i] == '\n':
      # A line break and the next line's indentation and comment markers
      # read as one space, so a citation wrapped over two lines is found.
      inc i
      while i < text.len and text[i] in {' ', '\t', '#'}: inc i
      flat.add(' ')
    else:
      flat.add(text[i])
      inc i
  let low = flat.toLowerAscii()
  var at = low.find("decision")
  while at >= 0:
    var j = at + "decision".len
    if j < low.len and low[j] == 's': inc j
    while true:
      while j < low.len and low[j] in {' ', ',', '\t'}: inc j
      if low.continuesWith("and ", j): j += 4
      while j < low.len and low[j] == ' ': inc j
      var k = j
      while k < low.len and low[k] in Digits: inc k
      if k == j: break
      # "owner decision 2026-11-04" is a date, not a decision number.
      if k < low.len and low[k] == '-': break
      result.add(parseInt(low[j ..< k]))
      j = k
    at = low.find("decision", at + 1)

proc recordedDecisions*(spec: string): seq[int] =
  ## The numbers §13 of the add-on spec records: every list item ``N.``
  ## that opens a bold title (``N. **...``) between the heading
  ## ``## 13.`` and the next ``## `` heading.
  var inSection = false
  for line in spec.splitLines():
    if line.startsWith("## "):
      inSection = line.startsWith("## 13.")
      continue
    if not inSection: continue
    let dot = line.find(". **")
    if dot > 0 and line[0 ..< dot].allCharsInSet(Digits):
      result.add(parseInt(line[0 ..< dot]))

proc trackedFiles*(repoRoot: string; roots: openArray[string]): seq[string] =
  ## The files git tracks under ``roots`` (paths relative to ``repoRoot``),
  ## as absolute paths: a reviewer's or an operator's untracked probe beside
  ## them is never read. Empty when git cannot list them.
  var args = @["-C", repoRoot, "ls-files", "-z", "--"]
  for r in roots: args.add(r)
  let p = startProcess("git", args = args, options = {poUsePath, poStdErrToStdOut})
  let o = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  if rc != 0: return
  for f in o.split('\0'):
    if f.len > 0: result.add(repoRoot / f)
