## Profile package resolution (GM4b).
##
## A home profile's ``package "<name>"`` reference resolves through the same
## selection as a recipe's ``uses: "<name>"`` (Provisioning-Contributions.md
## §"Profile Package References"; Gradual-Nix-To-Reprobuild-Migration.md
## §Decision): the canonical package definition and its provisioning
## contributions, filtered for the target platform and selected by a policy,
## through ``repro_tool_profiles/realization_selection.selectRealization`` —
## the one implementation both callers use.
##
## This module supplies what is specific to the PROFILE caller:
##
## * the candidate records — ``profileToolUse`` projects the reference
##   exactly as interface extraction projects a recipe's ``uses:``
##   (``toProjectInterface`` over the definitions the engine links through
##   ``repro_dsl_stdlib/package_registry`` and their contributions);
## * the profile's target (``profileRealizationTarget``) and selection policy
##   (``selectionPolicyFor``, from ``adapterPreference:``);
## * the host inventory a profile may consult: PATH everywhere, and on a
##   Windows host the Scoop installed-app table and bucket manifests
##   (``ScoopHostInventory``);
## * the shape the home archive realizer consumes (``ArchiveRealization``)
##   for a ``tarball`` selection that needs it.
##
## Before GM4b this module held a per-platform adapter chain that read a
## second copy of the archive realizations (the ``<tool>Catalog`` records).
## Both are gone; see Core-Invariants.md §"One Implementation Per Concern".
##
## The host-target detection below (microarchitecture level and features) is
## unchanged PMC-2..PMC-4 machinery: it decides what the host PROVIDES, which
## the selection then compares against each archive's floor.

import std/[json, options, os, osproc, sets, strutils, tables]
from repro_core/paths import extendedPath

import repro_project_dsl
import repro_interface_artifacts
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/package_registry
import repro_tool_profiles/realization_selection

import ./catalog_projection
from repro_home_resources/drivers/app_bundle import installerProductPathError

export packages_schema
export catalog_projection
export realization_selection
export package_registry.packageAvailability

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
  ArchiveRealization* = object
    ## A selected ``tarball`` realization in the shape the home archive
    ## realizer (``builtin_adapter.realizeBuiltinPackage``) consumes.
    ## Built by ``archiveRealizationOf`` from the selected record — it is a
    ## projection of that record, never a second source of truth.
    packageId*: string
    app*: string
    resolvedVersion*: string         ## the record's version, when declared
    executableName*: string
    cacheHit*: bool                  ## set by the realizer when the CAS
                                     ## prefix already exists
    builtinVersion*: string          ## the record's ``detail.version``
    builtinCpuLevel*: MicroarchLevel
                                     ## PMC-2: the microarchitecture FLOOR the
                                     ## selected record declared, or
                                     ## ``mlNone``.
    builtinCpuFeatures*: set[CpuFeature]
                                     ## PMC-3: the extra extensions the
                                     ## selected record declared beyond its
                                     ## floor (the DECLARED set, not its
                                     ## expansion).
    resolvedTarget*: string
                                     ## PMC-4: ``renderResolvedTarget`` of the
                                     ## two above — the single spelling a lock
                                     ## entry and a cache key use. ``""`` for a
                                     ## record that declares no floor.
    urlUsed*: string
    digestAlgorithm*: string         ## "sha256" | "sha512" | "sha1"
    digestValue*: string             ## hex digest (lowercase)
    archiveFormat*: ArchiveFormat
    installMethod*: InstallMethod
    binRelpath*: seq[string]
    extractPath*: string             ## inner-dir flatten
    installerArgs*: seq[string]
    pacmanPackages*: seq[string]
    bootstrapArgv*: seq[string]
    envSubstitutions*: seq[tuple[name, value: string]]
    nested7z*: bool
    preInstallActions*: seq[PreInstallAction]
    preInstallUnrecognized*: seq[string]
    msiAdminInstall*: bool
      ## When true the realize loop uses ``msiexec /a`` instead of
      ## ``dark.exe`` for MSI extraction (the per-record form of the global
      ## ``CAKBUILTIN_PREFER_MSIEXEC=1``).
    launcherEmit*: seq[LauncherEmitSpec]
    appBundle*: string
      ## GM4c: the ``.app`` bundle's path inside the archive, for an
      ## ``imAppBundle`` record (Store-And-Installation-Layout.md § macOS
      ## Application Bundles). With ``bundleId`` / ``teamId`` and the
      ## record's version it is what the realizer verifies. For a macOS
      ## installer application it is the product bundle's path inside the
      ## installed prefix (§ Installer applications).
    bundleId*: string
    teamId*: string
    installerApp*: string
      ## The installer application's path inside the archive, for a macOS
      ## ``imInstallerSilent`` record (Store-And-Installation-Layout.md
      ## § Installer applications); "" for a Windows installer.

  ArchiveRoute* = enum
    ## Which realizer a ``tarball`` selection goes to (see
    ## ``realization_selection.archiveInstallerFeatures``).
    arExtract = "tarball"
      ## A plain archive: the ``uses:`` provisioning edge
      ## (``repro_tool_profiles.resolveTarballTool``) realizes it, exactly as
      ## it does for a recipe.
    arInstaller = "builtin"
      ## Installers, MSYS2 packages, pre-install steps, launcher emission:
      ## the home archive realizer (``builtin_adapter``).

  ScoopHostInventory* = ref object
    ## Per-apply handle on the host's Scoop: installed apps and configured
    ## bucket manifests. The installed-app table and the bucket list are
    ## memoized, so a multi-package apply shells out to `scoop` at most once.
    scoopRoot: string
    scoopExe: string
    installedQueried: bool
    installedApps: Table[string, string]   ## app -> installed version
    buckets: seq[string]                   ## configured bucket names

  ProfilePackageResolution* = object
    ## A profile reference resolved for one target.
    packageId*: string
    requestedVersion*: string
    selection*: RealizationSelection
    useDef*: InterfaceToolUse
      ## The reference projected as a ``uses:``, NARROWED to the selected
      ## record, so a realizer handed it cannot select something else.
    archiveRoute*: ArchiveRoute
    archive*: ArchiveRealization
      ## Populated for a ``tarball`` selection routed to ``arInstaller``.
    cacheHit*: bool
      ## Already present on the host: a PATH selection, or a Scoop app
      ## installed at a satisfying version.
    installedVersion*: string

