## Explicit catalog imports and what a catalog publishes -- ReproOS-Campaign-
## Completion M6 deliverables 1 and 2, normatively specified by
## ``reprobuild-specs/Federated-Catalog-Imports.md``.
##
## This module is the PURE half of federated catalog discovery: it reads
## bytes it is handed and touches no filesystem, no process and no
## environment. The other half -- reading a catalog's objects at a pinned
## revision out of the workspace's shared clone, re-hashing every object on
## the way -- is ``repro_cli_support/catalog_discovery``.
##
## ## The declaration (``repro-catalogs.toml``)
##
## ``parseCatalogImportsDeclaration`` reads the consumer's declaration. The
## file is TOML, and the reader accepts a CLOSED subset of it (UTF-8 text;
## comments without a control character other than tab, blank lines, the
## top-level ``schema`` key, ``[[import]]`` / ``[[policy]]`` headers and
## ``key = "basic string"`` lines with the ``\\`` and ``\"`` escapes) and
## refuses everything else: the declaration is read on every
## lock-governed build, and a construct a lenient reader skipped would
## silently drop an import. Every refusal is collected, not just the first.
##
## An import names its catalog by ``repo`` (the coordinate's ``workspace``:
## the repository's workspace name), ``remote`` (its fetch URL -- an
## identity, never a local path, naming one host whoever parses it:
## ``remoteShapeDefect``) and EXACTLY ONE of ``commit`` (a full-width
## object id; a branch name or an abbreviated id refuses) and ``ref`` (a
## moving branch or tag name, which only the lock may pin). Neither the
## import's position in the file nor any directory name is an input.
##
## An import may name its ``kind`` (``provisioning``, the default, or
## ``nimble-index``): what the catalog publishes and what its identity
## means (Federated-Catalog-Imports.md § Catalog kinds). Any other value is
## refused, naming the line it is on: read as the default, a Nimble index
## would be looked for as a provisioning catalog (threat model G21).
##
## A ``[[policy]]`` is a curator policy (``package``, ``contributor``) or a
## Nimble acceptance (``package = "nimble:<name>"``, ``repo`` naming a
## ``nimble-index`` import, and exactly one of ``origin`` -- with
## ``revived`` for a revival entry -- and ``target``): the project's
## committed choice of a repointed or revived origin, or of a retargeted
## alias's new target, that the solve would not take on its own
## (Nimble-Package-Catalog NPC-AREQ16). A table mixing the two forms is
## refused.
##
## ## What a catalog publishes
##
## ``publishedCatalogContent`` turns the decoded ``published-interfaces/*.rbsz``
## artifacts of one catalog revision into ``CatalogContent``. The role of an
## artifact is decided by its content -- no contributions: a canonical
## interface; contributions: a contribution set -- so the interface-artifact
## identity (``catalogArtifactIdentity``, which binds every artifact's
## semantic fingerprint) determines the content completely. A record that is
## ``imported`` (re-exported from another catalog) or ``developInterface``
## (forbidden in a published snapshot) refuses, and so does an artifact whose
## stored fingerprint is not the one the current codec computes.
##
## ## The provider identity
##
## ``catalogProviderIdentity`` is the ``providerIdentity`` M7's contribution
## fingerprint needs and an interface artifact does not carry: a domain-
## separated digest of the catalog revision's ROOT TREE object id. A commit's
## root tree is the content identity of the catalog's entire source tree,
## which contains the provider implementation, and it is read out of the
## (re-hashed) commit object without running anything. It over-binds -- any
## change to any file of the catalog moves every fingerprint it publishes --
## which is the safe side. It does not bind code OUTSIDE the catalog
## repository that the provider imports; that limit is stated in the spec.

import std/[algorithm, options, sequtils, strutils, times]
from std/unicode import validateUtf8

import repro_hash
import repro_lock/catalog_imports
import repro_lock/provisioning

import ../repro_interface_artifacts
import ./catalog_composition
import ./contribution_fingerprint

