## The `RBPI` ("Reprobuild Profile Intent") binary envelope (M83
## Phase B). Mirrors the M69 `RBIP` plan envelope and the M69 `RBSL`
## audit-log record so the three on-disk artefact families share a
## single magic+version+bodyLen+body+checksum framing.
##
## On-disk shape (little-endian throughout):
##
##   offset 0   : magic            4 bytes ASCII "RBPI"
##   offset 4   : schemaVersion    u16 LE
##   offset 6   : bodyLength       u32 LE
##   offset 10  : body             bodyLength bytes (CBOR — see codec.nim)
##   trailing   : checksum         32 bytes BLAKE3-256
##                                 over magic + version + bodyLen + body
##
## Total envelope size = 10 + bodyLen + 32 bytes.
##
## The reader is STRICT: bad magic, unsupported version, declared body
## length that disagrees with the file size, and trailing-checksum
## mismatch all raise `ERbpiCorrupt` with the offending FIELD tagged.

import blake3
import repro_core

import ./errors

const
  RbpiMagic*         = "RBPI"           ## 4-byte ASCII envelope magic.
  RbpiSchemaVersion* = 13'u16           ## Current envelope schema version.
    ##
    ## Version history:
    ##   1 (M83 Phase B): initial envelope; ActivityElement carries
    ##     pkgName only on the CBOR side (pkgVersion was dropped at the
    ##     RBPI boundary in early M83 — a latent bug). configOverrides,
    ##     hosts, resources, adapterPreference all present.
    ##   2 (2026-06-09): ActivityElement.aekPackageRef CBOR map gains
    ##     two OPTIONAL fields:
    ##       "version"  -- the literal version pin (fixes the M83
    ##                     drop); present only when non-empty.
    ##       "binaries" -- the explicit binary names a package installs,
    ##                     used by path-based catalog adapters when the
    ##                     package name doesn't match the binary name
    ##                     (e.g. `ripgrep` -> `rg`); present only when
    ##                     non-empty.
    ##     The version bump matters for the on-disk cache: the profile
    ##     compile edge's weak fingerprint named the schema version
    ##     (`profileCompileWeakFingerprint`), so an action-cache record
    ##     written for v1 was never served for v2; v1 files are also
    ##     rejected by the strict reader at read time
    ##     (`unsupported RBPI schema version`). Since the profile compile
    ##     was split into a compile edge and a run edge (2026-10-22), no
    ##     edge outputs the envelope: `compileProfileToRbpi` encodes it from
    ##     the run edge's intent document on every call, so a schema bump
    ##     takes effect on the next call without any cache key naming it.
    ##   3 (Windows-System-Resources Phase G): ProfileIntent gains a
    ##     new top-level CBOR key ``"buildActions"`` carrying the list
    ##     of profile-scope action-edge intents (typed-tool
    ##     ``.build(...)`` and bare ``inlineExecCall(...)`` calls
    ##     emitted from inside a profile ``resources:`` block — see
    ##     ``repro_profile.types.ProfileBuildAction``). The decoder
    ##     treats the key as OPTIONAL so a v2 artifact still decodes
    ##     (degrading to an empty seq); the version bump exists so the
    ##     cache-hit path's strict-reader rejection re-runs the macro
    ##     after this build upgrades, in case the new macro path is
    ##     reachable from a profile that compiled cleanly under v2.
    ##   4 (GM3, platform-neutral intent): ResourceIntent and
    ##     ConfigOverride CBOR maps gain an OPTIONAL ``"guard"`` text
    ##     field -- the runtime predicate under which the element
    ##     applies, present only when non-empty. Bumped because a build
    ##     that did not know the key would decode a guarded element as
    ##     unconditional and apply it on every host.
    ##   5 (GM4, plan-time data files): ProfileIntent gains an OPTIONAL
    ##     top-level ``"dataFiles"`` array of text -- the data files the
    ##     profile's ``data:`` section names, which the planner reads and
    ##     expands. Bumped because a build that did not know the key would
    ##     plan the profile without the rows those files contribute.
    ##   6 (contribution-catalog imports): ProfileIntent gains an
    ##     OPTIONAL top-level ``"catalogImports"`` array of text -- the
    ##     contribution-catalog modules the profile's ``catalogs:`` section
    ##     imports. Bumped because a build that did not know the key would
    ##     resolve the profile's packages without those catalogs'
    ##     contributions.
    ##   7 (GM7, concern-scoped apply): ProfileIntent gains an OPTIONAL
    ##     top-level ``"hostApplies"`` map (host -> concern names) -- the
    ##     concerns a block-form ``hosts:`` entry says Reprobuild applies on
    ##     that host. Bumped because a build that did not know the key would
    ##     apply every concern on a host that hands some of them to another
    ##     tool.
    ##   8 (GM9, activity-scoped resources): ResourceIntent CBOR maps gain
    ##     an OPTIONAL ``"activity"`` text field -- the activity the
    ##     resource belongs to, present only when non-empty. Bumped
    ##     because a build that did not know the key would decode an
    ##     activity-scoped resource as profile-wide and apply it on hosts
    ##     that do not select the activity.
    ##   9 (GM10, host system-management attribute): ProfileIntent gains an
    ##     OPTIONAL top-level ``"systemManagedElsewhere"`` map (host -> map
    ##     with an optional ``"managedBy"`` text) -- the hosts whose
    ##     block-form ``hosts:`` entry says ``system: managedElsewhere[(...)]``.
    ##     Bumped because a build that did not know the key would let
    ##     ``repro infra apply`` take over a host whose system another
    ##     repository manages.
    ##  10 (GM11, activity-scoped stow packages): ProfileIntent gains an
    ##     OPTIONAL top-level ``"stowScopes"`` array (maps with ``"package"``,
    ##     ``"activity"`` and an optional ``"guard"``) -- the `stow/` packages
    ##     an activity's ``stow:`` block claims. Bumped because a build that
    ##     did not know the key would materialize a claimed package on every
    ##     host, including the ones that do not select its activity.
    ##  11 (ReproOS add-on mode): the GM10 ``"systemManagedElsewhere"`` map
    ##     becomes the three-valued ``"hostSystems"`` map (host -> map with
    ##     ``"mode"`` text -- ``managedElsewhere`` or ``addOn`` -- an optional
    ##     ``"managedBy"`` text and an optional ``"activities"`` array of
    ##     text, the system activities an add-on entry selects). Bumped
    ##     because a schema-10 reader would decode an add-on host as one whose
    ##     whole system is managed here, and plan or switch it as such.
    ##  12 (ReproOS add-on mode, managed prefixes): ProfileIntent gains an
    ##     OPTIONAL top-level ``"addOn"`` map with a ``"managedEtcPrefixes"``
    ##     array of text -- the profile's ``addOn:`` section. Bumped because
    ##     a build that did not know the key would plan the profile without
    ##     its managed prefixes and let every ``/etc`` path through the
    ##     add-on's scope check.
    ##  13 (ReproOS add-on mode, spec §13 decision 17): ``"hostSystems"``
    ##     ``"mode"`` gains the value ``full`` -- a fully managed host that
    ##     selects system activities through the block form. Bumped because
    ##     a schema-11 reader refuses the value as corrupt rather than
    ##     reading it, so a profile using it must be recompiled by a build
    ##     that knows it.
    ## When you change the on-the-wire CBOR shape of ANY field that
    ## affects how a downstream consumer would interpret the envelope,
    ## bump this constant AND document the change here.
  RbpiHeaderSize*    = 4 + 2 + 4        ## magic + version + bodyLen.
  RbpiTrailerSize*   = 32               ## BLAKE3-256 trailing checksum.