# ---------------------------------------------------------------------------
# Host target detection
# ---------------------------------------------------------------------------
#
# Every platform test passes a SYNTHETIC target through the resolver's
# parameters, so the suite runs identically on any machine. Do not convert
# them into a global lookup.

# ``detectHostCpu``, ``detectHostOs`` and ``baselineMicroarchLevel`` live in
# ``repro_dsl_stdlib/packages_schema`` (GM4b) so the realization selector in
# ``repro_tool_profiles`` names the host the same way; re-exported above.

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

type
  HostTargetResolver* = proc(): PlatformTarget {.gcsafe, closure.}
    ## PMC-6 — the seam that makes the microarchitecture host target and the
    ## engine's `targetTriple` ONE input instead of two.
    ##
    ## ## Why a closure and not a direct read
    ##
    ## `targetTriple` is a SOLVER VARIANT. Resolving it needs the solver, and
    ## this module must not import it -- the same layering rule that made the
    ## build engine take a `TargetTripleResolver` closure rather than reaching
    ## for `repro_dsl_stdlib` itself (`repro_build_engine/platform.nim`).
    ##
    ## So the CLI, which is the only layer that can see both, wires a closure
    ## here exactly as it already wires one there. This module stays a leaf,
    ## and the two axes acquire a single decision point instead of two
    ## independent ones that agree only by coincidence of defaults.
    ##
    ## `nil` means "nobody wired one", which is the library and test case: the
    ## environment-based default below applies, and behaviour is what it was
    ## before PMC-6.

var hostTargetResolverHook: HostTargetResolver = nil
  ## Deliberately private. A caller SETS it through `setHostTargetResolver`
  ## and can never read it back, so no code path can start branching on
  ## "was a resolver wired?" -- which would reintroduce the two-answers
  ## problem in a new shape.

proc setHostTargetResolver*(resolver: HostTargetResolver) =
  ## Wire the single host-target authority. Called once by the CLI driver.
  ##
  ## Passing `nil` restores the environment-based default; that is what tests
  ## do to get back to a known state, and it is why this is idempotent rather
  ## than a one-shot install.
  hostTargetResolverHook = resolver

proc environmentHostTarget*(): PlatformTarget =
  ## The host target as described by `REPRO_HOST_MICROARCH_LEVEL` /
  ## `REPRO_HOST_CPU_FEATURES` alone, ignoring any wired resolver.
  ##
  ## Exposed so the CLI's resolver can COMPOSE it -- read the variant, fall
  ## back to the environment -- rather than reimplementing the parsing and
  ## refusal rules and letting the two copies drift.
  let family = detectHostCpu()
  initPlatformTarget(family, detectHostMicroarchLevel(family),
    detectHostCpuFeatures(family))

proc hostTarget*(): PlatformTarget =
  ## What the produced artifacts must run on.
  ##
  ## The wired resolver when there is one; otherwise the environment, which
  ## itself defaults to the build machine -- the `"native"` sentinel the build
  ## engine already uses, and why one "host" concept worked for so long.
  if hostTargetResolverHook != nil:
    return hostTargetResolverHook()
  environmentHostTarget()

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

