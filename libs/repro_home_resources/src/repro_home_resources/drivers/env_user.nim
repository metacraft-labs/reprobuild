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
##
## **POSIX `env.userVariable` arm (Recipe-Validation side-finding):**
## the non-Windows `applyUserVariableCreate` writes
## `export <name>='<value>'` into a per-variable managed block in
## the same shell rc file `env.userPath` already owns (the
## `defaultUserPathHostFile`-resolved path, overridable via
## `REPRO_HOME_POSIX_PATH_RC`). Each variable gets a dedicated
## block id (`repro-home-env-<name>`) so multiple variables don't
## clobber each other. The value bytes follow the same UTF-16LE
## REG_SZ / REG_EXPAND_SZ encoding the Windows arm consumes — we
## decode to UTF-8 before quoting and writing the shell line. The
## destroy direction simply removes the per-variable managed block.

import std/[os, strutils]

import ./../errors
import ./../manifest_record
import ./../types
import ./managed_block
import ./registry

const
  EnvironmentSubkey* = "Environment"
  UserPathBlockId* = "repro-home-userpath"
    ## Legacy default sentinel id. Hand-written profiles that emit a
    ## single `env.userPath` resource continue to write into this
    ## block. The M69 emitter (`envUserPathResource`) sets a per-
    ## resource block id so per-package PATH contributions don't
    ## clobber each other in the shared rc file.
  UserPathRcEnvVar* = "REPRO_HOME_POSIX_PATH_RC"

when defined(windows):
  const PathSeparator* = ";"
else:
  const PathSeparator* = ":"

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ord(ch))

