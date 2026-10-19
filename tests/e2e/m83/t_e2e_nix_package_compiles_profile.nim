## Gradual-Nix-To-Reprobuild-Migration GM1 gate:
## `e2e_nix_package_compiles_profile`.
##
## The INSTALLED Nix package — `nix build .#default` of this very tree — plans
## a minimal home profile with no `REPROBUILD_*` variable set and no `nim` on
## `PATH`.
##
## The failures this pins down
## ---------------------------
## Measured 2026-10-13 against reprobuild 0.2.10 and again against this tree
## before the fix:
##
## * `repro home apply --plan` died in `setCurrentDir` on
##   `/nix/var/nix/builds/…-source` — the build-sandbox path the profile
##   compile baked in as `CompiledRepoRoot`. The package's wrapper names the
##   sources in `$REPROBUILD_SOURCE_ROOT`, which every other post-install
##   compile reads; the profile compile read only `$REPROBUILD_REPO_ROOT`.
## * The compile ran `findExe("nim")`, ignoring the `$REPRO_NIM_COMPILER` the
##   wrapper sets to the compiler the package was built with.
##
## What the environment looks like
## -------------------------------
## Every variable the package wrapper sets (`ReprobuildWrapperVariables`) and
## every `REPROBUILD_*` variable is REMOVED, so the wrapper's own defaults are
## the only source of them — a dev shell's `BEARSSL_SRC` or
## `REPRO_NIM_COMPILER` cannot stand in for the package's. Every `PATH`
## directory holding a `nim` is removed too, so a compile that ignored
## `$REPRO_NIM_COMPILER` has no compiler to fall back on. The working
## directory is a scratch directory, not a reprobuild tree. HOME is a scratch
## directory, so on macOS the state directory is the real default,
## `~/Library/Application Support/repro/home`, space included (GM1 deliverable
## "with the default state directory under ~/Library/Application Support").
##
## Which sources the compile used is read from nim's own record, the
## `<nimcache>/profile-build.json` it writes for every compile: `currentDir`
## is the working directory the compile ran in (the resolved source root), and
## `configFiles[0]` is the `nim.cfg` of the compiler that ran.
##
## Negative control: the source checkout's `build/bin/repro`, under the same
## `REPROBUILD_*`-free environment, still compiles against THIS checkout — the
## installed-package arm must not displace a developer's own tree.
##
## Vacuity guard: each run's plan must name the profile's one `fs.userFile`
## resource, and exactly one `.rbpi` must have been published.
##
## Mocks: none. A real `nix build` of this tree (run once by the fixture edge
## `reprobuild.test_fixtures.nix_package`, which each case checks against its
## own `nix eval`; see `nix_package_support.nixPackageUnderTest`), the real
## wrapped package, the real build engine, a real `nim c` and the real planner.