proc targetRoleForDepKind*(kind: string): TargetRole =
  ## PMC-6 — route a dependency to the target that must satisfy it, keyed on
  ## the engine's own `DepKind` spelling.
  ##
  ## Takes the kind as a STRING rather than importing `repro_build_engine`.
  ## That import would be a layering inversion (the engine deliberately does
  ## not depend on this side either), and the vocabulary here is three fixed
  ## tokens that the engine already serialises.
  ##
  ##   * `nativeBuildDeps:` / `dkNative` -- tools that RUN during the build.
  ##     They execute on the BUILD machine, so a compiler that traps here is
  ##     useless no matter what it is producing.
  ##   * `buildDeps:` / `dkBuild` and `runtimeDeps:` / `dkRuntime` -- libraries
  ##     the produced binaries link or load. They must satisfy the HOST target,
  ##     because that is where those binaries will run.
  ##
  ## The default is the HOST target, and that direction is deliberate: an
  ## unrecognised kind that resolved against the build machine could let an
  ## artifact silently inherit capabilities the target lacks, which is a SIGILL
  ## on someone else's machine. Resolving against the host target instead can
  ## only ever be too conservative -- it may refuse something that would have
  ## worked, loudly, here.
  case kind
  of "dkNative", "native", "nativeBuildDeps": trBuildMachine
  else: trHostTarget

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


# ---------------------------------------------------------------------------
# M0 (Realize-Layer-Plumbing-Closures spec) — extractor-discovery edges
# ---------------------------------------------------------------------------
#
# The home archive realizer (``builtin_adapter``) needs a small set of helper
# executables (``7z.exe``, ``lessmsi.exe``, ``dark.exe``, ``innounp.exe``)
# depending on the package's ``archive_format`` + ``install_method``.
# When the operator bundles those extractors as catalog packages in the
# SAME ``home.nim`` (the M3 bundling-posture decision from the
# Realize-Closure-And-Catalog-Expansion predecessor campaign), the
# realize-op order MUST honour these discovery edges — the consumer
# cannot realize until its extractor's prefix exists.
#
# The mapping below is the M0 hard-coded form. A future milestone could
# lift it to schema-driven metadata (a ``requires_for_realize:`` field on
# the ``tarball`` realization); for M0 the small constant table is
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
# the `tarball` realization (`TarballArchiveDetail`) would replace this
# hard-coded map. Migration starting point: move these consts into the
# per-package realization
# (each affected `packages/<tool>.nim` declares its own
# `requires_for_realize: @["7zip"]` or similar in the
# `tarball` statement); then have `extractorDependencies`
# below read `resolution.requiresForRealize` directly instead of
# pattern-matching on `archive_format` / `install_method`. The case
# statements in the proc body would collapse to a one-line passthrough.
# See Realize-Layer-Plumbing-Closures.milestones.org M0 Outstanding
# Tasks for the planned schema shape.
const
  ExtractorProvider7zip*    = "7zip"
    ## The stdlib definition is ``package "7zip"`` (module
    ## ``packages/pkg_7zip.nim``).
  ExtractorProviderLessmsi* = "lessmsi"
  ExtractorProviderWix3*    = "wix3"
  ExtractorProviderInnounp* = "innounp"

proc extractorDependencies*(packageId: string;
                            resolution: ArchiveRealization): seq[string] =
  ## Return the set of catalog-package names that must be realized BEFORE
  ## ``packageId`` can be realized, derived from the resolution's
  ## ``archive_format`` + ``install_method`` requirements.
  ##
  ## Hard-coded extractor-provider map (M0). Future enhancement:
  ## schema-driven ``requires_for_realize:`` field on
  ## the ``tarball`` realization.
  ##
  ## Callers pass only archives the home archive realizer will realize
  ## (GM4b: a ``tarball`` selection routed to ``builtin_adapter``); a
  ## selection of another kind, or a plain archive realized by the
  ## ``uses:`` provisioning edge, has no extractor-discovery edge.
  ##
  ## The returned seq never contains ``packageId`` itself (self-edges are
  ## skipped) — even though e.g. ``pkg_7zip.nim`` itself uses
  ## ``imInstallerMsi`` which needs ``lessmsi``, that's a real edge
  ## (7zip → lessmsi); the self-edge filter is for the degenerate
  ## case where the mapping ever points a package at itself.
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

proc openScoopHostInventory*(): ScoopHostInventory =
  ## Build a fresh per-apply Scoop inventory handle. Cheap: it only records
  ## the Scoop root + executable paths; the installed-app table and bucket
  ## inventory are filled lazily on first query.
  result = ScoopHostInventory()
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