proc bytesToString(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b:
    result[i] = char(x)

# ---------------------------------------------------------------------------
# Shared helpers used by both `env.userVariable` (POSIX arm) and
# `env.userPath` (POSIX arm). Defined here so they're visible to the
# `env.userVariable` block that follows; the `env.userPath` block
# below re-uses them without re-declaration.
# ---------------------------------------------------------------------------

proc shellSingleQuote(s: string): string =
  "'" & s.replace("'", "'\"'\"'") & "'"

proc defaultUserPathHostFile*(homeDir = ""): string =
  ## POSIX fallback for `env.userPath` AND `env.userVariable`: write a
  ## managed block into the current user's shell rc. Tests may pin the
  ## exact host file with `REPRO_HOME_POSIX_PATH_RC`.
  ##
  ## Distro coverage:
  ##   * Alpine / Arch / Debian / Fedora / Ubuntu — all five non-NixOS
  ##     Linux distros in the Recipe-Validation harness — resolve to
  ##     `~/.bashrc`, `~/.zshrc`, or `~/.profile` depending on the
  ##     current SHELL. The systemd `environment.d` machinery is NOT
  ##     used: the M82 sandbox-harness gate compares against the rc
  ##     fragment, and POSIX shells source rc files on every interactive
  ##     login — so the variable IS visible in the next shell after
  ##     `repro home apply`, on every distro the campaign covers.
  when defined(windows):
    ""
  else:
    let explicit = getEnv(UserPathRcEnvVar)
    if explicit.len > 0:
      return explicit
    let home =
      if homeDir.len > 0: homeDir
      else: getHomeDir()
    let shellName = extractFilename(getEnv("SHELL")).toLowerAscii()
    case shellName
    of "zsh":
      home / ".zshrc"
    of "bash":
      home / ".bashrc"
    of "fish":
      home / ".config" / "fish" / "config.fish"
    else:
      home / ".profile"

# ---------------------------------------------------------------------------
# `env.userVariable` driver.
# ---------------------------------------------------------------------------

proc userVariableBlockId*(name: string): string =
  ## Per-variable managed-block id under the shell rc file. Each
  ## variable gets its own block so multiple `env.userVariable`
  ## resources don't clobber each other when they share a host file.
  "repro-home-env-" & name

proc decodeRegistryStringValue(payload: RegistryValuePayload): string =
  ## Decode a REG_SZ / REG_EXPAND_SZ payload to a UTF-8 string. The
  ## trailing UTF-16LE NUL terminator is stripped. The POSIX arm
  ## writes the result into a shell `export` statement.
  case payload.kind
  of rvkString, rvkExpandString:
    fromUtf16Bytes(payload.bytes, trimTrailingNul = true)
  of rvkBinary:
    # Treat as raw UTF-8 bytes — POSIX env vars don't have a typed
    # encoding; the bytes are what `printenv` would echo verbatim.
    var s = newString(payload.bytes.len)
    for i, b in payload.bytes:
      s[i] = char(b)
    s
  of rvkDword:
    if payload.bytes.len >= 4:
      var v = uint32(payload.bytes[0]) or
              (uint32(payload.bytes[1]) shl 8) or
              (uint32(payload.bytes[2]) shl 16) or
              (uint32(payload.bytes[3]) shl 24)
      $v
    else: ""
  of rvkQword:
    if payload.bytes.len >= 8:
      var v: uint64 = 0
      for i in 0 ..< 8:
        v = v or (uint64(payload.bytes[i]) shl (i*8))
      $v
    else: ""
  of rvkMultiString:
    # MULTI_SZ -> newline-joined fallback (rare for env vars).
    decodeMultiString(payload.bytes).join("\n")

proc renderUserVariableBlockContent*(name: string;
                                     payload: RegistryValuePayload): string =
  ## Shell fragment used by the POSIX `env.userVariable` arm. Single-
  ## quote-escapes the decoded value so embedded `'`, `"`, `$`, and
  ## backticks are passed verbatim to the shell.
  let value = decodeRegistryStringValue(payload)
  "export " & name & "=" & shellSingleQuote(value) & "\n"

proc observeUserVariable*(name: string;
                         hostFilePath = ""): ObservedState =
  ## Observe `HKCU\Environment\<name>` on Windows; on POSIX, observe
  ## the per-variable managed block in the shared rc file. The
  ## recorded payload is the raw bytes written — UTF-16LE on
  ## Windows (REG_SZ / REG_EXPAND_SZ), the rendered shell-fragment
  ## bytes on POSIX. Drift comparison is byte-equality on the
  ## post-write digest.
  when defined(windows):
    observeRegistryValue("HKCU\\" & EnvironmentSubkey, name)
  else:
    let hostFile =
      if hostFilePath.len > 0: hostFilePath
      else: defaultUserPathHostFile()
    if hostFile.len == 0:
      result.present = false
      result.digest = zeroDigest()
      return
    observeManagedBlock(hostFile, userVariableBlockId(name))

proc applyUserVariableCreate*(name: string;
                              payload: RegistryValuePayload;
                              hostFilePath = ""):
    seq[byte] =
  ## Write the value. Returns the raw bytes that the apply executor
  ## should record as `payloadBytes`.
  ##
  ## On Windows: writes `HKCU\Environment\<name>` and broadcasts
  ## `WM_SETTINGCHANGE`; recorded bytes are the UTF-16LE registry
  ## payload (identical to what `observeUserVariable` reads back).
  ##
  ## On POSIX: writes `export <name>='<value>'` into a per-variable
  ## managed block in the shared rc file `env.userPath` already
  ## owns; recorded bytes are the rendered shell fragment between
  ## the sentinels.
  when defined(windows):
    let regType = registryValueKindToRegType(payload.kind)
    writeRegistryValue(EnvironmentSubkey, name, regType, payload.bytes)
    broadcastEnvironmentChange()
    result = payload.bytes
  else:
    let hostFile =
      if hostFilePath.len > 0: hostFilePath
      else: defaultUserPathHostFile()
    if hostFile.len == 0:
      # No rc file available (e.g. test env without HOME / SHELL); the
      # caller treats an empty payload as "wrote nothing", which keeps
      # the recorded post-write digest stable as the zero digest.
      result = @[]
      return
    let content = renderUserVariableBlockContent(name, payload)
    result = applyManagedBlockResource(hostFile,
      userVariableBlockId(name), content)

proc applyUserVariableUpdate*(name: string;
                              payload: RegistryValuePayload;
                              hostFilePath = ""):
    seq[byte] =
  applyUserVariableCreate(name, payload, hostFilePath)

proc applyUserVariableDestroy*(name: string;
                              hostFilePath = "") =
  when defined(windows):
    deleteRegistryValue(EnvironmentSubkey, name)
    broadcastEnvironmentChange()
  else:
    let hostFile =
      if hostFilePath.len > 0: hostFilePath
      else: defaultUserPathHostFile()
    if hostFile.len > 0:
      destroyManagedBlockResource(hostFile,
        userVariableBlockId(name))

# ---------------------------------------------------------------------------
# `env.userPath` driver — the gate-4 invariant lives here.
# ---------------------------------------------------------------------------

proc splitPathEntries*(raw: string): seq[string] =
  ## Split a user PATH contribution using the host platform's path-list
  ## separator. Empty entries are dropped, consistent with loader behavior.
  result = @[]
  for piece in raw.split(PathSeparator):
    if piece.len > 0:
      result.add(piece)

proc joinPathEntries*(entries: openArray[string]): string =
  entries.join(PathSeparator)

# `shellSingleQuote` + `defaultUserPathHostFile` are defined ABOVE the
# `env.userVariable` block so both arms share the helpers without
# duplication.

proc posixPathBlockContent*(entries: openArray[string]): string =
  ## Shell fragment used by POSIX `env.userPath`. It prepends the
  ## contributed directories while preserving the user's existing PATH.
  if entries.len == 0:
    return ""
  var quoted: seq[string] = @[]
  for entry in entries:
    if entry.len > 0:
      quoted.add(shellSingleQuote(entry))
  if quoted.len == 0:
    return ""
  "export PATH=" & quoted.join(":") & "${PATH:+:$PATH}\n"

proc parsePosixPathBlockEntries*(blockText: string): seq[string] =
  ## Inverse of `posixPathBlockContent`: walk the rendered block
  ## fragment and recover the contributed entries verbatim, undoing
  ## the single-quote escaping. Returns an empty seq when the block
  ## doesn't match the expected `export PATH='...':'...'${PATH:+:$PATH}`
  ## shape (e.g. user-edited content) — the caller treats that as a
  ## "can't reduce to entries" signal and falls back to digesting the
  ## raw bytes.
  result = @[]
  const Prefix = "export PATH="
  const Suffix = "${PATH:+:$PATH}"
  var body = blockText
  # Strip a trailing newline if present (the renderer always appends
  # one but the live block may have been re-saved without it).
  while body.len > 0 and body[^1] == '\n':
    body.setLen(body.len - 1)
  if not body.startsWith(Prefix):
    return @[]
  body = body[Prefix.len .. ^1]
  if not body.endsWith(Suffix):
    return @[]
  body = body[0 ..< body.len - Suffix.len]
  if body.len == 0:
    return @[]
  # Walk: each entry is a single-quoted run; `'\"'\"'` represents an
  # embedded `'`. Entries are separated by `:`.
  var i = 0
  while i < body.len:
    if body[i] != '\'':
      # Malformed — entries are always single-quoted.
      return @[]
    inc i
    var entry = ""
    while i < body.len:
      if body[i] == '\'':
        # Either end of the entry or the start of an embedded-quote
        # escape sequence `'\"'\"'` ( closing-quote, double-quoted
        # single-quote, opening-quote ).
        if i + 4 < body.len and
           body[i + 1] == '\"' and
           body[i + 2] == '\'' and
           body[i + 3] == '\"' and
           body[i + 4] == '\'':
          entry.add('\'')
          i += 5
          continue
        # End of the entry.
        inc i
        break
      entry.add(body[i])
      inc i
    result.add(entry)
    if i < body.len:
      if body[i] != ':':
        return @[]
      inc i

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
                   priorContribution: openArray[string];
                   hostFilePath = "";
                   blockId = ""): seq[byte] =
  ## Write the merged PATH back. Returns the bytes the executor
  ## should record as `payloadBytes` — the JOINED CONTRIBUTION
  ## (not the full PATH), so rollback knows exactly which entries
  ## to remove without touching unrelated user-added entries.
  ##
  ## `blockId` (POSIX only) selects the sentinel-delimited slice of
  ## the rc file. Empty means "use the legacy default block id"
  ## (`UserPathBlockId`); the M69 emitter passes a per-resource id
  ## so per-package PATH contributions don't clobber each other.
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
  else:
    let hostFile =
      if hostFilePath.len > 0: hostFilePath
      else: defaultUserPathHostFile()
    let effBlockId =
      if blockId.len > 0: blockId
      else: UserPathBlockId
    if hostFile.len > 0:
      discard applyManagedBlockResource(hostFile, effBlockId,
        posixPathBlockContent(contributed))
  # Recorded payload: the JOINED CONTRIBUTION bytes (UTF-8).
  let joined = joinPathEntries(contributed)
  result = bytesOf(joined)

