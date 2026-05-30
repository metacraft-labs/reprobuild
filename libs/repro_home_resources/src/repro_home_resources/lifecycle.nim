## M68 lifecycle decision algorithm.
##
## Per Home-Profile-Resource-Lifecycle.md "Lifecycle Decision
## Algorithm", per resource per apply:
##
##   1. Lookup recorded binding in the previous generation's
##      `resourceBindings` for the same resource address.
##   2. Observe the current real-world state via the resource
##      driver.
##   3. Decide:
##      - desired absent + observed absent              -> no_op
##      - desired present + observed absent             -> create
##      - desired present + observed matches desired    -> no_op (cache-hit)
##      - desired present + observed differs:
##          no recorded binding (first apply)           -> update (converge)
##          recorded postWrite == observed              -> update (safe)
##          recorded postWrite != observed              -> drift_blocked
##      - desired absent + observed present:
##          recorded postWrite == observed              -> destroy (safe)
##          recorded postWrite != observed              -> drift_blocked
##      - lifecyclePolicy = preventDestroy:             -> EPreventDestroy
##
## `--reconcile-drift` collapses `drift_blocked` -> `update`
## (overwrite the drift with the desired bytes). `--accept-overwrite`
## permits destroys that would otherwise be refused for drift.

import std/[strutils]

import repro_home_generations

import ./drivers/defaults
import ./drivers/launchd_user
import ./drivers/systemd_user
import ./drivers/vscode_extension
import ./errors
import ./manifest_record
import ./types

type
  ReconcilePolicy* = enum
    ## What to do when drift is detected.
    rpFailClosed = "fail-closed"
      ## Default: emit `drift_blocked`, the executor raises `EDrift`.
    rpReconcileDrift = "reconcile-drift"
      ## `--reconcile-drift`: overwrite the drift with the desired
      ## bytes; the action becomes `update`.
    rpAcceptOverwrite = "accept-overwrite"
      ## `--accept-overwrite`: tolerate drift even for destroys.

  DecisionOptions* = object
    reconcile*: ReconcilePolicy
    enforcePreventDestroy*: bool
      ## Phase B activates this. Phase A leaves it false so
      ## `lifecyclePolicy = preventDestroy` decisions still record
      ## an action (the gate verifies the policy enum round-trips
      ## through the manifest), but the executor does not refuse
      ## yet. Set to true once the Phase B `lifecyclePolicy`
      ## enforcement is on.

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

proc managedBlockBodyDigest(content: string): Digest256 =
  ## Digest of a managed-block body exactly as the shared
  ## managed-block writer (`drivers/managed_block.nim:spliceManagedBlock`)
  ## lays it on disk between the sentinels: a non-empty body is
  ## normalized to end with a single trailing `\n` (so the close
  ## sentinel sits on its own line), an empty body is left empty.
  ##
  ## Both the `fs.managedBlock` and `shell.integration` resources
  ## are written by that same writer (`shell.integration` reuses it
  ## via `drivers/shell_integration.nim:applyShellIntegration` ->
  ## `applyManagedBlockResource`), so both digest branches MUST use
  ## this one helper — keeping them from drifting apart again.
  var normalized = content
  if normalized.len > 0 and normalized[^1] != '\n':
    normalized.add('\n')
  var buf = newSeq[byte](normalized.len)
  for i, ch in normalized:
    buf[i] = byte(ord(ch))
  return digestOfBytes(buf)

