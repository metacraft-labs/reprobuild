## CBOR body codec for the M83 Phase B `RBPI` envelope.
##
## The body of an `RBPI` envelope is a single CBOR map encoding a
## `ProfileIntent`. The map keys are fixed UTF-8 tags; the
## `libs/cbor/` codec sorts map entries lexicographically on encode,
## so encoding is deterministic for any input value.
##
## Variant encoding convention: each variant value is a CBOR map with
## a `"kind"` text key naming the variant plus a `"value"` key whose
## CBOR shape depends on the variant. After lexicographic key sorting
## "kind" sorts before "value", so the tag always appears first on the
## wire — convenient for streaming readers that want to dispatch
## before consuming the payload.
##
## Signed integers (`FieldValue(fvkInt)`, `ConfigValue(cvkInt)`) are
## encoded as an 8-byte little-endian CBOR byte string of the i64
## bit-pattern. This avoids the cbor lib's lack of major-type-1
## (negative) support and round-trips `low(int)` cleanly.

import std/[algorithm, tables]

import cbor
import repro_profile/types

import ./envelope
import ./errors

# ---------------------------------------------------------------------------
# Field-tag constants (the on-wire key set).
# ---------------------------------------------------------------------------

const
  KeyKind         = "kind"
  KeyValue        = "value"
  KeyName         = "name"
  KeyActivities   = "activities"
  KeyConfigOverrides = "configOverrides"
  KeyHosts        = "hosts"
  KeyResources    = "resources"
  KeyAdapterPreference = "adapterPreference"
    ## M2.5: per-OS adapter chain table. Backward-compat: the key is
    ## OPTIONAL in the decoder — a pre-M2.5 RBPI artifact has no entry
    ## and decodes to an empty adapterPreference table.
  KeyBody         = "body"
  KeyPredicate    = "predicate"
  KeyPkg          = "pkg"
  KeyKey          = "key"
  KeyAddress      = "address"
  KeyFields       = "fields"
  KeyDependsOn    = "dependsOn"
  KeyVersion      = "version"
    ## M69: the literal version pin from `package(<id>, "<version>")`.
    ## Optional; omitted from the CBOR map when empty so existing
    ## pre-M69 RBPI artifacts round-trip unchanged.
  KeyBinaries     = "binaries"
    ## 2026-06-09: the explicit binary names a package installs, used
    ## by the path-based catalog adapter when the package name
    ## doesn't match the binary name (e.g. `ripgrep` -> `rg`).
    ## Optional; omitted when empty so the common case round-trips
    ## unchanged.

  # Variant tag values.
  TagPackageRef   = "packageRef"
  TagWhenGuard    = "whenGuard"
  TagString       = "string"
  TagInt          = "int"
  TagBool         = "bool"
  TagList         = "list"
  TagExpr         = "expr"

# ---------------------------------------------------------------------------
# Signed-int helpers.
# ---------------------------------------------------------------------------

