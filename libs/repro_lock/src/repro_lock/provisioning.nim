## The locked provisioning realization — M7 deliverable 2 of
## ``ReproOS-Campaign-Completion.milestones.org``, normatively specified by
## ``reprobuild-specs/Provisioning-Contributions.md`` § Locks And Snapshots:
##
##   A locked realization records:
##   - package name and canonical interface fingerprint;
##   - selected contributor id and contribution fingerprint;
##   - catalog repository coordinates and revision;
##   - realization-specific lock identity and integrity;
##   - host/target platform and selected capabilities.
##
## ## Where it lives, and why it is a leaf
##
## The record is one more array in the EXISTING committed lock --
## ``repro.lock``, schema ``reprobuild.solved-graph-lock.v2``, written and
## read by ``repro_lock``'s ``serializeLockedDependencies`` /
## ``parseLockedDependencies`` -- under the key ``provisioning``. There is no
## second lock file. The document schema does not change: the v2 reader has
## always ignored unknown keys ("forward-compatible within the v2 schema"),
## and the array is written ONLY when it is non-empty, so every lock that
## exists today re-serialises byte-identically and keeps its identity. That
## is the discipline PMC-4 applied to ``target`` and NLF-M9 to ``selection``.
##
## This module holds the record, its canonical encoding, its strict reader
## and its validation, and imports ``std`` only. ``repro_lock.nim`` imports
## it for the document codec; ``repro_interface_artifacts/contribution_lock``
## imports it for the WRITER that turns a composed selection into a record.
## The direction is deliberate and is the one ``repro_lock/identity.nim``
## documents: ``repro_lock.nim`` pulls in the clingo-backed solver, and the
## interface-artifact library must not; nor may ``repro_lock`` (which the
## resolving launcher links) pull in the interface-artifact library.
##
## ## Versioning
##
## Every entry carries ``record = "reprobuild.locked-provisioning-realization.v1"``
## as its FIRST field. The reader refuses any other value, and refuses an
## entry without one, so a later record shape is a new tag rather than a
## silent reinterpretation of this one. The document tag stays ``…v2``.
##
## CAVEAT, stated rather than implied: a Reprobuild binary built BEFORE this
## module existed reads a v2 document carrying ``provisioning`` and ignores
## the key, exactly as it ignores any unknown key. Such a binary also has no
## lock-driven provisioning selection at all (that is M7 deliverable 3), so
## it behaves as it did before -- it does not act on a record it cannot see.
##
## ## Canonical encoding
##
## One inline table per record, fields in ONE fixed order, values
## TOML-escaped; records sorted by (package, host platform, target
## platform), which is also the uniqueness key -- two records for one key
## refuse, on write and on read. Capabilities are a SET: sorted and
## de-duplicated on write. Hex identities are lower-cased by the writer
## where they enter (``contribution_lock``). So the
## same selection gives the same bytes whatever order anything was supplied
## in, and the reader accepts ONLY those bytes: after a strict parse it
## re-serialises and refuses the entry array unless the bytes agree.
##
## What never enters a record: an absolute path, a drive letter, a
## backslash, a ``file:`` URL, ``CatalogImport.discoveredAt`` or a
## ``SourceLocation``. The first four are refused by value
## (``localPathDefect``) in EVERY free-text field -- package, contributor,
## catalog workspace and remote, realization lock identity -- including a
## ``file`` component of a compound scheme (``git+file:``), a scheme whose
## path is absolute with no authority (``path:/…``, ``nix:/nix/store/…``),
## a drive-relative ``C:foo`` and a one-letter scheme (which cannot be told
## apart from a drive letter). The other fields are hex, enum, platform or
## capability tokens and cannot spell a path. The last two have no field
## to arrive through.
##
## ## Refuse, never truncate
##
## A required field that is missing, empty or malformed REFUSES, on write
## and on read. The catalog revision must be a full-width object id (40 or
## 64 lower-case hex) -- an abbreviated revision names a set of commits,
## not one. A truncated entry array, an unknown or duplicated field, an
## unknown record version and a non-canonical spelling all refuse.
##
## ## The gate, and the seal
##
## A record is serialisable only once it has been SEALED, and the only
## seals are ``sealLockedRealization`` (the writer's) and the strict reader's.
## The writer's seal takes the contribution-fingerprint EVIDENCE the record
## was derived from and refuses unless that fingerprint was produced with no
## refusal AND with every dependency bound through the resolver (M7 D1's
## ``dependenciesFullyResolved``; a leaf-padded fingerprint binds a
## dependency's coordinate only, and must never reach a lock). The seal
## records the canonical bytes at sealing time, and the serialiser refuses a
## record whose current bytes differ -- so a record built by hand, or
## edited after it was sealed, cannot be written.
##
## ## Reading a record back
##
## A record is handed out only through ``requireCurrentRealization``, which
## takes the CURRENT canonical interface fingerprint of the package and the
## CURRENT contribution fingerprint of the selected contribution, and
## refuses (``StaleLockedRealizationError``) unless both still match. The
## refusal says which one moved, because they mean different things:
##
##   * the interface moved -- the lock is pinned to an interface revision
##     the package no longer has, and is incompatible;
##   * only the contribution moved -- the package interface is unchanged,
##     so downstream typechecking stays valid, but the realization the lock
##     selected is not the one the catalog now describes.

