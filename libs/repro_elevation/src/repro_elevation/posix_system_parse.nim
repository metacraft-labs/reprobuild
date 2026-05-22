## Pure output-parsing + drift-comparison + file-generation logic for
## the M69 Phase-C POSIX / macOS system-scope drivers
## (`macos.systemDefault`, `systemd.systemUnit`, `launchd.systemDaemon`,
## `fs.systemFile`, `env.systemVariable`, `passwd.user`).
##
## Per the M68 Phase-B precedent: every real shell-out / filesystem
## write lives behind `when defined(linux)` / `when defined(macosx)`
## in `posix_system_driver.nim`; the PURE logic — parsing `defaults`,
## `systemctl show`, `id` / `getent passwd` output, the drift
## comparison, the launchd-plist / systemd-unit generation, the
## `passwd.user` attribute diff, and the system-PATH merge — is
## isolated HERE so it is unit-tested cross-platform without touching
## the host.
##
## No `import std/os`, no `osproc`, no platform syscalls — this module
## is platform-pure by construction.

import std/[algorithm, strutils]

# ===========================================================================
# macos.systemDefault — structural value comparison + path derivation.
#
# This is the system-scope analogue of M68 Phase B's `macos.userDefault`.
# The structural-comparison logic is GENUINELY the same as the home-scope
# driver — `defaults` re-serializes plists with whitespace / key-order
# variation regardless of scope — so the pure canonicalizer here is a
# faithful re-implementation of `repro_home_resources/drivers/defaults`'s
# `canonicalizeDefaultsValue`. It is re-declared (not imported) because
# `repro_elevation` deliberately does not depend on the home-scope
# resource library; the two catalogs are separate compilation units.
# ===========================================================================

proc canonicalizeDefaultsValue*(raw: string): string =
  ## Normalize a `defaults read` value into a canonical form so two
  ## structurally-equal values compare equal regardless of the
  ## whitespace / key-ordering `defaults` happened to emit. Dict
  ## members are sorted (key order is insignificant); array element
  ## order is preserved (arrays are ordered).
  proc canon(s: string; pos: var int): string

  proc skipWs(s: string; pos: var int) =
    while pos < s.len and s[pos] in {' ', '\t', '\n', '\r'}:
      inc pos

  proc readScalar(s: string; pos: var int): string =
    skipWs(s, pos)
    var tok = ""
    if pos < s.len and (s[pos] == '"' or s[pos] == '\''):
      let quote = s[pos]
      inc pos
      while pos < s.len:
        if s[pos] == '\\' and pos + 1 < s.len:
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
      var sorted = members
      sorted.sort()
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
      return "(" & elems.join(",") & ")"
    return readScalar(s, pos)

  var p = 0
  result = canon(raw, p)

proc defaultsValuesEqual*(a, b: string): bool =
  ## Structural equality of two `defaults` values: a dict with
  ## reordered keys compares equal; a reordered array does not. NOT
  ## a text compare.
  canonicalizeDefaultsValue(a) == canonicalizeDefaultsValue(b)

proc systemDefaultPlistPath*(domain: string): string =
  ## The on-disk plist a `macos.systemDefault` resource targets. The
  ## system-scope resource authors the plist path EXPLICITLY (per the
  ## spec, system-scope preferences don't always have a registered
  ## domain alias) — e.g. `/Library/Preferences/com.apple.loginwindow`.
  ## A bare reverse-DNS domain (no `/`) is resolved into the standard
  ## `/Library/Preferences/<domain>` location.
  let d = domain.strip()
  if d.contains('/'):
    d
  else:
    "/Library/Preferences/" & d

proc isSystemDefaultDomain*(domain: string): bool =
  ## A `macos.systemDefault` domain must resolve to a plist under
  ## `/Library/Preferences/` — the system-scope preferences root.
  ## A path that escapes that root is rejected with `EOutOfScope`
  ## (the same allowlist discipline `fs.systemFile` uses).
  let p = systemDefaultPlistPath(domain).strip()
  p.startsWith("/Library/Preferences/") and not p.contains("..")

# ===========================================================================
# systemd.systemUnit — unit-file path + `systemctl show` parsing.
#
# This is the system-scope analogue of M68's `systemd.userUnit`. The
# difference from user scope is genuine: the unit file lands under
# `/etc/systemd/system/` (not `~/.config/systemd/user/`) and the
# driver invokes `systemctl` WITHOUT `--user`. The unit-file content
# itself is operator-authored verbatim — there is no generator — so
# only the path derivation and the `systemctl show` parser are pure.
# ===========================================================================

