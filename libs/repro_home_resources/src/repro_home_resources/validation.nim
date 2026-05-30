## M68 home-scope resource validation — defence-in-depth layer 1.
##
## The home-scope analogue of M69's `operationValidationError`
## (`repro_elevation/operations.nim`). The four POSIX/macOS home
## drivers (`gsettings`, `defaults`, `systemd_user`, `launchd_user`)
## shell out — they interpolate operator-controlled typed fields
## into `execCmd` / `execCmdEx` command lines. The drivers escape
## every such field with `quoteShell` at the call site (layer 2),
## but a field that bears a shell metacharacter is, for these typed
## resources, never a legitimate value in the first place: a
## `defaults` value-type must be one of the fixed `defaults write`
## type flags, a launchd agent label is a reverse-DNS-style
## identifier. This module rejects such a value BEFORE it reaches
## any driver — the typed-resource model should never let an
## operator-controlled field arrive at a shell command line
## un-vetted.
##
## NOTE on severity: these are HOME-scope resources, applied
## UNELEVATED as the user who authored their own `home.nim`. No
## privilege boundary is crossed. This is a correctness /
## defence-in-depth hygiene check, not a privilege-escalation
## guard — a value bearing a metacharacter would simply be
## mishandled. `resourceValidationError` returns a human-readable
## reason string (empty == valid); the apply pipeline turns a
## non-empty reason into a fail-closed `EResourceDriver` before
## dispatch.
##
## Everything here is PURE — no shell-out, no platform `when` — so
## the cross-platform smoke suite exercises it on every host.

import std/[strutils]

import ./types

# ---------------------------------------------------------------------------
# launchd.userAgent — launchd label charset allowlist.
#
# `observeLaunchAgent` / `applyLaunchAgent` / `destroyLaunchAgent`
# interpolate `launchdLabel` into `launchctl print|bootout|bootstrap
# gui/<uid>/<label>` command lines AND into the on-disk plist file
# name (`agentPlistPath`). A launchd label is a reverse-DNS-style
# identifier; only alphanumerics, `.`, `-`, `_` have a legitimate
# place in one. Restricting the label to that charset closes the
# shell-injection surface (defence-in-depth layer 1; the driver
# `quoteShell`s `gui/<uid>/<label>` as layer 2) and also keeps the
# label from escaping its single path segment in the plist name.
# ---------------------------------------------------------------------------

proc isSafeLaunchdLabel*(label: string): bool =
  ## True only for a non-empty launchd label whose every character
  ## is in the conservative reverse-DNS identifier charset
  ## (alphanumerics, `.`, `-`, `_`), and which is not `.` or `..`.
  ## Shell metacharacters, whitespace and path separators are
  ## refused.
  let l = label.strip()
  if l.len == 0:
    return false
  if l == "." or l == "..":
    return false
  for ch in l:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      return false
  return true

# ---------------------------------------------------------------------------
# Shared shell-safety helper for the remaining shell-out fields.
#
# `linux.gsettings` (schema / path / key) and `systemd.userUnit`
# (unit name) also flow operator-controlled fields into `gsettings`
# / `systemctl --user` command lines. They are not closed sets, but
# none of them legitimately contains a shell metacharacter,
# whitespace, or a NUL — a GSettings schema id, dconf path or
# settings key, or a systemd unit file name are all plain
# identifiers. Reject any such character before dispatch (the
# driver `quoteShell`s the field as layer 2).
# ---------------------------------------------------------------------------

const ShellMetaCharacters* = {
  ';', '&', '|', '$', '`', '\\', '"', '\'', '<', '>', '(', ')',
  '{', '}', '[', ']', '*', '?', '~', '!', '#', '\n', '\r', '\t', ' '}
  ## Characters that have a special meaning to a POSIX shell (or are
  ## whitespace / control). None belongs in a GSettings identifier
  ## or a systemd unit name.

proc hasShellMetacharacter*(s: string): bool =
  ## True when `s` contains any character from `ShellMetaCharacters`.
  for ch in s:
    if ch in ShellMetaCharacters:
      return true
  return false

# ---------------------------------------------------------------------------
# Pre-dispatch resource validation.
#
# The home-scope analogue of M69's `operationValidationError`. The
# apply pipeline calls `resourceValidationError` on every desired
# `Resource` before it composes the plan; a non-empty return value
# is turned into a fail-closed driver error. Resource kinds whose
# drivers use Win32 APIs or pure file I/O (no shell-out) — every
# kind other than the four POSIX/macOS shell-out drivers — have
# nothing to validate here and return "".
# ---------------------------------------------------------------------------

