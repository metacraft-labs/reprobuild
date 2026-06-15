## D2 P1: dnf primary.xml index parsing library.
##
## Parses Fedora-style ``repodata/primary.xml`` (post-decompression) into
## structured records, resolves ``<rpm:requires>`` entries into atom
## trees, and walks the transitive closure of a starting package using a
## ``provides`` table for virtual deps (file paths, ``rpmlib(...)``
## features, etc).
##
## ## Why this lives in repro_dsl_stdlib/packages/
##
## Same rationale as ``apt_index.nim``: the C2 repro-harvest-apt + the
## C3 sandbox-launcher manifest generator + any future audit tooling all
## need a consistent view of the snapshot's package index. Keeping the
## parser next to the ``foreign_dnf`` DSL surface keeps the data
## definitions of the dnf-bundle Tier-3 model in one importable module.
##
## ## Scope
##
## D2 ships only the read path: parse the index, walk the closure, yield
## a sorted list of ``DnfPackageRecord``. Emitting an index (e.g. for a
## synthetic mirror) is out of scope.
##
## ## Parser caveats
##
## * The primary.xml is XML; we use a minimal targeted parser rather
##   than std/xmlparser to keep dependencies low and the parse byte-
##   stable. The parser is whitespace-tolerant and recognises only the
##   elements we need (``<package>``, ``<name>``, ``<version>``,
##   ``<location>``, ``<checksum>``, ``<size>``, ``<format>``,
##   ``<rpm:provides>``, ``<rpm:requires>``).
## * ``rpmlib(...)`` and file-path-style requires (e.g. ``/bin/sh``,
##   ``/sbin/ldconfig``) are tolerated: the closure walker silently
##   skips deps it cannot resolve when ``allowUnresolved`` is true
##   (default for D2's harvester is true so a real Fedora primary.xml
##   doesn't blow up on the dozens of system-implicit deps). The
##   harvester also relies on ``provides`` to map shared-library
##   sonames to packages.
## * Version operators (``EQ``, ``GE``, ``GT``, ``LE``, ``LT``) are
##   carried as enum values but not enforced — every snapshot is
##   internally consistent.

import std/[algorithm, sets, strutils, tables]

type
  DnfDependencyOp* = enum
    ## RPM version-constraint operator from ``rpm:entry flags="..."``.
    ddoAny       = "any"
    ddoLt        = "LT"
    ddoLe        = "LE"
    ddoEq        = "EQ"
    ddoGe        = "GE"
    ddoGt        = "GT"

  DnfDependencyAtom* = object
    ## One ``<rpm:entry>`` atom of a requires / provides clause.
    name*: string
    op*: DnfDependencyOp
    epoch*: string
    version*: string
    release*: string

  DnfPackageRecord* = object
    ## One ``<package>`` stanza in primary.xml, normalised. The harvester
    ## writes one catalog file per record reached via the closure walk.
    name*: string
    arch*: string
    epoch*: string
    version*: string
    release*: string
    summary*: string
    location*: string             ## relative path from the repo root
                                  ## (e.g. ``Packages/h/htop-3.3.0-1.fc39.x86_64.rpm``)
    checksumType*: string         ## typically ``sha256``
    checksumHex*: string          ## lowercase hex
    sizePackage*: int64           ## bytes of the .rpm file
    requires*: seq[DnfDependencyAtom]
    provides*: seq[DnfDependencyAtom]

  DnfIndex* = object
    records*: seq[DnfPackageRecord]
    byName*: Table[string, int]      ## real package name → index
    virtuals*: Table[string, seq[string]]
      ## maps a provided string (file path, soname, virtual name) to
      ## one or more real package names that advertise it.

  DnfIndexParseError* = object of CatchableError
    lineNo*: int
    stanzaName*: string

  DnfClosureError* = object of CatchableError
    rootPackage*: string
    missingDep*: string

# ---------------------------------------------------------------------------
# Lightweight XML scanner specialised for primary.xml shape
# ---------------------------------------------------------------------------
#
# We use a hand-rolled top-down parser instead of std/xmlparser to keep
# the output byte-stable and the dependency surface tight. The grammar:
#
#   metadata := <metadata ...> package* </metadata>
#   package  := <package type="rpm"> name version arch location
#                                     checksum size? format </package>
#   format   := <format> rpm:provides? rpm:requires? other-ignored* </format>
#
# We skip elements we don't care about by tag-balance walking.

type
  XmlScanner = object
    src: string
    pos: int

