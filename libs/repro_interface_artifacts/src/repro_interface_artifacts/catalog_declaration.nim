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

import std/[algorithm, options, sequtils, strutils]
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
    line*: int                  ## where the table starts (diagnostics only).

  CatalogPolicyDeclaration* = object
    ## One ``[[policy]]`` table and the line it starts on. DIAGNOSTICS ONLY
    ## (M6 deliverable 4: a refusal names the table to edit); never a
    ## selection input.
    package*: string
    contributor*: string
    line*: int

  CatalogImportsDeclaration* = object
    imports*: seq[CatalogImportDeclaration]
      ## Sorted by ``repo``: declaration order is not an input.
    policy*: CatalogSelectionPolicy
      ## The ``[[policy]]`` rules. Their order is not an input either
      ## (``composeCatalogs`` folds them into a map and refuses a
      ## contradiction).

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
  for (at, raw) in imports:
    let pairs = fields(at, raw,
      ["repo", "remote", "commit", "ref", "interface_artifact"], "import")
    var d = CatalogImportDeclaration(line: at)
    for required in ["repo", "remote"]:
      if not pairs.hasKey(required):
        fail(at, "[[import]] is missing `" & required & "`")
    d.repo = pairs.valueOf("repo")
    d.remote = pairs.valueOf("remote")
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

  var rules: seq[CatalogSelectionRule] = @[]
  for (at, raw) in policies:
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
  CatalogImportsDeclaration(imports: declared,
    policy: CatalogSelectionPolicy(selections: rules))

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