const SystemdSystemUnitDir* = "/etc/systemd/system"
  ## The directory a `systemd.systemUnit` unit file lands in.

proc systemUnitPath*(name: string): string =
  ## The on-disk location of a systemd SYSTEM unit. A forward-slash
  ## join so the derivation is platform-independent for unit testing.
  ## `name` is the unit file name (e.g. `repro-agent.service`).
  let n = name.strip()
  SystemdSystemUnitDir & "/" & n

proc isSafeUnitName*(name: string): bool =
  ## A systemd unit name must be a single path segment — no `/`, no
  ## `..`, non-empty — so a `systemd.systemUnit` resource cannot
  ## escape `/etc/systemd/system/`.
  let n = name.strip()
  if n.len == 0:
    return false
  if n == "." or n == "..":
    return false
  '/' notin n and '\\' notin n

type
  SystemdUnitObservation* = object
    ## What `systemctl show <unit>` reports for a system unit. The
    ## driver reads `LoadState` (loaded / not-found / masked),
    ## `ActiveState` (active / inactive / failed) and `UnitFileState`
    ## (enabled / disabled / static / ...).
    loadState*: string
    activeState*: string
    unitFileState*: string

proc parseSystemctlShow*(rawOutput: string): SystemdUnitObservation =
  ## Parse the `key=value` lines of `systemctl show <unit>
  ## --property=LoadState,ActiveState,UnitFileState`. `systemctl
  ## show` always emits every requested property as a `Key=Value`
  ## line (an absent value is the empty string after the `=`), so
  ## the parse is unambiguous and pure.
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.len == 0:
      continue
    let idx = t.find('=')
    if idx < 0:
      continue
    let key = t[0 ..< idx].strip()
    let val = t[idx + 1 .. ^1].strip()
    case key
    of "LoadState": result.loadState = val
    of "ActiveState": result.activeState = val
    of "UnitFileState": result.unitFileState = val
    else: discard

proc systemdUnitIsLoaded*(obs: SystemdUnitObservation): bool =
  ## A unit is "present" when systemd has it loaded — the unit file
  ## exists and parsed. `not-found` means no unit file; `masked`
  ## means the unit file is shadowed by a `/dev/null` symlink (the
  ## driver still treats a masked unit as present-but-inert).
  obs.loadState.toLowerAscii() in ["loaded", "masked"]

# ===========================================================================
# launchd.systemDaemon — plist path + plist GENERATOR + launchctl parse.
#
# This is the system-scope analogue of M68's `launchd.userAgent`. The
# plist GENERATOR is GENUINELY the same shape as the user-agent
# generator (a `Label` + `ProgramArguments` + `RunAtLoad` dict) — so
# `buildLaunchDaemonPlist` is a faithful re-implementation of
# `repro_home_resources/drivers/launchd_user`'s `buildLaunchAgentPlist`.
# The system-scope DIFFERENCE is genuine: the plist lands under
# `/Library/LaunchDaemons/` (not `~/Library/LaunchAgents/`) and the
# driver bootstraps into the `system` domain target (not `gui/<uid>`).
# ===========================================================================

const LaunchDaemonsDir* = "/Library/LaunchDaemons"
  ## The directory a `launchd.systemDaemon` plist lands in.

proc daemonPlistPath*(label: string): string =
  ## The on-disk location of a system LaunchDaemon plist.
  let l = label.strip()
  LaunchDaemonsDir & "/" & l & ".plist"

proc isSafeDaemonLabel*(label: string): bool =
  ## A launchd daemon label must be a single path segment so the
  ## resource cannot escape `/Library/LaunchDaemons/`.
  let l = label.strip()
  if l.len == 0:
    return false
  if l == "." or l == "..":
    return false
  '/' notin l and '\\' notin l

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

proc buildLaunchDaemonPlist*(label: string; programArgs: seq[string];
                             runAtLoad: bool): string =
  ## Build a minimal-but-valid LaunchDaemon plist:
  ##   - `Label`            — the daemon label.
  ##   - `ProgramArguments` — the argv array (program + args).
  ##   - `RunAtLoad`        — whether launchd starts it at load.
  ##
  ## Newlines are LF; the caller writes the bytes verbatim. Pure
  ## function — the cross-platform smoke suite asserts the generated
  ## text. The plist shape is identical to a user LaunchAgent plist;
  ## launchd does not distinguish the two by content, only by the
  ## directory the plist lives in and the bootstrap domain target.
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
  result.add("</dict>\n")
  result.add("</plist>\n")

