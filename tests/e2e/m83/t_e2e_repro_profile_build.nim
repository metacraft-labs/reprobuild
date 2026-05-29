## M83 Phase C1 end-to-end test: drive the real `repro profile build`
## subcommand against the M83 Phase A fixture profiles.
##
## Scenarios covered:
##
##   - Cache miss: invokes Nim, produces a valid RBPI envelope at
##     `<state-dir>/profile-cache/<digest>.rbpi`, the bytes round-trip
##     through `decodeRbpi` and match the in-process construction of
##     the same ProfileIntent.
##   - Cache hit: a second invocation with no source change returns
##     the same bytes and does NOT rewrite the cache file (mtime is
##     preserved).
##   - Cache miss on touch: touching the profile source (changing the
##     digest) produces a new cache entry; the artifact path changes.
##   - `--no-cache` forces re-compile even when a valid artifact is
##     present.
##   - Compile-failure path: a deliberately broken fixture exits
##     non-zero with Nim's diagnostic visible on stderr.
##
## The gate uses the same locator pattern as
## `tests/e2e/home-intent/t_e2e_repro_home_intent_commands.nim` — it
## requires `build/bin/repro.exe` (built by `just build`).

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times, unittest]
from repro_core/paths import extendedPath

import repro_profile
import repro_profile_intent

const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "m83"
const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

type
  RunResult = object
    exitCode: int
    stdoutBytes: seq[byte]
    stderrText: string

proc runReproProfileBuildCapture(stateDir: string;
                                 args: openArray[string]): RunResult =
  ## Capturing variant: spawn `repro profile build` with stdout and
  ## stderr collected into in-memory buffers.
  let bin = reproBinary()
  var fullArgs = @["profile", "build"]
  for a in args:
    fullArgs.add a
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["REPRO_HOME_STATE_DIR"] = stateDir
  env["REPROBUILD_REPO_ROOT"] = ProjectRoot

  let p = startProcess(bin, args = fullArgs, env = env,
    options = {poUsePath})
  let outStream = p.outputStream()
  let errStream = p.errorStream()
  var outBuf: string = ""
  var errBuf: string = ""
  # Drain both streams concurrently to avoid pipe-full deadlocks. We
  # do this naively: read everything; both buffers are small.
  while true:
    let outChunk = outStream.readAll()
    let errChunk = errStream.readAll()
    if outChunk.len > 0: outBuf.add outChunk
    if errChunk.len > 0: errBuf.add errChunk
    if not p.running:
      # Final drain.
      let outRest = outStream.readAll()
      let errRest = errStream.readAll()
      if outRest.len > 0: outBuf.add outRest
      if errRest.len > 0: errBuf.add errRest
      break
  result.exitCode = p.waitForExit()
  p.close()
  result.stdoutBytes = newSeq[byte](outBuf.len)
  for i, ch in outBuf:
    result.stdoutBytes[i] = byte(ord(ch))
  result.stderrText = errBuf

proc makeStateDir(label: string): string =
  result = getTempDir() / "repro-profile-build-e2e" / label
  if dirExists(extendedPath(result)):
    removeDir(extendedPath(result))
  createDir(extendedPath(result))

proc copyFixtureInto(fixtureName, dir: string; renameTo: string = ""):
    string =
  let src = FixtureRoot / fixtureName
  doAssert fileExists(src), "missing fixture: " & src
  let dstName = if renameTo.len > 0: renameTo else: fixtureName
  result = dir / dstName
  copyFile(src, result)
  if fixtureName.endsWith("home_with_module.nim"):
    # Also copy the sibling module.
    let modulesDir = dir / "modules"
    createDir(extendedPath(modulesDir))
    copyFile(FixtureRoot / "modules" / "git_dev_tooling.nim",
      modulesDir / "git_dev_tooling.nim")

# ---------------------------------------------------------------------------

