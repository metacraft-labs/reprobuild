## M57 platform-e2e gate `e2e_windows_launcher_isolation`.
##
## Two side-by-side fixture packages export conflicting DLL names —
## `libfoo.dll` with DIFFERENT version strings. The launched plan MUST
## load the DLL from its OWN realized prefix, independent of the
## process's `PATH` state. The fixture verifies which DLL was actually
## loaded by having each `libfoo.dll` export a string-returning
## `repro_foo_version()` symbol, and by having the fixture executable
## print the returned string to stdout. The parent test compares the
## printed string against the expected version.
##
## Real components per the milestone spec:
##   * Real Reprobuild launcher binary (compiled from
##     `apps/repro-launcher/repro_launcher.nim`).
##   * Two real fixture DLLs compiled with `gcc` from C source.
##   * Two real fixture EXEs that dynamically load `libfoo.dll` and
##     print the exported version string.
##   * The real M56 store (LaunchPlans stored in `<root>/cas/...`).
##   * Real Windows `PATH` is mutated for the "reversed PATH"
##     scenario; no mocked launcher.
##
## Allowed mocks: temporary fixture prefixes only. No fake launcher,
## no fake DLL probes.

when not defined(windows):
  ## On non-Windows hosts the gate is a no-op that prints the spec-
  ## allowed `[platform N/A]` marker, then exits 0.
  echo "[platform N/A] e2e_windows_launcher_isolation: " &
    "this gate is Windows-only"
  quit(0)

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_launch_plan
import repro_local_store

# ---------------------------------------------------------------------------
# Source discovery
# ---------------------------------------------------------------------------

proc findRepoRoot(): string =
  var current = getAppFilename().parentDir
  for _ in 0 .. 10:
    if dirExists(current / "libs") and
        fileExists(current / "apps" / "repro-launcher" /
          "repro_launcher.nim"):
      return current
    let p = current.parentDir
    if p == current: break
    current = p
  ""

proc compileWindowsLauncher(repoRoot, outBin, nimcache: string): string =
  let src = repoRoot / "apps" / "repro-launcher" / "repro_launcher.nim"
  let res = execCmdEx("nim c --hints:off --verbosity:0 --nimcache:" &
    quoteShell(nimcache) & " --out:" & quoteShell(outBin) &
    " " & quoteShell(src))
  doAssert res.exitCode == 0, "launcher compile failed:\n" & res.output
  outBin

# ---------------------------------------------------------------------------
# Fixture DLL + EXE source emission
# ---------------------------------------------------------------------------

const FixtureDllSourceTemplate = """
/* Reprobuild M57 isolation gate fixture: libfoo.dll version $VERSION.
 * Exports `repro_foo_version` so the calling executable can identify
 * which on-disk DLL was actually loaded. The version string is
 * deliberately unique per package so the parent process can tell
 * pkg-a from pkg-b at runtime. */
#include <stdint.h>

__declspec(dllexport) const char* repro_foo_version(void) {
  return "$VERSION";
}
"""

const FixtureExeSourceTemplate = """
/* Reprobuild M57 isolation gate fixture: query.exe.
 *
 * Imports `repro_foo_version` via an import library, then prints what
 * the loader actually bound to. Because we link against the import
 * library for libfoo (NOT LoadLibrary-at-runtime), the Windows loader
 * resolves `libfoo.dll` using the standard DLL search order at
 * process startup — exactly the resolver the Reprobuild launcher's
 * SetDefaultDllDirectories + AddDllDirectory calls are designed to
 * direct. */
#include <stdio.h>

__declspec(dllimport) const char* repro_foo_version(void);

int main(void) {
  const char* v = repro_foo_version();
  printf("LIBFOO_VERSION=%s\n", v ? v : "(null)");
  return 0;
}
"""

