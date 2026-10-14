## Gradual-Nix-To-Reprobuild-Migration GM1w gate:
## `e2e_windows_bundle_compiles_profile`.
##
## The EXTRACTED Windows release bundle of this tree plans a minimal home
## profile with no `REPROBUILD_*` and no `*_SRC` variable set.
##
## The failures this pins down
## ---------------------------
## Measured 2026-10-13 on eli-pc (Windows 11) against reprobuild 0.2.10 and
## against this tree at 8617c3ff before the fix, with the same scrubbed
## environment this test builds:
##
## * The bundle found its sources -- the image seeds `$REPROBUILD_SOURCE_ROOT`
##   from `<prefix>\share\repro\source` and GM1 made the profile compile read
##   it -- but the archive shipped only `share\repro\source\libs`, not the
##   `config.nims` the profile compile includes to turn the `*_SRC` roots into
##   search paths. Nim saw only `libs\*\src`:
##     repro_project_dsl.nim(48, 23) Error: cannot open file: nimcrypto/sha2
##   0.2.10 with zah/dotfiles' `Set-ReproBundleSourceEnv` variables fails the
##   same way.
## * With `config.nims` shipped, the vendored hash headers' `-I` flags were
##   spliced into the C command line unquoted, so a bundle under a path with a
##   space (`C:\Users\First Last\...`) failed in gcc on a stray `vendor` input.
## * With `share\repro` removed, a binary built in a checkout that still exists
##   (this one) silently compiled against that checkout through the
##   compiled-in source root, so "the bundle works" could not be told apart
##   from "the build host's checkout works".
##
## How the bundle is produced
## --------------------------
## By `scripts/release/package_windows_release.ps1 -Zip`, the script the
## release job (`.github/workflows/release.yml`, "Package release assets
## (Windows)") runs: runtime-DLL staging into `build\bin`, the `bin\` and
## `lib\` copy, `stage_release_sources.sh` for `share\repro`, and the zip. It
## is unzipped with `Expand-Archive` into a directory whose path has a space.
## One deviation from the release: the binaries are this checkout's
## `build\bin` (`bash scripts/build_apps.sh`), not the output of the release
## job's `repro build .#release`; the packaging steps are identical. The DLL
## staging writes into `build\bin`, as it does in the release job.
##
## What the environment looks like
## -------------------------------
## Every `REPROBUILD_*` and `*_SRC` variable is REMOVED (asserted), with
## `REPRO_BOOTSTRAP_SOURCE_ENV`, `REPRO_PUBLIC_CLI_PATH`,
## `REPRO_NIM_COMPILER` and the home state overrides. Every `PATH` directory
## holding a `repro.exe` or `reprobuild.exe` is removed -- this checkout's
## `build\bin` and any installed bundle -- and no `PATH` entry may lie inside
## the workspace this checkout belongs to (asserted). `nim` comes from `PATH`
## (the Nim the reprobuild Windows environment, `env.ps1`, provisions; the
## bundle ships none). HOME / USERPROFILE / LOCALAPPDATA point at scratch
## directories, so the state directory is `%LOCALAPPDATA%\repro\home` under a
## spaced scratch base, and the working directory is outside any reprobuild
## tree.
##
## Proving which sources were used
## -------------------------------
## Nim's debug-mode C output embeds the absolute path of every Nim module it
## compiled (stack-frame file names), and `profile-build.json` records the
## compile's working directory and its `{.compile.}` C sources. The test reads
## them: the compile ran in the bundle's `share\repro\source`, used modules
## from its `share\repro\source\libs` AND from `share\repro\src` (the profile
## imports `repro_test_adapters/test_runner`, which exists only in
## `share\repro\src\reprobuild-test-adapters`), and nothing under the
## workspace root -- neither this checkout nor its sibling repositories.
##
## Vacuity guard: the plan names the profile's one `fs.userFile` resource,
## exactly one `.rbpi` is published under the state directory, and the planned
## file is not written.
##
## Negative control: the same run after deleting `share\repro` from the
## extracted bundle fails, and its diagnostic names the probed
## `...\share\repro\source` and the variables that would select a tree -- it
## does NOT fall back to this checkout, which exists on this host.
##
## Mocks: none. The release packaging script, a real zip, the real extracted
## `repro.exe` (thin client) and `reprobuild.exe` (engine), the real build
## engine spawning the real `__repro-compile-profile` helper, a real `nim c`
## and the real planner.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath
from repro_core/process_streams import drainStream

