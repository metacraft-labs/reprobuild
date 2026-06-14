## C2 P2: apt index parsing library.
##
## Parses the RFC 822-style stanzas in the snapshot.debian.org
## ``Packages`` file (post-decompression) into structured records,
## resolves ``Depends:`` / ``Pre-Depends:`` lines into atom trees, and
## walks the transitive closure of a starting package using the standard
## ``Provides:`` / ``Replaces:`` / version-constraint resolution rules.
##
## ## Why this lives in repro_dsl_stdlib/packages/
##
## The C2 ``repro-harvest-apt`` binary, the C3 sandbox-launcher manifest
## generator, and any future audit tooling all need a consistent view of
## the snapshot's Packages index. Keeping the parser next to the
## ``foreign_apt`` DSL surface keeps the data definitions of the
## apt-bundle Tier-3 model in one importable module.
##
## ## Scope
##
## C2 ships only the read path: parse the index, walk the closure,
## yield a sorted list of ``AptPackageRecord``. Emitting an index (e.g.
## for a synthetic mirror) is out of scope and would be added on
## demand.
##
## ## Parser caveats
##
## * The ``Description:`` field is multi-line (subsequent lines start
##   with whitespace per RFC 822 continuation rules); we capture the
##   first line only and skip continuations until the next non-indented
##   key. The full description is not needed for the harvester's
##   dependency walk.
## * ``Depends:`` carries alternatives via ``|`` (e.g. ``foo | bar``).
##   The closure walker picks the first alternative that resolves in
##   the snapshot's index — matching the apt-rdepends + apt-get
##   defaults. A future preferences file could override this.
## * Version-constraint operators (``<<``, ``<=``, ``=``, ``>=``,
##   ``>>``) are parsed but not enforced against the snapshot — every
##   snapshot is internally consistent by construction (a snapshot is
##   a frozen suite), so the constraint check is a redundancy. We carry
##   the operator + version through the AST so a future strict-mode
##   gate could enforce them.

import std/[algorithm, sets, strutils, tables]

type
  AptDependencyOp* = enum
    ## Version-constraint operator from the ``Depends:`` line. C2 carries
    ## but does not enforce these (see module doc).
    adoAny       = "any"     ## no version constraint
    adoLt        = "<<"      ## strictly less than
    adoLe        = "<="
    adoEq        = "="
    adoGe        = ">="
    adoGt        = ">>"      ## strictly greater than

  AptDependencyAtom* = object
    ## One atom of an apt ``Depends:`` clause. The atom names a single
    ## package (real or virtual) with an optional version constraint.
    name*: string                  ## package name as it appears on disk
    op*: AptDependencyOp
    version*: string               ## constraint version, "" when
                                   ## ``op == adoAny``
    architecture*: string          ## optional explicit arch
                                   ## (e.g. ``foo:amd64``)

  AptDependencyClause* = object
    ## A single comma-separated clause from a ``Depends:`` line. The
    ## clause may carry multiple ``|``-joined alternatives; the closure
    ## walker picks the first one that resolves.
    alternatives*: seq[AptDependencyAtom]

  AptPackageRecord* = object
    ## One stanza in the Packages index, normalised. The harvester writes
    ## one catalog file per record reached via the closure walk.
    name*: string                  ## ``Package:`` field
    version*: string               ## ``Version:`` field
    architecture*: string          ## ``Architecture:`` (``amd64``,
                                   ## ``all``, ``arm64``, ...)
    section*: string               ## ``Section:`` field, free-form
    priority*: string              ## ``Priority:`` field
    filename*: string              ## ``Filename:`` field (URL relative
                                   ## to the snapshot's pool root)
    sha256*: string                ## ``SHA256:`` field
    sizeBytes*: int64              ## ``Size:`` field
    depends*: seq[AptDependencyClause]    ## ``Depends:``
    preDepends*: seq[AptDependencyClause] ## ``Pre-Depends:``
    provides*: seq[AptDependencyAtom]     ## ``Provides:``
    replaces*: seq[AptDependencyAtom]     ## ``Replaces:``
    conflicts*: seq[AptDependencyAtom]    ## ``Conflicts:``
    descriptionFirstLine*: string  ## first line of ``Description:``
      ## (rest discarded for parser memory)

  AptIndex* = object
    ## The parsed Packages index. Two lookup tables back the closure
    ## walker:
    ##
    ##   * ``byName``    — real package name → record. ``Provides:``
    ##                     entries do NOT populate this table.
    ##   * ``virtuals``  — virtual package name → seq of real package
    ##                     names that provide it. The closure walker
    ##                     consults this when a ``Depends:`` atom is
    ##                     unknown to ``byName``.
    records*: seq[AptPackageRecord]
    byName*: Table[string, int]
      ## ``byName[<name>]`` is the index into ``records`` (saves a deep
      ## copy when callers want the record back).
    virtuals*: Table[string, seq[string]]
      ## Virtual-package alias map; a single virtual name may be
      ## advertised by several real packages.

  AptIndexParseError* = object of CatchableError
    ## Surface diagnostic for a malformed Packages stanza.
    lineNo*: int
    stanzaName*: string

  AptClosureError* = object of CatchableError
    ## Raised when the closure walker hits a dep it cannot resolve
    ## against the index — neither a real package nor a virtual.
    rootPackage*: string
    missingDep*: string

