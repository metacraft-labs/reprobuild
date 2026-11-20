## Saving a profile source again without changing a byte does not recompile
## the profile or re-run the platform probe.
##
## Primary assertion -- `e2e_profile_resave_without_edit_does_not_recompile`:
## through `compileProfileToRbpi`, run 1 executes both edges and publishes
## their records. Every file the profile is made of -- the root `home.nim`, a
## module it imports and a payload it reads with `staticRead` -- is then
## written again with the bytes it already holds, so each one's modification
## time moves and nothing else does. Run 2 must be answered from the action
## cache: neither edge launched, no `nim` spawned, the same intent published.
## The platform-probe case asserts the same of `probeProfilePlatforms`, and
## the CLI case of the public `repro home export`, which runs both.
##
## The defect (reprobuild-pm issue
## 2026-11-16-re-saving-an-unchanged-home-profile-recompiles-it-cold): the
## compile edge and the platform-probe edge stated no input-check policy and
## so ran under the `timestamp` default, where an input whose mtime moved is
## a changed input whatever its bytes are. An editor's save without an edit,
## a formatter that rewrites what it read, a `git checkout` or a generator
## that re-emits the profile then cost a cold compile. Measured before the
## fix (reprobuild `28f1e43dcaf`, Linux x86-64 under load): cold export
## 419 s, unchanged export 12 s, the same export after `home.nim` was
## rewritten with the same bytes 330 s. Only the run edge stated `ffpHybrid`.
## The fix states `ffpHybrid` on the other two (`profileCompileBuildAction`,
## `profilePlatformProbeBuildAction`): metadata first, and the content of an
## input whose metadata moved.
##
## Vacuity guards. A hit that proves nothing has three shapes, and each is
## excluded:
## * the rewrite did not move the mtime (a coarse filesystem clock): the test
##   sleeps past the granularity and asserts every rewritten file's mtime
##   moved, with its bytes equal;
## * the edges never read the files: run 1's compile record must list all
##   three among its observed inputs;
## * caching is switched off, or everything is a hit: run 1 must launch and
##   publish, and the soundness control below must launch.
##
## Soundness control: `ffpHybrid` must still see a real edit. The payload is
## then rewritten with DIFFERENT bytes of the SAME length, so size cannot be
## what gives the change away, and the compile must run again and publish the
## new content. The probe case edits the root module instead, also keeping
## its length. Both cases also pin the decision: the re-saved run is
## `cdHybridCutoff` on the compile edge and on the probe edge, and on the
## compile edge the unchanged run after it is a plain `cdHit` (the cutoff
## recorded the new metadata).
##
## Falsifying mutation (performed when this gate was written): remove
## `actionCachePolicy = ffpHybrid` from `profileCompileBuildAction` -- run 2
## of the library case launches the compile edge with "input metadata
## changed: …/home.nim" -- and from `profilePlatformProbeBuildAction`: run 2
## of the probe case launches with the same reason. The two library cases
## build their actions in the test process, so recompiling the test is enough
## to see them go red; the CLI case reads the policy from `build/bin/repro`
## and goes red only against an engine built without it.
##
## Platforms. Every host. On macOS the edges may fail closed (milestone
## GM0m, see the harness header): where run 1's record was not published,
## every run executes and the case reports that arm instead of asserting a
## cache answer. The content assertions hold on every arm.
##
## No mocks. The real `build/bin/repro` helper, the real Nim compiler, the
## real C toolchain, the real io-mon shim and the real filesystem; the `nim`
## on `PATH` is the pass-through counter justified in
## `profile_compile_edge_harness.nim`.

import std/[json, os, strutils, tables, times, unittest]

import repro_build_engine
import repro_profile_intent
import repro_profile_compile

import ./profile_compile_edge_harness

const ResaveProfile = """
import repro_profile
import ./resave_helpers

profile "gmResaveWithoutEdit":
  resources:
    resaveFile()
"""

const ResaveHelpers = """
import repro_profile

proc resavePayload*(): string =
  const text = staticRead("resave_payload.txt")
  text

template resaveFile*(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources,
    hostFile = "~/resave-without-edit.txt",
    content = resavePayload())
"""

const
  PayloadOne = "payload-one"
  PayloadTwo = "payload-two"
    ## The soundness control's payload: other bytes, the SAME length.
  HelperName = "resave_helpers.nim"
  PayloadName = "resave_payload.txt"
  SourceNames = ["home.nim", HelperName, PayloadName]
    ## Every file the profile is made of, relative to the profile directory.

  EditedResaveProfile = ResaveProfile.replace("gmResaveWithoutEdit",
    "gmResaveWithAnEdit_")
    ## The probe case's soundness control: the root module with another
    ## profile name of the SAME length.

