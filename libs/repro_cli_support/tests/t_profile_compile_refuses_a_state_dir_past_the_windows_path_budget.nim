## A profile compile under a state directory too long for Windows' path limit
## is refused up front, with a diagnostic that names the state directory's
## length, the limit and how to shorten it.
##
## The failure this pins down
## --------------------------
## Nim and MinGW's `cc1` open every file of the profile's nimcache,
## `<state-dir>\profile-cache\nimcache\<16 hex>\<mangled module>.nim.c`,
## through Win32 calls bound by MAX_PATH, and `cc1` cannot take the `\\?\`
## form. On eli-pc a 171-character state directory (a test's scratch under a
## long `TEMP`) failed inside `nim` with "cannot create directory: ..." and,
## once the nimcache name was shortened, with "cannot open ..." -- neither
## naming length nor remedy (reprobuild-pm issue
## 2026-10-27-windows-profile-compile-fails-when-the-state-dir-is-long). The
## governing rule is reprobuild-pm `spec/Profile-Compilation-Model.md`
## step 2: past the budget the compile is refused before `nim` runs.
##
## The case
## --------
## A real compile under a real 171-character state directory, through the
## real engine and the real `repro` built at `build/bin/`. On Windows it
## must be refused with the budget diagnostic and must not have created the
## profile cache (it was refused before `nim` ran). Elsewhere it must
## COMPILE: POSIX has no such limit, and the refusal must not reach a host
## that can build the profile. The budget arithmetic and the full wording
## of the diagnostic are checked on every host, without a compile, by
## `libs/repro_profile_compile/tests/t_smoke_repro_profile_compile.nim`.
##
## The second case does the same for the platform probe
## (`probeProfilePlatforms`), an entry point of its own whose per-platform
## working directories are deeper than the nimcache: refused on Windows,
## evaluated elsewhere.
##
## Mocks: none. Off Windows both cases run the real `nim` and C toolchain
## against reprobuild's real sources, as
## `t_in_process_profile_compile_never_spawns_its_caller` does.

import std/[os, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath
from repro_test_support import removeDirEventually

import repro_cli_support/home as cli_home
# Only what existed before the fix, so this file builds against the
# unfixed tree and its failure there can be shown.
from repro_profile_compile/sources import profileCacheDir
from repro_profile_compile/edge import ProfileCompileOptions,
  ProfileCompileError, probeProfilePlatforms

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()
const FixtureProfile = ProjectRoot / "tests" / "fixtures" / "m76" /
  "stow_byte_identical" / "home.nim"
const ObservedStateDirChars = 171
  ## The state directory length the issue observed failing on eli-pc.

proc reproBinary(): string =
  let candidate = ProjectRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(extendedPath(candidate)),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc paddedStateDir(root: string; chars: int): string =
  ## `<root>/state-sss...`, exactly `chars` characters long.
  let head = root / "state-"
  doAssert head.len < chars, "scratch root " & root &
    " is too long to build a " & $chars & "-character state directory"
  head & repeat('s', chars - head.len)

proc scratchRoot(): string =
  ## Under the temporary directory, which must leave room for the padding.
  ## A POSIX runner may hand out a deep `$TMPDIR`; `/tmp` serves there, as
  ## the length matters only on Windows, whose `%TEMP%` is short by default.
  let scratchParent =
    when defined(windows): ""
    else: (if getTempDir().len > 100: "/tmp" else: "")
  createTempDir("repro-long-state-", "", scratchParent)

suite "the Windows path budget of the profile compile":
  test "a compile under a 171-character state directory":
    let root = scratchRoot()
    defer: removeDirEventually(root)
    let stateDir = paddedStateDir(root, ObservedStateDirChars)
    check stateDir.len == ObservedStateDirChars  # ASCII: bytes == units
    createDir(extendedPath(stateDir))
    createDir(root / "profile")
    copyFile(FixtureProfile, root / "profile" / "home.nim")
    let outcome = cli_home.compileAndAdaptHomeProfile(
      root / "profile" / "home.nim", stateDir,
      publicCliPath = reproBinary())
    checkpoint("compile error: " & outcome.compileError)
    when defined(windows):
      check outcome.profile == nil
      # The refusal (`sources.profileStateDirBudgetProblem`, whose wording
      # `t_smoke_repro_profile_compile` checks in full), not a `nim`
      # diagnostic: it names the directory, its length and the remedy.
      check ("the state directory " & stateDir & " is " &
        $ObservedStateDirChars & " characters long") in outcome.compileError
      check "REPRO_HOME_STATE_DIR" in outcome.compileError
      check "nim diagnostics" notin outcome.compileError
      # Refused before anything was created under the state directory, so
      # before `nim` (which creates the nimcache) ran.
      check not dirExists(extendedPath(profileCacheDir(stateDir)))
    else:
      check outcome.compileError == ""
      check outcome.profile != nil

  test "a platform probe under a 171-character state directory":
    # `probeProfilePlatforms` is an entry point of its own (`repro home
    # export` and `repro home facts` call it after the compile), and its
    # per-platform working directories are deeper than the nimcache, so it
    # applies the same refusal rather than relying on a compile first.
    let root = scratchRoot()
    defer: removeDirEventually(root)
    let stateDir = paddedStateDir(root, ObservedStateDirChars)
    check stateDir.len == ObservedStateDirChars
    createDir(extendedPath(stateDir))
    createDir(root / "profile")
    copyFile(FixtureProfile, root / "profile" / "home.nim")
    let opts = ProfileCompileOptions(stateDir: stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot,
      workDir: root / "profile")
    when defined(windows):
      var message = ""
      try:
        discard probeProfilePlatforms(root / "profile" / "home.nim", opts)
      except ProfileCompileError as err:
        message = err.msg
      checkpoint("probe error: " & message)
      check ("the state directory " & stateDir & " is " &
        $ObservedStateDirChars & " characters long") in message
      check "REPRO_HOME_STATE_DIR" in message
      check not dirExists(extendedPath(profileCacheDir(stateDir)))
    else:
      let probe = probeProfilePlatforms(root / "profile" / "home.nim", opts)
      # Vacuity guard: the probe ran and evaluated at least this host.
      check probe.outcomes.len > 0
      var anyEvaluated = false
      for o in probe.outcomes:
        if o.evaluated: anyEvaluated = true
      check anyEvaluated