const
  CatalogImportsSchemaV1* = "reprobuild.catalog-imports.v1"
    ## The ``schema`` value of a ``repro-catalogs.toml`` this reader accepts.

  CatalogImportsFileName* = "repro-catalogs.toml"
    ## The declaration's file name, in the consumer's project root.

  PublishedInterfacesDir* = "published-interfaces"
    ## The directory, at a catalog repository's root, holding its published
    ## interface artifacts.

  PublishedIndexDir* = "published-index"
    ## The directory, at the root of a ``nimble-index`` catalog, holding the
    ## index: its ``root`` and ``objects/<id>``.

  PublishedArtifactSuffix* = ".rbsz"

  CatalogProviderIdentityMagic* = "reprobuild.catalog-provider-identity.v1"
    ## Domain magic of ``catalogProviderIdentity``.

type
  CatalogImportDeclaration* = object
    ## One ``[[import]]`` table. Exactly one of ``commit`` and ``gitRef`` is
    ## non-empty in a declaration ``parseCatalogImportsDeclaration`` returns.
    repo*: string
    remote*: string
    commit*: string             ## lower-cased full-width object id, or "".
    gitRef*: string             ## the declared moving reference, or "".
    interfaceArtifact*: string  ## lower-cased 64-hex assertion, or "".
    kind*: CatalogImportKind    ## what it publishes; default provisioning.
    line*: int                  ## where the table starts (diagnostics only).

  CatalogPolicyDeclaration* = object
    ## One ``[[policy]]`` table and the line it starts on. DIAGNOSTICS ONLY
    ## (M6 deliverable 4: a refusal names the table to edit); never a
    ## selection input.
    package*: string
    contributor*: string
    line*: int

  NimbleAcceptanceDeclaration* = object
    ## One ``[[policy]]`` table that accepts, for a ``nimble:`` package read
    ## through the ``nimble-index`` import ``repo``, a source the pinned
    ## index records but the solve would not take on its own
    ## (Nimble-Package-Catalog NPC-AREQ16): a repointed or revived origin
    ## (``origin``, with ``revived`` naming a revival entry), or a
    ## retargeted alias's new target (``target``). Exactly one of ``origin``
    ## and ``target`` is non-empty. Never a provisioning selection rule.
    package*: string   ## the Nimble name, without `nimble:`
    repo*: string      ## the `nimble-index` import it reads
    origin*: string    ## the accepted origin URL (`?subdir=` kept), or ""
    revived*: string
      ## the revival entry's time as written (`YYYY-MM-DDTHH:MM:SSZ`), or ""
      ## for the origin as the registry named it
    revivedAt*: int64  ## ``revived`` as Unix seconds; 0 when ""
    target*: string    ## the accepted alias target, without `nimble:`, or ""
    line*: int         ## where the table starts

  CatalogImportsDeclaration* = object
    imports*: seq[CatalogImportDeclaration]
      ## Sorted by ``repo``: declaration order is not an input.
    policy*: CatalogSelectionPolicy
      ## The ``[[policy]]`` rules. Their order is not an input either
      ## (``composeCatalogs`` folds them into a map and refuses a
      ## contradiction).
    nimbleAcceptances*: seq[NimbleAcceptanceDeclaration]
      ## The ``[[policy]]`` tables that accept a Nimble source, sorted by
      ## (repo, package). They are not ``policy`` rules: a Nimble name is
      ## resolved through its index, not composed from contributions.

  CatalogDeclarationError* = object of ValueError
    ## The declaration cannot be read; the message names every cause.

  PublishedArtifact* = object
    ## One decoded artifact read from a catalog's ``published-interfaces``.
    path*: string        ## repository-relative, for diagnostics only.
    artifact*: ProjectInterfaceArtifact

# ---------------------------------------------------------------------------
# The declaration
# ---------------------------------------------------------------------------

proc isHexOf(value: string; width: int): bool =
  value.len == width and value.allIt(it in {'0'..'9', 'a'..'f', 'A'..'F'})