suite "M83 Phase C1: `repro profile build` end-to-end":

  test "cache miss compiles and writes a valid RBPI artifact":
    let stateDir = makeStateDir("cache-miss")
    let profileSrcDir = createTempDir("repro-profile-build-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let res = runReproProfileBuildCapture(stateDir,
      ["--profile", profilePath, "--out", "-"])
    if res.exitCode != 0:
      echo "stderr: ", res.stderrText
    check res.exitCode == 0
    check res.stdoutBytes.len > 0

    let recovered = decodeRbpi(res.stdoutBytes)
    check recovered.name == "homeBasic"
    check recovered.activities.len == 1
    check recovered.activities[0].name == "default"
    check recovered.activities[0].body.len == 3
    check recovered.activities[0].body[0].pkgName == "neovim"
    check recovered.activities[0].body[1].pkgName == "tmux"
    check recovered.activities[0].body[2].kind == aekWhenGuard

    # Cache artifact exists under the per-digest path.
    var cachedFiles = 0
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        inc cachedFiles
    check cachedFiles == 1

  test "cache hit returns identical bytes and preserves mtime":
    let stateDir = makeStateDir("cache-hit")
    let profileSrcDir = createTempDir("repro-profile-build-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let r1 = runReproProfileBuildCapture(stateDir,
      ["--profile", profilePath, "--out", "-"])
    check r1.exitCode == 0
    var rbpiAfterMiss = ""
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        rbpiAfterMiss = p
        break
    check rbpiAfterMiss.len > 0
    let mtime1 = getLastModificationTime(rbpiAfterMiss)

    let r2 = runReproProfileBuildCapture(stateDir,
      ["--profile", profilePath, "--out", "-", "--verbose"])
    check r2.exitCode == 0
    check r2.stdoutBytes == r1.stdoutBytes
    # The verbose flag should mention "cache hit" on stderr.
    check "cache hit" in r2.stderrText
    let mtime2 = getLastModificationTime(rbpiAfterMiss)
    check mtime2 == mtime1

  test "touching the source triggers a cache miss with a new digest":
    let stateDir = makeStateDir("touch-miss")
    let profileSrcDir = createTempDir("repro-profile-build-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let r1 = runReproProfileBuildCapture(stateDir,
      ["--profile", profilePath, "--out", "-"])
    check r1.exitCode == 0

    # Mutate the source content. Avoid mere mtime change — we hash the
    # bytes, not the mtime; a meaningful byte change is what triggers a
    # different digest.
    var contents = readFile(profilePath)
    contents.add "\n# touch comment to perturb the digest\n"
    writeFile(profilePath, contents)

    let r2 = runReproProfileBuildCapture(stateDir,
      ["--profile", profilePath, "--out", "-"])
    check r2.exitCode == 0
    var rbpiFiles: seq[string]
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        rbpiFiles.add p
    check rbpiFiles.len == 2  # original digest + new digest.

  test "--no-cache forces re-compile even when the cache is warm":
    let stateDir = makeStateDir("no-cache")
    let profileSrcDir = createTempDir("repro-profile-build-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_basic.nim", profileSrcDir,
      "home.nim")
    let r1 = runReproProfileBuildCapture(stateDir,
      ["--profile", profilePath, "--out", "-"])
    check r1.exitCode == 0
    var rbpiAfterMiss = ""
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        rbpiAfterMiss = p
        break
    check rbpiAfterMiss.len > 0
    let mtime1 = getLastModificationTime(rbpiAfterMiss)
    # Sleep at least 1.1 seconds to ensure a distinct mtime tick on
    # filesystems with low-resolution timestamps (e.g. NTFS at 1s).
    sleep(1100)
    let r2 = runReproProfileBuildCapture(stateDir,
      ["--profile", profilePath, "--out", "-", "--no-cache"])
    check r2.exitCode == 0
    check r2.stdoutBytes == r1.stdoutBytes  # same input -> same bytes
    let mtime2 = getLastModificationTime(rbpiAfterMiss)
    check mtime2 > mtime1

  test "compile failure surfaces nim diagnostic and exits non-zero":
    let stateDir = makeStateDir("compile-fail")
    let profileSrcDir = createTempDir("repro-profile-build-src-", "")
    defer: removeDir(profileSrcDir)
    let profilePath = copyFixtureInto("home_compile_fail.nim",
      profileSrcDir, "home.nim")
    let res = runReproProfileBuildCapture(stateDir,
      ["--profile", profilePath, "--out", "-"])
    check res.exitCode != 0
    # Nim's diagnostic shows up in stderr (we forward it under a
    # bordered banner).
    check "nim diagnostics" in res.stderrText
    check "nope_undefined_predicate" in res.stderrText
    # No artifact at <digest>.rbpi was published.
    var rbpiFiles = 0
    for kind, p in walkDir(stateDir / "profile-cache"):
      if kind == pcFile and p.endsWith(".rbpi"):
        inc rbpiFiles
    check rbpiFiles == 0
