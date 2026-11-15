## Reading the ReproOS Add-On Mode spec's §13 decisions out of source text,
## for the unit tests that hold the code to citing only decisions the spec
## records under that number, and only for what the spec records there
## (reprobuild-pm ``spec/ReproOS-Add-On-Mode.md`` §13, the notes "*Numbers
## 82 to 85*" and "*Numbers 111 to 113*": an old citation must never land
## on an unrelated decision).
##
## A number alone cannot show that. Every number from 1 to the last
## decision is recorded, so a citation of the wrong decision passes any
## check of the number (reprobuild-pm issue ``2026-11-15-floor-the-
## citation-test-passes-a-citation-of-the-wrong-section-13-decision``:
## the ledger copy removed last was cited as 146, the specifier rule, and
## the configuration-gone VM case as 145, the run-start bound). So the
## committed list beside the tests (``addon_spec_section13.txt``) carries
## each decision's title as §13 states it, and for a decision the code
## cites, key words taken from that decision's entry: its title, or its text
## where the title is too short to name what the code does (decision
## 141's title names only the upper bound it adds). A citation must have one of its decision's key
## words near it (``citationRefusals``). Where the spec is found, the
## titles and key words are checked against it (``listRefusals``); in CI,
## which has no checkout of the private spec, the committed list stands in
## for it, and a key word near the citation is still required.
##
## Used by ``t_addon_floor_round12`` (every decision a tracked floor file
## cites is one §13 records, and near what it records; the list is the
## spec's own, read from the spec itself where a checkout has one) and
## ``t_addon_review_round8`` (A11's round-9 decisions are cited as 111 to
## 113, never by the Arch track's numbers).
##
## Not a test file (no ``t_`` prefix).

import std/[algorithm, os, osproc, streams, strutils]

type
  SectionDecision* = object
    ## One §13 entry, as the committed list records it.
    number*: int
    title*: string        ## the bold title, whitespace collapsed, no final "."
    keys*: seq[string]    ## lower-case key words of the entry; empty when uncited
    entry*: string        ## the spec's whole entry, lower case, whitespace
                          ## collapsed (``recordedTitles``; empty in a list)

  Citation* = object
    ## One decision number cited in a source text.
    number*: int
    at*: int              ## offset in ``flattenComments(text)``

const CitationReach* = 250
  ## How far, in characters of the flattened text, a key word may stand
  ## from the citation it vouches for on either side: a comment paragraph,
  ## or a suite name and the comment under it. A key word further away
  ## belongs to other code.

proc flattenComments*(text: string): string =
  ## ``text`` with every line break, and the next line's indentation and
  ## comment markers, read as one space, so a citation or a title wrapped
  ## over two comment lines reads as one line (a shell comment's ``#`` is a
  ## comment marker too).
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    if text[i] == '\n':
      inc i
      while i < text.len and text[i] in {' ', '\t', '#'}: inc i
      result.add(' ')
    else:
      result.add(text[i])
      inc i

proc digitsAt(low: string; j: int): int =
  ## The end of the run of digits that starts at ``j`` (``j`` when none).
  result = j
  while result < low.len and low[result] in Digits: inc result