static:
  doAssert PayloadOne.len == PayloadTwo.len and PayloadOne != PayloadTwo
  doAssert EditedResaveProfile.len == ResaveProfile.len and
    EditedResaveProfile != ResaveProfile

proc newResaveSandbox(label: string): ProfileSandbox =
  result = newProfileSandbox(label, ResaveProfile)
  result.writeProfileFile(HelperName, ResaveHelpers)
  result.writeProfileFile(PayloadName, PayloadOne)

proc resaveWithoutEdit(sb: ProfileSandbox) =
  ## Write every profile source again with the bytes it already holds, and
  ## prove that is what happened: the mtime moved, the bytes did not.
  sleep(1100)  # ext4 / APFS / NTFS timestamp granularity.
  for name in SourceNames:
    let path = sb.profileDir / name
    let before = readFile(path)
    let mtimeBefore = getLastModificationTime(path)
    writeFile(path, before)
    check readFile(path) == before
    # Vacuity guard: without a moved mtime the `timestamp` policy would hit
    # too and the case would pass before the fix.
    check getLastModificationTime(path) > mtimeBefore

proc checkIntent(bytes: seq[byte]; payload: string) =
  ## Exactly the one resource the profile declares, carrying `payload`.
  let intent = decodeRbpi(bytes)
  check intent.resources.len == 1
  if intent.resources.len == 1:
    check intent.resources[0].kind == "fs.userFile"
    check intent.resources[0].fields["content"].s == payload

proc observes(inputs: seq[string]; name: string): bool =
  for path in inputs:
    if path.extractFilename == name:
      return true
  false

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

const CacheAnswers = {cdHit, cdHybridCutoff}
  ## The two ways the action cache answers without running the edge: every
  ## input's metadata is as recorded, or (`ffpHybrid`) some metadata moved
  ## and the content behind it did not.

