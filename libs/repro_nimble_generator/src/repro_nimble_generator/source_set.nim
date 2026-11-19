## The source set of a Nimble index repository: `nimble-sources.toml`.
##
## A source set says what one index is generated from: the registry, read at
## a pinned commit, optional roots that restrict the index to their closure,
## sources the registry does not list, per-package overrides, and the
## generation policy. It is read as a CLOSED subset of TOML, the discipline
## `repro-catalogs.toml` is read with: UTF-8, comments, blank lines, the
## top-level `schema`, the tables `[[registry]]`, `[[root]]`, `[[extra]]`,
## `[[override]]`, `[[mirror]]` and `[policy]`, and `key = value` lines whose value is a
## basic "string", a non-negative decimal integer, or a one-line array of
## basic strings. An unknown key, a duplicate key, a table outside that list
## or any other construct is a refusal that names its line; every refusal is
## collected, not only the first.
##
## Nothing here touches a file, a process or the network: the reader takes
## the text and a name for diagnostics.
##
## The source set's identity (`sourceSetIdentity`) is a hash of its parsed,
## canonically ordered content, not of its bytes: the order of the tables,
## comments and spacing are not inputs of a generation, so two operators
## whose files differ only in those generate the same root. The mirrors are
## not in it either: they say where the sources are kept, not what they are.

import std/[algorithm, sets, strutils]
from std/unicode import validateUtf8

import blake3

import repro_domain_types/nimble_index/types

const
  SourceSetSchemaV1* = "reprobuild.nimble-source-set.v1"
  SourceSetFileName* = "nimble-sources.toml"
  SourceSetIdentityDomain = "reprobuild.nimble-source-set.identity.v1"
  MaxCooldownDays* = 3650

type
  UnlistedPolicy* = enum
    upRefuse = "refuse"
    upAllow = "allow"

  ProbePolicy* = enum
    ppOff = "off"
    ppSandboxed = "sandboxed"

  RegistrySource* = object
    remote*: string
    commit*: string ## lower-case full-width object id
    line*: int

  ExtraSource* = object
    name*: string
    origin*: string ## the origin URL, `?subdir=` removed
    subdir*: string
    line*: int

  OverrideRecord* = object
    ## `[[override]]`: an origin a package is generated from instead of the
    ## registry's (with `commit`, only that commit), and/or the requirements
    ## of versions the static reader cannot read (NPC-AREQ8 step 2), for one
    ## `tag` or for every such version of the package.
    package*: string
    origin*: string
    subdir*: string
    commit*: string
    tag*: string
    requires*: seq[string]
    hasRequires*: bool
    line*: int

  MirrorRole* = enum
    mrRequired = "required"
      ## publishing is complete only when every source object is on it
    mrOptional = "optional"
      ## served to clients, never awaited by a publish

  MirrorDecl* = object
    ## `[[mirror]]`: a durable copy of the index's source objects
    ## (NPC-AREQ13). A location, not part of what the index says, so it is
    ## not in the source set's identity.
    url*: string  ## `https://...`, or an absolute directory path
    role*: MirrorRole
    line*: int

  SourcePolicy* = object
    unlisted*: UnlistedPolicy
    probe*: ProbePolicy
    cooldownDays*: int
    trackHead*: seq[string] ## sorted, unique

  SourceSet* = object
    registries*: seq[RegistrySource] ## sorted by (remote, commit)
    roots*: seq[string]              ## sorted, unique
    extras*: seq[ExtraSource]        ## sorted by name key
    overrides*: seq[OverrideRecord]  ## sorted by (name key, tag)
    policy*: SourcePolicy
    mirrors*: seq[MirrorDecl]        ## in declaration order: the search order

  SourceSetError* = object of ValueError
    ## The source set cannot be read; the message names every cause.

proc isHex(value: string; width: int): bool =
  value.len == width and value.allCharsInSet({'0'..'9', 'a'..'f', 'A'..'F'})