import std/[algorithm, sequtils, strutils]

const
  LockedRealizationRecordV1* = "reprobuild.locked-provisioning-realization.v1"
    ## The per-record version tag. See "Versioning" above.

  ProvisioningLockKey* = "provisioning"
    ## The key of the record array inside the committed lock's ``[lock]``
    ## table.

type
  LockedRealizationKind* = enum
    ## Which realization family of the selected contribution is locked.
    lrkNix = "nix"
    lrkTarball = "tarball"
    lrkScoop = "scoop"
    lrkFromSource = "from-source"

  LockedSelectionReason* = enum
    ## How the selection being locked was made. Recorded so a locked build
    ## can say WHY a contributor is pinned; it is data, not a policy.
    lsrUniqueEligible = "unique-eligible"
    lsrCuratorPolicy = "curator-policy"

  LockedRealization* = object
    ## One locked realization. Every field is required; ``capabilities``
    ## may be the empty set.
    packageName*: string
    interfaceFingerprint*: string       ## canonical, 64 lower-case hex.
    contributor*: string
    contributionFingerprint*: string    ## M7 D1, 64 lower-case hex.
    catalogWorkspace*: string
    catalogRemote*: string
    catalogRevision*: string            ## full-width: 40 or 64 hex.
    catalogInterfaceArtifact*: string   ## 64 lower-case hex.
    realizationKind*: LockedRealizationKind
    realizationLockIdentity*: string
    realizationIntegrity*: string
    hostPlatform*: string               ## ``<cpu>-<os>``.
    targetPlatform*: string             ## ``<cpu>-<os>``.
    capabilities*: seq[string]
    selectedBy*: LockedSelectionReason
    sealed: string
      ## The canonical entry bytes at sealing time. Private: only this
      ## module's two seals set it, and the serialiser refuses a record
      ## whose current bytes differ.

  ContributionEvidence* = object
    ## What the writer knows about the contribution fingerprint it is
    ## locking: ``ContributionFingerprint.hex`` / ``.refusals`` /
    ## ``.unresolvedDependencies`` (the last as coordinate spellings).
    fingerprintHex*: string
    refusals*: seq[string]
    unresolvedDependencies*: seq[string]

  LockedRealizationError* = object of CatchableError
    ## A record refused on write or on read.

  LockedRealizationFreshness* = enum
    lrfCurrent = "current"
    lrfContributionChanged = "contribution-changed"
      ## Only the contribution moved: the package interface is unchanged,
      ## so typechecking stays valid; the locked realization does not.
    lrfInterfaceChanged = "interface-changed"
      ## The package interface moved: the lock is incompatible.

  StaleLockedRealizationError* = object of LockedRealizationError
    freshness*: LockedRealizationFreshness