proc parseCatalogImportsDeclaration*(text, path: string;
    policyTables: var seq[CatalogPolicyDeclaration]):
    CatalogImportsDeclaration =
  ## Read a ``repro-catalogs.toml`` (see the module docstring). Raises
  ## ``CatalogDeclarationError`` naming EVERY cause; never returns a
  ## partially read declaration. ``policyTables`` receives every
  ## ``[[policy]]`` table with its line, sorted by (package, contributor,
  ## line) -- for diagnostics only.
  policyTables = @[]
  var errors: seq[string] = @[]
  template fail(lineNo: int; message: string) =
    errors.add(path & ":" & $lineNo & ": " & message)

  if text.startsWith("\xEF\xBB\xBF"):
    raise newException(CatalogDeclarationError, path & ": starts with a " &
      "byte-order mark, which this reader does not accept; save it as " &
      "plain UTF-8")
  let badUtf8 = validateUtf8(text)
  if badUtf8 >= 0:
    raise newException(CatalogDeclarationError, path & ": is not valid " &
      "UTF-8 (byte " & $badUtf8 & "); TOML is UTF-8")

  proc commentDefect(comment: string): bool =
    ## TOML permits no control character but tab in a comment. A lone
    ## carriage return is one: an editor may show the text after it as a
    ## line of its own -- an ``interface_artifact`` assertion, say -- which
    ## this reader, like every TOML reader, would never see.
    for ch in comment:
      if (ord(ch) < 0x20 and ch != '\t') or ord(ch) == 0x7f:
        return true
    false

  type Section = enum sTop, sImport, sPolicy
  var section = sTop
  var schema = ""
  var sawSchema = false
  var imports: seq[(int, seq[(string, string)])] = @[]
  var kindLines: seq[int] = @[]
    ## per import: the line of its ``kind`` key, or 0
  var policies: seq[(int, seq[(string, string)])] = @[]
  var lineNo = 0
  for rawLine in text.split('\n'):
    inc lineNo
    var line = rawLine
    if line.endsWith("\r"):
      line.setLen(line.len - 1)
    line = line.strip(chars = {' ', '\t'})
    if line.len == 0:
      continue
    if line.startsWith("#"):
      if commentDefect(line):
        fail(lineNo, "a comment contains a control character (TOML " &
          "permits none but tab; a lone carriage return is one)")
      continue
    if line.startsWith("["):
      case line
      of "[[import]]":
        section = sImport
        imports.add((lineNo, newSeq[(string, string)]()))
        kindLines.add(0)
      of "[[policy]]":
        section = sPolicy
        policies.add((lineNo, newSeq[(string, string)]()))
      else:
        fail(lineNo, "unsupported table header " & line.escape() &
          " (only [[import]] and [[policy]] are read)")
        section = sTop
      continue
    # key = "basic string" [# comment]
    var pos = 0
    var key = ""
    while pos < line.len and line[pos] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      key.add(line[pos]); inc pos
    if key.len == 0:
      fail(lineNo, "expected `key = \"value\"`: " & line.escape())
      continue
    while pos < line.len and line[pos] in {' ', '\t'}: inc pos
    if pos >= line.len or line[pos] != '=':
      fail(lineNo, "expected `=` after key " & key.escape() &
        " (dotted, quoted and bare-without-value keys are not read)")
      continue
    inc pos
    while pos < line.len and line[pos] in {' ', '\t'}: inc pos
    if pos >= line.len or line[pos] != '"' or
        (pos + 2 < line.len and line[pos + 1] == '"' and line[pos + 2] == '"'):
      fail(lineNo, "the value of " & key.escape() & " must be a basic " &
        "\"string\" (arrays, inline tables, numbers, literal and multi-line " &
        "strings are not read)")
      continue
    inc pos
    var value = ""
    var closed = false
    var bad = ""
    while pos < line.len:
      let ch = line[pos]
      if ch == '"':
        closed = true
        inc pos
        break
      if ch == '\\':
        if pos + 1 < line.len and line[pos + 1] in {'\\', '"'}:
          value.add(line[pos + 1])
          pos += 2
          continue
        bad = "an escape other than \\\\ or \\\""
        break
      if ord(ch) < 0x20 or ord(ch) == 0x7f:
        bad = "a control character"
        break
      value.add(ch)
      inc pos
    if bad.len > 0:
      fail(lineNo, "the value of " & key.escape() & " contains " & bad)
      continue
    if not closed:
      fail(lineNo, "the value of " & key.escape() & " is not terminated")
      continue
    while pos < line.len and line[pos] in {' ', '\t'}: inc pos
    if pos < line.len and line[pos] != '#':
      fail(lineNo, "unexpected text after the value of " & key.escape())
      continue
    if pos < line.len and commentDefect(line[pos .. ^1]):
      fail(lineNo, "the comment after the value of " & key.escape() &
        " contains a control character (TOML permits none but tab; a " &
        "lone carriage return is one)")
      continue
    case section
    of sTop:
      if key != "schema":
        fail(lineNo, "unknown top-level key " & key.escape() &
          " (only `schema` precedes the tables)")
      elif sawSchema:
        fail(lineNo, "duplicate key \"schema\"")
      else:
        sawSchema = true
        schema = value
    of sImport:
      imports[^1][1].add((key, value))
      if key == "kind" and kindLines[^1] == 0:
        kindLines[^1] = lineNo
    of sPolicy:
      policies[^1][1].add((key, value))

  if not sawSchema:
    errors.add(path & ": missing `schema = \"" & CatalogImportsSchemaV1 & "\"`")
  elif schema != CatalogImportsSchemaV1:
    errors.add(path & ": unsupported schema \"" & schema & "\" (this reader " &
      "accepts " & CatalogImportsSchemaV1 & ")")

  proc fields(at: int; pairs: seq[(string, string)]; allowed: openArray[string];
              what: string): seq[(string, string)] =
    var seen: seq[string] = @[]
    for (k, v) in pairs:
      if k notin allowed:
        fail(at, "unknown key " & k.escape() & " in [[" & what & "]] (" &
          "accepted: " & allowed.join(", ") & ")")
        continue
      if k in seen:
        fail(at, "duplicate key " & k.escape() & " in [[" & what & "]]")
        continue
      seen.add(k)
      result.add((k, v))

  proc valueOf(pairs: seq[(string, string)]; k: string): string =
    for (key, value) in pairs:
      if key == k: return value
    ""

  proc hasKey(pairs: seq[(string, string)]; k: string): bool =
    pairs.anyIt(it[0] == k)

  proc nameProblem(value: string): string =
    if value.strip().len == 0: return "is empty"
    if value != value.strip(): return "has leading or trailing whitespace"
    localPathDefect(value)

  var declared: seq[CatalogImportDeclaration] = @[]
  for n, (at, raw) in imports:
    let pairs = fields(at, raw,
      ["repo", "remote", "kind", "commit", "ref", "interface_artifact"],
      "import")
    var d = CatalogImportDeclaration(line: at)
    for required in ["repo", "remote"]:
      if not pairs.hasKey(required):
        fail(at, "[[import]] is missing `" & required & "`")
    d.repo = pairs.valueOf("repo")
    d.remote = pairs.valueOf("remote")
    if pairs.hasKey("kind"):
      let k = pairs.valueOf("kind")
      if not parseCatalogImportKind(k, d.kind):
        # The key's own line: the line to edit.
        fail(kindLines[n], "unknown kind " & k.escape() & " of [[import]] " &
          d.repo.escape() & " (known kinds: " & catalogImportKindNames() &
          "); an unknown kind is never read as the default")
    if pairs.hasKey("repo"):
      let p = nameProblem(d.repo)
      if p.len > 0: fail(at, "repo " & d.repo.escape() & " " & p)
    if pairs.hasKey("remote"):
      var p = nameProblem(d.remote)
      if p.len == 0: p = remoteShapeDefect(d.remote)
      if p.len > 0:
        fail(at, "remote " & d.remote.escape() & " " & p & " (a remote is " &
          "the repository's fetch URL, an identity -- never a location on " &
          "this host)")
    let hasCommit = pairs.hasKey("commit")
    let hasRef = pairs.hasKey("ref")
    if hasCommit == hasRef:
      fail(at, "[[import]] " & d.repo.escape() & " must name exactly one of " &
        "`commit` (an exact, full-width commit id) and `ref` (a moving " &
        "branch or tag the lock pins)")
    if hasCommit:
      let c = pairs.valueOf("commit")
      if not (isHexOf(c, 40) or isHexOf(c, 64)):
        fail(at, "commit " & c.escape() & " of [[import]] " & d.repo.escape() &
          " is not a full-width commit id (40 or 64 hex digits); a branch " &
          "or tag name goes in `ref`, and an abbreviated id names a set of " &
          "commits, not one")
      else:
        d.commit = c.toLowerAscii()
    if hasRef:
      let r = pairs.valueOf("ref")
      let p = refDefect(r)
      if p.len > 0:
        fail(at, "ref " & r.escape() & " of [[import]] " & d.repo.escape() &
          " " & p)
      else:
        d.gitRef = r
    if pairs.hasKey("interface_artifact"):
      let a = pairs.valueOf("interface_artifact")
      if not isHexOf(a, 64):
        fail(at, "interface_artifact " & a.escape() & " of [[import]] " &
          d.repo.escape() & " is not a 64-hex interface-artifact identity")
      else:
        d.interfaceArtifact = a.toLowerAscii()
    declared.add(d)

  var repos, remotes: seq[string] = @[]
  for d in declared:
    if d.repo.len > 0:
      if d.repo in repos:
        fail(d.line, "repo " & d.repo.escape() & " is imported twice; one " &
          "repository is one catalog import")
      repos.add(d.repo)
    if d.remote.len > 0:
      if d.remote in remotes:
        fail(d.line, "remote " & d.remote.escape() & " is imported twice; " &
          "one remote is one catalog import")
      remotes.add(d.remote)

  const NimbleAcceptanceKeys = ["package", "repo", "origin", "revived",
    "target"]
  proc nimbleKey(name: string): string =
    ## NPC-AREQ3's name key: ASCII case folded, underscores removed.
    for c in name:
      if c != '_': result.add toLowerAscii(c)

  var rules: seq[CatalogSelectionRule] = @[]
  var acceptances: seq[NimbleAcceptanceDeclaration] = @[]
  for (at, raw) in policies:
    if raw.anyIt(it[0] in ["repo", "origin", "revived", "target"]):
      # A Nimble acceptance (NPC-AREQ16): `package = "nimble:<name>"`, the
      # import it reads, and the origin or alias target it accepts.
      if raw.anyIt(it[0] == "contributor"):
        fail(at, "[[policy]] names both a `contributor` (a provisioning " &
          "policy) and a Nimble acceptance key (`repo`, `origin`, " &
          "`revived`, `target`); a table is one or the other")
        continue
      let pairs = fields(at, raw, NimbleAcceptanceKeys, "policy")
      var a = NimbleAcceptanceDeclaration(line: at)
      for required in ["package", "repo"]:
        if not pairs.hasKey(required):
          fail(at, "[[policy]] accepting a Nimble source is missing `" &
            required & "`")
      let package = pairs.valueOf("package")
      if pairs.hasKey("package"):
        if not package.startsWith("nimble:") or package.len == 7 or
            nameProblem(package).len > 0:
          fail(at, "policy package " & package.escape() & " is not a " &
            "`nimble:<name>` package; only a Nimble package's origin or " &
            "alias target is accepted this way")
        else:
          a.package = package[7 .. ^1]
      a.repo = pairs.valueOf("repo")
      if pairs.hasKey("repo"):
        var isIndex = false
        for d in declared:
          if d.repo == a.repo and d.kind == cikNimbleIndex: isIndex = true
        if not isIndex:
          fail(at, "policy repo " & a.repo.escape() & " is not a " &
            "`nimble-index` [[import]] of this file; name the import the " &
            "package is read through")
      let hasOrigin = pairs.hasKey("origin")
      let hasTarget = pairs.hasKey("target")
      if hasOrigin == hasTarget:
        fail(at, "[[policy]] accepting a Nimble source names exactly one " &
          "of `origin` (a repointed or revived origin) and `target` (a " &
          "retargeted alias's new target)")
      if hasOrigin:
        a.origin = pairs.valueOf("origin")
        # Compared exactly with the origins the index records, so it is
        # not normalized; `?subdir=` is part of it.
        if a.origin.strip().len == 0:
          fail(at, "policy origin is empty")
        elif a.origin != a.origin.strip():
          fail(at, "policy origin " & a.origin.escape() & " has leading or " &
            "trailing whitespace")
      if pairs.hasKey("revived"):
        a.revived = pairs.valueOf("revived")
        if not hasOrigin:
          fail(at, "policy `revived` names a revival entry of an origin " &
            "and needs `origin`")
        else:
          try:
            a.revivedAt = parse(a.revived, "yyyy-MM-dd'T'HH:mm:ss'Z'",
              utc()).toTime.toUnix
            if a.revivedAt <= 0: raise newException(ValueError, "not after 1970")
          except CatchableError:
            fail(at, "policy revived " & a.revived.escape() & " is not a " &
              "UTC time spelled YYYY-MM-DDTHH:MM:SSZ (the revival's time, " &
              "as the remedy prints it)")
      if hasTarget:
        let t = pairs.valueOf("target")
        if not t.startsWith("nimble:") or t.len == 7 or
            nameProblem(t).len > 0:
          fail(at, "policy target " & t.escape() & " is not a " &
            "`nimble:<name>` package")
        else:
          a.target = t[7 .. ^1]
      acceptances.add(a)
      continue
    let pairs = fields(at, raw, ["package", "contributor"], "policy")
    for required in ["package", "contributor"]:
      if not pairs.hasKey(required):
        fail(at, "[[policy]] is missing `" & required & "`")
    let package = pairs.valueOf("package")
    let contributor = pairs.valueOf("contributor")
    if pairs.hasKey("package") and nameProblem(package).len > 0:
      fail(at, "policy package " & package.escape() & " " &
        nameProblem(package))
    if pairs.hasKey("contributor") and nameProblem(contributor).len > 0:
      fail(at, "policy contributor " & contributor.escape() & " " &
        nameProblem(contributor))
    rules.add(CatalogSelectionRule(targetPackage: package,
      contributor: contributor))
    policyTables.add(CatalogPolicyDeclaration(package: package,
      contributor: contributor, line: at))

  for i, a in acceptances:
    for b in acceptances[0 ..< i]:
      if a.package.len > 0 and a.repo == b.repo and
          nimbleKey(a.package) == nimbleKey(b.package):
        fail(a.line, "nimble:" & a.package & " is accepted twice through " &
          a.repo.escape() & " (the other [[policy]] is at line " & $b.line &
          "); one package takes one source, so keep one table")

  if errors.len > 0:
    raise newException(CatalogDeclarationError,
      "the catalog import declaration cannot be read:\n  " &
      errors.join("\n  "))
  declared.sort(proc (a, b: CatalogImportDeclaration): int = cmp(a.repo, b.repo))
  rules.sort(proc (a, b: CatalogSelectionRule): int =
    result = cmp(a.targetPackage, b.targetPackage)
    if result == 0: result = cmp(a.contributor, b.contributor))
  policyTables.sort(proc (a, b: CatalogPolicyDeclaration): int =
    result = cmp(a.package, b.package)
    if result == 0: result = cmp(a.contributor, b.contributor)
    if result == 0: result = cmp(a.line, b.line))
  acceptances.sort(proc (a, b: NimbleAcceptanceDeclaration): int =
    result = cmp(a.repo, b.repo)
    if result == 0: result = cmp(nimbleKey(a.package), nimbleKey(b.package)))
  CatalogImportsDeclaration(imports: declared,
    policy: CatalogSelectionPolicy(selections: rules),
    nimbleAcceptances: acceptances)