# ---------------------------------------------------------------------------
# Header helpers.
# ---------------------------------------------------------------------------

proc encodeRbpiHeader*(bodyLen: uint32): seq[byte] =
  ## Build the 10-byte fixed header: magic + schemaVersion + bodyLen.
  ## The trailing BLAKE3 checksum is written by `wrapEnvelope`.
  result = newSeqOfCap[byte](RbpiHeaderSize)
  for ch in RbpiMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(RbpiSchemaVersion)
  result.writeU32Le(bodyLen)

proc readRbpiHeader*(bytes: openArray[byte]):
    tuple[version: uint16, bodyLen: uint32] =
  ## Parse the 10-byte fixed header. Raises `ERbpiCorrupt` for a bad
  ## magic, an unsupported version, or a truncated input. Does NOT
  ## validate the trailing checksum — `readEnvelope` does that.
  if bytes.len < RbpiHeaderSize:
    raiseRbpiCorrupt("envelope",
      "input is " & $bytes.len & " bytes; need at least " &
      $RbpiHeaderSize & " for the header")
  for i in 0 ..< 4:
    if bytes[i] != byte(ord(RbpiMagic[i])):
      raiseRbpiCorrupt("magic",
        "expected ASCII '" & RbpiMagic & "' at offset 0")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != RbpiSchemaVersion:
    raiseRbpiCorrupt("schemaVersion",
      "unsupported RBPI schema version " & $version &
      " (this build understands " & $RbpiSchemaVersion & ")")
  let bodyLen = readU32Le(bytes, pos)
  (version: version, bodyLen: bodyLen)

# ---------------------------------------------------------------------------
# Envelope wrap / unwrap.
# ---------------------------------------------------------------------------

proc wrapEnvelope*(body: openArray[byte]): seq[byte] =
  ## Returns magic + version + bodyLen + body + BLAKE3-256(magic +
  ## version + bodyLen + body). Deterministic for a fixed body.
  result = newSeqOfCap[byte](RbpiHeaderSize + body.len + RbpiTrailerSize)
  for ch in RbpiMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(RbpiSchemaVersion)
  result.writeU32Le(uint32(body.len))
  for b in body:
    result.add(b)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

proc readEnvelope*(bytes: openArray[byte]): seq[byte] =
  ## Validate the magic, version, body-length bounds, and trailing
  ## BLAKE3 checksum BEFORE returning the body bytes. Raises
  ## `ERbpiCorrupt` on any structural failure, with the offending
  ## field tagged ("magic", "schemaVersion", "bodyLength", "checksum",
  ## or "envelope" for an outright-too-short input).
  if bytes.len < RbpiHeaderSize + RbpiTrailerSize:
    raiseRbpiCorrupt("envelope",
      "input is " & $bytes.len & " bytes; need at least " &
      $(RbpiHeaderSize + RbpiTrailerSize) & " for an empty-body envelope")
  # Header validation also catches bad magic / unsupported version.
  let (_, bodyLenU32) = readRbpiHeader(bytes)
  let bodyLen = int(bodyLenU32)
  let bodyEnd = RbpiHeaderSize + bodyLen
  if bodyEnd + RbpiTrailerSize != bytes.len:
    raiseRbpiCorrupt("bodyLength",
      "declared body length " & $bodyLen &
      " disagrees with input size " & $bytes.len &
      " (expected total " & $(bodyEnd + RbpiTrailerSize) & ")")
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if bytes[bodyEnd + i] != expected[i]:
      raiseRbpiCorrupt("checksum",
        "BLAKE3-256 trailing checksum mismatch")
  result = newSeqOfCap[byte](bodyLen)
  for i in 0 ..< bodyLen:
    result.add(bytes[RbpiHeaderSize + i])