proc ensureInstalledQueried(cat: ScoopHostInventory) =
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

proc installedVersion*(cat: ScoopHostInventory; app: string):
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

proc ensureBucketsQueried(cat: ScoopHostInventory) =
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

proc findBucketManifest*(cat: ScoopHostInventory; app: string):
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


# ---------------------------------------------------------------------------
# Host inventory
# ---------------------------------------------------------------------------

proc probeScoopApp*(inv: ScoopHostInventory; app: string): ScoopInventoryHit =
  ## What the host's Scoop knows about ``app``: installed (``scoop list`` /
  ## the ``apps/`` tree) and/or offered by a configured bucket. An installed
  ## app's executable name comes from its own copied manifest, its bucket
  ## from ``install.json`` when no bucket on disk carries it.
  let inst = installedVersion(inv, app)
  let manifest = findBucketManifest(inv, app)
  if (not inst.installed) and (not manifest.found):
    return ScoopInventoryHit(found: false, app: app)
  result = ScoopInventoryHit(found: true, app: app, executableName: app)
  if manifest.found:
    result.bucket = manifest.bucket
    result.version = manifest.version
    if manifest.binName.len > 0:
      result.executableName = manifest.binName
  if inst.installed:
    result.installed = true
    result.version = inst.version
    let installedExe = installedExecutableName(inv.scoopRoot, app,
      inst.version)
    if installedExe.len > 0:
      result.executableName = installedExe
    if result.bucket.len == 0:
      let installJson = inv.scoopRoot / "apps" / app / inst.version /
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

proc pathInventoryProbe*(): PathProbe =
  ## The host's PATH: the first of ``names`` ``findExe`` resolves.
  result = proc(names: seq[string]): string =
    for name in names:
      let exe = findExe(name)
      if exe.len > 0:
        return exe
    ""

proc profileHostInventory*(scoop: ScoopHostInventory = nil): HostInventory =
  ## The inventory a profile on THIS host may consult (Provisioning-
  ## Contributions.md §"Host inventory"): PATH everywhere, and the Scoop
  ## installed/bucket inventory on a Windows host.
  result.probePath = pathInventoryProbe()
  when defined(windows):
    let inv = if scoop.isNil: openScoopHostInventory() else: scoop
    result.probeScoop = proc(app: string): ScoopInventoryHit =
      probeScoopApp(inv, app)
  else:
    discard scoop

# ---------------------------------------------------------------------------
# Targets and policies
# ---------------------------------------------------------------------------

proc profileRealizationTarget*(platform, arch: string; isHost: bool):
    RealizationTarget =
  ## The realization target of a profile evaluated for ``platform`` /
  ## ``arch`` (``HostContext`` spellings: macos | linux | wsl | windows,
  ## x86_64 | arm64). The host's microarchitecture level and features are
  ## the ones it DECLARES (``hostTarget()``, PMC-2/3); a cross target is
  ## taken at its family's definitional baseline. An unrecognised spelling
  ## is refused: resolving for a platform nobody can name would select for
  ## "any" and look like success.
  let os =
    case platform.toLowerAscii()
    of "macos", "darwin", "osx": poMacos
    of "linux", "wsl": poLinux
    of "windows", "win": poWindows
    else:
      raise newException(ValueError, "cannot resolve packages for platform '" &
        platform & "' (expected macos, linux, wsl or windows)")
  let cpu =
    case arch.toLowerAscii()
    of "x86_64", "amd64", "x64": pcX86_64
    of "arm64", "aarch64": pcAArch64
    else:
      raise newException(ValueError, "cannot resolve packages for arch '" &
        arch & "' (expected x86_64 or arm64)")
  if isHost:
    var platformTarget = hostTarget()
    if platformTarget.family != cpu:
      platformTarget = initPlatformTarget(cpu, baselineMicroarchLevel(cpu))
    RealizationTarget(os: os, platform: platformTarget, isHost: true)
  else:
    realizationTargetFor(cpu, os, baselineMicroarchLevel(cpu))

proc adapterPreferenceKey*(os: PlatformOs): string =
  ## The ``adapterPreference:`` key for a target OS (the DSL canonicalizes
  ## ``macos`` to ``darwin``).
  case os
  of poWindows: "windows"
  of poLinux: "linux"
  of poMacos: "darwin"
  of poAny: ""

