## Host identity resolution and profile-directory discovery for the
## home profile intent layer.
##
## Per `Home-Profile-Intent-Layer.md`:
##
##   - Profile directory: `--profile-dir <path>` (CLI override) >
##     `$REPRO_HOME_PROFILE_DIR` > OS default
##     (`$XDG_CONFIG_HOME/repro/home/` on Linux/macOS,
##      `%APPDATA%\repro\home\` on Windows).
##   - Host identity: `$REPRO_HOST` > `--host <name>` (CLI override) >
##     lowercased OS hostname. Every `repro home` subcommand, `repro infra
##     plan` / `apply` and `repro system sync` / `rollback` resolve it once,
##     through `selectHost`, which also refuses a `--host` that `$REPRO_HOST`
##     would silently override (§Host Identity).

import std/[os, strutils]
when not defined(windows):
  from std/nativesockets import getHostname
from repro_core/paths import extendedPath

import ./errors

const
  HomeProfileEnvVar* = "REPRO_HOME_PROFILE_DIR"
  HomeHostEnvVar* = "REPRO_HOST"
  HomeProfileAnchor* = "home.nim"

when defined(windows):
  proc getComputerNameW(buf: WideCString; size: ptr int32): int32 {.
    stdcall, dynlib: "kernel32", importc: "GetComputerNameW".}

# ---------------------------------------------------------------------------
# CLI-override state. The CLI layer (M61) calls these setters once it has
# parsed argv; everything else in this library reads through the resolver.
# ---------------------------------------------------------------------------

var
  cliProfileDirOverride: string
  cliHostOverride: string

proc setProfileDirOverride*(path: string) =
  ## CLI-side setter for the `--profile-dir <path>` flag. Pass the empty
  ## string to clear.
  cliProfileDirOverride = path

proc setHostOverride*(name: string) =
  ## CLI-side setter for the `--host <name>` flag. Pass the empty string
  ## to clear.
  cliHostOverride = name

proc clearOverrides*() =
  ## Reset all CLI overrides. Tests use this to keep test cases isolated.
  cliProfileDirOverride = ""
  cliHostOverride = ""

# ---------------------------------------------------------------------------
# Profile directory discovery.
# ---------------------------------------------------------------------------

proc osDefaultProfileDir*(): string =
  ## OS-default profile directory per the spec:
  ##   Linux/macOS: `$XDG_CONFIG_HOME/repro/home/` (XDG_CONFIG_HOME
  ##                defaults to `$HOME/.config` when unset).
  ##   Windows:     `%APPDATA%\repro\home\`.
  when defined(windows):
    let appData = getEnv("APPDATA")
    if appData.len > 0:
      return appData / "repro" / "home"
    let userProfile = getEnv("USERPROFILE")
    if userProfile.len > 0:
      return userProfile / "AppData" / "Roaming" / "repro" / "home"
    return getHomeDir() / "AppData" / "Roaming" / "repro" / "home"
  else:
    let xdg = getEnv("XDG_CONFIG_HOME")
    if xdg.len > 0:
      return xdg / "repro" / "home"
    return getHomeDir() / ".config" / "repro" / "home"

proc resolveProfileDir*(): string =
  ## Resolve the profile directory in the documented precedence:
  ##
  ## 1. CLI override (set via `setProfileDirOverride`)
  ## 2. `$REPRO_HOME_PROFILE_DIR`
  ## 3. OS default
  if cliProfileDirOverride.len > 0:
    return cliProfileDirOverride
  let env = getEnv(HomeProfileEnvVar)
  if env.len > 0:
    return env
  result = osDefaultProfileDir()

proc resolveProfilePath*(): string =
  ## Path to the anchor file `home.nim` inside the resolved profile
  ## directory. The file itself need not exist yet — see
  ## `loadProfilePath` for the existence check.
  result = resolveProfileDir() / HomeProfileAnchor

