## M72 Deliverable 1: production package catalog.
##
## `repro home apply` must realize packages WITHOUT the
## `REPRO_TEST_PACKAGE_*` seams set. This module resolves a
## `PlannedPackage` reference against the REAL adapter catalog of the
## host environment.
##
## On Windows the preferred production adapter is Scoop: a package is a
## Scoop package if it is installed (`scoop list`) OR available in a
## configured Scoop bucket (the bucket directory holds an `<app>.json`
## manifest). The M55 Scoop adapter
## (`repro_tool_profiles.resolveScoopTool`) performs the actual
## realization; this module only decides the binding and computes the
## cache-hit determination.
##
## On macOS/Linux the first production adapter is PATH: a package whose
## executable name is already discoverable on PATH is recorded through
## the universal path adapter. This prepares the non-Windows home apply
## path without pretending to have a full package-manager catalog yet.
##
## Cache-hit rule (per the M72 deliverable text): an app already
## installed at a version satisfying the profile is a cache-hit — it is
## recorded as realized, NOT reinstalled. The M55 adapter already reuses
## an existing `apps/<app>/<version>/` directory without re-running
## `scoop install`; this module classifies the outcome BEFORE dispatch
## by probing the Scoop install tree, so the apply pipeline can report
## `cache-hit` vs `realize` and the gate can assert no `scoop install`
## ran for an already-installed app.
##
## Resolution precedence (M72): an explicit `REPRO_TEST_PACKAGE_*`
## override is a TEST-ONLY seam and wins over this production catalog.
## The dispatcher in `realize.nim` consults the env seams first; this
## module is the fallback path for packages with no seam binding.
##
## Efficiency: `scoop list` is queried ONCE per apply (the installed-app
## table is built lazily and memoized inside `ProductionCatalog`), not
## once per package.

import std/[json, options, os, osproc, sets, strutils, tables]
from repro_core/paths import extendedPath

# M64: the cakBuiltin adapter resolves against the M63 VersionedProvisioning
# catalog. We import the schema (cross-platform; no Windows-only deps).
import repro_dsl_stdlib/packages_schema
# M65: the adapter chain consults the built-in catalog registry to
# look up `<tool>Catalog` literals for a given tool name. The registry
# is the single point of truth for "which tools have a built-in catalog
# entry"; the chain walks it via `getCatalog(toolName)`.
import repro_dsl_stdlib/catalog_registry

# M80: the plan classifier and the apply-time Scoop adapter
# (`repro_tool_profiles.resolveScoopTool`) share ONE installed-version
# cache-hit predicate — `installedVersionSatisfies` — so a
# `repro home apply --plan` dry run and the real `repro home apply`
# can never disagree on whether an installed-but-bucket-drifted package
# is a cache-hit.
when defined(windows):
  import repro_tool_profiles

const
  ScoopRootEnvVar = "SCOOP"
  ScoopOverrideEnvVar = "REPRO_TEST_SCOOP_OVERRIDE"
    ## Same test seam the M55 adapter / `realize.nim` honor: point at a
    ## sandboxed `scoop` executable. Non-exported here so it does not
    ## collide with `realize.nim`'s own `ScoopOverrideEnvVar*`.

type
  CatalogAdapterKind* = enum
    cakPath = "path"
    cakScoop = "scoop"
    cakBuiltin = "builtin"
      ## M64: a tool resolved against a checked-in
      ## ``<tool>Catalog: seq[VersionedProvisioning]`` literal under
      ## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/``.  The
      ## adapter downloads the slice URL, verifies the SHA, extracts
      ## per ``archive_format``, and materializes the bytes directly
      ## into a content-addressed prefix.  See M63's
      ## ``packages_schema.nim`` and the M64 ``builtin_adapter`` module
      ## for the realization flow.
    cakNix = "nix"
      ## M65: placeholder for the M21 Nix profile adapter. The M65
      ## adapter chain accepts ``cakNix`` in the preference list and
      ## skips it cleanly when the realize-side Nix adapter is not
      ## present (the parallel work in ``libs/repro_home_*`` will land
      ## the production Nix branch). Listing ``cakNix`` here keeps the
      ## chain configuration future-proof so a host can declare
      ## ``adapter_preference: [nix, builtin, path]`` today without a
      ## schema migration when the Nix branch lands.

  ChainStepOutcome* = enum
    ## M65: the per-step verdict the selection chain records in its
    ## trace. ``csoResolved`` is the terminating outcome; the other
    ## variants are skip reasons that drive the structured
    ## diagnostic when the entire chain is exhausted.
    csoResolved = "resolved"
    csoAdapterUnavailable = "adapter-unavailable"
      ## The adapter is platform-incompatible (cakScoop on Linux),
      ## missing a host binary (cakScoop without ``scoop`` on PATH), or
      ## not yet implemented (cakNix today). The chain moves on.
    csoCatalogMiss = "catalog-miss"
      ## cakBuiltin specific: the tool has no entry in the M65 catalog
      ## registry, or the registered catalog is empty.
    csoToolNotFound = "tool-not-found"
      ## cakPath / cakScoop specific: the executable is not discoverable
      ## on PATH and no bucket manifest carries it.
    csoSchemaError = "schema-error"
      ## cakBuiltin specific: ``resolveBuiltinPackage`` returned a
      ## structured error (platform-not-supported, schema-invalid,
      ## version-not-in-catalog). The chain moves on with the detail
      ## captured in the trace.

  ChainStep* = object
    ## M65: one step of the adapter selection chain. The full
    ## ``chainTrace`` is attached to ``CatalogResolution.chainTrace``
    ## (on a hit, the trace ends at the resolving step; on miss the
    ## chain reports ``EAdapterChainExhausted`` carrying every step).
    adapter*: CatalogAdapterKind
    outcome*: ChainStepOutcome
    reason*: string
    capabilityShortfall*: bool
      ## PMC-4 — this adapter had the package and REFUSED it because the host
      ## cannot execute what it offers (``breMicroarchFloorNotSatisfied``), as
      ## opposed to not having it at all.
      ##
      ## The distinction is the whole point. "I don't have it" is a reason to
      ## try the next adapter. "I have it and this machine cannot run it" is
      ## not: the next adapters include ``cakPath``, which probes PATH for a
      ## SAME-NAMED executable, and resolving to that looks like success while
      ## delivering a binary nobody declared. That is PMC-1's
      ## silent-fallthrough hazard in new clothing, and it is why this is a
      ## typed field rather than a substring of ``reason`` -- a diagnostic
      ## string is not a control-flow signal, and sniffing one would break the
      ## first time the wording changed.

  CatalogResolution* = object
    ## The production catalog's verdict for one package reference.
    packageId*: string
    adapter*: CatalogAdapterKind
    bucket*: string
    app*: string
    resolvedVersion*: string         ## the version the catalog resolved
    executableName*: string
    sourcePath*: string              ## path-adapter executable source
    installed*: bool                 ## already present in the Scoop tree
    cacheHit*: bool                  ## installed AND version-satisfying
    searchedCatalogs*: seq[string]   ## buckets / sources searched
    # M64 cakBuiltin fields — populated by `resolveBuiltinPackage`. They
    # carry the realization inputs forward so `realizeBuiltinPackage`
    # does not need to re-resolve the slice.
    builtinVersion*: string          ## VersionedProvisioning.version
    builtinCpuLevel*: MicroarchLevel
                                     ## PMC-2: the microarchitecture FLOOR of
                                     ## the arm that was selected, or
                                     ## ``mlNone`` when it declared none
                                     ## (every catalog entry today). Recorded
                                     ## because "which target did this
                                     ## resolve for" stops being a property
                                     ## of the host alone once selection
                                     ## depends on it.
                                     ##
                                     ## Deliberately NOT wired into any lock
                                     ## identity or cache key here — that is
                                     ## PMC-4's named deliverable and doing
                                     ## it early would change key material
                                     ## without the tests that make the
                                     ## change safe. This field is the datum
                                     ## PMC-4 will read.
    builtinCpuFeatures*: set[CpuFeature]
                                     ## PMC-3: the extra extensions the
                                     ## selected arm declared beyond its
                                     ## floor, or ``{}`` (every catalog entry
                                     ## today). Recorded for the same reason
                                     ## ``builtinCpuLevel`` is, and under the
                                     ## same restriction: NOT wired into any
                                     ## lock identity or cache key here — that
                                     ## is PMC-4's named deliverable.
                                     ##
                                     ## The arm's DECLARED set, not its
                                     ## expansion: what the author wrote is
                                     ## what a lock entry should record, and
                                     ## the expansion is recoverable from it
                                     ## via ``requiredFeatures``.
    resolvedTarget*: string
                                     ## PMC-4: ``builtinCpuLevel`` and
                                     ## ``builtinCpuFeatures`` rendered as
                                     ## ONE string by
                                     ## ``renderResolvedTarget`` — the exact
                                     ## value that goes into a lock entry
                                     ## (``LockedPackage.target``) and into a
                                     ## binary-cache key
                                     ## (``PlatformTriple.microarch``).
                                     ##
                                     ## A derived field rather than a fourth
                                     ## source of truth: it is a pure
                                     ## function of the two above, computed
                                     ## HERE so that the lock writer and the
                                     ## cache-key deriver cannot each invent
                                     ## their own spelling of the same
                                     ## resolution. Two spellings would
                                     ## separate entries that are in fact
                                     ## interchangeable, which is a silent
                                     ## cache miss — quieter than the SIGILL
                                     ## this milestone prevents, and just as
                                     ## hard to attribute.
                                     ##
                                     ## ``""`` for every catalog entry today,
                                     ## which is what makes the whole change
                                     ## byte-neutral for existing keys and
                                     ## identities.
    urlUsed*: string                 ## PlatformBinary.url chosen for host
    digestAlgorithm*: string         ## "sha256" | "sha512"
    digestValue*: string             ## hex digest (lowercase)
    archiveFormat*: ArchiveFormat
    installMethod*: InstallMethod
    binRelpath*: seq[string]
    extractPath*: string             ## inner-dir flatten
    installerArgs*: seq[string]
    pacmanPackages*: seq[string]
    bootstrapArgv*: seq[string]
    envSubstitutions*: seq[tuple[name, value: string]]
    # M3 (Realize-Closure-And-Catalog-Expansion) — residual 7z family
    # metadata. ``nested7z`` is per-platform (carried out of the
    # selected ``PlatformBinary``); ``preInstallActions`` and
    # ``preInstallUnrecognized`` are per-version (cross-platform).
    nested7z*: bool
    preInstallActions*: seq[PreInstallAction]
    preInstallUnrecognized*: seq[string]
    # M4 (Realize-Closure-And-Catalog-Expansion) — per-platform MSI
    # admin-install override. When true, the realize loop uses
    # ``msiexec /a`` instead of ``dark.exe`` for MSI extraction. The
    # global ``CAKBUILTIN_PREFER_MSIEXEC=1`` env var has the same
    # effect; this flag is the per-(cpu, os) override.
    msiAdminInstall*: bool
    # M5 (Realize-Closure-And-Catalog-Expansion) — Scoop-style launcher
    # emit. After extract / install_method dispatch, the realize loop
    # walks this sequence and synthesizes one .ps1 + one .cmd launcher
    # per spec at ``<prefix>/bin/<launcher_name>.{ps1,cmd}`` invoking
    # the discovered interpreter against the spec's prefix-relative
    # ``target``. Composer's .phar wrap is the M5 anchor case.
    launcherEmit*: seq[LauncherEmitSpec]
    # M65: per-resolution chain trace. Populated by `chainResolvePackage`
    # to record every adapter consulted, in order, with each adapter's
    # outcome + skip reason. On a successful resolution the trace ends
    # at the resolving step (the final entry has
    # `outcome == csoResolved`); on an exhaustion the trace carries
    # every step the chain walked before raising. Empty for the legacy
    # `resolvePackage(cat, packageId)` signature (which does not run
    # the chain — it preserves the pre-M65 single-adapter behaviour
    # for callers that have not yet been migrated).
    chainTrace*: seq[ChainStep]

  EUnknownPackage* = object of CatchableError
    ## Raised when a package reference resolves to no production
    ## adapter catalog. Carries the package name and the list of
    ## catalogs searched so the apply pipeline can surface a
    ## structured diagnostic.
    packageId*: string
    searchedCatalogs*: seq[string]

  EAdapterChainExhausted* = object of CatchableError
    ## M65: every adapter in the configured chain was tried and none
    ## resolved the package. The exception carries the package id, the
    ## chain that was walked, and the full chain trace (one
    ## ``ChainStep`` per adapter consulted) so the CLI layer can render
    ## a per-adapter skip-reason diagnostic. The ``--plan`` extension
    ## reads ``chainTrace`` directly to render its plan classifier.
    packageId*: string
    chain*: seq[CatalogAdapterKind]
    chainTrace*: seq[ChainStep]

  EPackageUnavailableOnPlatform* = object of CatchableError
    ## PMC-1 (Platform-And-Microarchitecture-Constraints): the package
    ## DECLARED, via a package-level ``platforms:`` block, that it cannot
    ## exist on this host.
    ##
    ## Distinct from ``EAdapterChainExhausted`` on purpose, and that is the
    ## whole milestone. Chain-exhausted means "no adapter could supply this
    ## package HERE, YET" and its remediation — catalogue it, put it on PATH,
    ## reorder ``adapter_preference:`` — is advice a reader can act on. For a
    ## Windows package manager on Linux every one of those is impossible, and
    ## the old message sent the reader to add a Linux arm for a tool that has
    ## no POSIX build. This error names the reason instead, and carries the
    ## author's own ``msg`` when the declaration supplied one.
    packageId*: string
    declaredPlatforms*: string
      ## Rendered form of the declaration, e.g. ``windows only``.
    hostTarget*: string
      ## Rendered form of the host, on the same axes, e.g. ``linux``.
    authorMessage*: string

  ProductionCatalog* = object
    ## Per-apply catalog handle. Built once; the installed-app table
    ## and the bucket inventory are memoized so a multi-package apply
    ## shells out to `scoop` at most once.
    scoopRoot: string
    scoopExe: string
    installedQueried: bool
    installedApps: Table[string, string]   ## app -> installed version
    buckets: seq[string]                   ## configured bucket names