proc selectionPolicyFor*(adapterPreference: OrderedTable[string, seq[string]];
                         os: PlatformOs):
    tuple[policy: SelectionPolicy; source: string] =
  ## The selection policy for a target OS: the profile's
  ## ``adapterPreference:`` entry for it, else ``DefaultSelectionPolicy``
  ## (the same on every platform). An empty entry counts as absent. An
  ## unknown kind is refused — the DSL parsers reject it first, so reaching
  ## here with one is a bug.
  let key = adapterPreferenceKey(os)
  if key.len > 0 and key in adapterPreference and
      adapterPreference[key].len > 0:
    for name in adapterPreference[key]:
      let parsed = parseRealizationKind(name)
      if not parsed.ok and name.strip().toLowerAscii() in
          ["homebrew", "brew", "brewcask", "brewformula"]:
        # Not a typo: Homebrew is a contribution kind, but only as a BRIDGE
        # record that consumers installing through Homebrew read (the Nix
        # helper library). Reprobuild has no Homebrew realizer, so a policy
        # naming it is refused with that reason rather than as an unknown
        # word (Provisioning-Contributions.md §"Homebrew bridge records").
        raise newException(ValueError,
          "adapterPreference." & key & " names '" & name & "': Homebrew " &
          "contribution records are bridge records read by Nix consumers; " &
          "Reprobuild does not realize packages through Homebrew " &
          "(known kinds: tarball, builtin, nix, scoop, path)")
      if not parsed.ok:
        raise newException(ValueError,
          "adapterPreference." & key & " names unknown realization kind '" &
          name & "' (known: tarball, builtin, nix, scoop, path)")
      if parsed.kind notin result.policy:
        result.policy.add(parsed.kind)
    result.source = "adapterPreference." & key
  else:
    result.policy = DefaultSelectionPolicy
    result.source = "default"

# ---------------------------------------------------------------------------
# Candidates: the reference projected as a `uses:`
# ---------------------------------------------------------------------------

const ProfileProjectionPackage = "repro-home-profile"
  ## The synthetic package a profile reference is a ``uses:`` of.

proc profileToolUse*(packageId: string;
                     catalog = ProfileCatalog()):
    tuple[useDef: InterfaceToolUse; known: bool] =
  ## Project ``package "<packageId>"`` exactly as interface extraction
  ## projects ``uses: "<packageId>"`` (``toProjectInterface``): the canonical
  ## definitions of that name with their in-package realizations, plus every
  ## registered contribution targeting it whose interface fingerprint
  ## matches. ``known`` says whether a definition of the name was found.
  ##
  ## The definitions are found in ``usesImportCode``'s order: a bundled
  ## stdlib selector is the linked stdlib definition; otherwise a definition
  ## in the ``reprobuild-packages`` catalog (``catalog``, projected by
  ## ``catalog_projection`` from the profile's location) wins; otherwise the
  ## other stdlib definitions the engine links (the former catalog packages,
  ## which a recipe reaches through an explicit import).
  ##
  ## When the profile imports contribution catalogs (``catalogs:``), every
  ## reference with a definition in scope is in ``catalog`` -- bundled ones
  ## included -- projected by a recipe that imports those catalogs, so the
  ## contributions they register are candidates exactly as for that recipe.
  ## Without imports a bundled selector never is, and resolves from the
  ## linked definition below.
  if packageId in catalog.failures:
    raise newException(ValueError, catalog.failures[packageId])
  if packageId in catalog.uses:
    var use = catalog.uses[packageId]
    use.location = SourceLocation(file: "home-profile", line: 1)
    return (use, true)
  var home = PackageDef(packageName: ProfileProjectionPackage,
    sourceFile: "home-profile", sourceLine: 1)
  home.toolUses.add(PackageUseDef(rawConstraint: packageId,
    packageSelector: packageId, executableName: packageId,
    sourceFile: "home-profile", sourceLine: 1))
  var contributions: seq[ProvisioningContributionDef] = @[]
  for contribution in registeredProvisioningContributions():
    if contribution.targetPackage == packageId:
      contributions.add(contribution)
  let projected = toProjectInterface(home, registeredPackages(),
    contributions)
  (projected.toolUses[0], isLinkedPackage(packageId))

proc narrowedTo(useDef: InterfaceToolUse; selection: RealizationSelection):
    InterfaceToolUse =
  result = useDef
  result.nixProvisioning = @[]
  result.tarballProvisioning = @[]
  result.scoopProvisioning = @[]
  if selection.ambient:
    return
  case selection.kind
  of rkNix: result.nixProvisioning = @[selection.nix]
  of rkTarball: result.tarballProvisioning = @[selection.tarball]
  of rkScoop: result.scoopProvisioning = @[selection.scoop]
  of rkPath: discard

# ---------------------------------------------------------------------------
# Archive realization inputs
# ---------------------------------------------------------------------------

const
  MacosPkgInstallRefusal* =
    "no system-scope realizer runs macOS installer packages yet"
    ## The reason a ``pkg-install`` record is refused, quoted verbatim in the
    ## refusal so tests and callers can recognise it.

