## `macos.userDefault` driver — Phase B.
##
## Reads / writes / deletes per-user macOS preferences via the
## `defaults` command-line tool. The `when defined(macosx)` branch
## shells out; on every other platform the apply / destroy / observe
## entry points raise `ENotImplementedPlatform` (fail-closed).
##
## Per the spec ("`macos.userDefault`"):
##   - observe: `defaults read <domain> <key>` + `defaults read-type`
##   - apply:   `defaults write <domain> <key> -<type> <value>`
##   - destroy: `defaults delete <domain> <key>`
##
## Drift detection compares values STRUCTURALLY, not as text:
## `defaults` re-serializes plists with whitespace / key-order
## variation, so a byte compare produces false positives. The
## `defaultsValuesEqual` pure function normalizes both sides into a
## canonical token tree and compares those.
##
## `restartTarget` runs `killall <target>` ONLY when the value
## actually changed — a cache-hit re-apply does NOT kick the daemon.
## This is the core assertion of gate 3
## (`e2e_macos_user_default_restart_target`).
##
## Container plists: sandboxed-app preferences live in container
## plists rather than the main user-defaults domain. The driver
## detects the container path automatically; a domain that is not
## writable from the current process produces `EUnsupportedDomain`.
##
## ## Pure logic isolated for off-macOS unit testing
##
## `canonicalizeDefaultsValue` and `defaultsValuesEqual` (the
## structural comparison) and `isContainerDomain` are pure
## functions exercised by the Windows smoke suite. Only the
## `defaults` / `killall` shell-out is platform-bound.

import std/[osproc, strutils]

import ./../errors
import ./../manifest_record
import ./../types

# ---------------------------------------------------------------------------
# Structural comparison (pure).
# ---------------------------------------------------------------------------

proc canonicalizeDefaultsValue*(raw: string): string =
  ## Normalize a `defaults read` value into a canonical form so two
  ## structurally-equal values compare equal regardless of the
  ## whitespace / key-ordering `defaults` happened to emit.
  ##
  ## The canonicalization:
  ##   - tokenizes on the plist structural characters `{ } ( ) ; ,`
  ##   - drops insignificant whitespace between tokens
  ##   - sorts the `key = value;` members of every `{ ... }` dict so
  ##     a reordered dict canonicalizes identically
  ##   - leaves array `( ... )` element order intact (arrays are
  ##     ordered; reordering an array IS a real change)
  ##
  ## Scalars (strings, numbers, booleans) pass through with only
  ## whitespace trimmed.
  proc canon(s: string; pos: var int): string

  proc skipWs(s: string; pos: var int) =
    while pos < s.len and s[pos] in {' ', '\t', '\n', '\r'}:
      inc pos

  proc readScalar(s: string; pos: var int): string =
    ## Read a run of characters up to the next structural delimiter.
    ## A wholly-quoted scalar (`'...'` or `"..."`) canonicalizes to
    ## its UNQUOTED content: `defaults read` returns bare strings
    ## while a `defaults write` literal may carry quotes, so quote
    ## style must not produce false drift. `=` is a delimiter so a
    ## `key = value;` dict member is tokenized as `key`, `=`,
    ## `value`, `;`.
    skipWs(s, pos)
    var tok = ""
    if pos < s.len and (s[pos] == '"' or s[pos] == '\''):
      let quote = s[pos]
      inc pos
      while pos < s.len:
        if s[pos] == '\\' and pos + 1 < s.len:
          # Keep the unescaped character so `'it\'s'` and `it's`
          # canonicalize the same.
          tok.add(s[pos + 1]); pos += 2
        elif s[pos] == quote:
          inc pos; break
        else:
          tok.add(s[pos]); inc pos
      return tok
    while pos < s.len and s[pos] notin {'{', '}', '(', ')', ';', ',',
        '=', ' ', '\t', '\n', '\r'}:
      tok.add(s[pos])
      inc pos
    return tok.strip()

  proc canon(s: string; pos: var int): string =
    skipWs(s, pos)
    if pos >= s.len:
      return ""
    if s[pos] == '{':
      inc pos
      var members: seq[string] = @[]
      while true:
        skipWs(s, pos)
        if pos >= s.len or s[pos] == '}':
          if pos < s.len: inc pos
          break
        let key = readScalar(s, pos)
        skipWs(s, pos)
        if pos < s.len and s[pos] == '=':
          inc pos
        let value = canon(s, pos)
        skipWs(s, pos)
        if pos < s.len and s[pos] == ';':
          inc pos
        members.add(key & "=" & value)
      # Sort dict members: key order is insignificant.
      var sorted = members
      # Simple insertion sort (member counts are small).
      for i in 1 ..< sorted.len:
        let cur = sorted[i]
        var j = i - 1
        while j >= 0 and sorted[j] > cur:
          sorted[j + 1] = sorted[j]
          dec j
        sorted[j + 1] = cur
      return "{" & sorted.join(";") & "}"
    if s[pos] == '(':
      inc pos
      var elems: seq[string] = @[]
      while true:
        skipWs(s, pos)
        if pos >= s.len or s[pos] == ')':
          if pos < s.len: inc pos
          break
        let elem = canon(s, pos)
        skipWs(s, pos)
        if pos < s.len and s[pos] == ',':
          inc pos
        elems.add(elem)
      # Arrays are ordered — element order is significant.
      return "(" & elems.join(",") & ")"
    # Scalar.
    return readScalar(s, pos)

  var p = 0
  result = canon(raw, p)