proc raiseStanza(msg: string; lineNo = 0; stanzaName = "") {.noreturn.} =
  var e = newException(DnfIndexParseError, msg)
  e.lineNo = lineNo
  e.stanzaName = stanzaName
  raise e

proc skipWs(s: var XmlScanner) =
  while s.pos < s.src.len and s.src[s.pos] in {' ', '\t', '\r', '\n'}:
    inc s.pos

proc startsHere(s: XmlScanner; needle: string): bool =
  if s.pos + needle.len > s.src.len: return false
  for i in 0 ..< needle.len:
    if s.src[s.pos + i] != needle[i]: return false
  true

proc consume(s: var XmlScanner; needle: string): bool =
  if startsHere(s, needle):
    s.pos += needle.len
    return true
  false

proc skipUntil(s: var XmlScanner; needle: string) =
  while s.pos < s.src.len and not startsHere(s, needle):
    inc s.pos

proc readUntilChar(s: var XmlScanner; ch: char): string =
  let start = s.pos
  while s.pos < s.src.len and s.src[s.pos] != ch:
    inc s.pos
  result = s.src[start ..< s.pos]

proc readTextUntil(s: var XmlScanner; needle: string): string =
  let start = s.pos
  while s.pos < s.src.len and not startsHere(s, needle):
    inc s.pos
  result = s.src[start ..< s.pos]

proc xmlUnescape(s: string): string =
  ## Reverse the five XML entity escapes we care about. primary.xml
  ## payloads rarely carry exotic entities so this is sufficient.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let semi = s.find(';', start = i)
      if semi < 0:
        result.add(s[i])
        inc i
        continue
      let ent = s[i + 1 ..< semi]
      case ent
      of "amp":  result.add('&')
      of "lt":   result.add('<')
      of "gt":   result.add('>')
      of "quot": result.add('"')
      of "apos": result.add('\'')
      else:
        if ent.startsWith("#x") or ent.startsWith("#X"):
          try:
            let cp = parseHexInt(ent[2 .. ^1])
            if cp < 128: result.add(char(cp))
          except CatchableError: discard
        elif ent.startsWith("#"):
          try:
            let cp = parseInt(ent[1 .. ^1])
            if cp < 128: result.add(char(cp))
          except CatchableError: discard
      i = semi + 1
    else:
      result.add(s[i])
      inc i

type
  XmlAttr = object
    name: string
    value: string

proc parseAttrs(rawTag: string): seq[XmlAttr] =
  ## Given the contents of an opening tag (everything between '<' and
  ## the terminating '>'), extract attribute name/value pairs.
  result = @[]
  var i = 0
  # Skip the tag name token.
  while i < rawTag.len and rawTag[i] notin {' ', '\t', '\r', '\n'}:
    inc i
  while i < rawTag.len:
    while i < rawTag.len and rawTag[i] in {' ', '\t', '\r', '\n', '/'}:
      inc i
    if i >= rawTag.len: break
    let nameStart = i
    while i < rawTag.len and rawTag[i] notin {' ', '\t', '\r', '\n', '='}:
      inc i
    let name = rawTag[nameStart ..< i]
    while i < rawTag.len and rawTag[i] in {' ', '\t', '\r', '\n'}: inc i
    if i >= rawTag.len or rawTag[i] != '=':
      if name.len > 0:
        result.add(XmlAttr(name: name, value: ""))
      continue
    inc i  # '='
    while i < rawTag.len and rawTag[i] in {' ', '\t', '\r', '\n'}: inc i
    if i >= rawTag.len: break
    var quote = ' '
    if rawTag[i] == '\'' or rawTag[i] == '"':
      quote = rawTag[i]
      inc i
    let valStart = i
    while i < rawTag.len and rawTag[i] != quote: inc i
    let value = rawTag[valStart ..< i]
    if i < rawTag.len: inc i  # closing quote
    result.add(XmlAttr(name: name, value: xmlUnescape(value)))

proc getAttr(attrs: seq[XmlAttr]; name: string): string =
  for a in attrs:
    if a.name == name: return a.value
  ""

# ---------------------------------------------------------------------------
# Token-level helpers
# ---------------------------------------------------------------------------

type
  TagShape = enum
    tsOpen, tsClose, tsSelfClose

