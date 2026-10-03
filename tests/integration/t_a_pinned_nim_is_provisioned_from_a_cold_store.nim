## M5 "pin the provider-compile toolchain", end to end: a project pins a Nim
## that is NOT the bootstrap's own (2.2.8; the bootstrap fetches 2.2.10), and
## a reprobuild with an EMPTY store provisions it from the official release
## archive and compiles the project's provider with it.
##
## Reprobuild-specs Distribution-And-Packaging.milestones.org, M5. The user's
## direction (2026-10-01): a pinned Nim of any released version is provisioned
## automatically, as a regular package, with the bootstrap's hard-failure
## semantics, verified against a digest that is part of the pin.
##
## WHAT IS REAL HERE. `build/bin/reprobuild` from this checkout, nim-lang.org,
## a fresh store in a temporary directory, the binary cache disabled.
##
##   1. `repro lock refresh` resolves the store-sourced `nim ==2.2.8` to the
##      official archive for this platform and records its URL and SHA-256 in
##      the committed lock. The digests asserted below were measured by
##      downloading each archive on 2026-10-01; they equal nim-lang.org's
##      published `.sha256` files.
##   2. `repro build` in that project, with a store that holds no Nim at all,
##      realizes nim 2.2.8 from that archive through the tool store's
##      provisioning edge (verified against the LOCK's digest; on Linux built
##      from the source archive), installs it at the pin's prefix, and
##      compiles the provider with it. The recipe REFUSES to compile under any
##      other Nim (`when NimVersion != "2.2.8": {.error.}`), so a provider
##      compiled by the bootstrap's 2.2.10 -- or by a `nim` found on PATH of
##      another version -- fails the build.
##   3. Negative control: the same recipe, in a project whose lock pins no
##      Nim, fails to build with the guard's message naming the bootstrap's
##      version. Without it, a guard that never fired would pass step 2.
##
## The C compiler that the provider compile hands to Nim is the host's `gcc`
## when one is on PATH (named through `REPRO_BOOTSTRAP_CC`, as the hand-over
## test does), so this test does not also provision the bootstrap gcc into
## its cold store; the cold-store claim is about the Nim.
##
## No mocks. A network test: it downloads nim 2.2.8 (and, for the control,
## the bootstrap's nim 2.2.10) from nim-lang.org into its temporary store.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times,
            unittest]
import repro_test_support/reasoned_skip

import repro_core/cli_images
import repro_lock
import repro_selfhost
import repro_tool_profiles

# Ambient-execution hatch: this test runs the engine binary under test, the
# Nim it provisioned, and finds the host's gcc. `git grep uncontrolled` is the
# audit surface.
import repro_core/ambient_execution

const
  PinnedNim = "2.2.8"
  BootstrapNim = "2.2.10"

type PinnedArchive = tuple[url, sha256, build: string]

proc expectedArchive(platform: string): PinnedArchive =
  ## The archive `repro lock refresh` must pin for nim 2.2.8 on `platform`.
  ## Each digest was measured by downloading the archive (2026-10-01) and
  ## equals nim-lang.org's published `<archive>.sha256`.
  case platform
  of "amd64-windows":
    ("https://nim-lang.org/download/nim-2.2.8_x64.zip",
     "11fe2415a64a791b899cc78e2eeacdde93b5f122f2fabc447db36d38002bfb8c",
     LockedArchiveBinary)
  of "arm64-macosx":
    ("https://nim-lang.org/download/nim-2.2.8-macosx_arm64.tar.xz",
     "b4b804ec4dc4eb8e89fe12751481a7fb11a8e4b8918f110068be6cceafe52a8e",
     LockedArchiveBinary)
  of "amd64-macosx":
    ("https://nim-lang.org/download/nim-2.2.8-macosx_x64.tar.xz",
     "c77c945cd3e465bdba76ddd6393fe5babf0a724f162c9ecb4bffec19b83e88ba",
     LockedArchiveBinary)
  of "amd64-linux", "arm64-linux":
    ("https://nim-lang.org/download/nim-2.2.8.tar.xz",
     "114191afa083c5059dcbe5ce88dbe4f42542cff04e2c3017668ee438bc0b8cfc",
     LockedArchiveSource)
  else:
    ("", "", "")

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc engineBinary(): string =
  ## A missing binary is a BUILD defect: raise, never skip.
  result = findRepoRoot() / "build" / "bin" / reprobuildEngineExeName()
  if not fileExists(result):
    raise newException(IOError, result & " is missing. Build it with " &
      "`just build` / scripts/build_apps.sh.")

