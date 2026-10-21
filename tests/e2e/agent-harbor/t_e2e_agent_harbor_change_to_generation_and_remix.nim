## ReproOS-Agent-Harbor-Integration M5 verification
## ``e2e_agent_harbor_change_to_generation_and_remix``.
##
## "An accepted edit becomes a healthy generation and portable Remix, then
## survives an upstream update or reports an actionable conflict."
##
## Real repro builds into a real store, real home generations switched and
## rolled back by `repro home` (through the fixture's `HomeSeamDriver`, see
## `agent_harbor_fixture` for the one seam and why), real signed Remix
## manifests read back through the Remix export-bundle reader.
##
## What it shows:
##   1. an accepted change is staged as a signed draft Remix whose target is
##      the original package by interface identity, and activated (only with
##      approval) as a new generation that passes its declared health check;
##   2. the overlay exports as a portable bundle that verifies offline;
##   3. a change whose health check fails is rolled back automatically, and
##      the previous healthy generation is current again;
##   4. an explicit rollback re-selects the original generation;
##   5. after an upstream update the change re-applies cleanly to the new
##      recipe and rebuilds; an upstream edit of the same lines is reported
##      as a conflict naming the file, with the workspace kept.
##
## Skip rule: as `agent_harbor_fixture.fixtureRunnable`.

import std/[os, sequtils, strutils, tables, unittest]

import repro_agent_protocol
import repro_agent_backend
import repro_remix

import ./agent_harbor_fixture

proc approved(f: Fixture; intent: Intent; ops: seq[Operation];
              declared: seq[string]): seq[OpResult] =
  let r = f.submit(intent, ops, declared)
  check r.approvalRequired.len > 0
  let a = f.host.approvePlan(f.consent, r.planId.hex)
  f.host.execute(f.agent, r.planId.hex, a).results

proc changeTo(f: Fixture; intent: Intent; source, expected: string): string =
  ## A fresh workspace with `source` and its test expectation, built and
  ## tested. Returns the workspace id.
  let ws = f.checkoutGreeter(intent)
  let rs = f.runPlan(intent,
    @[op(okSourceWrite, ws, {"path": "greeter/src/main.c", "content": source}),
      op(okSourceWrite, ws, {"path": "greeter/tests/expected.txt",
                             "content": expected & "\n"}),
      op(okBuildRun, ws, {"target": InstallTarget}), op(okTestRun, ws)],
    @["source.write:greeter", "build.run:greeter", "test.run:greeter"])
  for r in rs:
    checkpoint r.detail & "\n" & r.output
  ws

if not fixtureRunnable():
  echo "[SKIP] e2e_agent_harbor_change_to_generation_and_remix: needs " &
    "Linux, " & reproBinary & " and cc"
