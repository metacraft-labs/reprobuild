## Gradual-Nix-To-Reprobuild-Migration GM4b gate:
## `e2e_home_profile_resolves_just_for_darwin`.
##
## Resolving a home profile that names `just` for target aarch64-darwin, from
## any host, selects the aarch64-apple-darwin tarball realization of package
## `just`.
##
## Before GM4b the home side resolved through a per-platform adapter chain
## whose macOS form never consulted the archive realizations, and the copy it
## would have read (the `justCatalog` record) had no macOS arm at all; the
## realization existed only in `package just:`. This gate proves the
## canonical definition is now the only thing consulted.
##
## Two routes, both production code:
##
## 1. the real CLI — `build/bin/repro home apply --plan --target-platform
##    macos --target-arch arm64` on a compiled `home.nim` (macro form). On an
##    Apple Silicon host the target is the host (and `just` may well be on
##    PATH — the default policy consults declared realizations first, so it
##    must not matter); elsewhere it is a cross target. The selection is the
##    same either way, which is what "from any host" means;
## 2. the library entry point the CLI uses (`resolveProfileSelections`),
##    evaluated for a host name that is NOT this machine, which pins the
##    cross-target case on every machine, and exposes the lock identity.
##
## Expected values are written out here, copied from `packages/just.nim`'s
## aarch64 macOS `tarball` statement, not derived from the resolver.
##
## Vacuity guard: the plan must contain a package line for `just` naming the
## exact URL and version, and the library selection must be a `tarball` with
## the exact lock identity; a plan that resolved nothing, or resolved `just`
## through PATH or nix, fails.
##
## Negative control: a defined package with no realization for the target
## (`dotnet-sdk`: Windows archives only, no nixPackage) reports a
## MISSING-REALIZATION diagnostic that names the target platform
## (`aarch64-macos`), not "unknown package". An undefined name
## (`gm4b-no-such-package`) is the contrast case and IS reported as unknown —
## with the target named.
##
## Mocks: none — the real binary, the real profile compile, the real planner.
## Only HOME and the state/store/profile directories are redirected.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_home_apply
import repro_home_intent

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()

const
  JustDarwinUrl = "https://github.com/casey/just/releases/download/1.51.0/" &
    "just-1.51.0-aarch64-apple-darwin.tar.gz"
  JustDarwinLock = "tarball:just@1.51.0:macos-aarch64:sha256:" &
    "61e3f1b8a545ff064b091eab4b6e14f8cc743ff15549be293b1e92f5b1467002"

proc profileBody(packages: openArray[string]): string =
  result = "import repro_profile\n\nprofile \"gm4bJustForDarwin\":\n" &
    "  activity default:\n"
  for p in packages:
    result.add("    " & p & "\n")

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  result = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(extendedPath(result)),
    "repro binary not found at " & result & "; build with `just build` first"

proc runPlan(root: string; packages: openArray[string]):
    tuple[exitCode: int; output: string] =
  let profileDir = root / "profile"
  let homeDir = root / "home"
  for dir in [profileDir, homeDir, root / "state", root / "store"]:
    createDir(extendedPath(dir))
  writeFile(extendedPath(profileDir / "home.nim"), profileBody(packages))
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["HOME"] = homeDir
  env["USERPROFILE"] = homeDir
  env["REPRO_HOME_PROFILE_DIR"] = profileDir
  env["REPRO_HOME_STATE_DIR"] = root / "state"
  env["REPRO_STORE_ROOT"] = root / "store"
  env["REPRO_HOST"] = "gm4b-darwin-plan"
  let p = startProcess(reproBinary(), workingDir = root,
    args = @["home", "apply", "--plan", "--allow-drift",
             "--target-platform", "macos", "--target-arch", "arm64"],
    env = env, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc packageLine(output, packageId: string): string =
  for line in output.splitLines():
    let t = line.strip()
    for action in ["realize  ", "cache-hit  ", "missing  "]:
      if t.startsWith(action & packageId & "  "):
        return t
  ""

proc librarySelections(root: string; packages: openArray[string]):
    ProfileSelections =
  let dir = root / "lib-profile"
  createDir(dir)
  var body = "import repro/profile\n\nprofile \"gm4bJustForDarwin\":\n" &
    "  activity default:\n"
  for p in packages:
    body.add("    " & p & "\n")
  writeFile(dir / "home.nim", body)
  var opts: ApplyOptions
  opts.profileDir = dir
  opts.profilePath = dir / "home.nim"
  opts.stateDir = dir / "state"
  opts.storeRoot = dir / "store"
  opts.homeDir = dir / "home"
  opts.host = "gm4b-not-this-host"
  opts.targetContext = HostContext(platform: "macos", arch: "arm64",
    host: opts.host)
  opts.hasTargetContext = true
  resolveProfileSelections(opts)

suite "GM4b: e2e_home_profile_resolves_just_for_darwin":

  test "e2e_home_profile_resolves_just_for_darwin: repro home apply --plan " &
      "for aarch64-darwin selects just's aarch64-apple-darwin tarball":
    let root = createTempDir("repro-gm4b-just-darwin-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let res = runPlan(root, ["just"])
    checkpoint(res.output)
    check res.exitCode == 0
    let line = packageLine(res.output, "just")
    checkpoint("just line: " & line)
    check line.startsWith("realize  just  ")
    check ("tarball " & JustDarwinUrl & " @1.51.0") in line
    check "path " notin line
    check "nix " notin line

  test "e2e_home_profile_resolves_just_for_darwin: the library resolver " &
      "selects the same record, with its lock identity, for a non-host " &
      "aarch64-darwin target":
    let root = createTempDir("repro-gm4b-just-darwin-lib-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let selections = librarySelections(root, ["just"])
    check selections.target == "aarch64-macos"
    check selections.policySource == "default"
    check selections.previews.len == 1
    let pv = selections.previews[0]
    check pv.resolved
    let s = pv.resolution.selection
    check s.kind == rkTarball
    check s.tarball.url == JustDarwinUrl
    check s.version == "1.51.0"
    check s.lockIdentity == JustDarwinLock
    check not s.ambient
    # The plain archive is realized by the `uses:` provisioning edge.
    check pv.resolution.archiveRoute == arExtract

  test "negative control: a defined package with no darwin realization is " &
      "a missing realization naming the platform, not an unknown package":
    let root = createTempDir("repro-gm4b-just-darwin-neg-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let res = runPlan(root, ["just", "`dotnet-sdk`", "`gm4b-no-such-package`"])
    checkpoint(res.output)
    check res.exitCode == 0  # --allow-drift: drift is the subject here
    # The positive case still holds in the same plan.
    check ("tarball " & JustDarwinUrl) in packageLine(res.output, "just")
    let dotnet = packageLine(res.output, "dotnet-sdk")
    checkpoint("dotnet-sdk line: " & dotnet)
    check dotnet.startsWith("missing  dotnet-sdk  ")
    check "missing-realization" in dotnet
    check "aarch64-macos" in dotnet
    check "unknown package" notin dotnet
    # Contrast: a name no definition in scope carries IS unknown, and the
    # diagnostic still names the target.
    let unknown = packageLine(res.output, "gm4b-no-such-package")
    checkpoint("gm4b-no-such-package line: " & unknown)
    check unknown.startsWith("missing  gm4b-no-such-package  ")
    check "unknown package 'gm4b-no-such-package'" in unknown
    check "aarch64-macos" in unknown
