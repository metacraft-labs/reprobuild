## `systemd.userUnit` driver — Phase B.
##
## Manages a systemd user unit:
##   - apply:   write `~/.config/systemd/user/<name>`, then
##              `systemctl --user daemon-reload`, then optionally
##              `systemctl --user enable --now <name>`.
##   - destroy: `systemctl --user disable --now <name>`, remove the
##              unit file, then `systemctl --user daemon-reload`.
##   - observe: read the unit file + `systemctl --user is-enabled`.
##
## Every filesystem write lives INSIDE the `when defined(linux)`
## guard — the off-Linux path must NOT touch the disk; it raises
## `ENotImplementedPlatform` (fail-closed). On any non-Linux host
## the apply / destroy / observe entry points raise immediately.
##
## ## Pure logic isolated for off-Linux unit testing
##
## `userUnitPath` (the unit-file path derivation) and
## `canonicalUnitBytes` (the M83-step-4b digest-input encoder) are
## pure functions exercised by the Windows smoke suite.

import std/[osproc, strutils]
from repro_core/paths import extendedPath

when defined(linux):
  import std/os

import ./../errors
import ./../manifest_record
import ./../types

# ---------------------------------------------------------------------------
# Unit-file path derivation (pure).
# ---------------------------------------------------------------------------

proc userUnitPath*(homeDir, name: string): string =
  ## The on-disk location of a systemd user unit. Uses a forward-
  ## slash join so the derivation is platform-independent (the unit
  ## only ever lands on Linux, but the pure helper is unit-tested
  ## on Windows).
  var h = homeDir
  if h.len > 0 and (h[^1] == '/' or h[^1] == '\\'):
    h = h[0 ..< h.len - 1]
  h & "/.config/systemd/user/" & name

# ---------------------------------------------------------------------------
# Canonical-bytes derivation (pure).
# ---------------------------------------------------------------------------

proc canonicalUnitBytes*(unitContent: string; enabled: bool;
                        state: SystemdUnitState): seq[byte] =
  ## The canonical byte sequence the digest covers. M83 step 4b:
  ## `enabled` and `state` are reconciled by `systemctl` without
  ## touching the unit file, so a change to either MUST register
  ## as drift. The digest therefore covers a leading `\x1f`-
  ## separated tag tuple (`E0|E1`, then the state string) and then
  ## the unit-file body. Both `digestOfResource` and
  ## `observeUserUnit` call this helper so the desired-vs-observed
  ## comparison is byte-for-byte under the same encoding.
  let tag = (if enabled: "E1" else: "E0") & "\x1f" & $state & "\x1f"
  let total = tag.len + unitContent.len
  result = newSeq[byte](total)
  var i = 0
  for ch in tag:
    result[i] = byte(ord(ch))
    inc i
  for ch in unitContent:
    result[i] = byte(ord(ch))
    inc i

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound).
# ---------------------------------------------------------------------------

proc observeUserUnit*(homeDir, name: string): ObservedState =
  ## Read the unit file and query `systemctl --user is-enabled` +
  ## `is-active`. The canonical bytes the digest covers are the
  ## triple (`is-enabled`, `is-active`, unit-file contents) encoded
  ## by `canonicalUnitBytes`. A drift on any of the three planks
  ## therefore registers as observed != desired and the lifecycle
  ## algorithm emits an `update`.
  when defined(linux):
    let path = userUnitPath(homeDir, name)
    if not fileExists(extendedPath(path)):
      result.present = false
      result.digest = zeroDigest()
      return
    let content = readFile(extendedPath(path))
    # `name` is `quoteShell`'d as defence-in-depth layer 2;
    # `resourceValidationError` rejects a metacharacter-bearing unit
    # name as layer 1. `is-enabled` exits 0 when enabled, non-zero
    # otherwise; we treat the exit code as the source of truth (the
    # stdout token can also be `static`/`linked`/etc. for unusual
    # units, but `enabled vs. anything else` is the dimension the
    # lifecycle compares).
    let qname = quoteShell(name)
    let (_, enabledCode) = execCmdEx("systemctl --user is-enabled " & qname)
    let enabled = enabledCode == 0
    let (activeOut, _) = execCmdEx("systemctl --user is-active " & qname)
    let state =
      if activeOut.strip() == "active": susRunning
      else: susStopped
    let raw = canonicalUnitBytes(content, enabled, state)
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")

