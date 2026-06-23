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

# ---------------------------------------------------------------------------
# fs.systemDirectory — directory-scope allowlist.
#
# The directory allowlist is a SUPERSET of `fs.systemFile`'s file
# allowlist. In addition to the fixed POSIX roots (`/etc/`,
# `/usr/local/etc/`) and the runtime `${PROGRAMDATA}` root, a directory
# may live under a top-level Windows install-root like `C:\actions-
# runner` or `C:\actions-runner-tokens`. The carve-out is necessary
# because production deployments install long-running services under
# the system drive's root rather than under `${PROGRAMDATA}` — there is
# no analogue at file scope (`fs.systemFile` writes are always config-
# directory writes, never install-root writes). The allowlist is still
# a closed set: the path must be a SINGLE-segment subdirectory of
# `<drive>:\` (no nested `C:\Users\<user>\...` or `C:\Windows\...`),
# free of any `..` segment, and shape-compliant with NTFS path
# conventions.
# ---------------------------------------------------------------------------

proc isTopLevelWindowsInstallRoot*(path: string): bool =
  ## True when `path` names a top-level subdirectory of a Windows
  ## drive root — shape `<X>:\<name>` or `<X>:\<name>\<subpath>` where
  ## `<X>` is a single drive letter and `<name>` is a single path
  ## segment in a conservative install-root charset (letters, digits,
  ## `.`, `-`, `_`). Used by `systemDirectoryScopeError` to admit the
  ## production install-root pattern (`C:\actions-runner`,
  ## `C:\actions-runner-tokens`) without opening the full Windows
  ## filesystem to the fs.systemDirectory driver.
  let n = normalizeSlashes(path)
  if n.len < 4:
    return false
  if not ((n[0] in {'A'..'Z'} or n[0] in {'a'..'z'}) and n[1] == ':' and
          n[2] == '/'):
    return false
  let rest = n[3 .. ^1]
  if rest.len == 0:
    return false
  # The first segment after the drive root is the install-root name.
  let firstSegEnd = rest.find('/')
  let firstSeg =
    if firstSegEnd < 0: rest else: rest[0 ..< firstSegEnd]
  if firstSeg.len == 0:
    return false
  for ch in firstSeg:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      return false
  return true

proc isAllowedSystemDirectoryPath*(path: string;
                                   programDataRoot = ""): bool =
  ## True for an absolute path that is either under one of the
  ## `fs.systemFile` allowlist roots OR is a top-level Windows install-
  ## root (e.g. `C:\actions-runner-tokens`). A `..` segment is
  ## refused regardless. The proc is pure; the driver supplies
  ## `programDataRoot` at apply time when running on Windows.
  if isAllowedSystemFilePath(path, programDataRoot):
    return true
  if isTopLevelWindowsInstallRoot(path):
    # Even an install-root carve-out path is refused if it contains
    # a `..` segment — the structural-escape guard is enforced
    # uniformly across both arms.
    let norm = normalizeSlashes(path)
    for seg in norm.split('/'):
      if seg == "..":
        return false
    return true
  return false

proc systemDirectoryScopeError*(path: string;
                                programDataRoot = ""): string =
  ## Returns "" when the directory path is in-scope, otherwise a
  ## human diagnostic naming the allowlist. The companion of
  ## `systemFileScopeError`. Pure — the driver turns a non-empty
  ## result into `EOutOfScope`.
  if isAllowedSystemDirectoryPath(path, programDataRoot):
    return ""
  var roots = "/etc/, /usr/local/etc/, <DRIVE>:\\<install-root>"
  if programDataRoot.len > 0:
    roots.add(", " & normalizeSlashes(programDataRoot))
  "fs.systemDirectory path '" & path & "' is not under a recognized " &
    "system directory (" & roots & ") — creating arbitrary system " &
    "directories is not permitted"

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
  ## -nG <name>` (FULL group set — primary + supplementary), and `id
  ## -gn <name>` (the primary group name).
  ##
  ## `id -nG` returns the COMPLETE group list — both the primary
  ## group and every supplementary group — so the primary is filtered
  ## out here to leave `groups` as the supplementary-only set the
  ## `passwd.user` resource pins. The distinction matters on every
  ## distro that runs `useradd` with `USERGROUPS_ENAB=yes` (the
  ## Debian / Ubuntu default): `useradd reprotest --groups users`
  ## creates a per-user primary group `reprotest` AND adds the user
  ## to supplementary `users`, so `id -nG reprotest` returns
  ## `reprotest users`. Without this filter the per-user primary
  ## group spuriously shows up as an "extraGroup" in `diffPasswd
  ## User` and breaks the post-apply re-probe digest comparison
  ## even on a freshly-converged `useradd`.
  result = parseGetentPasswd(getentLine)
  if not result.present:
    return
  result.primaryGroup = primaryGroupOutput.strip()
  let allGroups = parseIdGroups(idGroupsOutput)
  if result.primaryGroup.len > 0:
    for g in allGroups:
      if g != result.primaryGroup:
        result.groups.add(g)
  else:
    result.groups = allGroups

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

