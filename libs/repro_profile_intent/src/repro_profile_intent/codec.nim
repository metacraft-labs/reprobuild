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
from repro_profile/host_system import hostSystemDeclProblem

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
  KeyBuildActions = "buildActions"
    ## Windows-System-Resources Phase G: action-edge intent items
    ## emitted by typed-tool ``.build(...)`` and ``inlineExecCall(...)``
    ## calls inside a profile ``resources:`` block. Backward-compat:
    ## the key is OPTIONAL in the decoder — a pre-Phase-G RBPI artifact
    ## (cached before this codec extension) has no entry and decodes
    ## with an empty ``buildActions`` seq, so existing profile-compile
    ## fixtures survive the codec bump without a re-encode.
  KeyDataFiles    = "dataFiles"
    ## GM4: the plan-time data-file references a profile's `data:` section
    ## declares (`ProfileIntent.dataFiles`). Optional; omitted when empty,
    ## so a profile without data files encodes exactly as before. Envelope
    ## schema 5.
  KeyCatalogImports = "catalogImports"
    ## The contribution-catalog modules a profile's `catalogs:` section
    ## imports (`ProfileIntent.catalogImports`). Optional; omitted when
    ## empty, so a profile without the section encodes exactly as before.
    ## Envelope schema 6.
  KeyHostApplies  = "hostApplies"
    ## The concerns Reprobuild applies per host (`ProfileIntent.hostApplies`,
    ## a block-form `hosts:` entry's `applies:`). Optional; omitted when no
    ## host declares, so a profile without a declaration encodes exactly as
    ## before. Envelope schema 7.
  KeyHostSystems  = "hostSystems"
    ## GM10 + add-on mode: the hosts whose `hosts:` entry has a `system:` key
    ## (`ProfileIntent.hostSystems`): a map host -> map carrying `"mode"`
    ## (text: `managedElsewhere`, `addOn` or `full`), `"managedBy"` (text)
    ## only when the entry names a manager, and `"activities"` (array of
    ## text) only when an `addOn` / `full` entry selects system activities. Optional; omitted when
    ## no host entry has the key, so a profile without the attribute encodes
    ## exactly as before. Envelope schema 13 (11 replaced schema 9's
    ## `"systemManagedElsewhere"` map, which could not say `addOn`; 13 added
    ## the `full` mode).
  KeyMode         = "mode"
  KeyManagedBy    = "managedBy"
  KeySystemActivities = "activities"
  KeyAddOn        = "addOn"
    ## ReproOS add-on mode: the profile-wide `addOn:` section
    ## (`ProfileIntent.addOn`), a map with `"managedEtcPrefixes"` (an array
    ## of text). Optional; omitted when the profile declares none, so a
    ## profile without the section encodes exactly as before. Envelope
    ## schema 12.
  KeyManagedEtcPrefixes = "managedEtcPrefixes"
  KeyConfirmTimeout = "confirmTimeout"
    ## Inside the `addOn` map: the add-on switch's `confirmTimeout` in
    ## seconds (ReproOS-Add-On Mode §7.5), as an unsigned integer. Optional;
    ## omitted when not declared, so a section without it encodes as before.
  KeyStowScopes   = "stowScopes"
    ## GM11: the activities' stow claims (`ProfileIntent.stowScopes`): an
    ## array of maps with `"package"` and `"activity"` (text) and, under a
    ## guard, `"guard"` (text). Optional; omitted when no activity claims a
    ## stow package, so a profile without a `stow:` block encodes exactly as
    ## before. Envelope schema 10.
  KeyPackage      = "package"
  KeyArgv         = "argv"
  KeyCwd          = "cwd"
  KeyDeps         = "deps"
  KeyInputs       = "inputs"
  KeyOutputs      = "outputs"
  KeyCommandStatsId = "commandStatsId"
  KeyToolIdentityRefs = "toolIdentityRefs"
  KeyRequiresElevation = "requiresElevation"
  KeyCacheable    = "cacheable"
  KeySubstituteOnly = "substituteOnly"
  KeyExpectedOutputDigest = "expectedOutputDigest"
  KeyId           = "id"
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
  KeyGuard        = "guard"
    ## GM3: the runtime predicate a ResourceIntent / ConfigOverride
    ## applies under (`ResourceIntent.guard`). Optional; omitted when the
    ## element applies on every host. Envelope schema 4.
  KeyActivity     = "activity"
    ## GM9: the activity a ResourceIntent belongs to
    ## (`ResourceIntent.activity`). Optional; omitted for a profile-wide
    ## resource. Envelope schema 8.
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
  var fields = @[entry(KeyPkg, cborText(c.pkg)),
                 entry(KeyKey, cborText(c.key)),
                 entry(KeyValue, encodeConfigValue(c.value))]
  if c.guard.expr.len > 0:
    fields.add entry(KeyGuard, cborText(c.guard.expr))
  cborMap(fields)

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
  var fields = @[entry(KeyKind, cborText(r.kind)),
                 entry(KeyAddress, cborText(r.address)),
                 entry(KeyFields, cborMap(fieldEntries)),
                 entry(KeyDependsOn, cborArray(deps))]
  if r.guard.expr.len > 0:
    fields.add entry(KeyGuard, cborText(r.guard.expr))
  if r.activity.len > 0:
    fields.add entry(KeyActivity, cborText(r.activity))
  cborMap(fields)

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

