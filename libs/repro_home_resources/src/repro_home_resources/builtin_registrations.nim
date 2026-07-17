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
    registerResourceType(ResourceTypeDef(
      typeId: $kind,
      determinism: rdHostBound,
      driver: driver))