proc recipe(token: string): string =
  ## `token` makes the recipe text unique to this run, so no provider or
  ## interface artifact compiled by an earlier run (with whatever Nim) can be
  ## served for it.
  "import repro_project_dsl\n\n" &
  "# run " & token & "\n" &
  "when NimVersion != \"" & PinnedNim & "\":\n" &
  "  {.error: \"provider compiled with Nim \" & NimVersion & \", not the " &
    "pinned " & PinnedNim & "\".}\n\n" &
  "package pinnedNimProbe:\n" &
  "  build:\n" &
  "    discard\n"

proc solverInputs(nimSource: string): string =
  ## The project's solver inputs, as the `repro.solver` sidecar spells them.
  ## `repro lock refresh --inputs` reads them verbatim instead of compiling
  ## the recipe: before the first refresh there is no pin, so compiling it
  ## would use the bootstrap's Nim, which the recipe's guard refuses.
  "package pinnedNimProbe\nversions: 0.1.0\ndepends: nim ==" & PinnedNim &
    "\n\npackage nim\nversions: " & PinnedNim & "\nsource: " & nimSource & "\n"

proc drain(s: Stream): string =
  var chunk = newString(4096)
  while true:
    let n = s.readData(addr chunk[0], chunk.len)
    if n <= 0:
      break
    result.add(chunk[0 ..< n])

type Run = object
  code: int
  output: string

proc runEngine(cwd, storeRoot, cacheRoot: string; args: seq[string]): Run =
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["REPRO_STORE_ROOT"] = storeRoot
  env["REPROBUILD_ACTION_CACHE_ROOT"] = cacheRoot
  env["REPRO_SELFHOST_DEBUG"] = "1"
  env["REPRO_CACHE_DISABLE"] = "1"
  env["REPROBUILD_NO_RUNQUOTA"] = "1"
  env["REPROBUILD_PROGRESS"] = "quiet"
  env["REPRO_DAEMON"] = "off"
  # A compiler nothing has used before has an empty nimcache, so the
  # interface extraction and the provider compile are both COLD compiles of
  # the whole DSL (hundreds of C units each). Measured on a loaded Windows
  # host (2026-10-02) the first one ran past the default 1800 s cap while
  # still making progress. The cap stays finite, so a wedged compile still
  # fails the test rather than hanging it.
  env["REPRO_INTERFACE_COMPILE_TIMEOUT_SECONDS"] = "7200"
  env["REPRO_FULL_CLI"] = engineBinary()
  env["REPRO_PUBLIC_CLI_PATH"] = engineBinary()
  for name in ["REPRO_SELFHOST_RESOLVED", "REPRO_NIM_COMPILER",
               "REPRO_LOCK_PINS", "REPRO_LOCK_PATH"]:
    if env.hasKey(name):
      env.del(name)
  let cc = uncontrolledFindExe("gcc")
  if cc.len > 0:
    env["REPRO_BOOTSTRAP_CC"] = cc
  var p = uncontrolledStartProcess(engineBinary(), workingDir = cwd,
    args = args, env = env, options = {poStdErrToStdOut})
  try:
    result.output = drain(p.outputStream)
    result.code = p.waitForExit()
  finally:
    p.close()

proc nimDep(lockPath: string): LockedDep =
  for d in parseLockedDependencies(readFile(lockPath)).deps:
    if d.name == "nim":
      return d
  raise newException(KeyError, lockPath & " has no nim dep")

const
  HostPlatform = hostCPU & "-" & hostOS
    ## `currentPlatformId()`'s spelling, at compile time, so the platform gate
    ## below is a `when`.
  Expected = expectedArchive(HostPlatform)