const FieldOrder = [
  "record", "package", "interface", "contributor", "contribution",
  "catalog_workspace", "catalog_remote", "catalog_revision",
  "catalog_interface_artifact", "realization", "realization_lock_identity",
  "realization_integrity", "host_platform", "target_platform",
  "capabilities", "selected_by"]

# ---------------------------------------------------------------------------
# Value shapes
# ---------------------------------------------------------------------------

proc isLowerHex(value: string; width: int): bool =
  if value.len != width:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc isBase64Body(body: string; width: int; padding: int): bool =
  if body.len != width:
    return false
  for i, ch in body:
    if i >= width - padding:
      if ch != '=': return false
    elif ch notin {'A'..'Z', 'a'..'z', '0'..'9', '+', '/'}:
      return false
  true

proc integrityDefect(value: string): string =
  ## A realization's integrity evidence: a 64-hex digest, or an SRI
  ## ``sha256-``/``sha512-`` digest of exactly the width that algorithm
  ## produces. Weaker SRI algorithms (``sha1-``, ``md5-``) are not accepted
  ## into a lock.
  if isLowerHex(value, 64):
    return ""
  if value.startsWith("sha256-") and
      isBase64Body(value["sha256-".len .. ^1], 44, 1):
    return ""
  if value.startsWith("sha512-") and
      isBase64Body(value["sha512-".len .. ^1], 88, 2):
    return ""
  "not a 64-hex digest or a full-width sha256-/sha512- SRI digest"

proc localPathDefect(value: string): string =
  ## A value that spells a location on SOME host's filesystem. None may
  ## enter a record: a lock is committed and read on other hosts, and an
  ## absolute path in it is the cross-host leak this campaign has already
  ## paid for once (M6's ``catalogArtifactIdentity``).
  if '\\' in value:
    return "contains a backslash (a native path separator)"
  if value.startsWith("/") or value.startsWith("~") or
      value.startsWith("./") or value.startsWith("../"):
    return "is a filesystem path"
  if value.len >= 2 and value[0] in {'A'..'Z', 'a'..'z'} and value[1] == ':':
    # ``C:foo`` is a drive-relative path, and a one-letter URL scheme cannot
    # be told apart from one, so both refuse.
    return "starts with a drive letter"
  # A URL scheme, ``[A-Za-z][A-Za-z0-9+.-]*:``.
  var colon = -1
  if value.len > 0 and value[0] in {'A'..'Z', 'a'..'z'}:
    for i in 1 ..< value.len:
      if value[i] == ':':
        colon = i
        break
      if value[i] notin {'A'..'Z', 'a'..'z', '0'..'9', '+', '.', '-'}:
        break
  if colon > 0:
    let scheme = value[0 ..< colon].toLowerAscii()
    if "file" in scheme.split('+'):
      return "is a file: URL"
    let rest = value[colon + 1 .. ^1]
    if rest.startsWith("///") or
        (rest.startsWith("/") and not rest.startsWith("//")):
      # ``path:/home/…``, ``nix:/nix/store/…``, ``x:///…``: a scheme with no
      # authority whose path is absolute names a location on THIS host.
      return "names an absolute path on the local host"
  for i in 0 ..< value.len - 1:
    if value[i] in {'A'..'Z', 'a'..'z'} and value[i + 1] == ':' and
        (i == 0 or value[i - 1] notin {'A'..'Z', 'a'..'z', '0'..'9'}) and
        (i + 2 >= value.len or value[i + 2] in {'/', '\\'}):
      return "contains a drive letter"
  ""

proc nameDefect(value: string): string =
  if value.strip().len == 0:
    return "empty"
  if value != value.strip():
    return "has leading or trailing whitespace"
  ""

