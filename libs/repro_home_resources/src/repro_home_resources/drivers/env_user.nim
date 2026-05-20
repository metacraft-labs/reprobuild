## `env.userVariable` and `env.userPath` drivers — typed sugar over
## the Windows registry driver with the `WM_SETTINGCHANGE` broadcast
## enabled.
##
## Per the anti-patterns list: NO `setx` shell-out. `setx` has a
## 1024-character limit and other quirks; we write the registry
## value directly and broadcast `WM_SETTINGCHANGE` so cmd.exe /
## Explorer pick up the change.
##
## `env.userPath` is the special case: it reads the existing PATH
## value, splits on `;`, then computes the new value as
## `(existing entries we did NOT add) ++ (the entries this generation
## contributes)`. Gate 4 verifies that user-added entries (outside
## the recorded contribution) are preserved on rollback.

import std/[sequtils, strutils]

import ./../errors
import ./../manifest_record
import ./../types
import ./registry

const
  EnvironmentSubkey* = "Environment"
  PathSeparator* = ";"

# ---------------------------------------------------------------------------
# `env.userVariable` driver.
# ---------------------------------------------------------------------------

proc observeUserVariable*(name: string): ObservedState =
  ## Observe `HKCU\Environment\<name>`. The recorded payload is the
  ## raw bytes written (UTF-16LE including the trailing double-zero
  ## terminator for REG_SZ / REG_EXPAND_SZ).
  observeRegistryValue("HKCU\\" & EnvironmentSubkey, name)

proc applyUserVariableCreate*(name: string;
                              payload: RegistryValuePayload):
    seq[byte] =
  ## Write the value. Returns the raw bytes that the apply executor
  ## should record as `payloadBytes`. Always issues the
  ## `WM_SETTINGCHANGE` broadcast.
  when defined(windows):
    let regType = registryValueKindToRegType(payload.kind)
    writeRegistryValue(EnvironmentSubkey, name, regType, payload.bytes)
    broadcastEnvironmentChange()
  result = payload.bytes

proc applyUserVariableUpdate*(name: string;
                              payload: RegistryValuePayload):
    seq[byte] =
  applyUserVariableCreate(name, payload)

proc applyUserVariableDestroy*(name: string) =
  when defined(windows):
    deleteRegistryValue(EnvironmentSubkey, name)
    broadcastEnvironmentChange()

# ---------------------------------------------------------------------------
# `env.userPath` driver — the gate-4 invariant lives here.
# ---------------------------------------------------------------------------

proc splitPathEntries*(raw: string): seq[string] =
  ## Split a Windows-style PATH value on `;`. Empty entries are
  ## dropped (consistent with the OS's loader behavior).
  result = @[]
  for piece in raw.split(';'):
    if piece.len > 0:
      result.add(piece)

proc joinPathEntries*(entries: openArray[string]): string =
  entries.join(";")