proc raiseUnknownPackage*(packageId: string;
                          searched: seq[string]) {.noreturn.} =
  var e = newException(EUnknownPackage,
    "no production adapter catalog knows package '" & packageId &
    "'. Searched: " &
    (if searched.len > 0: searched.join(", ") else: "<no catalogs configured>") &
    ". Make the executable available on PATH, declare the package in a " &
    "configured platform catalog (Scoop on Windows), or set " &
    "REPRO_TEST_PACKAGE_SOURCE / REPRO_TEST_PACKAGE_SCOOP for a test-only " &
    "adapter binding.")
  e.packageId = packageId
  e.searchedCatalogs = searched
  raise e

# ---------------------------------------------------------------------------
# Host target detection
# ---------------------------------------------------------------------------
#
# Declared here rather than beside the M64 built-in resolver because BOTH
# resolution entry points (the legacy ``resolvePackage`` below and M65's
# ``chainResolvePackage``) take the host target as a DEFAULTED PARAMETER, and
# a default expression can only name something already declared. Keeping that
# seam is a hard requirement of the Platform-And-Microarchitecture-Constraints
# campaign: every platform test passes a SYNTHETIC host through these
# parameters, so the suite runs identically on any machine. Do not convert
# them into a global lookup.

proc detectHostCpu*(): PlatformCpu =
  ## Map the Nim `hostCPU` token to the schema's `PlatformCpu` enum.
  ## Unknown CPUs fall through to `pcAny` (the realize loop will then
  ## look for an arch-independent slice; if none exists,
  ## `selectPlatformBinary` reports `found=false`).
  when defined(amd64) or defined(x86_64):
    pcX86_64
  elif defined(arm64) or defined(aarch64):
    pcAArch64
  elif defined(i386) or defined(i686) or defined(x86):
    pcX86
  else:
    pcAny

proc detectHostOs*(): PlatformOs =
  when defined(windows):
    poWindows
  elif defined(linux):
    poLinux
  elif defined(macosx) or defined(osx):
    poMacos
  else:
    poAny

const HostMicroarchLevelEnvVar* = "REPRO_HOST_MICROARCH_LEVEL"
  ## PMC-2 deliverable 2, the override half: the microarchitecture level
  ## this host DECLARES it provides.
  ##
  ## An environment variable rather than a probe because the authority for
  ## "what may this machine be given" is the fleet, not the silicon. This
  ## org's CI already labels runners ``x86-64-v2`` / ``x86-64-v3``; that
  ## label is the thing an operator can reason about, audit and change,
  ## and it is what a shared binary cache must agree with. It also
  ## satisfies the milestone's requirement that a build be able to target
  ## a floor BELOW the builder — PMC-4 depends on being able to say "this
  ## build resolves as a v1 host" on a v3 machine, and a cpuid probe
  ## cannot be talked down.
  ##
  ## Accepts the same vocabulary as ``parseMicroarchLevelToken``
  ## (``x86-64-v3``, ``v3``, ``none``). An UNPARSEABLE value is refused
  ## loudly rather than ignored: silently falling back to the baseline
  ## would turn a typo in a runner label into a fleet that thinks it is
  ## v1 and quietly stops using every optimised artifact.

proc baselineMicroarchLevel*(family: PlatformCpu): MicroarchLevel =
  ## The level a CPU family provides BY DEFINITION, with no probing.
  ##
  ## ``x86_64`` is exactly ``x86-64-v1``: v1 is the psABI baseline every
  ## amd64 chip implements, so claiming it needs no detection. Anything
  ## above it does — v2/v3/v4 are feature-set questions and host FEATURE
  ## DETECTION is PMC-3's named deliverable, not this one's. Until then a
  ## host that can run more says so through
  ## ``REPRO_HOST_MICROARCH_LEVEL``.
  ##
  ## Defaulting low rather than high is the same decision Package-Model.md
  ## §"Two hazards specific to this project" reaches for the cache: Spack
  ## optimises for the build host and its binaries famously do not run
  ## elsewhere. A conservative floor costs peak performance and buys cache
  ## entries that are actually reusable across a fleet.
  case family
  of pcX86_64: mlX86_64_v1
  of pcAny, pcAArch64, pcX86: mlNone

const DefaultTargetFloorEnvVar* = "REPRO_DEFAULT_TARGET_FLOOR"
  ## PMC-4 deliverable 3, the central half: the floor an artifact is BUILT to
  ## target when its package does not say.
  ##
  ## Read this alongside ``HostMicroarchLevelEnvVar`` and note they are
  ## opposites, because conflating them is the whole hazard. That one declares
  ## what a host may be GIVEN (a ceiling, read on the consuming side). This one
  ## declares what an artifact is BUILT FOR (a floor, chosen on the producing
  ## side). Raising the ceiling lets a machine accept more; raising the floor
  ## makes what you produce run on fewer machines.

proc defaultTargetFloor*(): MicroarchLevel =
  ## PMC-4: the fleet-wide default floor. **Conservative, and deliberately so.**
  ##
  ## Spack optimises for the BUILD host by default, which is exactly why Spack
  ## binaries famously fail to run elsewhere: every artifact silently inherits
  ## the capabilities of whichever machine happened to build it, and the
  ## failure surfaces as a SIGILL on a different machine much later. A
  ## cache-oriented system wants the opposite trade — a floor low enough that
  ## one cached artifact serves the whole fleet, with higher levels taken
  ## EXPLICITLY by the packages that can justify losing that reuse.
  ##
  ## So the default is ``mlNone``: no floor, runs anywhere. It is not an
  ## absence of policy — it IS the policy, and the constant exists so that
  ## changing it is one obvious edit rather than an archaeology exercise
  ## across call sites.
  ##
  ## The per-package opt-in override is ``cpu_level`` on the arm itself
  ## (``effectiveTargetFloor`` below), which is where a package that genuinely
  ## needs AVX-512 says so and accepts the narrower audience.
  ##
  ## Same refusal discipline as the host override: an unreadable value is an
  ## error, never a silent default. A typo here would otherwise lower the
  ## fleet's floor without anyone noticing, and "we shipped v1 artifacts for a
  ## month" is discovered by benchmark, not by error.
  let raw = getEnv(DefaultTargetFloorEnvVar, "")
  if raw.len == 0:
    return mlNone
  let parsed = parseMicroarchLevelToken(raw)
  if not parsed.ok:
    raise newException(ValueError,
      DefaultTargetFloorEnvVar & "='" & raw & "' is not a microarchitecture " &
      "level. Expected one of x86-64-v1 / x86-64-v2 / x86-64-v3 / " &
      "x86-64-v4 (or the bare v1..v4, or 'none' for no floor). This " &
      "variable declares what artifacts are BUILT FOR; an unreadable value " &
      "is refused rather than defaulted, because defaulting it would " &
      "silently change which machines can run what this fleet produces.")
  parsed.level

proc effectiveTargetFloor*(declared: MicroarchLevel;
                           fleetDefault = mlNone): MicroarchLevel =
  ## Resolve a package's floor: its own declaration if it made one, else the
  ## fleet default.
  ##
  ## ``fleetDefault`` is a DEFAULTED PARAMETER rather than a call to
  ## ``defaultTargetFloor()`` in the body, for the same reason ``hostLevel``
  ## is: a test must be able to name a synthetic fleet policy without setting
  ## a process-wide environment variable, and a pure function of its arguments
  ## is the only shape that allows it.
  ##
  ## A package that declares ``mlNone`` explicitly is indistinguishable from
  ## one that declared nothing, and that is correct: ``mlNone`` means "no
  ## floor", so there is nothing for it to be overriding.
  if declared != mlNone: declared else: fleetDefault

proc detectHostMicroarchLevel*(family = detectHostCpu()): MicroarchLevel =
  ## PMC-2: what does this host provide?
  ##
  ## ``REPRO_HOST_MICROARCH_LEVEL`` when set, else the family baseline.
  ##
  ## Note the shape: this is a PROC WITH A DEFAULTED PARAMETER, called
  ## from the default-parameter expressions of the resolution entry
  ## points. It is never consulted when a caller supplies a level, so the
  ## env read cannot reach a test that passes a synthetic host — which is
  ## precisely the seam the campaign's testability note protects.
  let raw = getEnv(HostMicroarchLevelEnvVar, "")
  if raw.len == 0:
    return baselineMicroarchLevel(family)
  let parsed = parseMicroarchLevelToken(raw)
  if not parsed.ok:
    raise newException(ValueError,
      HostMicroarchLevelEnvVar & "='" & raw & "' is not a microarchitecture " &
      "level. Expected one of x86-64-v1 / x86-64-v2 / x86-64-v3 / " &
      "x86-64-v4 (or the bare v1..v4, or 'none' for an unstated host). " &
      "This variable declares what the host may be GIVEN; an unreadable " &
      "value is refused rather than defaulted, because defaulting it " &
      "would silently change which artifacts this machine accepts.")
  parsed.level

