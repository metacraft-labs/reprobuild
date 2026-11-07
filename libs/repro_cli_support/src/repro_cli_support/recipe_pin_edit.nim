## Recipe pin edits: the two text rewrites `repro lock update` makes to a
## recipe, and the name resolution it does before either.
##
## `repro lock update <dependency> [--to <rev>]` is the one operation that may
## move a constraint the author wrote in a recipe (Unified-Locking-And-Hooks.md
## §16.4; the commit-time re-pin never does). It rewrites an EXACT pin only:
##
## * in `flake.nix`, the revision in the input's URL literal, written either
##   as a `rev=<sha>` query parameter or as the last path component of a forge
##   reference (`github:o/r/<sha>`);
## * in `repro.nim`, the version of an exact `uses:` entry (`"lib ==1.4.0"`),
##   replaced by the version whose producer `versions:` entry maps to the
##   target revision.
##
## Both rewrites change the bytes of ONE string literal on ONE line and keep
## every other byte of the file, so the diff a reviewer sees is the pin and
## nothing else. Both refuse rather than guess: a literal that cannot be found
## exactly once, or a revision that is not spelled where the reader says it
## is, comes back with ``ok = false`` and a diagnostic, and the caller writes
## nothing.
##
## The module is PURE: it takes texts and returns texts, and touches no file
## and no process. The caller (`repro lock update` in `repro_cli_support`)
## reads the files, decides which edits are needed and writes the results
## atomically.
##
## Flake references are described in the Nix manual:
## https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-flake#flake-references

import std/[strutils]

import repro_cli_support/recipe_constraints

type
  PinEdit* = object
    ## The result of one recipe rewrite.
    ok*: bool
    text*: string          ## the rewritten document (the input when not ok)
    line*: int             ## the 1-based line that changed
    before*: string        ## the literal's value before the edit
    after*: string         ## the literal's value after it
    diagnostic*: string    ## why ``ok`` is false

proc lineSpan(source: string; line: int): tuple[found: bool; start, stop: int] =
  ## Byte offsets of the 1-based ``line`` of ``source``, without its newline.
  if line <= 0: return
  var current = 1
  var start = 0
  var i = 0
  while current < line:
    if i >= source.len: return
    if source[i] == '\n':
      inc current
      start = i + 1
    inc i
  var stop = start
  while stop < source.len and source[stop] != '\n': inc stop
  (true, start, stop)

proc countOccurrences(haystack, needle: string): int =
  if needle.len == 0: return 0
  var at = haystack.find(needle)
  while at >= 0:
    inc result
    at = haystack.find(needle, at + needle.len)

proc replaceOnLine(source: string; line: int; oldText, newText: string):
    PinEdit =
  ## Replace the single occurrence of ``oldText`` on ``line`` with
  ## ``newText``. Refuses when the line does not exist or holds ``oldText``
  ## zero times or more than once: an edit that could land in two places is
  ## not an edit this module makes.
  result.text = source
  result.line = line
  let span = lineSpan(source, line)
  if not span.found:
    result.diagnostic = "line " & $line & " does not exist"
    return
  let lineText = source[span.start ..< span.stop]
  let n = countOccurrences(lineText, oldText)
  if n != 1:
    result.diagnostic = "line " & $line & " holds " & oldText & " " & $n &
      " time(s), not exactly once"
    return
  let at = span.start + lineText.find(oldText)
  result.text = source[0 ..< at] & newText & source[at + oldText.len .. ^1]
  result.ok = true

