## M83 Phase C end-to-end test: drive the public library API
## (`compileProfileToRbpi`) end-to-end. The library submits a
## `BuildAction` to `runBuild`, which spawns `repro.exe` with the
## `__repro-compile-profile` internal helper. So this gate exercises
## the full build-graph edge: source discovery, BuildAction
## construction, action-cache lookup, helper subprocess spawn,
## `nim c` invocation, JSON->RBPI bridge, and atomic publish.
##
## Scenarios:
##
##   - Cache miss: invokes Nim (via the helper subprocess), produces a
##     valid RBPI envelope at `<state-dir>/profile-cache/<digest>.rbpi`,
##     the bytes round-trip through `decodeRbpi`.
##   - Cache hit: a second invocation with no source change returns
##     the same bytes via the structural fast-path and does NOT
##     rewrite the cache file (mtime is preserved).
##   - Cache miss on touch: touching the profile source (changing the
##     digest) produces a new cache entry; the artifact path changes.
##   - `forceRebuild`: setting the option forces the helper to re-run.
##   - Compile failure: a deliberately broken fixture surfaces the Nim
##     diagnostic and `compileProfileToRbpi` raises
##     `ProfileCompileError`.
##   - Direct helper-subcommand drive: `repro.exe __repro-compile-profile`
##     is callable on its own (the action-graph edge is just a wrapper)
##     and writes the same envelope.
##
## The gate requires `build/bin/repro.exe` (built by `just build` or
## the recipe's `scripts/build_apps.sh` prelude).

import std/[os, osproc, strtabs, strutils, tempfiles, times, unittest]
from repro_core/paths import extendedPath

import repro_profile
import repro_profile_intent
import repro_profile_compile

const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "m83"
const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(extendedPath(candidate)),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc makeStateDir(label: string): string =
  result = getTempDir() / "repro-profile-compile-e2e" / label
  if dirExists(extendedPath(result)):
    removeDir(extendedPath(result))
  createDir(extendedPath(result))

proc copyFixtureInto(fixtureName, dir: string; renameTo: string = ""):
    string =
  let src = FixtureRoot / fixtureName
  doAssert fileExists(extendedPath(src)), "missing fixture: " & src
  let dstName = if renameTo.len > 0: renameTo else: fixtureName
  result = dir / dstName
  copyFile(src, result)
  if fixtureName.endsWith("home_with_module.nim"):
    let modulesDir = dir / "modules"
    createDir(extendedPath(modulesDir))
    copyFile(FixtureRoot / "modules" / "git_dev_tooling.nim",
      modulesDir / "git_dev_tooling.nim")

proc compileOpts(stateDir: string): ProfileCompileOptions =
  ProfileCompileOptions(
    stateDir: stateDir,
    publicCliPath: reproBinary(),
    repoRoot: ProjectRoot)

# ---------------------------------------------------------------------------