proc loadProfilePath*(): string =
  ## Return the absolute path of the profile's `home.nim`, raising
  ## `ENoProfile` if it is not present. The caller decides whether to
  ## scaffold a new profile in that case.
  let dir = resolveProfileDir()
  let path = dir / HomeProfileAnchor
  if not fileExists(extendedPath(path)):
    raiseNoProfile(dir, path)
  result = path

# ---------------------------------------------------------------------------
# Host identity.
# ---------------------------------------------------------------------------

proc normalizeHostName*(raw: string): string =
  ## The OS hostname as a host identity: surrounding whitespace removed and
  ## ASCII lower-cased, so `WIN-CI-BARE-001` (Windows spells
  ## `%COMPUTERNAME%` in upper case) and the `win-ci-bare-001` a `hosts:`
  ## registry is written with are one host (Home-Profile-Intent-Layer.md
  ## §Host Identity). Applied to the OS hostname only: `$REPRO_HOST` and
  ## `--host` are names the user chose and are used as given.
  raw.strip().toLowerAscii()

type
  OsHostnameSources* = object
    ## What the OS hostname is read from, kept apart from reading it so the
    ## per-platform rule is testable on any host (a Linux run can feed it the
    ## Windows inputs). `currentOsHostnameSources` fills it from the process.
    windows*: bool
      ## Which platform's rule applies.
    computerName*: string
      ## `%COMPUTERNAME%` (consulted on Windows only).
    hostnameEnv*: string
      ## `$HOSTNAME` (consulted on POSIX only).
    probe*: proc (): string {.closure.}
      ## The OS call used when the variable is empty: `GetComputerNameW` on
      ## Windows, gethostname(2) on POSIX. May be nil (no probe).

proc osHostnameFrom*(s: OsHostnameSources): string =
  ## The normalized OS hostname: the platform's variable (`%COMPUTERNAME%` on
  ## Windows, `$HOSTNAME` on POSIX), else the platform's probe, then
  ## `normalizeHostName`. "" when neither yields a name.
  var raw = if s.windows: s.computerName else: s.hostnameEnv
  if raw.strip().len == 0 and s.probe != nil:
    raw = s.probe()
  normalizeHostName(raw)

proc probeOsHostname(): string =
  ## The platform's hostname call, unnormalized; "" when it fails.
  when defined(windows):
    var size: int32 = 256
    var buf = newWideCString("", int(size))
    if getComputerNameW(buf, addr size) != 0:
      return $buf
    ""
  else:
    # gethostname(2), not the `hostname` command: the command needs a binary
    # on `PATH`, and the places that most need an identity have none -- a
    # systemd unit whose `path` holds only a compiler (the NixOS
    # `services.mcl-repro-deploy-agent` unit), a nix build sandbox, a
    # minimal container. `$HOSTNAME` is a bash variable that is normally
    # not exported, so without this every such run refused ("pass --host
    # NAME"). The command itself only prints gethostname(2), so the name is
    # the same wherever both work (reprobuild-pm issue
    # 2026-10-18-deploy-agent-invents-a-host-identity-instead-of-resolving-one).
    try:
      getHostname()
    except OSError:
      ""

proc currentOsHostnameSources*(): OsHostnameSources =
  ## The hostname sources of this process on this platform.
  OsHostnameSources(
    windows: defined(windows),
    computerName: getEnv("COMPUTERNAME"),
    hostnameEnv: getEnv("HOSTNAME"),
    probe: probeOsHostname)

proc systemHostname*(): string =
  ## OS hostname, normalized (`normalizeHostName`). On Windows uses
  ## `%COMPUTERNAME%` (or `GetComputerNameW` as a fallback); on POSIX uses
  ## `$HOSTNAME`, else gethostname(2).
  osHostnameFrom(currentOsHostnameSources())

proc currentHost*(): string =
  ## Resolve the current host identity per the documented precedence:
  ##
  ## 1. `$REPRO_HOST`
  ## 2. CLI `--host <name>` override (set via `setHostOverride`)
  ## 3. Lowercased system hostname
  let env = getEnv(HomeHostEnvVar)
  if env.len > 0:
    return env
  if cliHostOverride.len > 0:
    return cliHostOverride
  result = systemHostname()