proc parseCatalogImportsDeclaration*(text, path: string):
    CatalogImportsDeclaration =
  ## ``parseCatalogImportsDeclaration`` without the diagnostic policy lines.
  var ignored: seq[CatalogPolicyDeclaration]
  parseCatalogImportsDeclaration(text, path, ignored)

# ---------------------------------------------------------------------------
# What a catalog publishes
# ---------------------------------------------------------------------------

proc fingerprintHex(d: ContentDigest): string =
  toHex(d.bytes).toLowerAscii()

proc decodePublishedArtifact*(path, bytes: string): ProjectInterfaceArtifact =
  ## Decode one published artifact (the envelope codec checks its own stored
  ## fingerprint), then require that fingerprint to be the SEMANTIC one the
  ## current codec computes. A legacy wire fingerprint, or one computed by an
  ## older codec, refuses: the catalog must republish. Raises
  ## ``ValueError`` naming the path.
  var raw = newSeq[byte](bytes.len)
  for i, ch in bytes:
    raw[i] = byte(ord(ch))
  try:
    result = decodeProjectInterfaceArtifact(raw)
  except CatchableError as err:
    raise newException(ValueError, "published artifact " & path &
      " is not a readable interface artifact: " & err.msg)
  let semantic = interfaceFingerprint(result.projectInterface)
  if result.interfaceFingerprint != semantic:
    raise newException(ValueError, "published artifact " & path &
      " carries interface fingerprint " &
      fingerprintHex(result.interfaceFingerprint) & ", but the current codec " &
      "computes " & fingerprintHex(semantic) & " for its interface; it was " &
      "written by another codec version (or edited) and must be republished")

