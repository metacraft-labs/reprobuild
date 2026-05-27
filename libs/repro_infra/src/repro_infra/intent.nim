## Formatting-preserving structural editor for the system-scope
## intent layer (`system.nim`) — M69 Phase B.
##
## The `repro system add` / `repro system remove` commands edit
## `system.nim` THROUGH this editor; they never string-munge the file.
##
## ## Why a parallel editor (and not the M60 `repro_home_intent` one)
##
## The M60 home-scope structural editor is built for `home.nim`'s
## structure: a `profile <name>:` root, indentation-nested `activity`
## blocks, `config:` / `hosts:` / `resources:` sub-blocks, and bare
## package-reference lines. `system.nim` (Phase A's `profile.nim`
## format) is structurally unrelated — a FLAT list of
## `kind { key = value ... }` brace stanzas, no profile root, no
## activities, no indentation-based nesting. The home editor's IR
## (`nkActivity`, `nkCondBlock`, `nkPackageRef`, …) has no node that
## maps onto a system-scope brace stanza. Reuse would mean bending the
## home IR into a shape it was not designed for; a small parallel
## editor on Phase A's own `profile.nim` parser is the honest choice.
##
## ## Round-trip invariant
##
## `addResource(p, …)` followed by `removeResource(p, address)` against
## a file that did not previously contain `address` produces a file
## byte-identical to the original — including comments, blank lines,
## the detected line ending, and the trailing-newline flag.
##
## ## Insertion-position rule
##
## A new stanza is appended at the END of the file, after the last
## non-blank/non-comment line and BEFORE any trailing blank/comment
## lines (so a file-footer comment stays at the foot). Insertion order
## is deterministic and reversible by `removeResource`.

import std/[os, strutils]
from repro_core/paths import extendedPath

import ./errors
import ./profile

type
  SystemIntentDoc* = object
    ## A loaded `system.nim`, kept as its raw lines so an edit
    ## preserves every byte the editor does not touch.
    path*: string
    lines*: seq[string]
    lineEnding*: string                ## "\n" or "\r\n"
    hasTrailingNewline*: bool

  StanzaSpan* = object
    ## The line range one resource stanza occupies in the document
    ## (0-based, inclusive). `leadingComments` is the count of
    ## comment / blank lines immediately above the stanza head that
    ## "belong" to it — they are removed together with the stanza so
    ## a remove is a clean inverse of an add.
    address*: string
    kindTag*: string
    startLine*: int                    ## the `kind {` head line
    endLine*: int                      ## the `}` line
    leadingBlankComments*: int

# ---------------------------------------------------------------------------
# Load / save.
# ---------------------------------------------------------------------------

proc detectLineEnding(raw: string): string =
  if raw.contains("\r\n"): "\r\n" else: "\n"

proc loadSystemIntent*(path: string): SystemIntentDoc =
  ## Load `system.nim` into the editor document. Raises
  ## `ESystemProfileInvalid` (via `parseSystemProfile`'s validation,
  ## called by the editor's lookups) only when an edit needs a parsed
  ## view; the bare load just splits lines.
  if not fileExists(extendedPath(path)):
    raiseSystemProfileInvalid("no system profile at " & path)
  let raw = readFile(extendedPath(path))
  result.path = path
  result.lineEnding = detectLineEnding(raw)
  result.hasTrailingNewline = raw.len > 0 and
    (raw[^1] == '\n')
  # Split on the detected ending; normalize so each `lines` element is
  # ending-free.
  var body = raw
  if result.hasTrailingNewline:
    # Drop exactly one trailing newline (and its \r) so the split does
    # not yield a spurious empty final element.
    body.setLen(body.len - 1)
    if body.len > 0 and body[^1] == '\r':
      body.setLen(body.len - 1)
  for ln in body.split(result.lineEnding):
    result.lines.add(ln)
  if raw.len == 0:
    result.lines = @[]