proc digestOfResource*(desired: Resource): Digest256 =
  ## Canonical content digest for a desired resource. The bytes
  ## fed into the BLAKE3 hash are exactly the bytes the apply
  ## executor would record in `ResourceBinding.payloadBytes`,
  ## so cache-hit comparison is byte-for-byte with the previous
  ## generation's recorded `postWriteDigest`.
  case desired.kind
  of rkFsManagedBlock:
    # The driver normalizes the on-disk block body by ensuring a
    # trailing `\n` (so the close sentinel sits on its own line).
    # Mirror that normalization here so cache-hit comparison
    # (desired digest == observed digest) holds when the content
    # the user passed already ends with `\n` AND when it doesn't.
    return managedBlockBodyDigest(desired.managedBlockContent)
  of rkWindowsRegistryValue:
    return digestOfBytes(desired.registryPayload.bytes)
  of rkEnvUserVariable:
    return digestOfBytes(desired.envVarPayload.bytes)
  of rkEnvUserPath:
    # The recorded payload is the joined entries; preserves order.
    when defined(windows):
      let sep = ";"
    else:
      let sep = ":"
    let joined = desired.pathEntries.join(sep)
    var buf = newSeq[byte](joined.len)
    for i, ch in joined:
      buf[i] = byte(ord(ch))
    return digestOfBytes(buf)
  of rkWindowsStartup:
    var buf = newSeq[byte](desired.startupCommand.len)
    for i, ch in desired.startupCommand:
      buf[i] = byte(ord(ch))
    return digestOfBytes(buf)
  of rkShellIntegration:
    # `shell.integration` is written by the SAME managed-block writer
    # as `rkFsManagedBlock` (via `applyShellIntegration` ->
    # `applyManagedBlockResource`), which appends a trailing `\n` to a
    # non-empty body. The desired digest must therefore apply the
    # identical trailing-newline normalization, otherwise an unchanged
    # `shell.integration` resource re-plans as `update` instead of
    # `no-op`. Genuine content drift still produces a differing digest.
    return managedBlockBodyDigest(desired.shellBlockContent)
  of rkLinuxGsettings:
    var buf = newSeq[byte](desired.gsettingsValueLiteral.len)
    for i, ch in desired.gsettingsValueLiteral:
      buf[i] = byte(ord(ch))
    return digestOfBytes(buf)
  of rkSystemdUserUnit:
    # The on-disk file the driver writes is just `unitContent`, but
    # `unitEnabled` and `unitState` are RECONCILED by `systemctl`
    # without touching the file. A change to either field must
    # therefore re-trigger the apply path even when the file body
    # itself is unchanged. `canonicalUnitBytes` encodes the triple
    # consistently for both desired (here) and observed
    # (`observeUserUnit`); same content + enabled + state -> same
    # digest -> cache-hit no-op.
    return digestOfBytes(canonicalUnitBytes(desired.unitContent,
      desired.unitEnabled, desired.unitState))
  of rkMacosUserDefault:
    # Structural canonicalization (NOT a text compare): the
    # `macos.userDefault` driver records and observes the
    # structurally-canonicalized value, so the desired digest must
    # be over the same canonical form. A dict with reordered keys
    # or a value that differs only in quote style / whitespace
    # therefore digests identically and does NOT register as drift.
    let canonical = canonicalizeDefaultsValue(desired.defaultsValueLiteral)
    var buf = newSeq[byte](canonical.len)
    for i, ch in canonical:
      buf[i] = byte(ord(ch))
    return digestOfBytes(buf)
  of rkLaunchdUserAgent:
    # M83 step 4b: the canonical bytes are the rendered plist —
    # `launchAgentPlistFor` returns `launchdPlistContent` verbatim
    # when present (backwards-compat path) or freshly builds the
    # XML from the typed `label` / `programArgs` / `runAtLoad` /
    # `keepAlive` fields (the M83 step 4b common case). The
    # `observeLaunchAgent` driver reads the plist from disk and
    # digests its raw bytes; the two converge to the same hash
    # when nothing on disk has drifted.
    let canonical = launchAgentPlistFor(desired.launchdLabel,
      desired.launchdProgramArgs, desired.launchdRunAtLoad,
      desired.launchdKeepAlive, desired.launchdPlistContent)
    var buf = newSeq[byte](canonical.len)
    for i, ch in canonical:
      buf[i] = byte(ord(ch))
    return digestOfBytes(buf)
  of rkFsUserFile:
    # Whole-file: the digest is over the raw declared content bytes
    # (verbatim — no trailing-newline normalization, unlike
    # `fs.managedBlock` whose sentinel writer appends `\n`). On
    # re-observation `observeUserFile` digests the same raw bytes,
    # so a cache-hit re-apply compares equal byte-for-byte.
    var buf = newSeq[byte](desired.userFileContent.len)
    for i, ch in desired.userFileContent:
      buf[i] = byte(ord(ch))
    return digestOfBytes(buf)
  of rkVscodeExtension:
    # The canonical-desired form is the sorted line-oriented rendering
    # of the declared extension set (with `@version` pins preserved
    # verbatim). `observeVscodeExtensions` computes the same canonical
    # form against the installed set + `removeUnknown` policy, so a
    # cache-hit re-apply digests equal.
    let specs = parseDesiredExtensions(desired.vscodeExtensions)
    let canon = canonicalExtensionSet(specs)
    var buf = newSeq[byte](canon.len)
    for i, ch in canon:
      buf[i] = byte(ord(ch))
    return digestOfBytes(buf)

proc summarize*(action: ResourceActionKind; address: string;
                kind: ResourceKind): string =
  case action
  of rakNoOp: "no-op    " & address & " (" & $kind & ")"
  of rakCreate: "create   " & address & " (" & $kind & ")"
  of rakUpdate: "update   " & address & " (" & $kind & ")"
  of rakReplace: "replace  " & address & " (" & $kind & ")"
  of rakDestroy: "destroy  " & address & " (" & $kind & ")"
  of rakAdopt: "adopt    " & address & " (" & $kind & ")"
  of rakDriftBlocked: "DRIFT    " & address & " (" & $kind & ")"

# ---------------------------------------------------------------------------
# Decision.
# ---------------------------------------------------------------------------

