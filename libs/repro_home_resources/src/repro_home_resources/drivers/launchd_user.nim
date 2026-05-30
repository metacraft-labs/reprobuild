## `launchd.userAgent` driver — Phase B.
##
## Manages a macOS LaunchAgent:
##   - apply:   write `~/Library/LaunchAgents/<label>.plist`, then
##              `launchctl bootstrap gui/<uid> <plist>`.
##   - destroy: `launchctl bootout gui/<uid>/<label>`, remove the
##              plist.
##   - observe: read the plist + `launchctl print gui/<uid>/<label>`.
##
## Modern `launchctl` form: the driver uses `bootstrap` / `bootout`
## (the domain-target API introduced in macOS 10.10) rather than the
## legacy `launchctl load` / `unload`. `bootstrap` is the documented
## supported path on every currently-supported macOS; `load` is kept
## only as a comment for historical context. The `gui/<uid>` domain
## target is the per-user GUI domain — the right domain for a
## user LaunchAgent.
##
## Every filesystem write lives INSIDE the `when defined(macosx)`
## guard. On any non-macOS host the apply / destroy / observe entry
## points raise `ENotImplementedPlatform` (fail-closed).
##
## ## Pure logic isolated for off-macOS unit testing
##
## `agentPlistPath` and the plist GENERATOR (`buildLaunchAgentPlist`)
## are pure functions exercised by the Windows smoke suite. Only the
## `launchctl` shell-out is platform-bound.

import std/[osproc, strutils]
from repro_core/paths import extendedPath

when defined(macosx):
  import std/os

import ./../errors
import ./../manifest_record
import ./../types

# ---------------------------------------------------------------------------
# Plist path derivation (pure).
# ---------------------------------------------------------------------------

proc agentPlistPath*(homeDir, label: string): string =
  ## The on-disk location of a user LaunchAgent plist. Forward-slash
  ## join so the derivation is platform-independent for unit testing.
  var h = homeDir
  if h.len > 0 and (h[^1] == '/' or h[^1] == '\\'):
    h = h[0 ..< h.len - 1]
  h & "/Library/LaunchAgents/" & label & ".plist"

# ---------------------------------------------------------------------------
# Plist GENERATOR (pure).
# ---------------------------------------------------------------------------

proc escapeXml*(s: string): string =
  ## Escape the five XML predefined entities for plist text nodes.
  result = ""
  for ch in s:
    case ch
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else: result.add(ch)

proc buildLaunchAgentPlist*(label: string; programArgs: seq[string];
                           runAtLoad: bool;
                           keepAlive: bool = false): string =
  ## Build a minimal-but-valid LaunchAgent plist:
  ##   - `Label`            — the agent label.
  ##   - `ProgramArguments` — the argv array (program + args).
  ##   - `RunAtLoad`        — whether launchd starts it at load.
  ##   - `KeepAlive`        — whether launchd restarts the agent
  ##                          after exit (M83 step 4b, default
  ##                          `false`).
  ##
  ## Newlines are LF; the caller writes the bytes verbatim (the
  ## driver's binary write avoids CRLF translation). This is a pure
  ## function: the Windows smoke suite asserts the generated text.
  ##
  ## Ordering note: the `KeepAlive` key is emitted AFTER `RunAtLoad`
  ## so the plist key order is `Label`, `ProgramArguments`,
  ## `RunAtLoad`, `KeepAlive`. Two semantically-equal plists with
  ## the same field values therefore hash to the same digest — the
  ## cache-hit no-op holds across applies.
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  result.add("<!DOCTYPE plist PUBLIC " &
    "\"-//Apple//DTD PLIST 1.0//EN\" " &
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n")
  result.add("<plist version=\"1.0\">\n")
  result.add("<dict>\n")
  result.add("  <key>Label</key>\n")
  result.add("  <string>" & escapeXml(label) & "</string>\n")
  result.add("  <key>ProgramArguments</key>\n")
  result.add("  <array>\n")
  for arg in programArgs:
    result.add("    <string>" & escapeXml(arg) & "</string>\n")
  result.add("  </array>\n")
  result.add("  <key>RunAtLoad</key>\n")
  result.add("  " & (if runAtLoad: "<true/>" else: "<false/>") & "\n")
  result.add("  <key>KeepAlive</key>\n")
  result.add("  " & (if keepAlive: "<true/>" else: "<false/>") & "\n")
  result.add("</dict>\n")
  result.add("</plist>\n")

# ---------------------------------------------------------------------------
# Typed-resource helper: render-or-use cached plist bytes.
# ---------------------------------------------------------------------------

proc launchAgentPlistFor*(label: string; programArgs: seq[string];
                          runAtLoad, keepAlive: bool;
                          cachedPlistContent: string = ""): string =
  ## The canonical plist for a `launchd.userAgent` resource. M83
  ## step 4b: when `cachedPlistContent` is non-empty the typed
  ## fields are bookkeeping and the bytes are used verbatim — this
  ## supports backwards-compatible apply paths where the upstream
  ## carried a literal `plistContent` field. When `cachedPlistContent`
  ## is empty (the M83 step 4b common case) the bytes are
  ## DETERMINISTICALLY rendered from `label` + `programArgs` +
  ## `runAtLoad` + `keepAlive` via `buildLaunchAgentPlist`.
  ##
  ## Cache-hit semantics: `digestOfResource` for `rkLaunchdUserAgent`
  ## calls this proc with the same arguments, so the desired-digest
  ## and the on-disk bytes are byte-for-byte identical when nothing
  ## changed.
  if cachedPlistContent.len > 0:
    return cachedPlistContent
  return buildLaunchAgentPlist(label, programArgs, runAtLoad, keepAlive)

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound).
# ---------------------------------------------------------------------------

