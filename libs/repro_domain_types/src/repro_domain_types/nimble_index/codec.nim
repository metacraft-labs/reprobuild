## Canonical codec of the Nimble index objects: root, shard, name map and
## origin events.
##
## ## Frame
##
## Every object is an RBSZ frame (the framing of ``repro_domain_types``):
##
##   "RBSZ" | u16 frame version (1) | u16 type id | u32 payload length | payload
##
## little-endian. The payload is the SSZ encoding of the kind's wire type
## (``wire.nim``), whose first field is the u16 ``schema``. The decoder
## refuses, in this order and before decoding anything else: an input
## longer than the kind's byte bound, a short or mismatched frame, an
## unknown frame version, a type id other than the one asked for, and a
## schema other than ``NimbleIndexSchemaVersion`` (for a shard, also
## ``NimbleShardSubmodulesSchema`` and ``NimbleShardConditionsSchema``).
##
## ## Shard schemas
##
## A shard whose records carry no ``submodules`` list is schema 1. A shard
## in which any record carries one is schema 2 (``ShardW2``, whose records
## add the list after their schema-1 fields). The schema is a function of
## the value, so it is part of the canonical form: schema 2 for a shard
## without any list is refused as non-canonical. A reader that knows only
## schema 1 refuses a schema-2 shard (``nrUnknownSchema``) and so never
## offers a record without the submodule trees its digest covers.
##
## A shard in which any condition node is a Nim-version comparison or an
## OS-family term (the NPC-AREQ7 terms of the A3 ruling) is schema 3
## (``ShardW3``): schema 2's layout, with every condition node carrying, after
## its kind and name, the comparison's term, operator and literal
## (``ConditionNodeW3``). Schema 3 is chosen by the value too, before
## schema 2: a shard with such a node is schema 3 whether or not it has a
## submodule list, and schema 3 for a shard without one is non-canonical. A
## reader of schemas 1 and 2 refuses a schema-3 shard (``nrUnknownSchema``),
## so it never reads such a condition as a target term or as no condition.
##
## ## Canonical form
##
## One value has exactly one encoding, and the decoder accepts only it:
##
## * the SSZ layout of the wire type, with every list and text within its
##   bound (an over-bound count is refused by the SSZ decoder before the list
##   is allocated);
## * enumerations within their vocabularies, unknown flag bits clear;
## * set-like lists strictly ascending by their key (packages and aliases by
##   ``nameKey``, versions by ``versionSortKey``, shards by bucket, names by
##   ``nameKey``, events by ``eventSortKey``), so a duplicate is a refusal;
## * text in its alphabet (identifiers printable ASCII, free text UTF-8
##   without control characters), so one value cannot be spelled two ways;
## * after decoding and validation the value is re-encoded, and anything but
##   the identical bytes is refused (``nrNonCanonical``).
##
## The same validation runs on encode, so the writer cannot produce an
## object the reader refuses.
##
## ## Identity and shard keying
##
## An object's identity is BLAKE3-256 of its bytes (``indexObjectId``), the
## key the content-addressed store uses. A package belongs to the shard
## ``shardBucket(nameKey(name), shardBits)``: the top ``shardBits`` bits of
## BLAKE3(``ShardKeyDomain`` & "\0" & key), read big-endian.

import std/[algorithm, options, strutils, unicode]

import blake3

import ./types
import ./wire