proc canonicalPasswdUserStateMaskedBy*(observed: PasswdUserObservation;
    desired: PasswdUserDesired): string =
  ## Render an observed user account in the SAME canonical form as
  ## `canonicalPasswdUserDesired`: any attribute the desired left
  ## unpinned (empty `homeDir` / `shell`, or the always-unpinned
  ## uid) is rendered as the literal `*` so the masked-observed
  ## bytes compare equal to the desired bytes whenever the pinned
  ## attributes match.
  ##
  ## This is the comparator the post-apply re-probe uses to decide
  ## "did `useradd` / `usermod` converge on what was asked for?". A
  ## resource that does not pin `homeDir` is satisfied by ANY
  ## observed home directory (the one `useradd` chose); the
  ## unmasked `canonicalPasswdUserState` stays unchanged for the
  ## drift-detection paths that need the literal observed value.
  ##
  ## Group semantics — ADDITIVE-only post-apply check (M11 fix). On
  ## Linux a fresh `useradd --groups <list>` ends up with exactly
  ## `<list>` as the supplementary set (because Linux's
  ## `USERGROUPS_ENAB=yes` auto-creates a per-user primary that
  ## `parsePasswdObservation` filters out, leaving only the
  ## declared supplementary set). On macOS a fresh `sysadminctl
  ## -addUser` makes the user a member of every "everyone-style"
  ## default group (`everyone`, `localaccounts`, `_appstore`,
  ## `_lpadmin`, `com.apple.access_*`, ...) — observed groups end
  ## up as a STRICT SUPERSET of the declared set, never equal.
  ## The original M82 post-apply contract compared groups as a SET
  ## (observed must equal desired) which works on Linux but
  ## fails-closed spuriously on macOS even when the apply
  ## genuinely succeeded. M11 changes the masked-canonical to mask
  ## groups DOWN to the intersection-with-desired: the observed
  ## groups are filtered to the set the resource actually
  ## declared, so the comparator checks "every declared group is
  ## observed" (additive — the contract `passwd.group` itself
  ## advertises) rather than "no extra groups exist" (subtractive
  ## — never a property the resource pinned). A future
  ## ~--strict-members~ resource attribute can flip the comparator
  ## back to the strict form. The unmasked
  ## `canonicalPasswdUserState` stays unchanged for the drift-
  ## detection paths that need the literal observed value.
  if not observed.present:
    return "user:absent"
  let homeRendered =
    if desired.homeDir.len > 0: observed.homeDir else: "*"
  let shellRendered =
    if desired.shell.len > 0: observed.shell else: "*"
  let desiredSet = normalizeGroupSet(desired.groups)
  var groupsMasked: seq[string]
  for g in normalizeGroupSet(observed.groups):
    if g in desiredSet:
      groupsMasked.add(g)
  "user:present;uid=*" &
    ";home=" & homeRendered &
    ";shell=" & shellRendered &
    ";groups=" & groupsMasked.join(",")

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

# ===========================================================================
# passwd.group — `getent group` parse + desired-vs-observed diff.
#
# The Linux `/etc/group` form is `name:passwd:gid:member1,member2,...`.
# `getent group <name>` renders that same colon line; the pure parser
# below digests its fields. The system-scope driver wraps `groupadd`
# / `groupmod` / `gpasswd` / `groupdel`; the PURE pieces — the
# observation parse and the desired-vs-observed diff — are here.
# ===========================================================================