proc launchctlDaemonLoaded*(rawPrintOutput: string; code: int): bool =
  ## `launchctl print system/<label>` exits non-zero when the daemon
  ## is not bootstrapped. A zero exit with a non-empty body means the
  ## daemon is loaded.
  code == 0 and rawPrintOutput.strip().len > 0

# ===========================================================================
# fs.systemFile — the recognized-system-directory allowlist.
#
# Per the spec ("fs.systemFile"): writing arbitrary system paths is
# not permitted; the resource refuses paths that are not under a
# recognized system directory with `EOutOfScope`.
# ===========================================================================

const SystemFileAllowedRoots* = [
  "/etc/",
  "/usr/local/etc/"]
  ## The POSIX system-directory allowlist. On Windows the
  ## `${PROGRAMDATA}` root is added at runtime by the driver (it is
  ## not a fixed path). A `fs.systemFile` path must be under one of
  ## these roots.

proc normalizeSlashes*(p: string): string =
  ## Normalize backslashes to forward slashes for the allowlist
  ## check — `${PROGRAMDATA}` paths on Windows use backslashes.
  p.replace('\\', '/')

proc isAllowedSystemFilePath*(path: string; programDataRoot = ""): bool =
  ## True only for an absolute path under a recognized system
  ## directory (`/etc/`, `/usr/local/etc/`, or `${PROGRAMDATA}` when
  ## `programDataRoot` is supplied) and free of any `..` segment. A
  ## path outside the allowlist is rejected with `EOutOfScope`.
  let norm = normalizeSlashes(path).strip()
  if norm.len == 0:
    return false
  for seg in norm.split('/'):
    if seg == "..":
      return false
  for root in SystemFileAllowedRoots:
    if norm.startsWith(root):
      return true
  if programDataRoot.len > 0:
    var pdRoot = normalizeSlashes(programDataRoot).strip()
    if pdRoot.len > 0 and pdRoot[^1] != '/':
      pdRoot.add('/')
    if norm.startsWith(pdRoot):
      return true
  return false

proc systemFileScopeError*(path: string; programDataRoot = ""): string =
  ## Returns "" when the path is in-scope, otherwise a human
  ## diagnostic naming the allowlist. Pure — the driver turns a
  ## non-empty result into `EOutOfScope`.
  if isAllowedSystemFilePath(path, programDataRoot):
    return ""
  var roots = "/etc/, /usr/local/etc/"
  if programDataRoot.len > 0:
    roots.add(", " & normalizeSlashes(programDataRoot))
  "fs.systemFile path '" & path & "' is not under a recognized " &
    "system directory (" & roots & ") — writing arbitrary system " &
    "paths is not permitted"

# ===========================================================================
# env.systemVariable — system-PATH / system-environment merge logic.
#
# The system-scope analogue of M68's `env.userPath`. The
# contribution-not-overwrite merge — keep the existing entries this
# generation did NOT add, then append this generation's contribution —
# is GENUINELY the same algorithm as the user-PATH merge, so
# `computeMergedSystemPath` mirrors `env_user.computeMergedPath`. The
# storage backend differs (HKLM on Windows, `/etc/environment` /
# `/etc/profile.d` on POSIX) but that lives in the driver.
# ===========================================================================

proc splitPathList*(raw: string; sep: char): seq[string] =
  ## Split a PATH-like list on the platform separator. Empty entries
  ## are dropped, consistent with loader behavior.
  result = @[]
  for piece in raw.split(sep):
    if piece.len > 0:
      result.add(piece)

proc joinPathList*(entries: openArray[string]; sep: char): string =
  result = ""
  for i, e in entries:
    if i > 0:
      result.add(sep)
    result.add(e)

proc computeMergedSystemPath*(existing, contributed: openArray[string]):
    seq[string] =
  ## Merge logic for a system PATH-style variable: existing entries
  ## first (preserves the host's preferred order), then any
  ## contributed entry not already present. Identical to the
  ## `env.userPath` merge — system scope does not change the
  ## algorithm, only the storage backend.
  result = @[]
  for e in existing:
    if e notin result:
      result.add(e)
  for c in contributed:
    if c notin result:
      result.add(c)