proc applyUserUnit*(homeDir, name, unitContent: string;
                    enabled: bool;
                    state: SystemdUnitState = susRunning): seq[byte] =
  ## Write the unit file, `daemon-reload`, then converge the
  ## `enabled` flag (`systemctl --user enable/disable`) and the
  ## runtime `state` (`systemctl --user start/stop`). All filesystem
  ## I/O is inside the linux guard.
  ##
  ## M83 step 4b changed the contract: `enabled` and `state` are
  ## now independent. The pre-4b call form
  ## `applyUserUnit(home, name, content, enabled = true)` used
  ## `enable --now` which combined the two; the new contract uses
  ## `enable` + `start` separately so a unit can be `enabled =
  ## true, state = "Stopped"` (boot-time enabled, currently
  ## stopped) or `enabled = false, state = "Running"` (transient
  ## one-shot started by hand) — every combination of the two
  ## fields is now reachable.
  when defined(linux):
    let path = userUnitPath(homeDir, name)
    createDir(extendedPath(parentDir(path)))
    writeFile(extendedPath(path), unitContent)
    let (reloadOut, reloadCode) = execCmdEx("systemctl --user daemon-reload")
    if reloadCode != 0:
      raiseResourceDriver("systemd:user:" & name, "systemd.userUnit",
        "systemctl --user daemon-reload",
        "exit " & $reloadCode & ": " & reloadOut.strip())
    # `name` is `quoteShell`'d (layer 2; validated at layer 1).
    let qname = quoteShell(name)
    if enabled:
      let (enableOut, enableCode) = execCmdEx(
        "systemctl --user enable " & qname)
      if enableCode != 0:
        raiseResourceDriver("systemd:user:" & name, "systemd.userUnit",
          "systemctl --user enable",
          "exit " & $enableCode & ": " & enableOut.strip())
    else:
      # Best-effort disable when not enabled. A unit that is already
      # disabled exits 0 from `disable`; a unit that has no
      # `[Install]` section emits a warning on stderr but is also
      # tolerated.
      discard execCmd("systemctl --user disable " & qname)
    case state
    of susRunning:
      let (startOut, startCode) = execCmdEx(
        "systemctl --user start " & qname)
      if startCode != 0:
        raiseResourceDriver("systemd:user:" & name, "systemd.userUnit",
          "systemctl --user start",
          "exit " & $startCode & ": " & startOut.strip())
    of susStopped:
      let (stopOut, stopCode) = execCmdEx(
        "systemctl --user stop " & qname)
      if stopCode != 0:
        # A unit that is already stopped exits 0 from `stop`; a
        # unit that no longer exists in the unit-file set after a
        # `daemon-reload` raises a non-zero exit but the file we
        # just wrote IS there, so any non-zero here is a real
        # failure.
        raiseResourceDriver("systemd:user:" & name, "systemd.userUnit",
          "systemctl --user stop",
          "exit " & $stopCode & ": " & stopOut.strip())
    result = canonicalUnitBytes(unitContent, enabled, state)
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")

proc destroyUserUnit*(homeDir, name: string) =
  ## Stop the unit if running, disable it, remove the unit file,
  ## then `daemon-reload`. The destroy direction tolerates every
  ## per-step exit code — a unit that is already stopped or
  ## disabled is the common case; only the final state matters,
  ## not whether each transitive command was a no-op.
  when defined(linux):
    let path = userUnitPath(homeDir, name)
    # `name` is `quoteShell`'d (layer 2; validated at layer 1).
    let qname = quoteShell(name)
    discard execCmd("systemctl --user stop " & qname)
    discard execCmd("systemctl --user disable " & qname)
    if fileExists(extendedPath(path)):
      try: removeFile(extendedPath(path))
      except OSError: discard
    discard execCmd("systemctl --user daemon-reload")
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")
