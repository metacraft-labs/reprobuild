## The locked catalog import -- ReproOS-Campaign-Completion M6 deliverable 1,
## normatively specified by ``reprobuild-specs/Federated-Catalog-Imports.md``
## § Pinning.
##
## A consumer declares the catalogs it imports in ``repro-catalogs.toml``,
## and may name a catalog by a moving ``ref``. The committed ``repro.lock``
## pins every declared import to ONE exact revision and the interface-artifact
## identity read at it:
##
##   catalog_imports = [{ record = "reprobuild.locked-catalog-import.v1",
##     repo = "...", remote = "...", ref = "...", revision = "<full hex>",
##     interface_artifact = "<64 hex>" }]
##
## ## Where it lives, and why it mirrors ``provisioning``
##
## One more array in the EXISTING committed lock (schema
## ``reprobuild.solved-graph-lock.v2``) under the ``[lock]`` table, written
## ONLY when non-empty, so every lock that exists today re-serialises
## byte-identically -- the discipline ``repro_lock/provisioning`` applies to
## its own records. The record imports ``std`` only, for the same reason.
##
## ## Strict, canonical, refuse-never-truncate
##
## Every field is required. ``revision`` must be a full-width lower-case
## object id (40 or 64 hex): a branch name or an abbreviated id names a set
## of commits, not one, and is refused on write and on read. ``ref`` is the
## ADVISORY moving reference the declaration named (empty when it named a
## commit); it never selects anything at build time. ``repo`` and ``remote``
## refuse a local path, a ``file:`` URL and a drive letter
## (``provisioning.localPathDefect``): a lock is committed and read on other
## hosts; ``remote`` also refuses a spelling whose host depends on who parses
## it (``remoteShapeDefect``). Records are sorted by ``repo``, which is the uniqueness key; two
## records for one repo, or for one remote, refuse. The reader accepts only
## the bytes the writer produces.
##
## ## No seal
##
## Unlike a provisioning record, an import pin carries no fingerprint that
## needs evidence: it is verified against the CATALOG on every use (the
## identity read at ``revision`` must equal ``interface_artifact``), so a
## hand-edited pin is either a consistent pin of another commit -- the same
## as editing the lock deliberately -- or refused when it is read.

import std/[algorithm, strutils]

import ./provisioning

const
  LockedCatalogImportRecordV1* = "reprobuild.locked-catalog-import.v1"
    ## The per-record version tag. The reader refuses any other value.

  CatalogImportsLockKey* = "catalog_imports"
    ## The key of the record array inside the committed lock's ``[lock]``
    ## table.

type
  LockedCatalogImport* = object
    ## One pinned catalog import. Every field is required except ``gitRef``,
    ## which is empty when the declaration named a commit.
    repo*: string              ## the repository's workspace name.
    remote*: string            ## the repository's fetch URL (an identity).
    gitRef*: string            ## advisory: the declared moving reference.
    revision*: string          ## full-width: 40 or 64 lower-case hex.
    interfaceArtifact*: string ## 64 lower-case hex.

  LockedCatalogImportError* = object of CatchableError
    ## A catalog import pin refused on write or on read.

const ImportFieldOrder = ["record", "repo", "remote", "ref", "revision",
  "interface_artifact"]

proc isLowerHex(value: string; width: int): bool =
  if value.len != width:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc isFullRevision*(value: string): bool =
  ## A full-width lower-case object id: 40 (SHA-1) or 64 (SHA-256) hex.
  isLowerHex(value, 40) or isLowerHex(value, 64)

proc refDefect*(value: string): string =
  ## Why ``value`` is not an acceptable moving reference (a branch or tag
  ## name); empty when it is. Stricter than git (a false refusal is safe):
  ## a ref must not be something a reader could mistake for a commit, a
  ## revision expression, an option, or a path outside ``refs/``.
  if value.len == 0:
    return "is empty"
  # Whitespace is refused by the character check below (a space, or a
  # control character), so it needs no check of its own.
  if isFullRevision(value.toLowerAscii()):
    return "is a full-width object id; name a commit with `commit`, not `ref`"
  if value[0] in {'-', '/', '.'} or value[^1] in {'/', '.'}:
    return "starts with '-', '/' or '.', or ends with '/' or '.'"
  if ".." in value or "@{" in value or "//" in value or value == "@" or
      value.endsWith(".lock") or "/." in value:
    return "contains '..', '@{', '//' or '/.', is '@', or ends in '.lock'"
  for ch in value:
    if ord(ch) < 0x20 or ord(ch) == 0x7f or
        ch in {' ', '~', '^', ':', '?', '*', '[', '\\'}:
      return "contains a character git does not allow in a ref name: " &
        escape($ch)
  ""