proc subtractSystemPathContribution*(existing, contribution: openArray[string]):
    seq[string] =
  ## Remove only the recorded contribution entries from the live
  ## list — pre-existing / host-added entries (anything not in
  ## `contribution`) remain. The rollback / destroy direction.
  result = @[]
  for e in existing:
    if e notin contribution:
      result.add(e)

# ===========================================================================
# passwd.user — `id` / `getent passwd` parsing + the attribute diff.
#
# `passwd.user` has no home-scope analogue — it is wholly new code.
# The driver wraps `useradd`/`usermod`/`userdel` (Linux) and the
# `dscl` / `sysadminctl` equivalents (macOS). The PURE pieces — the
# observation parse and the desired-vs-observed attribute diff that
# decides whether a `usermod` is needed — are here.
# ===========================================================================

type
  PasswdUserObservation* = object
    ## What an observation of a user account reports. `present`
    ## false means the account does not exist.
    present*: bool
    uid*: string
    homeDir*: string
    shell*: string
    primaryGroup*: string
    groups*: seq[string]            ## supplementary group names, sorted

  PasswdUserDesired* = object
    ## The desired state a `passwd.user` resource declares. An empty
    ## `homeDir` / `shell` means "leave the system default"; the diff
    ## ignores an attribute the resource does not pin.
    name*: string
    homeDir*: string
    shell*: string
    groups*: seq[string]            ## supplementary groups

proc parseGetentPasswd*(rawLine: string): PasswdUserObservation =
  ## Parse a single `getent passwd <name>` line — the canonical
  ## `name:passwd:uid:gid:gecos:home:shell` colon-separated form.
  ## An empty / malformed line means the account is absent.
  let t = rawLine.strip()
  if t.len == 0:
    result.present = false
    return
  let fields = t.split(':')
  if fields.len < 7:
    result.present = false
    return
  result.present = true
  result.uid = fields[2].strip()
  result.homeDir = fields[5].strip()
  result.shell = fields[6].strip()

proc parseIdGroups*(rawOutput: string): seq[string] =
  ## Parse the supplementary-group name list from `id -nG <name>`
  ## output — a space-separated list of group names on one line.
  ## Returns the names sorted so the diff is order-insensitive.
  var names: seq[string]
  for tok in rawOutput.strip().split({' ', '\t', '\n', '\r'}):
    let g = tok.strip()
    if g.len > 0:
      names.add(g)
  names.sort()
  return names

proc parsePasswdObservation*(getentLine, idGroupsOutput, primaryGroupOutput:
                             string): PasswdUserObservation =
  ## Assemble a full `PasswdUserObservation` from the three probe
  ## outputs the driver collects: `getent passwd <name>` (or the
  ## macOS `dscl` equivalent rendered into the same colon form), `id
  ## -nG <name>` (supplementary groups), and `id -gn <name>` (the
  ## primary group name).
  result = parseGetentPasswd(getentLine)
  if not result.present:
    return
  result.groups = parseIdGroups(idGroupsOutput)
  result.primaryGroup = primaryGroupOutput.strip()

proc normalizeGroupSet(groups: openArray[string]): seq[string] =
  ## A sorted, de-duplicated copy of a group list — so the diff is
  ## order- and duplicate-insensitive.
  for g in groups:
    let n = g.strip()
    if n.len > 0 and n notin result:
      result.add(n)
  result.sort()

type
  PasswdUserDiff* = object
    ## The result of comparing a desired `passwd.user` against the
    ## live observation. `accountAbsent` => the account must be
    ## created. The `*Differs` flags drive a `usermod`.
    accountAbsent*: bool
    homeDirDiffers*: bool
    shellDiffers*: bool
    groupsDiffer*: bool
    missingGroups*: seq[string]     ## desired groups the user is NOT in
    extraGroups*: seq[string]       ## supplementary groups not desired