proc nextTag(s: var XmlScanner;
             outName: var string;
             outAttrs: var seq[XmlAttr];
             outShape: var TagShape;
             outText: var string): bool =
  ## Advance ``s`` past any leading character data, then consume the
  ## next opening / closing / self-closing tag. Returns ``false`` at
  ## EOF. ``outText`` carries the character data immediately preceding
  ## the tag (the element's text content for simple ``<x>val</x>``).
  outName = ""
  outAttrs = @[]
  outText = ""
  var collectedText = false
  while true:
    if s.pos >= s.src.len: return false
    let textStart = s.pos
    while s.pos < s.src.len and s.src[s.pos] != '<':
      inc s.pos
    if not collectedText and s.pos > textStart:
      outText = xmlUnescape(s.src[textStart ..< s.pos])
      collectedText = true
    if s.pos >= s.src.len: return false
    # Skip comments, processing instructions, and DOCTYPE-like declarations.
    if startsHere(s, "<!--"):
      s.pos += 4
      skipUntil(s, "-->")
      if s.pos < s.src.len: s.pos += 3
      continue
    if startsHere(s, "<?"):
      s.pos += 2
      skipUntil(s, "?>")
      if s.pos < s.src.len: s.pos += 2
      continue
    if startsHere(s, "<!"):
      s.pos += 2
      var depth = 0
      while s.pos < s.src.len:
        if s.src[s.pos] == '[': inc depth
        elif s.src[s.pos] == ']': dec depth
        elif s.src[s.pos] == '>' and depth <= 0:
          inc s.pos
          break
        inc s.pos
      continue
    break
  if s.pos >= s.src.len or s.src[s.pos] != '<': return false
  inc s.pos  # past '<'
  var shape = tsOpen
  if s.pos < s.src.len and s.src[s.pos] == '/':
    shape = tsClose
    inc s.pos
  let rawStart = s.pos
  while s.pos < s.src.len and s.src[s.pos] != '>': inc s.pos
  if s.pos >= s.src.len: return false
  var raw = s.src[rawStart ..< s.pos]
  inc s.pos  # past '>'
  if raw.len > 0 and raw[^1] == '/':
    shape = tsSelfClose
    raw.setLen(raw.len - 1)
  outShape = shape
  # Tag name is the first whitespace-delimited token.
  var ni = 0
  while ni < raw.len and raw[ni] notin {' ', '\t', '\r', '\n', '/'}: inc ni
  outName = raw[0 ..< ni]
  outAttrs = parseAttrs(raw)
  true

# ---------------------------------------------------------------------------
# Element-level parsers
# ---------------------------------------------------------------------------

proc parseEntryAttrs(attrs: seq[XmlAttr]): DnfDependencyAtom =
  result.name = getAttr(attrs, "name")
  let flags = getAttr(attrs, "flags")
  case flags
  of "":   result.op = ddoAny
  of "EQ": result.op = ddoEq
  of "LT": result.op = ddoLt
  of "LE": result.op = ddoLe
  of "GT": result.op = ddoGt
  of "GE": result.op = ddoGe
  else:    result.op = ddoAny
  result.epoch = getAttr(attrs, "epoch")
  result.version = getAttr(attrs, "ver")
  result.release = getAttr(attrs, "rel")