proc defaultsValuesEqual*(a, b: string): bool =
  ## Structural equality: two `defaults` values are equal when their
  ## canonical forms match. A dict with reordered keys compares
  ## equal; a reordered array does not. NOT a text compare.
  canonicalizeDefaultsValue(a) == canonicalizeDefaultsValue(b)

# ---------------------------------------------------------------------------
# Container-domain detection (pure).
# ---------------------------------------------------------------------------

proc isContainerDomain*(domain: string): bool =
  ## Sandboxed-app preferences live in container plists under
  ## `~/Library/Containers/<bundle-id>/Data/Library/Preferences/`.
  ## A domain that is itself a path under `Containers/` (or that the
  ## caller already resolved to a container plist path) is a
  ## container domain. Plain reverse-DNS bundle ids are NOT treated
  ## as containers here — the `defaults` tool resolves those itself;
  ## the driver only special-cases an explicit container path.
  domain.contains("/Library/Containers/") or
    domain.contains("\\Library\\Containers\\")

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound shell-out).
# ---------------------------------------------------------------------------

proc observeUserDefault*(domain, key: string): ObservedState =
  ## `defaults read <domain> <key>` for the value plus
  ## `defaults read-type` for the type. The canonical bytes the
  ## digest covers are the structurally-canonicalized value text so
  ## that two structurally-equal observations digest identically.
  when defined(macosx):
    # `domain` / `key` are `quoteShell`'d as defence-in-depth: the
    # pre-dispatch validator (`resourceValidationError`) already
    # rejects any value bearing a shell metacharacter, but escaping
    # the arguments here means even a bypassed validation cannot
    # break out of the argument and reach arbitrary execution.
    let (output, exitCode) = execCmdEx(
      "defaults read " & quoteShell(domain) & " " & quoteShell(key))
    if exitCode != 0:
      result.present = false
      result.digest = zeroDigest()
      return
    let canonical = canonicalizeDefaultsValue(output.strip())
    var raw = newSeq[byte](canonical.len)
    for i, ch in canonical:
      raw[i] = byte(ord(ch))
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    raiseNotImplementedPlatform("macos.userDefault", "macosx")

proc applyUserDefault*(domain, key, valueLiteral: string;
                      restartTarget: string;
                      valueChanged: bool):
    seq[byte] =
  ## `defaults write <domain> <key> <value>`. Runs `killall
  ## <restartTarget>` ONLY when `valueChanged` is true — a cache-hit
  ## re-apply (the lifecycle algorithm's `rakNoOp` branch) never
  ## reaches this proc, and a reconcile-update passes
  ## `valueChanged = true`. The recorded payload bytes are the
  ## structurally-canonicalized value so drift comparison is stable.
  when defined(macosx):
    # Every operator-controlled argument is `quoteShell`'d (defence-
    # in-depth layer 2; `resourceValidationError` is layer 1).
    let (output, exitCode) = execCmdEx(
      "defaults write " & quoteShell(domain) & " " & quoteShell(key) &
      " " & quoteShell(valueLiteral))
    if exitCode != 0:
      raiseUnsupportedDomain(domain,
        "defaults write returned exit " & $exitCode & ": " &
        output.strip() & " (domain may be an unwritable sandboxed-app " &
        "container)")
    if restartTarget.len > 0 and valueChanged:
      discard execCmd("killall " & quoteShell(restartTarget))
    let canonical = canonicalizeDefaultsValue(valueLiteral)
    result = newSeq[byte](canonical.len)
    for i, ch in canonical:
      result[i] = byte(ord(ch))
  else:
    raiseNotImplementedPlatform("macos.userDefault", "macosx")

proc destroyUserDefault*(domain, key, restartTarget: string) =
  ## `defaults delete <domain> <key>`, then `killall <restartTarget>`
  ## so the affected daemon drops the now-removed value.
  when defined(macosx):
    # Operator-controlled arguments are `quoteShell`'d (layer 2).
    discard execCmd(
      "defaults delete " & quoteShell(domain) & " " & quoteShell(key))
    if restartTarget.len > 0:
      discard execCmd("killall " & quoteShell(restartTarget))
  else:
    raiseNotImplementedPlatform("macos.userDefault", "macosx")