# ---------------------------------------------------------------------------
# Low-level RFC 822 stanza parser
# ---------------------------------------------------------------------------

proc raiseStanza(msg: string; lineNo = 0; stanzaName = "") {.noreturn.} =
  var e = newException(AptIndexParseError, msg)
  e.lineNo = lineNo
  e.stanzaName = stanzaName
  raise e

proc splitStanzas(content: string): seq[string] =
  ## Split the index into individual stanzas separated by blank lines.
  ## Preserves the line numbering for diagnostics by keeping the
  ## ``\n`` separators inside each stanza.
  var stanza = ""
  for rawLine in content.splitLines:
    let line = rawLine.strip(leading = false, trailing = true,
      chars = {'\r'})
    if line.len == 0:
      if stanza.len > 0:
        result.add(stanza)
        stanza = ""
    else:
      if stanza.len > 0:
        stanza.add('\n')
      stanza.add(line)
  if stanza.len > 0:
    result.add(stanza)

proc parseStanzaFields(stanza: string): OrderedTable[string, string] =
  ## Parse a single stanza into ``key -> value`` pairs. Multi-line
  ## continuations (lines starting with whitespace) are joined into
  ## the previous key's value with a single ``\n`` separator. Field
  ## names are normalised to lowercase for case-insensitive lookup
  ## (RFC 822 says field names are case-insensitive; the Debian indexes
  ## use Capitalized-Hyphen by convention but we should not rely on
  ## casing for correctness).
  result = initOrderedTable[string, string]()
  var currentKey = ""
  for rawLine in stanza.splitLines:
    if rawLine.len == 0:
      continue
    if rawLine[0] in {' ', '\t'}:
      if currentKey.len == 0:
        raiseStanza("continuation line with no preceding field: " &
          rawLine)
      let cont = rawLine.strip(leading = true, trailing = true)
      if result[currentKey].len > 0:
        result[currentKey].add('\n')
      result[currentKey].add(cont)
    else:
      let colon = rawLine.find(':')
      if colon <= 0:
        raiseStanza("missing colon in stanza line: " & rawLine)
      let key = rawLine[0 ..< colon].strip().toLowerAscii()
      let value = rawLine[colon + 1 .. ^1].strip()
      currentKey = key
      result[key] = value

# ---------------------------------------------------------------------------
# Dependency parsing
# ---------------------------------------------------------------------------

proc parseDependencyAtom(token: string): AptDependencyAtom =
  ## Parse a single dependency atom (no ``|`` alternatives).
  ##
  ## Accepted shapes:
  ##   * ``pkg``
  ##   * ``pkg:arch``
  ##   * ``pkg (>= 1.2.3)``
  ##   * ``pkg:arch (>= 1.2.3)``
  ##   * ``pkg (= 1.2.3)``
  let t = token.strip()
  if t.len == 0:
    raiseStanza("empty dependency atom")

  result.op = adoAny

  # Split off the version constraint if present.
  let parenOpen = t.find('(')
  var nameSection = t
  if parenOpen >= 0:
    let parenClose = t.find(')', start = parenOpen + 1)
    if parenClose < 0:
      raiseStanza("unterminated version constraint in dependency: " & t)
    let constraintBody = t[parenOpen + 1 .. parenClose - 1].strip()
    nameSection = t[0 ..< parenOpen].strip()
    # Constraint body is "<op> <version>" — both segments may be
    # whitespace separated.
    var opStr = ""
    var ver = ""
    var idx = 0
    while idx < constraintBody.len and constraintBody[idx] in
        {'<', '>', '=', '!'}:
      opStr.add(constraintBody[idx])
      inc idx
    ver = constraintBody[idx .. ^1].strip()
    case opStr
    of "<<": result.op = adoLt
    of "<=", "<": result.op = adoLe
    of "=": result.op = adoEq
    of ">=", ">": result.op = adoGe
    of ">>": result.op = adoGt
    else:
      raiseStanza("unknown version-constraint operator '" & opStr &
        "' in dependency: " & t)
    result.version = ver

  # Architecture qualifier on the name (``pkg:amd64``).
  let colon = nameSection.find(':')
  if colon >= 0:
    result.name = nameSection[0 ..< colon]
    result.architecture = nameSection[colon + 1 .. ^1]
  else:
    result.name = nameSection
    result.architecture = ""

  if result.name.len == 0:
    raiseStanza("empty package name in dependency: " & t)

