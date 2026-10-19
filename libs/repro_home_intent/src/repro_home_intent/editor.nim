## Structural, formatting-preserving editor for `home.nim`.
##
## Public surface:
##
##   addPackageReference(profilePath, package, activity = "default",
##                       predicate = "", predicateKeyword = ckWhen)
##   removePackageReference(profilePath, package, activity = "default",
##                          predicate = "")
##   setConfigurable(profilePath, packageDotConfigurable, value,
##                   configurableLookup, predicate = "")
##   setHostActivities(profilePath, host, activities)
##
## Round-trip invariant: `add(p, x)` followed by `remove(p, x)` against
## a profile that did not previously contain `x` in the targeted scope
## produces a file byte-identical to the original (including comments,
## blank lines, and trailing newline).
##
## Insertion-position rule (canonical, documented here for round-trip
## stability): new bare package-reference lines are appended at the
## END of the targeted activity body (or conditional block body),
## immediately after the last existing reference and BEFORE any
## trailing blank/comment lines that belong to the parent block.
## Insertion order is therefore deterministic and reversible by
## remove. We do NOT lexically sort because that would silently
## reorder user-authored bodies that intentionally use insertion
## order.

import std/[options, os, sequtils, strutils]
from repro_core/paths import extendedPath

import ./errors
import ./model
import ./parser
import ./predicate

# ---------------------------------------------------------------------------
# Profile (de)serialization.
# ---------------------------------------------------------------------------

proc serialize*(p: Profile): string =
  ## Reassemble the in-memory lines into a string, preserving the
  ## detected line ending and trailing-newline flag.
  for i, line in p.lines:
    if i > 0:
      result.add p.lineEnding
    result.add line
  if p.hasTrailingNewline:
    result.add p.lineEnding

proc writeProfile*(p: Profile) =
  ## Atomically write the profile back to disk: write to a sibling
  ## `<path>.tmp` and `moveFile` over the original. This matches the
  ## spec's atomic-write requirement for sync-tool safety.
  try:
    let payload = serialize(p)
    let tmpPath = p.path & ".tmp"
    writeFile(extendedPath(tmpPath), payload)
    moveFile(extendedPath(tmpPath), extendedPath(p.path))
  except IOError as e:
    var err = newException(EProfileWriteError,
      "writing profile failed: " & e.msg)
    err.profilePath = p.path
    raise err
  except OSError as e:
    var err = newException(EProfileWriteError,
      "writing profile failed: " & e.msg)
    err.profilePath = p.path
    raise err

# ---------------------------------------------------------------------------
# Line manipulation primitives.
# ---------------------------------------------------------------------------

