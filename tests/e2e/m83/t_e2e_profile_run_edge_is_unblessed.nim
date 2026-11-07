## The profile compile's RUN edge carries no entropy blessing, and the
## COMPILE edge's blessing does not reach it.
##
## Since 2026-10-22 a profile compile is two edges (reprobuild-pm
## `spec/Profile-Compilation-Model.md` §2): the compile edge
## (`__repro_profile_compile`, the helper running `nim c`) carries the
## provider compile's entropy blessing, and the run edge
## (`__repro_profile_run`, the profile binary launched directly) carries
## none. The blessing is sound only for the compile: the run's process tree is
## chosen by the profile -- user code -- and its randomness can reach the
## intent, exactly the case idiomatic-reprobuild.md §4.3 ("Never bless an
## interpreter") exists for. This gate holds that line.
##
## Fixture: a profile whose one resource's content is 16 bytes drawn from
## `std/sysrand` when the binary RUNS. That draw is real entropy that reaches
## the output, so the run edge must never be published, on any platform.
##
## Primary assertion -- `e2e_profile_run_edge_is_unblessed`: the first
## compile executes both edges; the run edge's capture holds the draw
## (`entropySources`, the vacuity guard: the monitor saw it) and its publish
## is skipped with `unblessed-entropy`. The second compile of the unchanged
## profile runs the binary AGAIN (not a hit) and plans different content --
## which is what a publication would have frozen.
##
## Second assertion -- `e2e_profile_compile_blessing_does_not_reach_run`: in
## the same graph the compile edge IS published (its blessing at work) and
## the run edge is not; the compile edge is answered from the cache on the
## second call while the run edge re-runs. On Windows the compile edge's own
## capture additionally holds entropy (the stack-protector canary seed MSYS2's
## gcc toolchain draws in nearly every process), so the two edges differ in
## nothing but their policy: one draw is excused, the other is not. The two
## actions are also checked as constructed: `ndpEntropyBlessed` with
## `ProviderCompilerEntropyJustification` on the compile, `ndpUnblessed` with
## no per-image blessings on the run.
##
## Falsifying mutation (performed when this gate was written; see GM1w):
## bless the run edge (`nonDeterminism = ndpEntropyBlessed` with any
## justification in `profileRunBuildAction`). The primary case goes red: the
## first run edge is published and the second call is a cache hit that plans
## the first run's random content again.
##
## Platforms: every host. On macOS (milestone GM0m) the compile edge may fail
## closed for reasons of the macOS monitor (`EdgeMayFailClosed`, harness
## header); the compile-edge publication checks are then reported rather than
## asserted. Nothing about the RUN edge is relaxed anywhere: if macOS cannot
## observe the draw, the vacuity guard fails rather than letting the gate pass
## for the wrong reason.
##
## No mocks: real `build/bin/repro`, real Nim and C toolchain, real io-mon
## shim, real `std/sysrand`, real filesystem.

import std/[strutils, tables, unittest]

import repro_core
import repro_build_engine
import repro_profile
import repro_profile_intent
import repro_profile_compile

import ./profile_compile_edge_harness

const EntropyProfile = """
import std/[strutils, sysrand]
import repro_profile

proc drawn(): string =
  ## Run-time entropy that REACHES the intent: the resource's content.
  for b in urandom(16):
    result.add toHex(b)

template entropyFile(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources,
    hostFile = "~/run-edge-entropy.txt",
    content = drawn())

profile "runEdgeEntropy":
  resources:
    entropyFile()
"""

proc drawnContent(art: ProfileCompileArtifact): string =
  ## The planned content, with the shape asserted (vacuity guard: exactly
  ## one resource, 32 hex digits).
  let intent = decodeRbpi(art.rbpiBytes)
  check intent.resources.len == 1
  if intent.resources.len == 1:
    result = intent.resources[0].fields["content"].s
  check result.len == 32