proc buildFixtureDll(pkgDir, version: string) =
  ## Compile a `libfoo.dll` whose exported `repro_foo_version()` returns
  ## the package's version string. We use `gcc` from the workspace
  ## install (`env.ps1` puts it on PATH).
  createDir(pkgDir / "lib")
  let cSrc = pkgDir / "lib" / "libfoo.c"
  writeFile(cSrc, FixtureDllSourceTemplate.replace("$VERSION", version))
  let dllPath = pkgDir / "lib" / "libfoo.dll"
  let impLibPath = pkgDir / "lib" / "libfoo.a"
  let cmd = "gcc -shared -O0 -o " & quoteShell(dllPath) &
    " " & quoteShell(cSrc) &
    " -Wl,--out-implib," & quoteShell(impLibPath)
  let res = execCmdEx(cmd)
  doAssert res.exitCode == 0, "gcc dll compile failed:\n" & res.output

proc buildFixtureExe(pkgDir, libDir: string) =
  ## Compile `query.exe` and link it against `libfoo.a`. The linker
  ## records `libfoo.dll` as a normal import, so the OS DLL search
  ## kicks in at process startup.
  createDir(pkgDir / "bin")
  let cSrc = pkgDir / "bin" / "query.c"
  writeFile(cSrc, FixtureExeSourceTemplate)
  let exePath = pkgDir / "bin" / "query.exe"
  let cmd = "gcc -O0 -o " & quoteShell(exePath) &
    " " & quoteShell(cSrc) & " -L" & quoteShell(libDir) & " -lfoo"
  let res = execCmdEx(cmd)
  doAssert res.exitCode == 0, "gcc exe compile failed:\n" & res.output

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc basePlan(pkgPrefix, libDir, exePath, command, version: string): LaunchPlan =
  LaunchPlan(
    schemaVersion: LaunchPlanCurrentSchemaVersion,
    realizedPrefix: pkgPrefix,
    exportedCommand: command,
    executablePath: exePath,
    arguments: @[],
    hasWorkingDirectory: false,
    workingDirectory: "",
    environmentBindings: @[],
    executableBindings: @[],
    runtimeLibraryDirs: @[libDir],
    projectedRuntimeImage: ProjectedRuntimeImage(present: false),
    executionProfile: ExecutionProfileChecksum(present: false),
    supportProfile: newSupportProfile("windows", "x86_64", "msvc", ""),
    provenance: LaunchPlanProvenance(adapter: "tarball",
      packageId: "libfoo@" & version,
      realizationHashHex: repeat("cc", 32)),
    binding: lbkWindowsLauncher)

proc stageLauncher(repoRoot, binDir, command, launcher, storeRoot: string;
                   plan: LaunchPlan; requireExecProfile = false;
                   execProfileHex = "") =
  ## Copy the prebuilt launcher binary into the home-bin dir under the
  ## command's name and drop a `<command>.repro-launch` sidecar next to
  ## it. This is the Windows materialization protocol from the spec.
  createDir(binDir)
  let launcherCopy = binDir / (command & ".exe")
  copyFile(launcher, launcherCopy)
  let sidecarPath = launcherCopy & LaunchPlanSidecarSuffix
  writeSidecarFile(sidecarPath, LaunchSidecar(
    schemaVersion: LaunchSidecarCurrentVersion,
    launchPlanIdHex: launchPlanIdHex(plan),
    storeRoot: storeRoot,
    realizedPrefix: plan.realizedPrefix,
    exportedCommand: command,
    requiresExecutionProfile: requireExecProfile,
    executionProfileHex: execProfileHex))

# ---------------------------------------------------------------------------
# Gate body
# ---------------------------------------------------------------------------