proc citations*(text: string): seq[Citation] =
  ## Every number cited as a "decision" in ``text``, in text order: ``decision
  ## N``, ``decisions N, M and K``, across comment-marker line breaks
  ## (``(§13 decision\n  ## 82)``), and the amendment spelled after a
  ## citation without the word, ``decision 141, as 145 amends it`` (the upper bound from the run's
  ## start), as the
  ## add-on code, its tests and the scripts beside them cite §13.
  let flat = flattenComments(text)
  let low = flat.toLowerAscii()
  var at = low.find("decision")
  while at >= 0:
    var j = at + "decision".len
    if j < low.len and low[j] == 's': inc j
    while true:
      while j < low.len and low[j] in {' ', ',', '\t'}: inc j
      if low.continuesWith("and ", j): j += 4
      while j < low.len and low[j] == ' ': inc j
      let k = digitsAt(low, j)
      if k == j: break
      # "owner decision 2026-11-04" is a date, not a decision number.
      if k < low.len and low[k] == '-': break
      result.add(Citation(number: parseInt(low[j ..< k]), at: at))
      j = k
    at = low.find("decision", at + 1)
  # "as N amends": the word "decision" is left out, and the number is a
  # citation all the same (round 13's test named 141's amendment so).
  at = low.find("as ")
  while at >= 0:
    if at == 0 or low[at - 1] notin IdentChars:
      let j = at + 3
      let k = digitsAt(low, j)
      if k > j and low.continuesWith(" amend", k):
        result.add(Citation(number: parseInt(low[j ..< k]), at: at))
    at = low.find("as ", at + 1)
  result.sort(proc (a, b: Citation): int = cmp(a.at, b.at), SortOrder.Ascending)

proc citedDecisions*(text: string): seq[int] =
  ## The numbers of ``citations(text)``.
  for c in citations(text): result.add(c.number)

proc normalTitle(t: string): string =
  ## A title with its whitespace collapsed and no final full stop, as the
  ## committed list writes it.
  result = t.splitWhitespace().join(" ")
  result.removeSuffix('.')

proc recordedTitles*(spec: string): seq[SectionDecision] =
  ## The entries §13 of the add-on spec records: every list item ``N.``
  ## that opens a bold title (``N. **...**``, the title possibly wrapped
  ## over several lines) between the heading ``## 13.`` and the next
  ## ``## `` heading, with that title, and its entry: the item's text up
  ## to the next item or the end of the section. ``keys`` is empty.
  let lines = spec.splitLines()
  var inSection = false
  var i = 0
  var entry: seq[string]
  proc finish(result: var seq[SectionDecision]; entry: var seq[string]) =
    if result.len > 0 and entry.len > 0:
      result[^1].entry = entry.join(" ").splitWhitespace().join(" ").toLowerAscii()
    entry.setLen(0)
  while i < lines.len:
    let line = lines[i]
    inc i
    if line.startsWith("## "):
      finish(result, entry)
      inSection = line.startsWith("## 13.")
      continue
    if not inSection: continue
    let dot = line.find(". **")
    if dot <= 0 or not line[0 ..< dot].allCharsInSet(Digits):
      if result.len > 0: entry.add(line)
      continue
    finish(result, entry)
    entry.add(line)
    var title = line[dot + 4 .. ^1]
    var k = i
    while "**" notin title and k < lines.len:
      title.add(" " & lines[k].strip())
      inc k
    let close = title.find("**")
    if close >= 0: title.setLen(close)
    result.add(SectionDecision(number: parseInt(line[0 ..< dot]),
                               title: normalTitle(title)))
  finish(result, entry)

proc recordedDecisions*(spec: string): seq[int] =
  ## The numbers ``recordedTitles(spec)`` reads.
  for d in recordedTitles(spec): result.add(d.number)

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

proc readDecisionList*(text: string): seq[SectionDecision] =
  ## The entries of a committed decision list, one per line:
  ## ``N Title`` or ``N Title | key, key phrase``. ``#`` at the start of a
  ## line starts a comment; blank lines are skipped. Raises ``ValueError``
  ## on a line that does not start with a number and a title.
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let sp = line.find(' ')
    if sp <= 0:
      raise newException(ValueError, "a decision line without a title: " & line)
    var d = SectionDecision(number: parseInt(line[0 ..< sp]))
    var rest = line[sp + 1 .. ^1]
    let bar = rest.find(" | ")
    if bar >= 0:
      for k in rest[bar + 3 .. ^1].split(','):
        let key = k.strip().toLowerAscii()
        if key.len > 0: d.keys.add(key)
      rest.setLen(bar)
    d.title = normalTitle(rest)
    if d.title.len == 0:
      raise newException(ValueError, "a decision line without a title: " & line)
    result.add(d)