import repro_test_support/reasoned_skip

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()
const WorkspaceRoot = ProjectRoot.parentDir()
  ## The workspace this checkout sits in; its sibling repositories (io-mon,
  ## runquota, ...) are the dev copies of the bundle's `share\repro\src`.

const MarkerName = "gm1w-bundle-marker.txt"
const ProfileBody = """
import repro_profile
# Lives only in the bundle's share\repro\src\reprobuild-test-adapters: proves
# the compile resolved a source-only input from the installed layout.
import repro_test_adapters/test_runner

discard defaultTestRunner()

profile "gm1wWindowsBundle":
  resources:
    fsUserFile(hostFile = "~/""" & MarkerName & """",
      content = "planned by the extracted Windows bundle\n")
"""

type RunResult = tuple[exitCode: int; output: string]

proc run(exe: string; args: openArray[string]; cwd: string;
         env: StringTableRef = nil): RunResult =
  let p = startProcess(exe, workingDir = cwd, args = @args, env = env,
    options = {poStdErrToStdOut})
  let output = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc lower(path: string): string =
  ## Windows paths compare case-insensitively and with either separator.
  path.replace('/', '\\').toLowerAscii()

proc isUnder(path, root: string): bool =
  let p = lower(path)
  let r = lower(root).strip(leading = false, chars = {'\\'})
  p == r or p.startsWith(r & "\\")

when not defined(windows):
  suite "GM1w: e2e_windows_bundle_compiles_profile":
    test "e2e_windows_bundle_compiles_profile":
      skip("[platform N/A] the Windows release bundle (a zip of " &
        "scripts/release/package_windows_release.ps1's tree) is built and " &
        "run only on Windows; the POSIX installed-package gate is GM1's " &
        "e2e_nix_package_compiles_profile")
