## M83 Phase C end-to-end test: drive the public library API
## (`compileProfileToRbpi`) end-to-end. The library submits TWO
## `BuildAction`s to one `runBuild`: the COMPILE edge, which spawns
## `repro.exe` with the `__repro-compile-profile` internal helper (`nim c`
## only), and the RUN edge, which launches the profile binary itself under
## the intent-output contract. So this gate exercises the full pair:
## BuildAction construction, action-cache lookup per edge, helper subprocess
## spawn, `nim c` invocation, the direct binary launch, the JSON->RBPI bridge,
## and atomic publish (reprobuild-pm `spec/Profile-Compilation-Model.md` §2).
##
## Scenarios:
##
##   - Cache miss: invokes Nim (via the helper subprocess), produces a
##     valid RBPI envelope at `<state-dir>/profile-cache/<profile-key>.rbpi`,
##     the bytes round-trip through `decodeRbpi`.
##   - Cache hit: a second invocation with no source change is answered
##     by the engine's ACTION CACHE on BOTH edges (neither is launched) and
##     does NOT rewrite the published file (mtime is preserved). There is no
##     structural fast path in front of the edges any more. The FIRST call
##     must have published both records: on Windows the compile edge's tree
##     (MSYS2's gcc toolchain, the engine's OpenSSL DLLs) draws a
##     stack-protector canary seed through `ProcessPrng` / `RtlGenRandom` in
##     almost every process, and before the split the unblessed single edge
##     therefore hit only on the THIRD call. The compile edge now carries the
##     provider compile's blessing, so this is the gate that the second call
##     is a hit on Windows as on Linux. Falsifying mutation: drop that
##     blessing (`nonDeterminism = ndpEntropyBlessed` in
##     `profileCompileBuildAction`) -- red on Windows: the first call's
##     compile edge is skipped with `unblessed-entropy` and the second
##     call's compile edge is not a hit.
##   - Re-run on touch: touching the profile source re-executes the edge
##     and republishes to the SAME per-profile path — the output name is
##     declared identity, not a content key.
##   - `forceRebuild`: setting the option forces both edges to re-run.
##   - Compile failure: a deliberately broken fixture surfaces the Nim
##     diagnostic and `compileProfileToRbpi` raises
##     `ProfileCompileError` naming the compile edge.
##   - A profile whose emitter never runs is refused with the profile's own
##     diagnostics -- including after an earlier successful run, whose intent
##     document the run edge must not leave behind to be served.
##   - A profile binary that exits non-zero fails the run edge, and its
##     stderr reaches the error.
##   - Direct helper-subcommand drive: `repro.exe __repro-compile-profile`
##     is callable on its own (the action-graph edge is just a wrapper),
##     links the binary and does not run it; the binary, run under the
##     intent-output contract, writes the intent the envelope is made of.
##
## The gate requires `build/bin/repro.exe` (built by `just build` or
## the recipe's `scripts/build_apps.sh` prelude).

import std/[os, osproc, strtabs, strutils, tempfiles, times, unittest]
from repro_core/paths import extendedPath