suite "a pinned Nim is provisioned from a cold store and compiles the provider":
  let platform = currentPlatformId()
  doAssert platform == HostPlatform
  let expected = Expected
  let root = createTempDir("repro-pinned-nim-e2e-", "")
  let store = root / "store"
  let cache = root / "action-cache"
  let token = $getCurrentProcessId() & "-" & $epochTime()

  test "lock refresh pins the official archive and its digest":
    when Expected.url.len == 0:
      skip("no expected nim " & PinnedNim & " archive is recorded here for " &
        HostPlatform)
    else:
      let project = root / "pinned"
      createDir(project)
      writeFile(project / "repro.nim", recipe(token))
      writeFile(project / "repro.solver", solverInputs("store"))
      let r = runEngine(project, store, cache, @["lock", "refresh", "--inputs",
        project / "repro.solver"])
      checkpoint("rc=" & $r.code & "\n" & r.output)
      require r.code == 0
      let dep = nimDep(project / "repro.lock")
      check dep.coordinates.kind == ckStore
      check dep.version == PinnedNim
      check dep.archive.url == expected.url
      check dep.archive.sha256 == expected.sha256
      check dep.archive.build == expected.build

  test "a build with an empty store provisions it and compiles with it":
    when Expected.url.len == 0:
      skip("no expected nim " & PinnedNim & " archive is recorded here for " &
        HostPlatform)
    else:
      let project = root / "pinned"
      require fileExists(project / "repro.lock")
      let pin = projectPinsFor(project).providerNim
      require pin.state == spsPinned
      let prefix = selfPrefixAbsolutePath(store, pin)
      let exe = pinnedExecutableIn(providerNimPin(), prefix)
      let archive = store / "tool-store" / "downloads" /
        (expected.sha256 & ".archive")
      # Cold: nothing provides this Nim yet, and its archive was never
      # downloaded into this store.
      check not dirExists(prefix)
      check not fileExists(archive)
      let r = runEngine(project, store, cache, @["build", "--no-runquota",
        "--daemon=off"])
      checkpoint("rc=" & $r.code & "\n" & r.output)
      check r.code == 0
      check r.output.contains("realizing the pinned provider compiler nim " &
        PinnedNim & " from " & expected.url)
      check r.output.contains("provider compiler " & exe)
      check not r.output.contains("provider compiled with Nim")
      check fileExists(exe)
      check fileExists(prefix / "lib" / "system.nim")
      # The archive that was realized is the one the lock pins, by digest.
      check fileExists(archive)
      if fileExists(archive):
        check fileSha256Hex(archive) == expected.sha256
      # And it is the pinned version.
      if fileExists(exe):
        let v = uncontrolledExecCmdEx(quoteShell(exe) & " --version")
        checkpoint(v.output)
        check v.output.startsWith("Nim Compiler Version " & PinnedNim)

  test "control: without the pin the same recipe is refused by its guard":
    when Expected.url.len == 0:
      skip("no expected nim " & PinnedNim & " archive is recorded here for " &
        HostPlatform)
    else:
      let project = root / "unpinned"
      createDir(project)
      writeFile(project / "repro.nim", recipe(token & "-control"))
      writeFile(project / "repro.solver", solverInputs("nim"))
      let refresh = runEngine(project, store, cache, @["lock", "refresh", "--inputs",
        project / "repro.solver"])
      checkpoint("refresh rc=" & $refresh.code & "\n" & refresh.output)
      require refresh.code == 0
      check not readFile(project / "repro.lock").contains("archive_")
      check projectPinsFor(project).providerNim.state == spsNotAddressable
      let r = runEngine(project, store, cache, @["build", "--no-runquota",
        "--daemon=off"])
      checkpoint("rc=" & $r.code & "\n" & r.output)
      check r.code != 0
      check r.output.contains("provider compiled with Nim " & BootstrapNim &
        ", not the pinned " & PinnedNim)

  try: removeDir(root)
  except OSError: discard
