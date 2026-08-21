## M68 merge note (hand-edited): the auto-generated ``nimCatalog`` body
## sits below the pre-existing ``package nim:`` DSL block. The DSL
## block remains the source of truth for the Nim CLI surface
## (``nim c`` / ``nim js`` flag declarations) and the Nix
## provisioning shape on Nix-capable hosts; the ``nimCatalog`` slice
## is consumed by the M64 ``cakBuiltin`` adapter on Windows.
## Re-harvest emits ONLY the catalog half; re-attach the DSL block
## by hand if you regenerate.
##
## **Known M69 realize-time gap.** The Scoop manifest carries a
## ``post_install`` PowerShell hook that copies ``dist/nimble/src/nimblepkg``
## into ``bin/`` so ``nimble`` can locate its package definitions at
## runtime. The harvester silently drops the hook (per the module's
## "post_install is deliberately discarded" rule), so cakBuiltin's
## realized prefix will ship ``bin/nimble.exe`` but ``nimble``
## invocations may fail to find ``nimblepkg``. The manifest also
## carries an ``installer.script`` (``Add-Path -Path "$env:USERPROFILE\.nimble\bin"``)
## — a USERPROFILE PATH tweak, not a true installer, so M68's
## refined harvester correctly keeps ``install_method = imExtract``.
##
## **M9.5 merge note (hand-edited):** added a ``(pcX86_64, poLinux)``
## platform slice manually (the Nim upstream publishes prebuilts on
## ``nim-lang.org/download/``, NOT on GitHub Releases — so the M7
## gh-releases harvester doesn't apply). URL pattern:
## ``nim-<ver>-linux_x64.tar.xz``; sha256 lifted from upstream's
## ``.sha256`` sidecar. archive_format_override = afTarXz (Windows is
## afZip); bin_relpath_override drops the .exe suffix. Upstream Nim's
## Linux build targets glibc 2.17+ (the prebuilt is statically linked
## against the c runtime where feasible).

import std/[options, os, sets, strutils, tables]
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# L3 PUBLISH-SCOPE (public-interface publishing for hand-authored
# ``build:`` blocks). ``blake3`` composes the recipe-revision digest;
# ``repro_core`` resolves the recipe file bytes. ``repro_project_dsl``
# re-exports the ``CacheEntryIdentity`` shape + ``publicInterfaceIdentity``
# (cache_key) + the ``registeredVersions`` / ``activeProviderProjectRoot`` /
# ``currentBuild*`` context surface used below.
import blake3
import repro_core

var reproNimPathsEnabled {.threadvar.}: bool
var reproConfigNimsFile {.threadvar.}: string

# ---------------------------------------------------------------------------
# Pre-existing M21 DSL declaration (CLI surface + Nix provisioning).
# ---------------------------------------------------------------------------