proc removeUserPathContribution*(contribution: openArray[string];
                                 hostFilePath = "";
                                 blockId = "") =
  ## Destroy: remove only the recorded contribution entries from
  ## the live PATH. User-added entries (anything not in
  ## `contribution`) remain byte-identical.
  ##
  ## `blockId` (POSIX only) selects the sentinel-delimited slice
  ## of the rc file. Empty means "use the legacy default block id"
  ## so a destroy initiated against a recorded resource whose
  ## identity carries the default still finds the block.
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
  else:
    let hostFile =
      if hostFilePath.len > 0: hostFilePath
      else: defaultUserPathHostFile()
    let effBlockId =
      if blockId.len > 0: blockId
      else: UserPathBlockId
    if hostFile.len > 0:
      destroyManagedBlockResource(hostFile, effBlockId)

proc observeUserPath*(contribution: openArray[string];
                      hostFilePath = "";
                      blockId = ""): ObservedState =
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
    let hostFile =
      if hostFilePath.len > 0: hostFilePath
      else: defaultUserPathHostFile()
    let effBlockId =
      if blockId.len > 0: blockId
      else: UserPathBlockId
    if hostFile.len == 0:
      result.present = false
      result.digest = zeroDigest()
      return
    let observed = observeManagedBlock(hostFile, effBlockId)
    if not observed.present:
      result.present = false
      result.digest = zeroDigest()
      return
    let expected = posixPathBlockContent(contribution)
    let expectedBytes = bytesOf(expected)
    result.present = true
    if observed.rawBytes == expectedBytes:
      # The block IS exactly what we'd render for the desired
      # contribution — digest the joined entries directly so the
      # cache-hit short-circuit matches the recorded post-write
      # digest byte-for-byte.
      let joined = bytesOf(joinPathEntries(contribution))
      result.rawBytes = joined
      result.digest = digestOfBytes(joined)
    else:
      # Live block doesn't match what we'd render NOW. Reduce to the
      # same digest space (joined-entries bytes) by parsing the
      # live block back to its entries. That way the digest we
      # return is comparable to `recorded.postWriteDigest`, which
      # is ALSO the joined-entries digest of whatever was last
      # written — letting `decideAction`'s safe-update branch
      # (`recorded.postWriteDigest == observed.digest`) fire when
      # the live block reflects our last write but the desired
      # contribution has since changed (the classic "two-package
      # apply, then drop one" case).
      #
      # If the block is user-edited into a shape we can't parse, we
      # fall back to the raw-bytes digest; the lifecycle algorithm
      # then sees this as drift relative to the recorded digest,
      # which is the correct outcome (the user wrote something
      # outside our format and reconciliation requires explicit
      # operator intent).
      let liveEntries = parsePosixPathBlockEntries(
        bytesToString(observed.rawBytes))
      if liveEntries.len > 0:
        let joined = bytesOf(joinPathEntries(liveEntries))
        result.rawBytes = joined
        result.digest = digestOfBytes(joined)
      else:
        result.rawBytes = observed.rawBytes
        result.digest = observed.digest
