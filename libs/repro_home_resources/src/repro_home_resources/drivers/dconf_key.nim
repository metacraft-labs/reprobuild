## `linux.dconfKey` driver — M83 step 7 (Driver A).
##
## Wraps `dconf write` / `dconf read` / `dconf reset` for the
## GNOME-stack settings database (`~/.config/dconf/user`). Per-user;
## the driver runs unelevated as the current user.
##
## Per the spec ("`linux.dconfKey`"):
##   - read:  `dconf read <key>`         (empty output = absent)
##   - write: `dconf write <key> <value>` (idempotent — dconf is
##                                         content-addressed)
##   - reset: `dconf reset <key>`         (revert to schema default)
##
## The `key` is a slash-prefixed dconf key path (e.g.
## `/org/gnome/desktop/interface/color-scheme`). The `value` is a
## GVariant textual literal — treated as opaque text by the driver
## (the operator picks the literal that matches the schema; the
## driver does not parse or validate the GVariant shape, mirroring
## the `linux.gsettings` driver's contract).
##
## The `when defined(linux)` branch shells out; every other platform
## raises `ENotImplementedPlatform` (fail-closed, NOT a silent
## no-op).
##
## ## Pure logic isolated for off-Linux unit testing
##
## `canonicalDconfBytes` (the M83-step-7 digest-input encoder) is a
## pure function exercised by the cross-platform smoke suite.

import std/[osproc, strutils]

import ./../errors
import ./../manifest_record
import ./../types

# ---------------------------------------------------------------------------
# Canonical-bytes derivation (pure).
# ---------------------------------------------------------------------------

proc canonicalDconfBytes*(valueLiteral: string): seq[byte] =
  ## The canonical byte sequence the digest covers. dconf is
  ## content-addressed (a write of the SAME value is a no-op), so
  ## the desired digest is over the GVariant literal verbatim — the
  ## same bytes the read path returns after stripping the trailing
  ## newline. Both `digestOfResource` and `observeDconfKey` call
  ## this helper so the desired-vs-observed comparison is byte-for-
  ## byte under the same encoding.
  result = newSeq[byte](valueLiteral.len)
  for i, ch in valueLiteral:
    result[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound shell-out).
# ---------------------------------------------------------------------------

proc observeDconfKey*(key: string): ObservedState =
  ## `dconf read <key>`. Empty stdout means "key not set / no
  ## value" (absent); a non-empty line is the current GVariant
  ## literal. The canonical bytes the digest covers are the
  ## stripped-of-trailing-newline literal.
  when defined(linux):
    # `key` is `quoteShell`'d as defence-in-depth layer 2;
    # `resourceValidationError` rejects a metacharacter-bearing dconf
    # key as layer 1. dconf keys legitimately contain `/` (path
    # separators) so the metacharacter filter MUST NOT reject `/`.
    let (output, exitCode) = execCmdEx(
      "dconf read " & quoteShell(key))
    if exitCode != 0:
      result.present = false
      result.digest = zeroDigest()
      return
    let val = output.strip(leading = false, trailing = true)
    if val.len == 0:
      # `dconf read` returns exit 0 + empty output when the key has
      # no user-set value (revert to schema default). Treat that as
      # absent so the lifecycle algorithm decides `create` on first
      # apply.
      result.present = false
      result.digest = zeroDigest()
      return
    let raw = canonicalDconfBytes(val)
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    raiseNotImplementedPlatform("linux.dconfKey", "linux")

proc applyDconfKey*(key, valueLiteral: string): seq[byte] =
  ## `dconf write <key> <value>`. The recorded payload bytes are
  ## the GVariant literal itself (the same bytes the observe path
  ## returns).
  when defined(linux):
    # `valueLiteral` is a GVariant literal that LEGITIMATELY carries
    # spaces, quotes and brackets — it is NOT validated against the
    # metacharacter set, so `quoteShell` here is its sole protection
    # (it must reach `dconf write` as exactly one argument). `key`
    # is `quoteShell`'d as defence-in-depth (validated at layer 1).
    let (output, exitCode) = execCmdEx(
      "dconf write " & quoteShell(key) & " " & quoteShell(valueLiteral))
    if exitCode != 0:
      raiseResourceDriver("dconf:" & key, "linux.dconfKey",
        "dconf write",
        "exit " & $exitCode & ": " & output.strip())
    result = canonicalDconfBytes(valueLiteral)
  else:
    raiseNotImplementedPlatform("linux.dconfKey", "linux")

proc destroyDconfKey*(key: string) =
  ## `dconf reset <key>` — revert the key to its schema default.
  ## Tolerates a non-zero exit (the key may already be at the
  ## default; `dconf reset` is best-effort by design).
  when defined(linux):
    # `key` is `quoteShell`'d (layer 2; validated layer 1).
    discard execCmd(
      "dconf reset " & quoteShell(key))
  else:
    raiseNotImplementedPlatform("linux.dconfKey", "linux")
