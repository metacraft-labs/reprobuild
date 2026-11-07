## The profile binary's RUN is inside the monitored profile-compile edge: a
## file the profile reads when it runs — not when it is compiled — also
## invalidates the cached intent.
##
## Primary assertion — `e2e_profile_compile_runtime_read_tracked`: a profile
## whose `resources:` helper calls `readFile` at run time plans `one`, then,
## after only that file changes, plans `two` through the public
## `repro home plan`.
##
## Why this is a separate gate from the `staticRead` one. The published
## envelope is not the compiled binary; it is what the binary PRINTS when the
## helper runs it, so the binary's behaviour is the edge's output. A read the
## compiler never sees is a dependency all the same. If the run phase is moved
## out of the monitored edge, the compile-time evidence is unchanged by the
## edit and the previous intent is served. Two mutations were measured against
## this gate:
##
## * the run's output memoized on the profile binary's bytes (the "intent is a
##   pure function of the binary" assumption), so a re-executed edge reuses
##   the previous run: the gate goes red at the final run, which plans `one`
##   after the file says `two` — the stale intent this gate exists for;
## * the binary run with the monitor shim stripped from its environment: the
##   engine detects the blind child as a monitor loss and refuses to publish
##   (fails closed), so the edge re-runs every time and the gate goes red at
##   the negative control instead.
##
## Vacuity guards:
##
## * every run asserts exactly one resource, an `fs.userFile` whose content is
##   the file's current text;
## * the read is shown to happen at RUN time: after the edit, the already
##   compiled profile binary — run directly, without recompiling — prints the
##   new value. Without this the gate could pass because the compiler happened
##   to fold the read into a constant, which is the other gate's case.
##
## Negative control: an unchanged file on a second run spawns no `nim` and
## plans the same value.
##
## ONLY THE RUN EDGE RE-RUNS. Since the profile compile was split into a
## compile edge and a run edge (reprobuild-pm
## `spec/Profile-Compilation-Model.md` §2), a file read only at run time is
## an input of the run edge alone. After its edit the CLI case spawns no
## `nim` (the compile is answered from the cache) and still plans the new
## value; the library case reads the engine's decision per edge: the compile
## edge `cdHit` and not launched, the run edge launched with the file named
## in its miss reason.
##
## No mocks: real `build/bin/repro`, real Nim, real io-mon shim, real
## filesystem; the `nim` spy is a pass-through counter (harness header).

## Platforms: every host. On macOS (milestone GM0m) the negative control
## accepts a complete re-run in place of a cache answer when macOS monitoring
## makes the edge fail closed (`cacheAnswered` in the harness); the planned
## value must be the file's current text everywhere.

import std/[os, strutils, tables, unittest]

import repro_build_engine
import repro_profile
import repro_profile_intent
import repro_profile_compile

import ./profile_compile_edge_harness

const RuntimeReadProfile = """
import std/os
import repro_profile

const RuntimePayloadPath = currentSourcePath().parentDir / "runtime.txt"

proc runtimePayload(): string =
  ## A RUN-TIME read: the path is a constant, the content is not.
  readFile(RuntimePayloadPath)

template runtimeFile(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources,
    hostFile = "~/runtime-" & runtimePayload() & ".txt",
    content = runtimePayload())

profile "gm0RuntimeRead":
  resources:
    runtimeFile()
"""

proc checkPlans(run: PlanRun; value: string) =
  checkpoint("repro home plan output:\n" & run.output)
  check run.exitCode == 0
  check run.createLines.len == 1
  if run.createLines.len == 1:
    check run.createLines[0].contains(
      "fs.userFile:~/runtime-" & value & ".txt")
  check run.intent.resources.len == 1
  if run.intent.resources.len == 1:
    let r = run.intent.resources[0]
    check r.kind == "fs.userFile"
    check r.fields["content"].s == value

suite "profile compile edge: run-time reads":

  test "e2e_profile_compile_runtime_read_tracked":
    let sb = newProfileSandbox("runtime-read", RuntimeReadProfile)
    defer: sb.dispose()

    sb.writeProfileFile("runtime.txt", "one")
    let run1 = sb.runHomePlan()
    checkPlans(run1, "one")
    check run1.nimSpawns >= 1

    # Negative control: unchanged input, no nim, same plan (on macOS, or a
    # complete re-run: harness header).
    let run2 = sb.runHomePlan()
    checkPlans(run2, "one")
    check cacheAnswered(run2.nimSpawns, run1.nimSpawns,
      "unchanged run-time file, repro home plan")

    sb.writeProfileFile("runtime.txt", "two")
    # Vacuity guard: the read happens at RUN time. The binary compiled for
    # run 1, run again unchanged, already reports the new value.
    let direct = sb.runProfileBinaryDirectly()
    checkpoint("profile binary run directly:\n" & direct)
    check direct.contains("runtime-two.txt")
    check not direct.contains("runtime-one.txt")

    let run3 = sb.runHomePlan()
    checkPlans(run3, "two")
    # Only the run edge re-ran: the compile was answered from the cache, so
    # no `nim` was spawned for the edit (on macOS, or a complete re-run).
    check cacheAnswered(run3.nimSpawns, run1.nimSpawns,
      "run-time file edited, repro home plan: the compile edge")

  test "a run-time read re-runs the run edge and not the compile":
    # The same sequence through `compileProfileToRbpi`, reading the ENGINE's
    # decision for each edge instead of inferring it from spawn counts.
    let sb = newProfileSandbox("runtime-read-lib", RuntimeReadProfile)
    defer: sb.dispose()
    let opts = ProfileCompileOptions(stateDir: sb.stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot)

    sb.writeProfileFile("runtime.txt", "one")
    let first = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("first: publishSkip=" & first.cachePublishSkipReason)
    check first.compileEdge.launched
    check first.runEdge.launched
    check decodeRbpi(first.rbpiBytes).resources[0].fields["content"].s == "one"
    # The run-time read is in the RUN edge's record, and not in the
    # compile's: the compiler never opened the file.
    var runSaw, compileSaw = false
    for path in first.runEdge.observedInputs:
      if path.endsWith("runtime.txt"):
        runSaw = true
    for path in first.compileEdge.observedInputs:
      if path.endsWith("runtime.txt"):
        compileSaw = true
    check not compileSaw
    let failedClosed = EdgeMayFailClosed and
      first.cachePublishSkipReason.len > 0
    if not failedClosed:
      check runSaw

    sb.writeProfileFile("runtime.txt", "two")
    let second = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("second: compile=" & $second.compileEdge.cacheDecision &
      " run=" & $second.runEdge.cacheDecision & " runMiss=" &
      second.runEdge.cacheMissReason)
    check decodeRbpi(second.rbpiBytes).resources[0].fields["content"].s ==
      "two"
    check second.runEdge.launched
    if failedClosed:
      echo "    [fail-closed, GM0m] run-time read library case: publish " &
        "skipped (", first.cachePublishSkipReason, ")"
    else:
      check second.compileEdge.cacheDecision == cdHit
      check not second.compileEdge.launched
      check second.runEdge.cacheMissReason.contains("runtime.txt")