proc indentStr(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = ' '

proc insertLine(p: Profile; atIdx: int; line: string) =
  ## Insert `line` so that it becomes index `atIdx` in `p.lines`.
  ## `atIdx == p.lines.len` appends. Adjusts every `startLine`/
  ## `endLine` of every node by +1 if the node was on or after `atIdx`.
  p.lines.insert(line, atIdx)
  proc shift(node: IntentNode; from1: int) =
    if node.isNil: return
    if node.startLine >= from1: inc node.startLine
    if node.endLine >= from1: inc node.endLine
    case node.kind
    of nkProfileRoot:
      if node.headerLine >= from1: inc node.headerLine
      for ch in node.children: shift(ch, from1)
    of nkActivity:
      if node.activityHeaderLine >= from1: inc node.activityHeaderLine
      for ch in node.activityChildren: shift(ch, from1)
    of nkCondBlock:
      if node.condHeaderLine >= from1: inc node.condHeaderLine
      for ch in node.condChildren: shift(ch, from1)
    of nkPackageRef:
      if node.packageLine >= from1: inc node.packageLine
    of nkConfigBlock:
      if node.configHeaderLine >= from1: inc node.configHeaderLine
      for ch in node.configPackages: shift(ch, from1)
    of nkConfigPackage:
      if node.configPackageHeaderLine >= from1:
        inc node.configPackageHeaderLine
      for ch in node.configEntries: shift(ch, from1)
    of nkConfigEntry:
      if node.configEntryLine >= from1: inc node.configEntryLine
    of nkHostsBlock:
      if node.hostsHeaderLine >= from1: inc node.hostsHeaderLine
      for ch in node.hostsEntries: shift(ch, from1)
    of nkHostsEntry:
      if node.hostEntryLine >= from1: inc node.hostEntryLine
      if node.hostActivitiesLine > 0 and node.hostActivitiesLine >= from1:
        inc node.hostActivitiesLine
      if node.hostListEndLine > 0 and node.hostListEndLine >= from1:
        inc node.hostListEndLine
    of nkResourcesBlock:
      if node.resourcesHeaderLine >= from1: inc node.resourcesHeaderLine
      for ch in node.resourcesEntries: shift(ch, from1)
    of nkResourceEntry:
      if node.resourceHeaderLine >= from1: inc node.resourceHeaderLine
      for ch in node.resourceAttrs: shift(ch, from1)
    of nkResourceAttr:
      if node.resourceAttrLine >= from1: inc node.resourceAttrLine
    of nkOpaque:
      discard
  shift(p.root, atIdx + 1)

proc deleteLine(p: Profile; atIdx: int) =
  ## Remove line at `atIdx`. Adjusts every node's line refs by -1 if
  ## they were strictly after `atIdx`.
  p.lines.delete(atIdx)
  proc shift(node: IntentNode; from1: int) =
    if node.isNil: return
    if node.startLine > from1: dec node.startLine
    if node.endLine >= from1: dec node.endLine
    case node.kind
    of nkProfileRoot:
      if node.headerLine > from1: dec node.headerLine
      for ch in node.children: shift(ch, from1)
    of nkActivity:
      if node.activityHeaderLine > from1: dec node.activityHeaderLine
      for ch in node.activityChildren: shift(ch, from1)
    of nkCondBlock:
      if node.condHeaderLine > from1: dec node.condHeaderLine
      for ch in node.condChildren: shift(ch, from1)
    of nkPackageRef:
      if node.packageLine > from1: dec node.packageLine
    of nkConfigBlock:
      if node.configHeaderLine > from1: dec node.configHeaderLine
      for ch in node.configPackages: shift(ch, from1)
    of nkConfigPackage:
      if node.configPackageHeaderLine > from1:
        dec node.configPackageHeaderLine
      for ch in node.configEntries: shift(ch, from1)
    of nkConfigEntry:
      if node.configEntryLine > from1: dec node.configEntryLine
    of nkHostsBlock:
      if node.hostsHeaderLine > from1: dec node.hostsHeaderLine
      for ch in node.hostsEntries: shift(ch, from1)
    of nkHostsEntry:
      if node.hostEntryLine > from1: dec node.hostEntryLine
      if node.hostActivitiesLine > from1: dec node.hostActivitiesLine
      if node.hostListEndLine > from1: dec node.hostListEndLine
    of nkResourcesBlock:
      if node.resourcesHeaderLine > from1: dec node.resourcesHeaderLine
      for ch in node.resourcesEntries: shift(ch, from1)
    of nkResourceEntry:
      if node.resourceHeaderLine > from1: dec node.resourceHeaderLine
      for ch in node.resourceAttrs: shift(ch, from1)
    of nkResourceAttr:
      if node.resourceAttrLine > from1: dec node.resourceAttrLine
    of nkOpaque:
      discard
  shift(p.root, atIdx + 1)

# ---------------------------------------------------------------------------
# Insertion-position helpers.
# ---------------------------------------------------------------------------

proc lineIsBlankOrComment(s: string): bool =
  let t = s.strip()
  t.len == 0 or t.startsWith("#")

proc lastNonBlankWithin(p: Profile; lo, hi: int): int =
  ## Return the 0-based index of the last non-blank/non-comment line in
  ## the inclusive range [lo, hi]. Returns lo-1 if all blank/comment.
  result = lo - 1
  for i in lo .. hi:
    if not lineIsBlankOrComment(p.lines[i]):
      result = i

proc insertionIndex(p: Profile; node: IntentNode;
                    bodyHeaderLine: int): int =
  ## 0-based line index AFTER which a new child of `node` should be
  ## appended. Skips trailing blank/comment lines so we preserve any
  ## comment that the user wrote *under* the block (it stays as the
  ## block's trailing comment, the new line slots in before it).
  ## Returns the index where the new line should be INSERTED (push
  ## existing lines down).
  let lo = bodyHeaderLine
  let hi = node.endLine - 1
  if hi < lo:
    # Empty body — insert immediately after the header.
    return bodyHeaderLine
  let lastReal = lastNonBlankWithin(p, lo, hi)
  if lastReal < lo:
    return bodyHeaderLine
  result = lastReal + 1

proc firstBodyBlock(act: IntentNode): int =
  ## Index in `act.activityChildren` of the activity's first `stow:` /
  ## `resources:` block (an `inspectProfile` extent), or -1.
  for i, ch in act.activityChildren:
    if ch.kind == nkOpaque and
       ch.opaqueKind in {okActivityStowBlock, okActivityResources}:
      return i
  -1

proc activityAppendIndex(p: Profile; act: IntentNode): int =
  ## Where a new element of `act`'s body is inserted. Package references
  ## and `when` blocks go after the body's last such element and BEFORE the
  ## activity's `stow:` / `resources:` blocks, so the elements stay
  ## together and the blocks stay at the end where they were written (the
  ## comment lines above a block keep introducing it). Without such a block
  ## this is `insertionIndex`.
  let k = firstBodyBlock(act)
  if k < 0:
    return insertionIndex(p, act, act.activityHeaderLine)
  if k == 0:
    return act.activityHeaderLine
  act.activityChildren[k - 1].endLine

# ---------------------------------------------------------------------------
# Sub-block lookups.
# ---------------------------------------------------------------------------

proc findCondWithCanonical(blocks: seq[IntentNode]; canon: string):
    Option[IntentNode] =
  for ch in blocks:
    if ch.kind == nkCondBlock and ch.canonicalPredicate == canon:
      return some(ch)
  none(IntentNode)

proc findPackageRef(blocks: seq[IntentNode]; pkg: string): int =
  ## Index in `blocks` where a package-reference matching `pkg` lives,
  ## or -1. Matches on package name only (any version variant).
  for i, ch in blocks:
    if ch.kind == nkPackageRef and ch.packageName == pkg:
      return i
  -1

proc findPackageRefVersioned(blocks: seq[IntentNode]; pkg, version: string): int =
  ## M69: locate a package reference matching both `pkg` AND `version`.
  ## An empty `version` matches a bare reference (no version pin); a
  ## non-empty `version` matches only the exact pinned literal so
  ## `repro home remove jdk@21.0.5` strips ONLY that pinned line and
  ## leaves a bare `package(jdk)` elsewhere untouched.
  for i, ch in blocks:
    if ch.kind == nkPackageRef and ch.packageName == pkg and
       ch.packageVersion == version:
      return i
  -1

# ---------------------------------------------------------------------------
# Block construction.
# ---------------------------------------------------------------------------

proc createActivityBlock(p: Profile; activityName: string): IntentNode =
  ## Append a new `activity <name>:` block at the end of the profile.
  ## The block is created with NO body lines; the caller then inserts
  ## children through the editor APIs.
  let parentIndent = p.root.indent + p.indentStep
  let header = indentStr(parentIndent) & "activity " & activityName & ":"
  # Insert position: after the last body line, before any trailing
  # blank/comment lines that belong to the file footer.
  let insertAt = p.root.endLine
  insertLine(p, insertAt, header)
  result = IntentNode(kind: nkActivity,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: parentIndent, activityName: activityName,
    activityHeaderLine: insertAt + 1, activityChildren: @[])
  p.root.children.add result
  if p.root.endLine < insertAt + 1:
    p.root.endLine = insertAt + 1

proc createCondBlock(p: Profile; parent: IntentNode;
                     predicateSrc: string; keyword: CondKeyword): IntentNode =
  ## Append a new `when <pred>:` (or `if <pred>:`) block at the end of
  ## `parent`'s body. `parent` may be an `nkActivity` or `nkCondBlock`.
  let parentBodyIndent =
    case parent.kind
    of nkActivity: parent.indent + p.indentStep
    of nkCondBlock: parent.indent + p.indentStep
    else: parent.indent + p.indentStep
  let predAst = parsePredicate(p.path, predicateSrc, 0)
  let canon = renderPredicate(normalizeAst(predAst))
  let kwStr = if keyword == ckWhen: "when" else: "if"
  let header = indentStr(parentBodyIndent) & kwStr & " " & canon & ":"
  let parentHeaderLine =
    case parent.kind
    of nkActivity: parent.activityHeaderLine
    of nkCondBlock: parent.condHeaderLine
    else: parent.startLine
  let insertAt =
    if parent.kind == nkActivity: activityAppendIndex(p, parent)
    else: insertionIndex(p, parent, parentHeaderLine)
  let blockAt =
    if parent.kind == nkActivity: firstBodyBlock(parent) else: -1
  insertLine(p, insertAt, header)
  result = IntentNode(kind: nkCondBlock,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: parentBodyIndent, keyword: keyword,
    predicateSource: canon,
    predicateAst: predAst, canonicalPredicate: canon,
    condHeaderLine: insertAt + 1, condChildren: @[])
  case parent.kind
  of nkActivity:
    if blockAt >= 0:
      parent.activityChildren.insert(result, blockAt)
    else:
      parent.activityChildren.add result
    if parent.endLine < insertAt + 1:
      parent.endLine = insertAt + 1
  of nkCondBlock:
    parent.condChildren.add result
    if parent.endLine < insertAt + 1:
      parent.endLine = insertAt + 1
  else: discard

# ---------------------------------------------------------------------------
# addPackageReference / removePackageReference.
# ---------------------------------------------------------------------------

proc childrenSeq(node: IntentNode): seq[IntentNode] =
  case node.kind
  of nkActivity: node.activityChildren
  of nkCondBlock: node.condChildren
  else: @[]

proc setChildrenSeq(node: IntentNode; children: seq[IntentNode]) =
  case node.kind
  of nkActivity: node.activityChildren = children
  of nkCondBlock: node.condChildren = children
  else: discard

proc headerLineOf(node: IntentNode): int =
  case node.kind
  of nkActivity: node.activityHeaderLine
  of nkCondBlock: node.condHeaderLine
  of nkConfigBlock: node.configHeaderLine
  of nkConfigPackage: node.configPackageHeaderLine
  of nkHostsBlock: node.hostsHeaderLine
  else: node.startLine

proc growBlockEndIfNeeded(node: IntentNode; line: int) =
  if node.endLine < line:
    node.endLine = line

proc profileHasMacroImport(p: Profile): bool =
  ## M83 Phase F3: detect whether the source carries the Phase A
  ## `import repro_profile` macro-library import. Used by the package-
  ## spelling renderer to decide whether a hyphenated name needs
  ## backticks. A legacy text-form fixture (slash-form `import
  ## repro/profile`) has no Phase A compile requirement, so hyphenated
  ## names stay bare to keep the existing round-trip behaviour
  ## byte-identical against the legacy home-intent test fixtures.
  const Marker = "import repro_profile"
  for raw in p.lines:
    let line = raw.strip()
    if line == Marker:
      return true
    if line.startsWith(Marker) and line.len > Marker.len and
       line[Marker.len] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      return true
  false

proc needsQuotedPackageSpelling(pkg: string): bool =
  ## A package name that cannot be written bare or backtick-quoted because
  ## it does not start like a Nim identifier (``7zip``). It is written as a
  ## string, the form the parser and the profile macro both accept
  ## (Package-Model.md §"Package names").
  pkg.len > 0 and not (pkg[0].isAlphaAscii() or pkg[0] == '_')

proc renderPackageRefSpelling(p: Profile; pkg: string): string =
  ## M83 Phase F3: emit a hyphenated package name with backticks
  ## (`` `pkg-x` ``) so the resulting line is also a valid Phase A
  ## macro-form identifier — but ONLY when the profile is Phase-A
  ## shaped (detected via the `import repro_profile` macro-library
  ## import). Legacy text-form profiles keep the bare spelling so the
  ## structural editor's round-trip stays byte-identical against the
  ## existing home-intent test fixtures.
  if needsQuotedPackageSpelling(pkg):
    return "\"" & pkg & "\""
  if not profileHasMacroImport(p):
    return pkg
  for ch in pkg:
    if ch == '-':
      return "`" & pkg & "`"
  pkg

proc stripBodyDiscardPlaceholder(p: Profile; blk: IntentNode) =
  ## M83 Phase F3: drop the synthetic `discard` placeholder line that
  ## `removePackageRefFromBlock` may have left when the body became
  ## empty. Called from `addPackageRefInBlock` right before inserting
  ## a real package line. Without this strip, the next add would
  ## leave the discard line in place AND add the package — visible as
  ## a stale `discard` in the file.
  let header = headerLineOf(blk)
  let endLine = blk.endLine
  var idx = header
  while idx < endLine and idx < p.lines.len:
    let line = p.lines[idx]
    var insideOpaque = false
    for ch in childrenSeq(blk):
      if ch.kind == nkOpaque and idx + 1 >= ch.startLine and
         idx + 1 <= ch.endLine:
        insideOpaque = true
    if insideOpaque:
      inc idx
      continue
    if line.strip() == "discard":
      deleteLine(p, idx)
      return
    inc idx

proc renderPackageLineText(p: Profile; pkg, version: string): string =
  ## M69: pick the source-text form for a package reference. A bare
  ## reference (empty `version`) renders as the legacy form (a bare
  ## identifier, optionally backtick-quoted by `renderPackageRefSpelling`
  ## for the M83 Phase A macro form). A versioned reference renders
  ## as `package(<pkg>, "<version>")` — the spec-mandated literal that
  ## the M69 parser round-trips byte-for-byte. The bare-`package(<id>)`
  ## form (versioned-shape with empty version) is reachable only via
  ## the CLI's `--versioned-call-form` path that the structural editor
  ## does not currently expose; the renderer falls back to the legacy
  ## bare form so a no-version `add` continues to produce the
  ## byte-identical line the existing round-trip tests assert.
  if version.len > 0:
    let id =
      if needsQuotedPackageSpelling(pkg): "\"" & pkg & "\"" else: pkg
    return "package(" & id & ", \"" & version & "\")"
  renderPackageRefSpelling(p, pkg)

proc addPackageRefInBlock(p: Profile; blk: IntentNode; pkg: string;
                          version = "") =
  ## Append `pkg` (optionally pinned to `version`) as the last child
  ## of `blk` (`nkActivity` or `nkCondBlock`), preserving any trailing
  ## blank/comment lines.
  stripBodyDiscardPlaceholder(p, blk)
  let bodyIndent = blk.indent + p.indentStep
  let line = indentStr(bodyIndent) & renderPackageLineText(p, pkg, version)
  let header = headerLineOf(blk)
  let insertAt =
    if blk.kind == nkActivity: activityAppendIndex(p, blk)
    else: insertionIndex(p, blk, header)
  let blockAt =
    if blk.kind == nkActivity: firstBodyBlock(blk) else: -1
  insertLine(p, insertAt, line)
  let newNode = IntentNode(kind: nkPackageRef,
    startLine: insertAt + 1, endLine: insertAt + 1, indent: bodyIndent,
    packageName: pkg, packageLine: insertAt + 1,
    packageVersion: version)
  case blk.kind
  of nkActivity:
    if blockAt >= 0:
      blk.activityChildren.insert(newNode, blockAt)
    else:
      blk.activityChildren.add newNode
  of nkCondBlock:
    blk.condChildren.add newNode
  else: discard
  growBlockEndIfNeeded(blk, insertAt + 1)
  # Cascade endLine growth up the chain.
  var parentSeq = @[p.root]
  proc grow(node: IntentNode; line: int) =
    growBlockEndIfNeeded(node, line)
  grow(p.root, insertAt + 1)

proc addPackageReference*(profilePath: string; package: string;
                          activity = "default";
                          predicate = "";
                          predicateKeyword = ckWhen;
                          version = "") =
  ## Add `package` as a bare reference inside `activity`, optionally
  ## nested under a `when <predicate>:` or `if <predicate>:` block.
  ## Behavior:
  ##
  ## - If `activity` does not exist, the activity block is created at
  ##   the end of the profile body.
  ## - If a conditional block with a predicate that NORMALIZES to the
  ##   same canonical form already exists, the new reference is
  ##   appended into that existing block and the keyword used by that
  ##   block is preserved (so `--when` finds an `if` block and appends
  ##   in-place rather than creating a duplicate).
  ## - Otherwise a new `<predicateKeyword> <canonicalPredicate>:` block
  ##   is created at the end of the activity body.
  ## - The reference is appended at the end of the target body. See
  ##   the module docstring for the "insertion-position" rule.
  ##
  ## The package name is added even if a reference with the same name
  ## already exists in that block; the spec is silent on dedup, but
  ## the round-trip invariant requires that `add` always produce an
  ## insertable line and `remove` always strip exactly one. The CLI
  ## may layer its own dedup over this if desired.
  ##
  ## The profile is read with `inspectProfile`: helper calls and the
  ## activity's `stow:` / `resources:` blocks are stepped over and kept
  ## byte-for-byte; the new line goes before those blocks
  ## (`activityAppendIndex`).
  let prof = inspectProfile(profilePath)
  var activityNode: IntentNode
  let existing = findActivity(prof, activity)
  if existing.isSome:
    activityNode = existing.get
  else:
    activityNode = createActivityBlock(prof, activity)
  var targetBlock: IntentNode
  if predicate.len == 0:
    targetBlock = activityNode
  else:
    let predAst = parsePredicate(profilePath, predicate, 0)
    let canon = renderPredicate(normalizeAst(predAst))
    let existingCond = findCondWithCanonical(
      activityNode.activityChildren, canon)
    if existingCond.isSome:
      targetBlock = existingCond.get
    else:
      targetBlock = createCondBlock(prof, activityNode,
        predicate, predicateKeyword)
  addPackageRefInBlock(prof, targetBlock, package, version)
  writeProfile(prof)

proc removePackageRefFromBlock(p: Profile; blk: IntentNode;
                              pkg: string;
                              version = ""): bool =
  ## Remove the first matching package reference from `blk`. Returns
  ## true on success. M69: when `version` is non-empty, only the
  ## exact `package(<pkg>, "<version>")` line is removed (so removing
  ## `jdk@21.0.5` does not strip a bare `package(jdk)` elsewhere in
  ## the same block). When `version` is empty the legacy by-name
  ## match runs and the first matching reference is removed.
  ##
  ## M83 Phase F3: when the removal leaves the block body empty, leave
  ## a `discard` placeholder line so the resulting file remains a valid
  ## Phase A macro-form body (Nim requires every block to have at
  ## least one statement). The legacy text parser already silently
  ## tolerates an empty body via the activity-block re-emission code;
  ## the `discard` placeholder is the canonical no-op statement for
  ## Phase A and round-trips cleanly through the structural editor's
  ## re-read (it is parsed as a no-op activity-body element and
  ## ignored by the intent layer).
  var children = childrenSeq(blk)
  let idx =
    if version.len > 0: findPackageRefVersioned(children, pkg, version)
    else: findPackageRef(children, pkg)
  if idx < 0:
    return false
  let line = children[idx].packageLine
  deleteLine(p, line - 1)
  children.delete(idx)
  setChildrenSeq(blk, children)
  if children.len == 0 and profileHasMacroImport(p):
    let bodyIndent = blk.indent + p.indentStep
    let discardLine = indentStr(bodyIndent) & "discard"
    let header = headerLineOf(blk)
    let insertAt = insertionIndex(p, blk, header)
    insertLine(p, insertAt, discardLine)
    growBlockEndIfNeeded(blk, insertAt + 1)
  true

proc removePackageReference*(profilePath: string; package: string;
                             activity = "default";
                             predicate = "";
                             version = ""): bool {.discardable.} =
  ## Remove the first occurrence of `package` from the targeted scope.
  ## If the removal would leave an activity body empty, the activity
  ## block stays (avoids noisy churn — per the spec's reasoning that
  ## the user's intent is to remove the package, not the activity).
  ## Returns whether a line was removed (the file is not rewritten when
  ## none was). Read with `inspectProfile`, so helper calls and `stow:` /
  ## `resources:` blocks are stepped over and kept byte-for-byte; a package
  ## a helper call contributes has no line here to remove (the CLI names
  ## those calls, `opaqueNodes`).
  let prof = inspectProfile(profilePath)
  let activityOpt = findActivity(prof, activity)
  if activityOpt.isNone:
    return false # nothing to remove
  let activityNode = activityOpt.get
  if predicate.len == 0:
    result = removePackageRefFromBlock(prof, activityNode, package, version)
    if result:
      writeProfile(prof)
    return
  let predAst = parsePredicate(profilePath, predicate, 0)
  let canon = renderPredicate(normalizeAst(predAst))
  let existingCond = findCondWithCanonical(
    activityNode.activityChildren, canon)
  if existingCond.isNone:
    return
  result = removePackageRefFromBlock(prof, existingCond.get, package,
    version)
  if result:
    writeProfile(prof)

# ---------------------------------------------------------------------------
# setConfigurable.
# ---------------------------------------------------------------------------

type
  ConfigurableLookup* = proc(package, configurable: string): bool {.gcsafe.}

proc renderConfigValue(value: string): string =
  ## Quote a string value. Booleans and numbers pass through unquoted
  ## (the spec accepts Nim literals on the RHS); we make this decision
  ## by looking at the value bytes.
  if value == "true" or value == "false":
    return value
  # Bare numeric literal?
  var allDigits = value.len > 0
  var i = 0
  if value.len > 0 and value[0] in {'-', '+'}: inc i
  while i < value.len:
    if not (value[i].isDigit() or value[i] == '.'): allDigits = false; break
    inc i
  if allDigits:
    return value
  result = "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc splitPkgDotKey(raw: string): tuple[pkg, key: string] =
  let dot = raw.find('.')
  if dot <= 0 or dot == raw.len - 1:
    raiseInvalidConfigurable(raw)
  (raw[0 ..< dot], raw[dot + 1 .. ^1])

proc createConfigBlock(p: Profile): IntentNode =
  let parentIndent = p.root.indent + p.indentStep
  let header = indentStr(parentIndent) & "config:"
  let insertAt = p.root.endLine
  insertLine(p, insertAt, header)
  result = IntentNode(kind: nkConfigBlock,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: parentIndent, configHeaderLine: insertAt + 1,
    configPackages: @[])
  p.root.children.add result
  if p.root.endLine < insertAt + 1:
    p.root.endLine = insertAt + 1

proc createConfigPackage(p: Profile; cfg: IntentNode;
                         pkgName: string): IntentNode =
  let parentIndent = cfg.indent + p.indentStep
  let header = indentStr(parentIndent) & pkgName & ":"
  let insertAt = insertionIndex(p, cfg, cfg.configHeaderLine)
  insertLine(p, insertAt, header)
  result = IntentNode(kind: nkConfigPackage,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: parentIndent, configPackageName: pkgName,
    configPackageHeaderLine: insertAt + 1, configEntries: @[])
  cfg.configPackages.add result
  if cfg.endLine < insertAt + 1:
    cfg.endLine = insertAt + 1
  if p.root.endLine < insertAt + 1:
    p.root.endLine = insertAt + 1

proc findConfigPackage(cfg: IntentNode; pkgName: string):
    Option[IntentNode] =
  ## The first UNGUARDED `<pkgName>:` block of `config:`; a package block
  ## inside a guard chain is not a target for an unguarded edit.
  for ch in cfg.configPackages:
    if ch.kind == nkConfigPackage and ch.configPackageName == pkgName:
      return some(ch)
  none(IntentNode)

proc findConfigEntry(entries: seq[IntentNode]; key: string): int =
  ## Index of the first `<key> = ...` line among `entries` (direct
  ## children only: an entry inside a nested guard chain is not matched).
  for i, ch in entries:
    if ch.kind == nkConfigEntry and ch.configKey == key:
      return i
  -1

type
  AssignmentSite = object
    node: IntentNode
    guards: seq[string]   ## predicate text of every enclosing guard, outer
                          ## first; empty when unguarded

proc collectAssignments(nodes: seq[IntentNode]; pkgName, key: string;
                        inPackage: bool; guards: seq[string];
                        into: var seq[AssignmentSite]) =
  ## Every assignment of `<pkgName>.<key>` under `nodes` (a `config:` body
  ## or a package body), with the guards around it.
  for node in nodes:
    case node.kind
    of nkConfigPackage:
      if node.configPackageName == pkgName:
        collectAssignments(node.configEntries, pkgName, key, true, guards,
          into)
    of nkConfigEntry:
      if inPackage and node.configKey == key:
        into.add AssignmentSite(node: node, guards: guards)
    of nkCondBlock:
      let text =
        case node.keyword
        of ckWhen: "when " & node.predicateSource
        of ckIf: "if " & node.predicateSource
        of ckElif: "elif " & node.predicateSource
        of ckElse: "else"
      collectAssignments(node.condChildren, pkgName, key, inPackage,
        guards & @[text], into)
    else: discard

proc describeSite(p: Profile; site: AssignmentSite): string =
  result = p.path & ":" & $site.node.configEntryLine
  if site.guards.len == 0:
    result.add " (unguarded)"
  else:
    result.add " (under `" & site.guards.join(":` / `") & ":`)"

proc refuseOverlappingConfigAssignment(p: Profile; cfg: IntentNode;
                                       pkgName, key: string;
                                       added: IntentNode) =
  ## A NEW assignment `added` may sit only after unguarded assignments of
  ## the same key. Scalars resolve last-write-wins
  ## (Configurable-System.md §Priorities And Contributions), so on a host
  ## where two assignments' guards both hold the later one wins: `added`
  ## must not be followed by another assignment (it would be shadowed),
  ## and must not follow a guarded one (it would shadow it -- for an
  ## unguarded `added`, on every host that guard selects). Guards are not
  ## compared for satisfiability (Home-Profile-Intent-Layer.md §Predicate
  ## Normalization), so any such pair is refused.
  var sites: seq[AssignmentSite]
  collectAssignments(cfg.configPackages, pkgName, key, false, @[], sites)
  var conflicting: seq[string]
  var reason = ""
  for site in sites:
    if site.node == added:
      continue
    if site.node.configEntryLine > added.configEntryLine:
      conflicting.add describeSite(p, site)
      if reason.len == 0:
        reason = "a later assignment would override it wherever both apply"
    elif site.guards.len > 0:
      conflicting.add describeSite(p, site)
      if reason.len == 0:
        reason = "it would override a guarded assignment wherever both apply"
  if conflicting.len > 0:
    raiseOverlappingAssignment(p.path, pkgName & "." & key, reason &
      "; name that guard with --when to edit it, or edit the profile by " &
      "hand", conflicting)

proc growEnclosingEnd(p: Profile; line: int; nodes: varargs[IntentNode]) =
  for node in nodes:
    if not node.isNil and node.endLine < line:
      node.endLine = line
  if p.root.endLine < line:
    p.root.endLine = line

proc createConfigGuard(p: Profile; pkg: IntentNode;
                       predicateSrc: string): IntentNode =
  ## Append a `when <canonical predicate>:` block at the end of the
  ## package block `pkg`. Created empty; the caller adds the entry.
  let predAst = parsePredicate(p.path, predicateSrc, 0)
  let canon = renderPredicate(normalizeAst(predAst))
  let guardIndent = pkg.indent + p.indentStep
  let insertAt = insertionIndex(p, pkg, pkg.configPackageHeaderLine)
  insertLine(p, insertAt, indentStr(guardIndent) & "when " & canon & ":")
  result = IntentNode(kind: nkCondBlock,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: guardIndent, keyword: ckWhen,
    predicateSource: canon, predicateAst: predAst,
    canonicalPredicate: canon, condHeaderLine: insertAt + 1,
    condChildren: @[])
  pkg.configEntries.add result

proc setConfigurable*(profilePath: string; packageDotConfigurable: string;
                     value: string;
                     configurableLookup: ConfigurableLookup;
                     predicate = "") =
  ## Write or update `<package>.<configurable> = <value>` inside the
  ## profile's `config:` section. Creates the `config:` block and the
  ## `<package>:` sub-block on demand. Subsequent calls into the same
  ## sub-block append the new entry in insertion order.
  ##
  ## `predicate` (a runtime predicate expression, e.g. `windows` or
  ## `linux and arm64`) guards the assignment: it lands in the package
  ## block's `when <pred>:` block whose normalized predicate matches,
  ## created (as `when <canonical predicate>:` at the end of the package
  ## block) when there is none. Without it the unguarded assignment is
  ## edited. Either way an existing assignment of the key at that target
  ## is updated in place; a NEW assignment that would overlap an
  ## assignment of the same key under a different guard is refused
  ## (`EOverlappingAssignment`, see `refuseOverlappingConfigAssignment`).
  ## Assignments inside guard chains the edit does not target, and
  ## package blocks inside guard chains, are left byte-for-byte as they
  ## are.
  ##
  ## `configurableLookup(package, configurable)` is the seam by which
  ## the caller (CLI / apply pipeline) injects knowledge of which
  ## configurables a package declares. If the lookup returns false,
  ## `EUnknownConfigurable` is raised. Passing `nil` opts out of the
  ## check (the apply pipeline does its own resolution).
  let (pkgName, keyName) = splitPkgDotKey(packageDotConfigurable)
  if configurableLookup != nil and not configurableLookup(pkgName, keyName):
    raiseUnknownConfigurable(profilePath, pkgName, keyName)
  # Validate the predicate before touching anything (it raises
  # `EUnstructured` naming the offending token).
  let canon =
    if predicate.len > 0:
      renderPredicate(normalizeAst(parsePredicate(profilePath, predicate, 0)))
    else: ""
  let prof = loadProfile(profilePath)
  var cfg: IntentNode
  let cfgOpt = findConfigBlock(prof)
  if cfgOpt.isSome:
    cfg = cfgOpt.get
  else:
    cfg = createConfigBlock(prof)
  var pkg: IntentNode
  let pkgOpt = findConfigPackage(cfg, pkgName)
  if pkgOpt.isSome:
    pkg = pkgOpt.get
  else:
    pkg = createConfigPackage(prof, cfg, pkgName)
  # The block the assignment belongs in: the package block itself, or its
  # guard block for `predicate`.
  var target = pkg
  var guard: IntentNode = nil
  if canon.len > 0:
    let existingGuard = findCondWithCanonical(pkg.configEntries, canon)
    guard =
      if existingGuard.isSome: existingGuard.get
      else: createConfigGuard(prof, pkg, predicate)
    target = guard
  let siblings =
    if guard.isNil: pkg.configEntries else: guard.condChildren
  let entryIndent = target.indent + prof.indentStep
  let rhs = renderConfigValue(value)
  let newLine = indentStr(entryIndent) & keyName & " = " & rhs
  let existingIdx = findConfigEntry(siblings, keyName)
  if existingIdx >= 0:
    # Update in place. Preserve the line index.
    let entry = siblings[existingIdx]
    prof.lines[entry.configEntryLine - 1] = newLine
    entry.configValueSource = rhs
  else:
    let insertAt = insertionIndex(prof, target, headerLineOf(target))
    insertLine(prof, insertAt, newLine)
    let entryNode = IntentNode(kind: nkConfigEntry,
      startLine: insertAt + 1, endLine: insertAt + 1, indent: entryIndent,
      configKey: keyName, configValueSource: rhs,
      configEntryLine: insertAt + 1)
    if guard.isNil:
      pkg.configEntries.add entryNode
    else:
      guard.condChildren.add entryNode
    growEnclosingEnd(prof, insertAt + 1, guard, pkg, cfg)
    refuseOverlappingConfigAssignment(prof, cfg, pkgName, keyName, entryNode)
  writeProfile(prof)

# ---------------------------------------------------------------------------
# setHostActivities.
# ---------------------------------------------------------------------------

proc createHostsBlock(p: Profile): IntentNode =
  let parentIndent = p.root.indent + p.indentStep
  let header = indentStr(parentIndent) & "hosts:"
  let insertAt = p.root.endLine
  insertLine(p, insertAt, header)
  result = IntentNode(kind: nkHostsBlock,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: parentIndent, hostsHeaderLine: insertAt + 1,
    hostsEntries: @[])
  p.root.children.add result
  if p.root.endLine < insertAt + 1:
    p.root.endLine = insertAt + 1

proc renderHostList(activities: seq[string]): string =
  result = "["
  for i, a in activities:
    if i > 0:
      result.add ", "
    result.add a
  result.add "]"

proc findHostsEntry(hostsBlk: IntentNode; host: string): int =
  for i, ch in hostsBlk.hostsEntries:
    if ch.hostName == host:
      return i
  -1

proc replaceLineSpan(p: Profile; firstLine, lastLine: int;
                     replacement: seq[string]) =
  ## Replace the 1-based lines `firstLine .. lastLine` with `replacement`,
  ## keeping every node's line references consistent.
  for _ in firstLine .. lastLine:
    deleteLine(p, firstLine - 1)
  for k, line in replacement:
    insertLine(p, firstLine - 1 + k, line)

proc setHostActivitiesIn(prof: Profile; host: string;
                         activities: seq[string]) =
  ## `setHostActivities` on a profile already read: the host's activity
  ## list -- all of its lines when it spans several -- becomes the
  ## canonical one-line `[a, b]`; a missing entry (or `activities:` key)
  ## is added.
  var hostsBlk: IntentNode
  let hostsOpt = findHostsBlock(prof)
  if hostsOpt.isSome:
    hostsBlk = hostsOpt.get
  else:
    hostsBlk = createHostsBlock(prof)
  let entryIndent = hostsBlk.indent + prof.indentStep
  let line = indentStr(entryIndent) & "\"" & host & "\": " &
    renderHostList(activities)
  let existingIdx = findHostsEntry(hostsBlk, host)
  if existingIdx >= 0 and hostsBlk.hostsEntries[existingIdx].hostBlockForm:
    # Block form: rewrite (or add) the `activities:` line under the host,
    # leaving `applies:` and the host line as they are.
    let entry = hostsBlk.hostsEntries[existingIdx]
    let childLine = indentStr(entryIndent + prof.indentStep) &
      "activities: " & renderHostList(activities)
    if entry.hostActivitiesLine > 0:
      replaceLineSpan(prof, entry.hostActivitiesLine,
        max(entry.hostListEndLine, entry.hostActivitiesLine), @[childLine])
      entry.hostListEndLine = entry.hostActivitiesLine
    else:
      insertLine(prof, entry.hostEntryLine, childLine)
      entry.hostActivitiesLine = entry.hostEntryLine + 1
      entry.hostListEndLine = entry.hostActivitiesLine
    entry.hostActivities = activities
  elif existingIdx >= 0:
    let entry = hostsBlk.hostsEntries[existingIdx]
    replaceLineSpan(prof, entry.hostEntryLine,
      max(entry.hostListEndLine, entry.hostEntryLine), @[line])
    entry.hostListEndLine = entry.hostEntryLine
    entry.hostActivities = activities
  else:
    let insertAt = insertionIndex(prof, hostsBlk, hostsBlk.hostsHeaderLine)
    insertLine(prof, insertAt, line)
    let entry = IntentNode(kind: nkHostsEntry,
      startLine: insertAt + 1, endLine: insertAt + 1, indent: entryIndent,
      hostName: host, hostActivities: activities,
      hostEntryLine: insertAt + 1, hostListEndLine: insertAt + 1)
    hostsBlk.hostsEntries.add entry
    if hostsBlk.endLine < insertAt + 1:
      hostsBlk.endLine = insertAt + 1
    if prof.root.endLine < insertAt + 1:
      prof.root.endLine = insertAt + 1

proc setHostActivities*(profilePath, host: string;
                       activities: seq[string]) =
  ## Create or update the `hosts:` entry for `host`. Writes
  ## `"<host>": [<activity>, ...]` in the canonical form (a list that
  ## spanned lines becomes one line). `default` is always implicitly active,
  ## so the activities list does NOT need to include it. We don't enforce
  ## that here; the CLI does. `repro home enable` / `disable` use
  ## `editHostActivity`, which keeps the entry's own layout.
  ##
  ## Read with `inspectHostsBlock`: the edit is of the `hosts:` block only,
  ## so nothing elsewhere in the profile (helper calls, an activity's
  ## `stow:` / `resources:` blocks) is read or can stop it, and all of it
  ## keeps its bytes.
  let prof = inspectHostsBlock(profilePath)
  setHostActivitiesIn(prof, host, activities)
  writeProfile(prof)

type
  HostListItem = object
    ## One activity identifier of a `[...]` list, as offsets into the
    ## list's text: `[first, last)`.
    name: string
    first, last: int

proc hostListItems(text: string; openIdx: int):
    tuple[items: seq[HostListItem]; closeIdx: int] =
  ## The identifiers of the list whose `[` is `text[openIdx]`, and the
  ## offset of its `]` (-1 when it does not close). `#` comments run to the
  ## end of their line.
  result.closeIdx = -1
  var i = openIdx + 1
  while i < text.len:
    let ch = text[i]
    if ch == ']':
      result.closeIdx = i
      return
    if ch == '#':
      while i < text.len and text[i] != '\n':
        inc i
      continue
    if ch.isAlphaAscii() or ch == '_' or ch.isDigit():
      let start = i
      while i < text.len and (text[i].isAlphaAscii() or text[i].isDigit() or
                              text[i] == '_'):
        inc i
      result.items.add HostListItem(name: text[start ..< i], first: start,
        last: i)
      continue
    inc i

proc lineStartOf(text: string; offset: int): int =
  ## Offset of the first character of the line holding `offset`.
  var i = offset - 1
  while i >= 0 and text[i] != '\n':
    dec i
  i + 1

proc lineEndOf(text: string; offset: int): int =
  ## Offset of the `\n` ending the line holding `offset` (or `text.len`).
  var i = offset
  while i < text.len and text[i] != '\n':
    inc i
  i

const HostListWrapColumn = 80
  ## A spanning list whose last line would grow past this column gets the
  ## new activity on a continuation line of its own (`editHostActivity`).

proc enableInList(text: string; openIdx: int; items: seq[HostListItem];
                  closeIdx: int; activity: string): string =
  if items.len == 0:
    return text[0 .. openIdx] & activity & text[closeIdx .. ^1]
  let last = items[^1]
  let lineStart = lineStartOf(text, last.first)
  let lineLen = lineEndOf(text, last.last) - lineStart
  if lineStart > 0 and lineLen + 2 + activity.len > HostListWrapColumn:
    # The list already spans lines and its last line is full: continue it
    # on a new line at that line's indentation.
    var indent = 0
    while text[lineStart + indent] == ' ':
      inc indent
    return text[0 ..< last.last] & ",\n" & indentStr(indent) & activity &
      text[last.last .. ^1]
  text[0 ..< last.last] & ", " & activity & text[last.last .. ^1]

proc disableInList(text: string; openIdx: int; items: seq[HostListItem];
                   k: int): string =
  ## `text` without `items[k]` and one separator next to it. Lines other
  ## than the ones holding the item keep their bytes; a continuation line
  ## the removal empties is dropped.
  let item = items[k]
  if items.len == 1:
    return text[0 ..< item.first] & text[item.last .. ^1]
  if k == items.high:
    # The last item: drop the separator before it (`, x` -- or `,\n   x`,
    # which joins the closing `]` onto the previous item's line).
    return text[0 ..< items[k - 1].last] & text[item.last .. ^1]
  # Drop the item, its comma and the blanks after it on the same line.
  var cut = item.last
  while cut < text.len and text[cut] == ' ':
    inc cut
  if cut < text.len and text[cut] == ',':
    inc cut
  while cut < text.len and text[cut] == ' ':
    inc cut
  var head = text[0 ..< item.first]
  var tail = text[cut .. ^1]
  if tail.len == 0 or tail[0] == '\n':
    # The item ended its line: drop the blanks it leaves at the end, and
    # the whole line when nothing else was on it.
    while head.len > 0 and head[^1] == ' ':
      head.setLen(head.len - 1)
    if head.len > 0 and head[^1] == '\n' and tail.len > 0:
      tail = tail[1 .. ^1]
  head & tail

proc editHostActivity*(profilePath, host, activity: string;
                       enable: bool): bool =
  ## Add (`enable`) or remove `activity` in `host`'s `hosts:` entry, the
  ## edit `repro home enable` / `disable` make. Only the activity list of
  ## that entry changes: the new identifier goes after the last one (on a
  ## new continuation line when the list spans lines and its last line
  ## would pass `HostListWrapColumn`), a removed one takes one separator
  ## with it, and every other line of the profile -- the entry's other
  ## lines included -- keeps its bytes. An entry (or block-form
  ## `activities:` key) that does not exist yet is added in the canonical
  ## one-line form (`setHostActivities`). Returns whether the file changed.
  ##
  ## Read with `inspectHostsBlock`, so only the `hosts:` block is read: a
  ## profile that composes helpers, or whose activities hold `stow:` /
  ## `resources:` blocks, is edited all the same.
  let prof = inspectHostsBlock(profilePath)
  let hostsOpt = findHostsBlock(prof)
  let idx =
    if hostsOpt.isSome: findHostsEntry(hostsOpt.get, host) else: -1
  let entry =
    if idx >= 0: hostsOpt.get.hostsEntries[idx] else: nil
  if entry.isNil or (entry.hostBlockForm and entry.hostActivitiesLine == 0):
    var acts =
      if entry.isNil: newSeq[string]() else: entry.hostActivities
    if enable:
      acts.add activity
    else:
      let before = acts.len
      acts = acts.filterIt(it != activity)
      if not entry.isNil and acts.len == before:
        return false
    setHostActivitiesIn(prof, host, acts)
    writeProfile(prof)
    return true
  if enable == (activity in entry.hostActivities):
    return false
  let firstLine =
    if entry.hostBlockForm: entry.hostActivitiesLine else: entry.hostEntryLine
  let lastLine = max(entry.hostListEndLine, firstLine)
  let text = prof.lines[firstLine - 1 .. lastLine - 1].join("\n")
  # The list opens at the first `[` after the `:` that ends the key --
  # `"<host>":` (whose name may hold any character) or `activities:`.
  let keyEnd =
    if entry.hostBlockForm: text.find(':')
    else: text.find("\":")
  let openIdx = text.find('[', max(keyEnd, 0))
  let (items, closeIdx) = hostListItems(text, max(openIdx, 0))
  if openIdx < 0 or closeIdx < 0:
    raiseUnstructured(profilePath, firstLine, 1,
      "the activity list of hosts entry \"" & host & "\"",
      "a `[activity, ...]` list")
  let edited =
    if enable:
      enableInList(text, openIdx, items, closeIdx, activity)
    else:
      var k = -1
      for i, it in items:
        if it.name == activity:
          k = i
          break
      disableInList(text, openIdx, items, k)
  replaceLineSpan(prof, firstLine, lastLine, edited.split("\n"))
  writeProfile(prof)
  true

# ---------------------------------------------------------------------------
# setResource (M78).
# ---------------------------------------------------------------------------
#
# Formatting-preserving insert/update of a `resources:` entry, exactly
# parallel to `setConfigurable`'s find-or-create-block / find-or-create-
# entry / add-or-update-attribute structure. New entries are appended at
# the end of the `resources:` block; attributes are appended at the end
# of the entry in insertion order, and an existing key is updated in
# place. The editor writes resource entries at the profile top level
# (not nested under a `when`/`if`); a predicate-guarded resource is
# hand-authored, and an edit naming an address declared only under a
# guard is refused (`EGuardedTarget`) rather than duplicated unguarded.

proc createResourcesBlock(p: Profile): IntentNode =
  let parentIndent = p.root.indent + p.indentStep
  let header = indentStr(parentIndent) & "resources:"
  let insertAt = p.root.endLine
  insertLine(p, insertAt, header)
  result = IntentNode(kind: nkResourcesBlock,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: parentIndent, resourcesHeaderLine: insertAt + 1,
    resourcesEntries: @[])
  p.root.children.add result
  if p.root.endLine < insertAt + 1:
    p.root.endLine = insertAt + 1

proc createResourceEntry(p: Profile; resBlk: IntentNode;
                         kind, address: string): IntentNode =
  let parentIndent = resBlk.indent + p.indentStep
  let header = indentStr(parentIndent) & kind & " " & address & ":"
  let insertAt = insertionIndex(p, resBlk, resBlk.resourcesHeaderLine)
  insertLine(p, insertAt, header)
  result = IntentNode(kind: nkResourceEntry,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: parentIndent, resourceKind: kind, resourceAddress: address,
    resourceHeaderLine: insertAt + 1, resourceAttrs: @[])
  resBlk.resourcesEntries.add result
  if resBlk.endLine < insertAt + 1:
    resBlk.endLine = insertAt + 1
  if p.root.endLine < insertAt + 1:
    p.root.endLine = insertAt + 1

proc findResourceEntry(resBlk: IntentNode; address: string):
    Option[IntentNode] =
  ## The unguarded `<kind> <address>:` entry directly inside `resources:`.
  for ch in resBlk.resourcesEntries:
    if ch.kind == nkResourceEntry and ch.resourceAddress == address:
      return some(ch)
  none(IntentNode)

proc guardedResourceSites(p: Profile; nodes: seq[IntentNode];
                          address: string; inGuard: bool;
                          into: var seq[string]) =
  ## `file:line` of every declaration of `address` inside a guard chain.
  for node in nodes:
    case node.kind
    of nkResourceEntry:
      if inGuard and node.resourceAddress == address:
        into.add p.path & ":" & $node.resourceHeaderLine
    of nkCondBlock:
      guardedResourceSites(p, node.condChildren, address, true, into)
    else: discard

proc findResourceAttr(entry: IntentNode; key: string): int =
  for i, ch in entry.resourceAttrs:
    if ch.kind == nkResourceAttr and ch.resourceAttrKey == key:
      return i
  -1

proc setResource*(profilePath, kind, address, attrKey: string;
                  value: string) =
  ## Write or update `<attrKey> = <value>` inside the `resources:`
  ## entry identified by `<kind> <address>:`. Creates the `resources:`
  ## block and the `<kind> <address>:` entry on demand. `value` is
  ## quoted as a string literal unless it is already a bool / numeric
  ## literal (same rule as `setConfigurable`).
  let prof = loadProfile(profilePath)
  var resBlk: IntentNode
  let resOpt = findResourcesBlock(prof)
  if resOpt.isSome:
    resBlk = resOpt.get
  else:
    resBlk = createResourcesBlock(prof)
  var entry: IntentNode
  let entryOpt = findResourceEntry(resBlk, address)
  if entryOpt.isSome:
    entry = entryOpt.get
  else:
    # A resource declared only under a guard is not this edit's target:
    # adding an unguarded entry would duplicate its address on every host
    # the guard selects, and editing the guarded one would edit only some
    # hosts' resource. Refuse; guarded resources are hand-authored.
    var sites: seq[string]
    guardedResourceSites(prof, resBlk.resourcesEntries, address, false,
      sites)
    if sites.len > 0:
      raiseGuardedTarget(profilePath, address,
        "the resource is declared only under a `when <pred>:` guard; " &
        "edit it in the profile by hand", sites)
    entry = createResourceEntry(prof, resBlk, kind, address)
  let attrIndent = entry.indent + prof.indentStep
  let rhs = renderConfigValue(value)
  let newLine = indentStr(attrIndent) & attrKey & " = " & rhs
  let existingIdx = findResourceAttr(entry, attrKey)
  if existingIdx >= 0:
    let attr = entry.resourceAttrs[existingIdx]
    prof.lines[attr.resourceAttrLine - 1] = newLine
    attr.resourceAttrValueSource = rhs
  else:
    let insertAt = insertionIndex(prof, entry, entry.resourceHeaderLine)
    insertLine(prof, insertAt, newLine)
    let attrNode = IntentNode(kind: nkResourceAttr,
      startLine: insertAt + 1, endLine: insertAt + 1, indent: attrIndent,
      resourceAttrKey: attrKey, resourceAttrValueSource: rhs,
      resourceAttrLine: insertAt + 1)
    entry.resourceAttrs.add attrNode
    if entry.endLine < insertAt + 1:
      entry.endLine = insertAt + 1
    if resBlk.endLine < insertAt + 1:
      resBlk.endLine = insertAt + 1
    if prof.root.endLine < insertAt + 1:
      prof.root.endLine = insertAt + 1
  writeProfile(prof)
