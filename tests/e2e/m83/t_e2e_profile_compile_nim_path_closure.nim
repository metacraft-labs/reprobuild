## Regression gate: the `--path:` set the profile-compile child receives must
## cover the WHOLE transitive import closure of `repro_profile`, not the
## subset somebody last remembered to write down.
##
## The failure this pins down
## --------------------------
## `profileNimPaths` used to return a hand-written array of lib names. A
## profile's `import repro_profile` reaches, transitively:
##
##   repro_profile -> repro_profile/build_actions -> repro_project_dsl
##     -> repro_project_dsl/install_mirror_resolver -> repro_local_store
##
## `repro_local_store` was never added to that array, so every profile
## compile that actually ran `nim c` died with::
##
##   .../repro_project_dsl/install_mirror_resolver.nim(9, 8)
##     Error: cannot open file: repro_local_store
##
## and it was not alone — `repro_peer_cache`, `repro_provider_runtime`,
## `repro_shm_index`, `repro_solver` and `repro_system_apply` were missing
## from the same array for the same reason. The breakage stayed invisible
## because a successful compile is cached as an `.rbpi` envelope keyed on
## the PROFILE's source digest: as long as a machine's profile text did not
## change, the cached envelope was served and `nim c` never ran. Editing any
## profile forced a real recompile and surfaced the break.
##
## Why the test compiles from a temp dir OUTSIDE the repo
## ------------------------------------------------------
## This is the single detail that makes the gate meaningful. Inside the
## repo, `config.nims`'s `switch("path", "libs"/<name>/"src")` loop resolves
## every lib on its own and the `--path:` set is never load-bearing — which
## is exactly why the pre-existing in-repo fixture gates stayed green
## through the whole outage. Nim resolves those relative switches against
## the PROJECT directory, so a profile compiled from a user's own directory
## (the production shape: `C:\Users\<user>\<profile-dir>\system.nim`) gets
## nothing from them and depends entirely on `profileNimPaths`. Compiling
## from a temp dir reproduces that.
##
## Mocks: none. This test runs the real `runProfileCompileHelper` — the
## verbatim body of the internal `__repro-compile-profile` subcommand — on
## the real argv that `profileCompileBuildAction` emits, driving a real
## `nim c` against the real `libs/` tree and asserting on the real RBPI
## envelope it publishes. The only production step not covered here is the
## build engine spawning `repro.exe` as a subprocess, which
## `t_e2e_repro_profile_compile_via_action.nim` already gates.

import std/[algorithm, os, sequtils, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_build_engine
import repro_profile_intent
import repro_profile_compile

const ProfileBody = """
import repro_profile

profile "nimPathClosureGate":
  activity default:
    neovim
"""

proc libsWithSrc(repoRoot: string): seq[string] =
  ## Every `libs/<name>` that exposes a `src` directory — the ground truth
  ## `profileNimPaths` is supposed to reflect.
  let libsRoot = repoRoot / "libs"
  for kind, path in walkDir(libsRoot):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let name = path.lastPathPart
    if dirExists(libsRoot / name / "src"):
      result.add name
  result.sort()

suite "profile-compile Nim path closure":

  test "profileNimPaths covers every libs/<name>/src in the repo":
    # The invariant, stated as a property rather than as another list:
    # whatever lands under `libs/` with a `src` dir is on the child's
    # `--path:`. A newly added library cannot silently fall off.
    let repoRoot = reprobuildRepoRoot()
    let emitted = profileNimPaths(repoRoot)
    check emitted.len > 0
    for name in libsWithSrc(repoRoot):
      let expected = repoRoot / "libs" / name / "src"
      check expected in emitted

  test "profileNimPaths carries the transitively-imported libs the old list omitted":
    # Named canaries for the six libraries the hand-maintained array was
    # missing. Each is reachable only transitively from `import
    # repro_profile`, which is why each was easy to forget.
    let repoRoot = reprobuildRepoRoot()
    let emitted = profileNimPaths(repoRoot)
    for name in ["repro_local_store", "repro_peer_cache",
                 "repro_provider_runtime", "repro_shm_index",
                 "repro_solver", "repro_system_apply"]:
      check (repoRoot / "libs" / name / "src") in emitted

  test "profileNimPaths is deterministic and duplicate-free":
    # The path set is baked into the profile-compile BuildAction's argv;
    # a readdir-order-dependent argv would be a gratuitous cache miss.
    let repoRoot = reprobuildRepoRoot()
    let first = profileNimPaths(repoRoot)
    let second = profileNimPaths(repoRoot)
    check first == second
    check first.deduplicate().len == first.len
    check first.isSorted()

  test "profileNimPaths yields nothing for a root with no libs/ tree":
    let empty = createTempDir("repro-nimpath-empty-", "")
    defer: removeDir(empty)
    check profileNimPaths(empty).len == 0

  test "__repro-compile-profile compiles a profile from outside the repo":
    # The real regression gate. Reverting `profileNimPaths` to the old
    # hand-written array makes this fail with
    # `cannot open file: repro_local_store`.
    # `compileProfileBinary` resolves Nim through `findExe`, so the gate is
    # only meaningful when Nim is on PATH (it always is in the devshell).
    doAssert findExe("nim").len > 0,
      "profile compilation requires `nim` on PATH"

    let profileDir = createTempDir("repro-nimpath-profile-", "")
    defer: removeDir(profileDir)
    let stateDir = createTempDir("repro-nimpath-state-", "")
    defer: removeDir(stateDir)

    let profileRoot = profileDir / "home.nim"
    writeFile(extendedPath(profileRoot), ProfileBody)
    doAssert not profileRoot.isRelativeTo(reprobuildRepoRoot()),
      "the profile must live outside the repo or config.nims masks the bug"

    let rbpiPath = stateDir / "gate.rbpi"
    let manifestPath = stateDir / "gate.source.txt"
    let nimcacheDir = stateDir / "nimcache"

    # Build the argv through the production BuildAction constructor rather
    # than hand-rolling it, so the flag names/order under test are the ones
    # the build engine really emits. argv[0] is the `repro` binary and
    # argv[1] the subcommand; the helper body parses everything after.
    let action = profileCompileBuildAction(
      profileRoot, rbpiPath, manifestPath, nimcacheDir,
      publicCliPath = "repro", workDir = profileDir,
      repoRoot = reprobuildRepoRoot(),
      inputSources = @[profileRoot],
      weak = weakFingerprintFromText("nim-path-closure-gate"))
    check action.argv[1] == "__repro-compile-profile"

    let exitCode = runProfileCompileHelper(action.argv[2 .. ^1])
    check exitCode == 0

    check fileExists(extendedPath(rbpiPath))
    check fileExists(extendedPath(manifestPath))

    let raw = readFile(extendedPath(rbpiPath))
    var bytes = newSeq[byte](raw.len)
    for i, ch in raw:
      bytes[i] = byte(ord(ch))
    let intent = decodeRbpi(bytes)
    check intent.name == "nimPathClosureGate"
    check intent.activities.len == 1
    check intent.activities[0].name == "default"
    check intent.activities[0].body.len == 1
    check intent.activities[0].body[0].pkgName == "neovim"