type
  PasswdGroupObservation* = object
    ## What an observation of a group account reports. `present`
    ## false means the group does not exist.
    present*: bool
    gid*: string
    members*: seq[string]              ## member names, sorted

  PasswdGroupDesired* = object
    ## The desired state a `passwd.group` resource declares. An empty
    ## `gid` means "leave unpinned" (the system picks one on create,
    ## an existing gid is left alone on update). `members` is the
    ## supplementary-membership set the resource declares —
    ## ADDITIVE-ONLY semantics at the driver layer (a user already in
    ## the group but not listed is NOT removed; the M83 step-6 driver
    ## does not converge a membership-subtract by default).
    name*: string
    gid*: string
    members*: seq[string]

proc parseGetentGroup*(rawLine: string): PasswdGroupObservation =
  ## Parse a single `getent group <name>` line — the canonical
  ## `name:passwd:gid:member1,member2,...` colon form. An empty /
  ## malformed line means the group is absent. The member list is
  ## sorted so the diff is order-insensitive.
  let t = rawLine.strip()
  if t.len == 0:
    result.present = false
    return
  let fields = t.split(':')
  if fields.len < 4:
    result.present = false
    return
  result.present = true
  result.gid = fields[2].strip()
  var members: seq[string]
  for tok in fields[3].split(','):
    let m = tok.strip()
    if m.len > 0:
      members.add(m)
  members.sort()
  result.members = members

type
  PasswdGroupDiff* = object
    ## The result of comparing a desired `passwd.group` against the
    ## live observation. `groupAbsent` => `groupadd` is needed.
    ## `gidDiffers` drives a `groupmod --gid`. `missingMembers` drives
    ## a `usermod -aG <name> <user>` per entry; `extraMembers` is
    ## REPORTED for completeness but NOT acted on (additive-only
    ## membership) unless a future `--strict-members` flag flips the
    ## driver to subtract them via `gpasswd -d`.
    groupAbsent*: bool
    gidDiffers*: bool
    missingMembers*: seq[string]
    extraMembers*: seq[string]

proc diffPasswdGroup*(desired: PasswdGroupDesired;
                      observed: PasswdGroupObservation): PasswdGroupDiff =
  ## Compare a desired group against the live observation. An empty
  ## desired `gid` is "unpinned" — never reported as a difference.
  ## The member set is compared as a SET; the resource pins the
  ## SUPPLEMENTARY membership additively, so a member present on the
  ## group but not declared is `extraMembers` (reported, not removed
  ## — the driver is additive-only by default).
  if not observed.present:
    result.groupAbsent = true
    for m in desired.members:
      let n = m.strip()
      if n.len > 0 and n notin result.missingMembers:
        result.missingMembers.add(n)
    result.missingMembers.sort()
    return
  if desired.gid.len > 0 and desired.gid.strip() != observed.gid.strip():
    result.gidDiffers = true
  var want: seq[string]
  for m in desired.members:
    let n = m.strip()
    if n.len > 0 and n notin want:
      want.add(n)
  want.sort()
  let have = observed.members
  for m in want:
    if m notin have:
      result.missingMembers.add(m)
  for m in have:
    if m notin want:
      result.extraMembers.add(m)

proc canonicalPasswdGroupState*(observed: PasswdGroupObservation): string =
  ## Render an observed group to a stable canonical string the broker's
  ## re-observe / drift digest covers. The gid is included (a group
  ## re-created with a different gid is a real change); members are
  ## sorted.
  if not observed.present:
    return "group:absent"
  "group:present;gid=" & observed.gid &
    ";members=" & observed.members.join(",")

proc canonicalPasswdGroupDesired*(desired: PasswdGroupDesired): string =
  ## The desired canonical string. An unpinned `gid` (empty) is
  ## rendered `*` so a desired state that does not pin the gid does
  ## not falsely equal an observed state that has one. ADDITIVE-only
  ## semantics: the canonical digest reflects the DECLARED members
  ## only — an observation with extra members will not match the
  ## desired digest, so the driver runs the apply (which is a no-op
  ## for already-present declared members and an `-aG` for missing
  ## ones). This is intentional: a profile that adds a member then is
  ## re-applied should converge the new member; ditto for the gid.
  var members: seq[string]
  for m in desired.members:
    let n = m.strip()
    if n.len > 0 and n notin members:
      members.add(n)
  members.sort()
  "group:present;gid=" & (if desired.gid.len > 0: desired.gid else: "*") &
    ";members=" & members.join(",")