suite "profile edges: a save that changes no byte is not a change":

  test "e2e_profile_resave_without_edit_does_not_recompile":
    let sb = newResaveSandbox("resave-compile")
    defer: sb.dispose()
    let opts = ProfileCompileOptions(stateDir: sb.stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot)
    withSpyOnPath(sb):
      let first = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("first: decision=" & $first.cacheDecision &
        " publishSkip=" & first.cachePublishSkipReason)
      check first.compileEdge.launched
      check first.runEdge.launched
      check sb.nimSpawnCount("c") >= 1
      checkIntent(first.rbpiBytes, PayloadOne)
      let failedClosed = EdgeMayFailClosed and
        first.cachePublishSkipReason.len > 0
      if not failedClosed:
        check first.cachePublishSkipReason.len == 0
        # Vacuity guard: the compile's record names every file about to be
        # rewritten, so the hit below is a decision ABOUT them.
        for name in SourceNames:
          checkpoint("compile edge observed " & name & "?")
          check first.compileEdge.observedInputs.observes(name)

      sb.resaveWithoutEdit()
      let spawnsBefore = sb.nimSpawnCount()
      let second = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("second (after the re-save): decision=" &
        $second.cacheDecision & " miss=" & second.cacheMissReason)
      if failedClosed:
        echo "    [fail-closed, GM0m] re-save case: publish skipped (",
          first.cachePublishSkipReason, "); every compile re-runs"
        check second.edgeLaunched
      else:
        check not second.compileEdge.launched
        # The compile read the re-saved files, so this is the content
        # comparison and not a metadata hit.
        check second.compileEdge.cacheDecision == cdHybridCutoff
        check not second.runEdge.launched
        check second.runEdge.cacheDecision in CacheAnswers
        check not second.edgeLaunched
        check sb.nimSpawnCount() == spawnsBefore
      checkIntent(second.rbpiBytes, PayloadOne)

      if not failedClosed:
        # The cutoff recorded the metadata it saw, so the next unchanged run
        # is an ordinary metadata hit and hashes nothing again.
        let again = compileProfileToRbpi(sb.profilePath, opts)
        checkpoint("again (nothing touched): decision=" &
          $again.cacheDecision & " miss=" & again.cacheMissReason)
        check not again.edgeLaunched
        check again.compileEdge.cacheDecision == cdHit
        check sb.nimSpawnCount() == spawnsBefore

      # Soundness control: other bytes, the same length, a new mtime.
      sleep(1100)
      sb.writeProfileFile(PayloadName, PayloadTwo)
      let spawnsBeforeEdit = sb.nimSpawnCount("c")
      let third = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("third (after the edit): decision=" & $third.cacheDecision &
        " miss=" & third.cacheMissReason)
      check third.compileEdge.launched
      check third.runEdge.launched
      check sb.nimSpawnCount("c") > spawnsBeforeEdit
      checkIntent(third.rbpiBytes, PayloadTwo)

  test "platform probe is not re-run by a save that changes no byte":
    # The probe reads the same sources (`nim dump`, then one `nim check` per
    # target platform), so the same save used to re-run every check.
    let sb = newResaveSandbox("resave-probe")
    defer: sb.dispose()
    let opts = ProfileCompileOptions(stateDir: sb.stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot)
    withSpyOnPath(sb):
      let first = probeProfilePlatforms(sb.profilePath, opts)
      checkpoint("probe first: decision=" & $first.cacheDecision)
      check first.edgeLaunched
      let checksOnce = sb.nimSpawnCount("check")
      check checksOnce >= 1
      # Vacuity guard: the host's own platform was evaluated.
      var anyEvaluated = false
      for o in first.outcomes:
        if o.evaluated:
          anyEvaluated = true
      check anyEvaluated

      # Positive control: an untouched sandbox is answered from the cache, so
      # this edge's record was published and the next answer is not vacuous.
      # (On macOS it may fail closed instead; the re-save assertion is then
      # not made.)
      let unchanged = probeProfilePlatforms(sb.profilePath, opts)
      checkpoint("probe unchanged: decision=" & $unchanged.cacheDecision &
        " miss=" & unchanged.cacheMissReason)
      let failedClosed = EdgeMayFailClosed and unchanged.edgeLaunched
      if not failedClosed:
        check not unchanged.edgeLaunched
        check unchanged.cacheDecision in CacheAnswers

      sb.resaveWithoutEdit()
      let spawnsBefore = sb.nimSpawnCount()
      let second = probeProfilePlatforms(sb.profilePath, opts)
      checkpoint("probe second (after the re-save): decision=" &
        $second.cacheDecision & " miss=" & second.cacheMissReason)
      if failedClosed:
        echo "    [fail-closed, GM0m] probe re-save case: the unchanged ",
          "probe re-ran, so every probe re-runs"
        check second.edgeLaunched
      else:
        check not second.edgeLaunched
        # The probe read the re-saved root module, so this is the content
        # comparison and not a metadata hit.
        check second.cacheDecision == cdHybridCutoff
        check sb.nimSpawnCount() == spawnsBefore
      check second.outcomes.len == first.outcomes.len

      # Soundness control: a real edit of the root module re-runs the probe.
      # Other bytes of the same length, so size is not what shows it.
      sleep(1100)
      sb.writeProfileFile("home.nim", EditedResaveProfile)
      let checksBeforeEdit = sb.nimSpawnCount("check")
      let third = probeProfilePlatforms(sb.profilePath, opts)
      checkpoint("probe third (after the edit): decision=" &
        $third.cacheDecision & " miss=" & third.cacheMissReason)
      check third.edgeLaunched
      check sb.nimSpawnCount("check") > checksBeforeEdit

  test "repro home export after a save that changes no byte spawns no nim":
    # The public command the measurement was taken through. It runs the
    # compile, the run and the platform-probe edges.
    let sb = newResaveSandbox("resave-export")
    defer: sb.dispose()
    let args = ["home", "export", "--host", DefaultSandboxHost]

    let cold = sb.runRepro(args)
    checkpoint("cold export exit " & $cold.exitCode & "\nstderr:\n" &
      cold.stderr)
    check cold.exitCode == 0
    check cold.nimCompileSpawns >= 1
    check cold.nimSpawns > cold.nimCompileSpawns  # the probe ran too

    sb.resaveWithoutEdit()
    let resaved = sb.runRepro(args)
    checkpoint("export after the re-save exit " & $resaved.exitCode &
      "\nstderr:\n" & resaved.stderr)
    check resaved.exitCode == 0
    check cacheAnswered(resaved.nimSpawns, cold.nimSpawns,
      "re-saved profile, repro home export")
    if cold.exitCode == 0 and resaved.exitCode == 0:
      # The document is the same one, and it carries the payload.
      let coldDoc = parseJson(cold.stdout)
      let resavedDoc = parseJson(resaved.stdout)
      check coldDoc == resavedDoc
      check cold.stdout.contains(PayloadOne)