proc remoteShapeDefect*(value: string): string =
  ## Why ``value`` is not a remote whose repository every reader of it
  ## agrees on; empty when it is. Applied to a declared remote, a pinned
  ## remote and the URL a shared clone says it was cloned from.
  ##
  ## The identity check (``shared_clones.canonicalRemoteIdentity``) takes the
  ## host to follow the FIRST ``@`` before the first ``/``; curl ends the
  ## authority at a ``?`` or ``#`` and git turns ``\`` into ``/``. So
  ## ``https://evil?@host/o/r`` has the identity of ``host/o/r`` and is
  ## fetched from ``evil`` (measured with ``git ls-remote``) -- and so a
  ## remote with any of those characters, whitespace, a control character,
  ## a second ``@``, or (scp-like, without ``://``) an ``@`` that does not
  ## precede the host's ``:`` refuses. Stricter than git; a false refusal is
  ## the safe side.
  for ch in value:
    if ord(ch) <= 0x20 or ord(ch) == 0x7f or ch in {'?', '#', '\\'}:
      return "contains whitespace, a control character, '?', '#' or a " &
        "backslash, which make the host it names depend on who parses it"
  let ats = value.count('@')
  if ats > 1:
    return "contains more than one '@', which makes the host it names " &
      "depend on who parses it"
  if ats == 1 and "://" notin value:
    let colon = value.find(':')
    if colon < 0 or value.find('@') > colon:
      return "is neither a URL (`scheme://host/path`) nor an scp-like " &
        "`user@host:path`"
  ""

proc nameDefect(value: string): string =
  if value.strip().len == 0:
    return "empty"
  if value != value.strip():
    return "has leading or trailing whitespace"
  ""

proc catalogImportDefects*(r: LockedCatalogImport): seq[string] =
  ## Every field whose value is missing or malformed, as
  ## ``field <name>: <problem>``. Applied on write and on read.
  template defect(name, problem: string) =
    result.add("field " & name & ": " & problem)
  block:
    var d = nameDefect(r.repo)
    if d.len == 0: d = localPathDefect(r.repo)
    if d.len > 0: defect("repo", d)
  block:
    var d = nameDefect(r.remote)
    if d.len == 0: d = localPathDefect(r.remote)
    if d.len == 0: d = remoteShapeDefect(r.remote)
    if d.len > 0: defect("remote", d)
  if r.gitRef.len > 0:
    let d = refDefect(r.gitRef)
    if d.len > 0: defect("ref", d)
  if not isFullRevision(r.revision):
    defect("revision", "not a full-width revision (40 or 64 lower-case " &
      "hex): \"" & r.revision & "\"")
  if not isLowerHex(r.interfaceArtifact, 64):
    defect("interface_artifact", "not a 64 lower-case hex interface-artifact " &
      "identity: \"" & r.interfaceArtifact & "\"")

proc tomlEscape(s: string): string =
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)

proc canonicalCatalogImportEntry*(r: LockedCatalogImport): string =
  ## One record as its canonical inline table, fields in one fixed order.
  let values = [LockedCatalogImportRecordV1, r.repo, r.remote, r.gitRef,
    r.revision, r.interfaceArtifact]
  result = "{ "
  for i, name in ImportFieldOrder:
    if i > 0: result.add(", ")
    result.add(name & " = \"" & tomlEscape(values[i]) & "\"")
  result.add(" }")

proc serializeCatalogImports*(records: seq[LockedCatalogImport]): string =
  ## The canonical right-hand side of the ``catalog_imports`` key. Refuses
  ## a malformed record, two records for one repo, and two for one remote.
  ## The CALLER omits the key when ``records`` is empty.
  if records.len == 0:
    raise newException(LockedCatalogImportError,
      "catalog_imports: an empty array is never written (a lock without " &
      "catalog imports omits the key)")
  var sorted = records
  sorted.sort(proc (a, b: LockedCatalogImport): int = cmp(a.repo, b.repo))
  var remotes: seq[string] = @[]
  result = "["
  for i, r in sorted:
    let defects = catalogImportDefects(r)
    if defects.len > 0:
      raise newException(LockedCatalogImportError,
        "catalog import \"" & r.repo & "\": " & defects.join("; "))
    if i > 0:
      if sorted[i - 1].repo == r.repo:
        raise newException(LockedCatalogImportError,
          "two catalog imports are pinned for repo \"" & r.repo &
          "\"; a lock pins each import exactly once")
      result.add(", ")
    if r.remote in remotes:
      raise newException(LockedCatalogImportError,
        "two catalog imports are pinned for remote \"" & r.remote &
        "\"; one remote is one catalog")
    remotes.add(r.remote)
    result.add(canonicalCatalogImportEntry(r))
  result.add("]")