proc isPlatformToken(value: string): bool =
  ## ``<cpu>-<os>``, the spelling ``currentPlatformId`` produces.
  let dash = value.find('-')
  if dash <= 0 or dash >= value.high or value.find('-', dash + 1) >= 0:
    return false
  for ch in value:
    if ch notin {'a'..'z', '0'..'9', '_', '-'}:
      return false
  true

proc isCapabilityToken(value: string): bool =
  if value.len == 0 or value[0] notin {'a'..'z', '0'..'9'}:
    return false
  for ch in value:
    if ch notin {'a'..'z', '0'..'9', '.', '_', '+', '-'}:
      return false
  true

proc realizationDefects*(r: LockedRealization): seq[string] =
  ## Every field whose value is missing or malformed, as
  ## ``field <name>: <problem>``. Applied to a record on write and on read.
  template defect(name, problem: string) =
    result.add("field " & name & ": " & problem)

  block:
    var d = nameDefect(r.packageName)
    if d.len == 0: d = localPathDefect(r.packageName)
    if d.len > 0: defect("package", d)
  if not isLowerHex(r.interfaceFingerprint, 64):
    defect("interface", "not a 64-hex canonical interface fingerprint")
  block:
    var d = nameDefect(r.contributor)
    if d.len == 0: d = localPathDefect(r.contributor)
    if d.len > 0: defect("contributor", d)
  if not isLowerHex(r.contributionFingerprint, 64):
    defect("contribution", "not a 64-hex contribution fingerprint")
  block:
    var d = nameDefect(r.catalogWorkspace)
    if d.len == 0: d = localPathDefect(r.catalogWorkspace)
    if d.len > 0: defect("catalog_workspace", d)
  block:
    var d = nameDefect(r.catalogRemote)
    if d.len == 0: d = localPathDefect(r.catalogRemote)
    if d.len > 0: defect("catalog_remote", d)
  if not (isLowerHex(r.catalogRevision, 40) or
      isLowerHex(r.catalogRevision, 64)):
    defect("catalog_revision",
      "not a full-width revision (40 or 64 hex): \"" & r.catalogRevision &
      "\"")
  if not isLowerHex(r.catalogInterfaceArtifact, 64):
    defect("catalog_interface_artifact",
      "not a 64-hex interface-artifact identity")
  block:
    var d = nameDefect(r.realizationLockIdentity)
    if d.len == 0: d = localPathDefect(r.realizationLockIdentity)
    if d.len > 0: defect("realization_lock_identity", d)
  block:
    let d = integrityDefect(r.realizationIntegrity)
    if d.len > 0: defect("realization_integrity", d)
  if not isPlatformToken(r.hostPlatform):
    defect("host_platform", "not a <cpu>-<os> platform: \"" &
      r.hostPlatform & "\"")
  if not isPlatformToken(r.targetPlatform):
    defect("target_platform", "not a <cpu>-<os> platform: \"" &
      r.targetPlatform & "\"")
  for i, capability in r.capabilities:
    if not isCapabilityToken(capability):
      defect("capabilities", "not a capability token: \"" & capability & "\"")
    elif i > 0 and r.capabilities[i - 1] >= capability:
      defect("capabilities", "not a sorted set")

# ---------------------------------------------------------------------------
# Canonical encoding
# ---------------------------------------------------------------------------

proc tomlEscape(s: string): string =
  ## The same basic-string escaping ``repro_lock`` uses for every other
  ## value in the document.
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)

proc fieldValues(r: LockedRealization): seq[string] =
  ## The record's values in ``FieldOrder``.
  @[LockedRealizationRecordV1, r.packageName, r.interfaceFingerprint,
    r.contributor, r.contributionFingerprint, r.catalogWorkspace,
    r.catalogRemote, r.catalogRevision, r.catalogInterfaceArtifact,
    $r.realizationKind, r.realizationLockIdentity, r.realizationIntegrity,
    r.hostPlatform, r.targetPlatform, r.capabilities.join(","),
    $r.selectedBy]

