## Built-in home-scope resource-type registrations.
##
## `Composable-Resource-Types.md` Migration step 1: one
## `ResourceTypeDef` per built-in `ResourceKind`, whose driver points
## at the per-kind digest/observe leaf procs extracted from the former
## `case` statements in `lifecycle.nim` / `plan.nim`. Importing
## `repro_home_resources` runs `registerBuiltinResourceTypes()` so the
## registry is populated before any planner call.
##
## `typeId = $kind` — the enum's stable string form (e.g.
## "fs.managedBlock"), the same tag serialized into the activation
## manifest's `ResourceBinding.resourceKind`.
##
## Determinism: every home-scope built-in is machine STATE (a registry
## value, a gsettings/dconf/KDE key, a managed block in a user file, an
## env var, a startup entry, a shell-integration block, a systemd/
## launchd unit, a VS Code extension set, a Homebrew formula/cask) —
## none is a bytewise-reproducible build artifact, so all are
## `rdHostBound`. Slice 1 only POPULATES the class; soft-rebuild
## consumption is a later slice.
##
## Import-cycle note: this module sits ABOVE `lifecycle` and `plan`
## (it imports both). `type_registry` sits BELOW them and imports
## neither, so there is no cycle: types -> type_registry ->
## lifecycle/plan -> builtin_registrations -> umbrella.

import ./types
import ./type_registry
import ./lifecycle
import ./plan

proc builtinResourceOwnership*(kind: ResourceKind): ResourceOwnership =
  ## What a first apply of `kind` may do over an existing, differing object
  ## no generation records (`ResourceOwnership`). Every kind is a whole
  ## object -- drift -- except the ones whose observation of "nothing of
  ## ours yet" is not anyone's object, which converge:
  ##
  ## * `env.userPath`, `vscode.extension`: contributions to a shared
  ##   collection (the user `Path` / the rc file's PATH block; the installed
  ##   extensions, observed as their intersection with the desired set).
  ## * `linux.gsettings`: `gsettings get` answers the schema default for a
  ##   key nobody set, so the observation cannot tell a default (nobody's)
  ##   from a value someone chose; as drift, every gsettings resource on a
  ##   fresh host would need `--reconcile-drift`. (`linux.dconfKey` and
  ##   `linux.kdeConfigKey` observe an unset key as absent, so they are whole
  ##   objects.)
  ## * `pkg.homebrewFormula` / `pkg.homebrewCask`: the installation is
  ##   Homebrew's and moving it to the declared version is what `brew` itself
  ##   does; no user content is replaced. As drift, every cask a Brewfile
  ##   installed would need `--reconcile-drift` when a host's `applications`
  ##   concern takes it over from Home Manager.
  case kind
  of rkEnvUserPath, rkVscodeExtension, rkLinuxGsettings, rkHomebrewFormula,
     rkHomebrewCask:
    roSetContribution
  of rkFsManagedBlock, rkWindowsRegistryValue, rkEnvUserVariable,
     rkWindowsStartup, rkShellIntegration, rkSystemdUserUnit,
     rkMacosUserDefault, rkLaunchdUserAgent, rkFsUserFile, rkLinuxDconfKey,
     rkLinuxKdeConfigKey, rkMacosAppBundle:
    roWholeObject

proc registerBuiltinResourceTypes*() =
  ## Register a `ResourceTypeDef` for every built-in `ResourceKind`.
  ## Idempotent: re-registering a `typeId` replaces the prior entry
  ## with an identical value.
  for kind in ResourceKind:
    var driver: ResourceDriver
    case kind
    of rkFsManagedBlock:
      driver = ResourceDriver(digest: digestFsManagedBlock,
        observe: observeFsManagedBlock)
    of rkWindowsRegistryValue:
      driver = ResourceDriver(digest: digestWindowsRegistryValue,
        observe: observeWindowsRegistryValue)
    of rkEnvUserVariable:
      driver = ResourceDriver(digest: digestEnvUserVariable,
        observe: observeEnvUserVariable)
    of rkEnvUserPath:
      driver = ResourceDriver(digest: digestEnvUserPath,
        observe: observeEnvUserPath)
    of rkWindowsStartup:
      driver = ResourceDriver(digest: digestWindowsStartup,
        observe: observeWindowsStartup)
    of rkShellIntegration:
      driver = ResourceDriver(digest: digestShellIntegration,
        observe: observeShellIntegration)
    of rkLinuxGsettings:
      driver = ResourceDriver(digest: digestLinuxGsettings,
        observe: observeLinuxGsettings)
    of rkSystemdUserUnit:
      driver = ResourceDriver(digest: digestSystemdUserUnit,
        observe: observeSystemdUserUnit)
    of rkMacosUserDefault:
      driver = ResourceDriver(digest: digestMacosUserDefault,
        observe: observeMacosUserDefault)
    of rkLaunchdUserAgent:
      driver = ResourceDriver(digest: digestLaunchdUserAgent,
        observe: observeLaunchdUserAgent)
    of rkFsUserFile:
      driver = ResourceDriver(digest: digestFsUserFile,
        observe: observeFsUserFileR)
    of rkVscodeExtension:
      driver = ResourceDriver(digest: digestVscodeExtension,
        observe: observeVscodeExtension)
    of rkLinuxDconfKey:
      driver = ResourceDriver(digest: digestLinuxDconfKey,
        observe: observeLinuxDconfKeyR)
    of rkLinuxKdeConfigKey:
      driver = ResourceDriver(digest: digestLinuxKdeConfigKey,
        observe: observeLinuxKdeConfigKeyR)
    of rkHomebrewFormula:
      driver = ResourceDriver(digest: digestHomebrewFormula,
        observe: observeHomebrewFormulaR)
    of rkHomebrewCask:
      driver = ResourceDriver(digest: digestHomebrewCask,
        observe: observeHomebrewCaskR)
    of rkMacosAppBundle:
      driver = ResourceDriver(digest: digestMacosAppBundle,
        observe: observeMacosAppBundle)
    registerResourceType(ResourceTypeDef(
      typeId: $kind,
      determinism: rdHostBound,
      ownership: builtinResourceOwnership(kind),
      driver: driver))