proc refuseUnrealizableMacosShape(packageId: string;
                                  record: InterfaceTarballProvisioning) =
  ## GM4c: the macOS vendor shapes a contribution may DECLARE but nothing
  ## realizes (Store-And-Installation-Layout.md § macOS Application Bundles,
  ## "Shapes this does not cover"), and the application shapes declared for
  ## another os. Refused at resolution, so ``--plan`` names the reason
  ## before anything is downloaded. A macOS ``installer-silent`` record is
  ## an installer application and IS realized (§ Installer applications);
  ## ``archiveRealizationOf`` refuses one that lacks a field the realizer
  ## verifies.
  let detail = record.detail
  let os = parsePlatformOsToken(record.os)
  let macos = os.ok and os.os == poMacos
  if detail.installMethod == $imPkgInstall:
    raise newException(ValueError,
      "the tarball realization of package '" & packageId & "' (" &
      record.url & ") is an installer package that must be run as root " &
      "(installMethod pkg-install): its scripts and privileged components " &
      "are what install the product, which makes it system scope (P3). " &
      "A home profile cannot realize it, and " & MacosPkgInstallRefusal &
      ". Install it outside Reprobuild until one does.")
  if detail.installMethod == $imAppBundle and not macos:
    raise newException(ValueError,
      "the tarball realization of package '" & packageId & "' (" &
      record.url & ") declares installMethod app-bundle for os '" &
      record.os & "'; an application bundle is a macOS realization")
  if detail.installerApp.len > 0 and not macos:
    raise newException(ValueError,
      "the tarball realization of package '" & packageId & "' (" &
      record.url & ") names the installer application " &
      detail.installerApp.escape & " for os '" & record.os & "'; an " &
      "installer application is a macOS realization")

proc archiveRouteFor*(packageId: string;
                      record: InterfaceTarballProvisioning): ArchiveRoute =
  ## Route a selected ``tarball`` record to the realizer that performs
  ## everything it asks for. A record that asks for work only one realizer
  ## does AND work only the other does has no realizer; it is refused, as
  ## is a declared macOS shape nothing realizes.
  refuseUnrealizableMacosShape(packageId, record)
  let installer = archiveInstallerFeatures(record)
  if installer.len == 0:
    return arExtract
  let extractOnly = extractRealizerFeatures(record)
  if extractOnly.len > 0:
    raise newException(ValueError,
      "the tarball realization of package '" & packageId & "' (" &
      record.url & ") needs " & installer.join(", ") &
      ", which only the home archive realizer performs, and " &
      extractOnly.join(", ") & ", which only the `uses:` provisioning edge " &
      "performs; no realizer can realize it")
  arInstaller