proc canonicalRealizationEntry*(r: LockedRealization): string =
  ## One record as its canonical inline table.
  let values = fieldValues(r)
  result = "{ "
  for i, name in FieldOrder:
    if i > 0: result.add(", ")
    result.add(name & " = \"" & tomlEscape(values[i]) & "\"")
  result.add(" }")

proc cmpKey(a, b: LockedRealization): int =
  ## The uniqueness and sort key: one realization per package per
  ## host/target platform pair.
  result = cmp(a.packageName, b.packageName)
  if result == 0: result = cmp(a.hostPlatform, b.hostPlatform)
  if result == 0: result = cmp(a.targetPlatform, b.targetPlatform)

proc isSealed*(r: LockedRealization): bool =
  ## True iff the record came out of a seal and has not been edited since.
  ## (A canonical entry is never empty, so an unsealed record never
  ## matches.)
  r.sealed == canonicalRealizationEntry(r)

proc normalizedForWrite(r: LockedRealization): LockedRealization =
  ## The one normalisation the record owns: ``capabilities`` is a SET.
  ## Hex case is normalised where the value enters, by the writer
  ## (``contribution_lock``); a direct caller passing upper-case hex is
  ## refused by ``realizationDefects`` rather than silently rewritten.
  result = r
  var capabilities = r.capabilities
  capabilities.sort(cmp)
  result.capabilities = capabilities.deduplicate(isSorted = true)
  result.sealed = ""

proc lockedRealizationRefusals*(r: LockedRealization;
                                evidence: ContributionEvidence): seq[string] =
  ## Why ``sealLockedRealization`` would refuse ``r``; empty when it would
  ## seal. The evidence gate first, then every field.
  if evidence.refusals.len > 0:
    result.add("evidence: the contribution fingerprint refused (" &
      evidence.refusals.join("; ") & ")")
  if evidence.unresolvedDependencies.len > 0:
    result.add("evidence: the contribution fingerprint is not fully " &
      "resolved; these dependencies are bound by coordinate only: " &
      evidence.unresolvedDependencies.join(", "))
  let normalized = normalizedForWrite(r)
  if evidence.fingerprintHex != normalized.contributionFingerprint:
    result.add("evidence: the contribution fingerprint evidence is for " &
      "a different fingerprint than the record carries")
  result.add(realizationDefects(normalized))

proc sealLockedRealization*(r: LockedRealization;
                            evidence: ContributionEvidence):
    LockedRealization =
  ## THE writer's seal. Normalises the record for write (capabilities
  ## sorted and de-duplicated), refuses it unless the evidence
  ## shows a fully resolved contribution fingerprint equal to the one the
  ## record carries and every field is well formed, and then seals it.
  let refusals = lockedRealizationRefusals(r, evidence)
  if refusals.len > 0:
    raise newException(LockedRealizationError,
      "refusing to lock the provisioning realization of package \"" &
      r.packageName & "\": " & refusals.join("; "))
  result = normalizedForWrite(r)
  result.sealed = canonicalRealizationEntry(result)

proc serializeProvisioningRealizations*(
    records: seq[LockedRealization]): string =
  ## The canonical right-hand side of the ``provisioning`` key. Refuses an
  ## unsealed or edited record and two records for one (package, host,
  ## target) key. (A sealed record is well formed: both seals validate, and
  ## any later edit breaks the seal.)
  for r in records:
    if not r.isSealed:
      raise newException(LockedRealizationError,
        "provisioning realization of package \"" & r.packageName &
        "\" was not sealed by the lock writer (or was edited after it was " &
        "sealed); build it with sealLockedRealization")
  var sorted = records
  sorted.sort(cmpKey)
  result = "["
  for i, r in sorted:
    if i > 0:
      if cmpKey(sorted[i - 1], r) == 0:
        raise newException(LockedRealizationError,
          "two provisioning realizations are locked for package \"" &
          r.packageName & "\" on " & r.hostPlatform & " -> " &
          r.targetPlatform & "; a lock selects exactly one")
      result.add(", ")
    result.add(canonicalRealizationEntry(r))
  result.add("]")