proc encodeStringArray(items: seq[string]): DynamicValue =
  var arr: seq[DynamicValue] = @[]
  for it in items:
    arr.add cborText(it)
  cborArray(arr)

proc encodeBuildAction(b: ProfileBuildAction): DynamicValue =
  ## Windows-System-Resources Phase G: CBOR map for one
  ## ``ProfileBuildAction``. Every field is required on the wire — the
  ## flattened mirror has fixed shape, no optional keys. ``cacheable``
  ## defaults to true at the helper level so a decoded value never
  ## carries an undefined cacheability semantic.
  cborMap(@[
    entry(KeyId, cborText(b.id)),
    entry(KeyArgv, encodeStringArray(b.argv)),
    entry(KeyCwd, cborText(b.cwd)),
    entry(KeyDeps, encodeStringArray(b.deps)),
    entry(KeyInputs, encodeStringArray(b.inputs)),
    entry(KeyOutputs, encodeStringArray(b.outputs)),
    entry(KeyCommandStatsId, cborText(b.commandStatsId)),
    entry(KeyToolIdentityRefs, encodeStringArray(b.toolIdentityRefs)),
    entry(KeyRequiresElevation, cborBool(b.requiresElevation)),
    entry(KeyCacheable, cborBool(b.cacheable)),
    entry(KeySubstituteOnly, cborBool(b.substituteOnly)),
    entry(KeyExpectedOutputDigest, cborText(b.expectedOutputDigest))])

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
  var bas: seq[DynamicValue] = @[]
  for b in p.buildActions:
    bas.add encodeBuildAction(b)
  var entries = @[entry(KeyName, cborText(p.name)),
            entry(KeyActivities, cborArray(acts)),
            entry(KeyConfigOverrides, cborArray(cfgs)),
            entry(KeyHosts, encodeHosts(p.hosts)),
            entry(KeyResources, cborArray(ress)),
            entry(KeyBuildActions, cborArray(bas)),
            entry(KeyAdapterPreference,
              encodeAdapterPreference(p.adapterPreference))]
  if p.dataFiles.len > 0:
    entries.add entry(KeyDataFiles, encodeStringArray(p.dataFiles))
  if p.catalogImports.len > 0:
    entries.add entry(KeyCatalogImports, encodeStringArray(p.catalogImports))
  if p.addOn.declared:
    var ao = @[entry(KeyManagedEtcPrefixes,
      encodeStringArray(p.addOn.managedEtcPrefixes))]
    if p.addOn.confirmTimeoutSec > 0:
      ao.add entry(KeyConfirmTimeout, cborUInt(uint64(p.addOn.confirmTimeoutSec)))
    entries.add entry(KeyAddOn, cborMap(ao))
  if p.hostApplies.len > 0:
    entries.add entry(KeyHostApplies, encodeHosts(p.hostApplies))
  if p.hostSystems.len > 0:
    var hostEntries: seq[DynamicMapEntry] = @[]
    for host, decl in p.hostSystems:
      var inner = @[entry(KeyMode, cborText($decl.mode))]
      if decl.managedBy.len > 0:
        inner.add entry(KeyManagedBy, cborText(decl.managedBy))
      if decl.activities.len > 0:
        inner.add entry(KeySystemActivities,
          encodeStringArray(decl.activities))
      hostEntries.add entry(host, cborMap(inner))
    hostEntries.sort(proc(a, b: DynamicMapEntry): int = cmp(a.key, b.key))
    entries.add entry(KeyHostSystems, cborMap(hostEntries))
  if p.stowScopes.len > 0:
    # Declaration order is kept (an array): it is the order diagnostics
    # name the claims in.
    var claims: seq[DynamicValue] = @[]
    for s in p.stowScopes:
      var fields = @[entry(KeyPackage, cborText(s.package)),
                     entry(KeyActivity, cborText(s.activity))]
      if s.guard.expr.len > 0:
        fields.add entry(KeyGuard, cborText(s.guard.expr))
      claims.add cborMap(fields)
    entries.add entry(KeyStowScopes, cborArray(claims))
  cborMap(entries)

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