proc compileOptions(sb: ProfileSandbox): ProfileCompileOptions =
  ProfileCompileOptions(stateDir: sb.stateDir,
    publicCliPath: reproBinary(), repoRoot: ProjectRoot)

suite "profile run edge: unblessed":

  test "e2e_profile_run_edge_is_unblessed":
    let sb = newProfileSandbox("run-edge-entropy", EntropyProfile)
    defer: sb.dispose()
    let opts = sb.compileOptions()

    let first = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("first: run entropy=" & first.runEdge.entropySources.join(",") &
      " runSkip=" & first.runEdge.cachePublishSkipReason)
    check first.compileEdge.launched
    check first.runEdge.launched
    # Vacuity guard: the monitor saw the profile's draw in the run edge.
    check first.runEdge.entropySources.len > 0
    # ... and the unblessed run edge refused to publish because of it.
    check "unblessed-entropy" in first.runEdge.cachePublishSkipReason
    let firstContent = first.drawnContent()

    let second = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("second: run=" & $second.runEdge.cacheDecision & " miss=" &
      second.runEdge.cacheMissReason)
    # The binary RAN again: nothing was published for it to hit.
    check second.runEdge.launched
    check second.runEdge.cacheDecision != cdHit
    check "unblessed-entropy" in second.runEdge.cachePublishSkipReason
    # And it is right not to have been cached: the intent differs per run.
    check second.drawnContent() != firstContent

  test "e2e_profile_compile_blessing_does_not_reach_run":
    # As constructed: the compile edge carries the provider compile's
    # blessing, the run edge nothing.
    let key = "0123"
    let compileAction = profileCompileBuildAction("/p/home.nim",
      "/s/bin/" & key & "/profile-build", "/s/nimcache/" & key, "/bin/repro",
      "", "/repo", weakFingerprintFromText("blessing-scope"))
    let runAction = profileRunBuildAction("/p/home.nim",
      "/s/bin/" & key & "/profile-build", "/s/" & key & ".intent.json", "",
      profileRunWeakFingerprint("/s/" & key & ".intent.json"))
    check compileAction.nonDeterminism == ndpEntropyBlessed
    check compileAction.nonDeterminismJustification ==
      ProviderCompilerEntropyJustification
    check runAction.nonDeterminism == ndpUnblessed
    check runAction.nonDeterminismJustification.len == 0
    check runAction.entropyBlessedImages.len == 0

    # As executed, in ONE graph: the blessed compile publishes, the run in
    # the same build does not.
    let sb = newProfileSandbox("blessing-scope", EntropyProfile)
    defer: sb.dispose()
    let opts = sb.compileOptions()
    let first = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("first: compile entropy=" &
      first.compileEdge.entropySources.join(",") & " compileSkip=" &
      first.compileEdge.cachePublishSkipReason & " runSkip=" &
      first.runEdge.cachePublishSkipReason)
    check "unblessed-entropy" in first.runEdge.cachePublishSkipReason
    when defined(windows):
      # Measured: the MinGW toolchain seeds its stack-protector canary
      # through `ProcessPrng` / `RtlGenRandom` in nearly every process. That
      # draw is in the compile edge's capture and is excused there.
      check first.compileEdge.entropySources.len > 0
    let compileFailedClosed = EdgeMayFailClosed and
      first.compileEdge.cachePublishSkipReason.len > 0
    if compileFailedClosed:
      echo "    [fail-closed, GM0m] compile edge publish skipped (",
        first.compileEdge.cachePublishSkipReason, ")"
    else:
      check first.compileEdge.cachePublishSkipReason.len == 0
      check "entropy" notin first.compileEdge.cachePublishSkipReason

    let second = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("second: compile=" & $second.compileEdge.cacheDecision &
      " run=" & $second.runEdge.cacheDecision)
    check second.runEdge.launched
    check second.runEdge.cacheDecision != cdHit
    if not compileFailedClosed:
      check second.compileEdge.cacheDecision == cdHit
      check not second.compileEdge.launched