const
  FrameMagic = [byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))]
  NimbleIndexFrameVersion* = 1'u16
    ## The RBSZ frame version every index object carries; a reader refuses
    ## any other.
  FrameHeaderLen* = 12

  KnownFlagBits = (1'u32 shl (ord(RecordFlag.high) + 1)) - 1

# ---------------------------------------------------------------------------
# Bytes and lists
# ---------------------------------------------------------------------------

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(ord(c))

proc toStr(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b:
    result[i] = char(x)

template toL(s: untyped; L: typedesc; field: string): untyped =
  ## A bounded SSZ list from a seq, refusing (never truncating) past the
  ## bound.
  block:
    let tmp = s
    if tmp.len > int(L.maxLen):
      refuse(nrBound, field & " has " & $tmp.len & " entries, bound " &
        $L.maxLen)
    L.init(tmp)

template textL(s: string; L: typedesc; field: string): untyped =
  toL(toBytes(s), L, field)

proc wText[L](x: L): string = toStr(asSeq(x))

proc cmpBytes(a, b: string): int =
  ## Byte-wise comparison (std `cmp` on strings is byte-wise too; this
  ## names the intent).
  cmp(a, b)

proc indexObjectId*(bytes: openArray[byte]): IndexObjectId =
  ## The identity of an index object: BLAKE3-256 of its bytes.
  IndexObjectId(blake3.digest(bytes))

proc shardBucket*(key: string; shardBits: int): uint32 =
  ## The shard a package name key belongs to (see the module docstring).
  if shardBits <= 0:
    return 0
  let d = blake3.digest(ShardKeyDomain & "\0" & key)
  let top = (uint32(d[0]) shl 24) or (uint32(d[1]) shl 16) or
    (uint32(d[2]) shl 8) or uint32(d[3])
  top shr (32 - shardBits)

# ---------------------------------------------------------------------------
# Text alphabets
# ---------------------------------------------------------------------------

proc checkIdent(s, field: string; allowEmpty = false;
                maxLen = MaxNameBytes) =
  ## Printable ASCII without spaces.
  if s.len == 0:
    if allowEmpty: return
    refuse(nrInvalidText, field & " is empty")
  if s.len > maxLen:
    refuse(nrBound, field & " is longer than " & $maxLen & " bytes")
  for c in s:
    if ord(c) < 0x21 or ord(c) > 0x7e:
      refuse(nrInvalidText, field & " contains a byte outside printable ASCII")

proc checkSpacedAscii(s, field: string; maxLen: int) =
  ## Printable ASCII with single interior spaces: one spelling per value.
  if s.len == 0:
    refuse(nrInvalidText, field & " is empty")
  if s.len > maxLen:
    refuse(nrBound, field & " is longer than " & $maxLen & " bytes")
  if s[0] == ' ' or s[^1] == ' ':
    refuse(nrInvalidText, field & " has leading or trailing space")
  for i, c in s:
    if ord(c) < 0x20 or ord(c) > 0x7e:
      refuse(nrInvalidText, field & " contains a byte outside printable ASCII")
    if c == ' ' and i > 0 and s[i - 1] == ' ':
      refuse(nrInvalidText, field & " contains a doubled space")

proc checkFreeText(s, field: string; maxLen: int; allowEmpty = false) =
  ## UTF-8 without control characters.
  if s.len == 0:
    if allowEmpty: return
    refuse(nrInvalidText, field & " is empty")
  if s.len > maxLen:
    refuse(nrBound, field & " is longer than " & $maxLen & " bytes")
  if validateUtf8(s) != -1:
    refuse(nrInvalidText, field & " is not valid UTF-8")
  for r in s.runes:
    let v = int32(r)
    if v < 0x20 or v == 0x7f or (v >= 0x80 and v < 0xa0):
      refuse(nrInvalidText, field & " contains a control character")

proc isLowerHex(s: string): bool =
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc checkConditionName(s, field: string) =
  if s.len == 0 or s.len > MaxConditionNameBytes:
    refuse(nrInvalidText, field & " is empty or longer than " &
      $MaxConditionNameBytes & " bytes")
  for c in s:
    if c notin {'a'..'z', '0'..'9', '_'}:
      refuse(nrInvalidText, field & " is not a lower-case Nim target name")

# ---------------------------------------------------------------------------
# Sort keys
# ---------------------------------------------------------------------------

proc versionSortKey*(r: VersionRecord): string =
  ## The canonical order of a package's records: by kind, then tag, then
  ## commit. Unique per package, so a duplicate record is refused.
  $chr(ord(r.version.kind)) & r.version.tag & "\0" & r.commit

proc heldSortKey*(h: HeldVersion): string =
  ## The canonical order of an observation's held versions: as records.
  $chr(ord(h.version.kind)) & h.version.tag & "\0" & h.commit

proc eventSortKey*(e: OriginEvent): string =
  var t = ""
  for shift in countdown(56, 0, 8):
    t.add chr(int((e.observedAt shr uint64(shift)) and 0xff))
  nameKey(e.package) & "\0" & $chr(ord(e.kind)) & e.version & "\0" & t &
    e.before & "\0" & e.after

proc requireStrictlyAscending(keys: seq[string]; field: string) =
  for i in 1 ..< keys.len:
    let c = cmpBytes(keys[i - 1], keys[i])
    if c == 0:
      refuse(nrDuplicate, field & " entry " & $i & " duplicates its predecessor")
    if c > 0:
      refuse(nrUnsorted, field & " entry " & $i & " is out of canonical order")

# ---------------------------------------------------------------------------
# Validation (applied on encode and on decode)
# ---------------------------------------------------------------------------

const
  OsFamilyNames = ["posix", "unix", "bsd"]
  MaxNimVersionLiteral = uint64(high(int64))
    ## an integer literal of a Nim-version comparison is a Nim `int`

proc isPlainNode(n: ConditionNode): bool =
  ## A node that carries no Nim-version comparison fields.
  n.term == nvNone and n.op == opNone and n.ints.len == 0 and n.text.len == 0

proc validateCondition*(nodes: seq[ConditionNode]; field: string) =
  ## A well-formed prefix expression over the closed term set, or empty.
  ## Every field a node's kind does not use is empty, so one condition has
  ## one encoding.
  if nodes.len > MaxConditionNodes:
    refuse(nrBound, field & " has more than " & $MaxConditionNodes & " nodes")
  if nodes.len == 0:
    return
  var needed = 1
  for i, n in nodes:
    if needed <= 0:
      refuse(nrMalformed, field & " has nodes after a complete expression")
    dec needed
    let at = field & " node " & $i
    if n.kind != cnNimVersion and not n.isPlainNode:
      refuse(nrNonCanonical, at & ": only a nim-version node has a term, " &
        "an operator or a literal")
    case n.kind
    of cnDefinedOs, cnDefinedCpu, cnHostOs, cnHostCpu:
      checkConditionName(n.name, at)
    of cnOsFamily:
      if n.name notin OsFamilyNames:
        refuse(nrUnknownVocabulary, at & ": " & n.name.escape() &
          " is not an OS-family term (posix, unix, bsd)")
    of cnNimVersion:
      if n.name.len > 0:
        refuse(nrNonCanonical, at & ": a nim-version node has no name")
      if n.term == nvNone or n.op == opNone:
        refuse(nrMalformed, at & ": a nim-version node names its term " &
          "and its operator")
      let wantInts = case n.term
        of nvMajor, nvMinor, nvPatch: 1
        of nvMajorMinor: 2
        of nvMajorMinorPatch: 3
        else: 0
      if n.ints.len != wantInts:
        refuse(nrInconsistent, at & ": " & $n.term & " is compared with " &
          $wantInts & " integer literal(s), not " & $n.ints.len)
      for x in n.ints:
        if x > MaxNimVersionLiteral:
          refuse(nrBound, at & ": integer literal " & $x & " is not a Nim int")
      if n.term == nvVersion:
        checkFreeText(n.text, at & ".text", MaxNimVersionTextBytes,
          allowEmpty = true)
      elif n.text.len > 0:
        refuse(nrInconsistent, at & ": only NimVersion is compared with a " &
          "string")
    of cnAnd, cnOr:
      if n.name.len > 0:
        refuse(nrNonCanonical, at & ": an operator has no name")
      needed += 2
    of cnNot:
      if n.name.len > 0:
        refuse(nrNonCanonical, at & ": an operator has no name")
      needed += 1
  if needed != 0:
    refuse(nrMalformed, field & " is an incomplete expression")

proc validateRequirement(r: RequirementEntry; field: string) =
  validateCondition(r.condition, field & ".condition")
  case r.targetKind
  of rtPackage:
    checkIdent(r.target, field & ".target")
    if r.subdir.len > 0:
      refuse(nrInconsistent, field & ": a package-name requirement has no subdir")
  of rtUrl:
    checkIdent(r.target, field & ".target", maxLen = MaxTextBytes)
    checkFreeText(r.subdir, field & ".subdir", MaxPathBytes, allowEmpty = true)
  case r.versionKind
  of rvAny, rvHead:
    if r.constraint.len > 0:
      refuse(nrInconsistent, field & ": an `" & $r.versionKind &
        "` requirement has no constraint")
  of rvRange:
    checkSpacedAscii(r.constraint, field & ".constraint", MaxConstraintBytes)
  of rvCommit:
    if r.constraint.len < 4 or r.constraint.len > 64 or
        not isLowerHex(r.constraint):
      refuse(nrInvalidText, field & ".constraint is not 4 to 64 lower-case " &
        "hex digits")
  of rvRef:
    checkIdent(r.constraint, field & ".constraint", maxLen = MaxConstraintBytes)
  if r.features.len > MaxRequirementFeatures:
    refuse(nrBound, field & ".features has more than " &
      $MaxRequirementFeatures & " entries")
  for i, f in r.features:
    checkIdent(f, field & ".features[" & $i & "]")
  checkFreeText(r.source, field & ".source", MaxTextBytes)

proc validateRequirements(rs: seq[RequirementEntry]; bound: int; field: string) =
  if rs.len > bound:
    refuse(nrBound, field & " has " & $rs.len & " entries, bound " & $bound)
  for i, r in rs:
    validateRequirement(r, field & "[" & $i & "]")

proc validatePaths(ps: seq[string]; bound: int; field: string) =
  if ps.len > bound:
    refuse(nrBound, field & " has " & $ps.len & " entries, bound " & $bound)
  for i, p in ps:
    checkFreeText(p, field & "[" & $i & "]", MaxPathBytes)

proc validateNamedBins(ps: seq[NamedBin]; bound: int; field: string) =
  if ps.len > bound:
    refuse(nrBound, field & " has " & $ps.len & " entries, bound " & $bound)
  for i, p in ps:
    checkFreeText(p.key, field & "[" & $i & "].key", MaxPathBytes)
    checkFreeText(p.value, field & "[" & $i & "].value", MaxPathBytes)

proc validateRecordVersion(v: RecordVersion; field: string) =
  ## The version of a record or of a held version.
  case v.kind
  of rvkTag:
    var parsed: seq[uint64]
    checkIdent(v.tag, field & ".version.tag")
    if not parseTagVersion(v.tag, parsed) or parsed != v.components:
      refuse(nrInconsistent, field & ": the version components are not " &
        "what tag " & v.tag.escape() & " reads as")
  of rvkLabel:
    var parsed: seq[uint64]
    checkIdent(v.tag, field & ".version.tag")
    if v.components.len > 0 or parseTagVersion(v.tag, parsed):
      refuse(nrInconsistent, field & ": a label is a tag that does not " &
        "read as a version, and has no components")
  of rvkHead, rvkRef:
    checkIdent(v.tag, field & ".version.tag")
    if v.components.len > 0:
      refuse(nrInconsistent, field & ": a pseudo-version has no components")
  of rvkCommit:
    if v.tag.len > 0 or v.components.len > 0:
      refuse(nrInconsistent, field & ": a commit pseudo-version has no tag " &
        "and no components")
  if v.components.len > MaxVersionComponents:
    refuse(nrBound, field & ".version has more than " &
      $MaxVersionComponents & " components")

proc validateSubmodules(r: VersionRecord; field: string) =
  ## The ``submodules`` list (spec § 4.4, the NPC-M13 amendment): bounded,
  ## strictly ascending by path, each path relative and `/`-separated, each
  ## URL an identifier, each commit a full-width object id. A record with a
  ## list is flagged `gitlinks`.
  if r.submodules.len > MaxSubmodules:
    refuse(nrBound, field & ".submodules has " & $r.submodules.len &
      " entries, bound " & $MaxSubmodules)
  if r.submodules.len > 0 and flGitlinks notin r.flags:
    refuse(nrInconsistent, field & ": a record with submodules is flagged " &
      "gitlinks")
  var paths: seq[string]
  for i, m in r.submodules:
    let f = field & ".submodules[" & $i & "]"
    checkFreeText(m.path, f & ".path", MaxPathBytes)
    for part in m.path.split('/'):
      if part.len == 0 or part == "." or part == "..":
        refuse(nrInvalidText, f & ".path " & m.path.escape() & " is not a " &
          "relative path of named components")
    checkIdent(m.url, f & ".url", maxLen = MaxTextBytes)
    if m.commit.len notin [40, 64] or not isLowerHex(m.commit):
      refuse(nrInvalidText, f & ".commit is not a full-width lower-case " &
        "object id")
    paths.add m.path
  requireStrictlyAscending(paths, field & ".submodules")

proc validateRecord*(r: VersionRecord; originCount: int; field: string) =
  ## One version record, against the package it is in.
  validateRecordVersion(r.version, field)
  if r.commit.len notin [40, 64] or not isLowerHex(r.commit):
    refuse(nrInvalidText, field & ".commit is not a full-width lower-case " &
      "object id")
  if int(r.origin) >= originCount:
    refuse(nrInconsistent, field & ".origin names origin " & $r.origin &
      " of " & $originCount)
  validateRequirements(r.nim, MaxNimEntries, field & ".nim")
  validateRequirements(r.requires, MaxRequirements, field & ".requires")
  if r.features.len > MaxFeatures:
    refuse(nrBound, field & ".features has " & $r.features.len &
      " entries, bound " & $MaxFeatures)
  var featureKeys: seq[string]
  for i, f in r.features:
    checkIdent(f.name, field & ".features[" & $i & "].name")
    validateRequirements(f.requires, MaxRequirements,
      field & ".features[" & $i & "].requires")
    featureKeys.add f.name
  var sortedFeatures = featureKeys
  sortedFeatures.sort(cmpBytes)
  for i in 1 ..< sortedFeatures.len:
    if sortedFeatures[i] == sortedFeatures[i - 1]:
      refuse(nrDuplicate, field & ".features names " &
        sortedFeatures[i].escape() & " twice")
  let l = r.layout
  checkFreeText(l.srcDir, field & ".layout.srcDir", MaxPathBytes,
    allowEmpty = true)
  validatePaths(l.installDirs, MaxLayoutEntries, field & ".layout.installDirs")
  validatePaths(l.installFiles, MaxLayoutEntries, field & ".layout.installFiles")
  validatePaths(l.installExt, MaxLayoutEntries, field & ".layout.installExt")
  validatePaths(l.skipDirs, MaxLayoutEntries, field & ".layout.skipDirs")
  validatePaths(l.skipFiles, MaxLayoutEntries, field & ".layout.skipFiles")
  validatePaths(l.skipExt, MaxLayoutEntries, field & ".layout.skipExt")
  validatePaths(l.paths, MaxLayoutEntries, field & ".layout.paths")
  if l.modules.len > MaxModules:
    refuse(nrBound, field & ".layout.modules has more than " & $MaxModules &
      " entries")
  for i, m in l.modules:
    checkIdent(m, field & ".layout.modules[" & $i & "]")
  requireStrictlyAscending(l.modules, field & ".layout.modules")
  if l.conditional.len > MaxConditionalFields:
    refuse(nrBound, field & ".layout.conditional has more than " &
      $MaxConditionalFields & " entries")
  for i, c in l.conditional:
    let f = field & ".layout.conditional[" & $i & "]"
    validatePaths(c.values, MaxLayoutEntries, f & ".values")
    validateNamedBins(c.pairs, MaxLayoutEntries, f & ".pairs")
    if c.field == rfNamedBin:
      if c.values.len > 0:
        refuse(nrInconsistent, f & ": namedBin carries pairs, not values")
    elif c.pairs.len > 0:
      refuse(nrInconsistent, f & ": only namedBin carries pairs")
    if c.condition.len == 0:
      refuse(nrInconsistent, f & " has no condition")
    validateCondition(c.condition, f & ".condition")
  let b = r.binaries
  validatePaths(b.bin, MaxBinaries, field & ".binaries.bin")
  validateNamedBins(b.namedBin, MaxBinaries, field & ".binaries.namedBin")
  checkFreeText(b.binDir, field & ".binaries.binDir", MaxPathBytes,
    allowEmpty = true)
  checkIdent(b.backend, field & ".binaries.backend", allowEmpty = true)
  if r.foreign.len > MaxForeign:
    refuse(nrBound, field & ".foreign has more than " & $MaxForeign &
      " entries")
  for i, d in r.foreign:
    checkFreeText(d.name, field & ".foreign[" & $i & "].name", MaxTextBytes)
    validateCondition(d.condition, field & ".foreign[" & $i & "].condition")
  if (flPlatformLimited in r.flags) != (r.probePlatform.len > 0):
    refuse(nrInconsistent, field & ": probePlatform is set exactly when " &
      "platform_limited is")
  checkIdent(r.probePlatform, field & ".probePlatform", allowEmpty = true)
  if flPlatformLimited in r.flags and flUsesProbe notin r.flags:
    refuse(nrInconsistent, field & ": only a probe limits a record to a " &
      "platform")
  let staticallyReadable = r.readerClass in {rrcPlain, rrcClosedWhen,
    rrcFeature}
  if not staticallyReadable and flUnreadable notin r.flags and
      flOverrideApplied notin r.flags and flUsesProbe notin r.flags:
    refuse(nrInconsistent, field & ": the reader class is " & $r.readerClass &
      " and nothing supplied the requirements, so the record must be " &
      "flagged unreadable")
  if r.nimbleFile.isNone and flUnreadable notin r.flags and
      flOverrideApplied notin r.flags:
    refuse(nrInconsistent, field & ": a record read from no `.nimble` is " &
      "unreadable unless an override supplied it")
  validateSubmodules(r, field)

proc validatePackage*(p: PackageEnvelope; field: string) =
  checkIdent(p.name, field & ".name")
  if p.origins.len == 0:
    refuse(nrInconsistent, field & " has no origin")
  if p.origins.len > MaxOrigins:
    refuse(nrBound, field & ".origins has more than " & $MaxOrigins & " entries")
  var seen: seq[string]
  for i, o in p.origins:
    checkIdent(o.url, field & ".origins[" & $i & "].url", maxLen = MaxTextBytes)
    checkFreeText(o.subdir, field & ".origins[" & $i & "].subdir",
      MaxPathBytes, allowEmpty = true)
    let k = o.url & "\0" & o.subdir
    if k in seen:
      refuse(nrDuplicate, field & ".origins[" & $i & "] repeats an origin")
    seen.add k
  if int(p.registryOrigin) >= p.origins.len:
    refuse(nrInconsistent, field & ".registryOrigin names origin " &
      $p.registryOrigin & " of " & $p.origins.len)
  if p.versions.len > MaxVersionsPerPackage:
    refuse(nrBound, field & ".versions has more than " &
      $MaxVersionsPerPackage & " entries")
  var keys: seq[string]
  for i, r in p.versions:
    validateRecord(r, p.origins.len, field & ".versions[" & $i & "]")
    keys.add versionSortKey(r)
  requireStrictlyAscending(keys, field & ".versions")

proc validateObservation*(o: PackageObservation; field: string) =
  checkIdent(o.name, field & ".name")
  checkIdent(o.origin.url, field & ".origin.url", maxLen = MaxTextBytes)
  checkFreeText(o.origin.subdir, field & ".origin.subdir", MaxPathBytes,
    allowEmpty = true)
  checkIdent(o.headRef, field & ".headRef", allowEmpty = true)
  if o.head.len > 0 and (o.head.len notin [40, 64] or not isLowerHex(o.head)):
    refuse(nrInvalidText, field & ".head is not a full-width lower-case " &
      "object id")
  if o.state != osAnswering and (o.head.len > 0 or o.headRef.len > 0 or
      o.tags.len > 0):
    refuse(nrInconsistent, field & ": an origin that did not answer has no " &
      "refs")
  if o.tags.len > MaxObservedTags:
    refuse(nrBound, field & ".tags has more than " & $MaxObservedTags &
      " entries")
  var names: seq[string]
  for i, t in o.tags:
    checkIdent(t.name, field & ".tags[" & $i & "].name")
    if t.commit.len notin [40, 64] or not isLowerHex(t.commit):
      refuse(nrInvalidText, field & ".tags[" & $i & "].commit is not a " &
        "full-width lower-case object id")
    names.add t.name
  requireStrictlyAscending(names, field & ".tags")
  if o.held.len > MaxHeldVersions:
    refuse(nrBound, field & ".held has more than " & $MaxHeldVersions &
      " entries")
  var keys: seq[string]
  for i, h in o.held:
    let f = field & ".held[" & $i & "]"
    validateRecordVersion(h.version, f)
    if h.commit.len notin [40, 64] or not isLowerHex(h.commit):
      refuse(nrInvalidText, f & ".commit is not a full-width lower-case " &
        "object id")
    keys.add heldSortKey(h)
  requireStrictlyAscending(keys, field & ".held")

proc validateShard*(s: NimbleShard) =
  if int(s.shardBits) > MaxShardBits:
    refuse(nrBound, "shard: shardBits " & $s.shardBits & " exceeds " &
      $MaxShardBits)
  if uint64(s.bucket) >= (1'u64 shl s.shardBits):
    refuse(nrInconsistent, "shard: bucket " & $s.bucket & " does not exist " &
      "at " & $s.shardBits & " bits")
  if s.packages.len > MaxPackagesPerShard:
    refuse(nrBound, "shard: " & $s.packages.len & " packages, bound " &
      $MaxPackagesPerShard)
  if s.aliases.len > MaxAliasesPerShard:
    refuse(nrBound, "shard: " & $s.aliases.len & " aliases, bound " &
      $MaxAliasesPerShard)
  if s.observations.len > MaxPackagesPerShard:
    refuse(nrBound, "shard: " & $s.observations.len & " observations, " &
      "bound " & $MaxPackagesPerShard)
  if s.packages.len == 0 and s.aliases.len == 0 and s.observations.len == 0:
    refuse(nrInconsistent, "shard: an empty bucket has no shard")
  var keys: seq[string]
  for i, p in s.packages:
    let field = "shard.packages[" & $i & "]"
    validatePackage(p, field)
    let k = nameKey(p.name)
    if shardBucket(k, int(s.shardBits)) != s.bucket:
      refuse(nrWrongShard, field & " " & p.name.escape() & " belongs to " &
        "another shard")
    keys.add k
  requireStrictlyAscending(keys, "shard.packages")
  var aliasKeys: seq[string]
  for i, a in s.aliases:
    let field = "shard.aliases[" & $i & "]"
    checkIdent(a.alias, field & ".alias")
    checkIdent(a.target, field & ".target")
    let k = nameKey(a.alias)
    if k == nameKey(a.target):
      refuse(nrInconsistent, field & " names itself")
    if shardBucket(k, int(s.shardBits)) != s.bucket:
      refuse(nrWrongShard, field & " " & a.alias.escape() & " belongs to " &
        "another shard")
    if keys.binarySearch(k, cmpBytes) >= 0:
      refuse(nrDuplicate, field & " " & a.alias.escape() & " is also a " &
        "package name in this shard")
    aliasKeys.add k
  requireStrictlyAscending(aliasKeys, "shard.aliases")
  var observationKeys: seq[string]
  for i, o in s.observations:
    let field = "shard.observations[" & $i & "]"
    validateObservation(o, field)
    let k = nameKey(o.name)
    if shardBucket(k, int(s.shardBits)) != s.bucket:
      refuse(nrWrongShard, field & " " & o.name.escape() & " belongs to " &
        "another shard")
    if aliasKeys.binarySearch(k, cmpBytes) >= 0:
      refuse(nrInconsistent, field & " " & o.name.escape() & " is an alias " &
        "in this shard, and an alias is not observed")
    observationKeys.add k
  requireStrictlyAscending(observationKeys, "shard.observations")

proc validateRoot*(r: NimbleIndexRoot) =
  checkSpacedAscii(r.generator, "root.generator", MaxNameBytes)
  if int(r.shardBits) > MaxShardBits:
    refuse(nrBound, "root: shardBits " & $r.shardBits & " exceeds " &
      $MaxShardBits)
  if r.shards.len > MaxShards:
    refuse(nrBound, "root: " & $r.shards.len & " shards, bound " & $MaxShards)
  var total = 0'u64
  for i, s in r.shards:
    if uint64(s.bucket) >= (1'u64 shl r.shardBits):
      refuse(nrInconsistent, "root.shards[" & $i & "]: bucket " & $s.bucket &
        " does not exist at " & $r.shardBits & " bits")
    if i > 0 and r.shards[i - 1].bucket >= s.bucket:
      if r.shards[i - 1].bucket == s.bucket:
        refuse(nrDuplicate, "root.shards[" & $i & "] repeats bucket " &
          $s.bucket)
      refuse(nrUnsorted, "root.shards[" & $i & "] is out of canonical order")
    if s.size == 0 or s.size > uint64(MaxShardBytes):
      refuse(nrBound, "root.shards[" & $i & "]: size " & $s.size &
        " is outside 1.." & $MaxShardBytes)
    total += uint64(s.packages)
  if total != uint64(r.packageCount):
    refuse(nrInconsistent, "root: the shards hold " & $total &
      " packages, packageCount says " & $r.packageCount)
  for (name, o, bound) in [("nameMap", r.nameMap, MaxNameMapBytes),
                           ("events", r.events, MaxEventsBytes)]:
    if o.size == 0 or o.size > uint64(bound):
      refuse(nrBound, "root." & name & ": size " & $o.size &
        " is outside 1.." & $bound)

proc validateNameMap*(m: NimbleNameMap) =
  if m.entries.len > MaxNames:
    refuse(nrBound, "name map: " & $m.entries.len & " entries, bound " &
      $MaxNames)
  var keys: seq[string]
  for i, e in m.entries:
    checkIdent(e.name, "nameMap[" & $i & "].name")
    checkIdent(e.target, "nameMap[" & $i & "].target", allowEmpty = true)
    keys.add nameKey(e.name)
  requireStrictlyAscending(keys, "nameMap")
  for i, e in m.entries:
    if e.target.len == 0:
      continue
    let at = keys.binarySearch(nameKey(e.target), cmpBytes)
    if at < 0:
      refuse(nrInconsistent, "nameMap[" & $i & "]: alias target " &
        e.target.escape() & " is not in the map")
    if at == i or m.entries[at].target.len > 0:
      refuse(nrInconsistent, "nameMap[" & $i & "]: an alias names a " &
        "canonical name, never another alias")
    if m.entries[at].name != e.target:
      refuse(nrNonCanonical, "nameMap[" & $i & "]: alias target is not " &
        "spelled as the canonical name")

proc validateEvents*(e: NimbleEvents) =
  if e.events.len > MaxEvents:
    refuse(nrBound, "events: " & $e.events.len & " entries, bound " &
      $MaxEvents)
  var keys: seq[string]
  for i, ev in e.events:
    let f = "events[" & $i & "]"
    checkIdent(ev.package, f & ".package")
    checkIdent(ev.version, f & ".version", allowEmpty = true)
    checkFreeText(ev.before, f & ".before", MaxTextBytes, allowEmpty = true)
    checkFreeText(ev.after, f & ".after", MaxTextBytes, allowEmpty = true)
    keys.add eventSortKey(ev)
  requireStrictlyAscending(keys, "events")

# ---------------------------------------------------------------------------
# Domain <-> wire
# ---------------------------------------------------------------------------

var vocabularyFailure {.threadvar.}: string
  ## The first unknown enumeration value or flag bit met by ``fromW``. The
  ## conversion records it (mapping the value to the enumeration's first
  ## member) and carries on, and the decoder refuses once the conversion has
  ## returned, before validation, so no caller sees the stand-in value:
  ## every ``fromW`` is private and each decoder calls ``checkVocabulary``.
  ## Raising instead, in the middle of an object constructor, leaks the
  ## fields the constructor had already built with this toolchain
  ## (measured: up to 3.7 KB per refusal), and a decoder refuses hostile
  ## input in a loop.

proc vocabulary(field, detail: string) =
  if vocabularyFailure.len == 0:
    vocabularyFailure = field & " " & detail

proc enumFrom[E: enum](v: SomeUnsignedInt; _: typedesc[E]; field: string): E =
  if uint64(v) > uint64(ord(E.high)):
    vocabulary(field, "has unknown value " & $v)
    return E.low
  E(v)

proc checkVocabulary() =
  if vocabularyFailure.len > 0:
    let detail = vocabularyFailure
    vocabularyFailure = ""
    refuse(nrUnknownVocabulary, detail)

proc isConditionsSchemaNode(n: ConditionNode): bool =
  ## A node only shard schema ``NimbleShardConditionsSchema`` can carry.
  n.kind in {cnOsFamily, cnNimVersion} or not n.isPlainNode

proc toW[C: ConditionNodeW | ConditionNodeW3](nodes: seq[ConditionNode];
    field: string; _: typedesc[C]): List[C, MaxConditionNodes] =
  var ws: seq[C]
  for n in nodes:
    when C is ConditionNodeW3:
      ws.add ConditionNodeW3(kind: uint8(ord(n.kind)),
        name: textL(n.name, WCondName, field),
        term: uint8(ord(n.term)), op: uint8(ord(n.op)),
        ints: toL(n.ints, List[uint64, MaxNimVersionInts], field & ".ints"),
        text: textL(n.text, List[byte, MaxNimVersionTextBytes],
          field & ".text"))
    else:
      if n.isConditionsSchemaNode:
        refuse(nrInconsistent, field & ": a " & $n.kind & " condition is " &
          "encoded only in a shard of schema " & $NimbleShardConditionsSchema)
      ws.add ConditionNodeW(kind: uint8(ord(n.kind)),
        name: textL(n.name, WCondName, field))
  toL(ws, List[C, MaxConditionNodes], field)

proc fromW[C: ConditionNodeW | ConditionNodeW3](w: List[C, MaxConditionNodes];
    field: string): seq[ConditionNode] =
  for n in w:
    when C is ConditionNodeW3:
      result.add ConditionNode(kind: enumFrom(n.kind, ConditionNodeKind, field),
        name: wText(n.name),
        term: enumFrom(n.term, NimVersionTerm, field & ".term"),
        op: enumFrom(n.op, ConditionOp, field & ".op"),
        ints: asSeq(n.ints), text: wText(n.text))
    else:
      # Schema 1 and 2 have the seven kinds of NPC-M3 only: the A3 kinds
      # exist in schema 3 alone.
      let k = enumFrom(n.kind, ConditionNodeKind, field)
      if k > cnNot:
        vocabulary(field, "has kind " & $k & ", which only a shard of " &
          "schema " & $NimbleShardConditionsSchema & " carries")
      result.add ConditionNode(kind: k, name: wText(n.name))

proc toW[C: ConditionNodeW | ConditionNodeW3](r: RequirementEntry;
    field: string; _: typedesc[C]): RequirementWT[C] =
  var fs: seq[WName]
  for f in r.features: fs.add textL(f, WName, field & ".features")
  RequirementWT[C](condition: toW(r.condition, field & ".condition", C),
    targetKind: uint8(ord(r.targetKind)),
    target: textL(r.target, WText, field & ".target"),
    subdir: textL(r.subdir, WPath, field & ".subdir"),
    versionKind: uint8(ord(r.versionKind)),
    constraint: textL(r.constraint, WConstraint, field & ".constraint"),
    features: toL(fs, List[WName, MaxRequirementFeatures], field & ".features"),
    source: textL(r.source, WText, field & ".source"))

proc fromW[C: ConditionNodeW | ConditionNodeW3](w: RequirementWT[C];
    field: string): RequirementEntry =
  result.condition = fromW(w.condition, field & ".condition")
  result.targetKind = enumFrom(w.targetKind, RequirementTargetKind,
    field & ".targetKind")
  result.target = wText(w.target)
  result.subdir = wText(w.subdir)
  result.versionKind = enumFrom(w.versionKind, RequirementVersionKind,
    field & ".versionKind")
  result.constraint = wText(w.constraint)
  for f in w.features: result.features.add wText(f)
  result.source = wText(w.source)

proc reqsW[N: static int; C](rs: seq[RequirementEntry]; field: string;
                             _: typedesc[C]): List[RequirementWT[C], N] =
  var ws: seq[RequirementWT[C]]
  for i, r in rs: ws.add toW(r, field & "[" & $i & "]", C)
  toL(ws, List[RequirementWT[C], N], field)

proc reqsFromW(w: auto; field: string): seq[RequirementEntry] =
  for i, r in w: result.add fromW(r, field & "[" & $i & "]")

proc pathsW[N: static int](ps: seq[string]; field: string): List[WPath, N] =
  var ws: seq[WPath]
  for p in ps: ws.add textL(p, WPath, field)
  toL(ws, List[WPath, N], field)

proc pathsFromW(w: auto): seq[string] =
  for p in w: result.add wText(p)

proc binsW[N: static int](ps: seq[NamedBin]; field: string):
    List[NamedBinW, N] =
  var ws: seq[NamedBinW]
  for p in ps:
    ws.add NamedBinW(key: textL(p.key, WPath, field),
      value: textL(p.value, WPath, field))
  toL(ws, List[NamedBinW, N], field)

proc binsFromW(w: auto): seq[NamedBin] =
  for p in w: result.add NamedBin(key: wText(p.key), value: wText(p.value))

proc commitBytes(hex, field: string): seq[byte] =
  if hex.len mod 2 != 0 or not isLowerHex(hex):
    refuse(nrInvalidText, field & " is not lower-case hex")
  for i in countup(0, hex.len - 2, 2):
    result.add byte(parseHexInt(hex[i .. i + 1]))

proc toW[T: VersionRecordW | VersionRecordW2 | VersionRecordW3](
    r: VersionRecord; field: string; _: typedesc[T]): T =
  when T is VersionRecordW3:
    type C = ConditionNodeW3
  else:
    type C = ConditionNodeW
  var comps = r.version.components
  result.version = VersionW(kind: uint8(ord(r.version.kind)),
    components: toL(comps, List[uint64, MaxVersionComponents],
      field & ".version.components"),
    tag: textL(r.version.tag, WName, field & ".version.tag"))
  var commit: seq[byte]
  if r.commit.len mod 2 != 0 or not isLowerHex(r.commit):
    refuse(nrInvalidText, field & ".commit is not lower-case hex")
  for i in countup(0, r.commit.len - 2, 2):
    commit.add byte(parseHexInt(r.commit[i .. i + 1]))
  result.commit = toL(commit, List[byte, MaxCommitBytes], field & ".commit")
  result.tree = r.tree
  result.archiveSha256 = r.archiveSha256
  result.size = r.size
  result.firstSeen = r.firstSeen
  result.origin = r.origin
  result.nim = reqsW[MaxNimEntries, C](r.nim, field & ".nim", C)
  result.requires = reqsW[MaxRequirements, C](r.requires,
    field & ".requires", C)
  var fs: seq[FeatureWT[C]]
  for i, f in r.features:
    fs.add FeatureWT[C](name: textL(f.name, WName, field & ".features"),
      rootOnly: f.rootOnly,
      requires: reqsW[MaxRequirements, C](f.requires,
        field & ".features[" & $i & "].requires", C))
  result.features = toL(fs, List[FeatureWT[C], MaxFeatures],
    field & ".features")
  let l = r.layout
  var conds: seq[ConditionalFieldWT[C]]
  for i, c in l.conditional:
    let f = field & ".layout.conditional[" & $i & "]"
    conds.add ConditionalFieldWT[C](field: uint8(ord(c.field)),
      append: c.append,
      values: pathsW[MaxLayoutEntries](c.values, f & ".values"),
      pairs: binsW[MaxLayoutEntries](c.pairs, f & ".pairs"),
      condition: toW(c.condition, f & ".condition", C))
  var mods: seq[WName]
  for m in l.modules: mods.add textL(m, WName, field & ".layout.modules")
  result.layout = LayoutWT[C](
    srcDir: textL(l.srcDir, WPath, field & ".layout.srcDir"),
    installDirs: pathsW[MaxLayoutEntries](l.installDirs, field & ".layout.installDirs"),
    installFiles: pathsW[MaxLayoutEntries](l.installFiles, field & ".layout.installFiles"),
    installExt: pathsW[MaxLayoutEntries](l.installExt, field & ".layout.installExt"),
    skipDirs: pathsW[MaxLayoutEntries](l.skipDirs, field & ".layout.skipDirs"),
    skipFiles: pathsW[MaxLayoutEntries](l.skipFiles, field & ".layout.skipFiles"),
    skipExt: pathsW[MaxLayoutEntries](l.skipExt, field & ".layout.skipExt"),
    paths: pathsW[MaxLayoutEntries](l.paths, field & ".layout.paths"),
    modules: toL(mods, List[WName, MaxModules], field & ".layout.modules"),
    conditional: toL(conds, List[ConditionalFieldWT[C], MaxConditionalFields],
      field & ".layout.conditional"))
  let b = r.binaries
  result.binaries = BinariesW(
    bin: pathsW[MaxBinaries](b.bin, field & ".binaries.bin"),
    namedBin: binsW[MaxBinaries](b.namedBin, field & ".binaries.namedBin"),
    binDir: textL(b.binDir, WPath, field & ".binaries.binDir"),
    backend: textL(b.backend, WName, field & ".binaries.backend"))
  var fws: seq[ForeignWT[C]]
  for i, d in r.foreign:
    fws.add ForeignWT[C](name: textL(d.name, WText, field & ".foreign"),
      condition: toW(d.condition, field & ".foreign[" & $i & "].condition",
        C))
  result.foreign = toL(fws, List[ForeignWT[C], MaxForeign],
    field & ".foreign")
  var bits = 0'u32
  for f in r.flags: bits = bits or (1'u32 shl ord(f))
  result.flags = bits
  result.readerClass = uint8(ord(r.readerClass))
  result.resolutionClass = uint8(ord(r.resolutionClass))
  result.probePlatform = textL(r.probePlatform, WName, field & ".probePlatform")
  var nf: seq[WDigest]
  if r.nimbleFile.isSome: nf.add r.nimbleFile.get
  result.nimbleFile = toL(nf, List[WDigest, 1], field & ".nimbleFile")
  when T is VersionRecordW2 | VersionRecordW3:
    var sms: seq[SubmoduleW]
    for i, m in r.submodules:
      let f = field & ".submodules[" & $i & "]"
      sms.add SubmoduleW(path: textL(m.path, WPath, f & ".path"),
        url: textL(m.url, WText, f & ".url"),
        commit: toL(commitBytes(m.commit, f & ".commit"),
          List[byte, MaxCommitBytes], f & ".commit"))
    result.submodules = toL(sms, List[SubmoduleW, MaxSubmodules],
      field & ".submodules")
  else:
    if r.submodules.len > 0:
      refuse(nrInconsistent, field & ": a record with submodules is " &
        "encoded only in a shard of schema " & $NimbleShardSubmodulesSchema)

proc fromW[T: VersionRecordW | VersionRecordW2 | VersionRecordW3](w: T;
    field: string): VersionRecord =
  result.version = RecordVersion(
    kind: enumFrom(w.version.kind, RecordVersionKind, field & ".version.kind"),
    components: asSeq(w.version.components),
    tag: wText(w.version.tag))
  result.commit = toHexLower(asSeq(w.commit))
  result.tree = w.tree
  result.archiveSha256 = w.archiveSha256
  result.size = w.size
  result.firstSeen = w.firstSeen
  result.origin = w.origin
  result.nim = reqsFromW(w.nim, field & ".nim")
  result.requires = reqsFromW(w.requires, field & ".requires")
  for i, f in w.features:
    result.features.add RecordFeature(name: wText(f.name), rootOnly: f.rootOnly,
      requires: reqsFromW(f.requires, field & ".features[" & $i & "].requires"))
  let l = w.layout
  result.layout.srcDir = wText(l.srcDir)
  result.layout.installDirs = pathsFromW(l.installDirs)
  result.layout.installFiles = pathsFromW(l.installFiles)
  result.layout.installExt = pathsFromW(l.installExt)
  result.layout.skipDirs = pathsFromW(l.skipDirs)
  result.layout.skipFiles = pathsFromW(l.skipFiles)
  result.layout.skipExt = pathsFromW(l.skipExt)
  result.layout.paths = pathsFromW(l.paths)
  for m in l.modules: result.layout.modules.add wText(m)
  for i, c in l.conditional:
    let f = field & ".layout.conditional[" & $i & "]"
    result.layout.conditional.add RecordConditionalField(
      field: enumFrom(c.field, RecordField, f & ".field"), append: c.append,
      values: pathsFromW(c.values), pairs: binsFromW(c.pairs),
      condition: fromW(c.condition, f & ".condition"))
  result.binaries = RecordBinaries(bin: pathsFromW(w.binaries.bin),
    namedBin: binsFromW(w.binaries.namedBin),
    binDir: wText(w.binaries.binDir), backend: wText(w.binaries.backend))
  for i, d in w.foreign:
    result.foreign.add ForeignDependency(name: wText(d.name),
      condition: fromW(d.condition, field & ".foreign[" & $i & "].condition"))
  if (w.flags and not KnownFlagBits) != 0:
    vocabulary(field & ".flags", "has unknown bits " &
      $(w.flags and not KnownFlagBits))
  for f in RecordFlag:
    if (w.flags and (1'u32 shl ord(f))) != 0:
      result.flags.incl f
  result.readerClass = enumFrom(w.readerClass, RecordReaderClass,
    field & ".readerClass")
  result.resolutionClass = enumFrom(w.resolutionClass, RecordReaderClass,
    field & ".resolutionClass")
  result.probePlatform = wText(w.probePlatform)
  if w.nimbleFile.len == 1:
    result.nimbleFile = some(w.nimbleFile[0])
  when T is VersionRecordW2 | VersionRecordW3:
    for m in w.submodules:
      result.submodules.add RecordSubmodule(path: wText(m.path),
        url: wText(m.url), commit: toHexLower(asSeq(m.commit)))

proc toW[P: PackageW | PackageW2 | PackageW3](p: PackageEnvelope;
    field: string; _: typedesc[P]): P =
  var os: seq[OriginW]
  for o in p.origins:
    os.add OriginW(url: textL(o.url, WText, field & ".origins"),
      subdir: textL(o.subdir, WPath, field & ".origins"),
      vcs: uint8(ord(o.vcs)))
  when P is PackageW3:
    type R = VersionRecordW3
  elif P is PackageW2:
    type R = VersionRecordW2
  else:
    type R = VersionRecordW
  var vs: seq[R]
  for i, v in p.versions:
    vs.add toW(v, field & ".versions[" & $i & "]", R)
  P(name: textL(p.name, WName, field & ".name"),
    origins: toL(os, List[OriginW, MaxOrigins], field & ".origins"),
    registryOrigin: p.registryOrigin,
    versions: toL(vs, List[R, MaxVersionsPerPackage], field & ".versions"))

proc fromW[P: PackageW | PackageW2 | PackageW3](w: P; field: string):
    PackageEnvelope =
  result.name = wText(w.name)
  for i, o in w.origins:
    result.origins.add PackageOrigin(url: wText(o.url), subdir: wText(o.subdir),
      vcs: enumFrom(o.vcs, OriginVcs, field & ".origins[" & $i & "].vcs"))
  result.registryOrigin = w.registryOrigin
  for i, v in w.versions:
    result.versions.add fromW(v, field & ".versions[" & $i & "]")

proc commitL(hex, field: string): List[byte, MaxCommitBytes] =
  ## An object id as bytes; the empty id is the empty list.
  var commit: seq[byte]
  if hex.len mod 2 != 0 or not isLowerHex(hex):
    refuse(nrInvalidText, field & " is not lower-case hex")
  for i in countup(0, hex.len - 2, 2):
    commit.add byte(parseHexInt(hex[i .. i + 1]))
  toL(commit, List[byte, MaxCommitBytes], field)

proc toW(v: RecordVersion; field: string): VersionW =
  var comps = v.components
  VersionW(kind: uint8(ord(v.kind)),
    components: toL(comps, List[uint64, MaxVersionComponents],
      field & ".components"),
    tag: textL(v.tag, WName, field & ".tag"))

proc toW(o: PackageObservation; field: string): ObservationW =
  var tags: seq[ObservedTagW]
  for i, t in o.tags:
    tags.add ObservedTagW(name: textL(t.name, WName, field & ".tags"),
      commit: commitL(t.commit, field & ".tags[" & $i & "].commit"))
  var held: seq[HeldW]
  for i, h in o.held:
    held.add HeldW(version: toW(h.version, field & ".held[" & $i & "]"),
      commit: commitL(h.commit, field & ".held[" & $i & "].commit"),
      firstSeen: h.firstSeen)
  ObservationW(name: textL(o.name, WName, field & ".name"),
    origin: OriginW(url: textL(o.origin.url, WText, field & ".origin"),
      subdir: textL(o.origin.subdir, WPath, field & ".origin"),
      vcs: uint8(ord(o.origin.vcs))),
    state: uint8(ord(o.state)),
    headRef: textL(o.headRef, WName, field & ".headRef"),
    head: commitL(o.head, field & ".head"),
    tags: toL(tags, List[ObservedTagW, MaxObservedTags], field & ".tags"),
    held: toL(held, List[HeldW, MaxHeldVersions], field & ".held"))

proc fromW(w: ObservationW; field: string): PackageObservation =
  result.name = wText(w.name)
  result.origin = PackageOrigin(url: wText(w.origin.url),
    subdir: wText(w.origin.subdir),
    vcs: enumFrom(w.origin.vcs, OriginVcs, field & ".origin.vcs"))
  result.state = enumFrom(w.state, ObservationState, field & ".state")
  result.headRef = wText(w.headRef)
  result.head = toHexLower(asSeq(w.head))
  for t in w.tags:
    result.tags.add ObservedTag(name: wText(t.name),
      commit: toHexLower(asSeq(t.commit)))
  for i, h in w.held:
    result.held.add HeldVersion(
      version: RecordVersion(
        kind: enumFrom(h.version.kind, RecordVersionKind,
          field & ".held[" & $i & "].version.kind"),
        components: asSeq(h.version.components),
        tag: wText(h.version.tag)),
      commit: toHexLower(asSeq(h.commit)), firstSeen: h.firstSeen)

proc hasSubmoduleLists*(s: NimbleShard): bool =
  ## Whether any record of ``s`` carries a ``submodules`` list: what makes
  ## a shard schema ``NimbleShardSubmodulesSchema``.
  for p in s.packages:
    for v in p.versions:
      if v.submodules.len > 0: return true
  false

proc anyConditionsSchemaNode(nodes: seq[ConditionNode]): bool =
  for n in nodes:
    if n.isConditionsSchemaNode: return true
  false

proc anyConditionsSchemaNode(rs: seq[RequirementEntry]): bool =
  for r in rs:
    if anyConditionsSchemaNode(r.condition): return true
  false

proc hasConditionTerms*(r: VersionRecord): bool =
  ## Whether a condition node of ``r`` is one only shard schema
  ## ``NimbleShardConditionsSchema`` carries (a Nim-version comparison or an
  ## OS-family term).
  if anyConditionsSchemaNode(r.nim) or anyConditionsSchemaNode(r.requires):
    return true
  for f in r.features:
    if anyConditionsSchemaNode(f.requires): return true
  for c in r.layout.conditional:
    if anyConditionsSchemaNode(c.condition): return true
  for d in r.foreign:
    if anyConditionsSchemaNode(d.condition): return true
  false

proc hasConditionTerms*(s: NimbleShard): bool =
  for p in s.packages:
    for v in p.versions:
      if v.hasConditionTerms: return true
  false

proc shardSchemaOf*(s: NimbleShard): uint16 =
  ## The one schema ``s`` is encoded in (see the module docstring): 3 when
  ## a condition needs it, else 2 when a record has submodules, else 1.
  if s.hasConditionTerms: NimbleShardConditionsSchema
  elif s.hasSubmoduleLists: NimbleShardSubmodulesSchema
  else: NimbleIndexSchemaVersion

proc toW2T[S: ShardW2 | ShardW3](s: NimbleShard; _: typedesc[S]): S =
  when S is ShardW3:
    type P = PackageW3
    const schema = NimbleShardConditionsSchema
  else:
    type P = PackageW2
    const schema = NimbleShardSubmodulesSchema
  var ps: seq[P]
  for i, p in s.packages:
    ps.add toW(p, "shard.packages[" & $i & "]", P)
  var al: seq[AliasW]
  for a in s.aliases:
    al.add AliasW(alias: textL(a.alias, WName, "shard.aliases"),
      target: textL(a.target, WName, "shard.aliases"))
  var os: seq[ObservationW]
  for i, o in s.observations:
    os.add toW(o, "shard.observations[" & $i & "]")
  S(schema: schema, shardBits: s.shardBits,
    bucket: s.bucket,
    packages: toL(ps, List[P, MaxPackagesPerShard], "shard.packages"),
    aliases: toL(al, List[AliasW, MaxAliasesPerShard], "shard.aliases"),
    observations: toL(os, List[ObservationW, MaxPackagesPerShard],
      "shard.observations"))

proc toW2*(s: NimbleShard): ShardW2 =
  ## ``s`` as a schema-2 shard; refuses a schema-3 condition.
  toW2T(s, ShardW2)

proc toW3*(s: NimbleShard): ShardW3 =
  ## ``s`` as a schema-3 shard.
  toW2T(s, ShardW3)

proc toW*(s: NimbleShard): ShardW =
  ## ``s`` as a schema-1 shard; refuses a record with submodules.
  var ps: seq[PackageW]
  for i, p in s.packages:
    ps.add toW(p, "shard.packages[" & $i & "]", PackageW)
  var al: seq[AliasW]
  for a in s.aliases:
    al.add AliasW(alias: textL(a.alias, WName, "shard.aliases"),
      target: textL(a.target, WName, "shard.aliases"))
  var os: seq[ObservationW]
  for i, o in s.observations:
    os.add toW(o, "shard.observations[" & $i & "]")
  ShardW(schema: NimbleIndexSchemaVersion, shardBits: s.shardBits,
    bucket: s.bucket,
    packages: toL(ps, List[PackageW, MaxPackagesPerShard], "shard.packages"),
    aliases: toL(al, List[AliasW, MaxAliasesPerShard], "shard.aliases"),
    observations: toL(os, List[ObservationW, MaxPackagesPerShard],
      "shard.observations"))

proc fromW[S: ShardW | ShardW2 | ShardW3](w: S): NimbleShard =
  result.shardBits = w.shardBits
  result.bucket = w.bucket
  for i, p in w.packages:
    result.packages.add fromW(p, "shard.packages[" & $i & "]")
  for a in w.aliases:
    result.aliases.add PackageAlias(alias: wText(a.alias),
      target: wText(a.target))
  for i, o in w.observations:
    result.observations.add fromW(o, "shard.observations[" & $i & "]")

proc toW*(r: NimbleIndexRoot): RootW =
  var ss: seq[ShardRefW]
  for s in r.shards:
    ss.add ShardRefW(bucket: s.bucket, id: s.id, size: s.size,
      packages: s.packages)
  var prev: seq[WDigest]
  if r.previousRoot.isSome: prev.add r.previousRoot.get
  RootW(schema: NimbleIndexSchemaVersion,
    generator: textL(r.generator, WName, "root.generator"),
    sourceSet: r.sourceSet, generatedAt: r.generatedAt,
    previousRoot: toL(prev, List[WDigest, 1], "root.previousRoot"),
    packageCount: r.packageCount, versionCount: r.versionCount,
    eventCount: r.eventCount, shardBits: r.shardBits,
    shards: toL(ss, List[ShardRefW, MaxShards], "root.shards"),
    nameMap: ObjectRefW(id: r.nameMap.id, size: r.nameMap.size),
    events: ObjectRefW(id: r.events.id, size: r.events.size))

proc fromW(w: RootW): NimbleIndexRoot =
  result.generator = wText(w.generator)
  result.sourceSet = w.sourceSet
  result.generatedAt = w.generatedAt
  if w.previousRoot.len == 1:
    result.previousRoot = some(w.previousRoot[0])
  result.packageCount = w.packageCount
  result.versionCount = w.versionCount
  result.eventCount = w.eventCount
  result.shardBits = w.shardBits
  for s in w.shards:
    result.shards.add ShardRef(bucket: s.bucket, id: s.id, size: s.size,
      packages: s.packages)
  result.nameMap = ObjectRef(id: w.nameMap.id, size: w.nameMap.size)
  result.events = ObjectRef(id: w.events.id, size: w.events.size)

proc toW(m: NimbleNameMap): NameMapW =
  var es: seq[NameEntryW]
  for e in m.entries:
    es.add NameEntryW(name: textL(e.name, WName, "nameMap"),
      target: textL(e.target, WName, "nameMap"))
  NameMapW(schema: NimbleIndexSchemaVersion,
    entries: toL(es, List[NameEntryW, MaxNames], "nameMap"))

proc fromW(w: NameMapW): NimbleNameMap =
  for e in w.entries:
    result.entries.add NameEntry(name: wText(e.name), target: wText(e.target))

proc toW(e: NimbleEvents): EventsW =
  var es: seq[EventW]
  for ev in e.events:
    es.add EventW(kind: uint8(ord(ev.kind)),
      package: textL(ev.package, WName, "events.package"),
      version: textL(ev.version, WName, "events.version"),
      before: textL(ev.before, WText, "events.before"),
      after: textL(ev.after, WText, "events.after"),
      observedAt: ev.observedAt)
  EventsW(schema: NimbleIndexSchemaVersion,
    events: toL(es, List[EventW, MaxEvents], "events"))

proc fromW(w: EventsW): NimbleEvents =
  for i, ev in w.events:
    result.events.add OriginEvent(
      kind: enumFrom(ev.kind, OriginEventKind, "events[" & $i & "].kind"),
      package: wText(ev.package), version: wText(ev.version),
      before: wText(ev.before), after: wText(ev.after),
      observedAt: ev.observedAt)

# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

proc putU16(buf: var seq[byte]; v: uint16) =
  buf.add byte(v and 0xff)
  buf.add byte(v shr 8)

proc putU32(buf: var seq[byte]; v: uint32) =
  for i in 0 ..< 4:
    buf.add byte((v shr (8 * i)) and 0xff)

proc getU16(b: openArray[byte]; pos: int): uint16 =
  uint16(b[pos]) or (uint16(b[pos + 1]) shl 8)

proc getU32(b: openArray[byte]; pos: int): uint32 =
  for i in 0 ..< 4:
    result = result or (uint32(b[pos + i]) shl (8 * i))

proc typeIdOf*(kind: NimbleObjectKind): uint16 =
  case kind
  of nokRoot: RootTypeId
  of nokShard: ShardTypeId
  of nokNameMap: NameMapTypeId
  of nokEvents: EventsTypeId

proc maxBytesOf*(kind: NimbleObjectKind): int =
  case kind
  of nokRoot: MaxRootBytes
  of nokShard: MaxShardBytes
  of nokNameMap: MaxNameMapBytes
  of nokEvents: MaxEventsBytes

proc frame(kind: NimbleObjectKind; payload: seq[byte]): seq[byte] =
  if FrameHeaderLen + payload.len > maxBytesOf(kind):
    refuse(nrOversize, $kind & " of " & $(FrameHeaderLen + payload.len) &
      " bytes exceeds " & $maxBytesOf(kind))
  result = newSeqOfCap[byte](FrameHeaderLen + payload.len)
  result.add FrameMagic
  result.putU16(NimbleIndexFrameVersion)
  result.putU16(typeIdOf(kind))
  result.putU32(uint32(payload.len))
  result.add payload

proc peekObjectKind*(bytes: openArray[byte]): NimbleObjectKind =
  ## The kind an RBSZ frame says it holds; refuses anything that is not a
  ## Nimble index object frame. Reads the 12-byte header only.
  if bytes.len < FrameHeaderLen:
    refuse(nrTruncated, "shorter than the RBSZ frame header")
  for i in 0 ..< 4:
    if bytes[i] != FrameMagic[i]:
      refuse(nrBadMagic, "not an RBSZ frame")
  if getU16(bytes, 4) != NimbleIndexFrameVersion:
    refuse(nrUnknownFrameVersion, "frame version " & $getU16(bytes, 4))
  case getU16(bytes, 6)
  of RootTypeId: nokRoot
  of ShardTypeId: nokShard
  of NameMapTypeId: nokNameMap
  of EventsTypeId: nokEvents
  else:
    refuse(nrUnknownKind, "type id 0x" & toHex(int(getU16(bytes, 6)), 4) &
      " is not a Nimble index object")

proc acceptsSchema*(kind: NimbleObjectKind; schema: uint16): bool =
  ## The payload schemas a reader of this build decodes for ``kind``.
  schema == NimbleIndexSchemaVersion or
    (kind == nokShard and schema in [NimbleShardSubmodulesSchema,
                                     NimbleShardConditionsSchema])

proc checkFrame(bytes: openArray[byte]; kind: NimbleObjectKind): uint16 =
  ## Everything before the SSZ decode: size bound first, then the header,
  ## the kind, the length and the schema, which it returns.
  if bytes.len > maxBytesOf(kind):
    refuse(nrOversize, $kind & " of " & $bytes.len & " bytes exceeds " &
      $maxBytesOf(kind))
  let got = peekObjectKind(bytes)
  if got != kind:
    refuse(nrUnknownKind, "expected a " & $kind & ", the frame holds a " & $got)
  if FrameHeaderLen + int(getU32(bytes, 8)) != bytes.len:
    refuse(nrLengthMismatch, "the frame length field disagrees with the input")
  if bytes.len < FrameHeaderLen + 2:
    refuse(nrTruncated, $kind & " payload has no schema")
  let schema = getU16(bytes, FrameHeaderLen)
  if not acceptsSchema(kind, schema):
    refuse(nrUnknownSchema, $kind & " schema " & $schema & " (this reader " &
      "accepts " & $NimbleIndexSchemaVersion &
      (if kind == nokShard: ", " & $NimbleShardSubmodulesSchema & " and " &
         $NimbleShardConditionsSchema else: "") &
      ")")
  schema

proc sszFailure(msg: string): NimbleIndexRefusal =
  if "exceeds list limit" in msg: nrBound else: nrMalformed

template decodeWire(bytes: openArray[byte]; T: typedesc; what: string): untyped =
  ## The refusal is raised AFTER the ``except`` branch, never inside it:
  ## with this toolchain, raising from inside an ``except ... as e`` branch
  ## leaks the caught exception (measured: 116 bytes per refusal), and a
  ## decoder refuses hostile input in a loop.
  block:
    var w: T
    var failure = ""
    try:
      w = SSZ.decode(bytes.toOpenArray(FrameHeaderLen, bytes.len - 1), T)
    except SerializationError as e:
      failure = e.msg
    if failure.len > 0:
      refuse(sszFailure(failure), what & ": " & failure)
    w

# ---------------------------------------------------------------------------
# Public encode / decode
# ---------------------------------------------------------------------------

proc encodeShard*(s: NimbleShard): seq[byte] =
  ## ``s`` in the one schema its value has (``shardSchemaOf``).
  validateShard(s)
  case shardSchemaOf(s)
  of NimbleShardConditionsSchema: frame(nokShard, SSZ.encode(toW3(s)))
  of NimbleShardSubmodulesSchema: frame(nokShard, SSZ.encode(toW2(s)))
  else: frame(nokShard, SSZ.encode(toW(s)))

proc decodeShard*(bytes: openArray[byte]): NimbleShard =
  ## Bounded, fail-closed decode of a shard (threat model G3): see the
  ## module docstring for the order of the checks.
  let schema = checkFrame(bytes, nokShard)
  vocabularyFailure = ""
  if schema == NimbleShardConditionsSchema:
    let w = decodeWire(bytes, ShardW3, "shard")
    result = fromW(w)
  elif schema == NimbleShardSubmodulesSchema:
    let w = decodeWire(bytes, ShardW2, "shard")
    result = fromW(w)
  else:
    let w = decodeWire(bytes, ShardW, "shard")
    result = fromW(w)
  checkVocabulary()
  validateShard(result)
  if schema != shardSchemaOf(result):
    refuse(nrNonCanonical, "shard of schema " & $schema & " holds " &
      (if result.hasConditionTerms: "a nim-version or os-family condition"
       elif result.hasSubmoduleLists: "records with submodule lists"
       else: "no record with a submodule list or a schema-3 condition") &
      "; its schema is " & $shardSchemaOf(result))
  if encodeShard(result) != @bytes:
    refuse(nrNonCanonical, "shard does not re-encode to the same bytes")

proc encodeRoot*(r: NimbleIndexRoot): seq[byte] =
  validateRoot(r)
  frame(nokRoot, SSZ.encode(toW(r)))

proc decodeRoot*(bytes: openArray[byte]): NimbleIndexRoot =
  discard checkFrame(bytes, nokRoot)
  let w = decodeWire(bytes, RootW, "root")
  vocabularyFailure = ""
  result = fromW(w)
  checkVocabulary()
  validateRoot(result)
  if frame(nokRoot, SSZ.encode(toW(result))) != @bytes:
    refuse(nrNonCanonical, "root does not re-encode to the same bytes")

proc encodeNameMap*(m: NimbleNameMap): seq[byte] =
  validateNameMap(m)
  frame(nokNameMap, SSZ.encode(toW(m)))

proc decodeNameMap*(bytes: openArray[byte]): NimbleNameMap =
  discard checkFrame(bytes, nokNameMap)
  let w = decodeWire(bytes, NameMapW, "name map")
  vocabularyFailure = ""
  result = fromW(w)
  checkVocabulary()
  validateNameMap(result)
  if frame(nokNameMap, SSZ.encode(toW(result))) != @bytes:
    refuse(nrNonCanonical, "name map does not re-encode to the same bytes")

proc encodeEvents*(e: NimbleEvents): seq[byte] =
  validateEvents(e)
  frame(nokEvents, SSZ.encode(toW(e)))

proc decodeEvents*(bytes: openArray[byte]): NimbleEvents =
  discard checkFrame(bytes, nokEvents)
  let w = decodeWire(bytes, EventsW, "events")
  vocabularyFailure = ""
  result = fromW(w)
  checkVocabulary()
  validateEvents(result)
  if frame(nokEvents, SSZ.encode(toW(result))) != @bytes:
    refuse(nrNonCanonical, "events do not re-encode to the same bytes")

proc decodePackageAs[P: PackageW | PackageW2 | PackageW3](payload: openArray[byte];
                                              field: string;
                                              _: typedesc[P]): PackageEnvelope =
  var w: P
  var failure = ""
  try:
    w = SSZ.decode(payload, P)
  except SerializationError as e:
    failure = e.msg
  if failure.len > 0:
    refuse(sszFailure(failure), field & ": " & failure)
  vocabularyFailure = ""
  result = fromW(w, field)
  checkVocabulary()

proc decodePackageSlice*(payload: openArray[byte]; field: string;
                         shardBits: uint8; bucket: uint32;
                         schema = NimbleIndexSchemaVersion): PackageEnvelope =
  ## Decode ONE package envelope from its SSZ slice inside a shard of
  ## ``schema`` (the navigator's partial access), with the same validation
  ## and canonical-form check a whole-shard decode applies to it.
  if schema == NimbleShardConditionsSchema:
    result = decodePackageAs(payload, field, PackageW3)
  elif schema == NimbleShardSubmodulesSchema:
    result = decodePackageAs(payload, field, PackageW2)
  else:
    result = decodePackageAs(payload, field, PackageW)
  validatePackage(result, field)
  if shardBucket(nameKey(result.name), int(shardBits)) != bucket:
    refuse(nrWrongShard, field & " " & result.name.escape() & " belongs to " &
      "another shard")
  let again =
    if schema == NimbleShardConditionsSchema:
      SSZ.encode(toW(result, field, PackageW3))
    elif schema == NimbleShardSubmodulesSchema:
      SSZ.encode(toW(result, field, PackageW2))
    else:
      SSZ.encode(toW(result, field, PackageW))
  if again != @payload:
    refuse(nrNonCanonical, field & " does not re-encode to the same bytes")