# ---------------------------------------------------------------------------
# passwd.group command-argument construction. The driver passes argv
# directly and never interpolates an operator string into a shell line.
# ---------------------------------------------------------------------------

proc buildGroupaddArgs*(desired: PasswdGroupDesired): seq[string] =
  ## Build the `groupadd` argv for creating a new group. `--system`
  ## is deliberately NOT forced — a `passwd.group` resource may
  ## declare an ordinary user group.
  if desired.gid.len > 0:
    result.add("--gid")
    result.add(desired.gid)
  result.add(desired.name)

proc buildGroupmodGidArgs*(desired: PasswdGroupDesired): seq[string] =
  ## Build the `groupmod --gid <gid> <name>` argv. Only called when
  ## the diff reports `gidDiffers`; an empty desired gid never
  ## reaches here.
  result.add("--gid")
  result.add(desired.gid)
  result.add(desired.name)

proc buildGroupdelArgs*(name: string): seq[string] =
  ## Build the `groupdel <name>` argv for the destroy direction.
  result.add(name.strip())

# ===========================================================================
# linux.firewallRule — nftables rule body + comment marker + handle parser.
#
# Reprobuild manages exactly the rules it created. The marker that ties a
# wire `name` field to a live rule is the comment `repro-fw-<name>` —
# present on every rule we add, scanned for on every observe / destroy.
# The pure pieces — building the rule body, building the comment, and
# parsing `nft -a list chain` output for the rule's handle — live here.
#
# Separator choice (`-`, not `:`): nft's parser sub-parses bare comment
# tokens that contain `:` as `key:value` pairs and rejects them with
# "syntax error, unexpected colon". Even with shell-level `"…"` around
# the marker, the surrounding `nft add rule` invocation runs through
# `sh -c` and the shell strips the quotes before nft sees its argv. The
# only quoting layer nft itself honours is its OWN grammar; embedding
# `\"…\"` inside a single argv element works, but using a separator nft
# never sub-parses sidesteps the whole problem. The closed `name`
# charset (`A-Za-z0-9._-`) keeps `-` collision-free with the literal
# rule-name characters, so the marker boundary stays unambiguous.
# ===========================================================================

const NftCommentPrefix* = "repro-fw-"
  ## The comment prefix every Reprobuild-authored nftables rule carries.
  ## A rule the operator added by hand without this prefix is left
  ## alone; a rule with this prefix is the responsibility of the
  ## `linux.firewallRule` resource whose `name` matches.

proc nftRuleComment*(name: string): string =
  ## Build the comment string for a `linux.firewallRule` resource
  ## named `name`. The format is `repro-fw-<name>`; the closed
  ## charset on `name` is enforced by `isSafeNftRuleName` in
  ## `operations.nim`.
  NftCommentPrefix & name

proc nftRuleBody*(protocol, localPort, action, name: string): string =
  ## Build the rule body the driver passes to `nft add rule <chain>
  ## <body>`. The format mirrors the `nft` syntax exactly:
  ##
  ##   <protocol> dport <port> <action> comment "repro-fw:<name>"
  ##
  ## For icmp / icmpv6 the `dport` clause is omitted (the protocols
  ## have no port concept). The caller is responsible for the
  ## upstream closed-set validation; this proc just assembles the
  ## tokens.
  if protocol in ["icmp", "icmpv6"]:
    return protocol & " " & action & " comment \"" &
      nftRuleComment(name) & "\""
  protocol & " dport " & localPort & " " & action &
    " comment \"" & nftRuleComment(name) & "\""

