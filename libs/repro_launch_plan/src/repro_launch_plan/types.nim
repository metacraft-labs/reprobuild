## Typed `LaunchPlan` domain type (M57 — Launch-Plans-And-Platform-Launchers.md).
##
## A `LaunchPlan` is the typed, serializable description of how to start one
## specific exported command from one specific realized prefix, with the
## exact runtime bindings needed. It is content-addressed: identical plans
## share the same `launchPlanId` and the same on-disk artifact in
## the M56 CAS (`<store-root>/cas/blake3/<aa>/<full-hash>`).
##
## The on-disk encoding lives in `./codec.nim`; this module owns only the
## record shape and the small helpers (kinds, sentinel constants) that
## downstream binding code needs.

type
  LaunchPlanBindingKind* = enum
    ## Set by the binding decision algorithm at realization time. Recorded
    ## on the plan so consumers (the home-profile activation layer, the
    ## `repro launch-plan show` inspector, and the verification gate) can
    ## see which strategy was selected for each `(platform, executable)`.
    lbkUndecided                ## binding decision has not run yet
    lbkLinuxRunpathExact        ## strategy 1: embedded RUNPATH at exact dep dirs
    lbkLinuxOriginRelative      ## strategy 2: $ORIGIN-relative RUNPATH
    lbkLinuxScript              ## strategy 3: POSIX launcher script
    lbkMacosRpathRewrite        ## strategy 1: @rpath + install-name rewriting
    lbkMacosLoaderPath          ## strategy 2: @loader_path inside a projection
    lbkMacosScript              ## strategy 3: bash launcher
    lbkWindowsLauncher          ## strategy 1: native PE launcher binary
    lbkWindowsAppLocal          ## strategy 2: app-local DLL layout
    lbkWindowsProjection        ## strategy 3: projected runtime image

  EnvBindingKind* = enum
    ## `environmentBindings.kind` values per spec.
    ebkSet
    ebkPrepend
    ebkAppend
    ebkUnset

  EnvBinding* = object
    name*: string
    kind*: EnvBindingKind
    value*: string

  ExecutableBinding* = object
    ## 0install-style binding: a launched plan references an auxiliary
    ## executable from a sibling realized package by its logical
    ## adapter-declared name.
    logicalName*: string
    executablePath*: string

  SupportProfile* = object
    platform*: string                ## "linux" | "macos" | "windows"
    arch*: string                    ## "x86_64" | "aarch64" | ...
    abi*: string                     ## "msvc" | "gnu" | "darwin" | ...
    osMinVersion*: string            ## free-form, e.g. "10.0.19041" or "11.0"

  ExecutionProfileChecksum* = object
    ## Optional execution-profile checksum carried by launch plans
    ## emitted from weak-adapter realizations (Scoop / brew / winget).
    ## The bytes are a BLAKE3-256 digest over the recorded execution
    ## identity; the `mode` field flags whether mismatch is fatal.
    present*: bool
    requires*: bool                  ## == requiresExecutionProfileChecksum
    checksumHex*: string             ## lowercase hex; empty when not present

  LaunchPlanProvenance* = object
    adapter*: string                 ## "nix" | "tarball" | "scoop" | ...
    packageId*: string               ## free-form package identity string
    realizationHashHex*: string      ## the prefix's M56 realization hash

  ProjectedRuntimeImage* = object
    ## Identity of an opt-in projected runtime image used by this plan.
    ## When absent (`present == false`) the plan does not depend on a
    ## projection.
    present*: bool
    imageId*: string                 ## content-hash hex of the projection
    relativePath*: string            ## under <store-root>/cas/.../projections/

  LaunchPlan* = object
    schemaVersion*: uint16
    realizedPrefix*: string          ## absolute or store-relative; the
                                     ## launcher resolves it against the
                                     ## sidecar's recorded prefix
    exportedCommand*: string         ## the user-visible command name
    executablePath*: string          ## absolute path inside realizedPrefix
    arguments*: seq[string]          ## static argv, prepended before passthrough
    hasWorkingDirectory*: bool
    workingDirectory*: string
    environmentBindings*: seq[EnvBinding]
    executableBindings*: seq[ExecutableBinding]
    runtimeLibraryDirs*: seq[string] ## the EXACT dirs the launcher must add
    projectedRuntimeImage*: ProjectedRuntimeImage
    executionProfile*: ExecutionProfileChecksum
    supportProfile*: SupportProfile
    provenance*: LaunchPlanProvenance
    binding*: LaunchPlanBindingKind

const
  LaunchPlanCurrentSchemaVersion* = 1'u16
  LaunchPlanEnvelopeMagic* = "RBLP"        ## Reprobuild Launch Plan
  LaunchSidecarEnvelopeMagic* = "RBLS"     ## Reprobuild Launch Sidecar
  LaunchPlanSidecarSuffix* = ".repro-launch"
  LaunchScriptMagicPosix* = "# repro-launch-script v1"
  ## Prefix every generated POSIX launcher script starts with so the
  ## activation layer can recognize a Reprobuild-managed launcher even
  ## when its content hash has rotated.

proc newEnvBinding*(name: string; kind: EnvBindingKind; value: string): EnvBinding =
  EnvBinding(name: name, kind: kind, value: value)

proc newSupportProfile*(platform, arch, abi, osMin: string): SupportProfile =
  SupportProfile(platform: platform, arch: arch, abi: abi,
    osMinVersion: osMin)

proc isWindowsLauncherBinding*(kind: LaunchPlanBindingKind): bool =
  kind == lbkWindowsLauncher

proc isPosixScriptBinding*(kind: LaunchPlanBindingKind): bool =
  kind in {lbkLinuxScript, lbkMacosScript}

proc isElfRunpathBinding*(kind: LaunchPlanBindingKind): bool =
  kind in {lbkLinuxRunpathExact, lbkLinuxOriginRelative}

proc isMachoRpathBinding*(kind: LaunchPlanBindingKind): bool =
  kind in {lbkMacosRpathRewrite, lbkMacosLoaderPath}
