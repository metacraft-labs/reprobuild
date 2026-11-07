## Gradual-Nix-To-Reprobuild-Migration GM1 gate:
## `e2e_profile_compile_path_with_spaces`.
##
## A profile under a directory whose name has a space, with a state directory
## whose path has a space, compiles and plans through the real
## `repro home apply --plan`.
##
## The failure this pins down
## --------------------------
## `compileProfileBinary` used to assemble the `nim c` command as ONE string,
## quoting each path with `quoteShell`, and then split it again with
## `parseCmdLine`. On POSIX `quoteShell` quotes with single quotes and
## `parseCmdLine` does not honour them, so `--nimcache:'/a b/c'` came apart at
## the space and nim saw a stray positional argument:
##
##   Error: arguments can only be given if the '--run' option is selected
##
## The nimcache lives under the state directory, and the macOS default state
## directory is `~/Library/Application Support/repro/home` — so EVERY macOS
## apply failed this way, not just exotic layouts.
##
## How the state directory gets its space
## --------------------------------------
## The test does not set `REPRO_HOME_STATE_DIR`; it points the OS-default
## resolution (`repro_home_generations.osDefaultStateDir`) at a scratch HOME
## instead, so the path under test IS the default an operator gets: on macOS
## `$HOME/Library/Application Support/repro/home` (the space comes from Apple's
## layout, exactly as on a real Mac), on Linux `$XDG_STATE_HOME/repro/home`
## with an `XDG_STATE_HOME` that contains a space, on Windows
## `%LOCALAPPDATA%\repro\home` likewise.
##
## Vacuity guard: the plan must name the one `fs.userFile` resource the
## profile declares (by its host file and its content-bearing address), the
## compiled `.rbpi` must exist under the spaced state directory, and the
## planned file must NOT exist afterwards (a plan writes nothing). An apply
## that silently skipped the compile, or planned an empty intent, fails here.
##
## Falsifying mutation (performed while writing the test, 2026-10-13):
## restoring the `quoteShell` + `parseCmdLine` round-trip in
## `compileProfileBinary` makes the first case fail on POSIX with nim's
## `arguments can only be given if the '--run' option is selected`.
##
## Mocks: none. The real `build/bin/repro`, the real build engine spawning the
## real `__repro-compile-profile` helper, a real `nim c` and the real planner.
## Only HOME / XDG_STATE_HOME / LOCALAPPDATA are redirected, so nothing outside
## the scratch directory is read as state or written.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_profile_compile

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()

const MarkerName = "gm1-space-marker.txt"
const ProfileBody = """
import repro_profile

profile "gm1PathWithSpaces":
  resources:
    fsUserFile(hostFile = "~/""" & MarkerName & """",
      content = "planned through a path with a space\n")
"""

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  result = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(extendedPath(result)),
    "repro binary not found at " & result & "; build with `just build` first"

proc runRepro(env: StringTableRef; cwd: string;
              args: openArray[string]): tuple[exitCode: int; output: string] =
  let p = startProcess(reproBinary(), workingDir = cwd, args = @args,
    env = env, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc expectedDefaultStateDir(homeDir, spacedBase: string): string =
  ## The state directory `osDefaultStateDir` resolves to under the
  ## environment `scratchEnv` builds. Spelled out independently of the
  ## production proc so a change there cannot quietly move the path under
  ## test away from the one with the space.
  when defined(windows):
    spacedBase / "repro" / "home"
  elif defined(macosx):
    homeDir / "Library" / "Application Support" / "repro" / "home"
  else:
    spacedBase / "repro" / "home"

proc scratchEnv(homeDir, spacedBase, profileDir, storeRoot: string):
    StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  # The default state directory is what is under test; an inherited override
  # would replace it with whatever the caller's shell happens to hold.
  for name in ["REPRO_HOME_STATE_DIR", "REPRO_HOME_GENERATION_DIR"]:
    if result.hasKey(name):
      result.del(name)
  result["HOME"] = homeDir
  result["USERPROFILE"] = homeDir
  result["XDG_STATE_HOME"] = spacedBase
  result["LOCALAPPDATA"] = spacedBase
  result["REPRO_HOME_PROFILE_DIR"] = profileDir
  result["REPRO_STORE_ROOT"] = storeRoot
  result["REPRO_HOST"] = "gm1-path-with-spaces"

proc rbpiFilesUnder(stateDir: string): seq[string] =
  let cacheDir = stateDir / "profile-cache"
  if not dirExists(extendedPath(cacheDir)):
    return
  for kind, path in walkDir(cacheDir):
    if kind == pcFile and path.endsWith(".rbpi"):
      result.add path

suite "GM1: e2e_profile_compile_path_with_spaces":

  test "e2e_profile_compile_path_with_spaces: apply --plan compiles a " &
      "spaced profile into the spaced default state dir":
    let root = createTempDir("repro-gm1-spaces-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let homeDir = root / "home"
    let spacedBase = root / "state home"
    let profileDir = root / "my profile"
    let storeRoot = root / "store"
    for dir in [homeDir, spacedBase, profileDir, storeRoot]:
      createDir(extendedPath(dir))
    writeFile(extendedPath(profileDir / "home.nim"), ProfileBody)

    let stateDir = expectedDefaultStateDir(homeDir, spacedBase)
    # The premise of the test: both paths really carry a space.
    doAssert ' ' in stateDir, "state dir under test has no space: " & stateDir
    doAssert ' ' in profileDir

    let env = scratchEnv(homeDir, spacedBase, profileDir, storeRoot)
    let res = runRepro(env, root, ["home", "apply", "--plan"])
    checkpoint(res.output)
    check res.exitCode == 0
    check not res.output.contains("arguments can only be given")
    check not res.output.contains("profile compilation failed")

    # Vacuity: the plan carries the profile's one resource. Its address is
    # derived from the host file, so the marker name must appear.
    check res.output.contains("create  fs.userFile:~/" & MarkerName)

    # The compile really ran into the default (spaced) state directory.
    check rbpiFilesUnder(stateDir).len == 1

    # A plan applies nothing.
    check not fileExists(extendedPath(homeDir / MarkerName))

  test "e2e_profile_compile_path_with_spaces: the nim argv keeps each " &
      "spaced path as one argument":
    # The argv contract itself, independent of any process launch: one
    # element per flag, the path inside it verbatim with no shell quoting.
    let nimcache = "/state dir/profile-cache/nimcache/abc"
    let outBinary = nimcache / "profile-build"
    let profile = "/my profile/home.nim"
    let argv = profileCompileArgv("/opt/nim dir/bin/nim", profile, nimcache,
      outBinary, ProjectRoot)
    check argv[0] == "/opt/nim dir/bin/nim"
    check argv[1] == "c"
    check ("--nimcache:" & nimcache) in argv
    check ("--out:" & outBinary) in argv
    check argv[^1] == profile
    for arg in argv:
      check '\'' notin arg
    # Every library root is its own `--path:` element.
    let pathArgs = block:
      var paths: seq[string]
      for arg in argv:
        if arg.startsWith("--path:"):
          paths.add arg
      paths
    check pathArgs.len == profileNimPaths(ProjectRoot).len
    check pathArgs.len > 0