proc rewriteFlakeRevInUrl*(url, oldRev, newRev: string):
    tuple[ok: bool; url: string; diagnostic: string] =
  ## ``url`` with the revision it names moved from ``oldRev`` to ``newRev``,
  ## in whichever spelling it uses:
  ##
  ## * a `rev=<sha>` query parameter (`git+https://h/o/r?ref=main&rev=<sha>`,
  ##   `github:o/r?rev=<sha>`);
  ## * the last path component of a forge reference (`github:o/r/<sha>`),
  ##   which Nix reads as a revision when it is a full commit id.
  ##
  ## Everything else in the URL — the scheme, the host, `ref=`, the other
  ## query parameters, a `#fragment` — is carried through byte for byte. The
  ## old revision is matched case-insensitively (a commit id is hex) and must
  ## occur exactly once in the spelling it is expected in.
  if not isExactRevision(oldRev) or not isExactRevision(newRev):
    return (false, url, "both revisions must be full commit ids (" & oldRev &
      ", " & newRev & ")")
  let lower = url.toLowerAscii()
  let old = oldRev.toLowerAscii()
  let q = url.find('?')
  let hash = url.find('#')
  let baseEnd =
    if q >= 0: q
    elif hash >= 0: hash
    else: url.len
  # The query form: `rev=<sha>` as a whole parameter.
  let queryNeedle = "rev=" & old
  var queryHits: seq[int]
  if q >= 0:
    var at = lower.find(queryNeedle, q)
    while at >= 0:
      let before = lower[at - 1]
      let after = at + queryNeedle.len
      if before in {'?', '&'} and
          (after >= lower.len or lower[after] in {'&', '#'}):
        queryHits.add(at)
      at = lower.find(queryNeedle, at + 1)
  # The path form: `/<sha>` as the last path component of the base.
  var pathHit = -1
  let base = lower[0 ..< baseEnd]
  if base.endsWith("/" & old):
    pathHit = baseEnd - old.len
  if queryHits.len + (if pathHit >= 0: 1 else: 0) != 1:
    return (false, url, "the url " & url & " does not name revision " &
      oldRev & " exactly once (as rev=" & oldRev & " or as a /" & oldRev &
      " path component)")
  let at = if queryHits.len == 1: queryHits[0] + "rev=".len else: pathHit
  (true, url[0 ..< at] & newRev.toLowerAscii() & url[at + old.len .. ^1], "")

proc rewriteFlakeInputRev*(source, input, oldRev, newRev: string): PinEdit =
  ## The `flake.nix` text ``source`` with input ``input``'s URL literal moved
  ## from revision ``oldRev`` to ``newRev`` (``rewriteFlakeRevInUrl``). Only
  ## that literal changes. Refuses an input that is not declared, whose URL is
  ## not a plain one-line string literal (an interpolation, a `''` string), or
  ## whose URL does not name ``oldRev``.
  result.text = source
  var decl: FlakeInputDeclaration
  var found = false
  for d in scanFlakeInputDeclarations(source):
    if d.name == input:
      decl = d
      found = true
      break
  if not found:
    result.diagnostic = "flake.nix declares no input '" & input & "'"
    return
  if not decl.urlIsLiteral or decl.url.len == 0 or decl.urlLine <= 0:
    result.diagnostic = "input '" & input & "' has no plain string-literal " &
      "url in flake.nix, so its revision cannot be edited as text"
    return
  if '\\' in decl.url or '\n' in decl.url:
    result.diagnostic = "the url of input '" & input & "' (flake.nix:" &
      $decl.urlLine & ") is not a one-line literal without escapes"
    return
  let moved = rewriteFlakeRevInUrl(decl.url, oldRev, newRev)
  if not moved.ok:
    result.line = decl.urlLine
    result.diagnostic = "input '" & input & "' (flake.nix:" & $decl.urlLine &
      "): " & moved.diagnostic
    return
  result = replaceOnLine(source, decl.urlLine, "\"" & decl.url & "\"",
    "\"" & moved.url & "\"")
  result.before = decl.url
  result.after = moved.url
  if not result.ok:
    result.diagnostic = "input '" & input & "' (flake.nix:" & $decl.urlLine &
      "): " & result.diagnostic

proc exactConstraintWithVersion*(rawConstraint, exactVersion,
    newVersion: string): tuple[ok: bool; constraint: string] =
  ## The `uses:` constraint ``rawConstraint`` (an exact one, naming
  ## ``exactVersion``) with that version replaced by ``newVersion``. The
  ## selector, the operator (`==`, `=`, none) and a `v` prefix are kept as the
  ## author wrote them; only the version digits change.
  let at = rawConstraint.rfind(exactVersion)
  if exactVersion.len == 0 or at < 0: return (false, rawConstraint)
  # The version must be the tail of the constraint: an exact constraint is
  # one token after the selector, and the version ends it.
  if rawConstraint[at + exactVersion.len .. ^1].strip().len != 0:
    return (false, rawConstraint)
  (true, rawConstraint[0 ..< at] & newVersion &
    rawConstraint[at + exactVersion.len .. ^1])