proc publishedCatalogContent*(published: seq[PublishedArtifact];
                              refusals: var seq[string]): CatalogContent =
  ## The ``CatalogContent`` a catalog's published artifacts declare (see the
  ## module docstring). Appends every reason the publication cannot be
  ## composed to ``refusals``; the content is meaningful only when nothing
  ## was appended.
  if published.len == 0:
    refusals.add("the catalog publishes no interface artifacts")
    return
  for p in published:
    let pi = p.artifact.projectInterface
    if pi.provisioningContributions.len == 0:
      result.canonicalInterfaces.add(catalogInterface(pi.packageName,
        fingerprintHex(p.artifact.interfaceFingerprint), pi.location))
      continue
    for c in pi.provisioningContributions:
      let what = "published artifact " & p.path & ": contribution from \"" &
        c.contributor & "\" for package \"" & c.targetPackage & "\""
      if c.imported:
        refusals.add(what & " is IMPORTED (re-exported from another " &
          "catalog); a catalog publishes only its own records")
        continue
      if c.developInterface:
        refusals.add(what & " uses developInterface, which is forbidden in " &
          "a published catalog snapshot")
        continue
      if not isHexOf(c.targetInterfaceFingerprint, 64):
        refusals.add(what & " is not pinned to a 64-hex interface " &
          "fingerprint")
        continue
      result.contributions.add(c)