proc diffPasswdUser*(desired: PasswdUserDesired;
                     observed: PasswdUserObservation): PasswdUserDiff =
  ## Compare a desired user against the live observation. An empty
  ## desired `homeDir` / `shell` is "unpinned" — never reported as a
  ## difference. The group set is compared as a SET; the resource
  ## pins the SUPPLEMENTARY groups, so a group present on the user
  ## but not declared is `extraGroups` (a `usermod` re-set removes
  ## it, since `usermod -G` replaces the supplementary set).
  if not observed.present:
    result.accountAbsent = true
    result.missingGroups = normalizeGroupSet(desired.groups)
    return
  if desired.homeDir.len > 0 and
     desired.homeDir.strip() != observed.homeDir.strip():
    result.homeDirDiffers = true
  if desired.shell.len > 0 and
     desired.shell.strip() != observed.shell.strip():
    result.shellDiffers = true
  let want = normalizeGroupSet(desired.groups)
  let have = normalizeGroupSet(observed.groups)
  for g in want:
    if g notin have:
      result.missingGroups.add(g)
  for g in have:
    if g notin want:
      result.extraGroups.add(g)
  result.groupsDiffer =
    result.missingGroups.len > 0 or result.extraGroups.len > 0

proc passwdUserNeedsUpdate*(diff: PasswdUserDiff): bool =
  ## True when an EXISTING account needs a `usermod` to converge.
  not diff.accountAbsent and
    (diff.homeDirDiffers or diff.shellDiffers or diff.groupsDiffer)

proc canonicalPasswdUserState*(observed: PasswdUserObservation): string =
  ## Render an observed user account to a stable canonical string the
  ## broker's re-observe / drift digest covers. The uid is included
  ## (an account re-created with a different uid is a real change);
  ## the supplementary groups are sorted.
  if not observed.present:
    return "user:absent"
  "user:present;uid=" & observed.uid &
    ";home=" & observed.homeDir &
    ";shell=" & observed.shell &
    ";groups=" & normalizeGroupSet(observed.groups).join(",")

proc canonicalPasswdUserDesired*(desired: PasswdUserDesired): string =
  ## The desired canonical string. Unpinned attributes (empty
  ## `homeDir` / `shell`) are rendered as a literal `*` so a desired
  ## state that does not pin an attribute does not falsely equal an
  ## observed state that has one. The uid is never pinned by the
  ## resource — it is rendered `*`.
  "user:present;uid=*" &
    ";home=" & (if desired.homeDir.len > 0: desired.homeDir else: "*") &
    ";shell=" & (if desired.shell.len > 0: desired.shell else: "*") &
    ";groups=" & normalizeGroupSet(desired.groups).join(",")

# ---------------------------------------------------------------------------
# passwd.user command-argument construction. The `useradd` / `usermod`
# argv is built from typed fields — the driver passes argv directly
# and never interpolates an operator string into a shell line.
# ---------------------------------------------------------------------------

proc buildUseraddArgs*(desired: PasswdUserDesired): seq[string] =
  ## Build the `useradd` argv for creating a new account. `--system`
  ## is deliberately NOT forced — a `passwd.user` resource may
  ## declare an ordinary login account.
  result.add(desired.name)
  if desired.homeDir.len > 0:
    result.add("--home-dir")
    result.add(desired.homeDir)
    result.add("--create-home")
  if desired.shell.len > 0:
    result.add("--shell")
    result.add(desired.shell)
  let groups = normalizeGroupSet(desired.groups)
  if groups.len > 0:
    result.add("--groups")
    result.add(groups.join(","))

proc buildUsermodArgs*(desired: PasswdUserDesired;
                       diff: PasswdUserDiff): seq[string] =
  ## Build the `usermod` argv to converge an EXISTING account. Only
  ## the attributes that actually differ are passed. Returns an empty
  ## seq when nothing differs (no `usermod` needed).
  if not passwdUserNeedsUpdate(diff):
    return @[]
  if diff.homeDirDiffers:
    result.add("--home")
    result.add(desired.homeDir)
    result.add("--move-home")
  if diff.shellDiffers:
    result.add("--shell")
    result.add(desired.shell)
  if diff.groupsDiffer:
    # `usermod -G` REPLACES the supplementary group set with exactly
    # the declared set — this both adds the missing groups and drops
    # the extra ones.
    result.add("--groups")
    result.add(normalizeGroupSet(desired.groups).join(","))
  if result.len > 0:
    result.add(desired.name)

proc buildUserdelArgs*(name: string): seq[string] =
  ## Build the `userdel` argv for the destroy direction. `--remove`
  ## drops the home directory and mail spool too.
  result.add("--remove")
  result.add(name.strip())
