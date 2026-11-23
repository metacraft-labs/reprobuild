## A new entry in a directory ABOVE the profile directory does not invalidate
## the profile compile or the platform probe.
##
## Primary assertion -- `e2e_profile_compile_ignores_ancestor_membership`:
## through `compileProfileToRbpi`, run 1 executes the edge and publishes its
## record, run 2 on an unchanged sandbox is `cdHit`, and run 3 -- after only a
## new file and a new directory appeared in the profile directory's PARENT --
## is still `cdHit` with the edge not launched and no `nim` spawned. The
## platform-probe case asserts the same of `probeProfilePlatforms`.
##
## The defect (reprobuild-pm issue
## 2026-10-14-macos-profile-compile-is-keyed-on-the-membership-of-every-ancestor-directory):
## Nim looks for a `.nimble` in every ancestor of each module it compiles
## (`compiler/packagehandling.nim`, `getNimbleFile`: `walkFiles(dir /
## "*.nimble")` up the parent chain until one matches). On macOS io-mon
## records each of those glob listings as a directory enumeration
## (`getdirentries64`), and the engine keys the edge on every listed
## directory's FULL membership -- so a profile was keyed on the entries of
## `$HOME`, `/private/tmp`, `/`, … and any file created next to the profile
## directory recompiled it. Measured before the fix (reprobuild `b617af2e`,
## macOS aarch64, m1): run 3 of the library case is `cdMiss` with
## "input metadata changed: <sandbox root>/". The fix stages a `.nimble` in a
## profile directory that holds none while the helper runs Nim
## (`stageProfileFiles` in `compile.nim`), which ends the walk at the profile
## directory: the ancestors are no longer read at all, rather than read and
## exempted.
##
## Platforms. Every host. The primary assertion is meaningful only where the
## listing is recorded (macOS); on Linux glibc's `glob` reads directories
## through calls the preload shim does not interpose, so the run-3 hit holds
## there before and after the fix, and the case is a regression guard.
##
## Positive control: run 2 is a `cdHit` with the edge not launched, so caching
## works at all in this sandbox and run 3's hit is not vacuous; and run 1's
## record must be published (`cachePublishSkipReason` empty) -- a fail-closed
## edge would re-run every time and could not show the defect.
##
## Negative (soundness) control, macOS only (the only platform that records
## the listing): adding a `.nimble` to the PROFILE directory itself still
## invalidates (`cdMiss`, edge launched, miss reason naming the profile
## directory). The profile directory's membership is still a recorded input,
## so the fix is not an exemption that would also hide a real change. The
## user's `.nimble` must survive the compile (the helper stages a file only
## when the directory has none, and removes only what it staged), and the
## next unchanged run is a `cdHit` again.
##
## Vacuity guards: every run's published intent holds exactly the one
## resource the profile declares, and after every run the profile directory
## holds no `.nimble` the test did not put there -- the staged file is
## removed (no litter in the user's profile directory).
##
## No mocks. The real `build/bin/repro` helper, the real Nim compiler, the
## real C toolchain, the real io-mon shim and the real filesystem; the `nim`
## on `PATH` is the pass-through counter justified in
## `profile_compile_edge_harness.nim`.

import std/[algorithm, os, strutils, tables, unittest]

import repro_build_engine
import repro_profile_intent
import repro_profile_compile

import ./profile_compile_edge_harness

const AncestorProfile = """
import repro_profile

template ancestorFile(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources,
    hostFile = "~/ancestor-membership.txt",
    content = "unchanged")

profile "gm0mAncestorMembership":
  resources:
    ancestorFile()
"""

const UserNimbleName = "users-own-profile.nimble"
  ## The negative control's `.nimble`, standing for one a user keeps in their
  ## profile directory.

proc checkIntent(art: ProfileCompileArtifact) =
  ## Vacuity guard: the one resource the profile declares.
  let intent = decodeRbpi(art.rbpiBytes)
  check intent.resources.len == 1
  if intent.resources.len == 1:
    check intent.resources[0].kind == "fs.userFile"
    check intent.resources[0].fields["content"].s == "unchanged"

proc nimbleFiles(dir: string): seq[string] =
  ## The `*.nimble` entries of `dir`, by name, sorted.
  for kind, path in walkDir(dir):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".nimble"):
      result.add path.extractFilename
  result.sort()

proc mutateAncestor(sb: ProfileSandbox; label: string) =
  ## A new file AND a new directory in the profile directory's parent: the
  ## two entry kinds a user's `$HOME` gains every day. Nothing under the
  ## profile directory changes.
  writeFile(sb.root / ("ancestor-entry-" & label & ".txt"), label)
  createDir(sb.root / ("ancestor-dir-" & label))

template withSpyOnPath(sb: ProfileSandbox; body: untyped) =
  ## The spy first on `PATH`, and no `$REPRO_NIM_COMPILER` (the edge would
  ## take it over the spy; the spy forwards to that compiler instead).
  ## Restored afterwards.
  let savedPath = getEnv("PATH")
  let hadNim = existsEnv(ProfileNimCompilerEnvVar)
  let savedNim = getEnv(ProfileNimCompilerEnvVar)
  putEnv("PATH", sb.spyDir & $PathSep & savedPath)
  delEnv(ProfileNimCompilerEnvVar)
  try:
    body
  finally:
    putEnv("PATH", savedPath)
    if hadNim: putEnv(ProfileNimCompilerEnvVar, savedNim)