proc splitOriginUrl*(url: string): tuple[url, subdir: string] =
  ## A registry or source-set URL without its `?subdir=` query, and the
  ## subdirectory the query names (Nimble's `?subdir=`).
  let q = url.find('?')
  if q < 0:
    return (url, "")
  result.url = url[0 ..< q]
  for part in url[q + 1 .. ^1].split('&'):
    if part.startsWith("subdir="):
      result.subdir = part["subdir=".len .. ^1].strip(chars = {'/'})

type
  ValueKind = enum vkString, vkInt, vkArray
  Value = object
    kind: ValueKind
    s: string
    i: int
    items: seq[string]

proc parseSourceSet*(text, path: string): SourceSet =
  ## Read a `nimble-sources.toml` (see the module docstring). Raises
  ## `SourceSetError` naming every cause; never returns a partial set.
  var errors: seq[string]
  template fail(lineNo: int; message: string) =
    errors.add(path & ":" & $lineNo & ": " & message)

  if text.startsWith("\xEF\xBB\xBF"):
    raise newException(SourceSetError, path & ": starts with a byte-order " &
      "mark, which this reader does not accept; save it as plain UTF-8")
  let badUtf8 = validateUtf8(text)
  if badUtf8 >= 0:
    raise newException(SourceSetError, path & ": is not valid UTF-8 (byte " &
      $badUtf8 & "); TOML is UTF-8")

  proc controlChar(s: string): bool =
    for ch in s:
      if (ord(ch) < 0x20 and ch != '\t') or ord(ch) == 0x7f:
        return true
    false

  type Section = enum sTop, sRegistry, sRoot, sExtra, sOverride, sPolicy,
    sMirror
  var section = sTop
  var tables: seq[(Section, int, seq[(string, Value, int)])]
  var top: seq[(string, Value, int)]
  var sawPolicy = false
  var lineNo = 0

  proc parseString(line: string; pos: var int; lineNo: int;
                   key: string; ok: var bool): string =
    ## A basic string starting at ``line[pos] == '"'``.
    ok = false
    inc pos
    while pos < line.len:
      let ch = line[pos]
      if ch == '"':
        inc pos
        ok = true
        return
      if ch == '\\':
        if pos + 1 < line.len and line[pos + 1] in {'\\', '"'}:
          result.add line[pos + 1]
          pos += 2
          continue
        fail(lineNo, "the value of " & key.escape() & " contains an escape " &
          "other than \\\\ or \\\"")
        return
      if ord(ch) < 0x20 or ord(ch) == 0x7f:
        fail(lineNo, "the value of " & key.escape() & " contains a control " &
          "character")
        return
      result.add ch
      inc pos
    fail(lineNo, "the value of " & key.escape() & " is not terminated")

  for rawLine in text.split('\n'):
    inc lineNo
    var line = rawLine
    if line.endsWith("\r"):
      line.setLen(line.len - 1)
    line = line.strip(chars = {' ', '\t'})
    if line.len == 0:
      continue
    if line.startsWith("#"):
      if controlChar(line):
        fail(lineNo, "a comment contains a control character (TOML permits " &
          "none but tab; a lone carriage return is one)")
      continue
    if line.startsWith("["):
      var header = line
      let hash = header.find('#')
      if hash > 0:
        header = header[0 ..< hash].strip(chars = {' ', '\t'})
      case header
      of "[[registry]]": section = sRegistry
      of "[[root]]": section = sRoot
      of "[[extra]]": section = sExtra
      of "[[override]]": section = sOverride
      of "[[mirror]]": section = sMirror
      of "[policy]":
        if sawPolicy:
          fail(lineNo, "duplicate table [policy]")
        sawPolicy = true
        section = sPolicy
      else:
        fail(lineNo, "unsupported table header " & header.escape() &
          " (read: [[registry]], [[root]], [[extra]], [[override]], " &
          "[[mirror]], [policy])")
        section = sTop
        continue
      tables.add((section, lineNo, newSeq[(string, Value, int)]()))
      continue
    var pos = 0
    var key = ""
    while pos < line.len and line[pos] in {'a'..'z', 'A'..'Z', '0'..'9', '_',
                                           '-'}:
      key.add line[pos]
      inc pos
    if key.len == 0:
      fail(lineNo, "expected `key = value`: " & line.escape())
      continue
    while pos < line.len and line[pos] in {' ', '\t'}: inc pos
    if pos >= line.len or line[pos] != '=':
      fail(lineNo, "expected `=` after key " & key.escape() &
        " (dotted, quoted and bare-without-value keys are not read)")
      continue
    inc pos
    while pos < line.len and line[pos] in {' ', '\t'}: inc pos
    var value: Value
    var ok = true
    if pos < line.len and line[pos] == '"':
      if pos + 2 < line.len and line[pos + 1] == '"' and line[pos + 2] == '"':
        fail(lineNo, "the value of " & key.escape() & " is a multi-line " &
          "string, which is not read")
        continue
      value = Value(kind: vkString, s: parseString(line, pos, lineNo, key, ok))
    elif pos < line.len and line[pos] in {'0'..'9'}:
      var digits = ""
      while pos < line.len and line[pos] in {'0'..'9'}:
        digits.add line[pos]
        inc pos
      if digits.len > 1 and digits[0] == '0':
        fail(lineNo, "the value of " & key.escape() & " has a leading zero")
        continue
      if digits.len > 9:
        fail(lineNo, "the value of " & key.escape() & " is too large")
        continue
      value = Value(kind: vkInt, i: parseInt(digits))
    elif pos < line.len and line[pos] == '[':
      inc pos
      value = Value(kind: vkArray)
      var closed = false
      var expectItem = true
      while ok and pos < line.len:
        while pos < line.len and line[pos] in {' ', '\t'}: inc pos
        if pos >= line.len: break
        if line[pos] == ']':
          inc pos
          closed = true
          break
        if line[pos] == '"' and expectItem:
          value.items.add parseString(line, pos, lineNo, key, ok)
          expectItem = false
        elif line[pos] == ',' and not expectItem:
          inc pos
          expectItem = true
        else:
          fail(lineNo, "the array of " & key.escape() & " holds something " &
            "other than basic strings separated by commas")
          ok = false
      if ok and not closed:
        fail(lineNo, "the array of " & key.escape() & " does not close on " &
          "its line (a multi-line array is not read)")
        ok = false
    else:
      fail(lineNo, "the value of " & key.escape() & " must be a basic " &
        "\"string\", a non-negative integer or a one-line array of strings " &
        "(booleans, floats, dates, inline tables, literal and multi-line " &
        "strings are not read)")
      continue
    if not ok:
      continue
    while pos < line.len and line[pos] in {' ', '\t'}: inc pos
    if pos < line.len and line[pos] != '#':
      fail(lineNo, "unexpected text after the value of " & key.escape())
      continue
    if pos < line.len and controlChar(line[pos .. ^1]):
      fail(lineNo, "the comment after the value of " & key.escape() &
        " contains a control character")
      continue
    if section == sTop:
      top.add((key, value, lineNo))
    else:
      tables[^1][2].add((key, value, lineNo))

  # ---- the top level ------------------------------------------------------
  var schema = ""
  var sawSchema = false
  for (k, v, at) in top:
    if k != "schema":
      fail(at, "unknown top-level key " & k.escape() & " (only `schema` " &
        "precedes the tables)")
    elif sawSchema:
      fail(at, "duplicate key \"schema\"")
    elif v.kind != vkString:
      fail(at, "`schema` must be a string")
    else:
      sawSchema = true
      schema = v.s
  if not sawSchema:
    errors.add(path & ": missing `schema = \"" & SourceSetSchemaV1 & "\"`")
  elif schema != SourceSetSchemaV1:
    errors.add(path & ": unsupported schema " & schema.escape() &
      " (this reader accepts " & SourceSetSchemaV1 & ")")

  # ---- the tables ---------------------------------------------------------
  proc keysOf(entries: seq[(string, Value, int)]; allowed: openArray[string];
              what: string): seq[(string, Value, int)] =
    var seen: seq[string]
    for (k, v, at) in entries:
      if k notin allowed:
        var hint = ""
        if what == "[[registry]]" and k == "ref":
          hint = "; the registry is read at a pinned `commit`, and a ref " &
            "is accepted only by the command that updates the pin"
        fail(at, "unknown key " & k.escape() & " in " & what & " (accepted: " &
          allowed.join(", ") & ")" & hint)
        continue
      if k in seen:
        fail(at, "duplicate key " & k.escape() & " in " & what)
        continue
      seen.add k
      result.add((k, v, at))

  proc str(entries: seq[(string, Value, int)]; k: string; found: var bool;
           what: string): string =
    found = false
    for (key, v, at) in entries:
      if key == k:
        if v.kind != vkString:
          fail(at, "`" & k & "` in " & what & " must be a string")
          return ""
        found = true
        return v.s
    ""

  proc nameDefect(value: string): string =
    if value.len == 0: return "is empty"
    if value != value.strip(): return "has leading or trailing whitespace"
    for c in value:
      if ord(c) <= 0x20 or ord(c) >= 0x7f:
        return "contains a character outside printable ASCII"
    ""

  var registries: seq[RegistrySource]
  var roots: seq[(string, int)]
  var extras: seq[ExtraSource]
  var overrides: seq[OverrideRecord]
  var mirrors: seq[MirrorDecl]
  var policy = SourcePolicy(unlisted: upRefuse, probe: ppOff)

  for (sec, at, raw) in tables:
    case sec
    of sTop: discard
    of sRegistry:
      let e = keysOf(raw, ["remote", "commit"], "[[registry]]")
      var hasRemote, hasCommit: bool
      let remote = str(e, "remote", hasRemote, "[[registry]]")
      let commit = str(e, "commit", hasCommit, "[[registry]]")
      if not hasRemote: fail(at, "[[registry]] is missing `remote`")
      if not hasCommit:
        fail(at, "[[registry]] is missing `commit` (the registry is read " &
          "at a pinned commit, so a generation is repeatable)")
      elif not (isHex(commit, 40) or isHex(commit, 64)):
        fail(at, "commit " & commit.escape() & " of [[registry]] is not a " &
          "full-width commit id (40 or 64 hex digits); an abbreviated id " &
          "names a set of commits, not one")
      if hasRemote and nameDefect(remote).len > 0:
        fail(at, "remote " & remote.escape() & " " & nameDefect(remote))
      registries.add RegistrySource(remote: remote,
        commit: commit.toLowerAscii(), line: at)
    of sRoot:
      let e = keysOf(raw, ["package"], "[[root]]")
      var has: bool
      let p = str(e, "package", has, "[[root]]")
      if not has: fail(at, "[[root]] is missing `package`")
      elif nameDefect(p).len > 0:
        fail(at, "root package " & p.escape() & " " & nameDefect(p))
      else: roots.add((p, at))
    of sMirror:
      let e = keysOf(raw, ["url", "role"], "[[mirror]]")
      var hasUrl, hasRole: bool
      let url = str(e, "url", hasUrl, "[[mirror]]")
      let role = str(e, "role", hasRole, "[[mirror]]")
      var m = MirrorDecl(url: url, role: mrRequired, line: at)
      if not hasUrl: fail(at, "[[mirror]] is missing `url`")
      elif nameDefect(url).len > 0:
        fail(at, "mirror url " & url.escape() & " " & nameDefect(url))
      elif not (url.startsWith("https://") or url.startsWith("/")):
        fail(at, "mirror url " & url.escape() & " is neither an https:// " &
          "URL nor an absolute directory path")
      if hasRole:
        case role
        of "required": m.role = mrRequired
        of "optional": m.role = mrOptional
        else:
          fail(at, "mirror role " & role.escape() & " is neither " &
            "\"required\" nor \"optional\"")
      mirrors.add m
    of sExtra:
      let e = keysOf(raw, ["name", "origin"], "[[extra]]")
      var hasName, hasOrigin: bool
      let name = str(e, "name", hasName, "[[extra]]")
      let origin = str(e, "origin", hasOrigin, "[[extra]]")
      if not hasName: fail(at, "[[extra]] is missing `name`")
      elif nameDefect(name).len > 0:
        fail(at, "extra name " & name.escape() & " " & nameDefect(name))
      if not hasOrigin: fail(at, "[[extra]] is missing `origin`")
      let (u, sub) = splitOriginUrl(origin)
      extras.add ExtraSource(name: name, origin: u, subdir: sub, line: at)
    of sOverride:
      let e = keysOf(raw, ["package", "origin", "commit", "tag", "requires"],
        "[[override]]")
      var has, hasOrigin, hasCommit, hasTag: bool
      var o = OverrideRecord(line: at)
      o.package = str(e, "package", has, "[[override]]")
      if not has: fail(at, "[[override]] is missing `package`")
      elif nameDefect(o.package).len > 0:
        fail(at, "override package " & o.package.escape() & " " &
          nameDefect(o.package))
      let origin = str(e, "origin", hasOrigin, "[[override]]")
      (o.origin, o.subdir) = splitOriginUrl(origin)
      o.commit = str(e, "commit", hasCommit, "[[override]]").toLowerAscii()
      o.tag = str(e, "tag", hasTag, "[[override]]")
      for (k, v, kat) in e:
        if k == "requires":
          if v.kind != vkArray:
            fail(kat, "`requires` in [[override]] must be an array of " &
              "requirement strings")
          else:
            o.requires = v.items
            o.hasRequires = true
      if hasCommit and not hasOrigin:
        fail(at, "[[override]] names a `commit` without an `origin`")
      if hasCommit and not (isHex(o.commit, 40) or isHex(o.commit, 64)):
        fail(at, "commit " & o.commit.escape() & " of [[override]] is not a " &
          "full-width commit id")
      if not hasOrigin and not o.hasRequires:
        fail(at, "[[override]] " & o.package.escape() & " overrides " &
          "nothing: give an `origin`, `requires`, or both")
      if hasTag and not o.hasRequires:
        fail(at, "[[override]] names a `tag` but no `requires`")
      if hasTag and o.tag.len == 0:
        fail(at, "the `tag` of [[override]] is empty")
      overrides.add o
    of sPolicy:
      let e = keysOf(raw, ["unlisted", "probe", "cooldown_days", "track_head"],
        "[policy]")
      for (k, v, kat) in e:
        case k
        of "unlisted":
          if v.kind != vkString or v.s notin ["refuse", "allow"]:
            fail(kat, "`unlisted` must be \"refuse\" or \"allow\"")
          elif v.s == "allow": policy.unlisted = upAllow
        of "probe":
          if v.kind != vkString or v.s notin ["off", "sandboxed"]:
            fail(kat, "`probe` must be \"off\" or \"sandboxed\"")
          elif v.s == "sandboxed": policy.probe = ppSandboxed
        of "cooldown_days":
          if v.kind != vkInt:
            fail(kat, "`cooldown_days` must be a non-negative integer")
          elif v.i > MaxCooldownDays:
            fail(kat, "`cooldown_days` " & $v.i & " exceeds " &
              $MaxCooldownDays)
          else: policy.cooldownDays = v.i
        of "track_head":
          if v.kind != vkArray:
            fail(kat, "`track_head` must be an array of package names")
          else:
            var seen = initHashSet[string]()
            for n in v.items:
              if nameDefect(n).len > 0:
                fail(kat, "track_head name " & n.escape() & " " & nameDefect(n))
              elif nameKey(n) in seen:
                fail(kat, "track_head names " & n.escape() & " twice")
              else:
                seen.incl nameKey(n)
                policy.trackHead.add n
        else: discard

  if registries.len == 0 and extras.len == 0:
    errors.add(path & ": names no source: give a [[registry]] or an " &
      "[[extra]]")
  var seenRoots = initHashSet[string]()
  for (r, at) in roots:
    if nameKey(r) in seenRoots:
      fail(at, "root " & r.escape() & " is listed twice")
    seenRoots.incl nameKey(r)
  var seenExtras = initHashSet[string]()
  for x in extras:
    if x.name.len > 0 and nameKey(x.name) in seenExtras:
      fail(x.line, "extra " & x.name.escape() & " is listed twice")
    seenExtras.incl nameKey(x.name)
  var seenOverrides = initHashSet[string]()
  for o in overrides:
    let k = nameKey(o.package) & "\0" & o.tag & "\0" &
      (if o.origin.len > 0: "origin" else: "")
    if k in seenOverrides:
      fail(o.line, "a second [[override]] of " & o.package.escape() &
        (if o.tag.len > 0: " at tag " & o.tag.escape() else: ""))
    seenOverrides.incl k
  var seenMirrors = initHashSet[string]()
  for m in mirrors:
    if m.url in seenMirrors:
      fail(m.line, "mirror " & m.url.escape() & " is listed twice")
    seenMirrors.incl m.url
  var seenRemotes = initHashSet[string]()
  for r in registries:
    if r.remote in seenRemotes:
      fail(r.line, "registry " & r.remote.escape() & " is listed twice")
    seenRemotes.incl r.remote

  if errors.len > 0:
    raise newException(SourceSetError, "the source set cannot be read:\n  " &
      errors.join("\n  "))

  registries.sort(proc (a, b: RegistrySource): int =
    result = cmp(a.remote, b.remote)
    if result == 0: result = cmp(a.commit, b.commit))
  for (r, _) in roots: result.roots.add r
  result.roots.sort()
  extras.sort(proc (a, b: ExtraSource): int = cmp(nameKey(a.name), nameKey(b.name)))
  overrides.sort(proc (a, b: OverrideRecord): int =
    result = cmp(nameKey(a.package), nameKey(b.package))
    if result == 0: result = cmp(a.tag, b.tag)
    if result == 0: result = cmp(a.origin, b.origin))
  policy.trackHead.sort()
  result.registries = registries
  result.extras = extras
  result.overrides = overrides
  result.policy = policy
  result.mirrors = mirrors