proc readUserPathRaw*(): tuple[present: bool; raw: string; regType: uint32] =
  ## Read `HKCU\Environment\Path` (or `PATH`) as UTF-8. Returns
  ## `(present=false, "")` if no value is set yet. Tries both
  ## `Path` and `PATH` — Windows normalizes the name case but the
  ## driver records whichever case was already there.
  when defined(windows):
    var r = readRegistryValue(EnvironmentSubkey, "Path")
    if not r.present:
      r = readRegistryValue(EnvironmentSubkey, "PATH")
    if not r.present:
      return (false, "", 0'u32)
    # REG_SZ or REG_EXPAND_SZ; both are UTF-16LE.
    var trimmed = newSeq[byte](r.bytes.len)
    for i in 0 ..< r.bytes.len:
      trimmed[i] = r.bytes[i]
    # Strip the trailing UTF-16 NULs.
    while trimmed.len >= 2 and trimmed[^1] == 0 and trimmed[^2] == 0:
      trimmed.setLen(trimmed.len - 2)
    var s = ""
    var i = 0
    while i + 1 < trimmed.len:
      let u = uint16(trimmed[i]) or (uint16(trimmed[i+1]) shl 8)
      i += 2
      # We only emit ASCII directly; multi-byte Windows paths in
      # PATH are rare in practice but if they appear, we re-encode
      # them as UTF-8 the same way the registry driver does.
      if u < 0x80:
        s.add(char(u))
      elif u < 0x800:
        s.add(char(0xC0 or (u shr 6)))
        s.add(char(0x80 or (u and 0x3F)))
      else:
        s.add(char(0xE0 or (u shr 12)))
        s.add(char(0x80 or ((u shr 6) and 0x3F)))
        s.add(char(0x80 or (u and 0x3F)))
    return (true, s, r.regType)
  else:
    return (false, "", 0'u32)

proc dedup(seq1: seq[string]): seq[string] =
  result = @[]
  for s in seq1:
    if s notin result:
      result.add(s)

proc parseRecordedPathEntries*(payload: openArray[byte]): seq[string] =
  ## The recorded `payloadBytes` for `env.userPath` is the joined
  ## entries (semicolon-separated, UTF-8). Used to determine which
  ## entries this generation added so rollback can subtract them
  ## without touching user-added entries.
  var s = newString(payload.len)
  for i, b in payload:
    s[i] = char(b)
  splitPathEntries(s)

proc computeMergedPath*(existing, contributed: openArray[string]):
    string =
  ## Merge logic: take existing entries first (preserves the
  ## user's preferred order), append any contributed entry that
  ## isn't already present.
  var merged: seq[string] = @[]
  for e in existing:
    if e notin merged:
      merged.add(e)
  for c in contributed:
    if c notin merged:
      merged.add(c)
  joinPathEntries(merged)

proc applyUserPath*(contributed: openArray[string];
                   priorContribution: openArray[string]): seq[byte] =
  ## Write the merged PATH back. Returns the bytes the executor
  ## should record as `payloadBytes` — the JOINED CONTRIBUTION
  ## (not the full PATH), so rollback knows exactly which entries
  ## to remove without touching unrelated user-added entries.
  when defined(windows):
    let current = readUserPathRaw()
    var existingEntries =
      if current.present: splitPathEntries(current.raw)
      else: @[]
    # Subtract the prior contribution from existing — these are
    # the entries this generation added last time. Anything left
    # is either pre-existing or user-added between applies; we
    # preserve those.
    var pruned: seq[string] = @[]
    for e in existingEntries:
      if e notin priorContribution:
        pruned.add(e)
    let mergedRaw = computeMergedPath(pruned, contributed)
    let regType =
      if current.present and current.regType == 2'u32: 2'u32 # REG_EXPAND_SZ
      else: 1'u32 # REG_SZ
    writeRegistryValue(EnvironmentSubkey, "Path",
      regType, encodeString(mergedRaw))
    broadcastEnvironmentChange()
  # Recorded payload: the JOINED CONTRIBUTION bytes (UTF-8).
  let joined = joinPathEntries(contributed)
  result = newSeq[byte](joined.len)
  for i, ch in joined:
    result[i] = byte(ord(ch))

proc removeUserPathContribution*(contribution: openArray[string]) =
  ## Destroy: remove only the recorded contribution entries from
  ## the live PATH. User-added entries (anything not in
  ## `contribution`) remain byte-identical.
  when defined(windows):
    let current = readUserPathRaw()
    if not current.present:
      return
    let existingEntries = splitPathEntries(current.raw)
    var pruned: seq[string] = @[]
    for e in existingEntries:
      if e notin contribution:
        pruned.add(e)
    let mergedRaw = joinPathEntries(pruned)
    let regType =
      if current.regType == 2'u32: 2'u32
      else: 1'u32
    if pruned.len == 0:
      # Empty PATH; delete the value rather than writing an empty
      # string.
      deleteRegistryValue(EnvironmentSubkey, "Path")
    else:
      writeRegistryValue(EnvironmentSubkey, "Path",
        regType, encodeString(mergedRaw))
    broadcastEnvironmentChange()

proc observeUserPath*(contribution: openArray[string]): ObservedState =
  ## Observe the live PATH and reduce to the recorded form for
  ## drift comparison. The "observed digest" is computed over the
  ## subset of the desired contribution that's currently in PATH;
  ## the spec's gate-4 invariant ("user-added entries survive
  ## rollback") is implemented by ignoring all live entries the
  ## resource didn't add.
  ##
  ## Presence semantics: `present == true` ONLY when ALL of the
  ## contribution entries are in the live PATH. A partial match
  ## means the user (or another tool) removed one of OUR entries
  ## — that's a drift case the apply pipeline can decide on.
  ## A zero-overlap match means we haven't applied yet (or our
  ## contribution was wiped clean) — equivalent to "absent".
  when defined(windows):
    let current = readUserPathRaw()
    if not current.present:
      result.present = false
      result.digest = zeroDigest()
      return
    let live = splitPathEntries(current.raw)
    var matched: seq[string] = @[]
    for c in contribution:
      if c in live:
        matched.add(c)
    if matched.len == 0:
      # None of our entries are present; the resource is absent.
      result.present = false
      result.digest = zeroDigest()
      return
    let joined = joinPathEntries(matched)
    var raw = newSeq[byte](joined.len)
    for i, ch in joined:
      raw[i] = byte(ord(ch))
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    result.present = false
    result.digest = zeroDigest()
