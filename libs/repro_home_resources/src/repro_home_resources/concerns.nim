## Which concern each planned operation and each generation record belongs
## to (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
## §Concern-scoped apply, "The concerns").
##
## This is the ONE classification. The apply pipeline uses it to decide what
## it executes on a host that applies only some concerns, rollback uses it to
## decide what it releases instead of removing, and `repro home export`
## publishes `concernOfResourceKind` as data so the Nix side never restates
## it (P1, P6). The resource-kind table is an exhaustive `case`: a kind added
## to `ResourceKind` without a concern does not compile, so no operation can
## belong to no concern (Core-Invariants.md §Unrecognised Input Is Rejected,
## Not Skipped).
##
## A package reference's concern is not here: it depends on the realization
## the planner selects (`repro_home_apply/pipeline.packageConcern`). What is
## here is how a RECORD of a package's synthesized resources is classified
## after the fact: the `home.package.<id>.*` namespace is reserved for
## resources synthesized from realized packages, and a package is an
## application in a generation exactly when that generation placed its
## bundle (`home.package.<id>.app`).

import std/[sets, strutils]

import repro_home_generations
import repro_profile/concerns

import ./types

export concerns

const
  SynthesizedPackageAddressPrefix* = "home.package."
    ## The address namespace of resources synthesized from realized
    ## packages: `home.package.<id>.bin` / `.env.<VAR>` (env bindings),
    ## `home.package.<id>.app` (a placed application bundle).
  AppBundleAddressSuffix* = ".app"

proc appBundleAddress*(packageId: string): string =
  ## The resource address of ``packageId``'s placed application bundle.
  SynthesizedPackageAddressPrefix & packageId & AppBundleAddressSuffix

proc packageIdOfAppBundleAddress*(address: string): string =
  ## The inverse of ``appBundleAddress``; "" for any other address. Rollback
  ## uses it to find the package whose store prefix holds the bundle to
  ## re-place.
  if address.startsWith(SynthesizedPackageAddressPrefix) and
      address.endsWith(AppBundleAddressSuffix) and
      address.len > SynthesizedPackageAddressPrefix.len +
        AppBundleAddressSuffix.len:
    address[SynthesizedPackageAddressPrefix.len ..< address.len -
      AppBundleAddressSuffix.len]
  else:
    ""

proc concernOfResourceKind*(kind: ResourceKind): HomeConcern =
  ## The concern of a resource DECLARED in a profile's `resources:` (or in a
  ## data file's `[[resource]]` rows). Synthesized package resources take
  ## their package's concern instead (`concernOfSynthesized`).
  case kind
  of rkFsUserFile: hcFiles
  of rkEnvUserVariable, rkEnvUserPath, rkShellIntegration, rkFsManagedBlock:
    hcEnvironment
  of rkSystemdUserUnit, rkLaunchdUserAgent, rkWindowsStartup: hcServices
  of rkMacosUserDefault, rkLinuxGsettings, rkLinuxDconfKey,
     rkLinuxKdeConfigKey, rkWindowsRegistryValue, rkVscodeExtension:
    hcSettings
  of rkHomebrewCask, rkHomebrewFormula, rkMacosAppBundle: hcApplications

proc parseResourceKind*(text: string; kind: var ResourceKind): bool =
  ## The `ResourceKind` whose string form is `text` (the form generation
  ## records and the intent carry).
  for k in ResourceKind:
    if $k == text:
      kind = k
      return true
  false

proc resourceKindConcerns*(): seq[(string, HomeConcern)] =
  ## Every resource kind with its concern, in `ResourceKind` order: the
  ## table `repro home export` publishes (`concerns.resourceKinds`).
  for k in ResourceKind:
    result.add(($k, concernOfResourceKind(k)))

const
  ConfigOverrideConcern* = hcFiles
    ## A `config:` override parameterizes package-generated files and
    ## nothing else, so it belongs to the concern of those files.
  GeneratedFileConcern* = hcFiles
    ## Stow links and package-generated files.
  ManagedBlockRecordConcern* = hcEnvironment
    ## The package managed blocks a generation records (`managedBlocks`).

proc isSynthesizedPackageAddress*(address: string): bool =
  address.startsWith(SynthesizedPackageAddressPrefix)

proc applicationPackagesOf*(manifest: ActivationManifest): HashSet[string] =
  ## The packages a generation placed as applications: those it recorded a
  ## `macos.appBundle` binding for at `home.package.<id>.app`.
  for rb in manifest.resourceBindings:
    if rb.resourceKind == $rkMacosAppBundle:
      let id = packageIdOfAppBundleAddress(rb.resourceAddress)
      if id.len > 0:
        result.incl id

proc concernOfSynthesized*(address: string;
                           applicationPackages: HashSet[string]):
    HomeConcern =
  ## The concern of a resource synthesized for a package
  ## (`home.package.<id>.*`): its package's. `applicationPackages` are the
  ## packages that are applications in the plan or generation the address
  ## comes from; every other package's resources are `packages`.
  for id in applicationPackages:
    if address.startsWith(SynthesizedPackageAddressPrefix & id & "."):
      return hcApplications
  hcPackages

proc concernOfBinding*(rb: ResourceBinding;
                       applicationPackages: HashSet[string]): HomeConcern =
  ## The concern of a recorded resource binding. `applicationPackages` is
  ## `applicationPackagesOf` the manifest the binding comes from. Raises
  ## `ValueError` for a kind this build does not know: a record it cannot
  ## classify is not one it may release or remove on a guess.
  var kind: ResourceKind
  if not parseResourceKind(rb.resourceKind, kind):
    raise newException(ValueError, "generation records resource " &
      rb.resourceAddress & " of kind `" & rb.resourceKind &
      "`, which this repro does not know")
  if kind == rkMacosAppBundle:
    return hcApplications
  if isSynthesizedPackageAddress(rb.resourceAddress):
    return concernOfSynthesized(rb.resourceAddress, applicationPackages)
  concernOfResourceKind(kind)

proc ownedConcernsOf*(manifest: ActivationManifest): ConcernSet =
  ## The concerns a generation applied: the recorded set (schema 3), or
  ## every concern for a generation written without one.
  if manifest.concernsDeclared:
    toConcernSet(manifest.ownedConcerns)
  else:
    AllHomeConcerns
