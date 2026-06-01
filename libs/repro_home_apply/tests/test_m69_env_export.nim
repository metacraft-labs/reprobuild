## M69 — verify `env.userVariable` records are synthesized from a
## realized package's per-tool env table.
##
## The M64 cakBuiltin adapter populates `RealizedRecord.envBindings`
## with the (substituted) per-tool env entries declared in the
## catalog's `env:` block. The M69 apply pipeline (step 5) must turn
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
##   * **Negative**: packages whose catalog declares NO `env:` block
##     (ghc, nim, zig, cmake — see the M69 scrutiny revert) emit
##     ZERO `env.userVariable` records when routed through the live
##     catalog. Only the `env.userPath` bin-dir record is produced.
##     The companion positive assertion exercises `maven` and
##     `gradle` (the two M69 retained env blocks — MAVEN_HOME /
##     GRADLE_HOME, both standard environment variables exported by
##     `D:/metacraft/env.ps1`).

import std/[os, strutils, tables, unittest]
import repro_home_resources
import repro_home_apply/env_binding
import repro_home_apply/realize
import repro_home_apply/catalog_lookup

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
  ## Build a fake `RealizedRecord` whose `envBindings` reflects what
  ## the M64 cakBuiltin realizer would produce from the LIVE catalog
  ## slice (substituting `${prefix}` with a synthetic prefix). This
  ## exercises the catalog → realize → planEnvBindings round-trip
  ## without downloading anything.
  let slice = lookupCatalogSlice(packageId)
  let prefix = "C:\\store\\prefixes\\AB\\" & packageId & "-" & slice.resolvedVersion
  result.packageId = packageId
  result.adapter = akBuiltin
  result.prefixAbsolutePath = prefix
  if slice.slice.bin_relpath.len > 0:
    result.resolvedExecutablePath = prefix / slice.slice.bin_relpath[0]
  result.resolvedVersion = slice.resolvedVersion
  for k, v in slice.slice.env.pairs:
    var sub = v
    sub = sub.replace("${prefix}", prefix)
    result.envBindings.add((name: k, value: sub))

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
    # the M69 PATH record's value is a verbatim opaque string for the
    # downstream PATH writer, but ``prefixBinDirs`` derives it via
    # ``parentDir`` which honours the host's PathSep. Backslash
    # separators are not parsed as path separators on POSIX, so the
    # parent-dir walk produces ``""`` and the bin-dir lookup never
    # finds an entry. Forward slashes round-trip on both Windows and
    # POSIX without changing the assertion semantics.
    let rec = makeRecord("jdk",
      "C:/store/jdk/bin/javac.exe",
      @[(name: "JAVA_HOME", value: "C:/store/jdk")])
    let plan = planEnvBindings(@[rec])
    let pathLookup = findResource(plan, "home.package.jdk.bin")
    check pathLookup.found
    check pathLookup.r.kind == rkEnvUserPath
    check pathLookup.r.pathEntries.len >= 1
    # The recorded entry MUST be the parent of the resolved
    # executable (one PATH dir per realized prefix's bin dir).
    check pathLookup.r.pathEntries[0].endsWith("bin")
    check "C:/store/jdk/bin" in pathLookup.r.pathEntries[0]

suite "M69 env_binding: live-catalog round-trip":
  ## These tests exercise the catalog → planEnvBindings round-trip
  ## against the live `packages/*.nim` slices. They lock in the
  ## post-revert contract: the 4 packages whose hand-fabricated env
  ## bindings were removed (ghc/nim/zig/cmake) emit ZERO
  ## env.userVariable resources, while the 2 retained env bindings
  ## (maven, gradle) still emit their MAVEN_HOME / GRADLE_HOME
  ## records. The catalog is the ONLY source for the env table — no
  ## hand-merged code path injects bindings outside the catalog.

  test "package(maven) round-trip emits MAVEN_HOME from the live catalog":
    let rec = syntheticRealizedFromCatalog("maven")
    let plan = planEnvBindings(@[rec])
    let lookup = findResource(plan, "home.package.maven.env.MAVEN_HOME")
    check lookup.found
    check lookup.r.kind == rkEnvUserVariable
    check lookup.r.envVarName == "MAVEN_HOME"

  test "package(gradle) round-trip emits GRADLE_HOME from the live catalog":
    let rec = syntheticRealizedFromCatalog("gradle")
    let plan = planEnvBindings(@[rec])
    let lookup = findResource(plan, "home.package.gradle.env.GRADLE_HOME")
    check lookup.found
    check lookup.r.kind == rkEnvUserVariable
    check lookup.r.envVarName == "GRADLE_HOME"

  test "package(ghc) round-trip emits ZERO env.userVariable resources":
    # GHC has no canonical user-facing HOME env var; the M69 scrutiny
    # revert removed the fabricated `GHC_HOME` entry. The catalog
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