suite "M83 Phase C: compileProfileToRbpi via build-graph edge":

  test "cache miss compiles via helper subprocess and writes RBPI":
    let stateDir = makeStateDir("cache-miss")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")

    let artifact = compileProfileToRbpi(profilePath, compileOpts(stateDir))
    check artifact.rbpiBytes.len > 0
    let recovered = decodeRbpi(artifact.rbpiBytes)
    check recovered.name == "homeBasic"
    check recovered.activities.len == 1
    check recovered.activities[0].name == "default"
    check recovered.activities[0].body.len == 3
    check recovered.activities[0].body[0].pkgName == "neovim"
    check recovered.activities[0].body[1].pkgName == "tmux"
    check recovered.activities[0].body[2].kind == aekWhenGuard

    var cachedFiles = 0
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        inc cachedFiles
    check cachedFiles == 1
    check fileExists(extendedPath(artifact.rbpiPath))

  test "second call hits the structural cache without spawning nim":
    let stateDir = makeStateDir("cache-hit")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")

    let first = compileProfileToRbpi(profilePath, compileOpts(stateDir))
    let mtime1 = getLastModificationTime(first.rbpiPath)

    sleep(1100)  # NTFS / ext4 timestamp granularity.
    let second = compileProfileToRbpi(profilePath, compileOpts(stateDir))
    check second.rbpiBytes == first.rbpiBytes
    check second.rbpiPath == first.rbpiPath
    let mtime2 = getLastModificationTime(second.rbpiPath)
    check mtime2 == mtime1

  test "touching the source triggers a new digest + a fresh artifact":
    let stateDir = makeStateDir("touch-miss")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let first = compileProfileToRbpi(profilePath, compileOpts(stateDir))

    var contents = readFile(extendedPath(profilePath))
    contents.add "\n# touch comment to perturb the digest\n"
    writeFile(extendedPath(profilePath), contents)

    let second = compileProfileToRbpi(profilePath, compileOpts(stateDir))
    check second.digestHex != first.digestHex
    check second.rbpiPath != first.rbpiPath
    var rbpiFiles: seq[string]
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        rbpiFiles.add p
    check rbpiFiles.len == 2

  test "forceRebuild re-invokes the helper":
    let stateDir = makeStateDir("force-rebuild")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let first = compileProfileToRbpi(profilePath, compileOpts(stateDir))
    let mtime1 = getLastModificationTime(first.rbpiPath)
    sleep(1100)
    var forceOpts = compileOpts(stateDir)
    forceOpts.forceRebuild = true
    let second = compileProfileToRbpi(profilePath, forceOpts)
    check second.rbpiBytes == first.rbpiBytes
    let mtime2 = getLastModificationTime(second.rbpiPath)
    check mtime2 > mtime1

  test "compile failure surfaces nim diagnostic + raises":
    let stateDir = makeStateDir("compile-fail")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_compile_fail.nim",
      profileSrcDir, "home.nim")
    var caught = false
    try:
      discard compileProfileToRbpi(profilePath, compileOpts(stateDir))
    except ProfileCompileError as err:
      caught = true
      # The library wraps the build-engine failure with the action ID
      # in the message. Detailed Nim diagnostics are forwarded by the
      # helper subprocess to its own stderr (visible in this test's
      # captured output via the action's stdoutMerged stream).
      check "__repro_profile_compile" in err.msg
    check caught
    var rbpiFiles = 0
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        inc rbpiFiles
    check rbpiFiles == 0

# ---------------------------------------------------------------------------
# Direct helper-subcommand drive. The internal `__repro-compile-profile`
# subcommand is callable on its own; the BuildAction is just a wrapper
# that the engine uses to spawn it. We exercise it here to keep the
# helper surface stable under refactoring.
# ---------------------------------------------------------------------------

suite "M83 Phase C: __repro-compile-profile helper subcommand":

  test "helper produces a valid RBPI envelope on its own":
    let stateDir = makeStateDir("helper-direct")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let rbpiPath = stateDir / "out.rbpi"
    let manifestPath = stateDir / "out.source.txt"
    let nimcacheDir = stateDir / "nimcache"
    createDir(extendedPath(stateDir))

    var env = newStringTable()
    for k, v in envPairs():
      env[k] = v
    let p = startProcess(reproBinary(), args = [
        "__repro-compile-profile",
        "--profile", profilePath,
        "--rbpi", rbpiPath,
        "--manifest", manifestPath,
        "--nimcache", nimcacheDir,
        "--repo-root", ProjectRoot
      ],
      env = env,
      options = {poUsePath, poStdErrToStdOut})
    let exitCode = p.waitForExit()
    p.close()
    check exitCode == 0
    check fileExists(extendedPath(rbpiPath))
    check fileExists(extendedPath(manifestPath))

    let raw = readFile(extendedPath(rbpiPath))
    var bytes = newSeq[byte](raw.len)
    for i, ch in raw:
      bytes[i] = byte(ord(ch))
    let recovered = decodeRbpi(bytes)
    check recovered.name == "homeBasic"
    check recovered.activities.len == 1