proc canonicalText*(s: SourceSet): string =
  ## The source set's content in one canonical spelling: what its identity
  ## hashes. Line numbers are not part of it, and neither are the mirrors:
  ## where copies of the sources are kept does not change what the index
  ## says (NPC-AREQ19: a location is not identity).
  var lines = @["schema " & SourceSetSchemaV1]
  for r in s.registries:
    lines.add "registry " & r.remote.escape() & " " & r.commit
  for r in s.roots:
    lines.add "root " & r.escape()
  for x in s.extras:
    lines.add "extra " & x.name.escape() & " " & x.origin.escape() & " " &
      x.subdir.escape()
  for o in s.overrides:
    var reqs: seq[string]
    for r in o.requires: reqs.add r.escape()
    lines.add "override " & o.package.escape() & " origin=" &
      o.origin.escape() & " subdir=" & o.subdir.escape() & " commit=" &
      o.commit & " tag=" & o.tag.escape() & " requires=" &
      (if o.hasRequires: "[" & reqs.join(",") & "]" else: "-")
  var heads: seq[string]
  for h in s.policy.trackHead: heads.add h.escape()
  lines.add "policy unlisted=" & $s.policy.unlisted & " probe=" &
    $s.policy.probe & " cooldown_days=" & $s.policy.cooldownDays &
    " track_head=[" & heads.join(",") & "]"
  lines.join("\n") & "\n"

proc sourceSetIdentity*(s: SourceSet): IndexObjectId =
  ## BLAKE3 of the canonical text under a domain: the root's `sourceSet`.
  IndexObjectId(blake3.digest(SourceSetIdentityDomain & "\0" & canonicalText(s)))