# ---------------------------------------------------------------------------
# Strict reader
# ---------------------------------------------------------------------------

proc parseError(message: string) {.noreturn.} =
  raise newException(LockedRealizationError, message)

proc parseProvisioningRealizations*(rhs: string): seq[LockedRealization] =
  ## Parse the right-hand side of the ``provisioning`` key. Strict: every
  ## entry must carry exactly the v1 fields, each once, each well formed,
  ## and the whole array must be the canonical bytes the writer produces.
  ## Anything else -- including a truncated array -- raises
  ## ``LockedRealizationError``.
  let s = rhs.strip()
  var pos = 0

  proc skipSpaces() =
    while pos < s.len and s[pos] in {' ', '\t'}: inc pos

  proc expect(ch: char; what: string) =
    skipSpaces()
    if pos >= s.len:
      parseError("provisioning: truncated; expected " & what)
    if s[pos] != ch:
      parseError("provisioning: expected " & what & " at byte " & $pos)
    inc pos

  proc readValue(): string =
    ## A basic string, after its opening quote, through its closing quote.
    while true:
      if pos >= s.len:
        parseError("provisioning: truncated inside a quoted value")
      let ch = s[pos]
      if ch == '"':
        inc pos
        return
      if ch == '\\':
        if pos + 1 >= s.len:
          parseError("provisioning: truncated inside an escape")
        case s[pos + 1]
        of '\\': result.add('\\')
        of '"': result.add('"')
        of 'n': result.add('\n')
        of 'r': result.add('\r')
        of 't': result.add('\t')
        else: parseError("provisioning: unknown escape \\" & s[pos + 1])
        pos += 2
      else:
        result.add(ch)
        inc pos

  var entries: seq[seq[(string, string)]] = @[]
  expect('[', "'['")
  skipSpaces()
  if pos < s.len and s[pos] == ']':
    # The writer omits the key rather than writing an empty array, so an
    # empty array is not something this codec produced.
    parseError("provisioning: an empty array is never written (a lock " &
      "without locked realizations omits the key)")
  else:
    while true:
      expect('{', "'{'")
      var pairs: seq[(string, string)] = @[]
      while true:
        skipSpaces()
        var key = ""
        while pos < s.len and s[pos] in {'a'..'z', '_'}:
          key.add(s[pos]); inc pos
        if key.len == 0:
          if pos >= s.len: parseError("provisioning: truncated; expected a key")
          parseError("provisioning: expected a key at byte " & $pos)
        expect('=', "'='")
        expect('"', "a quoted value")
        pairs.add((key, readValue()))
        skipSpaces()
        if pos >= s.len: parseError("provisioning: truncated; expected ',' or '}'")
        if s[pos] == ',':
          inc pos
        elif s[pos] == '}':
          inc pos
          break
        else:
          parseError("provisioning: expected ',' or '}' at byte " & $pos)
      entries.add(pairs)
      skipSpaces()
      if pos >= s.len: parseError("provisioning: truncated; expected ',' or ']'")
      if s[pos] == ',':
        inc pos
      elif s[pos] == ']':
        inc pos
        break
      else:
        parseError("provisioning: expected ',' or ']' at byte " & $pos)
  skipSpaces()
  if pos != s.len:
    parseError("provisioning: unexpected bytes after the array at byte " & $pos)

  for n, pairs in entries:
    let where = "provisioning entry " & $n & ": "
    var values: array[FieldOrder.len, string]
    var seen: array[FieldOrder.len, bool]
    for (key, value) in pairs:
      let index = FieldOrder.find(key)
      if index < 0:
        parseError(where & "unknown field " & key)
      if seen[index]:
        parseError(where & "duplicate field " & key)
      seen[index] = true
      values[index] = value
    for index, name in FieldOrder:
      if not seen[index]:
        parseError(where & "missing field " & name)
    if values[0] != LockedRealizationRecordV1:
      parseError(where & "unsupported record version \"" & values[0] &
        "\" (this reader accepts " & LockedRealizationRecordV1 & ")")
    var r = LockedRealization(
      packageName: values[1], interfaceFingerprint: values[2],
      contributor: values[3], contributionFingerprint: values[4],
      catalogWorkspace: values[5], catalogRemote: values[6],
      catalogRevision: values[7], catalogInterfaceArtifact: values[8],
      realizationLockIdentity: values[10], realizationIntegrity: values[11],
      hostPlatform: values[12], targetPlatform: values[13])
    try:
      r.realizationKind = parseEnum[LockedRealizationKind](values[9])
    except ValueError:
      parseError(where & "field realization: unknown kind \"" & values[9] & "\"")
    try:
      r.selectedBy = parseEnum[LockedSelectionReason](values[15])
    except ValueError:
      parseError(where & "field selected_by: unknown reason \"" &
        values[15] & "\"")
    r.capabilities = if values[14].len == 0: @[] else: values[14].split(',')
    let defects = realizationDefects(r)
    if defects.len > 0:
      parseError(where & defects.join("; "))
    r.sealed = canonicalRealizationEntry(r)
    result.add(r)

  if serializeProvisioningRealizations(result) != s:
    parseError("provisioning: not the canonical encoding (field order, " &
      "record order, spacing or escaping differs from what the lock writer " &
      "produces); regenerate the lock")

