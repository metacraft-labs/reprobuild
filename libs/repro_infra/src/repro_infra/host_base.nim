## What a host's base system is, as `repro infra` observes it before acting
## on the host's system scope: ReproOS, NixOS, a distribution-managed Linux
## (Debian, Ubuntu, Arch, ...), or not Linux at all.
##
## ReproOS add-on mode (`system: addOn` in the host registry) is only
## meaningful on a distribution host, and a distribution host that the
## registry declares must say how its system is managed
## (`repro_cli_support/infra_host_registry.modeMismatchRefusal`). Both
## checks read the base from here.
##
## The observation is `os-release(5)`: `/etc/os-release`, else
## `/usr/lib/os-release`, parsed as data (never sourced). `ID` names the
## distribution and `ID_LIKE` its family (Raspberry Pi OS is `ID=raspbian`,
## `ID_LIKE=debian`). ReproOS writes `ID=reproos`; NixOS writes `ID=nixos`.
## https://www.freedesktop.org/software/systemd/man/latest/os-release.html

import std/[os, strutils, tables]

const
  OsReleaseOverrideEnvVar* = "REPRO_OS_RELEASE_PATH"
    ## Test seam, shared with the system drivers' distro probe
    ## (`repro_elevation/posix_system_driver.OsReleaseOverrideEnvVar`): when
    ## set, this file is read instead of the host's `os-release`, on any
    ## platform. It lets a gate observe a Debian or ReproOS base from
    ## whatever machine runs it. It is not a security boundary: whoever sets
    ## the environment of `repro infra` already chooses what it applies.
  OsReleasePaths* = ["/etc/os-release", "/usr/lib/os-release"]
    ## Where `os-release(5)` says to look, in order.
  DebianFamilyIds* = ["debian", "ubuntu", "raspbian"]
    ## The `ID` / `ID_LIKE` values of the Debian family, the bases the
    ## `add-on-debian` realisation covers.

type
  HostBaseKind* = enum
    hbkReproOS = "reproos"
      ## ReproOS: the system is Reprobuild's as a whole.
    hbkNixOS = "nixos"
      ## NixOS: the system is a NixOS configuration's.
    hbkDistribution = "distribution"
      ## Any other Linux with an `os-release`: a distribution owns the base.
    hbkNotLinux = "not-linux"
      ## macOS, Windows, ...: neither a distribution host nor ReproOS.
    hbkUnknown = "unknown"
      ## Linux without a readable `os-release`: the base cannot be told.

  HostBase* = object
    kind*: HostBaseKind
    id*: string
      ## `os-release` `ID`, lower-case; "" when not observed.
    idLike*: seq[string]
      ## `os-release` `ID_LIKE`, split on whitespace.
    versionId*: string
      ## `os-release` `VERSION_ID`, or "".
    source*: string
      ## The file read, or "" when none was.

proc unquoteOsReleaseValue(raw: string): string =
  ## An `os-release` value: shell-like, optionally in single or double
  ## quotes; inside double quotes `\` escapes `"`, `\`, `$` and `` ` ``.
  let v = raw.strip()
  if v.len >= 2 and v[0] == '\'' and v[^1] == '\'':
    return v[1 ..< v.len - 1]
  if v.len >= 2 and v[0] == '"' and v[^1] == '"':
    var i = 1
    while i < v.len - 1:
      if v[i] == '\\' and i + 1 < v.len - 1 and v[i + 1] in {'"', '\\', '$', '`'}:
        result.add v[i + 1]
        inc i, 2
      else:
        result.add v[i]
        inc i
    return
  v

proc parseOsRelease*(content: string): Table[string, string] =
  ## The `KEY=value` assignments of an `os-release` file. Comments, blank
  ## lines and lines that are not an assignment are skipped, as the format
  ## says a reader must.
  for line in content.splitLines():
    let t = line.strip()
    if t.len == 0 or t.startsWith("#"):
      continue
    let eq = t.find('=')
    if eq <= 0:
      continue
    let key = t[0 ..< eq]
    if not key.allCharsInSet({'A'..'Z', '0'..'9', '_'}):
      continue
    result[key] = unquoteOsReleaseValue(t[eq + 1 .. ^1])

proc classifyHostBase*(osRelease: Table[string, string]; source: string;
                       isLinux: bool): HostBase =
  ## Classify a parsed `os-release`. `isLinux` is whether the observing
  ## process runs on Linux; it decides the base when no file was read.
  result.source = source
  result.id = osRelease.getOrDefault("ID").toLowerAscii()
  for like in osRelease.getOrDefault("ID_LIKE").splitWhitespace():
    result.idLike.add like.toLowerAscii()
  result.versionId = osRelease.getOrDefault("VERSION_ID")
  if source.len == 0:
    result.kind = if isLinux: hbkUnknown else: hbkNotLinux
  elif result.id == "reproos":
    result.kind = hbkReproOS
  elif result.id == "nixos":
    result.kind = hbkNixOS
  elif result.id.len == 0:
    result.kind = hbkUnknown
  else:
    result.kind = hbkDistribution

proc isDebianFamily*(b: HostBase): bool =
  ## The base is Debian or a derivative (Ubuntu, Raspberry Pi OS, ...).
  if b.kind != hbkDistribution:
    return false
  if b.id in DebianFamilyIds:
    return true
  for like in b.idLike:
    if like in DebianFamilyIds:
      return true
  false

proc describeHostBase*(b: HostBase): string =
  ## One phrase for diagnostics: `debian 13 (/etc/os-release)`, `NixOS`, ...
  case b.kind
  of hbkNotLinux: "not Linux (no os-release)"
  of hbkUnknown:
    if b.source.len == 0: "Linux with no readable os-release"
    else: "Linux whose " & b.source & " names no ID"
  else:
    b.id & (if b.versionId.len > 0: " " & b.versionId else: "") &
      " (" & b.source & ")"

proc observeHostBase*(): HostBase =
  ## Observe the running host's base: the `REPRO_OS_RELEASE_PATH` file when
  ## set, else the first readable `os-release`. An unreadable override is
  ## reported as unknown rather than silently replaced by the real file, so
  ## a gate that points it somewhere wrong sees the mistake.
  let isLinux = defined(linux)
  let override = getEnv(OsReleaseOverrideEnvVar)
  var candidates: seq[string]
  if override.len > 0:
    candidates = @[override]
  elif defined(linux) or defined(macosx):
    for p in OsReleasePaths:
      candidates.add p
  for p in candidates:
    if fileExists(p):
      try:
        return classifyHostBase(parseOsRelease(readFile(p)), p,
          isLinux or override.len > 0)
      except IOError, OSError:
        discard
  classifyHostBase(initTable[string, string](), "",
    isLinux or override.len > 0)
