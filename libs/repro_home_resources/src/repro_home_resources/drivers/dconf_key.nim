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
## ## Session-bus bootstrap (the headless / bare-rootfs case)
##
## `dconf` is a D-Bus IPC client: every read/write/reset call talks
## to the per-user `ca.desrt.dconf` service through
## `$DBUS_SESSION_BUS_ADDRESS`. On a desktop session the login flow
## starts that bus; on a bare rootfs (a fresh WSL distro, a headless
## container, a remote shell with no `dbus-launch` prologue) there is
## NONE, and every `dconf` call fails with `error: Could not
## connect: No such file or directory`.
##
## The driver auto-bootstraps: when `$DBUS_SESSION_BUS_ADDRESS` is
## empty it wraps `dconf <verb>` with `dbus-run-session -- dconf
## <verb>`, which spawns a transient session bus for the lifetime of
## the child process. `dbus-run-session` ships in the `dbus` package
## on every systemd distro (Ubuntu, Debian, Fedora, Arch, NixOS).
## The per-user dconf database (`~/.config/dconf/user`) persists
## across these short-lived buses — the bus is purely IPC.
##
## When the operator already has a session bus (a GNOME login, a
## `dbus-launch` prologue, the harness's pre-flight
## `dbus-daemon --session --fork`), the wrapper is omitted and the
## driver calls `dconf` directly — `dbus-run-session` would spawn a
## SECOND bus and read a different dconf database for the current
## process, breaking observe-after-apply.
##
## The `when defined(linux)` branch shells out; every other platform
## raises `ENotImplementedPlatform` (fail-closed, NOT a silent
## no-op).
##
## ## Pure logic isolated for off-Linux unit testing
##
## `canonicalDconfBytes` (the M83-step-7 digest-input encoder) and
## `dconfArgvFor` (the bus-bootstrap-aware argv composer) are pure
## functions exercised by the cross-platform smoke suite.

import std/[os, osproc, strutils]

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

proc dconfArgvFor*(verb: string; args: openArray[string];
                   dbusSessionBusAddress: string): seq[string] =
  ## Compose the argv for one `dconf <verb> <args…>` invocation.
  ## When the supplied `dbusSessionBusAddress` is empty the result
  ## is wrapped with `dbus-run-session --` so a transient session
  ## bus is started for the lifetime of the child; when non-empty
  ## the wrapper is omitted (the operator's existing bus is reused
  ## so observe-after-apply reads the same dconf database).
  ##
  ## Pure for cross-platform unit testing — does NOT consult
  ## `getEnv` directly. The driver entry points read
  ## `$DBUS_SESSION_BUS_ADDRESS` and pass it in.
  let needsWrapper = dbusSessionBusAddress.strip().len == 0
  if needsWrapper:
    result.add("dbus-run-session")
    result.add("--")
  result.add("dconf")
  result.add(verb)
  for a in args:
    result.add(a)

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound shell-out).
# ---------------------------------------------------------------------------

when defined(linux):
  proc runDconfArgv(verb: string; args: openArray[string]):
      tuple[output: string, exitCode: int] =
    ## Run `dconf <verb> <args…>` via `execCmdEx`, wrapping the call
    ## in `dbus-run-session --` when `$DBUS_SESSION_BUS_ADDRESS` is
    ## empty. The argv elements are individually `quoteShell`-d to
    ## defence-in-depth the shell-out — the upstream validators
    ## already restricted the key charset; `valueLiteral` is opaque
    ## and may legitimately contain spaces / quotes / brackets, so
    ## quoting is its sole protection.
    let bus = getEnv("DBUS_SESSION_BUS_ADDRESS")
    let argv = dconfArgvFor(verb, args, bus)
    var line = ""
    for i, a in argv:
      if i > 0:
        line.add(' ')
      line.add(quoteShell(a))
    return execCmdEx(line)

proc observeDconfKey*(key: string): ObservedState =
  ## `dconf read <key>`. Empty stdout means "key not set / no
  ## value" (absent); a non-empty line is the current GVariant
  ## literal. The canonical bytes the digest covers are the
  ## stripped-of-trailing-newline literal.
  when defined(linux):
    # `resourceValidationError` rejects a metacharacter-bearing dconf
    # key as layer 1. dconf keys legitimately contain `/` (path
    # separators) so the metacharacter filter MUST NOT reject `/`.
    # The bus-bootstrap wrapper (added when DBUS_SESSION_BUS_ADDRESS
    # is empty) ensures the read can complete on a bare rootfs.
    let (output, exitCode) = runDconfArgv("read", [key])
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
    # metacharacter set, so `runDconfArgv` quotes every element as
    # its sole protection. The bus-bootstrap wrapper (added when
    # DBUS_SESSION_BUS_ADDRESS is empty) ensures the write can
    # complete on a bare rootfs.
    let (output, exitCode) = runDconfArgv("write", [key, valueLiteral])
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
  ## default; `dconf reset` is best-effort by design). The bus-
  ## bootstrap wrapper (added when DBUS_SESSION_BUS_ADDRESS is
  ## empty) keeps the reset path working on a bare rootfs.
  when defined(linux):
    discard runDconfArgv("reset", [key])
  else:
    raiseNotImplementedPlatform("linux.dconfKey", "linux")
