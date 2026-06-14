## B1: surface parser for the ReproOS system-scope configuration DSL.
##
## The DSL surface is the Nim-ish block syntax shown in the campaign
## spec's B1 example (`ReproOS-Generations-And-Foreign-Packages.milestones.org`).
## A typical file looks like:
##
## .. code-block:: nim
##
##   system reproosConfig:
##     imports:
##       "./modules/users.nim"
##
##     kernel = reproosKernel
##     kernel_cmdline = [
##       "console=ttyS0,115200n8",
##       "init=/sbin/init",
##       "rw",
##     ]
##
##     packages = [
##       coreutils,
##       bash,
##       package(apt, "git", snapshot = "debian/bookworm/20260601T000000Z"),
##     ]
##
##     users:
##       user "root":
##         shell = bash
##         password_hash = "$y$j9T$..."
##
##     services:
##       enable "systemd-networkd.service"
##       disable "systemd-resolved.service"
##
##     mounts:
##       mount "/", source = "LABEL=reproos-root", fstype = "ext4"
##
## The parser is intentionally NOT a general Nim parser. It walks the
## source line by line, recognizing exactly the block forms above plus
## their leaf grammars (`=` for kernel/cmdline/packages,
## `user "<name>":` headers, `enable <"unit">` / `disable <"unit">` /
## `mask <"unit">` verbs, `mount "<point>", k = v, ...` mount lines).
## Anything else is rejected with `EUnstructured` and a precise
## `file:line:col + saw/expected` pair. This mirrors the home-profile
## intent layer (`libs/repro_home_intent`) and lets the parse stage
## be exercised from unit tests without standing up the Nim VM.
##
## Composition (the B1 P4 deliverable) is handled here: `imports:`
## paths are resolved at parse time relative to the importing file's
## directory and merged into the parent with last-write-wins semantics
## (the parent overrides the imported module). Cycles are rejected
## with `ECircularImport`.

import std/[options, os, strutils, tables]
from repro_core/paths import extendedPath

import ./errors
import ./types

const
  IndentStepDefault = 2
  ## B1 surface uses two-space indentation by convention; the parser
  ## auto-detects narrower/wider step at the `system` header (matching
  ## the home-intent layer's behavior).

# ---------------------------------------------------------------------------
# Source-text scanning helpers (kept private; mirror home-intent).
# ---------------------------------------------------------------------------

proc countLeadingSpaces(s: string): int =
  result = 0
  while result < s.len and s[result] == ' ':
    inc result

proc isBlankOrComment(s: string): bool =
  let t = s.strip()
  t.len == 0 or t.startsWith("#")

proc trimTrailing(s: string): string =
  result = s
  while result.len > 0 and result[^1] in {' ', '\t', '\r'}:
    result.setLen(result.len - 1)

proc stripInlineComment(s: string): string =
  ## Strip `# ...` comments. We only do this for header-style lines;
  ## value lines may carry literal `#` inside string literals.
  var inStr = false
  for i, c in s:
    if c == '"' and (i == 0 or s[i-1] != '\\'):
      inStr = not inStr
    elif c == '#' and not inStr:
      return s[0 ..< i]
  s

proc splitLines2(src: string): tuple[lines: seq[string]; ending: string;
                                     trailingNewline: bool] =
  let ending = if src.find("\r\n") >= 0: "\r\n" else: "\n"
  var lines = src.split(ending)
  let trailing = lines.len > 0 and lines[^1].len == 0
  if trailing:
    lines.setLen(lines.len - 1)
  (lines, ending, trailing)

# ---------------------------------------------------------------------------
# Header matcher.
# ---------------------------------------------------------------------------

type
  HeaderMatch = object
    matched: bool
    keyword: string
    rest: string                ## text between the keyword and the
                                ## trailing `:`
    indent: int

proc matchHeader(line, expectedKeyword: string): HeaderMatch =
  let trimmed = stripInlineComment(line).trimTrailing()
  let indent = countLeadingSpaces(trimmed)
  if indent > trimmed.len:
    return HeaderMatch(matched: false)
  let body = trimmed[indent .. ^1]
  if not body.endsWith(":"):
    return HeaderMatch(matched: false)
  let inner = body[0 ..< body.len - 1]
  if inner == expectedKeyword:
    return HeaderMatch(matched: true, keyword: expectedKeyword,
      rest: "", indent: indent)
  if inner.startsWith(expectedKeyword) and inner.len > expectedKeyword.len and
     inner[expectedKeyword.len] in {' ', '\t'}:
    return HeaderMatch(matched: true, keyword: expectedKeyword,
      rest: inner[expectedKeyword.len + 1 .. ^1].strip(), indent: indent)
  HeaderMatch(matched: false)

