## ReproOS-Agent-Harbor-Integration M4 verification
## ``e2e_agent_harbor_preview_accept_reject``.
##
## "HCR and restart fixtures preview changes, accept into the next stage,
## reject cleanly, and preserve the active generation until approval."
##
## Real repro builds, a real home generation (made current with the
## fixture's `HomeSeamDriver`, see `agent_harbor_fixture`), the real agent
## host. The consent surface is the test, on the host's consent channel.
##
## What it shows:
##   1. the preview strategy is decided and reported: on a host without a
##      direct-patch HCR profile, or with an application that has no HCR
##      agent, it is a supervised restart and says why;
##   2. the user sees before (the installed package, previewed the same
##      isolated way) and after, the test run and the diff, as evidence the
##      host itself produced, and a plan citing anything else is refused;
##   3. a rejected stage plan leaves no trace: no new prefix, the active
##      generation unchanged; the user's feedback becomes a new intent and
##      executes nothing;
##   4. an approved stage plan builds the change into the store and stages
##      its overlay, and the active generation is STILL unchanged: staging
##      is not activation.
##
## The HCR arm of the gate (an application whose HCR agent advertises this
## host's profile) needs a direct-patch host (Linux x86_64, macOS arm64) and
## an HCR-enabled fixture; it is decided by `choosePreviewStrategy`, which
## `t_agent_preview_strategy` covers, and its execution is not wired yet.
##
## Skip rule: as `agent_harbor_fixture.fixtureRunnable`.

import std/[os, sequtils, strutils, tables, unittest]

import repro_agent_protocol
import repro_agent_backend

import ./agent_harbor_fixture

if not fixtureRunnable():
  echo "[SKIP] e2e_agent_harbor_preview_accept_reject: needs Linux, " &
    reproBinary & " and cc"
else:
  suite "M4 — preview, accept, reject":
    let f = newFixture("m4", @["workspace.create:greeter",
      "source.read:greeter", "source.write:greeter", "build.run:greeter",
      "test.run:greeter", "preview.run:greeter"], withGenerations = true)
    let g1 = f.backend.activeGeneration()
    let intent = f.host.captureIntent(f.consent, f.sid, "make greeter say v2")
    let ws = f.checkoutGreeter(intent)
    var evidence: seq[Digest32]

    test "the active generation runs the installed package":
      check g1.len > 0
      check exeOutput(f.backend.driver.launcherDir / "greeter") ==
        "hello from greeter v1"

    test "before and after are previewed, tested and diffed":
      let rs = f.runPlan(intent,
        @[op(okSourceWrite, ws, {"path": "greeter/src/main.c",
                                 "content": greeterV2}),
          op(okSourceWrite, ws, {"path": "greeter/tests/expected.txt",
                                 "content": "hello from greeter v2\n"}),
          op(okBuildRun, ws, {"target": InstallTarget}),
          op(okTestRun, ws),
          op(okPreviewStart, ws, {"executable": "usr/bin/greeter",
                                  "baseline": "1"}),
          op(okPreviewStart, ws, {"executable": "usr/bin/greeter"}),
          op(okSourceDiff, ws)],
        @["source.write:greeter", "build.run:greeter", "test.run:greeter",
          "preview.run:greeter", "source.read:greeter"])
      for r in rs:
        checkpoint r.detail & "\n" & r.output
      check rs.allIt(it.status == osCompleted)
      let (before, after) = (rs[4], rs[5])
      check before.output.strip == "hello from greeter v1"
      check after.output.strip == "hello from greeter v2"
      # The strategy is decided and the reason is shown.
      check "strategy=restart" in after.detail
      check ("no direct-patch HCR profile" in after.detail or
             "did not connect an HCR agent" in after.detail)
      evidence = @[rs[3].resultId, before.resultId, after.resultId,
                   rs[6].resultId]

    test "the user is shown exactly the evidence the host produced":
      let shown = evidence.mapIt(f.host.showEvidence(f.consent, f.sid, it.hex))
      check shown.mapIt(it.kind) == @[okTestRun, okPreviewStart,
                                       okPreviewStart, okSourceDiff]
      check shown[1].output.strip == "hello from greeter v1"
      check shown[2].output.strip == "hello from greeter v2"
      check "+  puts(\"hello from greeter v2\");" in shown[3].output
      var forged = evidence
      forged[1] = id("reproos.agent.result.v1", "fake before".toBytes)
      expect AgentRefusal:
        discard f.submit(intent, @[op(okGenerationStage, ws)],
                         @["system.generation:stage"], forged)

    let prefixesBefore = toSeq(walkDir(f.store / "prefixes" / "greeter")).len

    test "a rejected change leaves no trace and feedback executes nothing":
      let r = f.submit(intent, @[op(okGenerationStage, ws,
                                    {"target": InstallTarget})],
                       @["system.generation:stage"], evidence)
      check r.approvalRequired == @[0]
      f.host.rejectPlan(f.consent, r.planId.hex)
      expect AgentRefusal:
        discard f.host.execute(f.agent, r.planId.hex)
      let fb = f.host.captureFeedback(f.consent, f.sid, r.planId.hex,
                                      "say v2, but keep the exclamation")
      check fb.text.startsWith("say v2")
      check f.backend.activeGeneration() == g1
      check toSeq(walkDir(f.store / "prefixes" / "greeter")).len == prefixesBefore
      check f.backend.staged.len == 0
      check exeOutput(f.backend.driver.launcherDir / "greeter") ==
        "hello from greeter v1"

    test "an approved change is staged; the active generation still waits":
      let r = f.submit(intent, @[op(okGenerationStage, ws,
        {"target": InstallTarget, "intent": "make greeter say v2",
         "health": "command-exit-zero:greeter"})],
        @["system.generation:stage"], evidence)
      let a = f.host.approvePlan(f.consent, r.planId.hex)
      let rs = f.host.execute(f.agent, r.planId.hex, a).results
      checkpoint rs[0].detail & "\n" & rs[0].output
      check rs[0].status == osCompleted
      check rs[0].detail.startsWith("release=")
      check f.backend.staged.len == 1
      check toSeq(walkDir(f.store / "prefixes" / "greeter")).len ==
        prefixesBefore + 1
      # Staging is not activation.
      check f.backend.activeGeneration() == g1
      check exeOutput(f.backend.driver.launcherDir / "greeter") ==
        "hello from greeter v1"

    cleanup(f.tmp)