proc parsePackageElement(s: var XmlScanner): DnfPackageRecord =
  ## Parse the body of one ``<package type="rpm"> ... </package>`` element.
  ## ``s`` MUST be positioned immediately after the opening tag.
  var depth = 1  # we entered <package>
  var name: string
  var attrs: seq[XmlAttr]
  var shape: TagShape
  var text: string
  var inFormat = false
  while depth > 0 and nextTag(s, name, attrs, shape, text):
    if shape == tsClose:
      if name == "package":
        dec depth
      elif name == "format":
        inFormat = false
      continue
    if shape == tsOpen and name == "format":
      inFormat = true
      continue
    if shape == tsOpen and name == "package":
      inc depth
      continue
    # Leaf elements at the top level of <package>.
    case name
    of "name":
      let txt = readUntilChar(s, '<')
      result.name = xmlUnescape(txt).strip()
      # consume </name>
      var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
      discard nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText)
    of "arch":
      let txt = readUntilChar(s, '<')
      result.arch = xmlUnescape(txt).strip()
      var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
      discard nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText)
    of "summary":
      let txt = readUntilChar(s, '<')
      result.summary = xmlUnescape(txt).strip()
      var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
      discard nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText)
    of "version":
      # Self-closing or empty content: <version epoch="0" ver="3.3.0" rel="1.fc39"/>
      result.epoch = getAttr(attrs, "epoch")
      result.version = getAttr(attrs, "ver")
      result.release = getAttr(attrs, "rel")
      if shape == tsOpen:
        # Consume until </version>.
        var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
        while nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText):
          if dummyShape == tsClose and dummyName == "version": break
    of "checksum":
      result.checksumType = getAttr(attrs, "type")
      if shape == tsOpen:
        let txt = readUntilChar(s, '<')
        result.checksumHex = xmlUnescape(txt).strip().toLowerAscii()
        var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
        discard nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText)
    of "location":
      result.location = getAttr(attrs, "href")
      if shape == tsOpen:
        var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
        while nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText):
          if dummyShape == tsClose and dummyName == "location": break
    of "size":
      let pkgAttr = getAttr(attrs, "package")
      if pkgAttr.len > 0:
        try: result.sizePackage = parseBiggestInt(pkgAttr).int64
        except CatchableError: discard
      if shape == tsOpen:
        var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
        while nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText):
          if dummyShape == tsClose and dummyName == "size": break
    of "rpm:provides":
      # Parse children <rpm:entry .../>
      if shape == tsOpen:
        var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
        while nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText):
          if dummyShape == tsClose and dummyName == "rpm:provides": break
          if dummyName == "rpm:entry":
            result.provides.add(parseEntryAttrs(dummyAttrs))
    of "rpm:requires":
      if shape == tsOpen:
        var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
        while nextTag(s, dummyName, dummyAttrs, dummyShape, dummyText):
          if dummyShape == tsClose and dummyName == "rpm:requires": break
          if dummyName == "rpm:entry":
            # Skip "pre" / "post" install hints + rpmlib() features so
            # the closure walker doesn't drown in noise.
            let atom = parseEntryAttrs(dummyAttrs)
            if atom.name.startsWith("rpmlib("):
              continue
            result.requires.add(atom)
    else:
      # Unknown element; skip its content if it has any.
      if shape == tsOpen:
        var dummyName: string; var dummyAttrs: seq[XmlAttr]; var dummyShape: TagShape; var dummyText: string
        var localDepth = 1
        while localDepth > 0 and nextTag(s, dummyName, dummyAttrs,
            dummyShape, dummyText):
          if dummyShape == tsOpen: inc localDepth
          elif dummyShape == tsClose: dec localDepth
  if result.name.len == 0:
    raiseStanza("primary.xml stanza missing <name>")
  if result.arch.len == 0:
    result.arch = "x86_64"

proc parsePrimaryXml*(content: string): seq[DnfPackageRecord] =
  ## Public entry point. Parses every ``<package>`` in primary.xml and
  ## returns the records in input order.
  result = @[]
  var s = XmlScanner(src: content, pos: 0)
  var name: string
  var attrs: seq[XmlAttr]
  var shape: TagShape
  var text: string
  while nextTag(s, name, attrs, shape, text):
    if shape == tsOpen and name == "package":
      result.add(parsePackageElement(s))

proc buildDnfIndex*(records: sink seq[DnfPackageRecord]): DnfIndex =
  ## Build the name + provides lookup tables. Idempotent: re-running
  ## with the same input yields a byte-identical index.
  result.records = records
  result.byName = initTable[string, int]()
  result.virtuals = initTable[string, seq[string]]()
  for i, rec in result.records:
    result.byName[rec.name] = i
    for prov in rec.provides:
      if prov.name notin result.virtuals:
        result.virtuals[prov.name] = @[]
      result.virtuals[prov.name].add(rec.name)

# ---------------------------------------------------------------------------
# Closure walker
# ---------------------------------------------------------------------------

proc resolveAtom(index: DnfIndex; atomName: string): string =
  if atomName in index.byName:
    return atomName
  if atomName in index.virtuals:
    let provs = index.virtuals[atomName]
    if provs.len > 0:
      var sorted = provs
      sorted.sort(cmp)
      return sorted[0]
  ""

proc resolveClosure*(root: string; index: DnfIndex;
                     allowUnresolved = true): seq[DnfPackageRecord] =
  ## Walk the transitive ``rpm:requires`` closure of ``root`` (a real
  ## package name) in the index and return every reachable record. Sorted
  ## alphabetically by name for byte-stable output.
  ##
  ## ``allowUnresolved`` defaults to ``true`` for the dnf walker because
  ## a real Fedora primary.xml carries dozens of file-path-style requires
  ## and ``rpmlib(...)`` features that aren't part of the package set.
  ## The harvester's fixture-driven tests use ``false`` so closure
  ## completeness is provable.
  if root notin index.byName:
    var e = newException(DnfClosureError,
      "package '" & root & "' not in dnf index")
    e.rootPackage = root
    e.missingDep = root
    raise e

  var visited = initHashSet[string]()
  var queue: seq[string] = @[root]
  while queue.len > 0:
    let name = queue[0]
    queue.delete(0)
    if name in visited:
      continue
    visited.incl(name)
    let rec = index.records[index.byName[name]]
    result.add(rec)
    for req in rec.requires:
      # Filter out path-style requires unless they resolve via provides.
      let resolved = resolveAtom(index, req.name)
      if resolved.len == 0:
        if allowUnresolved:
          continue
        var e = newException(DnfClosureError,
          "dependency '" & req.name & "' of package '" & name &
          "' (root '" & root & "') is not in dnf index")
        e.rootPackage = root
        e.missingDep = req.name
        raise e
      if resolved notin visited:
        queue.add(resolved)

  result.sort(proc (a, b: DnfPackageRecord): int = cmp(a.name, b.name))

