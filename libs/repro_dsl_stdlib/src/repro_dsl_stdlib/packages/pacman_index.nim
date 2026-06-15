## D2 P2: pacman repo-database index parsing library.
##
## Parses Arch-style ``<repo>.db`` archives — a USTAR tarball (optionally
## gzipped) containing one directory per package, each with a ``desc``
## file in pacman's free-form key/value format. Walks transitive
## ``%DEPENDS%`` closures via a ``%PROVIDES%`` table for virtuals.
##
## ## Why this lives in repro_dsl_stdlib/packages/
##
## Same rationale as ``apt_index.nim`` and ``dnf_index.nim``: the C2
## harvester binary, the C3 sandbox-launcher manifest generator, and any
## future audit tooling all need a consistent view of the snapshot's
## package index.
##
## ## Scope
##
## D2 ships only the read path (parse + closure walk). Emitting a
## repo database is out of scope.
##
## ## Parser notes
##
## * ``desc`` files are plain text with section headers like ``%NAME%``
##   on a line by themselves and values on subsequent indented lines
##   until the next ``%HEADER%`` or blank line.
## * Dependency syntax: each ``%DEPENDS%`` entry may carry a version
##   constraint suffix (``glibc>=2.34``) using ``=``, ``<``, ``<=``,
##   ``>``, ``>=`` operators. We carry but don't enforce them.
## * Some dependency atoms name a soname (``libfoo.so=6``) or a virtual
##   feature. The closure walker uses the ``%PROVIDES%`` table for
##   resolution.

import std/[algorithm, sets, strutils, tables]

type
  PacmanDependencyOp* = enum
    pdoAny = "any"
    pdoLt  = "<"
    pdoLe  = "<="
    pdoEq  = "="
    pdoGe  = ">="
    pdoGt  = ">"

  PacmanDependencyAtom* = object
    name*: string
    op*: PacmanDependencyOp
    version*: string

  PacmanPackageRecord* = object
    name*: string
    version*: string           ## ``%VERSION%`` e.g. ``3.3.0-1``
    arch*: string              ## ``%ARCH%``
    filename*: string          ## ``%FILENAME%`` e.g.
                               ## ``htop-3.3.0-1-x86_64.pkg.tar.zst``
    descSummary*: string       ## first line of ``%DESC%``
    csize*: int64              ## compressed pkg size
    isize*: int64              ## installed size
    sha256*: string            ## lowercase hex
    depends*: seq[PacmanDependencyAtom]
    provides*: seq[PacmanDependencyAtom]
    optdepends*: seq[PacmanDependencyAtom]
    makedepends*: seq[PacmanDependencyAtom]
    checkdepends*: seq[PacmanDependencyAtom]

  PacmanIndex* = object
    records*: seq[PacmanPackageRecord]
    byName*: Table[string, int]
    virtuals*: Table[string, seq[string]]

  PacmanIndexParseError* = object of CatchableError
    lineNo*: int
    stanzaName*: string

  PacmanClosureError* = object of CatchableError
    rootPackage*: string
    missingDep*: string

proc raiseStanza(msg: string; lineNo = 0; stanzaName = "") {.noreturn.} =
  var e = newException(PacmanIndexParseError, msg)
  e.lineNo = lineNo
  e.stanzaName = stanzaName
  raise e

# ---------------------------------------------------------------------------
# Dependency-atom parsing
# ---------------------------------------------------------------------------

proc parseDependencyAtom*(token: string): PacmanDependencyAtom =
  ## Parse one ``%DEPENDS%`` entry like ``glibc>=2.34`` or
  ## ``libcurl.so=4-64`` or just ``ncurses``.
  let t = token.strip()
  if t.len == 0:
    raiseStanza("empty pacman dependency atom")

  result.op = pdoAny

  # Find the first occurrence of '=' '<' '>' that isn't inside a soname
  # tail (sonames look like ``libfoo.so=6`` where the '=' is genuine but
  # the version tail is the soname revision). pacman treats this the
  # same as a normal version constraint, so we don't special-case.
  var opStart = -1
  var i = 0
  while i < t.len:
    if t[i] in {'=', '<', '>'}:
      opStart = i
      break
    inc i
  if opStart < 0:
    result.name = t
    return

  result.name = t[0 ..< opStart]
  var opStr = ""
  var idx = opStart
  while idx < t.len and t[idx] in {'<', '>', '='}:
    opStr.add(t[idx])
    inc idx
  result.version = t[idx .. ^1].strip()
  case opStr
  of "=":  result.op = pdoEq
  of "<":  result.op = pdoLt
  of "<=": result.op = pdoLe
  of ">":  result.op = pdoGt
  of ">=": result.op = pdoGe
  else:
    raiseStanza("unknown pacman version-constraint operator '" & opStr &
      "' in dependency: " & t)

  if result.name.len == 0:
    raiseStanza("empty package name in pacman dependency: " & t)