when defined(macosx):
  proc currentUid(): string =
    ## The numeric uid of the running user, for the `gui/<uid>`
    ## launchctl domain target.
    let (out0, code) = execCmdEx("id -u")
    if code == 0:
      return out0.strip()
    return "501"  # conservative fallback for the default first user

proc observeLaunchAgent*(homeDir, label: string): ObservedState =
  ## Read the plist; `launchctl print` is queried for liveness. The
  ## canonical bytes the digest covers are the plist file contents.
  when defined(macosx):
    let path = agentPlistPath(homeDir, label)
    if not fileExists(extendedPath(path)):
      result.present = false
      result.digest = zeroDigest()
      return
    let content = readFile(extendedPath(path))
    var raw = newSeq[byte](content.len)
    for i, ch in content:
      raw[i] = byte(ord(ch))
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
    # `gui/<uid>/<label>` is `quoteShell`'d as one argument
    # (defence-in-depth layer 2; `resourceValidationError` already
    # rejects any label outside the launchd identifier charset at
    # layer 1).
    discard execCmdEx("launchctl print " &
      quoteShell("gui/" & currentUid() & "/" & label))
  else:
    raiseNotImplementedPlatform("launchd.userAgent", "macosx")

proc applyLaunchAgent*(homeDir, label, plistContent: string;
                      runAtLoad: bool;
                      keepAlive: bool = false): seq[byte] =
  ## Write the plist, then `launchctl bootstrap gui/<uid> <plist>`.
  ## A pre-existing agent is booted out first so `bootstrap` does
  ## not fail on a stale registration. All filesystem I/O is inside
  ## the macosx guard.
  when defined(macosx):
    let path = agentPlistPath(homeDir, label)
    createDir(extendedPath(parentDir(path)))
    writeFile(extendedPath(path), plistContent)
    let uid = currentUid()
    # Boot out any stale registration; ignore the exit code (no
    # prior registration is the common, non-error case). The
    # domain target and the plist path are `quoteShell`'d as one
    # argument each (defence-in-depth layer 2; the label is
    # validated against the launchd identifier charset at layer 1).
    discard execCmd("launchctl bootout " &
      quoteShell("gui/" & uid & "/" & label))
    let (bootOut, bootCode) = execCmdEx(
      "launchctl bootstrap " & quoteShell("gui/" & uid) & " " &
      quoteShell(path))
    if bootCode != 0:
      raiseResourceDriver("launchd:user:" & label, "launchd.userAgent",
        "launchctl bootstrap",
        "exit " & $bootCode & ": " & bootOut.strip())
    discard runAtLoad  # RunAtLoad is encoded in the plist itself.
    discard keepAlive  # KeepAlive is encoded in the plist itself.
    result = newSeq[byte](plistContent.len)
    for i, ch in plistContent:
      result[i] = byte(ord(ch))
  else:
    raiseNotImplementedPlatform("launchd.userAgent", "macosx")

proc destroyLaunchAgent*(homeDir, label: string) =
  ## `launchctl bootout gui/<uid>/<label>`, then remove the plist.
  when defined(macosx):
    let path = agentPlistPath(homeDir, label)
    # `gui/<uid>/<label>` is `quoteShell`'d as one argument
    # (layer 2; the label is validated at layer 1).
    discard execCmd("launchctl bootout " &
      quoteShell("gui/" & currentUid() & "/" & label))
    if fileExists(extendedPath(path)):
      try: removeFile(extendedPath(path))
      except OSError: discard
  else:
    raiseNotImplementedPlatform("launchd.userAgent", "macosx")