proc decideAction*(state: ResourceState;
                  options: DecisionOptions = DecisionOptions(
                    reconcile: rpFailClosed,
                    enforcePreventDestroy: false)): ResourceAction =
  ## Pure decision: given the composite state (desired + observed +
  ## recorded), return the typed action. Does NOT mutate anything;
  ## the executor consumes the action and performs the I/O.
  result.address = state.address
  result.driftExpectedHex = ""
  result.driftObservedHex = ""

  # Branch 1: nothing desired, nothing observed.
  if not state.hasDesired and not state.observed.present:
    result.kind = rakNoOp
    if state.hasRecorded:
      result.resourceKind = state.recorded.kind
    else:
      result.resourceKind = rkFsManagedBlock  # unused
    result.summary = summarize(rakNoOp, state.address, result.resourceKind)
    return

  # Branch 2: desired present.
  if state.hasDesired:
    result.resourceKind = state.desired.kind
    let desiredDigest = digestOfResource(state.desired)
    if not state.observed.present:
      # Create.
      result.kind = rakCreate
      result.summary = summarize(rakCreate, state.address, result.resourceKind)
      return
    if state.observed.digest == desiredDigest:
      # Cache-hit: live state already matches what we want.
      result.kind = rakNoOp
      result.summary = summarize(rakNoOp, state.address, result.resourceKind)
      return
    # Observed != desired. Decide between update (safe, we wrote
    # it last) and drift_blocked (user mutated since our write).
    if state.hasRecorded and not isZeroDigest(state.recorded.postWriteDigest) and
       state.recorded.postWriteDigest == state.observed.digest:
      # Safe update.
      result.kind = rakUpdate
      result.summary = summarize(rakUpdate, state.address, result.resourceKind)
      return
    # First-apply (no recorded binding) is NOT drift. "Drift" is
    # defined as the operator mutating state we PREVIOUSLY wrote.
    # If we have no record of ever writing this resource, the
    # observed-vs-desired diff is just the initial-convergence
    # delta — drive an `rakUpdate` (the apply executor converges
    # observed -> desired through the same code path as a regular
    # update). Hit by drivers whose `observe` returns `present=true`
    # with the empty-set hash on a system that has nothing matching
    # the desired set yet — e.g. `vscode.extension` on a fresh
    # install where no extensions are installed and the canonical
    # observed = the empty intersection of (installed ∩ desired).
    if not state.hasRecorded:
      result.kind = rakUpdate
      result.summary = summarize(rakUpdate, state.address, result.resourceKind)
      return
    # Drift.
    let expectedHex =
      if state.hasRecorded: digestHex(state.recorded.postWriteDigest)
      else: ""
    let observedHex = digestHex(state.observed.digest)
    if options.reconcile == rpReconcileDrift or
       options.reconcile == rpAcceptOverwrite:
      result.kind = rakUpdate
      result.driftExpectedHex = expectedHex
      result.driftObservedHex = observedHex
      result.summary = summarize(rakUpdate, state.address, result.resourceKind) &
        " [drift reconciled]"
      return
    result.kind = rakDriftBlocked
    result.driftExpectedHex = expectedHex
    result.driftObservedHex = observedHex
    result.summary = summarize(rakDriftBlocked, state.address,
      result.resourceKind)
    return

  # Branch 3: desired absent, observed present.
  if state.hasRecorded:
    result.resourceKind = state.recorded.kind
  else:
    # No prior record + nothing desired but something exists in
    # the world. Phase A: leave it alone (no_op). The user can
    # explicitly `repro home adopt` to claim it.
    result.kind = rakNoOp
    result.resourceKind = rkFsManagedBlock
    result.summary = summarize(rakNoOp, state.address, result.resourceKind) &
      " [unmanaged, leaving as-is]"
    return
  # We have a recorded binding; the desired set no longer
  # references this address; the world still has the bytes.
  # Safe destroy iff observed matches recorded postWrite.
  if state.recorded.postWriteDigest == state.observed.digest or
     options.reconcile == rpAcceptOverwrite:
    if options.enforcePreventDestroy and
       state.recorded.lifecyclePolicy == lpPreventDestroy:
      raisePreventDestroy(state.address)
    result.kind = rakDestroy
    result.summary = summarize(rakDestroy, state.address, result.resourceKind)
    return
  # Drift on destroy.
  result.kind = rakDriftBlocked
  result.driftExpectedHex = digestHex(state.recorded.postWriteDigest)
  result.driftObservedHex = digestHex(state.observed.digest)
  result.summary = summarize(rakDriftBlocked, state.address,
    result.resourceKind) & " [drift on destroy]"

# ---------------------------------------------------------------------------
# Drift assertion.
# ---------------------------------------------------------------------------

proc raiseIfDriftBlocked*(action: ResourceAction) =
  ## Convenience: the apply executor calls this once per action to
  ## fail-closed on drift without `--reconcile-drift`.
  if action.kind == rakDriftBlocked:
    raiseDrift(action.address, $action.resourceKind,
      action.driftExpectedHex, action.driftObservedHex)