const HostCpuFeaturesEnvVar* = "REPRO_HOST_CPU_FEATURES"
  ## PMC-3 deliverable 1, the declaration half: the CPU extensions this host
  ## DECLARES it provides, on top of whatever ``REPRO_HOST_MICROARCH_LEVEL``
  ## says.
  ##
  ## Accepts a list in the psABI spellings, separated by ``,`` / ``+`` /
  ## whitespace (``avx512vl,avx512vnni``), or the single word ``auto`` to run
  ## the real ``cpuid`` probe. An UNPARSEABLE value is refused loudly rather
  ## than ignored — exactly the rule ``REPRO_HOST_MICROARCH_LEVEL`` follows,
  ## and for the sharper version of the same reason: a dropped feature would
  ## silently change which artifacts this machine accepts with no error
  ## anywhere pointing back at the typo.
  ##
  ## **Unset means "declared nothing", NOT "probe".** That is a policy
  ## decision, not an omission, and it is the same one PMC-2 made for the
  ## level: the authority for "what may this machine be given" is the fleet,
  ## not the silicon. A probe cannot be talked DOWN, and "target a floor below
  ## the builder" is a requirement PMC-4 depends on. So a machine that can
  ## demonstrably run more still declares nothing until an operator says
  ## otherwise, and the conservative floor survives PMC-3 intact.

when defined(amd64) and not defined(js) and not defined(nimscript):
  # PMC-3: the ``cpuid`` / ``xgetbv`` primitives, as two tiny C statics.
  #
  # Emitted into the INCLUDESECTION so they are defined before any Nim-
  # generated code that calls them. ``__get_cpuid_count`` (GCC/Clang) and
  # ``__cpuidex`` (MSVC) both bounds-check the leaf against CPUID's own
  # maximum, so an unsupported leaf answers zeroes rather than garbage.
  # XGETBV is spelled as its raw opcode bytes to avoid depending on the
  # assembler's ISA level.
  {.emit: """/*INCLUDESECTION*/
#if defined(_MSC_VER)
#  include <intrin.h>
static void repro_cpuidex(unsigned int leaf, unsigned int sub,
                          unsigned int *out) {
  int regs[4];
  __cpuidex(regs, (int)leaf, (int)sub);
  out[0] = (unsigned int)regs[0]; out[1] = (unsigned int)regs[1];
  out[2] = (unsigned int)regs[2]; out[3] = (unsigned int)regs[3];
}
static unsigned long long repro_xgetbv0(void) { return _xgetbv(0); }
#else
#  include <cpuid.h>
static void repro_cpuidex(unsigned int leaf, unsigned int sub,
                          unsigned int *out) {
  unsigned int a = 0, b = 0, c = 0, d = 0;
  if (!__get_cpuid_count(leaf, sub, &a, &b, &c, &d)) { a = b = c = d = 0; }
  out[0] = a; out[1] = b; out[2] = c; out[3] = d;
}
static unsigned long long repro_xgetbv0(void) {
  unsigned int eax = 0, edx = 0;
  __asm__ __volatile__(".byte 0x0f, 0x01, 0xd0"
                       : "=a"(eax), "=d"(edx) : "c"(0));
  return (((unsigned long long)edx) << 32) | (unsigned long long)eax;
}
#endif
""".}

  proc cpuidEx(leaf, sub: uint32; outRegs: ptr uint32)
    {.importc: "repro_cpuidex", nodecl.}
  proc xgetbv0(): uint64 {.importc: "repro_xgetbv0", nodecl.}