# ---------------------------------------------------------------------------
# Reading a record back: only against the current facts
# ---------------------------------------------------------------------------

proc freshnessOf*(r: LockedRealization;
                  currentInterfaceFingerprint,
                  currentContributionFingerprint: string):
    LockedRealizationFreshness =
  ## Compare a locked record against the CURRENT canonical interface
  ## fingerprint of its package and the CURRENT contribution fingerprint of
  ## its contribution, both in their canonical lower-case 64-hex spelling
  ## (anything else compares unequal and refuses, the safe direction). The
  ## interface is asked first: an interface change is the incompatible one,
  ## whatever the contribution did.
  if currentInterfaceFingerprint != r.interfaceFingerprint:
    return lrfInterfaceChanged
  if currentContributionFingerprint != r.contributionFingerprint:
    return lrfContributionChanged
  lrfCurrent

proc requireCurrentRealization*(records: seq[LockedRealization];
                                packageName, hostPlatform,
                                targetPlatform: string;
                                currentInterfaceFingerprint,
                                currentContributionFingerprint: string):
    LockedRealization =
  ## The ONLY way a locked record is handed back for use. Raises
  ## ``LockedRealizationError`` when the lock records no realization for
  ## the package on this platform pair, and ``StaleLockedRealizationError``
  ## (carrying which fact moved) when the record no longer matches the
  ## current interface or contribution. Never returns a stale record.
  var found = false
  for r in records:
    if r.packageName == packageName and r.hostPlatform == hostPlatform and
        r.targetPlatform == targetPlatform:
      result = r
      found = true
      break
  if not found:
    raise newException(LockedRealizationError,
      "the lock records no provisioning realization for package \"" &
      packageName & "\" on " & hostPlatform & " -> " & targetPlatform)
  let freshness = freshnessOf(result, currentInterfaceFingerprint,
    currentContributionFingerprint)
  if freshness != lrfCurrent:
    let err = newException(StaleLockedRealizationError,
      case freshness
      of lrfInterfaceChanged:
        "the locked provisioning realization of package \"" & packageName &
        "\" is pinned to interface " & result.interfaceFingerprint &
        ", but the package's canonical interface is now " &
        currentInterfaceFingerprint &
        "; the lock is incompatible and must be refreshed"
      else:
        "the locked provisioning realization of package \"" & packageName &
        "\" selects contribution " & result.contributionFingerprint &
        " from \"" & result.contributor & "\", which is now " &
        currentContributionFingerprint &
        "; the package interface is unchanged (typechecking stays valid), " &
        "but the locked realization must be refreshed")
    err.freshness = freshness
    raise err