proc archiveRealizationOf*(packageId: string;
                           record: InterfaceTarballProvisioning):
    ArchiveRealization =
  ## Project a selected ``tarball`` record into the home archive realizer's
  ## input. Every field is decoded strictly: an archive format, install
  ## method, pre-install step or launcher spec the realizer cannot read is a
  ## refusal, not a default.
  let detail = record.detail
  result.packageId = packageId
  result.app = packageId
  result.resolvedVersion = detail.version
  result.builtinVersion = detail.version
  let level = parseMicroarchLevelToken(detail.cpuLevel)
  let features = parseCpuFeatureSet(detail.cpuFeatures)
  if not level.ok or not features.ok:
    raise newException(ValueError, "package '" & packageId &
      "': unreadable cpuLevel/cpuFeatures on " & record.url)
  result.builtinCpuLevel = level.level
  result.builtinCpuFeatures = features.features
  result.resolvedTarget = renderResolvedTarget(level.level, features.features)
  result.urlUsed = record.url
  if record.sha256.len > 0:
    result.digestAlgorithm = "sha256"
    result.digestValue = normalizedHexDigest(record.sha256, "sha256")
  elif detail.sha512.len > 0:
    result.digestAlgorithm = "sha512"
    result.digestValue = normalizedHexDigest(detail.sha512, "sha512")
  elif detail.sha1.len > 0:
    result.digestAlgorithm = "sha1"
    result.digestValue = normalizedHexDigest(detail.sha1, "sha1")
  else:
    raise newException(ValueError, "package '" & packageId &
      "': the tarball realization " & record.url & " names no digest")
  let format = parseArchiveFormatToken(record.archiveType)
  if not format.ok:
    raise newException(ValueError, "package '" & packageId &
      "': archive type '" & record.archiveType & "' is not one the home " &
      "archive realizer reads")
  result.archiveFormat = format.format
  let installMethod = parseInstallMethodToken(detail.installMethod)
  if not installMethod.ok:
    raise newException(ValueError, "package '" & packageId &
      "': unknown installMethod '" & detail.installMethod & "'")
  result.installMethod = installMethod.installMethod
  result.binRelpath = @[record.executablePath] & detail.extraExecutables
  result.extractPath = detail.extractPath
  result.installerArgs = detail.installerArgs
  result.pacmanPackages = detail.pacmanPackages
  result.bootstrapArgv = detail.bootstrapArgv
  var env: seq[tuple[name, value: string]] = @[]
  for binding in detail.env:
    let eq = binding.find('=')
    if eq <= 0:
      raise newException(ValueError, "package '" & packageId &
        "': env binding " & binding.escape() & " is not NAME=value")
    env.add((name: binding[0 ..< eq], value: binding[eq + 1 .. ^1]))
  # Stable order: by name, so the realize loop's output is deterministic.
  for i in 0 ..< env.len:
    for j in i + 1 ..< env.len:
      if env[j].name < env[i].name:
        swap(env[i], env[j])
  result.envSubstitutions = env
  result.nested7z = detail.nested7z
  result.msiAdminInstall = detail.msiAdminInstall
  for encoded in detail.preInstall:
    result.preInstallActions.add(decodePreInstallAction(encoded))
  result.preInstallUnrecognized = detail.preInstallUnrecognized
  for encoded in detail.launcherEmit:
    result.launcherEmit.add(decodeLauncherEmitSpec(encoded))
  result.appBundle = detail.appBundle
  result.bundleId = detail.bundleId
  result.teamId = detail.teamId
  result.installerApp = detail.installerApp
  if result.installMethod == imInstallerSilent and
      (result.installerApp.len > 0 or result.appBundle.len > 0 or
       result.bundleId.len > 0 or result.teamId.len > 0):
    # An installer-silent record that names an installer application or
    # any application field is a macOS installer APPLICATION
    # (Store-And-Installation-Layout.md § Installer applications): the
    # realizer verifies the installer against teamId and the product it
    # produced against appBundle / bundleId / version / teamId, so a record
    # missing any of them cannot be realized. One that names none of them
    # is a Windows installer (NSIS / MSI), realized as before.
    var missing: seq[string] = @[]
    if result.installerApp.len == 0: missing.add("installerApp")
    if result.appBundle.len == 0: missing.add("appBundle")
    if result.bundleId.len == 0: missing.add("bundleId")
    if result.teamId.len == 0: missing.add("teamId")
    if result.builtinVersion.len == 0: missing.add("version")
    if missing.len > 0:
      raise newException(ValueError, "package '" & packageId &
        "': the tarball realization " & record.url & " is a macOS " &
        "installer application (installMethod installer-silent) and must " &
        "declare installerApp (the installer's path inside the archive), " &
        "appBundle (the product bundle in the installed prefix), bundleId, " &
        "teamId and version; it lacks " & missing.join(", "))
    # The paths the realizer walks, checked before anything is downloaded
    # (§ Installer applications, "Declaring it"): the product path has one
    # or two components and the first is the placed item, never a bundle
    # holding another; the installer is a bundle inside the archive.
    let productError = installerProductPathError(result.appBundle)
    if productError.len > 0:
      raise newException(ValueError, "package '" & packageId &
        "': the installer application " & record.url & " declares " &
        "appBundle " & result.appBundle.escape & ", the product bundle in " &
        "the installed prefix; " & productError)
    let installerPath = result.installerApp.replace('\\', '/')
    var installerOk = not installerPath.startsWith("/") and
      installerPath.endsWith(".app")
    for part in installerPath.split('/'):
      if part.len == 0 or part == "." or part == "..":
        installerOk = false
    if not installerOk:
      raise newException(ValueError, "package '" & packageId &
        "': the installer application " & record.url & " declares " &
        "installerApp " & result.installerApp.escape & "; it must be a " &
        "relative path inside the archive naming a .app bundle")
    if result.archiveFormat notin {afDmg, afZip, afTarGz, afTarXz,
        afTarBz2}:
      raise newException(ValueError, "package '" & packageId &
        "': the installer application " & record.url & " is delivered " &
        "as " & $result.archiveFormat & "; an installer application is " &
        "copied out of a dmg, zip, tar.gz, tar.xz or tar.bz2 (a flat " &
        "installer package that must run is installMethod pkg-install)")
  if result.installMethod == imAppBundle and (result.appBundle.len == 0 or
      result.bundleId.len == 0 or result.teamId.len == 0 or
      result.builtinVersion.len == 0):
    raise newException(ValueError, "package '" & packageId &
      "': the app-bundle realization " & record.url & " must declare " &
      "appBundle, bundleId, teamId and version (the bundle's " &
      "CFBundleShortVersionString); realization verifies all four")
  # ``executablePath`` is a TARGET-platform path (``bin\gh.exe`` for a
  # Windows record); split on both separators so the leaf is right whichever
  # platform the resolution runs on.
  result.executableName = record.executablePath.split({'/', '\\'})[^1]

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