else:
  proc powershellExe(): string =
    ## pwsh when present (the release job's shell), else Windows PowerShell
    ## 5.1, which the packaging script also supports.
    result = findExe("pwsh")
    if result.len == 0:
      result = findExe("powershell")
    doAssert result.len > 0, "no PowerShell to run the packaging script"

  proc runPowerShell(script: string; cwd: string): RunResult =
    run(powershellExe(), ["-NoProfile", "-NonInteractive", "-Command",
      script], cwd)

  proc psQuote(s: string): string = "'" & s.replace("'", "''") & "'"

  proc packageAndExtract(scratch: string): string =
    ## Package this tree exactly as the release does, zip it, and unzip it
    ## under a spaced directory. Returns the extracted
    ## `reprobuild-<ver>-windows-x86_64` directory.
    for image in ["repro.exe", "reprobuild.exe"]:
      doAssert fileExists(ProjectRoot / "build" / "bin" / image),
        image & " not found in " & ProjectRoot / "build" / "bin" &
        "; build with `bash ./scripts/build_apps.sh` (after `. .\\env.ps1`)"
    let outDir = scratch / "pkg"
    let pack = runPowerShell("& ./scripts/release/package_windows_release.ps1" &
      " -OutDir " & psQuote(outDir) & " -Zip", ProjectRoot)
    doAssert pack.exitCode == 0, "packaging failed:\n" & pack.output
    var lines: seq[string]
    for line in pack.output.splitLines:
      if line.strip().len > 0:
        lines.add line.strip()
    doAssert lines.len >= 2, "packaging printed no paths:\n" & pack.output
    let zipPath = lines[^1]
    doAssert zipPath.endsWith(".zip") and fileExists(zipPath),
      "packaging printed no zip path:\n" & pack.output
    let pkgName = zipPath.extractFilename.changeFileExt("")
    doAssert pkgName.startsWith("reprobuild-") and
      pkgName.endsWith("-windows-x86_64"), pkgName
    let extractRoot = scratch / "x b"
    let expand = runPowerShell("Expand-Archive -LiteralPath " &
      psQuote(zipPath) & " -DestinationPath " & psQuote(extractRoot),
      scratch)
    doAssert expand.exitCode == 0, "Expand-Archive failed:\n" & expand.output
    result = extractRoot / pkgName
    # The archive's one top-level entry is the package directory, and it
    # carries what the release ships.
    var entries: seq[string]
    for kind, path in walkDir(extractRoot):
      entries.add path.extractFilename
    doAssert entries == @[pkgName], $entries
    for rel in ["bin\\repro.exe", "bin\\reprobuild.exe",
                "share\\repro\\source\\config.nims",
                "share\\repro\\source\\libs\\repro_profile\\src\\repro_profile.nim",
                "share\\repro\\src\\reprobuild-test-adapters\\src\\" &
                  "repro_test_adapters\\test_runner.nim"]:
      doAssert fileExists(result / rel), "extracted bundle lacks " & rel

  proc scrubbedEnv(homeDir, stateBase, profileDir, storeRoot: string):
      StringTableRef =
    result = newStringTable(modeCaseInsensitive)
    for k, v in envPairs():
      let name = k.toUpperAscii()
      if name.startsWith("REPROBUILD_") or name.endsWith("_SRC"):
        continue
      if name in ["REPRO_BOOTSTRAP_SOURCE_ENV", "REPRO_PUBLIC_CLI_PATH",
                  "REPRO_NIM_COMPILER", "REPRO_HOME_STATE_DIR",
                  "REPRO_HOME_GENERATION_DIR"]:
        continue
      result[k] = v
    var kept: seq[string]
    for dir in getEnv("PATH").split(PathSep):
      if dir.len == 0:
        continue
      if fileExists(dir / "repro.exe") or fileExists(dir / "reprobuild.exe"):
        continue
      kept.add dir
    result["PATH"] = kept.join($PathSep)
    result["HOME"] = homeDir
    result["USERPROFILE"] = homeDir
    result["LOCALAPPDATA"] = stateBase
    result["XDG_STATE_HOME"] = stateBase
    result["REPRO_HOME_PROFILE_DIR"] = profileDir
    result["REPRO_STORE_ROOT"] = storeRoot
    result["REPRO_HOST"] = "gm1w-windows-bundle"

  proc assertScrubbed(env: StringTableRef) =
    ## The premise of the test, checked rather than assumed.
    for k, v in env.pairs:
      let name = k.toUpperAscii()
      doAssert not name.startsWith("REPROBUILD_"), "child env keeps " & k
      doAssert not name.endsWith("_SRC"), "child env keeps " & k
    for dir in env["PATH"].split(PathSep):
      doAssert not isUnder(dir, WorkspaceRoot),
        "child PATH reaches into the workspace: " & dir
    var nimFound = false
    for dir in env["PATH"].split(PathSep):
      if dir.len > 0 and fileExists(dir / "nim.exe"):
        nimFound = true
        break
    doAssert nimFound, "no nim.exe on the child PATH; run under `. .\\env.ps1`"

  type Scenario = object
    root, homeDir, stateDir, profileDir: string
    res: RunResult

  proc planWithBundle(bundle, label: string): Scenario =
    ## One `repro home apply --plan` of the minimal profile with the
    ## extracted bundle's `bin\repro.exe`, in fresh scratch state.
    result.root = createTempDir("gm1w-" & label & "-", "")
    result.homeDir = result.root / "home"
    let stateBase = result.root / "state home"
    result.profileDir = result.root / "profile"
    let storeRoot = result.root / "store"
    for dir in [result.homeDir, stateBase, result.profileDir, storeRoot]:
      createDir(extendedPath(dir))
    doAssert not isUnder(result.root, WorkspaceRoot)
    writeFile(extendedPath(result.profileDir / "home.nim"), ProfileBody)
    result.stateDir = stateBase / "repro" / "home"
    doAssert ' ' in result.stateDir
    let env = scrubbedEnv(result.homeDir, stateBase, result.profileDir,
      storeRoot)
    assertScrubbed(env)
    result.res = run(bundle / "bin" / "repro.exe", ["home", "apply", "--plan"],
      result.root, env)

  proc rbpiCount(stateDir: string): int =
    let cacheDir = stateDir / "profile-cache"
    if not dirExists(cacheDir):
      return 0
    for kind, path in walkDir(cacheDir):
      if kind == pcFile and path.endsWith(".rbpi"):
        inc result

  proc nimcacheDirOf(stateDir: string): string =
    for path in walkDirRec(stateDir / "profile-cache" / "nimcache"):
      if path.extractFilename == "profile-build.json":
        return path.parentDir

  suite "GM1w: e2e_windows_bundle_compiles_profile":

    let scratch = createTempDir("gm1w-pkg-", "")
    doAssert not isUnder(scratch, WorkspaceRoot)
    let bundle = packageAndExtract(scratch)
    let bundleSource = bundle / "share" / "repro" / "source"
    let bundleSrc = bundle / "share" / "repro" / "src"

    test "e2e_windows_bundle_compiles_profile: the extracted bundle plans " &
        "a profile with no REPROBUILD_* or *_SRC variable set":
      let s = planWithBundle(bundle, "plan")
      defer:
        try: removeDir(s.root) except OSError: discard
      checkpoint(s.res.output)
      check s.res.exitCode == 0
      check not s.res.output.contains("profile compilation failed")
      # Vacuity: the plan carries the profile's one resource, one envelope
      # was published, and a plan applies nothing.
      check s.res.output.contains("create  fs.userFile:~/" & MarkerName)
      check rbpiCount(s.stateDir) == 1
      check not fileExists(s.homeDir / MarkerName)

      # Which sources the compile used.
      let nimcache = nimcacheDirOf(s.stateDir)
      check nimcache.len > 0
      if nimcache.len > 0:
        let buildJson = readFile(nimcache / "profile-build.json")
        let doc = parseJson(buildJson)
        # The compile ran in the bundle's source root ...
        check lower(doc["currentDir"].getStr()) == lower(bundleSource)
        # ... and nothing it recorded (its `{.compile.}` C sources, the
        # include flags config.nims passed) lies in the workspace.
        check not lower(buildJson.replace("\\\\", "\\")).contains(
          lower(WorkspaceRoot) & "\\")
        # Every Nim module's absolute path, as the generated C embeds it.
        var fromLibs, fromSrc, fromWorkspace: seq[string]
        for path in walkDir(nimcache):
          if path.kind != pcFile or not path.path.endsWith(".nim.c"):
            continue
          let text = lower(readFile(path.path).replace("\\\\", "\\"))
          if text.contains(lower(bundleSource / "libs") & "\\"):
            fromLibs.add path.path.extractFilename
          if text.contains(lower(bundleSrc / "reprobuild-test-adapters") &
              "\\"):
            fromSrc.add path.path.extractFilename
          if text.contains(lower(WorkspaceRoot) & "\\"):
            fromWorkspace.add path.path.extractFilename
        # Printed, not only checkpointed, so a passing run records the counts.
        echo "    modules from share\\repro\\source\\libs: ", fromLibs.len,
          "; from share\\repro\\src: ", fromSrc,
          "; from the workspace: ", fromWorkspace.len
        check fromLibs.len > 0
        check fromSrc.len > 0
        check fromWorkspace.len == 0

    test "e2e_windows_bundle_compiles_profile: negative control - without " &
        "share\\repro the bundle refuses and names the missing sources":
      removeDir(bundle / "share" / "repro")
      doAssert not dirExists(bundleSource)
      let s = planWithBundle(bundle, "noshare")
      defer:
        try: removeDir(s.root) except OSError: discard
      checkpoint(s.res.output)
      check s.res.exitCode != 0
      check s.res.output.contains("no reprobuild sources")
      # The probed installed-layout root, and the variables that would
      # select a tree instead.
      check lower(s.res.output).contains(lower(bundleSource))
      check s.res.output.contains("$REPROBUILD_SOURCE_ROOT")
      check s.res.output.contains("$REPROBUILD_REPO_ROOT")
      # Not a compile that got as far as nim, and not this checkout.
      check not s.res.output.contains("cannot open file")
      check s.res.output.contains("does not run from that checkout")
      check rbpiCount(s.stateDir) == 0

    try: removeDir(scratch) except OSError: discard