proc serialize*(doc: SystemIntentDoc): string =
  ## Reassemble the document, preserving the detected line ending and
  ## the trailing-newline flag.
  for i, line in doc.lines:
    if i > 0:
      result.add(doc.lineEnding)
    result.add(line)
  if doc.hasTrailingNewline:
    result.add(doc.lineEnding)

proc writeSystemIntent*(doc: SystemIntentDoc) =
  ## Atomically write the document back: write a sibling `.tmp` and
  ## `moveFile` over the original.
  let payload = serialize(doc)
  let tmp = doc.path & ".tmp"
  writeFile(extendedPath(tmp), payload)
  if fileExists(extendedPath(doc.path)):
    removeFile(extendedPath(doc.path))
  moveFile(extendedPath(tmp), extendedPath(doc.path))

# ---------------------------------------------------------------------------
# Stanza discovery. The editor re-derives stanza spans from the raw
# lines by a brace walk that mirrors `profile.parseSystemProfile`'s
# brace walk — so the editor and the parser agree on stanza bounds.
# ---------------------------------------------------------------------------

proc lineIsBlankOrComment(s: string): bool =
  let t = s.strip()
  t.len == 0 or t.startsWith("#")

proc stanzaSpans*(doc: SystemIntentDoc): seq[StanzaSpan] =
  ## Walk the document and return one `StanzaSpan` per resource stanza,
  ## in file order. The `address` is the parsed resource's address
  ## (the parser's `realWorldIdentity` default, or an explicit
  ## `address = "..."` field). A structurally-invalid file raises
  ## `ESystemProfileInvalid` via `parseSystemProfile`.
  let profile = parseSystemProfile(serialize(doc))
  # Re-walk the lines for brace bounds; pair each `{` head with the
  # parsed resource at the same ordinal.
  var resIdx = 0
  var i = 0
  while i < doc.lines.len:
    let stripped = doc.lines[i].strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      inc i
      continue
    # A stanza head is `<kindTag> {` (the `{` may be on a later line).
    # Find the head: the line that introduces the kind tag.
    let headLine = i
    # Locate the `{` — on this line or a following one.
    var braceLine = i
    var foundBrace = false
    while braceLine < doc.lines.len:
      if doc.lines[braceLine].contains('{'):
        foundBrace = true
        break
      inc braceLine
    if not foundBrace:
      break
    # Locate the matching `}`.
    var closeLine = braceLine
    while closeLine < doc.lines.len:
      if doc.lines[closeLine].contains('}'):
        break
      inc closeLine
    if closeLine >= doc.lines.len:
      break
    # Count the leading blank/comment lines that belong to this stanza
    # (contiguous run directly above the head).
    var lead = 0
    var j = headLine - 1
    while j >= 0 and lineIsBlankOrComment(doc.lines[j]):
      inc lead
      dec j
    if resIdx < profile.resources.len:
      result.add(StanzaSpan(
        address: profile.resources[resIdx].address,
        kindTag: $profile.resources[resIdx].kind,
        startLine: headLine,
        endLine: closeLine,
        leadingBlankComments: lead))
    inc resIdx
    i = closeLine + 1

proc findStanza*(doc: SystemIntentDoc; address: string):
    int =
  ## Index into `stanzaSpans(doc)` of the stanza whose `address`
  ## matches, or -1.
  let spans = stanzaSpans(doc)
  for idx, s in spans:
    if s.address == address:
      return idx
  return -1

# ---------------------------------------------------------------------------
# Stanza rendering. A new stanza is rendered in the canonical
# multi-line form so a hand-author and the editor produce the same
# shape; the rendering is deterministic.
# ---------------------------------------------------------------------------