proc parseDepends*(line: string): seq[AptDependencyClause] =
  ## Parse a Debian ``Depends:`` / ``Pre-Depends:`` field value.
  ##
  ## Grammar (informal):
  ##   field := clause (',' clause)*
  ##   clause := atom ('|' atom)*
  ##   atom  := name (':' arch)? (' (' op ver ')')?
  ##
  ## Returns one ``AptDependencyClause`` per comma-separated clause;
  ## each clause carries one or more ``|``-joined alternatives.
  ## Whitespace and blank entries are tolerated.
  result = @[]
  if line.len == 0:
    return
  # Flatten newlines (multi-line Depends: values are possible per RFC822
  # continuation).
  var flat = line.replace("\n", " ")
  for raw in flat.split(','):
    let clauseStr = raw.strip()
    if clauseStr.len == 0:
      continue
    var clause = AptDependencyClause()
    for altRaw in clauseStr.split('|'):
      let altStr = altRaw.strip()
      if altStr.len == 0:
        continue
      clause.alternatives.add(parseDependencyAtom(altStr))
    if clause.alternatives.len > 0:
      result.add(clause)

proc parseSimpleAtomList(line: string): seq[AptDependencyAtom] =
  ## Used for ``Provides:`` / ``Replaces:`` / ``Conflicts:``. These use
  ## comma-separated atoms (no ``|`` alternatives).
  result = @[]
  if line.len == 0:
    return
  let flat = line.replace("\n", " ")
  for raw in flat.split(','):
    let s = raw.strip()
    if s.len == 0:
      continue
    result.add(parseDependencyAtom(s))

# ---------------------------------------------------------------------------
# Packages-index parsing
# ---------------------------------------------------------------------------

proc parsePackageRecord(stanza: string): AptPackageRecord =
  let fields = parseStanzaFields(stanza)
  if not fields.hasKey("package"):
    raiseStanza("stanza missing 'Package' field")
  result.name = fields["package"]
  if fields.hasKey("version"):
    result.version = fields["version"]
  if fields.hasKey("architecture"):
    result.architecture = fields["architecture"]
  if fields.hasKey("section"):
    result.section = fields["section"]
  if fields.hasKey("priority"):
    result.priority = fields["priority"]
  if fields.hasKey("filename"):
    result.filename = fields["filename"]
  if fields.hasKey("sha256"):
    result.sha256 = fields["sha256"].toLowerAscii()
  if fields.hasKey("size"):
    try:
      result.sizeBytes = fields["size"].strip().parseBiggestInt.int64
    except ValueError:
      raiseStanza("non-integer Size field for package " & result.name,
        stanzaName = result.name)
  if fields.hasKey("depends"):
    result.depends = parseDepends(fields["depends"])
  if fields.hasKey("pre-depends"):
    result.preDepends = parseDepends(fields["pre-depends"])
  if fields.hasKey("provides"):
    result.provides = parseSimpleAtomList(fields["provides"])
  if fields.hasKey("replaces"):
    result.replaces = parseSimpleAtomList(fields["replaces"])
  if fields.hasKey("conflicts"):
    result.conflicts = parseSimpleAtomList(fields["conflicts"])
  if fields.hasKey("description"):
    let d = fields["description"]
    let nl = d.find('\n')
    if nl < 0:
      result.descriptionFirstLine = d
    else:
      result.descriptionFirstLine = d[0 ..< nl]

