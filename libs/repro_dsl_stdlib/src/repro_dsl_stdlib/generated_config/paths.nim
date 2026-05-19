## Path expansion + scope checking for `fs.configFile` and friends.
##
## Per `Generated-Configuration-Files.md`:
##
##   - `~/` and `${HOME}` expand to the home profile's target home directory
##     (`$REPRO_HOME_PROFILE_TARGET` if set, otherwise the real `$HOME` or
##     `%USERPROFILE%`).
##   - `${XDG_CONFIG_HOME}`, `${XDG_DATA_HOME}`, `${XDG_STATE_HOME}` expand to
##     the OS defaults when unset.
##   - `${APPDATA}`, `${LOCALAPPDATA}`, `${USERPROFILE}` are handled on Windows.
##   - Paths that escape the configured home / system scope after expansion
##     fail closed with `EOutOfScope`.

import std/[os, strutils]

type
  HomeScope* = object
    ## Resolved home-scope environment for path expansion. Constructed
    ## by `resolveHomeScope`; consumed by `expandPath`.
    home*: string
    xdgConfigHome*: string
    xdgDataHome*: string
    xdgStateHome*: string
    appData*: string
    localAppData*: string
    userProfile*: string

  EOutOfScope* = object of CatchableError

proc lookup(name: string): string =
  let v = getEnv(name)
  if v.len > 0: v else: ""

proc defaultIfEmpty(value, fallback: string): string =
  if value.len > 0: value else: fallback

proc resolveHomeScope*(): HomeScope =
  ## Build a `HomeScope` from the current environment. `$REPRO_HOME_PROFILE_TARGET`
  ## takes precedence over the real home directory so tests can confine
  ## generation to a fixture root.
  let target = lookup("REPRO_HOME_PROFILE_TARGET")
  var home =
    if target.len > 0: target
    elif lookup("HOME").len > 0: lookup("HOME")
    else: lookup("USERPROFILE")
  if home.len == 0:
    home = getHomeDir().strip(chars = {'/', '\\'}, leading = false)
  result.home = home
  result.userProfile = defaultIfEmpty(lookup("USERPROFILE"), home)
  result.xdgConfigHome = defaultIfEmpty(
    lookup("XDG_CONFIG_HOME"), home / ".config")
  result.xdgDataHome = defaultIfEmpty(
    lookup("XDG_DATA_HOME"), home / ".local" / "share")
  result.xdgStateHome = defaultIfEmpty(
    lookup("XDG_STATE_HOME"), home / ".local" / "state")
  let defaultAppData =
    when defined(windows):
      home / "AppData" / "Roaming"
    else:
      home / ".config"
  let defaultLocalAppData =
    when defined(windows):
      home / "AppData" / "Local"
    else:
      home / ".local" / "share"
  result.appData = defaultIfEmpty(lookup("APPDATA"), defaultAppData)
  result.localAppData = defaultIfEmpty(
    lookup("LOCALAPPDATA"), defaultLocalAppData)

proc replaceFirstAll(src, needle, repl: string): string =
  result = src
  var idx = result.find(needle)
  while idx >= 0:
    result = result[0 ..< idx] & repl & result[idx + needle.len .. ^1]
    idx = result.find(needle, start = idx + repl.len)

proc forwardSlashed(p: string): string =
  result = p.replace('\\', '/')

proc normalizeForScope(p: string): string =
  ## Normalize a path for the purpose of scope containment checks: replace
  ## backslashes with forward slashes, drop trailing slashes, lower-case on
  ## Windows. The result is used for prefix comparison only.
  result = forwardSlashed(p)
  while result.endsWith("/") and result.len > 1:
    result.setLen(result.len - 1)
  when defined(windows):
    result = result.toLowerAscii()

proc isWithinScope(absPath, scopeRoot: string): bool =
  if scopeRoot.len == 0: return false
  let a = normalizeForScope(absPath)
  let s = normalizeForScope(scopeRoot)
  if a == s: return true
  result = a.startsWith(s & "/")

proc expandPath*(scope: HomeScope; path: string): string =
  ## Expand placeholders in `path` and verify the resulting absolute
  ## path is inside `scope.home`. Raises `EOutOfScope` otherwise.
  if path.len == 0:
    raise newException(EOutOfScope, "empty path is not in any scope")
  var p = path
  # Tilde prefix.
  if p == "~" or p.startsWith("~/") or p.startsWith("~\\"):
    if p.len <= 1:
      p = scope.home
    else:
      p = scope.home / p[2 .. ^1]
  # Variable placeholders, longest-match-first so XDG_* are not
  # shadowed by HOME, etc.
  let replacements = @[
    ("${XDG_CONFIG_HOME}", scope.xdgConfigHome),
    ("${XDG_DATA_HOME}",   scope.xdgDataHome),
    ("${XDG_STATE_HOME}",  scope.xdgStateHome),
    ("${LOCALAPPDATA}",    scope.localAppData),
    ("${APPDATA}",         scope.appData),
    ("${USERPROFILE}",     scope.userProfile),
    ("${HOME}",            scope.home),
  ]
  for (needle, repl) in replacements:
    if repl.len > 0 and needle in p:
      p = p.replaceFirstAll(needle, repl)
  let absolute =
    if isAbsolute(p): p else: scope.home / p
  let resolved = absolutePath(absolute)
  if not isWithinScope(resolved, scope.home):
    raise newException(EOutOfScope,
      "path '" & path & "' (resolved to '" & resolved &
      "') is outside the home scope rooted at '" & scope.home & "'")
  result = resolved