else:
  suite "M5 — an accepted change becomes a generation and a Remix":
    let f = newFixture("m5", @["workspace.create:greeter",
      "source.read:greeter", "source.write:greeter", "build.run:greeter",
      "test.run:greeter", "preview.run:greeter", "remix.publish:private"],
      withGenerations = true)
    let g1 = f.backend.activeGeneration()
    let launcher = f.backend.driver.launcherDir / "greeter"
    let intent = f.host.captureIntent(f.consent, f.sid, "make greeter say v2")
    var release = ""
    var g2 = ""

    test "the accepted change is staged, then activated as a healthy generation":
      let ws = f.changeTo(intent, greeterV2, "hello from greeter v2")
      let staged = f.approved(intent, @[op(okGenerationStage, ws,
        {"target": InstallTarget, "intent": "make greeter say v2",
         "health": "command-exit-zero:greeter"})],
        @["system.generation:stage"])
      checkpoint staged[0].detail & "\n" & staged[0].output
      check staged[0].status == osCompleted
      release = staged[0].detail.split(' ')[0]["release=".len .. ^1]
      check f.backend.activeGeneration() == g1
      let act = f.approved(intent, @[op(okGenerationActivate, release)],
                           @["system.generation:activate"])
      checkpoint act[0].detail
      check act[0].status == osCompleted
      g2 = f.backend.activeGeneration()
      check g2.len > 0 and g2 != g1
      check exeOutput(launcher) == "hello from greeter v2"

    test "the overlay is a signed Remix and exports as a portable bundle":
      let ws = f.checkoutGreeter(intent)
      let rs = f.approved(intent, @[op(okRemixCapture, ws, {"release": release}),
                                    op(okRemixExport, ws, {"release": release})],
                          @["remix.publish:private", "remix.publish:export"])
      check rs.mapIt(it.status) == @[osCompleted, osCompleted]
      let bundlePath = rs[1].detail["bundle=".len .. ^1]
      let raw = readFile(bundlePath)
      var bytes = newSeq[byte](raw.len)
      for i, c in raw: bytes[i] = byte(ord(c))
      let bundle = readBundle(bytes)
      check bundle.manifests.len == 1
      let m = bundle.manifests[0].manifest
      check m.targets.len == 1
      check m.targets[0].original.package == "greeter"
      check m.targets[0].original.catalogRevision == f.installedRecipeTree
      check m.targets[0].original.interfaceFingerprint != default(Digest32)
      check m.patches.len == 1
      check m.permissions.len == 0
      check m.healthChecks.len == 1
      check m.healthChecks[0].kind == hcCommandExitZero
      check toHex(Digest32(bundle.manifests[0].id)) == release
      let patch = f.backend.staged[release].patch
      check "--- a/src/main.c" in patch
      check "+  puts(\"hello from greeter v2\");" in patch

    test "a change that fails its health check is rolled back automatically":
      let ws = f.changeTo(intent, greeterBroken.replace("greeter v1", "greeter v3"),
                          "hello from greeter v3")
      let staged = f.approved(intent, @[op(okGenerationStage, ws,
        {"target": InstallTarget, "intent": "say v3",
         "health": "command-exit-zero:greeter"})],
        @["system.generation:stage"])
      check staged[0].status == osCompleted
      let bad = staged[0].detail.split(' ')[0]["release=".len .. ^1]
      let act = f.approved(intent, @[op(okGenerationActivate, bad)],
                           @["system.generation:activate"])
      checkpoint act[0].detail
      check act[0].status == osFailed
      check "rolled back to generation " & g2 in act[0].detail
      check f.backend.activeGeneration() == g2
      check exeOutput(launcher) == "hello from greeter v2"

    test "an explicit rollback re-selects the original generation":
      let rs = f.approved(intent, @[op(okGenerationRollback, g1)],
                          @["system.generation:rollback"])
      check rs[0].status == osCompleted
      check f.backend.activeGeneration() == g1
      check exeOutput(launcher) == "hello from greeter v1"

    test "after an upstream update the change re-applies, or names its conflict":
      # Upstream adds a line elsewhere in the file: the change still applies.
      writeFile(f.recipeDir / "src" / "main.c",
                "/* upstream 1.0.1 */\n" & greeterV1)
      f.reinstall()
      let clean = f.runPlan(intent, @[op(okCheckoutReapply, "greeter",
                                         {"release": release})],
                            @["workspace.create:greeter"])
      checkpoint clean[0].output
      check clean[0].status == osCompleted
      check clean[0].output.startsWith("reapply=clean")
      let ws = clean[0].detail
      let rebuilt = f.runPlan(intent,
        @[op(okBuildRun, ws, {"target": InstallTarget}), op(okTestRun, ws),
          op(okPreviewStart, ws, {"executable": "usr/bin/greeter"})],
        @["build.run:greeter", "test.run:greeter", "preview.run:greeter"])
      check rebuilt.allIt(it.status == osCompleted)
      check rebuilt[2].output.strip == "hello from greeter v2"
      # Upstream rewrites the same line: a conflict, named, workspace kept.
      writeFile(f.recipeDir / "src" / "main.c",
                greeterV1.replace("hello from greeter v1", "hi from greeter v1"))
      f.reinstall()
      let conflict = f.runPlan(intent, @[op(okCheckoutReapply, "greeter",
                                            {"release": release})],
                               @["workspace.create:greeter"])
      checkpoint conflict[0].output
      check conflict[0].status == osCompleted
      check conflict[0].output.startsWith("reapply=conflict")
      check "rejected=greeter/src/main.c.rej" in conflict[0].output
      check f.host.workspaces.hasKey(conflict[0].detail)

    cleanup(f.tmp)
