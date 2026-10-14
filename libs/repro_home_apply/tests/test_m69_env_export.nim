## M69 — verify `env.userVariable` records are synthesized from a
## realized package's per-tool env table.
##
## The realizers populate `RealizedRecord.envBindings` with the
## (substituted) per-tool `env` entries a package's `tarball`
## realization declares (GM4b: formerly the catalog record's `env:`
## block; the home archive realizer and the extract route substitute
## `${prefix}` the same way). The M69 apply pipeline (step 5) must turn
## those entries into `env.userVariable` resource records keyed by
## a stable, per-package address. This test exercises the
## synthesizer (`planEnvBindings`) directly so we can assert the
## generated `Resource` records WITHOUT executing the registry
## driver (which would mutate the host's HKCU on Windows).
##
## Coverage:
##
##   * Single env binding: `package(jdk, "21.0.5")` with
##     `env: {JAVA_HOME: "${prefix}"}` → one `env.userVariable`
##     record (address `home.package.jdk.env.JAVA_HOME`) carrying
##     the substituted value.
##   * Multiple bindings per package (e.g. dotnet's DOTNET_ROOT +
##     MSBuildSDKsPath) become multiple records.
##   * Different packages produce non-colliding addresses.
##   * The bin-dir PATH record (`env.userPath`) is emitted alongside
##     the env vars.
##   * **Negative**: packages whose realization declares NO `env`
##     (ghc, nim, zig, cmake — see the M69 scrutiny revert) emit
##     ZERO `env.userVariable` records when resolved through the live
##     definitions. Only the `env.userPath` bin-dir record is produced.
##     The companion positive assertion exercises `maven` and
##     `gradle` (the two M69 retained env blocks — MAVEN_HOME /
##     GRADLE_HOME, both standard environment variables exported by
##     `D:/metacraft/env.ps1`).

import std/[os, strutils, tables, unittest]
import repro_home_resources
import repro_home_apply/env_binding
import repro_home_apply/realize
import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

proc makeRecord(pkg, exePath: string;
                bindings: seq[tuple[name, value: string]]): RealizedRecord =
  result.packageId = pkg
  result.adapter = akBuiltin
  result.prefixAbsolutePath = exePath.parentDir.parentDir  # rough
  result.resolvedExecutablePath = exePath
  result.envBindings = bindings

proc findResource(plan: EnvBindingPlan; address: string):
    tuple[found: bool; r: Resource] =
  for r in plan.resources:
    if r.address == address:
      return (true, r)
  (false, Resource(kind: rkEnvUserPath))

proc syntheticRealizedFromCatalog(packageId: string): RealizedRecord =
  ## Build the `RealizedRecord` a realization of the LIVE definition would
  ## produce for an x86_64-windows target, without downloading anything:
  ## resolve it (the real selection), then substitute `${prefix}` in the
  ## selected realization's `env` with a synthetic prefix — the substitution
  ## both realizers perform (`builtin_adapter.substituteEnv`).
  let r = resolveProfilePackage(packageId,
    realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1),
    DefaultSelectionPolicy)
  doAssert r.selection.kind == rkTarball,
    packageId & " has no Windows archive"
  let record = r.selection.tarball
  let prefix = "C:\\store\\prefixes\\AB\\" & packageId & "-" &
    r.selection.version
  result.packageId = packageId
  result.adapter =
    if r.archiveRoute == arInstaller: akBuiltin else: akTarball
  result.prefixAbsolutePath = prefix
  result.resolvedExecutablePath = prefix / record.executablePath
  result.resolvedVersion = r.selection.version
  var raw: seq[tuple[name, value: string]] = @[]
  for binding in record.detail.env:
    let eq = binding.find('=')
    raw.add((name: binding[0 ..< eq], value: binding[eq + 1 .. ^1]))
  result.envBindings = substituteEnv(raw, prefix)