suite "profile compile edge: ancestor directory membership is not an input":

  test "e2e_profile_compile_ignores_ancestor_membership":
    let sb = newProfileSandbox("ancestor-membership", AncestorProfile)
    defer: sb.dispose()
    # Precondition: the profile directory holds no `.nimble`, which is the
    # case the defect needs (Nim's walk leaves the directory) and the
    # common one for a real `~/.config/repro/home`.
    check nimbleFiles(sb.profileDir).len == 0
    let opts = ProfileCompileOptions(stateDir: sb.stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot)
    withSpyOnPath(sb):
      let first = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("first: decision=" & $first.cacheDecision &
        " publishSkip=" & first.cachePublishSkipReason)
      check first.edgeLaunched
      check first.cachePublishSkipReason.len == 0
      check sb.nimSpawnCount("c") >= 1
      checkIntent(first)
      check nimbleFiles(sb.profileDir).len == 0

      # Positive control: an unchanged sandbox is answered from the cache.
      let spawnsBefore = sb.nimSpawnCount()
      let second = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("second: decision=" & $second.cacheDecision &
        " miss=" & second.cacheMissReason)
      check second.cacheDecision == cdHit
      check not second.edgeLaunched
      check sb.nimSpawnCount() == spawnsBefore
      checkIntent(second)

      # Primary assertion: only the profile directory's PARENT changed.
      sb.mutateAncestor("one")
      let third = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("third (after a new entry in " & sb.root & "): decision=" &
        $third.cacheDecision & " miss=" & third.cacheMissReason)
      check third.cacheDecision == cdHit
      check not third.edgeLaunched
      check sb.nimSpawnCount() == spawnsBefore
      checkIntent(third)
      check nimbleFiles(sb.profileDir).len == 0

      # Negative (soundness) control: the profile directory's own membership
      # is still an input. A `.nimble` there is also a real input to Nim (it
      # names the profile's package), so it must be a miss -- where the
      # listing is recorded at all.
      writeFile(sb.profileDir / UserNimbleName,
        "# a user's own package file\n")
      let fourth = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("fourth (after " & UserNimbleName & " in the profile " &
        "directory): decision=" & $fourth.cacheDecision & " miss=" &
        fourth.cacheMissReason)
      when defined(macosx):
        check fourth.edgeLaunched
        check fourth.cacheDecision != cdHit
        check fourth.cacheMissReason.contains(sb.profileDir)
        check sb.nimSpawnCount() > spawnsBefore
      checkIntent(fourth)
      # The helper staged nothing beside the user's file, and left it alone.
      check nimbleFiles(sb.profileDir) == @[UserNimbleName]

      let spawnsAfterControl = sb.nimSpawnCount()
      let fifth = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("fifth: decision=" & $fifth.cacheDecision &
        " miss=" & fifth.cacheMissReason)
      check fifth.cacheDecision == cdHit
      check not fifth.edgeLaunched
      check sb.nimSpawnCount() == spawnsAfterControl
      checkIntent(fifth)
      check nimbleFiles(sb.profileDir) == @[UserNimbleName]

  test "platform probe ignores ancestor directory membership":
    # The probe runs Nim over the same profile (`nim dump`, then one `nim
    # check` per target platform) and stages the same files, so it had the
    # same ancestor walk. Same sequence as the primary case: executed,
    # unchanged hit (positive control), then a hit after the parent changes.
    let sb = newProfileSandbox("ancestor-membership-probe", AncestorProfile)
    defer: sb.dispose()
    check nimbleFiles(sb.profileDir).len == 0
    let opts = ProfileCompileOptions(stateDir: sb.stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot)
    withSpyOnPath(sb):
      let first = probeProfilePlatforms(sb.profilePath, opts)
      checkpoint("probe first: decision=" & $first.cacheDecision)
      check first.edgeLaunched
      check sb.nimSpawnCount("check") >= 1
      # Vacuity guard: the host's own platform was evaluated.
      var anyEvaluated = false
      for o in first.outcomes:
        if o.evaluated:
          anyEvaluated = true
      check anyEvaluated
      check nimbleFiles(sb.profileDir).len == 0

      let spawnsBefore = sb.nimSpawnCount()
      let second = probeProfilePlatforms(sb.profilePath, opts)
      checkpoint("probe second: decision=" & $second.cacheDecision &
        " miss=" & second.cacheMissReason)
      check second.cacheDecision == cdHit
      check not second.edgeLaunched
      check sb.nimSpawnCount() == spawnsBefore

      sb.mutateAncestor("probe")
      let third = probeProfilePlatforms(sb.profilePath, opts)
      checkpoint("probe third (after a new entry in " & sb.root &
        "): decision=" & $third.cacheDecision & " miss=" &
        third.cacheMissReason)
      check third.cacheDecision == cdHit
      check not third.edgeLaunched
      check sb.nimSpawnCount() == spawnsBefore
      check third.outcomes.len == first.outcomes.len
      check nimbleFiles(sb.profileDir).len == 0
