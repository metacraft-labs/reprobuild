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

import std/[algorithm, os, sets, strutils]

import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_home_intent/host_identity as hostIdentityMod
import repro_infra/host_base
import repro_infra/addon_diagnostics
from repro_cli_support/self_spawn_image import selfSpawnIoMonitorPath

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
    # Guarded like every internal-verb spawn: the compile wraps its actions
    # in `<publicCliPath> internal io monitor` (`self_spawn_image`).
    publicCliPath: selfSpawnIoMonitorPath(),
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

# ---------------------------------------------------------------------------
# ReproOS add-on mode: the registry's mode against the observed base, and
# the system-scope target the registry selects.
# ---------------------------------------------------------------------------

proc checkHostSystemMode*(v: HostRegistryVerdict; base: HostBase) =
  ## Refuse, with `EAddOnModeMismatch`, a host whose registry entry and
  ## observed base disagree (spec ReproOS-Add-On-Mode §8.1):
  ##
  ## * the registry says `addOn` and the base is not a distribution host
  ##   (ReproOS, NixOS, not Linux, or an unreadable `os-release`): add-on
  ##   mode manages objects on top of a distribution, and there is none;
  ## * the registry declares the host without a `system:` key and the base
  ##   is a distribution host: writing system objects on a distribution host
  ##   must be declared (`addOn` or `managedElsewhere`), never inferred.
  ##
  ## A host the registry does not declare (or no registry at all) keeps the
  ## behaviour it had before add-on mode existed; the report's `registry:`
  ## line names that case. A host managed elsewhere is refused before this
  ## check by `managedElsewhereRefusal`.
  if v.registryPath.len == 0 or not v.management.declared:
    return
  var mode = v.management.mode
  when defined(reproMutations):
    # Falsifying-mutation harness for `t_addon_mode_mismatch_is_refused`:
    # a planner that reads an undeclared mode on a distribution host as
    # `addOn`. Compiled in only with `-d:reproMutations`, armed by the
    # variable, so a production build cannot be put in this state.
    if mode == mmFull and base.kind == hbkDistribution and
        getEnv("REPRO_A6_MUTATE_UNDECLARED_MODE_AS_ADDON") == "1":
      mode = mmAddOn
  case mode
  of mmManagedElsewhere:
    discard
  of mmAddOn:
    if base.kind != hbkDistribution:
      raise newAddOnModeMismatch(v.host, $mmAddOn, describeHostBase(base),
        "host " & v.host & " is declared `system: " & AddOnKeyword &
        "` in the host registry " & v.registryPath & ", but it runs " &
        describeHostBase(base) & ", not a distribution-managed Linux. " &
        "Add-on mode manages declared objects on top of a distribution " &
        "(Debian, Ubuntu, ...); on ReproOS or NixOS the whole system is the " &
        "configuration's -- remove `system: " & AddOnKeyword & "` from its " &
        "`hosts:` entry. Nothing was planned or changed.")
  of mmFull:
    if base.kind == hbkDistribution:
      raise newAddOnModeMismatch(v.host, $mmFull, describeHostBase(base),
        "host " & v.host & " runs " & describeHostBase(base) & ", a " &
        "distribution-managed system, and the host registry " &
        v.registryPath & " declares it without saying how its system is " &
        "managed. Writing system objects on a distribution host must be " &
        "declared: add `system: " & AddOnKeyword & "` to its `hosts:` " &
        "entry to manage declared services, files and accounts on top of " &
        "the distribution, or `system: " & ManagedElsewhereKeyword &
        "(\"<what manages it>\")` if something else does. Nothing was " &
        "planned or changed.")

proc realisationFor*(v: HostRegistryVerdict; base: HostBase):
    SystemRealisation =
  ## How the selected resources are realised on the host: in full, unless
  ## the registry says `addOn`, which needs a realisation profile for the
  ## base. Only the Debian family has one (`add-on-debian`); another
  ## distribution is `EAddOnUnsupportedBase`. Call after
  ## `checkHostSystemMode`.
  var addOn = v.management.isAddOn
  when defined(reproMutations):
    # The same harness as `checkHostSystemMode`: the mutated planner also
    # realises the host as an add-on host, so its writes are planned.
    if not addOn and v.management.declared and
        base.kind == hbkDistribution and
        getEnv("REPRO_A6_MUTATE_UNDECLARED_MODE_AS_ADDON") == "1":
      addOn = true
  if not addOn:
    return srFull
  if base.isDebianFamily:
    return srAddOnDebian
  raise newAddOnUnsupportedBase(describeHostBase(base),
    "host " & v.host & " is declared `system: " & AddOnKeyword & "`, but " &
    "it runs " & describeHostBase(base) & ", for which no add-on " &
    "realisation profile exists (`" & AddOnDebianProfileName & "` covers " &
    "Debian, Ubuntu and their derivatives). Nothing was planned or changed.")

proc systemPlanTargetFor*(v: HostRegistryVerdict; base: HostBase):
    SystemPlanTarget =
  ## The system-scope target the registry selects for `v.host`: the
  ## `default` system activity plus what an add-on entry's block form
  ## lists (`enabledSystemActivities`), realised as `realisationFor` says.
  ## A host the registry does not declare, or no registry, plans `default`
  ## only, in full.
  systemPlanTarget(v.host, enabledSystemActivities(v.management),
    realisationFor(v, base))

proc describeSystemTarget*(t: SystemPlanTarget): string =
  ## One line for the plan / apply report: the system activities planned
  ## and how they are realised, e.g. `activities default, web; realised
  ## add-on-debian`.
  var others: seq[string]
  for a in t.activities:
    if a != DefaultSystemActivity:
      others.add a
  others.sort()
  "activities " & (@[DefaultSystemActivity] & others).join(", ") &
    "; realised " & $t.realisation