proc parseError(message: string) {.noreturn.} =
  raise newException(LockedCatalogImportError, message)

proc parseCatalogImports*(rhs: string): seq[LockedCatalogImport] =
  ## Parse the right-hand side of the ``catalog_imports`` key. Strict: every
  ## entry carries exactly the v1 fields, each once and well formed, and the
  ## array is the canonical bytes the writer produces. Anything else --
  ## including an empty or truncated array -- raises
  ## ``LockedCatalogImportError``.
  let s = rhs.strip()
  var pos = 0

  proc skipSpaces() =
    while pos < s.len and s[pos] in {' ', '\t'}: inc pos

  proc expect(ch: char; what: string) =
    skipSpaces()
    if pos >= s.len:
      parseError("catalog_imports: truncated; expected " & what)
    if s[pos] != ch:
      parseError("catalog_imports: expected " & what & " at byte " & $pos)
    inc pos

  proc readValue(): string =
    while true:
      if pos >= s.len:
        parseError("catalog_imports: truncated inside a quoted value")
      let ch = s[pos]
      if ch == '"':
        inc pos
        return
      if ch == '\\':
        if pos + 1 >= s.len:
          parseError("catalog_imports: truncated inside an escape")
        case s[pos + 1]
        of '\\': result.add('\\')
        of '"': result.add('"')
        of 'n': result.add('\n')
        of 'r': result.add('\r')
        of 't': result.add('\t')
        else: parseError("catalog_imports: unknown escape \\" & s[pos + 1])
        pos += 2
      else:
        result.add(ch)
        inc pos

  var entries: seq[seq[(string, string)]] = @[]
  expect('[', "'['")
  skipSpaces()
  if pos < s.len and s[pos] == ']':
    parseError("catalog_imports: an empty array is never written (a lock " &
      "without catalog imports omits the key)")
  while true:
    expect('{', "'{'")
    var pairs: seq[(string, string)] = @[]
    while true:
      skipSpaces()
      var key = ""
      while pos < s.len and s[pos] in {'a'..'z', '_'}:
        key.add(s[pos]); inc pos
      if key.len == 0:
        if pos >= s.len: parseError("catalog_imports: truncated; expected a key")
        parseError("catalog_imports: expected a key at byte " & $pos)
      expect('=', "'='")
      expect('"', "a quoted value")
      pairs.add((key, readValue()))
      skipSpaces()
      if pos >= s.len:
        parseError("catalog_imports: truncated; expected ',' or '}'")
      if s[pos] == ',':
        inc pos
      elif s[pos] == '}':
        inc pos
        break
      else:
        parseError("catalog_imports: expected ',' or '}' at byte " & $pos)
    entries.add(pairs)
    skipSpaces()
    if pos >= s.len: parseError("catalog_imports: truncated; expected ',' or ']'")
    if s[pos] == ',':
      inc pos
    elif s[pos] == ']':
      inc pos
      break
    else:
      parseError("catalog_imports: expected ',' or ']' at byte " & $pos)
  skipSpaces()
  if pos != s.len:
    parseError("catalog_imports: unexpected bytes after the array at byte " &
      $pos)

  for n, pairs in entries:
    let where = "catalog_imports entry " & $n & ": "
    var values: array[ImportFieldOrder.len, string]
    var seen: array[ImportFieldOrder.len, bool]
    for (key, value) in pairs:
      let index = ImportFieldOrder.find(key)
      if index < 0:
        parseError(where & "unknown field " & key)
      if seen[index]:
        parseError(where & "duplicate field " & key)
      seen[index] = true
      values[index] = value
    for index, name in ImportFieldOrder:
      if not seen[index]:
        parseError(where & "missing field " & name)
    if values[0] != LockedCatalogImportRecordV1:
      parseError(where & "unsupported record version \"" & values[0] &
        "\" (this reader accepts " & LockedCatalogImportRecordV1 & ")")
    let r = LockedCatalogImport(repo: values[1], remote: values[2],
      gitRef: values[3], revision: values[4], interfaceArtifact: values[5])
    let defects = catalogImportDefects(r)
    if defects.len > 0:
      parseError(where & defects.join("; "))
    result.add(r)

  var canonical = ""
  try:
    canonical = serializeCatalogImports(result)
  except LockedCatalogImportError as err:
    parseError(err.msg)
  if canonical != s:
    parseError("catalog_imports: not the canonical encoding (field order, " &
      "record order, spacing or escaping differs from what the lock writer " &
      "produces); regenerate the pins with `repro lock refresh " &
      "--provisioning`")