proc listedNumbers*(list: openArray[SectionDecision]): seq[int] =
  for d in list: result.add(d.number)

proc entryIndex*(list: openArray[SectionDecision]; number: int): int =
  ## The index of ``number``'s entry in ``list``; -1 when it has none.
  for i, d in list:
    if d.number == number: return i
  -1

proc atWordStart(hay, needle: string; at: int): bool =
  ## Whether ``needle`` stands at ``at`` in ``hay`` and starts a word there:
  ## a key word is a word or the first letters of one ("remov" reads
  ## "removed" and "removal"), never the middle of another word.
  hay.continuesWith(needle, at) and (at == 0 or hay[at - 1] notin Letters + Digits)

proc containsWordStart*(hay, needle: string): bool =
  ## Whether ``needle`` starts a word somewhere in ``hay`` (both lower case).
  var at = hay.find(needle)
  while at >= 0:
    if atWordStart(hay, needle, at): return true
    at = hay.find(needle, at + 1)
  false

proc listRefusals*(list, recorded: openArray[SectionDecision]): seq[string] =
  ## Why the committed ``list`` is not the spec's ``recorded`` §13
  ## (``recordedTitles``), one line each: a number the spec does not record,
  ## a title that is not the spec's, or a key word that starts no word of
  ## that decision's entry (case aside), so that a key word vouches only for
  ## what the spec records under the number.
  for d in list:
    let i = recorded.entryIndex(d.number)
    if i < 0:
      result.add("the list names decision " & $d.number &
                 ", which the spec does not record")
      continue
    let r = recorded[i]
    if r.title != d.title:
      result.add("the list titles decision " & $d.number & " \"" & d.title &
                 "\", which the spec titles \"" & r.title & "\"")
    for k in d.keys:
      if not containsWordStart(r.entry, k):
        result.add("decision " & $d.number & "'s key word \"" & k &
                   "\" is not in its entry in the spec")

proc citationRefusals*(text: string; list: openArray[SectionDecision];
                       reach = CitationReach): seq[string] =
  ## Why each citation in ``text`` fails, one line each: its number is not
  ## in ``list``; the list gives it no key words; or none of its key words
  ## stands within ``reach`` characters of it, so the text near it is about
  ## something else than what §13 records under that number.
  let flat = flattenComments(text)
  let low = flat.toLowerAscii()
  for c in citations(text):
    let i = list.entryIndex(c.number)
    let near = flat[max(0, c.at - 60) ..< min(flat.len, c.at + 40)]
    if i < 0:
      result.add("decision " & $c.number & ", which the list does not record, at \"" &
                 near & "\"")
      continue
    let d = list[i]
    if d.keys.len == 0:
      result.add("decision " & $c.number & " (\"" & d.title &
                 "\"), which the list gives no key words, at \"" & near & "\"")
      continue
    let window = low[max(0, c.at - reach) ..< min(low.len, c.at + reach)]
    var found = false
    for k in d.keys:
      if containsWordStart(window, k):
        found = true
        break
    if not found:
      result.add("decision " & $c.number & " (\"" & d.title & "\") with none of " &
                 d.keys.join(", ") & " near it, at \"" & near & "\"")

proc findAddonSpec*(repoRoot: string; env = getEnv("REPRO_ADDON_SPEC")): string =
  ## The add-on spec: ``env`` when set, else the first
  ## ``<dir>/reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` (or the checkout's
  ## former name, ``reprobuild-specs``) in ``repoRoot``'s parent or an
  ## ancestor of it, as the other spec-reading tests find theirs; "" when
  ## there is none.
  if env.len > 0: return env
  var d = repoRoot.parentDir
  while d.len > 1:
    for name in ["reprobuild-pm", "reprobuild-specs"]:
      let p = d / name / "spec" / "ReproOS-Add-On-Mode.md"
      if fileExists(p): return p
    let up = d.parentDir
    if up == d: break
    d = up
  ""