proc parsePackagesIndex*(content: string): seq[AptPackageRecord] =
  ## Public entry point. Parses every stanza in the index and returns
  ## the records in input order. Use ``buildAptIndex`` to obtain the
  ## name-keyed + virtual-aliased ``AptIndex`` structure ready for the
  ## closure walker.
  result = @[]
  for stanza in splitStanzas(content):
    result.add(parsePackageRecord(stanza))

proc buildAptIndex*(records: sink seq[AptPackageRecord]): AptIndex =
  ## Build the name + virtuals lookup tables. Idempotent: re-running
  ## with the same input yields a byte-identical index.
  result.records = records
  result.byName = initTable[string, int]()
  result.virtuals = initTable[string, seq[string]]()
  for i, rec in result.records:
    # Some Packages indexes contain duplicate stanzas for a single
    # architecture's promotion path (rare on Debian's main archive;
    # common on testing/unstable). Last writer wins, matching apt's
    # actual behaviour.
    result.byName[rec.name] = i
    for prov in rec.provides:
      if prov.name notin result.virtuals:
        result.virtuals[prov.name] = @[]
      result.virtuals[prov.name].add(rec.name)

# ---------------------------------------------------------------------------
# Closure walker
# ---------------------------------------------------------------------------

proc resolveAtom(index: AptIndex; atomName: string): string =
  ## Map a dependency atom name to a real package name in the index.
  ## Returns "" when the atom cannot be resolved (caller decides how to
  ## react; the closure walker uses this for the missing-dep error).
  if atomName in index.byName:
    return atomName
  if atomName in index.virtuals:
    let provs = index.virtuals[atomName]
    if provs.len > 0:
      # apt picks the alphabetically-first provider when several real
      # packages advertise the same virtual; this is also what
      # ``apt-rdepends`` and ``apt-cache showpkg`` print. The
      # ``provides`` arrays we built are insertion-order; sort here for
      # determinism.
      var sorted = provs
      sorted.sort(cmp)
      return sorted[0]
  ""

proc resolveClause(index: AptIndex;
                   clause: AptDependencyClause): string =
  ## Pick the first alternative that resolves. Returns "" if no
  ## alternative resolves.
  for alt in clause.alternatives:
    let r = resolveAtom(index, alt.name)
    if r.len > 0:
      return r
  ""

proc resolveClosure*(root: string; index: AptIndex;
                     allowUnresolved = false): seq[AptPackageRecord] =
  ## Walk the transitive ``Depends:`` + ``Pre-Depends:`` closure of
  ## ``root`` (a real package name) in the index and return every
  ## reachable record. The result is sorted alphabetically by name so
  ## downstream emitters get byte-stable output.
  ##
  ## ``allowUnresolved`` toggles the missing-dep policy: when ``true``,
  ## an unresolvable atom is silently dropped and the walk continues;
  ## when ``false`` (default), the walker raises ``AptClosureError`` so
  ## the harvester refuses to produce a partial catalog.
  if root notin index.byName:
    var e = newException(AptClosureError,
      "package '" & root & "' not in apt index")
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
    # Walk both Depends + Pre-Depends.
    for clauseSeq in [rec.depends, rec.preDepends]:
      for clause in clauseSeq:
        let resolved = resolveClause(index, clause)
        if resolved.len == 0:
          if allowUnresolved:
            continue
          var e = newException(AptClosureError,
            "dependency '" & clause.alternatives[0].name &
            "' of package '" & name & "' (root '" & root &
            "') is not in apt index")
          e.rootPackage = root
          e.missingDep = clause.alternatives[0].name
          raise e
        if resolved notin visited:
          queue.add(resolved)

  result.sort(proc (a, b: AptPackageRecord): int = cmp(a.name, b.name))

proc resolveMultiClosure*(roots: seq[string]; index: AptIndex;
                          allowUnresolved = false):
    seq[AptPackageRecord] =
  ## Multi-root closure: union of every per-root closure with no
  ## duplicates. Same sort + error policy as ``resolveClosure``.
  var seen = initHashSet[string]()
  for root in roots:
    let perRoot = resolveClosure(root, index, allowUnresolved)
    for rec in perRoot:
      if rec.name notin seen:
        seen.incl(rec.name)
        result.add(rec)
  result.sort(proc (a, b: AptPackageRecord): int = cmp(a.name, b.name))
