## The configured Nimble mirrors (Nimble-Package-Catalog.md NPC-AREQ13,
## CLI/nimble.md § Configuration): the list of mirror locations a fetch of
## `nimble:` sources tries before each catalog's own mirrors and before the
## origin.
##
## `mirrors` under `[nimble]` is read from, in this order:
##
## 1. the user's Reprobuild configuration file,
##    `$XDG_CONFIG_HOME/reprobuild/config.toml`, else
##    `~/.config/reprobuild/config.toml`;
## 2. the system's, `/etc/repro/config.toml`;
## 3. the workspace's shared settings file, `repro-workspace.toml`, for the
##    organization's mirrors.
##
## The lists are concatenated in that order and a location that appears
## twice is kept at its first place, so a host's own mirrors come before the
## organization's. The personal `repro-workspace.local.toml` does not take
## the key: it carries manifest layers only, and a `[nimble]` table there is
## refused naming the file. A malformed entry -- not a string, or neither an
## `https://` URL nor an absolute directory -- is refused naming the file and
## the entry.
##
## No configured mirror is trusted: every object fetched from one is checked
## against the lock's digest. The order decides only where bytes are fetched
## from first.
##
## Every path is a field of ``MirrorConfigPaths``, so a caller (a test) can
## point the reader at files under a private root and nothing of the host's
## is read.

import std/[os, strutils, tables]

import toml_serialization
import toml_serialization/types as toml_types

import repro_core/workspace_root
import repro_nimble_fetch

const
  SystemReprobuildConfigPath* = "/etc/repro/config.toml"
    ## The system's Reprobuild configuration file (CLI/nimble.md).
  NimbleMirrorsKey = "nimble.mirrors"
  LocalSettingsFileName = "repro-workspace.local.toml"

type
  NimbleMirrorConfigError* = object of CatchableError
    ## A configured mirror list that cannot be used; the message names the
    ## file and the entry.

  MirrorConfigPaths* = object
    ## The files the configured mirrors are read from. "" = no such file.
    user*: string
    system*: string
    workspace*: string       ## `repro-workspace.toml`
    workspaceLocal*: string  ## `repro-workspace.local.toml`, refused if it has the key

  ConfiguredMirror* = object
    location*: string ## as written: an `https://` base URL or an absolute directory
    source*: string   ## the file that declared it

  EnvLookup* = proc (name: string): string {.closure.}

proc hostEnv(name: string): string = getEnv(name)

const
  UserConfigEnvVar* = "REPROBUILD_USER_CONFIG"
    ## Names the user's Reprobuild configuration file instead of the XDG
    ## location, as for the other readers of that file.
  SystemConfigEnvVar* = "REPROBUILD_SYSTEM_CONFIG"
    ## Names the system's Reprobuild configuration file instead of
    ## ``SystemReprobuildConfigPath``, as for the other readers of it.

proc userReprobuildConfigPath*(env: EnvLookup = hostEnv): string =
  ## ``UserConfigEnvVar`` when set; else
  ## `$XDG_CONFIG_HOME/reprobuild/config.toml`, else
  ## `$HOME/.config/reprobuild/config.toml`; "" when none is known. A
  ## relative `XDG_CONFIG_HOME` is ignored, as the XDG base directory
  ## specification requires.
  let named = env(UserConfigEnvVar)
  if named.len > 0:
    return named
  let xdg = env("XDG_CONFIG_HOME")
  if xdg.len > 0 and xdg.isAbsolute:
    xdg / "reprobuild" / "config.toml"
  elif env("HOME").len > 0:
    env("HOME") / ".config" / "reprobuild" / "config.toml"
  else:
    ""

proc systemReprobuildConfigPath*(env: EnvLookup = hostEnv): string =
  ## ``SystemConfigEnvVar`` when set, else ``SystemReprobuildConfigPath``.
  let named = env(SystemConfigEnvVar)
  if named.len > 0: named else: SystemReprobuildConfigPath