proc probeHostCpuFeatures*(): set[CpuFeature] =
  ## PMC-3 deliverable 1, the probe half: what this silicon ACTUALLY has,
  ## from ``cpuid``.
  ##
  ## Reached only through ``REPRO_HOST_CPU_FEATURES=auto`` (see above), and
  ## living here rather than in ``packages_schema`` because it is a host read
  ## and the schema stays pure on that axis — the campaign's testability note
  ## makes that a requirement, not a preference.
  ##
  ## Two gates, both of which exist because the CPUID bit alone is not the
  ## question a caller is asking:
  ##
  ##   * ``avx`` is reported only when the OS enabled the extended register
  ##     state for it (``OSXSAVE`` plus ``XCR0[2:1]``). AVX instructions fault
  ##     on a kernel that did not, so a probe that answered from the raw
  ##     feature bit would report a capability this machine does not have —
  ##     the exact wrong direction for this campaign;
  ##   * the AVX-512 family is gated behind ``avx`` and ``XCR0[7:5]`` for the
  ##     same reason.
  ##
  ## Answers ``{}`` on anything that is not amd64: a probe with no
  ## implementation must not report a partial one.
  when defined(amd64) and not defined(js) and not defined(nimscript):
    var regs: array[4, uint32]
    template bitOf(word: uint32; bit: int): bool =
      (word and (1'u32 shl uint32(bit))) != 0'u32
    cpuidEx(0'u32, 0'u32, addr regs[0])
    let maxLeaf = regs[0]
    if maxLeaf < 1'u32:
      return {}
    cpuidEx(1'u32, 0'u32, addr regs[0])
    let leaf1Ecx = regs[2]
    let leaf1Edx = regs[3]
    if bitOf(leaf1Edx, 15): result.incl(cfCmov)
    if bitOf(leaf1Edx, 8): result.incl(cfCx8)
    if bitOf(leaf1Edx, 0): result.incl(cfFpu)
    if bitOf(leaf1Edx, 23): result.incl(cfMmx)
    if bitOf(leaf1Edx, 24): result.incl(cfFxsr)
    if bitOf(leaf1Edx, 25): result.incl(cfSse)
    if bitOf(leaf1Edx, 26): result.incl(cfSse2)
    # OSFXSR is a CR4 bit, not a CPUID one — unreadable from user mode. Every
    # OS that runs SSE code sets it, and SSE is reported above, so deriving it
    # from FXSR+SSE is the honest reading rather than a guess: if the OS had
    # not enabled FXSAVE state, nothing compiled for amd64 would run at all.
    if cfFxsr in result and cfSse in result: result.incl(cfOsfxsr)
    if bitOf(leaf1Ecx, 0): result.incl(cfSse3)
    if bitOf(leaf1Ecx, 1): result.incl(cfPclmulqdq)
    if bitOf(leaf1Ecx, 9): result.incl(cfSsse3)
    if bitOf(leaf1Ecx, 13): result.incl(cfCx16)
    if bitOf(leaf1Ecx, 19): result.incl(cfSse4_1)
    if bitOf(leaf1Ecx, 20): result.incl(cfSse4_2)
    if bitOf(leaf1Ecx, 22): result.incl(cfMovbe)
    if bitOf(leaf1Ecx, 23): result.incl(cfPopcnt)
    if bitOf(leaf1Ecx, 25): result.incl(cfAes)
    if bitOf(leaf1Ecx, 29): result.incl(cfF16c)
    if bitOf(leaf1Ecx, 30): result.incl(cfRdrnd)
    let osxsave = bitOf(leaf1Ecx, 27)
    if osxsave: result.incl(cfOsxsave)
    # XGETBV faults with #UD unless OSXSAVE is set, so it is read only inside
    # this guard.
    var xcr0: uint64 = 0'u64
    if osxsave:
      xcr0 = xgetbv0()
    let ymmEnabled = osxsave and ((xcr0 and 0x6'u64) == 0x6'u64)
    let zmmEnabled = ymmEnabled and ((xcr0 and 0xe0'u64) == 0xe0'u64)
    if ymmEnabled and bitOf(leaf1Ecx, 28): result.incl(cfAvx)
    if cfAvx in result and bitOf(leaf1Ecx, 12): result.incl(cfFma)
    # Extended leaf: SYSCALL/SYSRET (the psABI's "sce"), LAHF/SAHF in long
    # mode, and LZCNT.
    cpuidEx(0x80000000'u32, 0'u32, addr regs[0])
    if regs[0] >= 0x80000001'u32:
      cpuidEx(0x80000001'u32, 0'u32, addr regs[0])
      if bitOf(regs[3], 11): result.incl(cfSce)
      if bitOf(regs[2], 0): result.incl(cfLahfSahf)
      if bitOf(regs[2], 5): result.incl(cfLzcnt)
    if maxLeaf >= 7'u32:
      cpuidEx(7'u32, 0'u32, addr regs[0])
      let ebx = regs[1]
      let ecx = regs[2]
      let edx = regs[3]
      if bitOf(ebx, 3): result.incl(cfBmi1)
      if bitOf(ebx, 8): result.incl(cfBmi2)
      if bitOf(ebx, 18): result.incl(cfRdseed)
      if bitOf(ebx, 19): result.incl(cfAdx)
      if bitOf(ebx, 29): result.incl(cfSha)
      if cfAvx in result and bitOf(ebx, 5): result.incl(cfAvx2)
      if cfAvx in result and bitOf(ecx, 8): result.incl(cfGfni)
      if cfAvx in result and bitOf(ecx, 9): result.incl(cfVaes)
      if cfAvx in result and bitOf(ecx, 10): result.incl(cfVpclmulqdq)
      if zmmEnabled and cfAvx in result and bitOf(ebx, 16):
        result.incl(cfAvx512f)
        if bitOf(ebx, 17): result.incl(cfAvx512dq)
        if bitOf(ebx, 21): result.incl(cfAvx512Ifma)
        if bitOf(ebx, 28): result.incl(cfAvx512cd)
        if bitOf(ebx, 30): result.incl(cfAvx512bw)
        if bitOf(ebx, 31): result.incl(cfAvx512vl)
        if bitOf(ecx, 1): result.incl(cfAvx512Vbmi)
        if bitOf(ecx, 6): result.incl(cfAvx512Vbmi2)
        if bitOf(ecx, 11): result.incl(cfAvx512Vnni)
        if bitOf(ecx, 12): result.incl(cfAvx512Bitalg)
        if bitOf(ecx, 14): result.incl(cfAvx512Vpopcntdq)
        if bitOf(edx, 8): result.incl(cfAvx512Vp2intersect)
        if bitOf(edx, 23): result.incl(cfAvx512Fp16)
        cpuidEx(7'u32, 1'u32, addr regs[0])
        if bitOf(regs[0], 5): result.incl(cfAvx512Bf16)
  else:
    result = {}

proc detectHostCpuFeatures*(family = detectHostCpu()): set[CpuFeature] =
  ## PMC-3: what CPU extensions does this host provide, beyond its level?
  ##
  ## ``REPRO_HOST_CPU_FEATURES`` when set (``auto`` routes to
  ## ``probeHostCpuFeatures``), else ``{}`` — a host that has declared
  ## nothing.
  ##
  ## Same shape as ``detectHostMicroarchLevel`` and for the same reason: a
  ## PROC WITH A DEFAULTED PARAMETER, called from the default-parameter
  ## expressions of the resolution entry points. It is never consulted when a
  ## caller supplies a feature set, so the env read cannot reach a test that
  ## names a synthetic host.
  ##
  ## Both refusals below are the ``REPRO_HOST_MICROARCH_LEVEL`` rule applied
  ## to a set: an unreadable TOKEN is refused, and so is a feature belonging
  ## to another family — the latter could never be satisfied and would present
  ## as an unexplained refusal far from the variable that caused it.
  let raw = getEnv(HostCpuFeaturesEnvVar, "")
  if raw.strip().len == 0:
    return {}
  if raw.strip().toLowerAscii() == "auto":
    # A probe request for a family that is not the compiled one answers {}
    # rather than handing this machine's x86 features to an aarch64
    # resolution — the same dependence on ``family`` that
    # ``detectHostMicroarchLevel`` has.
    if family != detectHostCpu():
      return {}
    return probeHostCpuFeatures()
  let parsed = parseCpuFeatureSet(raw)
  if not parsed.ok:
    raise newException(ValueError,
      HostCpuFeaturesEnvVar & "='" & raw & "' names an unknown CPU feature '" &
      parsed.badToken & "'. Expected psABI spellings (avx2, avx512vl, " &
      "avx512vnni, sha, ...) separated by ',' / '+' / whitespace, or the " &
      "single word 'auto' to probe this machine. This variable declares " &
      "what the host may be GIVEN; an unreadable value is refused rather " &
      "than defaulted, because dropping a feature would silently change " &
      "which artifacts this machine accepts.")
  for f in parsed.features:
    if cpuFeatureFamily(f) != family:
      raise newException(ValueError,
        HostCpuFeaturesEnvVar & "='" & raw & "' names '" & $f &
        "', which belongs to cpu family " & $cpuFeatureFamily(f) &
        ", but this resolution's host family is " & $family &
        ". A feature the host family cannot have is never satisfiable and " &
        "would present as an unexplained refusal far from this variable.")
  parsed.features

# ---------------------------------------------------------------------------
# PMC-4/PMC-6 — the BUILD machine and the HOST target are two different things
#
# Everything above answers questions about "the host", and until now that word
# carried two meanings that happen to coincide today. They stop coinciding the
# moment a cross build exists, and the failure is silent: artifacts built with
# instructions the target machine cannot execute, discovered as a SIGILL far
# from here.
#
# The vocabulary is Nix's, because the build engine already uses it
# (`repro_build_engine/platform.nim`: `buildPlatformTriple()` vs
# `resolvedTargetTriple()`, `dkNative` vs `dkBuild`/`dkRuntime`, with `"native"`
# as the BUILD == HOST sentinel). Adding a second, parallel vocabulary here is
# the mistake PMC-3 avoided when it made the psABI level sugar over feature
# sets rather than a rival source of truth.
#
#   BUILD machine  the machine running `repro` right now. A MEASURED FACT --
#                  cpuid says what it says. Tools that RUN during the build
#                  (`nativeBuildDeps:`, `dkNative`) must satisfy this one:
#                  a compiler that traps on this machine is useless no matter
#                  what it is producing.
#
#   HOST target    what the produced artifacts must RUN on. A DECISION, not a
#                  measurement. `buildDeps:` / `runtimeDeps:` (`dkBuild`,
#                  `dkRuntime`) and every published artifact must satisfy this
#                  one. It is what belongs in the lock identity and the cache
#                  key, because it is the thing that makes two artifacts
#                  genuinely different.
#
# Why the existing REPRO_HOST_* variables are already the right seam: they say
# what the RUN target provides, which is exactly the host axis. Setting them
# BELOW the build machine is a cross build in miniature -- "produce something
# that runs on less than this machine" -- and it is the shape a real cross
# build takes. That is why they had to refuse an unparseable value rather than
# defaulting: a silently-defaulted override is a cross build quietly resolving
# as native, which is precisely the failure this section exists to prevent.
#
# The asymmetry to keep hold of: the host target may be LOWER than the build
# machine (build conservative artifacts on a capable machine -- the normal,
# desirable case). It being HIGHER is not automatically wrong either
# (cross-compiling for a more capable machine), but it means native tools and
# produced artifacts no longer share a floor, so they must be resolved
# separately. Either way the two must never be silently substituted for one
# another, which is what a single "host" concept guarantees will eventually
# happen.
# ---------------------------------------------------------------------------

type
  TargetRole* = enum
    ## Which of the two targets a resolution is asking about.
    trBuildMachine = "build"
      ## The machine running the build. Satisfied by `nativeBuildDeps:`.
    trHostTarget = "host"
      ## What the produced artifacts must run on. Satisfied by `buildDeps:` /
      ## `runtimeDeps:`, and what the lock identity and cache key carry.

proc buildMachineTarget*(): PlatformTarget =
  ## What the machine running `repro` actually provides. A MEASUREMENT:
  ## `cpuid` / `xgetbv`, never an override.
  ##
  ## Deliberately not overridable. The REPRO_HOST_* variables describe the
  ## target you are building FOR; letting them also rewrite what this machine
  ## IS would make a cross build unable to resolve its own compiler -- you
  ## would be telling reprobuild that the machine executing gcc lacks
  ## instructions gcc's binary actually uses. When cross compilation lands,
  ## the build machine stays measured and only the host target moves.
  let family = detectHostCpu()
  initPlatformTarget(family, baselineMicroarchLevel(family),
    probeHostCpuFeatures())

proc hostTarget*(): PlatformTarget =
  ## What the produced artifacts must run on.
  ##
  ## Defaults to the build machine -- that is the `"native"` sentinel the build
  ## engine already uses, and it is why one "host" concept has worked so far.
  ## REPRO_HOST_MICROARCH_LEVEL / REPRO_HOST_CPU_FEATURES move it, and moving
  ## it is what makes a build cross rather than native.
  let family = detectHostCpu()
  initPlatformTarget(family, detectHostMicroarchLevel(family),
    detectHostCpuFeatures(family))

proc isCrossTargeted*(buildT, hostT: PlatformTarget): bool =
  ## True when the two targets have diverged, i.e. this is no longer a
  ## `"native"` build in the build engine's sense.
  ##
  ## Exposed because the interesting diagnostics and cache decisions hang off
  ## this being observable, rather than each caller re-deriving it from a
  ## comparison it might get subtly wrong.
  # An UNSTATED host feature set is not a disagreement.
  #
  # PMC-3 made features DECLARED rather than probed: `detectHostCpuFeatures`
  # answers `{}` unless `REPRO_HOST_CPU_FEATURES` says otherwise, while
  # `buildMachineTarget` genuinely measures the silicon. Comparing those two
  # raw values reported CROSS on an ordinary native machine with no
  # configuration at all -- the host had said nothing and the build machine
  # had said everything.
  #
  # So a divergence requires the host to have STATED something different.
  # Family and level always count (both always have a value); features count
  # only once the host has named some, which is exactly when a caller has
  # taken a position on what the target provides.
  buildT.family != hostT.family or
    buildT.level != hostT.level or
    (hostT.features != {} and hostT.features != buildT.features)

proc targetForRole*(role: TargetRole; buildT, hostT: PlatformTarget):
    PlatformTarget =
  ## Route a dependency to the target that must satisfy it.
  ##
  ## Pure and fully parameterised on purpose: a test names both targets and
  ## asks the routing question directly, with no machine involved. That is the
  ## same seam `hostCpu`/`hostOs`/`hostLevel`/`hostFeatures` keep on the
  ## resolution entry points, and it is what makes cross-compilation behaviour
  ## testable on hardware that can only ever be one of the two.
  case role
  of trBuildMachine: buildT
  of trHostTarget: hostT

proc detectHostTarget*(): PlatformTarget =
  ## The HOST target -- what produced artifacts must run on.
  ##
  ## Retained as the established name (the binary-cache compat check and the
  ## PMC-2/PMC-3 tests call it). `hostTarget()` is the same value under a name
  ## that says which of the two axes it is; prefer that in new code, and reach
  ## for `buildMachineTarget()` when you mean the machine doing the work.
  hostTarget()

proc raisePackageUnavailableOnPlatform*(packageId: string;
                                        availability: PackageAvailability;
                                        hostCpu: PlatformCpu;
                                        hostOs: PlatformOs) {.noreturn.} =
  ## PMC-1: the package declared where it can exist and this host is not in
  ## that set. The message NAMES the reason — "chocolatey is declared for
  ## windows only; this host is linux" — because the remediation for a
  ## declared unavailability is categorically different from the remediation
  ## for a missing catalog entry, and the reader cannot tell the two apart
  ## from a chain trace.
  ##
  ## The advice deliberately does NOT mention PATH. Putting a same-named
  ## binary on PATH is exactly the silent-wrong-thing this milestone closes:
  ## it would resolve to something nobody declared.
  let declared = availability.describeDeclaredPlatforms()
  let host = availability.describeHostTarget(hostCpu, hostOs)
  var text = packageId & " is declared for " & declared &
    "; this host is " & host & "."
  if availability.message.len > 0:
    text.add(" " & availability.message)
  text.add(" This is a declared platform constraint (`platforms:` on the " &
    "package), not a missing catalog entry: no adapter can supply it here. " &
    "Guard the dependency at the point of use (`when defined(windows):` " &
    "around the `uses:` entry) if it is genuinely optional, or widen the " &
    "package's `platforms:` if it really does exist on this platform.")
  var e = newException(EPackageUnavailableOnPlatform, text)
  e.packageId = packageId
  e.declaredPlatforms = declared
  e.hostTarget = host
  e.authorMessage = availability.message
  raise e

# ---------------------------------------------------------------------------
# M0 (Realize-Layer-Plumbing-Closures spec) — extractor-discovery edges
# ---------------------------------------------------------------------------
#
# The realize loop's cakBuiltin adapter needs a small set of helper
# executables (``7z.exe``, ``lessmsi.exe``, ``dark.exe``, ``innounp.exe``)
# depending on the package's ``archive_format`` + ``install_method``.
# When the operator bundles those extractors as catalog packages in the
# SAME ``home.nim`` (the M3 bundling-posture decision from the
# Realize-Closure-And-Catalog-Expansion predecessor campaign), the
# realize-op order MUST honour these discovery edges — the consumer
# cannot realize until its extractor's prefix exists.
#
# The mapping below is the M0 hard-coded form. A future milestone could
# lift it to schema-driven catalog metadata (a ``requires_for_realize:``
# field on ``VersionedProvisioning``); for M0 the small constant table is
# the right tradeoff.
#
# Extractor-provider map (M0):
#
#   7z.exe       ← 7zip       (consumed by afSevenZip / afSevenZipSfx
#                              archive formats and the imInstallerNsis
#                              install method)
#   lessmsi.exe  ← lessmsi    (consumed by imInstallerMsi)
#   dark.exe     ← wix3       (consumed by imInstallerNsisBundle;
#                              dark unwraps the Burn outer)
#   lessmsi.exe  ← lessmsi    (also consumed by imInstallerNsisBundle;
#                              extracts the inner MSIs after dark)
#   innounp.exe  ← innounp    (consumed by imInstallerInnoSetup)

# TODO: schema-driven `requires_for_realize:` field on
# `VersionedProvisioning` would replace this hard-coded map. Migration
# starting point: move these consts into the per-tool catalog slice
# (each affected `packages/<tool>.nim` declares its own
# `requires_for_realize: @["7zip"]` or similar in the
# `VersionedProvisioning` literal); then have `extractorDependencies`
# below read `resolution.requiresForRealize` directly instead of
# pattern-matching on `archive_format` / `install_method`. The case
# statements in the proc body would collapse to a one-line passthrough.
# See Realize-Layer-Plumbing-Closures.milestones.org M0 Outstanding
# Tasks for the planned schema shape.
const
  ExtractorProvider7zip*    = "7zip"
  ExtractorProviderLessmsi* = "lessmsi"
  ExtractorProviderWix3*    = "wix3"
  ExtractorProviderInnounp* = "innounp"

proc extractorDependencies*(packageId: string;
                            resolution: CatalogResolution): seq[string] =
  ## Return the set of catalog-package names that must be realized BEFORE
  ## ``packageId`` can be realized, derived from the resolution's
  ## ``archive_format`` + ``install_method`` requirements.
  ##
  ## Hard-coded extractor-provider map (M0). Future enhancement:
  ## schema-driven ``requires_for_realize:`` field in
  ## ``VersionedProvisioning``.
  ##
  ## Returns an EMPTY seq when ``resolution.adapter`` is NOT ``cakBuiltin``
  ## (Scoop / PATH / Nix adapters handle their own extraction — the
  ## discovery edge does not apply). This matches the M0 spec's
  ## Outstanding Task note: "topo edges that originate from a
  ## cakScoop-resolved consumer are silently dropped".
  ##
  ## The returned seq never contains ``packageId`` itself (self-edges are
  ## skipped) — even though e.g. ``sevenzip.nim`` itself uses
  ## ``imInstallerMsi`` which needs ``lessmsi``, that's a real edge
  ## (sevenzip → lessmsi); the self-edge filter is for the degenerate
  ## case where the mapping ever points a package at itself.
  if resolution.adapter != cakBuiltin:
    return @[]
  var deps: seq[string] = @[]
  # archive_format-driven edges
  case resolution.archiveFormat
  of afSevenZip, afSevenZipSfx:
    deps.add(ExtractorProvider7zip)
  else:
    discard
  # install_method-driven edges (these override / extend the
  # archive_format edges for the installer families)
  case resolution.installMethod
  of imInstallerNsis:
    deps.add(ExtractorProvider7zip)
  of imInstallerMsi:
    deps.add(ExtractorProviderLessmsi)
  of imInstallerNsisBundle:
    # dark.exe to unwrap the Burn outer, lessmsi.exe to extract the
    # inner MSIs. Order in the seq is stable so a downstream consumer
    # that uses the order for tie-breaking gets a deterministic result.
    deps.add(ExtractorProviderWix3)
    deps.add(ExtractorProviderLessmsi)
  of imInstallerInnoSetup:
    deps.add(ExtractorProviderInnounp)
  else:
    discard
  # Deduplicate while preserving first-seen order, and drop any
  # self-edge (a package never depends on itself).
  var seen = initHashSet[string]()
  for d in deps:
    if d == packageId: continue
    if d in seen: continue
    seen.incl d
    result.add d

# ---------------------------------------------------------------------------
# Scoop environment discovery
# ---------------------------------------------------------------------------

proc resolveScoopExecutable(): string =
  let override = getEnv(ScoopOverrideEnvVar)
  if override.len > 0 and fileExists(extendedPath(override)):
    return override
  let envBinary = getEnv("REPROBUILD_SCOOP_BINARY")
  if envBinary.len > 0 and fileExists(extendedPath(envBinary)):
    return envBinary
  for candidate in ["scoop.cmd", "scoop.exe", "scoop.ps1", "scoop"]:
    let resolved = findExe(candidate)
    if resolved.len > 0:
      return resolved
  ""

proc resolveScoopRoot(): string =
  let explicit = getEnv(ScoopRootEnvVar)
  if explicit.len > 0:
    return explicit
  let home = getEnv("USERPROFILE", getEnv("HOME"))
  if home.len > 0:
    return home / "scoop"
  ""

proc openProductionCatalog*(): ProductionCatalog =
  ## Build a fresh per-apply catalog handle. Cheap: it only records the
  ## Scoop root + executable paths; the installed-app table and bucket
  ## inventory are filled lazily on first query.
  result.scoopRoot = resolveScoopRoot()
  result.scoopExe = resolveScoopExecutable()
  result.installedQueried = false
  result.installedApps = initTable[string, string]()

# ---------------------------------------------------------------------------
# `scoop list` — installed-app inventory
# ---------------------------------------------------------------------------

proc parseScoopListJson(raw: string; outTable: var Table[string, string]):
    bool =
  ## `scoop list` on a modern Scoop emits a JSON array of objects with
  ## `Name` + `Version` (and `Source`) keys when stdout is not a TTY.
  ## Returns true if the JSON shape was recognized.
  var node: JsonNode
  try:
    node = parseJson(raw)
  except CatchableError:
    return false
  if node.kind != JArray:
    return false
  for item in node:
    if item.kind != JObject:
      continue
    let name = item{"Name"}.getStr("")
    let version = item{"Version"}.getStr("")
    if name.len > 0:
      outTable[name.toLowerAscii()] = version
  true

proc readInstalledFromTree(scoopRoot: string;
                           outTable: var Table[string, string]) =
  ## Fallback inventory: walk `<scoop-root>/apps/<app>/<version>/` —
  ## the same on-disk shape `scoop install` produces. The `current`
  ## junction is skipped; the exact-version directory is the install
  ## marker. This is the robust path the M55 sandbox fixtures rely on
  ## (`populateScoopApp` lays down `apps/<app>/<version>` directly).
  let appsDir = scoopRoot / "apps"
  if not dirExists(extendedPath(appsDir)):
    return
  for kind, appPath in walkDir(extendedPath(appsDir)):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let app = extractFilename(appPath)
    for vk, vPath in walkDir(extendedPath(appPath)):
      if vk notin {pcDir, pcLinkToDir}:
        continue
      let ver = extractFilename(vPath)
      if ver != "current":
        outTable[app.toLowerAscii()] = ver

proc ensureInstalledQueried(cat: var ProductionCatalog) =
  ## Populate `installedApps` exactly once per apply. Prefers
  ## `scoop list` (the spec-named query) and falls back to walking the
  ## install tree when `scoop list` is unavailable or its output cannot
  ## be parsed. Either way the shell-out happens at most once.
  if cat.installedQueried:
    return
  cat.installedQueried = true
  var parsed = false
  if cat.scoopExe.len > 0:
    var command =
      if cat.scoopExe.endsWith(".ps1"):
        "powershell -NoProfile -ExecutionPolicy Bypass -File " &
          quoteShell(cat.scoopExe) & " list"
      else:
        quoteShell(cat.scoopExe) & " list"
    if cat.scoopRoot.len > 0:
      putEnv(ScoopRootEnvVar, cat.scoopRoot)
    try:
      let res = execCmdEx(command)
      if res.exitCode == 0:
        parsed = parseScoopListJson(res.output, cat.installedApps)
    except CatchableError:
      parsed = false
  # Always reconcile against the on-disk tree: `scoop list` JSON output
  # is version-dependent, and the M55 sandbox fixtures populate the
  # tree directly without a `scoop` metadata write. The tree walk is a
  # single directory enumeration — still O(1) shell-outs per apply.
  readInstalledFromTree(cat.scoopRoot, cat.installedApps)
  discard parsed

proc installedVersion*(cat: var ProductionCatalog; app: string):
    tuple[installed: bool; version: string] =
  ## Return whether `app` is installed and at which version. Triggers
  ## the one-time `scoop list` query on first call.
  ensureInstalledQueried(cat)
  let key = app.toLowerAscii()
  if key in cat.installedApps:
    (true, cat.installedApps[key])
  else:
    (false, "")

# ---------------------------------------------------------------------------
# Bucket inventory — "available in a configured bucket"
# ---------------------------------------------------------------------------

proc ensureBucketsQueried(cat: var ProductionCatalog) =
  if cat.buckets.len > 0:
    return
  let bucketsDir = cat.scoopRoot / "buckets"
  if not dirExists(extendedPath(bucketsDir)):
    return
  for kind, path in walkDir(extendedPath(bucketsDir)):
    if kind in {pcDir, pcLinkToDir}:
      cat.buckets.add(extractFilename(path))

proc bucketManifestPath(scoopRoot, bucket, app: string): string =
  scoopRoot / "buckets" / bucket / "bucket" / (app & ".json")

proc manifestBinName(node: JsonNode): string =
  ## Extract the executable leaf name from a Scoop manifest's `bin`
  ## field. `bin` may be a string, an array, or an array of pairs;
  ## the M55 adapter resolves the executable by its declared path, so
  ## the catalog reports the FIRST entry's leaf name.
  if node.isNil:
    return ""
  let binNode = node{"bin"}
  if binNode.isNil:
    return ""
  case binNode.kind
  of JString:
    extractFilename(binNode.getStr(""))
  of JArray:
    if binNode.len == 0:
      ""
    elif binNode[0].kind == JString:
      extractFilename(binNode[0].getStr(""))
    elif binNode[0].kind == JArray and binNode[0].len > 0 and
         binNode[0][0].kind == JString:
      extractFilename(binNode[0][0].getStr(""))
    else:
      ""
  else:
    ""

proc findBucketManifest*(cat: var ProductionCatalog; app: string):
    tuple[found: bool; bucket, version, binName: string] =
  ## Search every configured Scoop bucket for an `<app>.json` manifest.
  ## Returns the first bucket that carries one plus the manifest's
  ## declared `version` and `bin` (executable leaf name). This is the
  ## "available in a configured bucket" branch of the M72 deliverable.
  ensureBucketsQueried(cat)
  for bucket in cat.buckets:
    let mp = bucketManifestPath(cat.scoopRoot, bucket, app)
    if fileExists(extendedPath(mp)):
      var version = ""
      var binName = ""
      try:
        let parsed = parseJson(readFile(extendedPath(mp)))
        if parsed.kind == JObject:
          version = parsed{"version"}.getStr("")
          binName = manifestBinName(parsed)
      except CatchableError:
        version = ""
      return (true, bucket, version, binName)
  (false, "", "", "")

proc installedExecutableName(scoopRoot, app, version: string): string =
  ## Read the executable leaf name an installed app declares. Scoop
  ## copies the bucket manifest into `apps/<app>/<version>/
  ## manifest.json`; the M55 sandbox fixture writes that too.
  let mp = scoopRoot / "apps" / app / version / "manifest.json"
  if not fileExists(extendedPath(mp)):
    return ""
  try:
    let parsed = parseJson(readFile(extendedPath(mp)))
    if parsed.kind == JObject:
      return manifestBinName(parsed)
  except CatchableError:
    discard
  ""

# ---------------------------------------------------------------------------
# Resolution entry point
# ---------------------------------------------------------------------------

proc satisfiesProfile(installedVersion, pinnedVersion,
                      preferredVersion: string): bool =
  ## M80: a cache-hit requires an already-installed version that
  ## satisfies the package's version reference — and the bucket head
  ## is NEVER consulted here. This delegates to the SAME
  ## `installedVersionSatisfies` predicate that M77's apply-time
  ## `resolveScoopTool` uses, so the `--plan` classifier and the real
  ## apply cannot diverge.
  ##
  ## A `home.nim` package reference is always a bare/unpinned reference
  ## (`PlannedPackage` carries only a `packageId`, no version), so
  ## `pinnedVersion` and `preferredVersion` are both empty here and ANY
  ## installed version satisfies it — exactly what `resolveScoopTool`
  ## does (it cache-hits the installed version and runs no
  ## `scoop install`, leaving the drifted bucket head irrelevant). The
  ## pinned / ranged parameters are threaded through so a future
  ## version-pinned package reference resolves identically on both
  ## paths.
  if installedVersion.len == 0:
    return false
  when defined(windows):
    installedVersionSatisfies([installedVersion], pinnedVersion,
      preferredVersion).satisfied
  else:
    # Non-Windows path adapter has no version reference; an installed
    # executable is a cache-hit.
    pinnedVersion.len == 0 and preferredVersion.len == 0

proc resolvePathPackage(packageId: string; searched: var seq[string];
                        binaries: seq[string] = @[]):
    tuple[found: bool; resolution: CatalogResolution] =
  ## 2026-06-09 (binaries metadata): when `binaries` is non-empty,
  ## probe EACH binary name on PATH and report a hit on the first one
  ## that exists. Empty `binaries` preserves the pre-2026-06 behavior:
  ## probe the package name itself.
  searched.add("path:" & getEnv("PATH"))
  let probeNames =
    if binaries.len > 0: binaries
    else: @[packageId]
  var firstFound = ""
  for name in probeNames:
    let exe = findExe(name)
    if exe.len > 0:
      firstFound = exe
      break
  if firstFound.len == 0:
    return (false, CatalogResolution())
  var r = CatalogResolution(
    packageId: packageId,
    adapter: cakPath,
    app: packageId,
    executableName: extractFilename(firstFound),
    sourcePath: firstFound,
    installed: true,
    cacheHit: true,
    searchedCatalogs: searched)
  (true, r)

proc resolvePackage*(cat: var ProductionCatalog; packageId: string;
                     binaries: seq[string] = @[];
                     hostCpu = detectHostCpu();
                     hostOs = detectHostOs();
                     availability = none(PackageAvailability)):
    CatalogResolution =
  ## Resolve one `PlannedPackage` reference against the production
  ## catalog. Raises `EUnknownPackage` (naming the package and the
  ## catalogs searched) when no adapter recognizes it.
  ##
  ## Resolution order on Windows:
  ##   1. installed Scoop app (`scoop list`) — cache-hit candidate.
  ##   2. available in a configured Scoop bucket — realize via Scoop.
  ##
  ## PMC-1: raises ``EPackageUnavailableOnPlatform`` first when the package
  ## declared a ``platforms:`` set this host is not in. This entry point
  ## needs the gate as much as ``chainResolvePackage`` does — arguably more.
  ## It is the LEGACY path the realize dispatcher takes for a package with no
  ## built-in catalog registration (``useChain`` is false in
  ## ``realizeViaProductionCatalog``), which is exactly the shape a
  ## DSL-``tarball`` package like ``chocolatey`` has; and both of its exits
  ## end at ``resolvePathPackage``. Gating only the chain would have left the
  ## fallthrough-to-PATH hole open on the path that a declared-unavailable
  ## package actually takes.
  ##
  ## PMC-2 deliberately did NOT give this entry point a ``hostLevel``
  ## parameter. It resolves through Scoop and PATH only — neither consults a
  ## ``PlatformBinary``, so there is no microarchitecture floor to compare
  ## against, and a parameter here would be decoration a reader would
  ## reasonably expect to do something. ``chainResolvePackage`` and
  ## ``resolveBuiltinPackage``, which DO select arms, carry it.
  let declaredAvailability =
    if availability.isSome: availability.get
    else: packageAvailability(packageId)
  if not declaredAvailability.isAvailableOn(hostCpu, hostOs):
    raisePackageUnavailableOnPlatform(packageId, declaredAvailability,
      hostCpu, hostOs)
  result.packageId = packageId
  result.adapter = cakPath
  result.app = packageId
  result.executableName = packageId
  var searched: seq[string]

  when defined(windows):
    searched.add("scoop:installed-apps")
    let inst = installedVersion(cat, packageId)
    # Find the bucket manifest too: it tells us the bucket name (the
    # M55 adapter needs `bucket/app`), the available version, and the
    # declared executable leaf name.
    let manifest = findBucketManifest(cat, packageId)
    if manifest.found:
      result.adapter = cakScoop
      searched.add("scoop:bucket:" & manifest.bucket)
      result.bucket = manifest.bucket
      if manifest.binName.len > 0:
        result.executableName = manifest.binName
    if inst.installed:
      result.adapter = cakScoop
      result.installed = true
      # M80: an already-installed package is a cache-hit independent of
      # whether the Scoop bucket head has drifted ahead of it. A
      # `home.nim` package reference is a bare/unpinned reference, so
      # ANY installed version satisfies it — and `satisfiesProfile`
      # delegates to the SAME `installedVersionSatisfies` predicate
      # that M77's apply-time `resolveScoopTool` consults. The previous
      # M72 code required the installed version to EQUAL the bucket
      # head (`manifest.version`); that made `--plan` report an
      # installed-but-bucket-drifted package as `realize` while the
      # actual apply correctly cache-hit it. The bucket head is NOT
      # consulted here — exactly as `resolveScoopTool` does not consult
      # it for an installed app.
      result.resolvedVersion = inst.version
      result.cacheHit = satisfiesProfile(inst.version,
        pinnedVersion = "", preferredVersion = "")
      # Prefer the executable name the installed app's own manifest
      # declares (Scoop copies the bucket manifest into the version
      # dir on install; the M55 sandbox fixture writes it too).
      let installedExe = installedExecutableName(cat.scoopRoot, packageId,
        inst.version)
      if installedExe.len > 0:
        result.executableName = installedExe
      if result.bucket.len == 0:
        # Installed but no bucket on disk — read the per-app
        # install.json to recover the originating bucket so the M55
        # adapter can still bind `bucket/app`.
        let installJson = cat.scoopRoot / "apps" / packageId / inst.version /
          "install.json"
        if fileExists(extendedPath(installJson)):
          try:
            let parsed = parseJson(readFile(extendedPath(installJson)))
            if parsed.kind == JObject:
              result.bucket = parsed{"bucket"}.getStr("")
          except CatchableError:
            discard
      if result.bucket.len == 0:
        result.bucket = "main"
      return result
    if manifest.found:
      # Available but not installed → a genuine realize (the M55
      # adapter will run `scoop install`).
      result.adapter = cakScoop
      result.installed = false
      result.cacheHit = false
      result.resolvedVersion = manifest.version
      return result
    let pathResolution = resolvePathPackage(packageId, searched, binaries)
    if pathResolution.found:
      return pathResolution.resolution
    result.searchedCatalogs = searched
    raiseUnknownPackage(packageId, searched)
  else:
    let pathResolution = resolvePathPackage(packageId, searched, binaries)
    if pathResolution.found:
      return pathResolution.resolution
    result.searchedCatalogs = searched
    raiseUnknownPackage(packageId, searched)

# ---------------------------------------------------------------------------
# M64 — cakBuiltin resolver (probe the M63 VersionedProvisioning catalog)
# ---------------------------------------------------------------------------
#
# `resolveBuiltinPackage` takes a packageId + an in-memory catalog
# (`seq[VersionedProvisioning]`, the shape `<tool>Catalog: seq[...]`
# literals export from `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/
# packages/<tool>.nim`) + an optional version constraint and returns a
# fully-populated `CatalogResolution` whose `adapter == cakBuiltin` and
# whose `urlUsed / digestAlgorithm / digestValue / archiveFormat /
# installMethod / binRelpath / extractPath / installerArgs /
# pacmanPackages / bootstrapArgv / envSubstitutions` carry the
# realization inputs the cakBuiltin realize loop consumes.
#
# Version resolution: an empty `version` selects the catalog default
# (last entry); a non-empty `version` is matched exactly against
# `vp.version`. Per-platform resolution uses
# `packages_schema.selectPlatformBinary` with the host's (cpu, os)
# tuple.
#
# Returns `(found = false, resolution = default)` on miss. Callers
# (M65's adapter chain) treat a miss as "this adapter cannot resolve
# the package; try the next adapter" rather than fail-closed.

type
  BuiltinResolveError* = enum
    breOk = "ok"
    breVersionNotInCatalog = "version-not-in-catalog"
      ## Requested `version` does not match any slice in the catalog.
    breEmptyCatalog = "empty-catalog"
      ## The catalog is empty — the packages/<tool>.nim is missing the
      ## `let <tool>Catalog* = @[...]` literal or shipped a stub.
    brePlatformNotSupported = "platform-not-supported"
      ## A matching version was found but it has no `PlatformBinary`
      ## entry for the current (cpu, os) tuple.
    breMicroarchFloorNotSatisfied = "microarch-floor-not-satisfied"
      ## PMC-2: a `PlatformBinary` DOES exist for the host's (cpu, os),
      ## but every such arm declares a microarchitecture floor above what
      ## the host provides. Distinct from `brePlatformNotSupported`
      ## because the remediation is different — the artifact exists and
      ## the host is below it — and because the alternative to reporting
      ## it is resolving an arm that traps at `SIGILL` on first use, far
      ## from anything that points back here. `errorDetail` names the
      ## shortfall ("needs x86-64-v3, host provides x86-64-v2").
    breSchemaInvalid = "schema-invalid"
      ## The selected slice failed `validateVersionedProvisioning`.
    breLockedTargetNotSatisfied = "locked-target-not-satisfied"
      ## PMC-4: the caller supplied a `lockedTarget` — the microarchitecture
      ## a LOCK FILE says this package resolved for — and this host cannot
      ## run it.
      ##
      ## Distinct from `breMicroarchFloorNotSatisfied`, and the distinction
      ## is the whole of `t_lock_from_a_v3_host_resolves_on_a_v2_host`. That
      ## error means "the catalog offers nothing this host can run"; this one
      ## means "the catalog might well offer something, but the lock already
      ## named a different answer and re-resolving would silently substitute
      ## it". A lock that quietly re-resolves is worse than one that fails:
      ## the build succeeds, the artifact is not the pinned one, and nothing
      ## anywhere says so. The remediations differ too — get a host that
      ## satisfies the lock, or refresh the lock on this host and commit the
      ## new pin — so collapsing the two would send the reader to the wrong
      ## one.
      ##
      ## Appended at the END of the enum on purpose: nothing serializes
      ## `BuiltinResolveError` by ordinal today, and keeping the existing
      ## members' ordinals fixed means nothing can start to.

  BuiltinResolveResult* = object
    found*: bool
    resolution*: CatalogResolution
    error*: BuiltinResolveError
    errorDetail*: string

proc resolveBuiltinPackage*(packageId: string;
                            catalog: openArray[VersionedProvisioning];
                            version = "";
                            hostCpu = detectHostCpu();
                            hostOs = detectHostOs();
                            hostLevel = detectHostMicroarchLevel(hostCpu);
                            hostFeatures = detectHostCpuFeatures(hostCpu)):
    BuiltinResolveResult =
  ## Probe a checked-in VersionedProvisioning catalog for a satisfying
  ## (version, platform) tuple and produce a `CatalogResolution`
  ## carrying every input the M64 realize loop needs.
  ##
  ## PMC-2: ``hostLevel`` is what the host PROVIDES on the
  ## microarchitecture axis, and it is a DEFAULTED PARAMETER for the same
  ## reason ``hostCpu`` / ``hostOs`` are — a test names a synthetic v2 or
  ## v3 host and never needs the hardware. Its default reads the
  ## environment (``detectHostMicroarchLevel``), and that read happens
  ## only when no caller supplied a value, so the seam stays hermetic.
  ## Note the default's dependence on ``hostCpu``: a caller that says
  ## "resolve as if this were aarch64" gets aarch64's baseline, not the
  ## real machine's.
  ##
  ## PMC-3: ``hostFeatures`` is the FOURTH such parameter and is ADDITIVE on
  ## top of ``hostLevel`` — this host provides its level's set UNION whatever
  ## it declares here. Its default is ``detectHostCpuFeatures(hostCpu)``,
  ## which is the only place ``REPRO_HOST_CPU_FEATURES`` can reach selection:
  ## a caller that supplies a set is never affected by the environment, which
  ## is what keeps the whole campaign's test suite hermetic.
  result.found = false
  result.error = breOk
  result.resolution.packageId = packageId
  result.resolution.adapter = cakBuiltin
  result.resolution.app = packageId
  result.resolution.searchedCatalogs = @["builtin:" & packageId]
  if catalog.len == 0:
    result.error = breEmptyCatalog
    result.errorDetail = "builtin catalog for '" & packageId & "' is empty"
    return
  var picked: VersionedProvisioning
  if version.len == 0:
    let def = selectDefault(catalog)
    if not def.found:
      result.error = breEmptyCatalog
      result.errorDetail = "selectDefault returned no entry"
      return
    picked = def.entry
  else:
    let exact = selectVersion(catalog, version)
    if not exact.found:
      result.error = breVersionNotInCatalog
      result.errorDetail = "no slice with version '" & version &
        "' in builtin catalog for '" & packageId & "'"
      return
    picked = exact.entry
  let schemaErrors = validateVersionedProvisioning(picked)
  if schemaErrors.len > 0:
    result.error = breSchemaInvalid
    result.errorDetail = "selected slice failed validation: " &
      schemaErrors.join("; ")
    return
  let pb = selectPlatformBinaryEx(picked,
    initPlatformTarget(hostCpu, hostLevel, hostFeatures), hostOs)
  if not pb.found:
    if pb.refusedForLevel:
      # PMC-2 deliverable 4, widened by PMC-3 deliverable 3. An arm EXISTS for
      # this (cpu, os); the host simply cannot run it. Say so, and say by how
      # much — the generic "no platform slice" message would send the reader
      # looking for a missing build that is right there in the catalog.
      #
      # ``describeCapabilityShortfall`` rather than
      # ``describeMicroarchShortfall``: an arm requiring x86-64-v3 + avx512vl
      # refused on a v3 host has NO level shortfall, so the PMC-2 sentence
      # would be empty here — and if it were emitted anyway it would read
      # "needs x86-64-v3, host provides x86-64-v3", contradicting the refusal.
      result.error = breMicroarchFloorNotSatisfied
      result.errorDetail = "builtin catalog for '" & packageId &
        "' version '" & picked.version & "' has a slice for cpu=" &
        $hostCpu & " os=" & $hostOs &
        ", but this host cannot run it: " & describeCapabilityShortfall(pb) &
        ". Selecting it anyway would resolve cleanly and then trap at " &
        "SIGILL on the first instruction the host lacks."
      return
    result.error = brePlatformNotSupported
    result.errorDetail = "no platform slice for cpu=" & $hostCpu &
      " os=" & $hostOs & " in builtin catalog for '" & packageId &
      "' version '" & picked.version & "'"
    return
  # Populate the resolution.
  result.found = true
  result.resolution.resolvedVersion = picked.version
  result.resolution.builtinVersion = picked.version
  result.resolution.builtinCpuLevel = pb.binary.cpu_level
  result.resolution.builtinCpuFeatures = pb.binary.cpu_features
  result.resolution.urlUsed = pb.binary.url
  if pb.binary.sha256.len > 0:
    result.resolution.digestAlgorithm = "sha256"
    result.resolution.digestValue = pb.binary.sha256.toLowerAscii()
  elif pb.binary.sha512.len > 0:
    result.resolution.digestAlgorithm = "sha512"
    result.resolution.digestValue = pb.binary.sha512.toLowerAscii()
  else:
    # M1 (Realize-Closure spec): sha1 is the weak fallback; the realize
    # loop emits a ``WSha1HashAccepted`` warning when it runs. Slice
    # validation in ``validateVersionedProvisioning`` already enforced
    # that at least one of the three digests is populated, so reaching
    # this arm without sha1 set is a schema-validator bug, not a runtime
    # case.
    result.resolution.digestAlgorithm = "sha1"
    result.resolution.digestValue = pb.binary.sha1.toLowerAscii()
  # M9.5: per-platform overrides for archive_format + bin_relpath. The
  # cross-OS catalog harvester pass (M9.5) needs them because a single
  # tool's upstream ships different archive shapes per OS (e.g. gh ships
  # ``.zip`` on Windows + ``.tar.gz`` on Linux) and the realized binary
  # path differs by OS (``.exe`` suffix only on Windows). The default
  # PlatformBinary leaves both unset → fall back to the VersionedProvisioning
  # values.
  if pb.binary.has_archive_format_override:
    result.resolution.archiveFormat = pb.binary.archive_format_override
  else:
    result.resolution.archiveFormat = picked.archive_format
  result.resolution.installMethod = picked.install_method
  if pb.binary.bin_relpath_override.len > 0:
    result.resolution.binRelpath = pb.binary.bin_relpath_override
  else:
    result.resolution.binRelpath = picked.bin_relpath
  result.resolution.extractPath = pb.binary.extract_path
  result.resolution.installerArgs = picked.installer_args
  result.resolution.pacmanPackages = picked.pacman_packages
  result.resolution.bootstrapArgv = picked.bootstrap_argv
  # M3: thread the residual 7z-family metadata through.
  result.resolution.nested7z = pb.binary.nested_7z
  result.resolution.preInstallActions = picked.pre_install_actions
  result.resolution.preInstallUnrecognized = picked.pre_install_unrecognized
  # M4: thread the per-platform MSI admin-install override through.
  result.resolution.msiAdminInstall = pb.binary.msi_admin_install
  # M5: thread the launcher_emit spec list through.
  result.resolution.launcherEmit = picked.launcher_emit
  # Use the first bin_relpath as the executable name (leaf only). M9.5:
  # honor the per-platform bin_relpath_override when present (the Linux
  # binary is ``gh`` without the ``.exe`` suffix that the Windows slice
  # carries).
  let effectiveBinRelpath =
    if pb.binary.bin_relpath_override.len > 0:
      pb.binary.bin_relpath_override
    else:
      picked.bin_relpath
  if effectiveBinRelpath.len > 0:
    result.resolution.executableName = effectiveBinRelpath[0].extractFilename
  else:
    result.resolution.executableName = packageId
  # Stable env-substitution order — sort by key so the realize loop
  # produces deterministic output and `serializeAsCode` round-trips.
  var keys: seq[string] = @[]
  for k in picked.env.keys:
    keys.add(k)
  for i in 0 ..< keys.len:
    for j in i + 1 ..< keys.len:
      if keys[j] < keys[i]:
        let tmp = keys[i]
        keys[i] = keys[j]
        keys[j] = tmp
  for k in keys:
    result.resolution.envSubstitutions.add((name: k, value: picked.env[k]))
  result.resolution.installed = false
  result.resolution.cacheHit = false  # set true by `realizeBuiltinPackage`
                                      # when the CAS prefix exists

# ---------------------------------------------------------------------------
# M65 — adapter selection chain
# ---------------------------------------------------------------------------
#
# The chain accepts a per-host-configurable adapter preference list
# (default: platform-specific) and walks it in order, asking each
# adapter "can you resolve this package?" until one says yes. The trace
# of every step is attached to the resolution for ``--plan`` /
# ``repro show-conventions`` introspection; on exhaustion a structured
# ``EAdapterChainExhausted`` carrying the same trace is raised.
#
# The chain consults adapters in this conceptual order (cache-first is
# the implicit M56 store lookup that happens inside each adapter's
# realize loop, NOT a resolution-time concern — the resolver only
# decides WHICH adapter realizes; the realize loop's own
# `cacheHit` verdict is reported back through the M64 dispatcher):
#
#   1. cakBuiltin — `getCatalog(packageId)` against the M65 registry.
#                   A registered tool with a non-empty catalog that
#                   yields a `BuiltinResolveResult.found == true` is a
#                   chain hit.
#   2. cakNix     — placeholder. The M21 realize-side Nix adapter is
#                   landing in a parallel branch; until it is wired
#                   into the resolver, cakNix is skipped cleanly with
#                   `csoAdapterUnavailable`.
#   3. cakScoop   — Windows-only. Falls back to the existing
#                   `resolvePackage` logic for the Scoop branch.
#   4. cakPath    — the universal "executable already on PATH" adapter.
#                   Last-resort.
#
# The chain is greedy first-match. Adapters not listed in the
# preference are skipped silently (no trace entry). A preference of
# `[builtin, path]` will never consult cakScoop even on Windows.

const
  WindowsDefaultChain* = @[cakBuiltin, cakScoop, cakPath]
    ## M65: the default Windows adapter preference. cakBuiltin is the
    ## new primary; cakScoop is the user-facing interop branch for
    ## Scoop-native users; cakPath is the last-resort PATH fallback.

  LinuxDefaultChain* = @[cakNix, cakBuiltin, cakPath]
    ## M65: the default Linux adapter preference. cakNix is the
    ## existing M21 production path (skipped cleanly when the realize-
    ## side branch is not yet wired); cakBuiltin is the secondary; the
    ## PATH adapter remains the last-resort fallback.

  MacosDefaultChain* = @[cakNix, cakPath]
    ## M65: the default macOS adapter preference. cakBuiltin is not yet
    ## supported on macOS per the M64 outstanding-task list (slices
    ## ship Windows + Linux today; macOS slices land in a future
    ## campaign). Mac users continue using Nix; PATH is the fallback.

proc defaultAdapterChain*(): seq[CatalogAdapterKind] =
  ## Return the platform-default adapter preference chain. Callers
  ## that want to override the default pass an explicit ``chain`` to
  ## ``chainResolvePackage``; M69's ``adapter_preference:`` DSL hook
  ## reads the per-host preference out of ``home.nim`` and threads it
  ## through here.
  when defined(windows):
    WindowsDefaultChain
  elif defined(linux):
    LinuxDefaultChain
  elif defined(macosx) or defined(osx):
    MacosDefaultChain
  else:
    @[cakPath]

proc tryResolveBuiltin(packageId: string;
                       version: string;
                       hostCpu: PlatformCpu;
                       hostOs: PlatformOs;
                       hostLevel: MicroarchLevel;
                       hostFeatures: set[CpuFeature];
                       step: var ChainStep):
    tuple[found: bool; resolution: CatalogResolution] =
  ## M65: the cakBuiltin branch of the chain. Looks the tool up in the
  ## M65 catalog registry; on a hit, runs
  ## ``resolveBuiltinPackage`` and reports the resolution. On a miss or
  ## a structured error the resolver fills ``step`` with the skip
  ## reason and returns ``(false, ...)`` so the chain moves on.
  step.adapter = cakBuiltin
  let catOpt = getCatalog(packageId)
  if catOpt.isNone:
    step.outcome = csoCatalogMiss
    step.reason = "no built-in catalog registered for '" & packageId &
      "' (M65 registry knows " &
      (if RegisteredTools.len > 0:
         "@[\"" & RegisteredTools.join("\", \"") & "\"]"
       else: "<none>") & ")"
    return (false, CatalogResolution())
  let cat = catOpt.get
  if cat.len == 0:
    step.outcome = csoCatalogMiss
    step.reason = "built-in catalog for '" & packageId & "' is empty"
    return (false, CatalogResolution())
  let res = resolveBuiltinPackage(packageId, cat, version, hostCpu, hostOs,
    hostLevel, hostFeatures)
  if not res.found:
    step.outcome = csoSchemaError
    # PMC-2: ``res.errorDetail`` carries the microarchitecture shortfall for
    # ``breMicroarchFloorNotSatisfied``, and the chain-exhausted diagnostic
    # concatenates every step's ``reason`` — so "needs x86-64-v3, host
    # provides x86-64-v2" survives all the way to the message a user reads,
    # rather than stopping at this frame.
    step.reason = "resolveBuiltinPackage: " & $res.error & " (" &
      res.errorDetail & ")"
    # PMC-4: mark a CAPABILITY refusal so the chain can refuse to fall through
    # to ``cakPath``. See ``ChainStep.capabilityShortfall``.
    step.capabilityShortfall = res.error == breMicroarchFloorNotSatisfied
    return (false, CatalogResolution())
  step.outcome = csoResolved
  # The SUCCESS reason is left byte-identical to its pre-PMC-2 text. Every
  # host now has a microarchitecture level (x86_64 baselines at v1), so
  # appending it would rewrite this string on every successful resolution of
  # every existing package — a gratuitous compatibility event for a line that
  # says nothing new when the selected arm declares no floor. The level is
  # reported where it is load-bearing: the refusal.
  step.reason = "matched version '" & res.resolution.builtinVersion &
    "' for " & $hostCpu & "-" & $hostOs
  if res.resolution.builtinCpuLevel != mlNone:
    step.reason.add(" (" & describeMicroarchLevel(
      res.resolution.builtinCpuLevel) & ")")
  (true, res.resolution)

proc tryResolveNix(packageId: string; step: var ChainStep):
    tuple[found: bool; resolution: CatalogResolution] =
  ## M65: the cakNix branch of the chain. The M21 realize-side Nix
  ## adapter lands in a parallel branch under ``libs/repro_home_*``;
  ## until that integration is wired into the resolver, cakNix is
  ## skipped cleanly with ``csoAdapterUnavailable``. The chain moves
  ## on. Windows always skips cakNix regardless of registration —
  ## Nix is not supported on Windows.
  step.adapter = cakNix
  step.outcome = csoAdapterUnavailable
  when defined(windows):
    step.reason = "cakNix is not supported on Windows (skipped)"
  else:
    step.reason = "cakNix resolver not yet wired into the M65 chain " &
      "(parallel work in libs/repro_home_*); skipped cleanly so the " &
      "chain falls through to the next adapter"
  (false, CatalogResolution())

proc tryResolveScoop(cat: var ProductionCatalog; packageId: string;
                     step: var ChainStep):
    tuple[found: bool; resolution: CatalogResolution] =
  ## M65: the cakScoop branch of the chain. Windows-only; on non-
  ## Windows hosts the step is recorded as ``csoAdapterUnavailable``
  ## and the chain moves on. On Windows we look the package up in
  ## ``scoop list`` + the configured bucket inventory using the same
  ## helpers the legacy ``resolvePackage`` uses.
  step.adapter = cakScoop
  when not defined(windows):
    step.outcome = csoAdapterUnavailable
    step.reason = "cakScoop is Windows-only"
    return (false, CatalogResolution())
  else:
    let inst = installedVersion(cat, packageId)
    let manifest = findBucketManifest(cat, packageId)
    if (not inst.installed) and (not manifest.found):
      step.outcome = csoToolNotFound
      step.reason = "no installed Scoop app named '" & packageId &
        "' and no bucket manifest carries it"
      return (false, CatalogResolution())
    var resolution = CatalogResolution(
      packageId: packageId,
      adapter: cakScoop,
      app: packageId,
      executableName: packageId)
    if manifest.found:
      resolution.bucket = manifest.bucket
      if manifest.binName.len > 0:
        resolution.executableName = manifest.binName
      if not inst.installed:
        resolution.resolvedVersion = manifest.version
    if inst.installed:
      resolution.installed = true
      resolution.resolvedVersion = inst.version
      resolution.cacheHit = satisfiesProfile(inst.version,
        pinnedVersion = "", preferredVersion = "")
      let installedExe = installedExecutableName(cat.scoopRoot, packageId,
        inst.version)
      if installedExe.len > 0:
        resolution.executableName = installedExe
      if resolution.bucket.len == 0:
        let installJson = cat.scoopRoot / "apps" / packageId / inst.version /
          "install.json"
        if fileExists(extendedPath(installJson)):
          try:
            let parsed = parseJson(readFile(extendedPath(installJson)))
            if parsed.kind == JObject:
              resolution.bucket = parsed{"bucket"}.getStr("")
          except CatchableError:
            discard
      if resolution.bucket.len == 0:
        resolution.bucket = "main"
    step.outcome = csoResolved
    step.reason =
      if inst.installed:
        "installed at version '" & inst.version & "' (bucket=" &
          resolution.bucket & ")"
      else:
        "available in bucket '" & manifest.bucket & "' at version '" &
          manifest.version & "' (not yet installed)"
    return (true, resolution)

proc tryResolvePath(packageId: string; binaries: seq[string];
                    step: var ChainStep):
    tuple[found: bool; resolution: CatalogResolution] =
  ## M65: the cakPath branch of the chain. The last-resort adapter:
  ## the executable is on PATH, so we record it as a path-adapter
  ## resolution. Already-on-PATH is an implicit cache-hit.
  ##
  ## 2026-06-09 (binaries metadata): when `binaries` is non-empty, the
  ## adapter probes EACH binary name on PATH and reports a hit on the
  ## first one that exists. This handles upstream packages whose
  ## binary name differs from the package name (e.g. nixpkgs `ripgrep`
  ## ships the `rg` binary; `package("ripgrep", binaries = @["rg"])`
  ## resolves correctly). Empty `binaries` preserves the pre-2026-06
  ## behavior: probe the package name itself.
  step.adapter = cakPath
  let probeNames =
    if binaries.len > 0: binaries
    else: @[packageId]
  var firstFound = ""
  var foundName = ""
  for name in probeNames:
    let exe = findExe(name)
    if exe.len > 0:
      firstFound = exe
      foundName = name
      break
  if firstFound.len == 0:
    step.outcome = csoToolNotFound
    if probeNames.len == 1:
      step.reason = "'" & probeNames[0] & "' not found on PATH"
    else:
      step.reason = "none of [" & probeNames.join(", ") & "] found on PATH"
    return (false, CatalogResolution())
  step.outcome = csoResolved
  step.reason = "found '" & firstFound & "' on PATH"
  var resolution = CatalogResolution(
    packageId: packageId,
    adapter: cakPath,
    app: packageId,
    executableName: extractFilename(firstFound),
    sourcePath: firstFound,
    installed: true,
    cacheHit: true,
    searchedCatalogs: @["path:" & getEnv("PATH")])
  (true, resolution)

proc raiseAdapterChainExhausted*(packageId: string;
                                 chain: seq[CatalogAdapterKind];
                                 trace: seq[ChainStep]) {.noreturn.} =
  ## M65: every adapter in ``chain`` was tried and none resolved
  ## ``packageId``. The error carries the chain that was walked plus
  ## the per-step skip reason so the CLI layer can render a structured
  ## diagnostic ("nix: no nixPackage branch; builtin: no slice matches;
  ## scoop: not installed; path: not on PATH"). Mirrors the
  ## ``EAdapterChainExhausted`` shape the M65 spec specifies.
  var chainStr = ""
  for i, a in chain:
    if i > 0: chainStr.add(", ")
    chainStr.add($a)
  var reasonStr = ""
  for i, step in trace:
    if i > 0: reasonStr.add("; ")
    reasonStr.add($step.adapter & ": " & step.reason)
  var e = newException(EAdapterChainExhausted,
    "adapter chain exhausted for package '" & packageId &
    "'. Chain walked: [" & chainStr & "]. Per-adapter outcomes: " &
    reasonStr & ". Declare the package in a recognized adapter " &
    "catalog (built-in registry, Scoop, Nix), make its executable " &
    "available on PATH, or override `adapter_preference:` in home.nim.")
  e.packageId = packageId
  e.chain = chain
  e.chainTrace = trace
  raise e

proc chainResolvePackage*(cat: var ProductionCatalog;
                          packageId: string;
                          chain: seq[CatalogAdapterKind] = @[];
                          version = "";
                          binaries: seq[string] = @[];
                          hostCpu = detectHostCpu();
                          hostOs = detectHostOs();
                          availability = none(PackageAvailability);
                          hostLevel = detectHostMicroarchLevel(hostCpu);
                          hostFeatures = detectHostCpuFeatures(hostCpu)):
    CatalogResolution =
  ## M65: the production adapter selection chain. Walks ``chain`` in
  ## order, returning the first adapter's resolution. When ``chain`` is
  ## empty the platform default is used (Windows: builtin/scoop/path;
  ## Linux: nix/builtin/path; macOS: nix/path).
  ##
  ## Raises ``EAdapterChainExhausted`` if every adapter in the chain
  ## was tried and none resolved.
  ##
  ## PMC-1: raises ``EPackageUnavailableOnPlatform`` BEFORE walking the
  ## chain when the package declared a ``platforms:`` set this host is not
  ## in. ``availability`` overrides the registry lookup; leave it ``none``
  ## in production and pass a synthetic value in tests that need a
  ## declaration without a registered recipe.
  ##
  ## The returned ``CatalogResolution.chainTrace`` carries one entry
  ## per adapter consulted, in order, with the per-adapter outcome +
  ## skip reason (the final entry on a hit has
  ## ``outcome == csoResolved`` — the others are skip reasons).
  ##
  ## PMC-2: ``hostLevel`` says what this host provides on the
  ## microarchitecture axis. It is a DEFAULTED PARAMETER for the same
  ## reason ``hostCpu`` / ``hostOs`` are, and the campaign's testability
  ## note makes that a requirement rather than a convenience: a v2/v3
  ## test names its host here and needs no such hardware.
  ##
  ## PMC-3: ``hostFeatures`` is the fourth such parameter, additive on top of
  ## ``hostLevel``. Supplying one changes NOTHING for the standard library —
  ## every stdlib arm requires ``{}`` and ``{} ⊆ anything`` — which is the
  ## check that PMC-3 did not move every existing package by adding a field
  ## nobody uses.
  ##
  ## When the builtin catalog holds an arm the host cannot run, the
  ## cakBuiltin step SKIPS (as it already did for an unsupported
  ## platform) and the chain continues. That is deliberate — PMC-2 does
  ## not change chain control flow — but it means the shortfall must
  ## survive into the eventual ``EAdapterChainExhausted`` message, and it
  ## does: ``raiseAdapterChainExhausted`` renders every step's reason.
  ## Note the consequence for a chain ending in ``cakPath``: an
  ## unsatisfiable floor can still fall through to a same-named PATH
  ## binary, exactly as an unsupported platform always could. PMC-1
  ## closed that hole only for a package with an explicit ``platforms:``
  ## declaration; closing it for a microarchitecture shortfall is a
  ## behaviour change to the chain, not to selection, and is left to
  ## PMC-4/PMC-5 rather than smuggled in here.
  # PMC-1: declared availability is consulted BEFORE the adapter chain.
  #
  # Ordering is the substance of the deliverable, not a detail. The last
  # adapter in every default chain is ``cakPath``, which probes the host's
  # PATH for a same-named executable — so a package that cannot exist here
  # did not merely fail with a confusing message, it could RESOLVE, to an
  # undeclared binary that happened to share the name. That looks like
  # success. Gating in front of the loop is what makes ``cakPath``
  # unreachable for a package known to be unavailable.
  let declaredAvailability =
    if availability.isSome: availability.get
    else: packageAvailability(packageId)
  if not declaredAvailability.isAvailableOn(hostCpu, hostOs):
    raisePackageUnavailableOnPlatform(packageId, declaredAvailability,
      hostCpu, hostOs)
  let effective =
    if chain.len == 0: defaultAdapterChain()
    else: chain
  var trace: seq[ChainStep] = @[]
  # PMC-4: has some adapter already said "I have this and this host cannot run
  # it"? See the ``cakPath`` arm below for why that is not the same as "I do
  # not have it", and why only ``cakPath`` is poisoned by it.
  var capabilityRefusal = ""
  for adapter in effective:
    var step = ChainStep(adapter: adapter, outcome: csoAdapterUnavailable,
      reason: "")
    case adapter
    of cakBuiltin:
      let outcome = tryResolveBuiltin(packageId, version, hostCpu, hostOs,
        hostLevel, hostFeatures, step)
      if step.capabilityShortfall and capabilityRefusal.len == 0:
        capabilityRefusal = step.reason
      trace.add(step)
      if outcome.found:
        var resolution = outcome.resolution
        resolution.chainTrace = trace
        return resolution
    of cakNix:
      let outcome = tryResolveNix(packageId, step)
      trace.add(step)
      if outcome.found:
        var resolution = outcome.resolution
        resolution.chainTrace = trace
        return resolution
    of cakScoop:
      let outcome = tryResolveScoop(cat, packageId, step)
      trace.add(step)
      if outcome.found:
        var resolution = outcome.resolution
        resolution.chainTrace = trace
        return resolution
    of cakPath:
      # PMC-4 — the silent-wrong-thing gate, and the reason this whole flag
      # exists.
      #
      # ``cakPath`` probes the host's PATH for a SAME-NAMED executable. If an
      # earlier adapter refused because the host cannot execute what the
      # catalog offers, probing PATH does not recover from that: it resolves
      # a DIFFERENT, undeclared binary that merely shares a name, and reports
      # success. The user asked for a package with an x86-64-v3 floor and got
      # whatever ``foo.exe`` was first on PATH.
      #
      # This is exactly the hazard PMC-1 closed for declared availability
      # (`Package-Model.md`: "``cakPath`` stops being reachable for a package
      # known to be unavailable"), reappearing on the capability axis. PMC-1
      # could gate in front of the loop because availability is known before
      # any adapter runs; a floor shortfall is only discovered by ASKING the
      # builtin adapter, so the gate has to live here instead.
      #
      # Only ``cakPath`` is poisoned. ``cakNix`` and ``cakScoop`` resolve
      # genuinely different artifacts that may well satisfy this host, and
      # refusing them would turn a safety fix into an outage.
      if capabilityRefusal.len > 0:
        step.outcome = csoAdapterUnavailable
        step.reason = "refused: the builtin catalog has this package but " &
          "this host cannot run it, and resolving a same-named executable " &
          "from PATH would substitute an undeclared binary for the one that " &
          "was refused (" & capabilityRefusal & ")"
        trace.add(step)
        continue
      let outcome = tryResolvePath(packageId, binaries, step)
      trace.add(step)
      if outcome.found:
        var resolution = outcome.resolution
        resolution.chainTrace = trace
        return resolution
  raiseAdapterChainExhausted(packageId, effective, trace)