package nim:
  provisioning:
    nixPackage "nixpkgs#nim", executablePath = "bin/nim",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows / non-Nix Linux provisioning via Scoop's ScoopInstaller/Main
    # bucket. The bucket version is the source of truth — `preferredVersion`
    # is used here (vs. `version`) so any later 2.2.x publication satisfies
    # the codetracer constraint without forcing a downgrade. The bin path
    # matches `nimCatalog` below (Scoop manifest's first `bin` entry).
    # `requiresExecutionProfileChecksum = false` keeps the engine from
    # demanding a recorded execution-profile when the operator hasn't yet
    # captured one for the host architecture.
    scoopApp(bucket = "main", app = "nim",
      preferredVersion = ">=1.6,<3.0", executablePath = "bin/nim.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download provisioning consumed by --tool-provisioning=tarball.
    # One tarball(...) entry per (cpu, os) slice the package supports.
    # The resolver picks the first entry whose constraints match the
    # build host; entries with cpu/os = "any" (or omitted) match every
    # host and act as a catch-all. URLs + SHAs come straight from
    # nim-lang.org — the same upstream that `nimCatalog` below
    # harvests from.
    tarball url = "https://nim-lang.org/download/nim-2.2.10_x64.zip",
      sha256 = "fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/nim.exe",
      packageId = "nim@2.2.10",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:nim@2.2.10:sha256:fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f"
    tarball url = "https://nim-lang.org/download/nim-2.2.10-linux_x64.tar.xz",
      sha256 = "0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/nim",
      packageId = "nim@2.2.10",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:nim@2.2.10:linux:sha256:0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211"
    tarball url = "https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-macosx_arm64.tar.xz",
      sha256 = "9a3b012d0680d11d6163dd2f145470b090c1045f5e634f42daf119bea1cb2b5e",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/nim",
      packageId = "nim@2.2.10",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:nim@2.2.10:macos-aarch64:sha256:9a3b012d0680d11d6163dd2f145470b090c1045f5e634f42daf119bea1cb2b5e"
    tarball url = "https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-macosx_x64.tar.xz",
      sha256 = "35df59b9bbe9f5dfcdf40a82b41037e6ac499e2ec0be6688cd3dd0e55c8bc851",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/nim",
      packageId = "nim@2.2.10",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:nim@2.2.10:macos-x86_64:sha256:35df59b9bbe9f5dfcdf40a82b41037e6ac499e2ec0be6688cd3dd0e55c8bc851"

  executable nim:
    cli:
      dependencyPolicy automaticMonitor

      subcmd "c":
        flag defines is seq[string],
          alias = "-d:",
          format = concat,
          repeated = true
        flag mm is string,
          alias = "--mm:",
          format = concat
        # Windows-Cacheable-Builds-Session-Residuals S1: ``--cpu:`` makes a
        # cross-bitness compile expressible in the DSL. The Windows monitor
        # stack needs a 32-bit shim (``librepro_monitor_shim32.dll``) and a
        # 32-bit WOW64 probe beside the 64-bit shim; without a typed ``cpu``
        # flag those two artefacts could only be produced by shelling out to
        # ``io-mon/scripts/build_shim.sh``, which is neither cacheable nor
        # described by the graph. The flag is generic - every other
        # cross-compile target (``--cpu:arm64``, ``--cpu:amd64``) goes through
        # the same declaration.
        flag cpu is string,
          alias = "--cpu:",
          format = concat
        flag cc is string,
          alias = "--cc:",
          format = concat
        flag gccExe is string,
          alias = "--gcc.exe:",
          format = concat
        # ``--gcc.exe:`` selects the COMPILER driver only; nim keeps invoking
        # whatever ``gcc.linkerexe`` names (default: a bare ``gcc`` resolved
        # off PATH) for the link step. A cross-bitness build that sets only
        # ``gccExe`` therefore compiles 32-bit objects and then hands them to
        # the host's 64-bit linker. Both have to be named.
        flag gccLinkerExe is string,
          alias = "--gcc.linkerexe:",
          format = concat
        boolFlag threadsOn is bool, alias = "--threads:on"
        flag parallelBuild is int,
          alias = "--parallelBuild:",
          format = concat
        # Test-Fixtures-In-Build-Graph M2: ``--app:lib`` produces a shared
        # library (``.so`` / ``.dylib`` / ``.dll``) rather than an
        # executable. The monitor shim (``repro_monitor_shim``) is built
        # this way; expressing it as a typed flag lets the shim become a
        # graph edge (the ``test-fixtures`` collection in ``repro.nim``)
        # instead of a per-test runtime ``nim c --app:lib`` shell-out.
        boolFlag appLib is bool, alias = "--app:lib"
        boolFlag hintsOff is bool, alias = "--hints:off"
        boolFlag warningsOff is bool, alias = "--warnings:off"
        flag disabledHints is seq[string],
          alias = "--hint[",
          format = concat,
          repeated = true
        flag disabledWarnings is seq[string],
          alias = "--warning[",
          format = concat,
          repeated = true
        boolFlag debugInfo is bool, alias = "--debugInfo"
        boolFlag lineDirOn is bool, alias = "--lineDir:on"
        boolFlag stacktraceOn is bool, alias = "--stacktrace:on"
        boolFlag linetraceOn is bool, alias = "--linetrace:on"
        boolFlag hintsOn is bool, alias = "--hints:on"
        boolFlag warningsOn is bool, alias = "--warnings:on"
        boolFlag boundChecksOn is bool, alias = "--boundChecks:on"
        flag dynlibOverrides is seq[string],
          alias = "--dynlibOverride:",
          format = concat,
          repeated = true
        # Windows: project files (e.g. codetracer/reprobuild.nim) need to pass
        # -I/-L/-Wno-* flags to the C backend so the bundled libzip C sources
        # compile under MinGW UCRT (getpid implicit decl + missing system zlib).
        flag passC is seq[string],
          alias = "--passC:",
          format = concat,
          repeated = true
        flag passL is seq[string],
          alias = "--passL:",
          format = concat,
          repeated = true
        flag nimcache is string,
          alias = "--nimcache:",
          format = concat
        flag output is string,
          alias = "--out:",
          format = concat,
          role = output,
          required = true
        flag paths is seq[string],
          alias = "--path:",
          format = concat,
          repeated = true
        pos source is string,
          role = input,
          position = 0

        # Named-Targets M0: the primary output flag for ``nim c`` is
        # ``--out:`` (the existing typed-tool wrapper exposes it as
        # ``output``). M1 consumes this to derive an implicit target
        # name per build edge.
        outputs output

      subcmd "js":
        flag defines is seq[string],
          alias = "-d:",
          format = concat,
          repeated = true
        flag mm is string,
          alias = "--mm:",
          format = concat
        boolFlag hintsOff is bool, alias = "--hints:off"
        boolFlag warningsOff is bool, alias = "--warnings:off"
        flag disabledHints is seq[string],
          alias = "--hint[",
          format = concat,
          repeated = true
        flag disabledWarnings is seq[string],
          alias = "--warning[",
          format = concat,
          repeated = true
        boolFlag debugInfo is bool, alias = "--debugInfo"
        boolFlag lineDirOn is bool, alias = "--lineDir:on"
        boolFlag stacktraceOn is bool, alias = "--stacktrace:on"
        boolFlag linetraceOn is bool, alias = "--linetrace:on"
        boolFlag debugInfoOn is bool, alias = "--debugInfo:on"
        boolFlag sourcemapOn is bool, alias = "--sourcemap:on"
        boolFlag hotCodeReloadingOn is bool, alias = "--hotCodeReloading:on"
        flag output is string,
          alias = "--out:",
          format = concat,
          role = output,
          required = true
        flag paths is seq[string],
          alias = "--path:",
          format = concat,
          repeated = true
        pos source is string,
          role = input,
          position = 0

        # Named-Targets M0: same convention as ``subcmd "c"`` — the
        # ``--out:`` flag value supplies the implicit target name.
        outputs output

# ---------------------------------------------------------------------------
# Spec-Implementation M1 — fixture-friendly ``binary`` alias.
#
# Spec-example fixtures at ``reprobuild/tests/fixtures/spec-examples/``
# use ``nim.c(source = ..., binary = "build/bin/foo", ...)`` instead of
# the typed-tool's verbatim ``output`` flag. The shorthand below maps
# ``binary`` onto the wrapper's ``output`` flag so the fixtures
# compile without rewriting their DSL surface. Long-form
# ``nim.c(..., output = ...)`` continues to work; only the alias is
# additive. The cross-cutting ``Toolchain`` interface in M3 will
# subsume this alias.
# ---------------------------------------------------------------------------

proc defaultNimcacheDir(binary: string): string =
  let outputName = splitFile(binary).name
  if outputName.len > 0:
    result = "build" / "nimcache" / outputName
  else:
    result = "build" / "nimcache" / "nim-output"

proc usesSslDefine(defines: openArray[string]): bool =
  for define in defines:
    if define == "ssl" or define == "-d:ssl" or define == "--define:ssl":
      return true

proc opensslPassLForSsl(defines: openArray[string]): seq[string] =
  if usesSslDefine(defines):
    result = @["-lssl", "-lcrypto"]

proc compileDependencyPolicy(cacheDir: string;
                             cacheable: bool;
                             policy: BuildActionDependencyPolicy):
    BuildActionDependencyPolicy =
  if policy.kind != bdpDefault:
    return policy
  if cacheable:
    return defaultDependencyPolicy()
  makeDepfilePolicy(cacheDir / "nim-compile.d")

# ---------------------------------------------------------------------------
# L3 PUBLISH-SCOPE — public-interface publishing for hand-authored
# ``build:`` blocks.
#
# The from-source + Nim/Crystal AUTO conventions tag their final
# materialising action with ``publishToBinaryCache = true`` and a
# ``cacheEntryIdentity`` so the engine's binary-cache publisher hook
# fires. Hand-authored recipes drive their build through the ``nim.c``
# alias (below) inside an artifact-scoped ``build:`` block:
#
#   package ct:
#     executable ct:
#       build:
#         nim.c(source = "src/ct.nim", binary = "ct")
#
# The ``build:`` macro pushes an active-context frame carrying the
# owning ``(package, artifact)`` while the body runs. When the ``nim.c``
# output IS the artifact — i.e. the artifact is a declared
# ``executable``/``library`` (the package's PUBLIC INTERFACE) — the
# alias AUTO-TAGS the link action: the same ``publishToBinaryCache`` +
# ``cacheEntryIdentity`` the conventions stamp, with the identity
# composed off the shared ``publicInterfaceIdentity`` helper so the key
# matches a Nim-convention build of the same member byte-for-byte.
#
# A recipe can also opt in/out explicitly:
#   * ``publish = false`` — suppress the auto-tag even inside a declared
#     artifact (e.g. a scratch helper edge that happens to run there).
#   * ``publishAs = "<member>"`` — publish under a specific declared
#     member's identity (used for package-level ``build:`` blocks, or
#     when the binary basename differs from the member name).
# The default is AUTOMATIC: no recipe change is needed for the common
# case where the artifact name IS the public-interface member.

proc nimRecipeRevisionHex(projectRoot: string): string =
  ## BLAKE3 of the recipe file bytes, truncated to 32 hex chars — the
  ## exact ``providerRevision`` shape ``from_source_identity.
  ## providerRevisionHex`` produces, so a build-block publish and a
  ## Nim-convention publish of the same member derive an identical key.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  let bodyStr =
    try: readFile(extendedPath(match.path))
    except CatchableError: ""
  if bodyStr.len == 0:
    return ""
  let dig = blake3.digest(bodyStr)
  let full = blake3.toHex(dig)
  if full.len >= 32: full[0 ..< 32] else: full

proc nimMemberIsPublicInterface(packageName, memberName: string): bool =
  ## True when ``memberName`` is a declared ``executable``/``library`` of
  ## ``packageName`` — i.e. part of the package's PUBLIC INTERFACE. The
  ## artifact registry is populated by the ``package`` macro's M3
  ## ``executable:``/``library:`` lowering; ``files:`` artifacts are NOT
  ## public interface and are excluded.
  if packageName.len == 0 or memberName.len == 0:
    return false
  for artifact in registeredArtifacts(packageName):
    if artifact.artifactName == memberName and
        artifact.kind in {dakExecutable, dakLibrary}:
      return true
  false

proc nimPublicInterfaceIdentity(packageName, memberName: string):
    CacheEntryIdentity =
  ## Compose the publish identity for one declared public-interface
  ## member. ``packageName`` here is the MEMBER name (the granularity the
  ## Nim convention uses — each member materialises a distinct reusable
  ## artefact into the store), the toolchain tag is ``"nim"``, and the
  ## version is the recipe's last ``versions:`` entry (empty when the
  ## recipe carries no ``versions:`` block).
  let versionStr = block:
    var v = ""
    let vs = registeredVersions(packageName)
    if vs.len > 0:
      v = vs[^1].version
    v
  publicInterfaceIdentity(
    packageName = memberName,
    packageVersion = versionStr,
    toolchainName = "nim",
    providerRevision = nimRecipeRevisionHex(activeProviderProjectRoot()))

proc maybeTagPublicInterface(action: BuildActionDef;
                             publish: Option[bool]; publishAs: string) =
  ## Decide + apply the L3 publish tag for a ``nim.c`` edge, in place on
  ## the just-registered action. ``publish``/``publishAs`` are the
  ## explicit overrides; when unset the alias auto-associates the active
  ## artifact frame with a declared public-interface member.
  if publish.isSome and not publish.get():
    return   # explicit opt-out.
  let explicit = publish.isSome and publish.get()
  let frame = currentBuildContextFrame()
  let pkg = frame.packageName
  # Which member does this edge materialise?  Explicit ``publishAs`` wins;
  # otherwise the active artifact frame (the ``executable``/``library``
  # the ``build:`` block is nested inside).
  let member = if publishAs.len > 0: publishAs else: frame.artifactName
  if pkg.len == 0 or member.len == 0:
    # No active package/artifact context (e.g. a bare ``nim.c`` outside
    # any artifact ``build:`` block, with no ``publishAs``). Nothing to
    # attribute the publish to — stay inert.
    return
  # AUTO path: only tag when the member is genuinely part of the
  # package's declared public interface. EXPLICIT ``publish = true`` (or
  # a caller-named ``publishAs``) trusts the recipe author and publishes
  # under that member's identity regardless.
  if not explicit and publishAs.len == 0 and
      not nimMemberIsPublicInterface(pkg, member):
    return
  setRegisteredActionPublish(action.id, true,
    some(nimPublicInterfaceIdentity(pkg, member)))

proc c*(pkg: NimPackage; source: string; binary: string;
        defines: seq[string] = @[];
        paths: seq[string] = @[];
        imports: seq[string] = @[];
        cpu = "";
        cc = "";
        gccExe = "";
        gccLinkerExe = "";
        mm = "";
        passC: seq[string] = @[];
        passL: seq[string] = @[];
        nimcache = "";
        appLib = false;
        threadsOn = false;
        parallelBuild = 0;
        actionId = "";
        deps: openArray[string] = [];
        after: openArray[BuildActionDef] = [];
        extraInputs: openArray[string] = [];
        extraOutputs: openArray[string] = [];
        extraEnv: openArray[(string, string)] = [];
        depfile = "";
        cacheable = true;
        publish = none(bool);
        publishAs = "";
        dependencyPolicy = defaultDependencyPolicy();
        actionCachePolicy = defaultActionCachePolicy();
        commandStatsId = ""): BuildActionDef
    {.discardable.} =
  ## Test-Fixtures-In-Build-Graph M2: ``appLib`` / ``threadsOn`` were
  ## added to the convenience alias so the monitor-shim fixture edge in
  ## ``repro.nim`` can express ``nim c --app:lib --threads:on`` and
  ## backend ``--passC:`` / ``--passL:`` flags through the
  ## ``binary``-shorthand surface the rest of the build block uses.
  ##
  ## Windows-Cacheable-Builds-Session-Residuals S1: ``cpu`` / ``gccLinkerExe``
  ## make a cross-bitness compile expressible through this shorthand - the
  ## 32-bit monitor shim and WOW64 probe are ordinary graph edges rather than
  ## a shell-out to ``io-mon/scripts/build_shim.sh``. Give every ``cpu``-varying
  ## edge its OWN ``nimcache``: nim keys the cache directory by nothing but the
  ## path it is handed, so two bitnesses sharing one would link 32-bit objects
  ## into a 64-bit image.
  ##
  ## L3 PUBLISH-SCOPE: ``publish`` / ``publishAs`` control binary-cache
  ## publication of the resulting artifact (see the block comment above).
  ## By default (``publish`` unset) the alias auto-tags the edge when it
  ## runs inside a declared ``executable``/``library`` ``build:`` block,
  ## so a hand-authored recipe's public-interface binaries publish with
  ## no extra ceremony.
  discard imports
  # Windows: nim appends `.exe` to an executable regardless of what `--out:`
  # says, so a recipe that writes `binary = "build/bin/foo"` produces
  # `build/bin/foo.exe`. The `output` flag is `role = output` and is what
  # `outputs output` declares, so leaving it unsuffixed declares a file that
  # never exists.
  #
  # The cost was not cosmetic. The engine could not find the declared output,
  # so it could not capture it into the CAS -- every record was published
  # without payloads -- and the outputs-present fast path could not fire
  # either. A cache lookup whose fingerprint matched then failed on "cache
  # record does not contain output payloads" and re-ran. Every nim executable
  # edge on Windows was permanently uncacheable for this reason alone.
  #
  # `--out:foo.exe` produces exactly `foo.exe`, so naming the real file keeps
  # the argv and the declared output in agreement. Library edges are left
  # alone: `--app:lib` yields `.dll`, and the recipes that use it already
  # spell the extension out.
  let effectiveBinary =
    when defined(windows):
      if appLib or binary.len == 0 or binary.endsWith(".exe") or
          binary.endsWith(".dll"):
        binary
      else:
        binary & ".exe"
    else:
      binary
  let cacheDir = if nimcache.len > 0: nimcache else: defaultNimcacheDir(binary)
  let effectivePassL = passL & opensslPassLForSsl(defines)
  var inputs = @extraInputs
  if reproNimPathsEnabled and reproConfigNimsFile.len > 0:
    inputs.add(reproConfigNimsFile)

  result = c(pkg = pkg, source = source, output = effectiveBinary,
    defines = defines,
    cpu = cpu, cc = cc, gccExe = gccExe, gccLinkerExe = gccLinkerExe, mm = mm,
    paths = paths, passC = passC, passL = effectivePassL, nimcache = cacheDir,
    appLib = appLib, threadsOn = threadsOn, parallelBuild = parallelBuild,
    actionId = actionId,
    deps = deps, after = after, extraInputs = inputs,
    extraOutputs = extraOutputs, extraEnv = extraEnv,
    depfile = depfile, cacheable = cacheable,
    dependencyPolicy = compileDependencyPolicy(
      cacheDir, cacheable, dependencyPolicy),
    actionCachePolicy = actionCachePolicy,
    commandStatsId = commandStatsId)
  if usesSslDefine(defines):
    # The OpenSSL profile supplies the platform-specific library directories;
    # the linker arguments above intentionally contain no host paths.
    appendRegisteredActionToolIdentityRefs(result.id, ["openssl"])
  maybeTagPublicInterface(result, publish, publishAs)

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 2.2.10
# ---------------------------------------------------------------------------

let nimCatalog* = @[
  VersionedProvisioning(
    version: "2.2.10",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["bin\\atlas.exe", "bin\\nim.exe", "bin\\nimble.exe", "bin\\nimgrab.exe", "bin\\nimgrep.exe", "bin\\nimpretty.exe", "bin\\nimsuggest.exe", "bin\\vccexe.exe", "bin\\testament.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://nim-lang.org/download/nim-2.2.10_x64.zip", sha256: "fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f", sha512: "", extract_path: "nim-2.2.10"),
      # M9.5: Linux x86_64 slice. Upstream nim-lang.org Linux prebuilt;
      # the inner dir is ``nim-<ver>/`` (same convention as Windows);
      # archive_format_override = afTarXz; binaries lack .exe.
      PlatformBinary(cpu: pcX86_64, os: poLinux, url: "https://nim-lang.org/download/nim-2.2.10-linux_x64.tar.xz", sha256: "0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211", sha512: "", sha1: "", extract_path: "nim-2.2.10", archive_format_override: afTarXz, has_archive_format_override: true, bin_relpath_override: @["bin/atlas", "bin/nim", "bin/nimble", "bin/nimgrab", "bin/nimgrep", "bin/nimpretty", "bin/nimsuggest", "bin/testament"]),
      PlatformBinary(cpu: pcAArch64, os: poMacos, url: "https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-macosx_arm64.tar.xz", sha256: "9a3b012d0680d11d6163dd2f145470b090c1045f5e634f42daf119bea1cb2b5e", sha512: "", sha1: "", extract_path: "nim-2.2.10", archive_format_override: afTarXz, has_archive_format_override: true, bin_relpath_override: @["bin/atlas", "bin/nim", "bin/nimble", "bin/nimgrab", "bin/nimgrep", "bin/nimpretty", "bin/nimsuggest", "bin/testament"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos, url: "https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-macosx_x64.tar.xz", sha256: "35df59b9bbe9f5dfcdf40a82b41037e6ac499e2ec0be6688cd3dd0e55c8bc851", sha512: "", sha1: "", extract_path: "nim-2.2.10", archive_format_override: afTarXz, has_archive_format_override: true, bin_relpath_override: @["bin/atlas", "bin/nim", "bin/nimble", "bin/nimgrab", "bin/nimgrep", "bin/nimpretty", "bin/nimsuggest", "bin/testament"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]


# NOTE: named ``nimPackage`` (not ``package``) on purpose. A recipe that does
# ``import repro_dsl_stdlib/packages/nim as nim_pkg`` still brings this module's
# exported symbols into scope UNQUALIFIED (Nim's ``as`` only renames the
# qualified path, it does not hide unqualified access). A bare ``package`` proc
# here therefore shadow-collides with the core ``package`` MACRO from
# ``repro_project_dsl``: on ``package <name>:`` Nim eagerly typechecks this
# proc's ``NimPackage`` first argument against the bare identifier and fails
# with "undeclared identifier: '<name>'". Keeping a distinct name avoids the
# collision for every recipe that imports this module.
proc nimPackage*(pkg: NimPackage; name: string; srcDir = "src"): BuildTargetDef {.discardable.} =
  result = target(name, actions = @[])
  let absSrcDir = absolutePath(srcDir).replace('\\', '/')
  registerBuildTargetExtension(name, NimPackageExtension(
    name: name,
    srcDir: absSrcDir
  ))

proc resolveNimPackagePaths(): seq[string] =
  let activePkg = currentOwningPackage()
  var depNames = initHashSet[string]()
  if activePkg.len > 0:
    for edge in registeredWorkspaceDeps():
      if cmpIgnoreCase(edge.package, activePkg) == 0:
        depNames.incl(edge.dependency)
    for pkg in registeredPackages():
      if cmpIgnoreCase(pkg.packageName, activePkg) == 0:
        for u in pkg.toolUses:
          depNames.incl(u.packageSelector)
        for u in pkg.nativeBuildDeps:
          depNames.incl(u.packageSelector)
        for u in pkg.runtimeDeps:
          depNames.incl(u.packageSelector)
  
  var seenPaths = initHashSet[string]()
  for target in registeredBuildTargets():
    let ext = retrieveExtension[NimPackageExtension](target)
    if ext.isSome:
      let pkgExt = ext.get()
      if depNames.contains(pkgExt.name) or depNames.contains(target.name):
        if not seenPaths.contains(pkgExt.srcDir):
          seenPaths.incl(pkgExt.srcDir)
          result.add(pkgExt.srcDir)
  for target in registeredCollections():
    let ext = retrieveExtension[NimPackageExtension](target)
    if ext.isSome:
      let pkgExt = ext.get()
      if depNames.contains(pkgExt.name) or depNames.contains(target.name):
        if not seenPaths.contains(pkgExt.srcDir):
          seenPaths.incl(pkgExt.srcDir)
          result.add(pkgExt.srcDir)

  # Check physical sibling directories next to the current project
  let parent = getCurrentDir().parentDir()
  for dep in depNames:
    let siblingDir = parent / dep
    if dirExists(siblingDir):
      let srcDir = (siblingDir / "src").replace('\\', '/')
      if dirExists(srcDir):
        if not seenPaths.contains(srcDir):
          seenPaths.incl(srcDir)
          result.add(srcDir)
      else:
        let rootDir = siblingDir.replace('\\', '/')
        if not seenPaths.contains(rootDir):
          seenPaths.incl(rootDir)
          result.add(rootDir)

proc nimRepropathsConfig*(pkg: NimPackage;
                           reproPathsFile = "repro.paths";
                           gitignoreFile = ".gitignore";
                           configNimsFile = "config.nims"): seq[BuildActionDef] {.discardable.} =
  discard pkg
  reproNimPathsEnabled = true
  reproConfigNimsFile = configNimsFile
  
  let paths = resolveNimPackagePaths()
  var lines: seq[string] = @[]
  for p in paths:
    lines.add("switch(\"path\", \"" & p & "\")")
  let pathsContent = lines.join("\n") & "\n"
  
  let writePathsAction = fs.writeText(reproPathsFile, pathsContent,
    actionId = "generate_nim_paths_" & currentOwningPackage())
  result.add(writePathsAction)
  
  var ignoreFile = gitignoreFile
  if dirExists(getCurrentDir() / ".hg"):
    ignoreFile = ".hgignore"
  let ignoreAction = fs.ensureLine(ignoreFile, reproPathsFile,
    actionId = "ensure_ignore_nim_paths_" & currentOwningPackage())
  result.add(ignoreAction)
  
  let label = "repro-paths-bootstrap"
  let version = "1"
  let openSentinel = "# >>> repro:project:" & currentOwningPackage() & ":" & label & ":v" & version & " >>>"
  let closeSentinel = "# <<< repro:project:" & currentOwningPackage() & ":" & label & ":v" & version & " <<<"
  let openSearch = "# >>> repro:project:" & currentOwningPackage() & ":" & label & ":v"
  let closeSearch = "# <<< repro:project:" & currentOwningPackage() & ":" & label & ":v"
  let snippet = "when withDir(thisDir(), system.fileExists(\"" & reproPathsFile & "\")):\n  include \"" & reproPathsFile & "\""
  
  let snippetAction = fs.ensureSnippet(configNimsFile,
    openSentinel = openSentinel,
    closeSentinel = closeSentinel,
    openSearch = openSearch,
    closeSearch = closeSearch,
    snippet = snippet,
    actionId = "ensure_snippet_config_nims_" & currentOwningPackage())
  result.add(snippetAction)
