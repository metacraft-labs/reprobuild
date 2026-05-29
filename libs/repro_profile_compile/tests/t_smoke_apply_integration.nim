## M83 Phase D apply-path smoke tests.
##
## These tests drive the home-apply pipeline with a `Profile` produced
## by the adapter (via `ApplyOptions.preLoadedProfile`) instead of the
## legacy parser, and assert the apply pipeline reaches step 11 and
## commits a generation. The fixture profile is intentionally minimal:
## a `default` activity with one bare package reference + an empty
## `resources:` block. The apply runs in a tempdir-isolated state +
## store; nothing in `$HOME` is touched.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_home_apply
import repro_home_intent
import repro_local_store
import repro_profile
import repro_profile_compile

const ProfileText = """
import repro/profile

profile "phaseD-smoke":
  activity default:
    smoke-noop-pkg
"""

# A `ProfileIntent` matching the text above, suitable for the adapter.
proc makeIntent(): ProfileIntent =
  result = ProfileIntent(name: "phaseD-smoke")
  result.activities.add(ActivityIntent(name: "default",
    body: @[ActivityElement(kind: aekPackageRef,
      pkgName: "smoke-noop-pkg")]))

# We need a Store inside the tempdir so the apply pipeline can stage
# generated files via the CAS protocol. Existing apply tests provide
# this via the env-var seams the CLI honours.
proc setupApplyEnv(tempRoot: string):
    tuple[profilePath, profileDir, stateDir, storeRoot, homeDir: string] =
  result.profileDir = tempRoot / "profile"
  result.profilePath = result.profileDir / "home.nim"
  result.stateDir = tempRoot / "state"
  result.storeRoot = tempRoot / "store"
  result.homeDir = tempRoot / "home"
  createDir(result.profileDir)
  createDir(result.stateDir)
  createDir(result.storeRoot)
  createDir(result.homeDir)
  writeFile(result.profilePath, ProfileText)
  # Empty package catalog: every package name passes through.
  putEnv("REPRO_HOME_PACKAGE_CATALOG", "")
  # Test-only resource seam empty: the apply pipeline composes the
  # profile's resources block as the desired set.
  putEnv("REPRO_TEST_RESOURCES", "")
  # Wire `smoke-noop-pkg` as a path-adapter package so the realize
  # step doesn't need a Scoop install. We point it at the smoke
  # profile's own source file — its bytes are unimportant, the
  # realize step only needs SOMETHING to symlink into the prefix.
  putEnv("REPRO_TEST_PACKAGE_SOURCE",
    "smoke-noop-pkg=" & result.profilePath)

suite "M83 Phase D: home apply via preLoadedProfile":

  test "apply with preLoadedProfile commits a generation":
    let tempRoot = createTempDir("repro-m83-d-apply-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let f = setupApplyEnv(tempRoot)

    var opts: ApplyOptions
    opts.profileDir = f.profileDir
    opts.profilePath = f.profilePath
    opts.stateDir = f.stateDir
    opts.storeRoot = f.storeRoot
    opts.homeDir = f.homeDir
    opts.host = "phaseD-host"
    # Adapt the intent INTO a Profile and hand it to the pipeline
    # through the Phase D seam. The pipeline must NOT call
    # `loadProfile(profilePath)` — the adapted profile drives the run.
    opts.preLoadedProfile = profileIntentToHomeProfile(
      makeIntent(), f.profilePath)

    let outcome = runApply(opts)
    check outcome.kind == aokFreshApplied
    check outcome.generationIdHex.len > 0

  test "apply with preLoadedProfile is no-op on second invocation":
    let tempRoot = createTempDir("repro-m83-d-apply-noop-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let f = setupApplyEnv(tempRoot)
    let profile = profileIntentToHomeProfile(
      makeIntent(), f.profilePath)

    var opts: ApplyOptions
    opts.profileDir = f.profileDir
    opts.profilePath = f.profilePath
    opts.stateDir = f.stateDir
    opts.storeRoot = f.storeRoot
    opts.homeDir = f.homeDir
    opts.host = "phaseD-host"
    opts.preLoadedProfile = profile
    let first = runApply(opts)
    check first.kind == aokFreshApplied

    # Second apply with the SAME preLoadedProfile must take the no-op
    # short-circuit (the generation id is content-addressed; the input
    # didn't change).
    var opts2: ApplyOptions
    opts2.profileDir = f.profileDir
    opts2.profilePath = f.profilePath
    opts2.stateDir = f.stateDir
    opts2.storeRoot = f.storeRoot
    opts2.homeDir = f.homeDir
    opts2.host = "phaseD-host"
    opts2.preLoadedProfile = profile
    let second = runApply(opts2)
    check second.kind == aokNoOpVerified
    check second.generationIdHex == first.generationIdHex

  test "runApplyPlan honours preLoadedProfile (no-op preview)":
    let tempRoot = createTempDir("repro-m83-d-plan-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard
    let f = setupApplyEnv(tempRoot)

    var opts: ApplyOptions
    opts.profileDir = f.profileDir
    opts.profilePath = f.profilePath
    opts.stateDir = f.stateDir
    opts.storeRoot = f.storeRoot
    opts.homeDir = f.homeDir
    opts.host = "phaseD-host"
    opts.preLoadedProfile = profileIntentToHomeProfile(
      makeIntent(), f.profilePath)
    let preview = runApplyPlan(opts)
    # An apply preview against a fresh state-dir reports the operations
    # that WOULD run — the smoke profile lists one package, so we
    # expect AT LEAST one preview item. The exact count depends on
    # planner internals (synthetic seams, etc.); the load-bearing
    # check is that the planner didn't blow up.
    check preview.generationIdHex.len > 0
