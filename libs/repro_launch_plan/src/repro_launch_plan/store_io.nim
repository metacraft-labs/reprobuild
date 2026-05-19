## Thin facade over the M56 CAS for storing and retrieving `LaunchPlan`
## envelopes. Launch plans are CAS blobs keyed by their
## `launchPlanIdBytes` — the BLAKE3-256 of the RBLP envelope bytes.
##
## This module is intentionally tiny: all of the M56 store API
## (`storeCasBlob`, `readCasBlob`, hash-on-read verification, idempotent
## staging→rename) is reused as-is. The launch plan layer only adds the
## typed encode/decode hop.

import repro_local_store

import ./codec
import ./types

proc storeLaunchPlan*(s: var Store; plan: LaunchPlan): PrefixIdBytes =
  ## Encode the plan and persist its RBLP envelope as a CAS blob.
  ## Returns the BLAKE3-256 key — the canonical `launchPlanId`.
  let envelope = encodeLaunchPlan(plan)
  s.storeCasBlob(envelope)

proc loadLaunchPlan*(s: Store; id: PrefixIdBytes): LaunchPlan =
  ## Read the envelope (with hash-on-read verification courtesy of
  ## `readCasBlob`) and decode the typed plan. Any tampering between
  ## write and read is detected here as either an `ECasDigestMismatch`
  ## or a `LaunchPlanCodecError`.
  let bytes = s.readCasBlob(id)
  decodeLaunchPlan(bytes)

proc planExistsInStore*(s: Store; id: PrefixIdBytes): bool =
  ## Predicate version useful for the CLI inspector.
  try:
    discard s.readCasBlob(id)
    true
  except ECasMissing:
    false