# ---------------------------------------------------------------------------
# desc file parsing
# ---------------------------------------------------------------------------

proc parseDescFile*(content: string): PacmanPackageRecord =
  ## Parse a pacman ``desc`` file. The format alternates between a
  ## section header line (``%KEY%``) and one or more value lines until
  ## a blank line or EOF.
  var currentKey = ""
  var values: seq[string] = @[]
  var sections = initTable[string, seq[string]]()
  var i = 0
  let lines = content.splitLines
  while i < lines.len:
    let line = lines[i].strip(leading = false, trailing = true,
      chars = {'\r'})
    if line.len == 0:
      if currentKey.len > 0 and values.len > 0:
        sections[currentKey] = values
        values = @[]
      currentKey = ""
    elif line.startsWith("%") and line.endsWith("%"):
      if currentKey.len > 0 and values.len > 0:
        sections[currentKey] = values
        values = @[]
      currentKey = line[1 ..< line.len - 1]
    else:
      values.add(line.strip())
    inc i
  if currentKey.len > 0 and values.len > 0:
    sections[currentKey] = values

  proc firstOf(key: string): string =
    if sections.hasKey(key) and sections[key].len > 0:
      return sections[key][0]
    ""

  proc atomsOf(key: string): seq[PacmanDependencyAtom] =
    if sections.hasKey(key):
      for v in sections[key]:
        if v.len == 0: continue
        result.add(parseDependencyAtom(v))

  result.name = firstOf("NAME")
  result.version = firstOf("VERSION")
  result.arch = firstOf("ARCH")
  result.filename = firstOf("FILENAME")
  result.sha256 = firstOf("SHA256SUM").toLowerAscii
  result.descSummary = firstOf("DESC")
  let cs = firstOf("CSIZE")
  if cs.len > 0:
    try: result.csize = parseBiggestInt(cs).int64
    except CatchableError: discard
  let isz = firstOf("ISIZE")
  if isz.len > 0:
    try: result.isize = parseBiggestInt(isz).int64
    except CatchableError: discard
  result.depends = atomsOf("DEPENDS")
  result.provides = atomsOf("PROVIDES")
  result.optdepends = atomsOf("OPTDEPENDS")
  result.makedepends = atomsOf("MAKEDEPENDS")
  result.checkdepends = atomsOf("CHECKDEPENDS")

  if result.name.len == 0:
    raiseStanza("pacman desc file missing %NAME% section")

# ---------------------------------------------------------------------------
# Tar reader (USTAR + plain V7) and gzip detection
# ---------------------------------------------------------------------------

type
  TarEntry = object
    name*: string
    typeFlag*: char
    bytes*: string

proc parseOctal(s: string): int =
  result = 0
  for c in s:
    if c == '\0' or c == ' ': break
    if c < '0' or c > '7': break
    result = result * 8 + int(c.uint8 - '0'.uint8)

