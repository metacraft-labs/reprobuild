## `linux.kdeConfigKey` driver — M83 step 7 (Driver B).
##
## Wraps `kwriteconfig5` / `kwriteconfig6` for KDE Plasma settings.
## Per-user; the driver runs unelevated, writing to
## `~/.config/<file>` (e.g. `kdeglobals`, `kwinrc`).
##
## Per the spec ("`linux.kdeConfigKey`"):
##   - read:   `kreadconfig<N> --file <file> --group <group> \
##                              --key <key> --default ""`
##   - write:  `kwriteconfig<N> --file <file> --group <group> \
##                              --key <key> <value>`
##   - delete: `kwriteconfig<N> --file <file> --group <group> \
##                              --key <key> --delete`
##
## The `<N>` is 5 or 6, selected via the `kdeVersion` field. The
## default is 6 (the modern Plasma 6 binary); a profile targeting
## Plasma 5 sets `kdeVersion = 5`. Setting any other integer raises
## `ValueError` from the binary-selection helper (`kwriteconfigBinary`
## / `kreadconfigBinary`); the parser / dispatcher rejects unknown
## values at layer 1 so this branch is only reached if the typed
## field carries a bad value.
##
## Observation semantics — kreadconfig's `--default` flag asks the
## binary to report the supplied string when the key is absent.
## We pass a distinct sentinel (`"\x1f__repro_absent__"`) and
## compare against it: matching sentinel = absent, anything else =
## present with the returned value. This lets the driver
## distinguish between "key not set" and "key set to the empty
## string" (which is a legitimate, though rare, KDE value).
##
## The `when defined(linux)` branch shells out; every other platform
## raises `ENotImplementedPlatform` (fail-closed, NOT a silent
## no-op).
##
## ## Pure logic isolated for off-Linux unit testing
##
## `kwriteconfigBinary`, `kreadconfigBinary`, the absence sentinel,
## and `canonicalKdeConfigBytes` are pure functions exercised by
## the cross-platform smoke suite.

import std/[osproc, strutils]

import ./../errors
import ./../manifest_record
import ./../types

# ---------------------------------------------------------------------------
# Pure helpers.
# ---------------------------------------------------------------------------

const KdeConfigAbsenceSentinel* = "\x1f__repro_absent__"
  ## Passed to `kreadconfig --default` so a missing key surfaces as
  ## a string distinct from any legitimate value the user could set.
  ## The leading `\x1f` (unit-separator control character) guarantees
  ## the sentinel cannot collide with any KDE-valid value (which are
  ## all printable text).

proc kwriteconfigBinary*(version: int): string =
  ## The `kwriteconfig5` / `kwriteconfig6` binary name. Raises
  ## `ValueError` for any other major version; the parser /
  ## dispatcher rejects unknown values at layer 1 so this branch
  ## is only reached if the typed field carries a bad value.
  case version
  of 5: "kwriteconfig5"
  of 6: "kwriteconfig6"
  else:
    raise newException(ValueError,
      "linux.kdeConfigKey: kdeVersion must be 5 or 6, got " &
      $version)

proc kreadconfigBinary*(version: int): string =
  ## The matching `kreadconfig5` / `kreadconfig6` binary name.
  case version
  of 5: "kreadconfig5"
  of 6: "kreadconfig6"
  else:
    raise newException(ValueError,
      "linux.kdeConfigKey: kdeVersion must be 5 or 6, got " &
      $version)

proc canonicalKdeConfigBytes*(value: string): seq[byte] =
  ## The canonical byte sequence the digest covers. kwriteconfig is
  ## idempotent (re-writing the same value is a no-op), so the
  ## desired digest is over the VALUE bytes verbatim — the same
  ## bytes `kreadconfig` returns. The `file` / `group` / `key`
  ## triple is part of the resource IDENTITY (carried via
  ## `realWorldIdentity`); a key path change is a different
  ## resource and goes through create/destroy rather than update.
  result = newSeq[byte](value.len)
  for i, ch in value:
    result[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound shell-out).
# ---------------------------------------------------------------------------

proc observeKdeConfigKey*(file, group, key: string;
                          version: int): ObservedState =
  ## `kreadconfig<N> --file <file> --group <group> --key <key>
  ## --default <sentinel>`. Output matching the sentinel = absent;
  ## any other output (including an empty line when the user set
  ## the value to the empty string) = present with that value.
  when defined(linux):
    # `file` / `group` / `key` are `quoteShell`'d as defence-in-
    # depth layer 2; `resourceValidationError` rejects a
    # metacharacter-bearing value as layer 1.
    let bin = kreadconfigBinary(version)
    let (output, exitCode) = execCmdEx(
      bin & " --file " & quoteShell(file) &
      " --group " & quoteShell(group) &
      " --key " & quoteShell(key) &
      " --default " & quoteShell(KdeConfigAbsenceSentinel))
    if exitCode != 0:
      # kreadconfig reports non-zero on missing binary or malformed
      # invocation. Treat as absent — the lifecycle algorithm will
      # then plan a create on the next apply.
      result.present = false
      result.digest = zeroDigest()
      return
    # kreadconfig appends a trailing newline; strip only the trailing
    # newline so an intentional empty-string value (rare but valid)
    # surfaces as `present == true` with an empty rawBytes.
    let val = output.strip(leading = false, trailing = true)
    if val == KdeConfigAbsenceSentinel:
      result.present = false
      result.digest = zeroDigest()
      return
    let raw = canonicalKdeConfigBytes(val)
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    raiseNotImplementedPlatform("linux.kdeConfigKey", "linux")

proc applyKdeConfigKey*(file, group, key, value: string;
                        version: int): seq[byte] =
  ## `kwriteconfig<N> --file <file> --group <group> --key <key>
  ## <value>`. Idempotent.
  when defined(linux):
    # `value` legitimately carries arbitrary characters (numerics,
    # paths, free-form strings); `quoteShell` here is its sole
    # protection. `file` / `group` / `key` are quoted as defence-
    # in-depth (validated at layer 1).
    let bin = kwriteconfigBinary(version)
    let (output, exitCode) = execCmdEx(
      bin & " --file " & quoteShell(file) &
      " --group " & quoteShell(group) &
      " --key " & quoteShell(key) &
      " " & quoteShell(value))
    if exitCode != 0:
      raiseResourceDriver("kde:" & file & ":" & group & ":" & key,
        "linux.kdeConfigKey", bin,
        "exit " & $exitCode & ": " & output.strip())
    result = canonicalKdeConfigBytes(value)
  else:
    raiseNotImplementedPlatform("linux.kdeConfigKey", "linux")

proc destroyKdeConfigKey*(file, group, key: string;
                         version: int) =
  ## `kwriteconfig<N> --file ... --group ... --key ... --delete`.
  ## Tolerates non-zero exit (a key that is already absent is the
  ## common case; only the final state matters).
  when defined(linux):
    let bin = kwriteconfigBinary(version)
    discard execCmd(
      bin & " --file " & quoteShell(file) &
      " --group " & quoteShell(group) &
      " --key " & quoteShell(key) &
      " --delete")
  else:
    raiseNotImplementedPlatform("linux.kdeConfigKey", "linux")