proc i64ToBytes(value: int): seq[byte] =
  ## 8-byte little-endian dump of the i64 bit-pattern. Round-trips
  ## any int64 value (including `low(int)`) without sign-extension
  ## headaches.
  let raw = cast[uint64](int64(value))
  result = newSeq[byte](8)
  for i in 0 ..< 8:
    result[i] = byte((raw shr (i * 8)) and 0xff'u64)

proc bytesToI64(bytes: openArray[byte]): int =
  if bytes.len != 8:
    raiseRbpiCorrupt("body",
      "signed-int byte string must be 8 bytes (was " & $bytes.len & ")")
  var raw: uint64 = 0
  for i in 0 ..< 8:
    raw = raw or (uint64(bytes[i]) shl (i * 8))
  int(cast[int64](raw))

# ---------------------------------------------------------------------------
# Encode: ProfileIntent -> DynamicValue (cbor) -> bytes.
# ---------------------------------------------------------------------------

proc encodeFieldValue(v: FieldValue): DynamicValue =
  case v.kind
  of fvkString:
    cborMap(@[entry(KeyKind, cborText(TagString)),
              entry(KeyValue, cborText(v.s))])
  of fvkInt:
    cborMap(@[entry(KeyKind, cborText(TagInt)),
              entry(KeyValue, cborBytes(i64ToBytes(v.i)))])
  of fvkBool:
    cborMap(@[entry(KeyKind, cborText(TagBool)),
              entry(KeyValue, cborBool(v.b))])
  of fvkList:
    var items: seq[DynamicValue] = @[]
    for it in v.items:
      items.add cborText(it)
    cborMap(@[entry(KeyKind, cborText(TagList)),
              entry(KeyValue, cborArray(items))])
  of fvkExpr:
    cborMap(@[entry(KeyKind, cborText(TagExpr)),
              entry(KeyValue, cborText(v.expr))])

proc encodeConfigValue(v: ConfigValue): DynamicValue =
  case v.kind
  of cvkString:
    cborMap(@[entry(KeyKind, cborText(TagString)),
              entry(KeyValue, cborText(v.s))])
  of cvkInt:
    cborMap(@[entry(KeyKind, cborText(TagInt)),
              entry(KeyValue, cborBytes(i64ToBytes(v.i)))])
  of cvkBool:
    cborMap(@[entry(KeyKind, cborText(TagBool)),
              entry(KeyValue, cborBool(v.b))])
  of cvkExpr:
    cborMap(@[entry(KeyKind, cborText(TagExpr)),
              entry(KeyValue, cborText(v.expr))])

proc encodeResourceAddress(a: ResourceAddress): DynamicValue =
  cborMap(@[entry(KeyKind, cborText(a.kind)),
            entry(KeyName, cborText(a.name))])

proc encodeActivityElement(e: ActivityElement): DynamicValue

proc encodeActivityElementSeq(es: seq[ActivityElement]): DynamicValue =
  var items: seq[DynamicValue] = @[]
  for e in es:
    items.add encodeActivityElement(e)
  cborArray(items)

proc encodeActivityElement(e: ActivityElement): DynamicValue =
  case e.kind
  of aekPackageRef:
    var fields = @[entry(KeyKind, cborText(TagPackageRef)),
                   entry(KeyName, cborText(e.pkgName))]
    if e.pkgVersion.len > 0:
      fields.add entry(KeyVersion, cborText(e.pkgVersion))
    if e.pkgBinaries.len > 0:
      var binItems: seq[DynamicValue] = @[]
      for b in e.pkgBinaries:
        binItems.add cborText(b)
      fields.add entry(KeyBinaries, cborArray(binItems))
    cborMap(fields)
  of aekWhenGuard:
    cborMap(@[entry(KeyKind, cborText(TagWhenGuard)),
              entry(KeyPredicate, cborText(e.predicate.expr)),
              entry(KeyBody, encodeActivityElementSeq(e.guardedBody))])

proc encodeActivity(a: ActivityIntent): DynamicValue =
  cborMap(@[entry(KeyName, cborText(a.name)),
            entry(KeyBody, encodeActivityElementSeq(a.body))])

proc encodeConfigOverride(c: ConfigOverride): DynamicValue =
  cborMap(@[entry(KeyPkg, cborText(c.pkg)),
            entry(KeyKey, cborText(c.key)),
            entry(KeyValue, encodeConfigValue(c.value))])

proc encodeResource(r: ResourceIntent): DynamicValue =
  var fieldEntries: seq[DynamicMapEntry] = @[]
  for fk, fv in r.fields:
    fieldEntries.add entry(fk, encodeFieldValue(fv))
  # cbor's encoder canonicalises map order anyway, but we sort
  # explicitly so the in-memory DynamicValue is also canonical.
  fieldEntries.sort(proc(a, b: DynamicMapEntry): int = cmp(a.key, b.key))
  var deps: seq[DynamicValue] = @[]
  for d in r.dependsOn:
    deps.add encodeResourceAddress(d)
  cborMap(@[entry(KeyKind, cborText(r.kind)),
            entry(KeyAddress, cborText(r.address)),
            entry(KeyFields, cborMap(fieldEntries)),
            entry(KeyDependsOn, cborArray(deps))])

proc encodeHosts(h: Table[string, seq[string]]): DynamicValue =
  var hostEntries: seq[DynamicMapEntry] = @[]
  for hk, hv in h:
    var acts: seq[DynamicValue] = @[]
    for a in hv:
      acts.add cborText(a)
    hostEntries.add entry(hk, cborArray(acts))
  hostEntries.sort(proc(a, b: DynamicMapEntry): int = cmp(a.key, b.key))
  cborMap(hostEntries)

proc encodeAdapterPreference(ap: OrderedTable[string, seq[string]]):
    DynamicValue =
  ## M2.5: per-OS adapter chain table. Same shape as `encodeHosts` —
  ## a CBOR map keyed on canonical OS tags (`"windows"`, `"linux"`,
  ## `"darwin"`) whose values are CBOR arrays of adapter-name text
  ## strings.
  var apEntries: seq[DynamicMapEntry] = @[]
  for osKey, chain in ap:
    var adapters: seq[DynamicValue] = @[]
    for a in chain:
      adapters.add cborText(a)
    apEntries.add entry(osKey, cborArray(adapters))
  apEntries.sort(proc(a, b: DynamicMapEntry): int = cmp(a.key, b.key))
  cborMap(apEntries)

proc encodeProfileIntent(p: ProfileIntent): DynamicValue =
  var acts: seq[DynamicValue] = @[]
  for a in p.activities:
    acts.add encodeActivity(a)
  var cfgs: seq[DynamicValue] = @[]
  for c in p.configOverrides:
    cfgs.add encodeConfigOverride(c)
  var ress: seq[DynamicValue] = @[]
  for r in p.resources:
    ress.add encodeResource(r)
  cborMap(@[entry(KeyName, cborText(p.name)),
            entry(KeyActivities, cborArray(acts)),
            entry(KeyConfigOverrides, cborArray(cfgs)),
            entry(KeyHosts, encodeHosts(p.hosts)),
            entry(KeyResources, cborArray(ress)),
            entry(KeyAdapterPreference,
              encodeAdapterPreference(p.adapterPreference))])

proc encodeProfileIntentToBytes*(p: ProfileIntent): seq[byte] =
  ## CBOR-encode the `ProfileIntent`. Deterministic: same input bytes
  ## always produce the same output bytes (the underlying cbor codec
  ## sorts every map's keys lexicographically).
  encode(encodeProfileIntent(p))

# ---------------------------------------------------------------------------
# Decode: bytes -> DynamicValue -> ProfileIntent.
# ---------------------------------------------------------------------------

proc expectMap(v: DynamicValue; field: string): seq[DynamicMapEntry] =
  if v.kind != dvMap:
    raiseRbpiCorrupt("body",
      "expected a CBOR map for '" & field & "', got " & $v.kind)
  v.mapValue

proc expectText(v: DynamicValue; field: string): string =
  if v.kind != dvText:
    raiseRbpiCorrupt("body",
      "expected a CBOR text value for '" & field & "', got " & $v.kind)
  v.textValue

proc expectArray(v: DynamicValue; field: string): seq[DynamicValue] =
  if v.kind != dvArray:
    raiseRbpiCorrupt("body",
      "expected a CBOR array for '" & field & "', got " & $v.kind)
  v.arrayValue

proc expectBool(v: DynamicValue; field: string): bool =
  if v.kind != dvBool:
    raiseRbpiCorrupt("body",
      "expected a CBOR bool for '" & field & "', got " & $v.kind)
  v.boolValue

proc expectBytes(v: DynamicValue; field: string): seq[byte] =
  if v.kind != dvBytes:
    raiseRbpiCorrupt("body",
      "expected a CBOR byte string for '" & field & "', got " & $v.kind)
  v.bytesValue

proc lookup(entries: seq[DynamicMapEntry]; key, parent: string): DynamicValue =
  for e in entries:
    if e.key == key:
      return e.value
  raiseRbpiCorrupt("body",
    "missing required key '" & key & "' in '" & parent & "'")

proc lookupOpt(entries: seq[DynamicMapEntry]; key: string;
               found: var bool): DynamicValue =
  for e in entries:
    if e.key == key:
      found = true
      return e.value
  found = false

proc decodeFieldValue(v: DynamicValue): FieldValue =
  let entries = expectMap(v, "FieldValue")
  let kind = expectText(lookup(entries, KeyKind, "FieldValue"), KeyKind)
  let value = lookup(entries, KeyValue, "FieldValue")
  case kind
  of TagString: strField(expectText(value, KeyValue))
  of TagInt:    intField(bytesToI64(expectBytes(value, KeyValue)))
  of TagBool:   boolField(expectBool(value, KeyValue))
  of TagList:
    var items: seq[string] = @[]
    for it in expectArray(value, KeyValue):
      items.add expectText(it, KeyValue)
    listField(items)
  of TagExpr:   exprField(expectText(value, KeyValue))
  else:
    raiseRbpiCorrupt("body",
      "unknown FieldValue kind tag '" & kind & "'")

proc decodeConfigValue(v: DynamicValue): ConfigValue =
  let entries = expectMap(v, "ConfigValue")
  let kind = expectText(lookup(entries, KeyKind, "ConfigValue"), KeyKind)
  let value = lookup(entries, KeyValue, "ConfigValue")
  case kind
  of TagString: strValue(expectText(value, KeyValue))
  of TagInt:    intValue(bytesToI64(expectBytes(value, KeyValue)))
  of TagBool:   boolValue(expectBool(value, KeyValue))
  of TagExpr:   exprValue(expectText(value, KeyValue))
  else:
    raiseRbpiCorrupt("body",
      "unknown ConfigValue kind tag '" & kind & "'")

proc decodeResourceAddress(v: DynamicValue): ResourceAddress =
  let entries = expectMap(v, "ResourceAddress")
  ResourceAddress(
    kind: expectText(lookup(entries, KeyKind, "ResourceAddress"), KeyKind),
    name: expectText(lookup(entries, KeyName, "ResourceAddress"), KeyName))

proc decodeActivityElement(v: DynamicValue): ActivityElement

proc decodeActivityElementSeq(arr: seq[DynamicValue]): seq[ActivityElement] =
  for it in arr:
    result.add decodeActivityElement(it)

proc decodeActivityElement(v: DynamicValue): ActivityElement =
  let entries = expectMap(v, "ActivityElement")
  let kind = expectText(lookup(entries, KeyKind, "ActivityElement"), KeyKind)
  case kind
  of TagPackageRef:
    var version = ""
    var versionFound = false
    let verVal = lookupOpt(entries, KeyVersion, versionFound)
    if versionFound:
      version = expectText(verVal, KeyVersion)
    var binaries: seq[string] = @[]
    var binFound = false
    let binVal = lookupOpt(entries, KeyBinaries, binFound)
    if binFound:
      for it in expectArray(binVal, KeyBinaries):
        binaries.add expectText(it, KeyBinaries)
    ActivityElement(kind: aekPackageRef,
      pkgName: expectText(lookup(entries, KeyName, "ActivityElement"),
        KeyName),
      pkgVersion: version,
      pkgBinaries: binaries)
  of TagWhenGuard:
    ActivityElement(kind: aekWhenGuard,
      predicate: PredicateExpr(expr: expectText(
        lookup(entries, KeyPredicate, "ActivityElement"), KeyPredicate)),
      guardedBody: decodeActivityElementSeq(expectArray(
        lookup(entries, KeyBody, "ActivityElement"), KeyBody)))
  else:
    raiseRbpiCorrupt("body",
      "unknown ActivityElement kind tag '" & kind & "'")

proc decodeActivity(v: DynamicValue): ActivityIntent =
  let entries = expectMap(v, "ActivityIntent")
  result.name = expectText(lookup(entries, KeyName, "ActivityIntent"), KeyName)
  result.body = decodeActivityElementSeq(expectArray(
    lookup(entries, KeyBody, "ActivityIntent"), KeyBody))

proc decodeConfigOverride(v: DynamicValue): ConfigOverride =
  let entries = expectMap(v, "ConfigOverride")
  ConfigOverride(
    pkg: expectText(lookup(entries, KeyPkg, "ConfigOverride"), KeyPkg),
    key: expectText(lookup(entries, KeyKey, "ConfigOverride"), KeyKey),
    value: decodeConfigValue(lookup(entries, KeyValue, "ConfigOverride")))

proc decodeResource(v: DynamicValue): ResourceIntent =
  let entries = expectMap(v, "ResourceIntent")
  result.kind = expectText(
    lookup(entries, KeyKind, "ResourceIntent"), KeyKind)
  result.address = expectText(
    lookup(entries, KeyAddress, "ResourceIntent"), KeyAddress)
  let fieldsEntries = expectMap(
    lookup(entries, KeyFields, "ResourceIntent"), KeyFields)
  for fe in fieldsEntries:
    result.fields[fe.key] = decodeFieldValue(fe.value)
  for d in expectArray(
      lookup(entries, KeyDependsOn, "ResourceIntent"), KeyDependsOn):
    result.dependsOn.add decodeResourceAddress(d)

proc decodeHosts(v: DynamicValue): Table[string, seq[string]] =
  let entries = expectMap(v, "hosts")
  for e in entries:
    var acts: seq[string] = @[]
    for it in expectArray(e.value, "hosts.value"):
      acts.add expectText(it, "hosts.value")
    result[e.key] = acts

proc decodeAdapterPreference(v: DynamicValue):
    OrderedTable[string, seq[string]] =
  ## M2.5: decode the per-OS adapter chain table. Mirrors `decodeHosts`
  ## but writes to an OrderedTable so the iteration order is stable.
  result = initOrderedTable[string, seq[string]]()
  let entries = expectMap(v, "adapterPreference")
  for e in entries:
    var chain: seq[string] = @[]
    for it in expectArray(e.value, "adapterPreference.value"):
      chain.add expectText(it, "adapterPreference.value")
    result[e.key] = chain

proc decodeProfileIntentFromBytes*(bytes: openArray[byte]): ProfileIntent =
  ## Round-trip with `encodeProfileIntentToBytes`. Raises
  ## `ERbpiCorrupt(field: "body")` on malformed CBOR or schema
  ## mismatch (unknown tag / missing required key / wrong value
  ## kind).
  var root: DynamicValue
  try:
    root = decode(bytes)
  except CborError as e:
    raiseRbpiCorrupt("body", "malformed CBOR: " & e.msg)
  let entries = expectMap(root, "ProfileIntent")
  result.name = expectText(
    lookup(entries, KeyName, "ProfileIntent"), KeyName)
  for a in expectArray(
      lookup(entries, KeyActivities, "ProfileIntent"), KeyActivities):
    result.activities.add decodeActivity(a)
  for c in expectArray(
      lookup(entries, KeyConfigOverrides, "ProfileIntent"),
      KeyConfigOverrides):
    result.configOverrides.add decodeConfigOverride(c)
  result.hosts = decodeHosts(
    lookup(entries, KeyHosts, "ProfileIntent"))
  for r in expectArray(
      lookup(entries, KeyResources, "ProfileIntent"), KeyResources):
    result.resources.add decodeResource(r)
  # M2.5: adapter preference is OPTIONAL — a pre-M2.5 RBPI artifact
  # (cached before this codec extension) has no `KeyAdapterPreference`
  # entry, in which case the decoded value carries an empty table.
  var apFound = false
  let apNode = lookupOpt(entries, KeyAdapterPreference, apFound)
  if apFound:
    result.adapterPreference = decodeAdapterPreference(apNode)
  else:
    result.adapterPreference = initOrderedTable[string, seq[string]]()

# ---------------------------------------------------------------------------
# Convenience wrappers — wrap/unwrap the envelope around the CBOR body.
# ---------------------------------------------------------------------------

proc encodeRbpi*(p: ProfileIntent): seq[byte] =
  ## Convenience: `wrapEnvelope(encodeProfileIntentToBytes(p))`.
  wrapEnvelope(encodeProfileIntentToBytes(p))

proc decodeRbpi*(bytes: openArray[byte]): ProfileIntent =
  ## Convenience: `decodeProfileIntentFromBytes(readEnvelope(bytes))`.
  decodeProfileIntentFromBytes(readEnvelope(bytes))