suite "M69 env_binding synthesis":

  test "package(jdk, \"21.0.5\") emits JAVA_HOME env.userVariable":
    let rec = makeRecord("jdk",
      "C:\\store\\prefixes\\AB\\jdk-21.0.5\\bin\\javac.exe",
      @[(name: "JAVA_HOME",
         value: "C:\\store\\prefixes\\AB\\jdk-21.0.5")])
    let plan = planEnvBindings(@[rec])
    let envEntry = plan.envVariables[0]
    check envEntry.name == "JAVA_HOME"
    check envEntry.value == "C:\\store\\prefixes\\AB\\jdk-21.0.5"
    let lookup = findResource(plan, "home.package.jdk.env.JAVA_HOME")
    check lookup.found
    check lookup.r.kind == rkEnvUserVariable
    check lookup.r.envVarName == "JAVA_HOME"
    check lookup.r.lifecyclePolicy == lpDefault

  test "package(maven) emits MAVEN_HOME env.userVariable":
    let rec = makeRecord("maven",
      "C:\\store\\prefixes\\CD\\maven\\bin\\mvn.cmd",
      @[(name: "MAVEN_HOME",
         value: "C:\\store\\prefixes\\CD\\maven")])
    let plan = planEnvBindings(@[rec])
    let lookup = findResource(plan, "home.package.maven.env.MAVEN_HOME")
    check lookup.found
    check lookup.r.kind == rkEnvUserVariable
    check lookup.r.envVarName == "MAVEN_HOME"

  test "multiple env entries per package each get their own record":
    let rec = makeRecord("dotnet-sdk",
      "C:\\store\\prefixes\\EF\\dotnet\\dotnet.exe",
      @[(name: "DOTNET_ROOT", value: "C:\\store\\prefixes\\EF\\dotnet"),
        (name: "MSBuildSDKsPath",
         value: "C:\\store\\prefixes\\EF\\dotnet\\sdk\\10.0.300\\Sdks")])
    let plan = planEnvBindings(@[rec])
    check findResource(plan, "home.package.dotnet-sdk.env.DOTNET_ROOT").found
    check findResource(plan,
      "home.package.dotnet-sdk.env.MSBuildSDKsPath").found

  test "different packages produce non-colliding addresses":
    # JDK declares JAVA_HOME; Maven declares MAVEN_HOME. Both are
    # genuine, hand-merged M69 retained env bindings (standard env
    # vars exported by D:/metacraft/env.ps1). Cross-package isolation
    # must hold: maven's MAVEN_HOME never appears under jdk's address
    # space and vice versa.
    let r1 = makeRecord("jdk",
      "C:\\jdk\\bin\\javac.exe",
      @[(name: "JAVA_HOME", value: "C:\\jdk")])
    let r2 = makeRecord("maven",
      "C:\\maven\\bin\\mvn.cmd",
      @[(name: "MAVEN_HOME", value: "C:\\maven")])
    let plan = planEnvBindings(@[r1, r2])
    check findResource(plan, "home.package.jdk.env.JAVA_HOME").found
    check findResource(plan, "home.package.maven.env.MAVEN_HOME").found
    check (not findResource(plan, "home.package.jdk.env.MAVEN_HOME").found)
    check (not findResource(plan, "home.package.maven.env.JAVA_HOME").found)

  test "bin-dir PATH record is emitted alongside env vars":
    # Use forward-slash separators so the test is host-independent:
    # backslashes are not path separators on POSIX, so the parent-dir
    # walk produces ``""`` and the bin-dir lookup never finds an
    # entry. Forward slashes round-trip on both Windows and POSIX.
    # The expected bin dir is derived via ``parentDir`` so the
    # assertion remains stable whether the host normalizes to ``/``
    # (POSIX) or ``\`` (Windows) — the PATH writer consumes whatever
    # separator the host's ``parentDir`` chooses.
    let exePath = "C:/store/jdk/bin/javac.exe"
    let expectedBinDir = exePath.parentDir
    let rec = makeRecord("jdk", exePath,
      @[(name: "JAVA_HOME", value: "C:/store/jdk")])
    let plan = planEnvBindings(@[rec])
    let pathLookup = findResource(plan, "home.package.jdk.bin")
    check pathLookup.found
    check pathLookup.r.kind == rkEnvUserPath
    check pathLookup.r.pathEntries.len >= 1
    # The recorded entry MUST be the parent of the resolved
    # executable (one PATH dir per realized prefix's bin dir).
    check pathLookup.r.pathEntries[0].endsWith("bin")
    check pathLookup.r.pathEntries[0] == expectedBinDir