proc renderScalar(value: string): string =
  ## Render a scalar field value. A bool literal passes through
  ## unquoted; everything else is double-quoted VERBATIM — the Phase-A
  ## `system.nim` parser's `unquote` only strips the surrounding
  ## quotes (it does not decode `\`-escapes), so a Windows path like
  ## `HKLM\SOFTWARE\...` must be written with single backslashes, not
  ## escaped. A value that itself contains a `"` cannot be represented
  ## in this quote-stripping format — the editor rejects it rather
  ## than emit an unparseable file.
  case value.toLowerAscii()
  of "true", "false": value
  else:
    if value.contains('"'):
      raiseSystemProfileInvalid("a system-resource field value may not " &
        "contain a double-quote character: '" & value & "'")
    "\"" & value & "\""

proc renderList(items: seq[string]): string =
  ## Render a `[a, b]` list literal. Each element is quoted.
  if items.len == 0:
    return "[]"
  result = "[\n"
  for i, it in items:
    result.add("    " & renderScalar(it))
    if i < items.len - 1:
      result.add(",")
    result.add("\n")
  result.add("  ]")

proc renderStanza*(r: SystemResource): seq[string] =
  ## Render a `SystemResource` to its canonical multi-line stanza
  ## lines (ending-free). The field order is fixed per kind so the
  ## rendering is deterministic and a round-trip is byte-stable.
  result.add($r.kind & " {")
  case r.kind
  of srkWindowsRegistryValue:
    result.add("  key = " & renderScalar(r.regKey))
    if r.regName.len > 0:
      result.add("  name = " & renderScalar(r.regName))
    result.add("  kind = " & $r.regValueKind)
    result.add("  value = " & renderScalar(r.regValueLiteral))
  of srkWindowsOptionalFeature:
    result.add("  name = " & renderScalar(r.featureName))
    if not r.featureEnabled:
      result.add("  enabled = false")
  of srkWindowsCapability:
    result.add("  name = " & renderScalar(r.capabilityName))
    if not r.capabilityInstalled:
      result.add("  installed = false")
  of srkWindowsService:
    result.add("  name = " & renderScalar(r.serviceName))
    result.add("  startType = " & r.serviceStartType)
    result.add("  state = " & (if r.serviceRunning: "Running" else: "Stopped"))
  of srkWindowsVsInstaller:
    result.add("  edition = " & renderScalar(r.vsEdition))
    result.add("  channel = " & renderScalar(r.vsChannel))
    if r.vsInstallPath.len > 0:
      result.add("  installPath = " & renderScalar(r.vsInstallPath))
    if r.vsWorkloads.len > 0:
      result.add("  workloads = " & renderList(r.vsWorkloads))
    if r.vsComponents.len > 0:
      result.add("  components = " & renderList(r.vsComponents))
    if r.vsStrict:
      result.add("  strict = true")
  of srkMacosSystemDefault:
    result.add("  domain = " & renderScalar(r.sdDomain))
    result.add("  key = " & renderScalar(r.sdKey))
    if r.sdValueType.len > 0 and r.sdValueType != "-string":
      result.add("  type = " & renderScalar(r.sdValueType))
    if r.sdValueLiteral.len > 0:
      result.add("  value = " & renderScalar(r.sdValueLiteral))
    if r.sdRestartTarget.len > 0:
      result.add("  restartTarget = " & renderScalar(r.sdRestartTarget))
  of srkSystemdSystemUnit:
    result.add("  name = " & renderScalar(r.suName))
    result.add("  content = " & renderScalar(r.suContent))
    if not r.suEnabled:
      result.add("  enabled = false")
  of srkLaunchdSystemDaemon:
    result.add("  label = " & renderScalar(r.sdaLabel))
    result.add("  programArgs = " & renderList(r.sdaProgramArgs))
    if not r.sdaRunAtLoad:
      result.add("  runAtLoad = false")
  of srkFsSystemFile:
    result.add("  path = " & renderScalar(r.sfPath))
    if r.sfContent.len > 0:
      result.add("  content = " & renderScalar(r.sfContent))
  of srkEnvSystemVariable:
    result.add("  name = " & renderScalar(r.evName))
    if r.evContribution.len > 0:
      result.add("  contribute = " & renderList(r.evContribution))
    if r.evIsPathList:
      result.add("  isPathList = true")
  of srkPasswdUser:
    result.add("  name = " & renderScalar(r.puName))
    if r.puHome.len > 0:
      result.add("  home = " & renderScalar(r.puHome))
    if r.puShell.len > 0:
      result.add("  shell = " & renderScalar(r.puShell))
    if r.puGroups.len > 0:
      result.add("  groups = " & renderList(r.puGroups))
  # M82 Phase B: emit `depends_on` last so its presence is obvious in a
  # rendered stanza without disrupting the legacy kind-field order.
  # Absent / empty seq omits the line entirely (the common case), so
  # the existing structural-editor round-trips for resources without
  # declared dependencies stay byte-identical.
  if r.dependsOn.len > 0:
    var deps = newSeq[string]()
    for dep in r.dependsOn:
      deps.add(dep.kind & ":" & dep.name)
    result.add("  depends_on = " & renderList(deps))
  result.add("}")

