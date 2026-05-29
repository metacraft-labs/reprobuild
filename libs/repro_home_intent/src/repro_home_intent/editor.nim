## Structural, formatting-preserving editor for `home.nim`.
##
## Public surface:
##
##   addPackageReference(profilePath, package, activity = "default",
##                       predicate = "", predicateKeyword = ckWhen)
##   removePackageReference(profilePath, package, activity = "default",
##                          predicate = "")
##   setConfigurable(profilePath, packageDotConfigurable, value,
##                   configurableLookup)
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

import std/[options, os, strutils]
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
    of nkResourcesBlock:
      if node.resourcesHeaderLine >= from1: inc node.resourcesHeaderLine
      for ch in node.resourcesEntries: shift(ch, from1)
    of nkResourceEntry:
      if node.resourceHeaderLine >= from1: inc node.resourceHeaderLine
      for ch in node.resourceAttrs: shift(ch, from1)
    of nkResourceAttr:
      if node.resourceAttrLine >= from1: inc node.resourceAttrLine
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
    of nkResourcesBlock:
      if node.resourcesHeaderLine > from1: dec node.resourcesHeaderLine
      for ch in node.resourcesEntries: shift(ch, from1)
    of nkResourceEntry:
      if node.resourceHeaderLine > from1: dec node.resourceHeaderLine
      for ch in node.resourceAttrs: shift(ch, from1)
    of nkResourceAttr:
      if node.resourceAttrLine > from1: dec node.resourceAttrLine
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
  ## or -1.
  for i, ch in blocks:
    if ch.kind == nkPackageRef and ch.packageName == pkg:
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
  let insertAt = insertionIndex(p, parent, parentHeaderLine)
  insertLine(p, insertAt, header)
  result = IntentNode(kind: nkCondBlock,
    startLine: insertAt + 1, endLine: insertAt + 1,
    indent: parentBodyIndent, keyword: keyword,
    predicateSource: canon,
    predicateAst: predAst, canonicalPredicate: canon,
    condHeaderLine: insertAt + 1, condChildren: @[])
  case parent.kind
  of nkActivity:
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

proc renderPackageRefSpelling(p: Profile; pkg: string): string =
  ## M83 Phase F3: emit a hyphenated package name with backticks
  ## (`` `pkg-x` ``) so the resulting line is also a valid Phase A
  ## macro-form identifier — but ONLY when the profile is Phase-A
  ## shaped (detected via the `import repro_profile` macro-library
  ## import). Legacy text-form profiles keep the bare spelling so the
  ## structural editor's round-trip stays byte-identical against the
  ## existing home-intent test fixtures.
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
    if line.strip() == "discard":
      deleteLine(p, idx)
      return
    inc idx

proc addPackageRefInBlock(p: Profile; blk: IntentNode; pkg: string) =
  ## Append `pkg` as the last child of `blk` (`nkActivity` or
  ## `nkCondBlock`), preserving any trailing blank/comment lines.
  stripBodyDiscardPlaceholder(p, blk)
  let bodyIndent = blk.indent + p.indentStep
  let line = indentStr(bodyIndent) & renderPackageRefSpelling(p, pkg)
  let header = headerLineOf(blk)
  let insertAt = insertionIndex(p, blk, header)
  insertLine(p, insertAt, line)
  let newNode = IntentNode(kind: nkPackageRef,
    startLine: insertAt + 1, endLine: insertAt + 1, indent: bodyIndent,
    packageName: pkg, packageLine: insertAt + 1)
  case blk.kind
  of nkActivity:
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
                          predicateKeyword = ckWhen) =
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
  let prof = loadProfile(profilePath)
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
  addPackageRefInBlock(prof, targetBlock, package)
  writeProfile(prof)

proc removePackageRefFromBlock(p: Profile; blk: IntentNode;
                              pkg: string): bool =
  ## Remove the first matching package reference from `blk`. Returns
  ## true on success.
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
  let idx = findPackageRef(children, pkg)
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
                             predicate = "") =
  ## Remove the first occurrence of `package` from the targeted scope.
  ## If the removal would leave an activity body empty, the activity
  ## block stays (avoids noisy churn — per the spec's reasoning that
  ## the user's intent is to remove the package, not the activity).
  let prof = loadProfile(profilePath)
  let activityOpt = findActivity(prof, activity)
  if activityOpt.isNone:
    return # nothing to remove
  let activityNode = activityOpt.get
  if predicate.len == 0:
    discard removePackageRefFromBlock(prof, activityNode, package)
    writeProfile(prof)
    return
  let predAst = parsePredicate(profilePath, predicate, 0)
  let canon = renderPredicate(normalizeAst(predAst))
  let existingCond = findCondWithCanonical(
    activityNode.activityChildren, canon)
  if existingCond.isNone:
    return
  discard removePackageRefFromBlock(prof, existingCond.get, package)
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
  for ch in cfg.configPackages:
    if ch.configPackageName == pkgName:
      return some(ch)
  none(IntentNode)