proc parseNftHandleForComment*(rawOutput, comment: string): int =
  ## Parse `nft -a list chain <chain>` output for the handle of the
  ## rule carrying `comment`. Returns the integer handle, or -1 if
  ## no rule with that comment is present.
  ##
  ## A typical `nft -a list chain` line for a managed rule looks
  ## like:
  ##
  ##     tcp dport 22 accept comment "repro-fw:openssh" # handle 17
  ##
  ## The `# handle <N>` suffix is what `nft -a` emits; the parser
  ## walks lines, finds the one containing the comment marker, and
  ## reads the integer that follows `handle `. Robust to stray
  ## whitespace and trailing characters.
  for line in rawOutput.splitLines():
    if comment notin line:
      continue
    # Search for `handle` token; the integer immediately follows.
    let handleIdx = line.find("handle ")
    if handleIdx < 0:
      continue
    var i = handleIdx + len("handle ")
    var digits = ""
    while i < line.len and line[i] in {'0'..'9'}:
      digits.add(line[i])
      inc i
    if digits.len == 0:
      continue
    try:
      return parseInt(digits)
    except ValueError:
      continue
  return -1

proc parseNftRuleSpecForComment*(rawOutput, comment: string): string =
  ## Return the rule-body line (without leading whitespace, without
  ## the trailing `# handle N` suffix) for the rule carrying
  ## `comment` in `nft list chain` output. Returns "" if absent.
  ##
  ## The line text is what the canonical-bytes digest covers: two
  ## rules with the same comment but different actions (e.g. an
  ## operator hand-edited `accept` to `drop`) digest differently,
  ## so the broker's drift gate triggers a re-apply.
  for line in rawOutput.splitLines():
    if comment notin line:
      continue
    var clean = line.strip()
    let handleIdx = clean.find(" # handle")
    if handleIdx >= 0:
      clean = clean[0 ..< handleIdx].strip()
    return clean
  return ""

# ===========================================================================
# Linux distro probe — pure parser for `/etc/os-release`.
#
# Driver carve-outs (e.g. `systemd.systemUnit` on Alpine, which runs
# OpenRC) need to know whether the host is a systemd distro. The actual
# `/etc/os-release` read happens in `posix_system_driver.nim`; the pure
# parse logic lives here so the driver-side guard is testable
# cross-platform.
#
# `/etc/os-release` format (per `os-release(5)`):
#   KEY=value
#   KEY="quoted value"
#   # comments + blank lines allowed
# We treat the file as case-sensitive on keys (the spec mandates UPPER
# CASE) and tolerate surrounding whitespace + optional double / single
# quotes around values. A missing or empty `ID=` returns "".
# ===========================================================================

proc parseOsReleaseId*(rawContent: string): string =
  ## Extract the `ID=<distro>` value from a `/etc/os-release` file.
  ## Returns "" when the line is absent or empty. The IANA-style
  ## charset (lowercase letters, digits, `-`, `_`) is preserved
  ## verbatim — callers compare against literals like `"alpine"`,
  ## `"debian"`, `"fedora"`.
  for line in rawContent.splitLines():
    let t = line.strip()
    if t.len == 0 or t.startsWith("#"):
      continue
    if not t.startsWith("ID="):
      continue
    var value = t[3 .. ^1].strip()
    # Strip the optional surrounding quotes.
    if value.len >= 2 and
       ((value[0] == '"' and value[^1] == '"') or
        (value[0] == '\'' and value[^1] == '\'')):
      value = value[1 ..< value.len - 1]
    return value
  return ""

proc isAlpineFromOsRelease*(rawContent: string): bool =
  ## True when `/etc/os-release` declares `ID=alpine`. The Alpine
  ## family does NOT include `ID_LIKE=alpine` derivatives; if such a
  ## distro emerges, the caller can extend this predicate to also
  ## probe `ID_LIKE=`. The closed-set is the deliberate-conservative
  ## carve-out shape Recipe-Validation M7 requested.
  parseOsReleaseId(rawContent) == "alpine"

proc usesSystemdFromOsRelease*(rawContent: string): bool =
  ## True when the host's init system is reasonably expected to be
  ## systemd: i.e. NOT Alpine (OpenRC) and not Void (runit) and not
  ## Gentoo's OpenRC profile. The conservative default for an unknown
  ## distro is "yes" — every mainstream Linux distro the
  ## Recipe-Validation campaign covers (Arch, Debian, Fedora, Ubuntu,
  ## openSUSE) uses systemd by default. A non-systemd Linux distro
  ## that surfaces in the campaign should be added to this closed
  ## list before the carve-out is relaxed.
  let id = parseOsReleaseId(rawContent)
  id != "alpine" and id != "void" and id != "gentoo"