suite "e2e_windows_launcher_isolation":

  test "side-by-side conflicting DLLs each load from their own prefix":
    let repoRoot = findRepoRoot()
    check repoRoot.len > 0

    let tmp = createTempDir("repro-m57-e2e-iso-", "")
    defer:
      try: removeDir(tmp) except OSError: discard

    # 1. Compile the launcher binary once.
    let launcher = compileWindowsLauncher(repoRoot,
      tmp / "repro-launcher.exe", tmp / "nimcache-launcher")
    check fileExists(launcher)

    # 2. Build two fixture packages with conflicting libfoo.dll names.
    let pkgA = tmp / "store" / "prefixes" / "libfoo" / "1.0.0-aa" /
      "libfoo-pkg-a"
    let pkgB = tmp / "store" / "prefixes" / "libfoo" / "2.0.0-bb" /
      "libfoo-pkg-b"
    createDir(pkgA)
    createDir(pkgB)
    buildFixtureDll(pkgA, "libfoo-pkg-a-v1.0.0")
    buildFixtureDll(pkgB, "libfoo-pkg-b-v2.0.0")
    buildFixtureExe(pkgA, pkgA / "lib")
    buildFixtureExe(pkgB, pkgB / "lib")
    check fileExists(pkgA / "lib" / "libfoo.dll")
    check fileExists(pkgB / "lib" / "libfoo.dll")
    check fileExists(pkgA / "bin" / "query.exe")
    check fileExists(pkgB / "bin" / "query.exe")

    # 3. Open the M56 store and emit two LaunchPlans pointing at their
    # own pkg's libfoo dir.
    let storeRoot = tmp / "store"
    var store = openStore(storeRoot)
    let planA = basePlan(pkgA, pkgA / "lib",
      pkgA / "bin" / "query.exe", "query-from-a", "1.0.0")
    let planB = basePlan(pkgB, pkgB / "lib",
      pkgB / "bin" / "query.exe", "query-from-b", "2.0.0")
    let idA = store.storeLaunchPlan(planA)
    let idB = store.storeLaunchPlan(planB)
    check idA != idB
    store.close()

    # 4. Stage two launcher copies in the home-profile bin dir.
    let binDir = tmp / "home-bin"
    stageLauncher(repoRoot, binDir, "query-from-a", launcher, storeRoot, planA)
    stageLauncher(repoRoot, binDir, "query-from-b", launcher, storeRoot, planB)
    check fileExists(binDir / "query-from-a.exe")
    check fileExists(binDir / ("query-from-a.exe" & LaunchPlanSidecarSuffix))
    check fileExists(binDir / "query-from-b.exe")

    # 5. Baseline: launching either command from a clean PATH yields
    # the right version.
    let resA = execCmdEx(quoteShell(binDir / "query-from-a.exe"))
    check resA.exitCode == 0
    check "LIBFOO_VERSION=libfoo-pkg-a-v1.0.0" in resA.output

    let resB = execCmdEx(quoteShell(binDir / "query-from-b.exe"))
    check resB.exitCode == 0
    check "LIBFOO_VERSION=libfoo-pkg-b-v2.0.0" in resB.output

    # 6. Isolation: prepend pkgB's lib dir to PATH then launch the
    # pkg-A command. The launcher's AddDllDirectory call MUST take
    # precedence over the PATH widening. If isolation were broken, the
    # query EXE would load pkg-B's libfoo.dll and print v2.0.0.
    putEnv("PATH", (pkgB / "lib") & ";" & getEnv("PATH"))
    defer:
      # Restore PATH after this test runs.
      let originalPath = getEnv("PATH")
      let newPath = originalPath.replace((pkgB / "lib") & ";", "")
      putEnv("PATH", newPath)

    let resAIsolated = execCmdEx(quoteShell(binDir / "query-from-a.exe"))
    check resAIsolated.exitCode == 0
    check "LIBFOO_VERSION=libfoo-pkg-a-v1.0.0" in resAIsolated.output
    check "v2.0.0" notin resAIsolated.output

    # Symmetric: with pkg-A's libdir prepended to PATH, pkg-B's
    # launcher must still load its OWN DLL.
    putEnv("PATH", (pkgA / "lib") & ";" & getEnv("PATH"))
    let resBIsolated = execCmdEx(quoteShell(binDir / "query-from-b.exe"))
    check resBIsolated.exitCode == 0
    check "LIBFOO_VERSION=libfoo-pkg-b-v2.0.0" in resBIsolated.output
    check "v1.0.0" notin resBIsolated.output

  test "AddDllDirectory order: first matching dir wins":
    ## The spec specifies AddDllDirectory is called in the order the
    ## entries appear in `runtimeLibraryDirs`. Build a plan whose
    ## runtimeLibraryDirs lists pkg-A first then pkg-B; the launcher
    ## must load pkg-A's libfoo.dll. Then build a plan with the dirs
    ## in reverse order and verify pkg-B is loaded.

    let repoRoot = findRepoRoot()
    let tmp = createTempDir("repro-m57-e2e-order-", "")
    defer:
      try: removeDir(tmp) except OSError: discard

    let launcher = compileWindowsLauncher(repoRoot,
      tmp / "repro-launcher.exe", tmp / "nimcache-launcher")

    let pkgA = tmp / "store" / "prefixes" / "libfoo" / "1.0.0-aa" / "pkg-a"
    let pkgB = tmp / "store" / "prefixes" / "libfoo" / "2.0.0-bb" / "pkg-b"
    createDir(pkgA); createDir(pkgB)
    buildFixtureDll(pkgA, "order-v1")
    buildFixtureDll(pkgB, "order-v2")
    # The query EXE imports `libfoo` from one of the lib dirs. We link
    # it once against pkgA's import library so the executable's
    # imports are stable; isolation comes from the runtime DLL
    # resolution that the launcher steers.
    buildFixtureExe(pkgA, pkgA / "lib")

    let storeRoot = tmp / "store"
    var store = openStore(storeRoot)

    let planAB = LaunchPlan(
      schemaVersion: LaunchPlanCurrentSchemaVersion,
      realizedPrefix: pkgA,
      exportedCommand: "ord-ab",
      executablePath: pkgA / "bin" / "query.exe",
      arguments: @[],
      hasWorkingDirectory: false,
      workingDirectory: "",
      environmentBindings: @[],
      executableBindings: @[],
      runtimeLibraryDirs: @[pkgA / "lib", pkgB / "lib"],
      projectedRuntimeImage: ProjectedRuntimeImage(present: false),
      executionProfile: ExecutionProfileChecksum(present: false),
      supportProfile: newSupportProfile("windows", "x86_64", "msvc", ""),
      provenance: LaunchPlanProvenance(adapter: "tarball",
        packageId: "ord-ab",
        realizationHashHex: repeat("01", 32)),
      binding: lbkWindowsLauncher)

    let planBA = LaunchPlan(
      schemaVersion: LaunchPlanCurrentSchemaVersion,
      realizedPrefix: pkgA,
      exportedCommand: "ord-ba",
      executablePath: pkgA / "bin" / "query.exe",
      arguments: @[],
      hasWorkingDirectory: false,
      workingDirectory: "",
      environmentBindings: @[],
      executableBindings: @[],
      runtimeLibraryDirs: @[pkgB / "lib", pkgA / "lib"],
      projectedRuntimeImage: ProjectedRuntimeImage(present: false),
      executionProfile: ExecutionProfileChecksum(present: false),
      supportProfile: newSupportProfile("windows", "x86_64", "msvc", ""),
      provenance: LaunchPlanProvenance(adapter: "tarball",
        packageId: "ord-ba",
        realizationHashHex: repeat("02", 32)),
      binding: lbkWindowsLauncher)

    discard store.storeLaunchPlan(planAB)
    discard store.storeLaunchPlan(planBA)
    store.close()

    let binDir = tmp / "home-bin"
    stageLauncher(repoRoot, binDir, "ord-ab", launcher, storeRoot, planAB)
    stageLauncher(repoRoot, binDir, "ord-ba", launcher, storeRoot, planBA)

    let resAB = execCmdEx(quoteShell(binDir / "ord-ab.exe"))
    check resAB.exitCode == 0
    check "LIBFOO_VERSION=order-v1" in resAB.output

    let resBA = execCmdEx(quoteShell(binDir / "ord-ba.exe"))
    check resBA.exitCode == 0
    check "LIBFOO_VERSION=order-v2" in resBA.output

  test "app-local DLL layout (strategy 2) loads adjacent DLL":
    ## With binding `lbkWindowsAppLocal`, the realization step has
    ## copied the dependent DLL next to the executable. The
    ## Reprobuild launcher records ZERO entries in `runtimeLibraryDirs`,
    ## so it does not call AddDllDirectory. The Windows loader then
    ## finds the DLL via its standard "application directory first"
    ## search rule, even when `PATH` is empty / hostile.

    let repoRoot = findRepoRoot()
    let tmp = createTempDir("repro-m57-e2e-applocal-", "")
    defer:
      try: removeDir(tmp) except OSError: discard

    let launcher = compileWindowsLauncher(repoRoot,
      tmp / "repro-launcher.exe", tmp / "nimcache-launcher")

    let pkg = tmp / "store" / "prefixes" / "libfoo" / "3.0.0-cc" / "applocal"
    createDir(pkg)
    buildFixtureDll(pkg, "applocal-v3")
    buildFixtureExe(pkg, pkg / "lib")
    # Copy libfoo.dll next to query.exe to simulate the strategy-2
    # materialization. The launcher will NOT add a search dir, so the
    # only way the EXE can resolve libfoo.dll is via the application
    # directory.
    copyFile(pkg / "lib" / "libfoo.dll", pkg / "bin" / "libfoo.dll")

    let storeRoot = tmp / "store"
    var store = openStore(storeRoot)
    let plan = LaunchPlan(
      schemaVersion: LaunchPlanCurrentSchemaVersion,
      realizedPrefix: pkg,
      exportedCommand: "applocal",
      executablePath: pkg / "bin" / "query.exe",
      arguments: @[],
      hasWorkingDirectory: false,
      workingDirectory: "",
      environmentBindings: @[],
      executableBindings: @[],
      runtimeLibraryDirs: @[],            # strategy 2: no AddDllDirectory
      projectedRuntimeImage: ProjectedRuntimeImage(present: false),
      executionProfile: ExecutionProfileChecksum(present: false),
      supportProfile: newSupportProfile("windows", "x86_64", "msvc", ""),
      provenance: LaunchPlanProvenance(adapter: "tarball",
        packageId: "applocal",
        realizationHashHex: repeat("03", 32)),
      binding: lbkWindowsAppLocal)
    discard store.storeLaunchPlan(plan)
    store.close()

    let binDir = tmp / "home-bin"
    stageLauncher(repoRoot, binDir, "applocal", launcher, storeRoot, plan)

    let res = execCmdEx(quoteShell(binDir / "applocal.exe"))
    check res.exitCode == 0
    check "LIBFOO_VERSION=applocal-v3" in res.output

  test "execution-profile checksum mismatch fails closed":
    ## The launcher MUST refuse to spawn the child process if the
    ## sidecar requests execution-profile verification and the plan's
    ## checksum does not match the sidecar's. This is the weak-adapter
    ## fail-closed contract from the spec.

    let repoRoot = findRepoRoot()
    let tmp = createTempDir("repro-m57-e2e-execprof-", "")
    defer:
      try: removeDir(tmp) except OSError: discard

    let launcher = compileWindowsLauncher(repoRoot,
      tmp / "repro-launcher.exe", tmp / "nimcache-launcher")

    let pkg = tmp / "store" / "prefixes" / "libfoo" / "4.0.0-dd" / "exp"
    createDir(pkg)
    buildFixtureDll(pkg, "exp-v4")
    buildFixtureExe(pkg, pkg / "lib")

    let storeRoot = tmp / "store"
    var store = openStore(storeRoot)
    let plan = LaunchPlan(
      schemaVersion: LaunchPlanCurrentSchemaVersion,
      realizedPrefix: pkg,
      exportedCommand: "exp",
      executablePath: pkg / "bin" / "query.exe",
      arguments: @[],
      hasWorkingDirectory: false,
      workingDirectory: "",
      environmentBindings: @[],
      executableBindings: @[],
      runtimeLibraryDirs: @[pkg / "lib"],
      projectedRuntimeImage: ProjectedRuntimeImage(present: false),
      # The plan claims an execution profile of "good-hash".
      executionProfile: ExecutionProfileChecksum(present: true,
        requires: true, checksumHex: repeat("ad", 32)),
      supportProfile: newSupportProfile("windows", "x86_64", "msvc", ""),
      provenance: LaunchPlanProvenance(adapter: "scoop",
        packageId: "exp",
        realizationHashHex: repeat("04", 32)),
      binding: lbkWindowsLauncher)
    discard store.storeLaunchPlan(plan)
    store.close()

    let binDir = tmp / "home-bin"
    # The sidecar carries a DIFFERENT checksum hex than the plan. The
    # launcher must fail closed.
    stageLauncher(repoRoot, binDir, "exp", launcher, storeRoot, plan,
      requireExecProfile = true, execProfileHex = repeat("ff", 32))

    let res = execCmdEx(quoteShell(binDir / "exp.exe"))
    check res.exitCode != 0
    check "execution-profile checksum mismatch" in res.output