proc readUstarTar*(blob: string): seq[TarEntry] =
  ## Parse the simplest cross-compat subset of tar: 512-byte block aligned.
  ## Supports USTAR (name + prefix) and plain old V7 names. Skips type
  ## flag 'L' (GNU LongName) by reading the long name from the data
  ## payload and reusing it for the FOLLOWING entry.
  result = @[]
  var pos = 0
  var pendingLongName = ""
  while pos + 512 <= blob.len:
    let header = blob[pos ..< pos + 512]
    # Check for end-of-archive (two consecutive zero blocks).
    var allZero = true
    for c in header:
      if c != '\0': allZero = false; break
    if allZero: break
    var name = ""
    var k = 0
    while k < 100 and header[k] != '\0':
      name.add(header[k])
      inc k
    let typeFlag = header[156]
    # USTAR prefix at offset 345 (155 bytes).
    let magic = header[257 ..< 263]
    if magic.startsWith("ustar"):
      var prefix = ""
      var p = 345
      while p < 500 and p < 345 + 155 and header[p] != '\0':
        prefix.add(header[p])
        inc p
      if prefix.len > 0:
        name = prefix & "/" & name
    if pendingLongName.len > 0 and typeFlag != 'L':
      name = pendingLongName
      pendingLongName = ""
    let sizeField = header[124 ..< 124 + 12]
    let size = parseOctal(sizeField)
    let dataStart = pos + 512
    var bytes = ""
    if size > 0 and dataStart + size <= blob.len:
      bytes = blob[dataStart ..< dataStart + size]
    if typeFlag == 'L':
      # GNU long-name: data payload is the name for the next entry.
      pendingLongName = bytes
      if pendingLongName.len > 0 and pendingLongName[^1] == '\0':
        pendingLongName.setLen(pendingLongName.len - 1)
      let pad = (512 - (size mod 512)) mod 512
      pos = dataStart + size + pad
      continue
    result.add(TarEntry(name: name, typeFlag: typeFlag, bytes: bytes))
    let pad = (512 - (size mod 512)) mod 512
    pos = dataStart + size + pad

proc isGzip*(blob: string): bool =
  blob.len >= 2 and blob[0] == '\x1F' and blob[1] == '\x8B'

# ---------------------------------------------------------------------------
# Repo database parser entry point
# ---------------------------------------------------------------------------

proc parseRepoDb*(blob: string): seq[PacmanPackageRecord] =
  ## Parse a raw (uncompressed) USTAR tarball of desc files. The caller
  ## decompresses any gzip wrapper first (see ``maybeDecompress`` in
  ## the harvester binary, which shells out to ``gzip``).
  let entries = readUstarTar(blob)
  result = @[]
  for e in entries:
    # We accept any file whose name ends in '/desc'.
    let n = e.name.replace("\\", "/")
    if n.endsWith("/desc") or n == "desc":
      result.add(parseDescFile(e.bytes))

proc buildPacmanIndex*(records: sink seq[PacmanPackageRecord]):
    PacmanIndex =
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

proc resolveAtom(index: PacmanIndex; atomName: string): string =
  if atomName in index.byName:
    return atomName
  if atomName in index.virtuals:
    let provs = index.virtuals[atomName]
    if provs.len > 0:
      var sorted = provs
      sorted.sort(cmp)
      return sorted[0]
  ""

proc resolveClosure*(root: string; index: PacmanIndex;
                     allowUnresolved = false):
    seq[PacmanPackageRecord] =
  ## Walk the transitive ``%DEPENDS%`` closure of ``root``. Sorted by
  ## name for byte-stable output.
  if root notin index.byName:
    var e = newException(PacmanClosureError,
      "package '" & root & "' not in pacman index")
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
    for d in rec.depends:
      let resolved = resolveAtom(index, d.name)
      if resolved.len == 0:
        if allowUnresolved:
          continue
        var e = newException(PacmanClosureError,
          "dependency '" & d.name & "' of package '" & name &
          "' (root '" & root & "') is not in pacman index")
        e.rootPackage = root
        e.missingDep = d.name
        raise e
      if resolved notin visited:
        queue.add(resolved)

  result.sort(proc (a, b: PacmanPackageRecord): int = cmp(a.name, b.name))

proc resolveMultiClosure*(roots: seq[string]; index: PacmanIndex;
                          allowUnresolved = false):
    seq[PacmanPackageRecord] =
  var seen = initHashSet[string]()
  for root in roots:
    let perRoot = resolveClosure(root, index, allowUnresolved)
    for rec in perRoot:
      if rec.name notin seen:
        seen.incl(rec.name)
        result.add(rec)
  result.sort(proc (a, b: PacmanPackageRecord): int = cmp(a.name, b.name))