proc publishedArtifactIdentity*(published: seq[PublishedArtifact]): string =
  ## The catalog's interface-artifact identity: ``catalogArtifactIdentity``
  ## over the decoded set.
  catalogArtifactIdentity(published.mapIt(it.artifact))

proc catalogProviderIdentity*(objectFormat, rootTree: string): string =
  ## The ``providerIdentity`` of every contribution a catalog publishes at a
  ## revision whose root tree is ``rootTree`` (see the module docstring).
  let text = CatalogProviderIdentityMagic & "\n" & objectFormat & "\n" &
    rootTree.toLowerAscii() & "\n"
  toHex(blake3DomainDigest(toOpenArrayByte(text, 0, text.high),
    hdMetadataEnvelope).bytes).toLowerAscii()

proc offeredIdentities*(content: CatalogContent;
                        providerIdentity: string): seq[ContributionIdentity] =
  ## One ``ContributionIdentity`` per published record. ``dependencies`` and
  ## ``fromSourceProvisioning`` are empty: the artifact codec carries
  ## neither.
  for c in content.contributions:
    result.add(ContributionIdentity(contribution: c,
      providerIdentity: providerIdentity))

proc offeredContributionResolver*(offered: seq[ContributionIdentity]):
    ContributionResolver =
  ## The dependency resolver discovery supplies: a dependency coordinate
  ## binds to the UNIQUE offered identity with that target package,
  ## contributor and (normalised) target interface fingerprint, and to none
  ## otherwise -- never to the first of several.
  let pool = offered
  result = proc (dep: ContributionDependencyRef): Option[ContributionIdentity]
      {.gcsafe.} =
    var found: seq[ContributionIdentity] = @[]
    for identity in pool:
      if identity.contribution.targetPackage == dep.targetPackage and
          identity.contribution.contributor == dep.contributor and
          normalizedFingerprint(identity.contribution.targetInterfaceFingerprint) ==
            normalizedFingerprint(dep.targetInterfaceFingerprint):
        found.add(identity)
    if found.len == 1: some(found[0]) else: none(ContributionIdentity)