proc findConfigEntry(pkg: IntentNode; key: string): int =
  for i, ch in pkg.configEntries:
    if ch.configKey == key:
      return i
  -1

proc setConfigurable*(profilePath: string; packageDotConfigurable: string;
                     value: string;
                     configurableLookup: ConfigurableLookup) =
  ## Write or update `<package>.<configurable> = <value>` inside the
  ## profile's `config:` section. Creates the `config:` block and the
  ## `<package>:` sub-block on demand. Subsequent calls into the same
  ## sub-block append the new entry in insertion order.
  ##
  ## `configurableLookup(package, configurable)` is the seam by which
  ## the caller (CLI / apply pipeline) injects knowledge of which
  ## configurables a package declares. If the lookup returns false,
  ## `EUnknownConfigurable` is raised. Passing `nil` opts out of the
  ## check (the apply pipeline does its own resolution).
  let (pkgName, keyName) = splitPkgDotKey(packageDotConfigurable)
  if configurableLookup != nil and not configurableLookup(pkgName, keyName):
    raiseUnknownConfigurable(profilePath, pkgName, keyName)
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
  let entryIndent = pkg.indent + prof.indentStep
  let rhs = renderConfigValue(value)
  let newLine = indentStr(entryIndent) & keyName & " = " & rhs
  let existingIdx = findConfigEntry(pkg, keyName)
  if existingIdx >= 0:
    # Update in place. Preserve the line index.
    let entry = pkg.configEntries[existingIdx]
    prof.lines[entry.configEntryLine - 1] = newLine
    entry.configValueSource = rhs
  else:
    let insertAt = insertionIndex(prof, pkg, pkg.configPackageHeaderLine)
    insertLine(prof, insertAt, newLine)
    let entryNode = IntentNode(kind: nkConfigEntry,
      startLine: insertAt + 1, endLine: insertAt + 1, indent: entryIndent,
      configKey: keyName, configValueSource: rhs,
      configEntryLine: insertAt + 1)
    pkg.configEntries.add entryNode
    if pkg.endLine < insertAt + 1:
      pkg.endLine = insertAt + 1
    if cfg.endLine < insertAt + 1:
      cfg.endLine = insertAt + 1
    if prof.root.endLine < insertAt + 1:
      prof.root.endLine = insertAt + 1
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

proc setHostActivities*(profilePath, host: string;
                       activities: seq[string]) =
  ## Create or update the `hosts:` entry for `host`. Writes
  ## `"<host>": [<activity>, ...]` in the canonical form.
  ## `default` is always implicitly active, so the activities list
  ## does NOT need to include it (and SHOULD NOT — `repro home enable`
  ## refuses to put `default` in a hosts entry per spec). We don't
  ## enforce that here; the CLI does.
  let prof = loadProfile(profilePath)
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
  if existingIdx >= 0:
    let entry = hostsBlk.hostsEntries[existingIdx]
    prof.lines[entry.hostEntryLine - 1] = line
    entry.hostActivities = activities
  else:
    let insertAt = insertionIndex(prof, hostsBlk, hostsBlk.hostsHeaderLine)
    insertLine(prof, insertAt, line)
    let entry = IntentNode(kind: nkHostsEntry,
      startLine: insertAt + 1, endLine: insertAt + 1, indent: entryIndent,
      hostName: host, hostActivities: activities,
      hostEntryLine: insertAt + 1)
    hostsBlk.hostsEntries.add entry
    if hostsBlk.endLine < insertAt + 1:
      hostsBlk.endLine = insertAt + 1
    if prof.root.endLine < insertAt + 1:
      prof.root.endLine = insertAt + 1
  writeProfile(prof)

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
# hand-authored.

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
  for ch in resBlk.resourcesEntries:
    if ch.kind == nkResourceEntry and ch.resourceAddress == address:
      return some(ch)
  none(IntentNode)

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