proc resourceValidationError*(r: Resource): string =
  ## Return a human-readable reason a resource must be refused
  ## before any driver runs, or "" when the resource is acceptable.
  ## Only the four shell-out drivers' operator-controlled fields are
  ## checked — the Windows registry / managed-block / startup
  ## drivers do not shell out.
  case r.kind
  of rkMacosUserDefault:
    # The value-type is not a field on the resource today, but the
    # value literal must never carry a metacharacter that would
    # break out of the `defaults write` argument. The driver
    # `quoteShell`s every argument; this also rejects a metacharacter
    # in the domain / key, which are plain reverse-DNS / identifier
    # strings.
    if r.defaultsDomain.len == 0:
      return "macos.userDefault resource '" & r.address &
        "' has an empty domain"
    if r.defaultsKey.len == 0:
      return "macos.userDefault resource '" & r.address &
        "' has an empty key"
    if hasShellMetacharacter(r.defaultsDomain):
      return "macos.userDefault domain '" & r.defaultsDomain &
        "' contains a shell metacharacter or whitespace"
    if hasShellMetacharacter(r.defaultsKey):
      return "macos.userDefault key '" & r.defaultsKey &
        "' contains a shell metacharacter or whitespace"
    # `restartTarget` flows into `killall <target>`; it is a plain
    # process name.
    if r.defaultsRestartTarget.len > 0 and
       hasShellMetacharacter(r.defaultsRestartTarget):
      return "macos.userDefault restartTarget '" &
        r.defaultsRestartTarget &
        "' contains a shell metacharacter or whitespace"
  of rkLaunchdUserAgent:
    if not isSafeLaunchdLabel(r.launchdLabel):
      return "launchd.userAgent label '" & r.launchdLabel &
        "' is not a safe launchd identifier (letters, digits, " &
        "'.', '-', '_'; non-empty; not '.' or '..')"
  of rkLinuxGsettings:
    if r.gsettingsSchema.len == 0:
      return "linux.gsettings resource '" & r.address &
        "' has an empty schema"
    if r.gsettingsKey.len == 0:
      return "linux.gsettings resource '" & r.address &
        "' has an empty key"
    if hasShellMetacharacter(r.gsettingsSchema):
      return "linux.gsettings schema '" & r.gsettingsSchema &
        "' contains a shell metacharacter or whitespace"
    if hasShellMetacharacter(r.gsettingsPath):
      return "linux.gsettings path '" & r.gsettingsPath &
        "' contains a shell metacharacter or whitespace"
    if hasShellMetacharacter(r.gsettingsKey):
      return "linux.gsettings key '" & r.gsettingsKey &
        "' contains a shell metacharacter or whitespace"
  of rkSystemdUserUnit:
    if r.unitName.len == 0:
      return "systemd.userUnit resource '" & r.address &
        "' has an empty unit name"
    if hasShellMetacharacter(r.unitName):
      return "systemd.userUnit name '" & r.unitName &
        "' contains a shell metacharacter or whitespace"
    if '/' in r.unitName:
      return "systemd.userUnit name '" & r.unitName &
        "' must be a single path segment (no '/')"
  of rkLinuxDconfKey:
    # The dconf key path LEGITIMATELY contains `/` (it is a path
    # like `/org/gnome/desktop/interface/color-scheme`) but no
    # shell metacharacter belongs in it — `hasShellMetacharacter`
    # rejects every metacharacter and whitespace, and `/` is not
    # one (consistent with `linux.gsettings.path`).
    if r.dconfKey.len == 0:
      return "linux.dconfKey resource '" & r.address &
        "' has an empty key"
    if not r.dconfKey.startsWith("/"):
      return "linux.dconfKey key '" & r.dconfKey &
        "' must be slash-prefixed (e.g. '/org/gnome/...')"
    if hasShellMetacharacter(r.dconfKey):
      return "linux.dconfKey key '" & r.dconfKey &
        "' contains a shell metacharacter or whitespace"
    # `dconfValue` is an opaque GVariant literal — quoted at
    # `quoteShell` layer 2; not validated here.
  else:
    # Win32-API / pure-file-I/O drivers — no shell-out, nothing to
    # validate here.
    discard
  return ""