suite "M69 env_binding: live-definition round-trip":
  ## These tests exercise the definition → planEnvBindings round-trip
  ## against the live `packages/*.nim` realizations. They lock in the
  ## post-revert contract: the 4 packages whose hand-fabricated env
  ## bindings were removed (ghc/nim/zig/cmake) emit ZERO
  ## env.userVariable resources, while the 2 retained env bindings
  ## (maven, gradle) still emit their MAVEN_HOME / GRADLE_HOME
  ## records. The realization is the ONLY source for the env table — no
  ## hand-merged code path injects bindings outside it.

  test "package(maven) round-trip emits MAVEN_HOME from the live definition":
    let rec = syntheticRealizedFromCatalog("maven")
    let plan = planEnvBindings(@[rec])
    let lookup = findResource(plan, "home.package.maven.env.MAVEN_HOME")
    check lookup.found
    check lookup.r.kind == rkEnvUserVariable
    check lookup.r.envVarName == "MAVEN_HOME"

  test "package(gradle) round-trip emits GRADLE_HOME from the live definition":
    let rec = syntheticRealizedFromCatalog("gradle")
    let plan = planEnvBindings(@[rec])
    let lookup = findResource(plan, "home.package.gradle.env.GRADLE_HOME")
    check lookup.found
    check lookup.r.kind == rkEnvUserVariable
    check lookup.r.envVarName == "GRADLE_HOME"

  test "package(ghc) round-trip emits ZERO env.userVariable resources":
    # GHC has no canonical user-facing HOME env var; the M69 scrutiny
    # revert removed the fabricated `GHC_HOME` entry. The realization
    # declares no env bindings, so planEnvBindings must produce ONLY
    # the bin-dir PATH record for ghc and zero env.userVariable.
    let rec = syntheticRealizedFromCatalog("ghc")
    let plan = planEnvBindings(@[rec])
    check rec.envBindings.len == 0
    var envVarResources = 0
    for r in plan.resources:
      if r.kind == rkEnvUserVariable:
        inc envVarResources
    check envVarResources == 0
    # The PATH binding is still emitted (executables → userPath).
    check findResource(plan, "home.package.ghc.bin").found

  test "package(nim) round-trip emits ZERO env.userVariable resources":
    let rec = syntheticRealizedFromCatalog("nim")
    let plan = planEnvBindings(@[rec])
    check rec.envBindings.len == 0
    var envVarResources = 0
    for r in plan.resources:
      if r.kind == rkEnvUserVariable:
        inc envVarResources
    check envVarResources == 0
    check findResource(plan, "home.package.nim.bin").found

  test "package(zig) round-trip emits ZERO env.userVariable resources":
    let rec = syntheticRealizedFromCatalog("zig")
    let plan = planEnvBindings(@[rec])
    check rec.envBindings.len == 0
    var envVarResources = 0
    for r in plan.resources:
      if r.kind == rkEnvUserVariable:
        inc envVarResources
    check envVarResources == 0
    check findResource(plan, "home.package.zig.bin").found

  test "package(cmake) round-trip emits ZERO env.userVariable resources":
    # CMake's CMAKE_ROOT is a CMake-internal config variable; the
    # CMake docs explicitly warn against setting it externally
    # ("This variable should not normally be set by the user").
    # The M69 scrutiny revert removed the fabricated entry.
    let rec = syntheticRealizedFromCatalog("cmake")
    let plan = planEnvBindings(@[rec])
    check rec.envBindings.len == 0
    var envVarResources = 0
    for r in plan.resources:
      if r.kind == rkEnvUserVariable:
        inc envVarResources
    check envVarResources == 0
    check findResource(plan, "home.package.cmake.bin").found