proc resolveProfilePackage*(packageId: string;
                            target: RealizationTarget;
                            policy: SelectionPolicy;
                            requestedVersion = "";
                            binaries: seq[string] = @[];
                            contributor = none(string);
                            inventory = HostInventory();
                            scoop: ScoopHostInventory = nil;
                            availability = none(PackageAvailability);
                            lockIdentity = "";
                            catalog = ProfileCatalog()):
    ProfilePackageResolution =
  ## Resolve one profile package reference for ``target`` under ``policy``.
  ##
  ## Raises the selection errors of ``realization_selection``
  ## (``EPlatformUnavailable``, ``EAmbiguousRealization``,
  ## ``EMissingRealization``) and ``ValueError`` for a selected record no
  ## realizer can realize. ``availability`` overrides the registry lookup
  ## for tests that need a declaration without a linked definition;
  ## ``scoop`` supplies the cache-hit verdict for a declared Scoop
  ## realization on a Windows host. ``lockIdentity`` pins the exact
  ## realization a home-profile lock recorded (``SelectionRequest``).
  ## ``catalog`` carries the references the ``reprobuild-packages`` catalog
  ## defines (``projectCatalogPackages``); a resolution without one sees the
  ## linked definitions only.
  let projected = profileToolUse(packageId, catalog)
  let useDef = projected.useDef
  var probeNames = binaries
  if probeNames.len == 0:
    probeNames = @[if useDef.executableName.len > 0: useDef.executableName
                   else: packageId]
  let request = SelectionRequest(
    packageName: packageId,
    target: target,
    policy: policy,
    version: requestedVersion,
    contributor: contributor,
    lockIdentity: lockIdentity,
    availability:
      if availability.isSome: availability.get
      else: packageAvailability(packageId),
    probeNames: probeNames,
    definitionKnown: projected.known,
    inventory: inventory)
  let selection = selectRealization(useDef, request)
  result.packageId = packageId
  result.requestedVersion = requestedVersion
  result.selection = selection
  result.useDef = narrowedTo(useDef, selection)
  case selection.kind
  of rkTarball:
    result.archiveRoute = archiveRouteFor(packageId, selection.tarball)
    if result.archiveRoute == arInstaller:
      result.archive = archiveRealizationOf(packageId, selection.tarball)
  of rkPath:
    result.cacheHit = true
  of rkScoop:
    if selection.ambient:
      result.installedVersion =
        if selection.scoopInventory.installed: selection.scoopInventory.version
        else: ""
      result.cacheHit = selection.scoopInventory.installed and
        satisfiesProfile(selection.scoopInventory.version, requestedVersion,
          "")
    elif not scoop.isNil and target.isHost:
      let inst = installedVersion(scoop, selection.scoop.app)
      if inst.installed:
        result.installedVersion = inst.version
        result.cacheHit = satisfiesProfile(inst.version,
          selection.scoop.version, selection.scoop.preferredVersion)
  of rkNix:
    discard

proc offeredVersions*(packageId: string;
                      catalog = ProfileCatalog()): seq[string] =
  ## Every version a linked definition of ``packageId`` (or a contribution
  ## to it) pins a realization at, in declaration order, for any platform.
  ## ``tarball`` records name theirs in ``version``; ``scoopApp`` records in
  ## ``version``; ``nixPackage`` records name none.
  let useDef =
    try: profileToolUse(packageId, catalog).useDef
    except ValueError: return
  for record in useDef.tarballProvisioning:
    if record.detail.version.len > 0 and record.detail.version notin result:
      result.add(record.detail.version)
  for record in useDef.scoopProvisioning:
    if record.version.len > 0 and record.version notin result:
      result.add(record.version)

proc unpinnedHostVersion*(packageId: string;
                          catalog = ProfileCatalog()): Option[string] =
  ## The version an UNPINNED reference to ``packageId`` resolves to on this
  ## host among the versioned kinds (``tarball``, then ``scoop``) — what
  ## ``repro home add <tool>@latest`` writes, so that pinning a reference
  ## does not change which realization it selects. ``none`` when no versioned
  ## realization exists for the host.
  try:
    let resolution = resolveProfilePackage(packageId,
      hostRealizationTarget(), @[rkTarball, rkScoop], catalog = catalog)
    if resolution.selection.version.len > 0:
      return some(resolution.selection.version)
  except CatchableError:
    discard
  none(string)