# ---------------------------------------------------------------------------
# addResource / removeResource.
# ---------------------------------------------------------------------------

proc addResource*(doc: var SystemIntentDoc; r: SystemResource) =
  ## Append `r` as a new stanza at the end of the document. The new
  ## stanza is preceded by exactly one blank line (when the file is
  ## non-empty and does not already end with a blank line) so stanzas
  ## stay visually separated; that blank line is counted as the
  ## stanza's `leadingBlankComments` and removed by `removeResource`,
  ## preserving the round-trip invariant.
  ##
  ## Raises `ESystemProfileInvalid` when a stanza with the same
  ## address already exists (an add must not silently duplicate).
  if findStanza(doc, r.address) >= 0:
    raiseSystemProfileInvalid("a system resource with address '" &
      r.address & "' already exists; use `repro system remove` first")
  let rendered = renderStanza(r)
  # Insert position: after the last non-blank/non-comment line.
  var lastReal = -1
  for i in 0 ..< doc.lines.len:
    if not lineIsBlankOrComment(doc.lines[i]):
      lastReal = i
  var insertAt = lastReal + 1
  # If there is real content above, separate with one blank line —
  # but only if the line just above the insertion point is not
  # already blank.
  var prefix: seq[string]
  if lastReal >= 0:
    if insertAt > 0 and doc.lines[insertAt - 1].strip().len != 0:
      prefix.add("")
  var newLines = prefix & rendered
  # Splice.
  var rebuilt: seq[string]
  for i in 0 ..< insertAt:
    rebuilt.add(doc.lines[i])
  for ln in newLines:
    rebuilt.add(ln)
  for i in insertAt ..< doc.lines.len:
    rebuilt.add(doc.lines[i])
  let wasEmpty = doc.lines.len == 0
  doc.lines = rebuilt
  # An empty file gains a trailing newline (the canonical stanza form
  # ends with one); a non-empty file keeps its original flag so the
  # round-trip stays byte-faithful.
  if wasEmpty and doc.lines.len > 0:
    doc.hasTrailingNewline = true

proc removeResource*(doc: var SystemIntentDoc; address: string): bool =
  ## Remove the stanza whose address matches, together with the run of
  ## blank/comment lines directly above it that the editor counts as
  ## the stanza's. Returns false when no such stanza exists (a remove
  ## of an absent resource is a no-op, not an error).
  let spans = stanzaSpans(doc)
  var target = -1
  for idx, s in spans:
    if s.address == address:
      target = idx
      break
  if target < 0:
    return false
  let s = spans[target]
  let removeFrom = s.startLine - s.leadingBlankComments
  let removeTo = s.endLine
  var rebuilt: seq[string]
  for i in 0 ..< doc.lines.len:
    if i >= removeFrom and i <= removeTo:
      continue
    rebuilt.add(doc.lines[i])
  doc.lines = rebuilt
  return true