proc decodeGuard(entries: seq[DynamicMapEntry]): PredicateExpr =
  var found = false
  let v = lookupOpt(entries, KeyGuard, found)
  if found:
    result.expr = expectText(v, KeyGuard)

proc decodeConfigOverride(v: DynamicValue): ConfigOverride =
  let entries = expectMap(v, "ConfigOverride")
  ConfigOverride(
    pkg: expectText(lookup(entries, KeyPkg, "ConfigOverride"), KeyPkg),
    key: expectText(lookup(entries, KeyKey, "ConfigOverride"), KeyKey),
    value: decodeConfigValue(lookup(entries, KeyValue, "ConfigOverride")),
    guard: decodeGuard(entries))

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
  result.guard = decodeGuard(entries)
  var activityFound = false
  let activity = lookupOpt(entries, KeyActivity, activityFound)
  if activityFound:
    result.activity = expectText(activity, KeyActivity)

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
  # Windows-System-Resources Phase G: ``buildActions`` is OPTIONAL on
  # the wire — a pre-Phase-G RBPI artifact (cached before this codec
  # extension) has no ``KeyBuildActions`` entry and decodes with an
  # empty seq. New artifacts ALWAYS carry the key (even when the seq
  # is empty) so a structural integrity check at apply time can
  # distinguish "this profile has no action edges" from "this artifact
  # predates the action-edge feature".
  var baFound = false
  let baNode = lookupOpt(entries, KeyBuildActions, baFound)
  if baFound:
    for b in expectArray(baNode, KeyBuildActions):
      let bEntries = expectMap(b, "ProfileBuildAction")
      var ba = ProfileBuildAction(
        id: expectText(lookup(bEntries, KeyId, "ProfileBuildAction"),
          KeyId),
        cwd: expectText(lookup(bEntries, KeyCwd, "ProfileBuildAction"),
          KeyCwd),
        commandStatsId: expectText(lookup(bEntries, KeyCommandStatsId,
          "ProfileBuildAction"), KeyCommandStatsId),
        requiresElevation: expectBool(lookup(bEntries,
          KeyRequiresElevation, "ProfileBuildAction"),
          KeyRequiresElevation),
        cacheable: expectBool(lookup(bEntries, KeyCacheable,
          "ProfileBuildAction"), KeyCacheable))
      # Optional on decode: a cached envelope written before the
      # substitute-only edge existed carries neither key and is an
      # ordinary buildable edge, which is what it was.
      var soFound, eodFound: bool
      let soNode = lookupOpt(bEntries, KeySubstituteOnly, soFound)
      if soFound:
        ba.substituteOnly = expectBool(soNode, KeySubstituteOnly)
      let eodNode = lookupOpt(bEntries, KeyExpectedOutputDigest, eodFound)
      if eodFound:
        ba.expectedOutputDigest = expectText(eodNode, KeyExpectedOutputDigest)
      for it in expectArray(lookup(bEntries, KeyArgv,
          "ProfileBuildAction"), KeyArgv):
        ba.argv.add expectText(it, KeyArgv)
      for it in expectArray(lookup(bEntries, KeyDeps,
          "ProfileBuildAction"), KeyDeps):
        ba.deps.add expectText(it, KeyDeps)
      for it in expectArray(lookup(bEntries, KeyInputs,
          "ProfileBuildAction"), KeyInputs):
        ba.inputs.add expectText(it, KeyInputs)
      for it in expectArray(lookup(bEntries, KeyOutputs,
          "ProfileBuildAction"), KeyOutputs):
        ba.outputs.add expectText(it, KeyOutputs)
      for it in expectArray(lookup(bEntries, KeyToolIdentityRefs,
          "ProfileBuildAction"), KeyToolIdentityRefs):
        ba.toolIdentityRefs.add expectText(it, KeyToolIdentityRefs)
      result.buildActions.add ba
  # M2.5: adapter preference is OPTIONAL — a pre-M2.5 RBPI artifact
  # (cached before this codec extension) has no `KeyAdapterPreference`
  # entry, in which case the decoded value carries an empty table.
  var apFound = false
  let apNode = lookupOpt(entries, KeyAdapterPreference, apFound)
  if apFound:
    result.adapterPreference = decodeAdapterPreference(apNode)
  else:
    result.adapterPreference = initOrderedTable[string, seq[string]]()
  # GM4: data-file references are OPTIONAL on the wire (absent when the
  # profile declares none).
  var dfFound = false
  let dfNode = lookupOpt(entries, KeyDataFiles, dfFound)
  if dfFound:
    for it in expectArray(dfNode, KeyDataFiles):
      result.dataFiles.add expectText(it, KeyDataFiles)
  # Contribution-catalog imports are OPTIONAL on the wire (absent when the
  # profile declares none).
  var ciFound = false
  let ciNode = lookupOpt(entries, KeyCatalogImports, ciFound)
  if ciFound:
    for it in expectArray(ciNode, KeyCatalogImports):
      result.catalogImports.add expectText(it, KeyCatalogImports)
  # ReproOS add-on mode: the `addOn:` section is OPTIONAL on the wire
  # (absent when the profile declares none). A malformed one is corrupt.
  var aoFound = false
  let aoNode = lookupOpt(entries, KeyAddOn, aoFound)
  if aoFound:
    let ao = expectMap(aoNode, KeyAddOn)
    result.addOn.declared = true
    for it in expectArray(lookup(ao, KeyManagedEtcPrefixes, KeyAddOn),
                          KeyManagedEtcPrefixes):
      result.addOn.managedEtcPrefixes.add expectText(it, KeyManagedEtcPrefixes)
    var ctFound = false
    let ct = lookupOpt(ao, KeyConfirmTimeout, ctFound)
    if ctFound:
      if ct.kind != dvUInt or ct.uintValue == 0 or ct.uintValue > 86400'u64:
        raiseRbpiCorrupt("body", "addOn.confirmTimeout must be a positive " &
          "number of seconds")
      result.addOn.confirmTimeoutSec = int(ct.uintValue)
  # The per-host concern declaration is OPTIONAL on the wire (absent when
  # no host declares one).
  var haFound = false
  let haNode = lookupOpt(entries, KeyHostApplies, haFound)
  if haFound:
    result.hostApplies = decodeHosts(haNode)
  # GM10 + add-on mode: the system-management attribute is OPTIONAL on the
  # wire (absent when no host entry has a `system:` key). An entry with an
  # unknown mode, or one the `profile` macro could not have produced
  # (`hostSystemDeclProblem`), is refused as corrupt -- never read as
  # "managed here".
  var hsFound = false
  let hsNode = lookupOpt(entries, KeyHostSystems, hsFound)
  if hsFound:
    for e in expectMap(hsNode, KeyHostSystems):
      let inner = expectMap(e.value, KeyHostSystems)
      var modeFound, pointerFound, actsFound = false
      let modeNode = lookupOpt(inner, KeyMode, modeFound)
      if not modeFound:
        raiseRbpiCorrupt("body", KeyHostSystems & "." & e.key &
          " has no `" & KeyMode & "`")
      var decl: HostSystemDecl
      let modeText = expectText(modeNode, KeyMode)
      case modeText
      of $hsmManagedElsewhere: decl.mode = hsmManagedElsewhere
      of $hsmAddOn: decl.mode = hsmAddOn
      of $hsmFull: decl.mode = hsmFull
      else:
        raiseRbpiCorrupt("body", KeyHostSystems & "." & e.key &
          " has an unknown mode `" & modeText & "`")
      let pointerNode = lookupOpt(inner, KeyManagedBy, pointerFound)
      if pointerFound:
        decl.managedBy = expectText(pointerNode, KeyManagedBy)
      let actsNode = lookupOpt(inner, KeySystemActivities, actsFound)
      if actsFound:
        for it in expectArray(actsNode, KeySystemActivities):
          decl.activities.add expectText(it, KeySystemActivities)
      let problem = hostSystemDeclProblem(decl)
      if problem.len > 0:
        raiseRbpiCorrupt("body", KeyHostSystems & "." & e.key & ": " &
          problem)
      result.hostSystems[e.key] = decl
  # GM11: the stow claims are OPTIONAL on the wire (absent when no activity
  # claims a stow package). A malformed claim is refused as corrupt.
  var ssFound = false
  let ssNode = lookupOpt(entries, KeyStowScopes, ssFound)
  if ssFound:
    for it in expectArray(ssNode, KeyStowScopes):
      let claim = expectMap(it, KeyStowScopes)
      var guardFound = false
      let guardNode = lookupOpt(claim, KeyGuard, guardFound)
      result.stowScopes.add StowScope(
        package: expectText(lookup(claim, KeyPackage, KeyStowScopes),
          KeyPackage),
        activity: expectText(lookup(claim, KeyActivity, KeyStowScopes),
          KeyActivity),
        guard: PredicateExpr(expr:
          if guardFound: expectText(guardNode, KeyGuard) else: ""))

# ---------------------------------------------------------------------------
# Convenience wrappers — wrap/unwrap the envelope around the CBOR body.
# ---------------------------------------------------------------------------

proc encodeRbpi*(p: ProfileIntent): seq[byte] =
  ## Convenience: `wrapEnvelope(encodeProfileIntentToBytes(p))`.
  wrapEnvelope(encodeProfileIntentToBytes(p))

proc decodeRbpi*(bytes: openArray[byte]): ProfileIntent =
  ## Convenience: `decodeProfileIntentFromBytes(readEnvelope(bytes))`.
  decodeProfileIntentFromBytes(readEnvelope(bytes))
