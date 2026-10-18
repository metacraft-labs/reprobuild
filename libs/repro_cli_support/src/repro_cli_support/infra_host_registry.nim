## The host registry `repro infra plan` / `apply` and `repro system sync`
## consult before acting on a host's system scope (GM10; reprobuild-pm spec
## Gradual-Nix-To-Reprobuild-Migration.md §Hosts, feature 2).
##
## The registry is the home profile's `hosts:` block: the single place a
## configuration lists its hosts. A host entry there can say its system is
## managed elsewhere (`system: managedElsewhere("<pointer>")`,
## `repro_profile/host_system`); a system-scope command refuses such a host,
## names the pointer and changes nothing.
##
## Which registry: the home profile `--home-profile-dir` names, else the
## `home.nim` beside the system profile (a configuration that keeps both
## profiles in one directory, as a dotfiles repository does). There is
## deliberately NO fallback to the user's default home profile directory: a
## system profile and a registry that do not belong to one configuration
## would let an unrelated home profile refuse -- or, worse, appear to vouch
## for -- a system apply, including the managing repository's own. With no
## registry the commands behave as before and say that no registry was read.
##
## The registry is read through the normal profile-compile edge
## (`compileProfileToRbpi`), the same compiled intent `repro home` plans
## from, so the attribute has one reader.
##
## The host it is asked about is the command's identity as the one host
## resolver gives it (`host_identity.selectHost`, called by `infra.nim`'s
## `resolveInfraHost`), the same name the plan and the generation record.

import std/[os, strutils]

import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_home_intent/host_identity as hostIdentityMod
from repro_core/source_root import publicCliImagePath

type
  HostRegistryVerdict* = object
    registryPath*: string
      ## The home profile read, or "" when none was found.
    host*: string
      ## The host the registry was asked about.
    management*: HostSystemManagement

  EHostRegistry* = object of CatchableError
    ## The registry exists but could not be read (its compile failed). The
    ## commands refuse rather than plan a host whose attribute is unknown.

proc resolveHostRegistryPath*(homeProfileDir, systemProfilePath: string):
    string =
  ## The home profile whose `hosts:` registry applies to the system profile
  ## at `systemProfilePath`: `<homeProfileDir>/home.nim` when
  ## `homeProfileDir` is given (it must exist), else the `home.nim` beside
  ## the system profile, else "".
  if homeProfileDir.len > 0:
    let p = homeProfileDir / hostIdentityMod.HomeProfileAnchor
    if not fileExists(p):
      raise newException(EHostRegistry, "--home-profile-dir " &
        homeProfileDir & " holds no " & hostIdentityMod.HomeProfileAnchor)
    return p
  let sibling = systemProfilePath.parentDir / hostIdentityMod.HomeProfileAnchor
  if systemProfilePath.parentDir.len > 0 and fileExists(sibling) and
      sibling.absolutePath != systemProfilePath.absolutePath:
    return sibling
  ""

proc readHostRegistry*(registryPath, host, stateDir: string):
    HostRegistryVerdict =
  ## Compile the home profile at `registryPath` and report `host`'s system
  ## management. `registryPath` "" reports an unread registry (managed
  ## here). Raises `EHostRegistry` when the profile does not compile.
  result.registryPath = registryPath
  result.host = host
  if registryPath.len == 0:
    return
  let opts = ProfileCompileOptions(
    stateDir: stateDir,
    publicCliPath: publicCliImagePath(),
    repoRoot: "",
    workDir: registryPath.parentDir,
    verbose: false,
    forceRebuild: false)
  var intent: ProfileIntent
  try:
    let artifact = compileProfileToRbpi(registryPath, opts)
    intent = decodeRbpi(artifact.rbpiBytes)
  except CatchableError as err:
    raise newException(EHostRegistry, "cannot read the host registry " &
      registryPath & ": " & err.msg.strip())
  result.management = systemManagementFor(intent, host)

proc managedElsewhereRefusal*(v: HostRegistryVerdict;
                              command: string): string =
  ## The refusal `command` prints for a host whose system is managed
  ## elsewhere, or "" when the registry lets it proceed. The first line
  ## names the host, the registry and the pointer, so a script can show it
  ## as is.
  if not v.management.managedElsewhere:
    return ""
  let by =
    if v.management.managedBy.len > 0: v.management.managedBy
    else: "something other than this configuration (the registry names " &
      "no manager)"
  command & ": refusing host " & v.host & ": its system is managed " &
    "elsewhere, by " & by & "\n" &
    "  host registry : " & v.registryPath & "\n" &
    "  Nothing was planned or changed. Apply this host's system from " &
    "where it is managed; to manage it here, remove `system: " &
    ManagedElsewhereKeyword & "` from its `hosts:` entry."

proc describeRegistry*(v: HostRegistryVerdict): string =
  ## One line for the plan / apply report.
  if v.registryPath.len == 0:
    "none (no home.nim beside the system profile; --home-profile-dir " &
      "names one)"
  elif not v.management.declared:
    v.registryPath & " (host " & v.host & " not declared; system " &
      "managed here)"
  else:
    v.registryPath & " (host " & v.host & ": system " &
      describeManagement(v.management) & ")"
