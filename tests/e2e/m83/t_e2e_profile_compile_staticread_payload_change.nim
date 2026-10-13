## The profile compile is a normal monitored edge: a payload a profile reads
## with `staticRead` invalidates the compiled intent.
##
## Primary assertion — `e2e_profile_compile_staticread_payload_change`: a
## profile whose `resources:` helper reads `payload.txt` through `staticRead`
## plans `alpha`, `bravo`, `charlie` across three payload edits with no other
## change, through the public `repro home plan`.
##
## This is the defect the edge's old structural fast path could not catch.
## That fast path named the published `.rbpi` after a digest of an `import
## ./…` text walk and returned it before the build engine was consulted;
## `payload.txt` is not imported, so the digest never moved and the second run
## planned `alpha` again. Measured before the fix (reprobuild `0fee0fe6`,
## x86_64-linux): alpha, alpha, alpha. Reinstating the fast path in
## `compileProfileToRbpi` turns this gate red at the bravo run.
##
## Vacuity guard: every run asserts the published intent holds EXACTLY ONE
## resource — an `fs.userFile` whose `content` is the payload — and that the
## content equals the payload as it stands, so the gate cannot pass on an
## intent that lost the resource or never read the file.
##
## Negative control: an unchanged payload on a second run spawns no `nim`
## (observed through the `nim` spy, see `profile_compile_edge_harness.nim`)
## and re-publishes nothing; the library-level case below additionally reads
## the ENGINE's own decision and requires `cdHit` with the edge not launched.
## Without this the primary assertion would also pass for an edge that simply
## recompiled every time.
##
## No mocks. The real `build/bin/repro`, the real Nim compiler, the real
## io-mon shim and the real filesystem; the `nim` on `PATH` is a pass-through
## counter, justified in the harness header.

import repro_test_support/reasoned_skip

const PlatformSkipReason =
  "[platform N/A] t_e2e_profile_compile_staticread_payload_change: the nim " &
  "spy is a POSIX shell script and the gate is verified on Linux, where " &
  "io-mon is the established backend. macOS is milestone GM0m " &
  "(e2e_profile_compile_staticread_payload_change_macos); Windows has no " &
  "POSIX spy."

when not defined(linux):
  import std/unittest

  suite "profile compile edge: staticRead payload change":
    test "e2e_profile_compile_staticread_payload_change":
      skip(PlatformSkipReason)
    test "library edge answers an unchanged payload from the action cache":
      skip(PlatformSkipReason)
else:
  import std/[os, strutils, tables, unittest]

  import repro_build_engine
  import repro_profile
  import repro_profile_intent
  import repro_profile_compile

  import ./profile_compile_edge_harness

  const PayloadProfile = """
import repro_profile

proc payloadText(): string =
  ## The helper reads its data with `staticRead`: a compile-time read that no
  ## `import` statement mentions.
  const text = staticRead("payload.txt")
  text

template payloadFile(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources,
    hostFile = "~/payload-" & payloadText() & ".txt",
    content = payloadText())

profile "gm0StaticReadPayload":
  resources:
    payloadFile()
"""

  proc checkSinglePayloadResource(intent: ProfileIntent; payload: string) =
    ## The vacuity guard: exactly one resource, an `fs.userFile`, whose
    ## content is the payload as it stands now.
    check intent.resources.len == 1
    if intent.resources.len == 1:
      let r = intent.resources[0]
      check r.kind == "fs.userFile"
      check r.fields.hasKey("content")
      if r.fields.hasKey("content"):
        check r.fields["content"].s == payload
      check r.fields["hostFile"].s == "~/payload-" & payload & ".txt"

  proc checkPlans(run: PlanRun; payload: string) =
    checkpoint("repro home plan output:\n" & run.output)
    check run.exitCode == 0
    check run.createLines.len == 1
    check run.output.contains("1 resource(s) planned")
    if run.createLines.len == 1:
      check run.createLines[0].contains(
        "fs.userFile:~/payload-" & payload & ".txt")
    checkSinglePayloadResource(run.intent, payload)

  suite "profile compile edge: staticRead payload change":

    test "e2e_profile_compile_staticread_payload_change":
      let sb = newProfileSandbox("staticread", PayloadProfile)
      defer: sb.dispose()

      sb.writeProfileFile("payload.txt", "alpha")
      let run1 = sb.runHomePlan()
      checkPlans(run1, "alpha")
      # A cold compile spawns nim — this is what makes the spy count below
      # meaningful rather than vacuously zero.
      check run1.nimSpawns >= 1
      let rbpiMtime = getLastModificationTime(sb.publishedRbpiPath())

      # Negative control: nothing changed, so the action cache answers. No nim
      # process is spawned and the published envelope is not rewritten.
      sleep(1100)  # ext4 / APFS timestamp granularity.
      let run2 = sb.runHomePlan()
      checkPlans(run2, "alpha")
      check run2.nimSpawns == 0
      check getLastModificationTime(sb.publishedRbpiPath()) == rbpiMtime

      # The payload is the ONLY thing that changes from here on.
      sb.writeProfileFile("payload.txt", "bravo")
      let run3 = sb.runHomePlan()
      checkPlans(run3, "bravo")
      check run3.nimSpawns >= 1

      sb.writeProfileFile("payload.txt", "charlie")
      let run4 = sb.runHomePlan()
      checkPlans(run4, "charlie")
      check run4.nimSpawns >= 1

    test "library edge answers an unchanged payload from the action cache":
      # The same sequence through `compileProfileToRbpi`, so the negative
      # control can read the ENGINE's decision rather than infer it: the
      # unchanged run must be `cdHit` with the edge not launched.
      let sb = newProfileSandbox("staticread-lib", PayloadProfile)
      defer: sb.dispose()
      let savedPath = getEnv("PATH")
      putEnv("PATH", sb.spyDir & $PathSep & savedPath)
      defer: putEnv("PATH", savedPath)
      let opts = ProfileCompileOptions(stateDir: sb.stateDir,
        publicCliPath: reproBinary(), repoRoot: ProjectRoot)

      sb.writeProfileFile("payload.txt", "alpha")
      let first = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("first: decision=" & $first.cacheDecision &
        " publishSkip=" & first.cachePublishSkipReason)
      check first.edgeLaunched
      check first.cachePublishSkipReason.len == 0
      checkSinglePayloadResource(decodeRbpi(first.rbpiBytes), "alpha")
      # The payload is in the monitored dependency record — the reason the
      # edge can be invalidated by it at all.
      var sawPayload = false
      for path in first.observedInputs:
        if path.endsWith("payload.txt"):
          sawPayload = true
      check sawPayload

      let spawnsBefore = sb.nimSpawnCount()
      let second = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("second: decision=" & $second.cacheDecision &
        " miss=" & second.cacheMissReason)
      check not second.edgeLaunched
      check second.cacheDecision == cdHit
      check sb.nimSpawnCount() == spawnsBefore
      checkSinglePayloadResource(decodeRbpi(second.rbpiBytes), "alpha")

      sb.writeProfileFile("payload.txt", "bravo")
      let third = compileProfileToRbpi(sb.profilePath, opts)
      checkpoint("third: decision=" & $third.cacheDecision &
        " miss=" & third.cacheMissReason)
      check third.edgeLaunched
      check sb.nimSpawnCount() > spawnsBefore
      checkSinglePayloadResource(decodeRbpi(third.rbpiBytes), "bravo")