proc mirrorConfigPathsFor*(projectRoot: string; env: EnvLookup = hostEnv):
    MirrorConfigPaths =
  ## The host's files for a project: the user's and the system's
  ## configuration and the settings files of the workspace that owns
  ## ``projectRoot`` (none when it is in no workspace).
  result.user = userReprobuildConfigPath(env)
  result.system = systemReprobuildConfigPath(env)
  let root = findWorkspaceRoot(absolutePath(projectRoot))
  if root.len > 0:
    let settings = settingsFileIn(root)
    if settings.len > 0:
      result.workspace = settings
    if fileExists(root / LocalSettingsFileName):
      result.workspaceLocal = root / LocalSettingsFileName

proc configError(msg: string) {.noreturn.} =
  raise newException(NimbleMirrorConfigError, msg)

proc readTree(path: string): TomlValueRef =
  try:
    result = Toml.decode(readFile(path), TomlValueRef)
  except CatchableError as e:
    configError(path & ": cannot be read as TOML: " & e.msg.splitLines()[0])
  if result.isNil or result.kind notin {TomlKind.Table, TomlKind.InlineTable}:
    configError(path & ": is not a TOML table")

proc mirrorsOfFile(path: string): seq[string] =
  ## The `[nimble] mirrors` entries ``path`` declares, each checked; empty
  ## when the file or the key is absent. Other tables of the file are not
  ## this reader's and are not looked at.
  if path.len == 0 or not fileExists(path):
    return
  let tree = readTree(path)
  if "nimble" notin tree.tableVal:
    return
  let nimble = tree.tableVal["nimble"]
  if nimble.kind notin {TomlKind.Table, TomlKind.InlineTable}:
    configError(path & ": `nimble` must be a table")
  for k, _ in nimble.tableVal:
    if k != "mirrors":
      configError(path & ": unknown key `nimble." & k & "`; the `[nimble]` " &
        "table takes `mirrors` only")
  if "mirrors" notin nimble.tableVal:
    return
  let list = nimble.tableVal["mirrors"]
  if list.kind != TomlKind.Array:
    configError(path & ": `" & NimbleMirrorsKey & "` must be an array of " &
      "mirror locations (https:// base URLs or absolute directories)")
  for i, item in list.arrayVal:
    let at = path & ": `" & NimbleMirrorsKey & "[" & $i & "]`"
    if item.isNil or item.kind != TomlKind.String:
      configError(at & " is not a string; each entry is an https:// base " &
        "URL or an absolute directory")
    let location = item.stringVal
    try:
      discard parseMirror(location)
    except CatchableError:
      configError(at & " = " & location.escape() & " is neither an " &
        "https:// base URL nor an absolute directory")
    result.add location

proc refuseLocalKey(path: string) =
  if path.len == 0 or not fileExists(path):
    return
  let tree = readTree(path)
  if "nimble" in tree.tableVal:
    configError(path & ": `[nimble]` cannot be declared in " &
      LocalSettingsFileName & ", which carries manifest layers only; " &
      "declare the organization's Nimble mirrors in repro-workspace.toml, " &
      "or this host's in the user's or the system's Reprobuild " &
      "configuration")

proc configuredNimbleMirrors*(paths: MirrorConfigPaths): seq[ConfiguredMirror] =
  ## See the module header. Raises ``NimbleMirrorConfigError``.
  refuseLocalKey(paths.workspaceLocal)
  var seen = initTable[string, string]()
  for source in [paths.user, paths.system, paths.workspace]:
    for location in mirrorsOfFile(source):
      # A location is compared in the form the fetch uses (an https base
      # URL gains its trailing `/`), so `https://m/x` and `https://m/x/`
      # are one mirror, kept where it first appeared.
      let key = parseMirror(location).location
      if key in seen:
        continue
      seen[key] = source
      result.add ConfiguredMirror(location: location, source: source)

proc fetchMirrorsOf*(configured: seq[ConfiguredMirror]): seq[Mirror] =
  ## The configured mirrors as the fetch takes them, in order. A configured
  ## mirror is optional: a miss there moves on to the next location.
  for c in configured:
    result.add parseMirror(c.location, required = false)