import std/[json, os, strtabs, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_dsl_stdlib/packaging/runtime_contract
import repro_test_support/reasoned_skip

import ./nix_package_support

const MarkerName = "gm1-nix-package-marker.txt"
const ProfileBody = """
import repro_profile

profile "gm1NixPackage":
  resources:
    fsUserFile(hostFile = "~/""" & MarkerName & """",
      content = "planned by the installed package\n")
"""

proc pathWithoutNim(): string =
  var kept: seq[string]
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0 or fileExists(dir / addFileExt("nim", ExeExt)):
      continue
    kept.add dir
  kept.join($PathSep)

proc scrubbedEnv(homeDir, spacedBase, profileDir, storeRoot: string;
                 dropNim: bool): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k.startsWith("REPROBUILD_") or k in ReprobuildWrapperVariables:
      continue
    if k in ["REPRO_HOME_STATE_DIR", "REPRO_HOME_GENERATION_DIR"]:
      continue
    result[k] = v
  if dropNim:
    result["PATH"] = pathWithoutNim()
  result["HOME"] = homeDir
  result["XDG_STATE_HOME"] = spacedBase
  result["REPRO_HOME_PROFILE_DIR"] = profileDir
  result["REPRO_STORE_ROOT"] = storeRoot
  result["REPRO_HOST"] = "gm1-nix-package"

proc defaultStateDir(homeDir, spacedBase: string): string =
  when defined(macosx):
    homeDir / "Library" / "Application Support" / "repro" / "home"
  else:
    spacedBase / "repro" / "home"

type CompileRecord = object
  rbpiCount: int
  currentDir: string
  compilerConfig: string

proc compileRecord(stateDir: string): CompileRecord =
  let cacheDir = stateDir / "profile-cache"
  for kind, path in walkDir(cacheDir):
    if kind == pcFile and path.endsWith(".rbpi"):
      inc result.rbpiCount
  for path in walkDirRec(cacheDir / "nimcache"):
    if path.extractFilename == "profile-build.json":
      let doc = parseFile(path)
      result.currentDir = doc["currentDir"].getStr()
      if doc["configFiles"].len > 0:
        result.compilerConfig = doc["configFiles"][0].getStr()

proc planInScratch(repro: string; dropNim: bool):
    tuple[res: RunResult; rec: CompileRecord; stateDir: string] =
  let root = createTempDir("repro-gm1-nixpkg-", "")
  let homeDir = root / "home"
  let spacedBase = root / "state home"
  let profileDir = root / "profile"
  let storeRoot = root / "store"
  for dir in [homeDir, spacedBase, profileDir, storeRoot]:
    createDir(extendedPath(dir))
  writeFile(extendedPath(profileDir / "home.nim"), ProfileBody)
  let env = scrubbedEnv(homeDir, spacedBase, profileDir, storeRoot, dropNim)
  result.stateDir = defaultStateDir(homeDir, spacedBase)
  result.res = run(repro, ["home", "apply", "--plan"], root, env)
  result.rec = compileRecord(result.stateDir)
  doAssert not fileExists(homeDir / MarkerName), "a plan wrote the marker"
  try: removeDir(root) except OSError: discard

when defined(windows):
  suite "GM1: e2e_nix_package_compiles_profile":
    test "e2e_nix_package_compiles_profile":
      skip("[platform N/A] there is no Nix package on Windows; the release " &
        "bundle's equivalent is GM1w's e2e_windows_bundle_compiles_profile")
else:
  suite "GM1: e2e_nix_package_compiles_profile":

    test "e2e_nix_package_compiles_profile: the installed package plans a " &
        "profile with no REPROBUILD_* variable and no nim on PATH":
      let pkg = nixPackageUnderTest()
      let repro = pkg / "bin" / "repro"
      let sourceRoot = wrapperDefault(repro, "REPROBUILD_SOURCE_ROOT")
      let nimCompiler = wrapperDefault(repro, "REPRO_NIM_COMPILER")
      check sourceRoot.startsWith("/nix/store/")
      check nimCompiler.startsWith("/nix/store/")

      let (res, rec, stateDir) = planInScratch(repro, dropNim = true)
      checkpoint(res.output)
      when defined(macosx):
        check "Application Support" in stateDir
      check res.exitCode == 0
      check not res.output.contains("profile compilation failed")
      check res.output.contains("create  fs.userFile:~/" & MarkerName)
      check rec.rbpiCount == 1
      # The compile ran against the package's own sources ...
      check rec.currentDir == sourceRoot
      # ... with the compiler the package names, found through
      # $REPRO_NIM_COMPILER (no nim was on PATH).
      check rec.compilerConfig.startsWith(nimCompiler.parentDir.parentDir)

    test "e2e_nix_package_compiles_profile: negative control - a source " &
        "checkout's repro still compiles against that checkout":
      let repro = ProjectRoot / "build" / "bin" / "repro".addFileExt(ExeExt)
      doAssert fileExists(repro),
        "repro binary not found at " & repro & "; build with `just build`"
      # `nim` stays on PATH: a checkout build has no wrapper to name one.
      let (res, rec, _) = planInScratch(repro, dropNim = false)
      checkpoint(res.output)
      check res.exitCode == 0
      check res.output.contains("create  fs.userFile:~/" & MarkerName)
      check rec.rbpiCount == 1
      check rec.currentDir == ProjectRoot