# ---------------------------------------------------------------------------
# Block range helpers.
# ---------------------------------------------------------------------------

proc lastChildLine(lines: seq[string]; startIdx, childIndent: int): int =
  ## 0-based index of the last line still inside an indented block.
  var endIdx = startIdx - 1
  for i in startIdx .. lines.high:
    if isBlankOrComment(lines[i]):
      endIdx = i
      continue
    if countLeadingSpaces(lines[i]) < childIndent:
      break
    endIdx = i
  while endIdx >= startIdx and isBlankOrComment(lines[endIdx]):
    dec endIdx
  endIdx

# ---------------------------------------------------------------------------
# Right-hand-side scanners.
# ---------------------------------------------------------------------------

proc parseQuotedString(configPath: string; line: int; column: int;
                       src: string; start: int;
                       outVal: var string): int =
  ## Parse a `"..."` literal starting at `src[start]`. Returns the index
  ## of the character immediately past the closing quote. Raises
  ## `EUnstructured` on malformed input. Supports `\\"` and `\\\\` escapes;
  ## everything else passes through verbatim (the B1 surface does not
  ## need C-style `\\n` / `\\t`).
  if start >= src.len or src[start] != '"':
    raiseUnstructured(configPath, line, column,
      "non-quoted value", "a `\"...\"` string literal")
  var i = start + 1
  var buf = newStringOfCap(32)
  while i < src.len:
    let c = src[i]
    if c == '\\' and i + 1 < src.len:
      let nxt = src[i+1]
      case nxt
      of '"': buf.add '"'
      of '\\': buf.add '\\'
      else:
        buf.add '\\'
        buf.add nxt
      i += 2
    elif c == '"':
      outVal = buf
      return i + 1
    else:
      buf.add c
      inc i
  raiseUnstructured(configPath, line, column,
    "unterminated string", "a closing `\"`")

proc skipWs(s: string; i: int): int =
  result = i
  while result < s.len and s[result] in {' ', '\t'}:
    inc result