proc resolveMultiClosure*(roots: seq[string]; index: DnfIndex;
                          allowUnresolved = true):
    seq[DnfPackageRecord] =
  ## Multi-root closure: union of every per-root closure with no
  ## duplicates. Same sort + error policy as ``resolveClosure``.
  var seen = initHashSet[string]()
  for root in roots:
    let perRoot = resolveClosure(root, index, allowUnresolved)
    for rec in perRoot:
      if rec.name notin seen:
        seen.incl(rec.name)
        result.add(rec)
  result.sort(proc (a, b: DnfPackageRecord): int = cmp(a.name, b.name))

# ---------------------------------------------------------------------------
# Repomd.xml: maps logical types (primary, filelists, other) to file paths.
# ---------------------------------------------------------------------------

type
  RepomdEntry* = object
    dataType*: string
    location*: string
    checksumType*: string
    checksumHex*: string
    openChecksumHex*: string
    sizeBytes*: int64

proc parseRepomdXml*(content: string): seq[RepomdEntry] =
  ## Parse ``repodata/repomd.xml`` into one ``RepomdEntry`` per
  ## ``<data type=...>``. We only consume the fields we need:
  ## ``<location href=...>``, ``<checksum type=...>HEX</checksum>``,
  ## ``<open-checksum>``, ``<size>``.
  result = @[]
  var s = XmlScanner(src: content, pos: 0)
  var name: string
  var attrs: seq[XmlAttr]
  var shape: TagShape
  var text: string
  while nextTag(s, name, attrs, shape, text):
    if shape == tsOpen and name == "data":
      var entry = RepomdEntry(dataType: getAttr(attrs, "type"))
      var depth = 1
      var inOpenChk = false
      var inChk = false
      while depth > 0 and nextTag(s, name, attrs, shape, text):
        if shape == tsClose:
          if name == "data": dec depth
          elif name == "open-checksum": inOpenChk = false
          elif name == "checksum": inChk = false
          continue
        if shape == tsOpen and name == "data":
          inc depth
          continue
        case name
        of "location":
          entry.location = getAttr(attrs, "href")
          if shape == tsOpen:
            var dn: string; var da: seq[XmlAttr]; var ds: TagShape; var dt: string
            while nextTag(s, dn, da, ds, dt):
              if ds == tsClose and dn == "location": break
        of "checksum":
          entry.checksumType = getAttr(attrs, "type")
          inChk = true
          if shape == tsOpen:
            let txt = readUntilChar(s, '<')
            entry.checksumHex = xmlUnescape(txt).strip().toLowerAscii()
            var dn: string; var da: seq[XmlAttr]; var ds: TagShape; var dt: string
            discard nextTag(s, dn, da, ds, dt)
            inChk = false
        of "open-checksum":
          inOpenChk = true
          if shape == tsOpen:
            let txt = readUntilChar(s, '<')
            entry.openChecksumHex = xmlUnescape(txt).strip().toLowerAscii()
            var dn: string; var da: seq[XmlAttr]; var ds: TagShape; var dt: string
            discard nextTag(s, dn, da, ds, dt)
            inOpenChk = false
        of "size":
          if shape == tsOpen:
            let txt = readUntilChar(s, '<')
            try: entry.sizeBytes = parseBiggestInt(xmlUnescape(txt).strip).int64
            except CatchableError: discard
            var dn: string; var da: seq[XmlAttr]; var ds: TagShape; var dt: string
            discard nextTag(s, dn, da, ds, dt)
        else:
          if shape == tsOpen:
            var dn: string; var da: seq[XmlAttr]; var ds: TagShape; var dt: string
            var localDepth = 1
            while localDepth > 0 and nextTag(s, dn, da, ds, dt):
              if ds == tsOpen: inc localDepth
              elif ds == tsClose: dec localDepth
      result.add(entry)