# ---------------------------------------------------------------------------
# The one host resolver of the `repro home` commands.
# ---------------------------------------------------------------------------

type
  HostSource* = enum
    ## Where the resolved host identity came from, in the documented
    ## precedence (`$REPRO_HOST`, `--host`, the OS hostname).
    hsEnv = "env"
    hsFlag = "flag"
    hsHostname = "hostname"

  HostIdentity* = object
    name*: string
    source*: HostSource

  EHostIdentity* = object of CatchableError
    ## The host cannot be resolved as the caller asked: a `--host` that
    ## `$REPRO_HOST` would override, an empty `--host`, or no name at all.

proc machineHost*(): string =
  ## The identity this machine has WITHOUT any `--host`: `$REPRO_HOST`, else
  ## the lowercased OS hostname. `repro home enable/disable --host NAME`
  ## compare NAME with it to tell an edit for this machine from one for
  ## another host.
  let env = getEnv(HomeHostEnvVar)
  if env.len > 0: env else: systemHostname()

proc resolveHostFrom*(reproHostEnv, hostFlag: string; flagGiven: bool;
                      osHostname: proc (): string): HostIdentity =
  ## The host-identity rule itself, over injected inputs and with no side
  ## effect: `reproHostEnv` is `$REPRO_HOST` ("" when unset), `hostFlag` the
  ## command's `--host` value, `flagGiven` whether `--host` was passed at
  ## all, and `osHostname` the normalized OS hostname (consulted only when
  ## neither of the others names a host). `selectHost` feeds it the process'
  ## real inputs; tests feed it any platform's.
  ##
  ## Refusals (raise `EHostIdentity`):
  ## * `--host` given with an empty value;
  ## * `--host NAME` while `$REPRO_HOST` names ANOTHER host: `$REPRO_HOST`
  ##   takes precedence, and silently planning, applying or exporting for a
  ##   host the user did not name is worse than refusing;
  ## * no host at all (no `$REPRO_HOST`, no `--host`, no OS hostname).
  if flagGiven and hostFlag.len == 0:
    raise newException(EHostIdentity, "--host needs a non-empty name")
  if reproHostEnv.len > 0 and hostFlag.len > 0 and reproHostEnv != hostFlag:
    raise newException(EHostIdentity, "--host " & hostFlag &
      " conflicts with $" & HomeHostEnvVar & "=" & reproHostEnv &
      " (which takes precedence); unset one of them")
  if reproHostEnv.len > 0:
    result = HostIdentity(name: reproHostEnv, source: hsEnv)
  elif hostFlag.len > 0:
    result = HostIdentity(name: hostFlag, source: hsFlag)
  else:
    result = HostIdentity(name: osHostname(), source: hsHostname)
  if result.name.len == 0:
    raise newException(EHostIdentity,
      "could not determine the host name; pass --host NAME")

proc selectHost*(hostFlag: string; flagGiven = hostFlag.len > 0):
    HostIdentity =
  ## Resolve the host identity for one command and install it as the
  ## process-wide `--host` override, so everything the command calls
  ## afterwards (`currentHost()` in the planner, the apply pipeline, the
  ## export and facts producers) sees the same host. `hostFlag` is the
  ## command's `--host` value ("" when the flag was not given).
  ##
  ## This is the ONE host resolver: every `repro home` command, `repro infra
  ## plan` / `apply`, `repro system sync` / `rollback` and the host-registry
  ## gate in front of them call it, so one machine has one name in all of
  ## them (Home-Profile-Intent-Layer.md §Host Identity). The rule and its
  ## refusals are `resolveHostFrom`'s.
  result = resolveHostFrom(getEnv(HomeHostEnvVar), hostFlag, flagGiven,
    systemHostname)
  setHostOverride(hostFlag)