proc rewriteUsesExactVersion*(source: string; line: int; rawConstraint,
    exactVersion, newVersion: string): PinEdit =
  ## The `repro.nim` text ``source`` with the `uses:` string literal
  ## ``rawConstraint`` on ``line`` rewritten to name ``newVersion``. Only that
  ## literal changes.
  result.text = source
  result.line = line
  let replaced = exactConstraintWithVersion(rawConstraint, exactVersion,
    newVersion)
  if not replaced.ok:
    result.diagnostic = "'" & rawConstraint & "' does not end in version " &
      exactVersion
    return
  result = replaceOnLine(source, line, "\"" & rawConstraint & "\"",
    "\"" & replaced.constraint & "\"")
  result.before = rawConstraint
  result.after = replaced.constraint

# ---------------------------------------------------------------------------
# Naming a dependency
# ---------------------------------------------------------------------------

type
  DependencyCandidateKind* = enum
    dckFlakeInput = "input"     ## a root input of `flake.nix` / `flake.lock`
    dckReproLockDep = "dep"     ## a `deps` entry of `repro.lock`
    dckWorkspaceRepo = "repo"   ## a repo of the workspace membership

  DependencyCandidate* = object
    ## One thing a name given to `repro lock update` could mean.
    kind*: DependencyCandidateKind
    name*: string
    identity*: string      ## canonical repository URL, "" when none
    where*: string         ## where it is declared, for messages

  DependencyNameResolution* = object
    ok*: bool
    identity*: string      ## the one canonical repository the name means
    matches*: seq[DependencyCandidate]
      ## every candidate the name matched (for the messages)
    diagnostic*: string

proc describeCandidate*(c: DependencyCandidate): string =
  ## ``<kind>:<name>`` (the qualified spelling `repro lock update` accepts)
  ## plus where it is declared and the repository it resolves.
  $c.kind & ":" & c.name & " (" & c.where & ", " &
    (if c.identity.len > 0: "repository " & c.identity
     else: "no repository URL") & ")"

proc resolveDependencyName*(name: string;
    candidates: openArray[DependencyCandidate]): DependencyNameResolution =
  ## The ONE canonical repository ``name`` means among ``candidates``.
  ##
  ## A name may be a flake input, a `repro.lock` dependency or a workspace
  ## repo, so it is matched against all three. It may also be qualified as
  ## `input:<name>`, `dep:<name>` or `repo:<name>`, which matches that kind
  ## only. The answer is a repository, never a name (§16.3): two names for one
  ## repository resolve together, and when the matches name more than one
  ## repository (or one repository and a match with no repository URL) the
  ## name is AMBIGUOUS and is refused with every candidate in its qualified
  ## spelling. Nothing is guessed: a match that names no repository at all is
  ## refused too.
  var kindFilter = ""
  var bare = name
  let colon = name.find(':')
  if colon > 0 and name[0 ..< colon] in ["input", "dep", "repo"]:
    kindFilter = name[0 ..< colon]
    bare = name[colon + 1 .. ^1]
  for c in candidates:
    if c.name != bare: continue
    if kindFilter.len > 0 and $c.kind != kindFilter: continue
    result.matches.add(c)
  if result.matches.len == 0:
    var known: seq[string]
    for c in candidates:
      let spelled = $c.kind & ":" & c.name
      if spelled notin known: known.add(spelled)
    result.diagnostic = "'" & name & "' names no flake input, repro.lock " &
      "dependency or workspace repo of this repository" &
      (if known.len > 0: "; known: " & known.join(", ") else: "")
    return
  var identities: seq[string]
  var unidentified: seq[DependencyCandidate]
  for c in result.matches:
    if c.identity.len == 0:
      unidentified.add(c)
    elif c.identity notin identities:
      identities.add(c.identity)
  if identities.len > 1 or (identities.len == 1 and unidentified.len > 0):
    # Two repositories, or one repository and something this command cannot
    # identify: either way the name does not say which one is meant.
    var listed, spellings: seq[string]
    for c in result.matches:
      listed.add(describeCandidate(c))
      spellings.add($c.kind & ":" & c.name)
    result.diagnostic = "'" & name & "' is AMBIGUOUS: it names " &
      $result.matches.len & " things that are not one repository — " &
      listed.join("; ") & ". Name one of them by its qualified spelling (" &
      spellings.join(", ") & ")"
    return
  if identities.len == 0:
    var listed: seq[string]
    for c in unidentified: listed.add(describeCandidate(c))
    result.diagnostic = "'" & name & "' names " & listed.join("; ") &
      ", which resolves to no repository URL this command can identify, so " &
      "no other resolution of it can be found"
    return
  result.identity = identities[0]
  result.ok = true