proc parseIdentifier(configPath: string; line, column: int;
                     s: string; start: int;
                     outId: var string): int =
  ## Parse `[A-Za-z_][A-Za-z0-9_]*`. Returns index past the end.
  var i = start
  if i >= s.len or not (s[i] in {'A'..'Z', 'a'..'z', '_'}):
    raiseUnstructured(configPath, line, column,
      "non-identifier value", "an identifier")
  while i < s.len and s[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
    inc i
  outId = s[start ..< i]
  i

# ---------------------------------------------------------------------------
# Element-list parsing (for `kernel_cmdline = [...]` and `packages = [...]`).
# ---------------------------------------------------------------------------

proc collectListElements(configPath: string; lines: seq[string];
                         startLine: int; rhs: string;
                         outElements: var seq[tuple[text: string; line: int]]) =
  ## Collect element source-text strings from a `[ ... ]` list. The
  ## list may span multiple lines; trailing commas + comments are
  ## tolerated. Returns one entry per element with its source line.
  var buf = ""
  var lineNumber = startLine
  buf.add rhs
  if not buf.contains(']'):
    var i = startLine
    while i < lines.len and not buf.contains(']'):
      let ln = lines[i]
      buf.add ' '
      buf.add ln.stripInlineComment().trimTrailing()
      inc i
      lineNumber = i
  let lbIdx = buf.find('[')
  if lbIdx < 0:
    raiseUnstructured(configPath, startLine, 1,
      "value '" & rhs & "'", "a `[...]` list")
  let rbIdx = buf.rfind(']')
  if rbIdx < lbIdx:
    raiseUnstructured(configPath, startLine, 1,
      "unterminated list", "a closing `]`")
  let inside = buf[lbIdx + 1 ..< rbIdx]
  # Split top-level commas (depth-aware).
  var depth = 0
  var cur = ""
  var inStr = false
  var elems: seq[string]
  for i, c in inside:
    if c == '"' and (i == 0 or inside[i-1] != '\\'):
      inStr = not inStr
      cur.add c
    elif inStr:
      cur.add c
    elif c == '(' or c == '[':
      inc depth
      cur.add c
    elif c == ')' or c == ']':
      dec depth
      cur.add c
    elif c == ',' and depth == 0:
      let t = cur.strip()
      if t.len > 0:
        elems.add t
      cur = ""
    else:
      cur.add c
  let tail = cur.strip()
  if tail.len > 0:
    elems.add tail
  for e in elems:
    outElements.add (text: e, line: lineNumber)

# ---------------------------------------------------------------------------
# `package(...)` call form.
# ---------------------------------------------------------------------------

proc parsePackageCall(configPath: string; line: int; raw: string;
                      outRef: var PackageRef) =
  ## Parse one of:
  ##   * `package(<distro>, "<name>", snapshot = "<pin>")` — Tier 3
  ##   * `package("<name>")` — Tier 2
  ## The caller has already stripped the surrounding whitespace.
  if not raw.startsWith("package("):
    raiseUnstructured(configPath, line, 1,
      "'" & raw & "'", "a `package(...)` call")
  if not raw.endsWith(")"):
    raiseUnstructured(configPath, line, 1,
      "'" & raw & "'", "a closing `)`")
  let inner = raw["package(".len ..< raw.len - 1]
  # Split top-level commas (depth-aware).
  var depth = 0
  var cur = ""
  var inStr = false
  var parts: seq[string]
  for i, c in inner:
    if c == '"' and (i == 0 or inner[i-1] != '\\'):
      inStr = not inStr
      cur.add c
    elif inStr:
      cur.add c
    elif c == '(' or c == '[':
      inc depth
      cur.add c
    elif c == ')' or c == ']':
      dec depth
      cur.add c
    elif c == ',' and depth == 0:
      parts.add cur.strip()
      cur = ""
    else:
      cur.add c
  parts.add cur.strip()
  if parts.len == 1:
    # Tier 2: `package("<name>")`
    var name = ""
    discard parseQuotedString(configPath, line, 1, parts[0], 0, name)
    outRef = PackageRef(tier: ptStandaloneBinary, name: name,
      sourceFile: configPath, sourceLine: line)
    return
  if parts.len < 2:
    raiseUnstructured(configPath, line, 1,
      "'" & raw & "'",
      "`package(<distro>, \"<name>\", snapshot = \"<pin>\")`")
  let distro = parts[0]
  if distro notin KnownForeignDistros:
    raiseUnknownForeignDistro(configPath, distro, line)
  var name = ""
  discard parseQuotedString(configPath, line, 1, parts[1], 0, name)
  var snapshot = ""
  for p in parts[2 .. ^1]:
    let eqIdx = p.find('=')
    if eqIdx < 0:
      raiseUnstructured(configPath, line, 1,
        "'" & p & "'", "`snapshot = \"<pin>\"`")
    let key = p[0 ..< eqIdx].strip()
    let val = p[eqIdx + 1 .. ^1].strip()
    case key
    of "snapshot":
      discard parseQuotedString(configPath, line, 1, val, 0, snapshot)
    else:
      raiseUnstructured(configPath, line, 1,
        "'" & key & "'",
        "`snapshot = \"<pin>\"` (no other named args recognized)")
  if snapshot.len == 0:
    raiseMissingRequiredField(configPath, "package", name, "snapshot", line)
  # Snapshot shape: must contain at least two `/` separators
  # (`<distro>/<release>/<rfc3339-compact>`).
  let segs = snapshot.split('/')
  if segs.len < 3:
    raiseMalformedSnapshot(configPath, snapshot, line)
  for s in segs:
    if s.len == 0:
      raiseMalformedSnapshot(configPath, snapshot, line)
  outRef = PackageRef(tier: ptForeignBundle, name: name,
    distro: distro, snapshot: snapshot,
    sourceFile: configPath, sourceLine: line)

# ---------------------------------------------------------------------------
# `mount "<point>", source = "...", fstype = "...", options = "..."`
# ---------------------------------------------------------------------------

proc parseMountLine(configPath: string; line: int; raw: string;
                    outEntry: var MountEntry) =
  if not raw.startsWith("mount "):
    raiseUnstructured(configPath, line, 1,
      "'" & raw & "'", "a `mount \"<point>\", ...` line")
  let rest = raw["mount ".len .. ^1].strip()
  # Top-level comma split honoring "..." literals.
  var depth = 0
  var cur = ""
  var inStr = false
  var parts: seq[string]
  for i, c in rest:
    if c == '"' and (i == 0 or rest[i-1] != '\\'):
      inStr = not inStr
      cur.add c
    elif inStr:
      cur.add c
    elif c == '(' or c == '[':
      inc depth
      cur.add c
    elif c == ')' or c == ']':
      dec depth
      cur.add c
    elif c == ',' and depth == 0:
      parts.add cur.strip()
      cur = ""
    else:
      cur.add c
  parts.add cur.strip()
  if parts.len < 1:
    raiseUnstructured(configPath, line, 1,
      "'" & raw & "'", "`mount \"<point>\", source = \"...\", fstype = \"...\"`")
  var mountPoint = ""
  discard parseQuotedString(configPath, line, 1, parts[0], 0, mountPoint)
  var source = ""
  var fstype = ""
  var options: seq[string]
  var dump = 0
  var pass = 0
  for p in parts[1 .. ^1]:
    let eqIdx = p.find('=')
    if eqIdx < 0:
      raiseUnstructured(configPath, line, 1,
        "'" & p & "'", "`<key> = <value>`")
    let key = p[0 ..< eqIdx].strip()
    let val = p[eqIdx + 1 .. ^1].strip()
    case key
    of "source":
      discard parseQuotedString(configPath, line, 1, val, 0, source)
    of "fstype":
      discard parseQuotedString(configPath, line, 1, val, 0, fstype)
    of "options":
      var raw = ""
      discard parseQuotedString(configPath, line, 1, val, 0, raw)
      for opt in raw.split(','):
        let o = opt.strip()
        if o.len > 0:
          options.add o
    of "dump":
      dump = parseInt(val)
    of "pass":
      pass = parseInt(val)
    else:
      raiseUnstructured(configPath, line, 1,
        "'" & key & "'",
        "one of `source`, `fstype`, `options`, `dump`, `pass`")
  if source.len == 0:
    raiseMissingRequiredField(configPath, "mount", mountPoint, "source", line)
  if fstype.len == 0:
    raiseMissingRequiredField(configPath, "mount", mountPoint, "fstype", line)
  if fstype notin KnownFstypes:
    raiseUnknownFstype(configPath, fstype, line)
  outEntry = MountEntry(mountPoint: mountPoint, source: source,
    fstype: fstype, options: options,
    dump: dump, pass: pass,
    sourceFile: configPath, sourceLine: line)

# ---------------------------------------------------------------------------
# Service unit-name validation.
# ---------------------------------------------------------------------------

const KnownSystemdUnitTypes = [
  ".service", ".socket", ".target", ".timer", ".path", ".mount",
  ".automount", ".swap", ".device", ".slice", ".scope"]

proc isValidUnitName(unit: string): bool =
  for suffix in KnownSystemdUnitTypes:
    if unit.endsWith(suffix):
      let stem = unit[0 ..< unit.len - suffix.len]
      if stem.len == 0:
        return false
      # Allow `<name>(@<instance>)?` for template units.
      let atIdx = stem.find('@')
      if atIdx >= 0:
        let head = stem[0 ..< atIdx]
        let tail = stem[atIdx + 1 .. ^1]
        if head.len == 0:
          return false
        # tail may be empty (template form like `getty@.service`).
        return true
      return true
  false

# ---------------------------------------------------------------------------
# `users:` block.
# ---------------------------------------------------------------------------

proc parseUserBlock(configPath: string; lines: seq[string];
                    headerIdx, childIndent: int;
                    outUser: var User): int =
  ## Parse a `user "<name>":` block starting at line `headerIdx`
  ## (0-based). Returns the 0-based index immediately past the block.
  let headerLine = lines[headerIdx].stripInlineComment().trimTrailing()
  let indent = countLeadingSpaces(headerLine)
  let stripped = headerLine[indent .. ^1]
  if not stripped.startsWith("user "):
    raiseUnstructured(configPath, headerIdx + 1, indent + 1,
      "'" & stripped & "'", "`user \"<name>\":`")
  let rest = stripped["user ".len .. ^1].strip()
  if not rest.endsWith(":"):
    raiseUnstructured(configPath, headerIdx + 1, indent + 1,
      "'" & rest & "'", "trailing `:` after the user name")
  let inner = rest[0 ..< rest.len - 1].strip()
  var name = ""
  discard parseQuotedString(configPath, headerIdx + 1, indent + 1,
    inner, 0, name)
  outUser = User(name: name,
    sourceFile: configPath, sourceLine: headerIdx + 1)
  let endIdx = lastChildLine(lines, headerIdx + 1, childIndent)
  var i = headerIdx + 1
  while i <= endIdx:
    let ln = lines[i]
    if isBlankOrComment(ln):
      inc i
      continue
    let ind = countLeadingSpaces(ln)
    if ind < childIndent:
      break
    let body = ln.stripInlineComment().trimTrailing()[ind .. ^1].strip()
    let eqIdx = body.find('=')
    if eqIdx < 0:
      raiseUnstructured(configPath, i + 1, ind + 1,
        "'" & body & "'", "`<key> = <value>`")
    let key = body[0 ..< eqIdx].strip()
    let val = body[eqIdx + 1 .. ^1].strip()
    case key
    of "shell":
      # `shell = bash` references a bare identifier (a package symbol).
      var sid = ""
      discard parseIdentifier(configPath, i + 1, ind + 1, val, 0, sid)
      outUser.shell = sid
    of "password_hash":
      var ph = ""
      discard parseQuotedString(configPath, i + 1, ind + 1, val, 0, ph)
      outUser.passwordHash = ph
    of "groups":
      # `groups = ["wheel", "audio"]` (single-line list only here).
      var elems: seq[tuple[text: string; line: int]]
      collectListElements(configPath, lines, i + 1, val, elems)
      for e in elems:
        var g = ""
        discard parseQuotedString(configPath, e.line, ind + 1, e.text, 0, g)
        outUser.groups.add g
    of "uid":
      outUser.uid = some(parseInt(val))
    of "home_dir":
      var hd = ""
      discard parseQuotedString(configPath, i + 1, ind + 1, val, 0, hd)
      outUser.homeDir = hd
    else:
      raiseUnstructured(configPath, i + 1, ind + 1,
        "'" & key & "'",
        "one of `shell`, `password_hash`, `groups`, `uid`, `home_dir`")
    inc i
  if outUser.shell.len == 0:
    raiseMissingRequiredField(configPath, "user", outUser.name, "shell",
      headerIdx + 1)
  endIdx + 1

# ---------------------------------------------------------------------------
# `services:` block.
# ---------------------------------------------------------------------------

proc parseServicesBlock(configPath: string; lines: seq[string];
                       headerIdx, childIndent: int;
                       outStates: var seq[ServiceState]) =
  let endIdx = lastChildLine(lines, headerIdx + 1, childIndent)
  var i = headerIdx + 1
  while i <= endIdx:
    let ln = lines[i]
    if isBlankOrComment(ln):
      inc i
      continue
    let ind = countLeadingSpaces(ln)
    if ind < childIndent:
      break
    let body = ln.stripInlineComment().trimTrailing()[ind .. ^1].strip()
    var verb = ""
    var endVerb = 0
    while endVerb < body.len and body[endVerb] in {'a'..'z', 'A'..'Z'}:
      inc endVerb
    verb = body[0 ..< endVerb]
    if verb notin KnownServiceVerbs:
      raiseUnstructured(configPath, i + 1, ind + 1,
        "'" & verb & "'",
        "one of `enable`, `disable`, `mask`")
    let rest = body[endVerb .. ^1].strip()
    var unit = ""
    discard parseQuotedString(configPath, i + 1, ind + 1, rest, 0, unit)
    if not isValidUnitName(unit):
      raiseUnknownService(configPath, unit, i + 1)
    let stateKind = case verb
                    of "enable": svsEnabled
                    of "disable": svsDisabled
                    of "mask": svsMasked
                    else: svsEnabled
    outStates.add ServiceState(unit: unit, state: stateKind,
      sourceFile: configPath, sourceLine: i + 1)
    inc i

# ---------------------------------------------------------------------------
# `mounts:` block.
# ---------------------------------------------------------------------------

proc parseMountsBlock(configPath: string; lines: seq[string];
                     headerIdx, childIndent: int;
                     outMounts: var seq[MountEntry]) =
  let endIdx = lastChildLine(lines, headerIdx + 1, childIndent)
  var i = headerIdx + 1
  while i <= endIdx:
    let ln = lines[i]
    if isBlankOrComment(ln):
      inc i
      continue
    let ind = countLeadingSpaces(ln)
    if ind < childIndent:
      break
    let body = ln.stripInlineComment().trimTrailing()[ind .. ^1].strip()
    var entry: MountEntry
    parseMountLine(configPath, i + 1, body, entry)
    outMounts.add entry
    inc i

# ---------------------------------------------------------------------------
# `users:` block (collects user entries).
# ---------------------------------------------------------------------------

proc parseUsersBlock(configPath: string; lines: seq[string];
                    headerIdx, childIndent: int;
                    outUsers: var seq[User]) =
  let endIdx = lastChildLine(lines, headerIdx + 1, childIndent)
  var i = headerIdx + 1
  while i <= endIdx:
    let ln = lines[i]
    if isBlankOrComment(ln):
      inc i
      continue
    let ind = countLeadingSpaces(ln)
    if ind < childIndent:
      break
    let body = ln.stripInlineComment().trimTrailing()[ind .. ^1].strip()
    if not body.startsWith("user "):
      raiseUnstructured(configPath, i + 1, ind + 1,
        "'" & body & "'", "`user \"<name>\":` header")
    var user: User
    let grandchildIndent = ind + IndentStepDefault
    i = parseUserBlock(configPath, lines, i, grandchildIndent, user)
    outUsers.add user

# ---------------------------------------------------------------------------
# `imports:` block.
# ---------------------------------------------------------------------------

proc parseImportsBlock(configPath: string; lines: seq[string];
                      headerIdx, childIndent: int;
                      outImports: var seq[string]) =
  let endIdx = lastChildLine(lines, headerIdx + 1, childIndent)
  var i = headerIdx + 1
  while i <= endIdx:
    let ln = lines[i]
    if isBlankOrComment(ln):
      inc i
      continue
    let ind = countLeadingSpaces(ln)
    if ind < childIndent:
      break
    let body = ln.stripInlineComment().trimTrailing()[ind .. ^1].strip()
    var path = ""
    discard parseQuotedString(configPath, i + 1, ind + 1, body, 0, path)
    outImports.add path
    inc i

# ---------------------------------------------------------------------------
# Top-level `system <name>:` parse.
# ---------------------------------------------------------------------------

proc mergeConfigs(parent, child: SystemConfig) =
  ## Merge `child` (imported module) INTO `parent`. Last-write-wins on
  ## collisions: the parent's existing scalar fields are kept; child
  ## seq entries that don't collide by key are appended. This makes
  ## imports additive for entry-style sections (packages, users,
  ## services, mounts) while letting the parent override scalar
  ## kernel/cmdline fields. Documented in `docs/reproos-config-dsl.md`.
  ##
  ## The merge happens INSIDE the parser before the parent's own
  ## entries are processed, which makes "last write" the parent's
  ## own declarations.
  if parent.kernel.isEmpty and not child.kernel.isEmpty:
    parent.kernel = child.kernel
  if parent.kernelCmdline.isEmpty and not child.kernelCmdline.isEmpty:
    parent.kernelCmdline = child.kernelCmdline
  # For seq sections, append child first; the parent's later
  # declarations will be appended after by the parser, and the
  # downstream lowering pass deduplicates by key with "last entry
  # wins" semantics (`./lower.nim` `deduplicate*` helpers).
  var existingPkgs = initTable[string, bool]()
  for p in parent.packages:
    existingPkgs[p.name] = true
  for p in child.packages:
    if p.name notin existingPkgs:
      parent.packages.add p
      existingPkgs[p.name] = true

  var existingUsers = initTable[string, bool]()
  for u in parent.users:
    existingUsers[u.name] = true
  for u in child.users:
    if u.name notin existingUsers:
      parent.users.add u
      existingUsers[u.name] = true

  var existingSvcs = initTable[string, bool]()
  for s in parent.services:
    existingSvcs[s.unit] = true
  for s in child.services:
    if s.unit notin existingSvcs:
      parent.services.add s
      existingSvcs[s.unit] = true

  var existingMnts = initTable[string, bool]()
  for m in parent.mounts:
    existingMnts[m.mountPoint] = true
  for m in child.mounts:
    if m.mountPoint notin existingMnts:
      parent.mounts.add m
      existingMnts[m.mountPoint] = true

proc parseSystemConfigFile*(configPath: string;
                            importStack: var seq[string]): SystemConfig

proc parseSystemBody(configPath: string; lines: seq[string];
                    systemIdx, childIndent: int;
                    cfg: SystemConfig;
                    importStack: var seq[string]) =
  let endIdx = lastChildLine(lines, systemIdx + 1, childIndent)
  var i = systemIdx + 1
  while i <= endIdx:
    let ln = lines[i]
    if isBlankOrComment(ln):
      inc i
      continue
    let ind = countLeadingSpaces(ln)
    if ind < childIndent:
      break
    let body = ln.stripInlineComment().trimTrailing()[ind .. ^1].strip()

    let mImports = matchHeader(ln, "imports")
    if mImports.matched and mImports.indent == childIndent:
      var imports: seq[string]
      let grand = ind + IndentStepDefault
      parseImportsBlock(configPath, lines, i, grand, imports)
      # Resolve each import + parse + merge.
      let baseDir = configPath.splitFile.dir
      for imp in imports:
        cfg.imports.add imp
        let resolved = if isAbsolute(imp): imp else: baseDir / imp
        let absResolved = absolutePath(resolved)
        if absResolved in importStack:
          var cycle = importStack
          cycle.add absResolved
          raiseCircularImport(configPath, cycle)
        if not fileExists(extendedPath(absResolved)):
          raiseImportNotFound(configPath, imp, absResolved)
        let child = parseSystemConfigFile(absResolved, importStack)
        mergeConfigs(cfg, child)
      # Advance past the imports block.
      i = lastChildLine(lines, i + 1, ind + IndentStepDefault) + 1
      continue

    let mUsers = matchHeader(ln, "users")
    if mUsers.matched and mUsers.indent == childIndent:
      let grand = ind + IndentStepDefault
      var users: seq[User]
      parseUsersBlock(configPath, lines, i, grand, users)
      for u in users:
        var found = false
        for j, eu in cfg.users:
          if eu.name == u.name:
            cfg.users[j] = u
            found = true
            break
        if not found:
          cfg.users.add u
      i = lastChildLine(lines, i + 1, ind + IndentStepDefault) + 1
      continue

    let mServices = matchHeader(ln, "services")
    if mServices.matched and mServices.indent == childIndent:
      let grand = ind + IndentStepDefault
      var states: seq[ServiceState]
      parseServicesBlock(configPath, lines, i, grand, states)
      for s in states:
        var found = false
        for j, es in cfg.services:
          if es.unit == s.unit:
            cfg.services[j] = s
            found = true
            break
        if not found:
          cfg.services.add s
      i = lastChildLine(lines, i + 1, ind + IndentStepDefault) + 1
      continue

    let mMounts = matchHeader(ln, "mounts")
    if mMounts.matched and mMounts.indent == childIndent:
      let grand = ind + IndentStepDefault
      var mounts: seq[MountEntry]
      parseMountsBlock(configPath, lines, i, grand, mounts)
      for m in mounts:
        var found = false
        for j, em in cfg.mounts:
          if em.mountPoint == m.mountPoint:
            cfg.mounts[j] = m
            found = true
            break
        if not found:
          cfg.mounts.add m
      i = lastChildLine(lines, i + 1, ind + IndentStepDefault) + 1
      continue

    # Scalar assignment: `kernel = ...`, `kernel_cmdline = [...]`,
    # `packages = [...]`.
    let eqIdx = body.find('=')
    if eqIdx < 0:
      raiseUnstructured(configPath, i + 1, ind + 1,
        "'" & body & "'",
        "`<key> = <value>` or one of `imports:`, `users:`, `services:`, `mounts:`")
    let key = body[0 ..< eqIdx].strip()
    let val = body[eqIdx + 1 .. ^1].strip()
    case key
    of "kernel":
      var kid = ""
      discard parseIdentifier(configPath, i + 1, ind + 1, val, 0, kid)
      cfg.kernel = KernelRef(name: kid,
        sourceFile: configPath, sourceLine: i + 1)
      inc i
    of "kernel_cmdline":
      var elems: seq[tuple[text: string; line: int]]
      collectListElements(configPath, lines, i + 1, val, elems)
      var parts: seq[string]
      for e in elems:
        var s = ""
        discard parseQuotedString(configPath, e.line, ind + 1, e.text, 0, s)
        parts.add s
      cfg.kernelCmdline = KernelCmdline(parts: parts,
        sourceFile: configPath, sourceLine: i + 1)
      # Advance past the (possibly multi-line) list.
      if val.contains(']'):
        inc i
      else:
        var j = i + 1
        while j < lines.len and not lines[j].contains(']'):
          inc j
        i = j + 1
    of "packages":
      var elems: seq[tuple[text: string; line: int]]
      collectListElements(configPath, lines, i + 1, val, elems)
      for e in elems:
        let t = e.text
        if t.startsWith("package("):
          var pr: PackageRef
          parsePackageCall(configPath, e.line, t, pr)
          cfg.packages.add pr
        else:
          # Bare identifier => Tier 1 (`coreutils`).
          var id = ""
          discard parseIdentifier(configPath, e.line, ind + 1, t, 0, id)
          cfg.packages.add PackageRef(tier: ptFromSource, name: id,
            sourceFile: configPath, sourceLine: e.line)
      if val.contains(']'):
        inc i
      else:
        var j = i + 1
        while j < lines.len and not lines[j].contains(']'):
          inc j
        i = j + 1
    else:
      raiseUnstructured(configPath, i + 1, ind + 1,
        "'" & key & "'",
        "one of `kernel`, `kernel_cmdline`, `packages`")

proc parseSystemConfigSource*(configPath, source: string;
                              importStack: var seq[string]): SystemConfig =
  ## Parse `source` (the raw bytes of `configPath`) into a `SystemConfig`.
  ## Diagnostics carry `configPath` even though the bytes were supplied
  ## by the caller (this lets the test suite feed in-memory fixtures).
  let (lines, _, _) = splitLines2(source)
  # Top-level: tolerate `import`, `from`, `include`, blank, comment;
  # then expect the unique `system <name>:` header.
  var systemIdx = -1
  for i, ln in lines:
    if isBlankOrComment(ln): continue
    let m = matchHeader(ln, "system")
    if m.matched:
      if systemIdx >= 0:
        raiseUnstructured(configPath, i + 1, m.indent + 1,
          "a second `system " & m.rest & ":` header",
          "exactly one `system <name>:` block per file")
      systemIdx = i
    else:
      if systemIdx < 0:
        let s = ln.strip()
        if s.startsWith("import ") or s == "import" or
           s.startsWith("from ") or s.startsWith("include "):
          continue
        raiseUnstructured(configPath, i + 1, countLeadingSpaces(ln) + 1,
          "'" & s & "'",
          "`import` or the unique `system <name>:` block header")
  if systemIdx < 0:
    raiseUnstructured(configPath, 1, 1,
      "no `system <name>:` header",
      "a top-level `system <name>:` block")
  let header = matchHeader(lines[systemIdx], "system")
  let name = header.rest
  if name.len == 0:
    raiseUnstructured(configPath, systemIdx + 1, header.indent + 1,
      "anonymous `system:`",
      "`system <name>:` with a non-empty identifier")
  let cfg = initSystemConfig(name)
  cfg.sourceFile = configPath
  let childIndent = header.indent + IndentStepDefault
  parseSystemBody(configPath, lines, systemIdx, childIndent,
    cfg, importStack)
  cfg

proc parseSystemConfigFile*(configPath: string;
                            importStack: var seq[string]): SystemConfig =
  let absPath = absolutePath(configPath)
  importStack.add absPath
  defer:
    discard importStack.pop()
  if not fileExists(extendedPath(absPath)):
    var e = newException(ENoConfig,
      "no configuration.nim at '" & absPath & "'")
    e.configPath = absPath
    e.expectedPath = absPath
    raise e
  let source = readFile(extendedPath(absPath))
  parseSystemConfigSource(absPath, source, importStack)

proc parseSystemConfigFile*(configPath: string): SystemConfig =
  ## Convenience overload for callers that don't need to track the
  ## import stack across multiple top-level parses.
  var stack: seq[string]
  parseSystemConfigFile(configPath, stack)

proc parseSystemConfigSource*(configPath, source: string): SystemConfig =
  var stack: seq[string]
  stack.add absolutePath(configPath)
  parseSystemConfigSource(configPath, source, stack)