import repro_build_engine
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
    check first.edgeLaunched
    check first.compileEdge.launched
    check first.runEdge.launched
    # Both records were published on the FIRST run (see the header): the
    # compile edge's entropy, where the platform draws any, is excused by
    # its blessing; the run edge's tree (the profile binary) draws none.
    checkpoint("first: compile entropy=" &
      first.compileEdge.entropySources.join(",") & " run entropy=" &
      first.runEdge.entropySources.join(",") & " publishSkip=" &
      first.cachePublishSkipReason)
    check first.compileEdge.cachePublishSkipReason.len == 0
    check first.runEdge.cachePublishSkipReason.len == 0
    check first.runEdge.entropySources.len == 0
    let mtime1 = getLastModificationTime(first.rbpiPath)

    sleep(1100)  # NTFS / ext4 timestamp granularity.
    let second = compileProfileToRbpi(profilePath, compileOpts(stateDir))
    checkpoint("cacheDecision=" & $second.cacheDecision & " missReason=" &
      second.cacheMissReason & " firstPublishSkip=" &
      first.cachePublishSkipReason)
    check not second.edgeLaunched
    check second.cacheDecision == cdHit
    # The COMPILE edge is answered from the cache (nim not spawned), and so
    # is the run edge (the profile binary not spawned).
    check second.compileEdge.cacheDecision == cdHit
    check not second.compileEdge.launched
    check second.runEdge.cacheDecision == cdHit
    check not second.runEdge.launched
    check second.rbpiBytes == first.rbpiBytes
    check second.rbpiPath == first.rbpiPath
    let mtime2 = getLastModificationTime(second.rbpiPath)
    check mtime2 == mtime1

  test "touching the source re-runs the edge into the same artifact path":
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
    check second.edgeLaunched
    check second.compileEdge.launched
    # A trailing comment does not change the intent, so the envelope bytes
    # (and their digest) are unchanged; what matters is that the edge ran.
    check second.digestHex == first.digestHex
    check second.rbpiPath == first.rbpiPath
    var rbpiFiles: seq[string]
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        rbpiFiles.add p
    check rbpiFiles.len == 1

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
    check second.edgeLaunched
    check second.compileEdge.launched
    check second.runEdge.launched
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
      # The compile edge FAILED and its transcript is what is reported, not
      # the run edge it blocked.
      check "nim compile failed" in err.msg
    check caught
    var rbpiFiles = 0
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        inc rbpiFiles
    check rbpiFiles == 0

  test "a profile whose emitter never runs is refused, and no stale intent is served":
    # The run edge's declared output is the intent document, and the engine
    # removes it before every run (`removeBeforeRun`). Without that, a
    # profile edited so that it no longer reaches the emitter would exit 0,
    # leave the PREVIOUS run's document in place, and be encoded as this
    # run's intent -- a stale plan with a green exit.
    let stateDir = makeStateDir("missing-emitter")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let first = compileProfileToRbpi(profilePath, compileOpts(stateDir))
    check decodeRbpi(first.rbpiBytes).name == "homeBasic"

    writeFile(extendedPath(profilePath),
      "stderr.writeLine(\"missing emitter diagnostic\")\n")
    var caught = ""
    try:
      discard compileProfileToRbpi(profilePath, compileOpts(stateDir))
    except ProfileCompileError as err:
      caught = err.msg
    checkpoint(caught)
    check "printed no ProfileIntent JSON" in caught
    check "missing emitter diagnostic" in caught

  test "a failing profile binary fails the run edge with its own stderr":
    let stateDir = makeStateDir("runtime-failure")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = profileSrcDir / "home.nim"
    writeFile(extendedPath(profilePath),
      "stderr.writeLine(\"runtime failure detail\")\nquit(7)\n")
    var caught = ""
    try:
      discard compileProfileToRbpi(profilePath, compileOpts(stateDir))
    except ProfileCompileError as err:
      caught = err.msg
    checkpoint(caught)
    check ProfileRunActionId in caught
    check "runtime failure detail" in caught
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

  test "helper links the profile binary on its own and does not run it":
    let stateDir = makeStateDir("helper-direct")
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let binaryPath = stateDir / "bin" / addFileExt("profile-build", ExeExt)
    let nimcacheDir = stateDir / "nimcache"
    createDir(extendedPath(stateDir))

    var env = newStringTable()
    for k, v in envPairs():
      env[k] = v
    let p = startProcess(reproBinary(), args = [
        "__repro-compile-profile",
        "--profile", profilePath,
        "--binary", binaryPath,
        "--nimcache", nimcacheDir,
        "--repo-root", ProjectRoot
      ],
      env = env,
      options = {poUsePath, poStdErrToStdOut})
    let exitCode = p.waitForExit()
    p.close()
    check exitCode == 0
    check fileExists(extendedPath(binaryPath))

    # The run edge's invocation: the binary, under the intent-output
    # contract, writes the document the envelope is encoded from.
    let document = stateDir / "intent.json"
    check not fileExists(extendedPath(document))
    let run = startProcess(binaryPath, args = [ReproIntentOutFlag, document],
      options = {poStdErrToStdOut})
    check run.waitForExit() == 0
    run.close()
    let recovered = decodeRbpi(rbpiBytesFromJson(
      readFile(extendedPath(document))))
    check recovered.name == "homeBasic"
    check recovered.activities.len == 1
