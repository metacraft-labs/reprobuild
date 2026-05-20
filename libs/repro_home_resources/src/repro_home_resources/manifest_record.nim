## M68 extension of the M62 ResourceBinding record.
##
## Wraps the manifest writer's `ResourceBinding` type with helpers
## that convert between the in-memory `RecordedBinding` and the
## on-disk record. The on-disk fields are owned by
## `repro_home_generations/manifest.nim`; this module bridges them
## to the typed `Resource` + `ObservedState` world.

import blake3
import repro_home_generations

import ./errors
import ./types

# ---------------------------------------------------------------------------
# Digest helpers.
# ---------------------------------------------------------------------------

proc digestOfBytes*(bytes: openArray[byte]): Digest256 =
  let raw = blake3.digest(bytes)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc isZeroDigest*(d: Digest256): bool =
  for i in 0 ..< 32:
    if d[i] != 0: return false
  true

proc zeroDigest*(): Digest256 =
  for i in 0 ..< 32:
    result[i] = 0'u8

proc digestHexShort*(d: Digest256): string =
  ## 12-hex-char prefix used in diagnostics.
  let full = digestHex(d)
  if full.len >= 12: full[0 ..< 12] else: full

# ---------------------------------------------------------------------------
# Conversion: ResourceBinding (on-disk) -> RecordedBinding (in-memory)
# ---------------------------------------------------------------------------

proc toRecorded*(rb: ResourceBinding): RecordedBinding =
  ## V2 records carry the full M68 surface. V1 records (M62
  ## fixtures) only set the address / identity / provider /
  ## attributes / policy fields; the typed-resource fields stay
  ## at their zero values, which the lifecycle algorithm treats
  ## as "no recorded post-write state available — assume
  ## create" for V1 records that happen to be present.
  result.address = rb.resourceAddress
  result.resourceId = rb.realWorldIdentity
  result.preWriteDigest = rb.preWriteDigest
  result.hasPreWriteDigest = rb.hasPreWriteDigest
  result.postWriteDigest = rb.postWriteDigest
  result.payloadKind = rb.payloadKind
  result.payloadBytes = rb.payloadBytes
  if rb.lifecyclePolicy.len > 0:
    try:
      result.lifecyclePolicy = lifecyclePolicyFromString(rb.lifecyclePolicy)
    except ValueError:
      result.lifecyclePolicy = lpDefault
  else:
    result.lifecyclePolicy = lpDefault
  if rb.resourceKind.len > 0:
    try:
      result.kind = resourceKindFromString(rb.resourceKind)
    except ValueError:
      # M62 records without a kind tag — treat as managed block
      # (the only V1 candidate). Not used in M68's flow but
      # documented for forward-compat.
      result.kind = rkFsManagedBlock

# ---------------------------------------------------------------------------
# Conversion: applied state -> ResourceBinding (on-disk)
# ---------------------------------------------------------------------------

proc toResourceBinding*(address: string;
                        kind: ResourceKind;
                        identity: string;
                        preWrite: ObservedState;
                        postWriteBytes: openArray[byte];
                        payloadKind: string;
                        lifecyclePolicy: LifecyclePolicy): ResourceBinding =
  ## Build the on-disk record from the apply executor's outputs.
  ## The `preWrite.digest` is preserved verbatim (zero digest when
  ## the resource was absent — that's the `create` case).
  result.resourceAddress = address
  result.providerIdentity = "repro.builtin"
  result.realWorldIdentity = identity
  result.lifecyclePolicy = $lifecyclePolicy
  result.resourceKind = $kind
  if preWrite.present:
    result.preWriteDigest = preWrite.digest
    result.hasPreWriteDigest = true
  else:
    result.preWriteDigest = zeroDigest()
    result.hasPreWriteDigest = false
  result.postWriteDigest = digestOfBytes(postWriteBytes)
  result.payloadKind = payloadKind
  result.payloadBytes = newSeq[byte](postWriteBytes.len)
  for i, b in postWriteBytes:
    result.payloadBytes[i] = b
  if result.payloadBytes.len > ManifestResourcePayloadMaxBytes:
    raiseResourceDriver(address, $kind, "manifest_record",
      "payload size " & $result.payloadBytes.len & " exceeds " &
      $ManifestResourcePayloadMaxBytes & "-byte cap; place large " &
      "state in CAS rather than the resource binding")

proc toDestroyBinding*(address: string;
                      kind: ResourceKind;
                      identity: string;
                      preWrite: ObservedState;
                      payloadKind: string;
                      lifecyclePolicy: LifecyclePolicy): ResourceBinding =
  ## Build a destroy-record: the resource WAS there before and is
  ## gone now. `preWriteDigest` captures the bytes we destroyed so
  ## rollback can restore them; `postWriteDigest` is the zero
  ## digest meaning "resource is intentionally absent at this
  ## generation".
  result.resourceAddress = address
  result.providerIdentity = "repro.builtin"
  result.realWorldIdentity = identity
  result.lifecyclePolicy = $lifecyclePolicy
  result.resourceKind = $kind
  if preWrite.present:
    result.preWriteDigest = preWrite.digest
    result.hasPreWriteDigest = true
    result.payloadBytes = preWrite.rawBytes
  else:
    result.preWriteDigest = zeroDigest()
    result.hasPreWriteDigest = false
    result.payloadBytes = @[]
  result.postWriteDigest = zeroDigest()
  result.payloadKind = payloadKind
  if result.payloadBytes.len > ManifestResourcePayloadMaxBytes:
    raiseResourceDriver(address, $kind, "manifest_record",
      "destroy payload size " & $result.payloadBytes.len &
      " exceeds " & $ManifestResourcePayloadMaxBytes & "-byte cap")
