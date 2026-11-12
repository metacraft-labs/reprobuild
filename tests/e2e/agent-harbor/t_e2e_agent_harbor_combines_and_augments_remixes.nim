## ReproOS-Agent-Harbor-Integration M6 verification
## ``e2e_agent_harbor_combines_and_augments_remixes``.
##
## "Compatible Remixes compose into a healthy generation with full lineage,
## while conflicts and blocked safety scores stop before activation."
##
## Real repro builds and home generations (`agent_harbor_fixture`, with its
## one test seam), real signed overlays, and the Remix protocol's own
## composition (`repro_remix.compose`). The Remixes are local overlays the
## agent staged; a marketplace registry is not involved (see the M6 entry).
##
## What it shows:
##   1. two Remixes changing disjoint files compose; the composed workspace
##      carries both changes, builds, passes its test, and stages as a
##      release whose parents are both members; activated (with approval)
##      it is a healthy generation running both changes;
##   2. two Remixes changing the same lines are refused as a patch
##      conflict, and a blocked member refuses the composition, in both
##      cases before any workspace or generation exists.
##
## Skip rule: as `agent_harbor_fixture.fixtureRunnable`.

import std/[os, sequtils, sets, strutils, tables, unittest]

import repro_agent_protocol
import repro_agent_backend
import repro_remix

import ./agent_harbor_fixture

proc approved(f: Fixture; intent: Intent; ops: seq[Operation];
              declared: seq[string]): seq[OpResult] =
  let r = f.submit(intent, ops, declared)
  let a = f.host.approvePlan(f.consent, r.planId.hex)
  f.host.execute(f.agent, r.planId.hex, a).results

proc stageChange(f: Fixture; intent: Intent;
                 writes: seq[(string, string)]): string =
  ## Check out, apply `writes`, stage; returns the release id.
  let ws = f.checkoutGreeter(intent)
  var ops: seq[Operation]
  for (path, content) in writes:
    ops.add op(okSourceWrite, ws, {"path": "greeter/" & path, "content": content})
  discard f.runPlan(intent, ops, @["source.write:greeter"])
  let rs = f.approved(intent, @[op(okGenerationStage, ws,
    {"target": InstallTarget, "intent": "change",
     "health": "command-exit-zero:greeter"})], @["system.generation:stage"])
  doAssert rs[0].status == osCompleted, rs[0].detail & "\n" & rs[0].output
  rs[0].detail.split(' ')[0]["release=".len .. ^1]

if not fixtureRunnable():
  echo "[SKIP] e2e_agent_harbor_combines_and_augments_remixes: needs " &
    "Linux, " & reproBinary & " and cc"
else:
  suite "M6 — compose and augment Remixes":
    # Acquired on first use from inside a case, so the runner's
    # `--list-json` probe installs nothing and a failed install fails the
    # case that needed it; released at the end of this suite by the process
    # that acquired it (see `agent_harbor_fixture`).
    var fixture = lazyFixture("m6", @["workspace.create:greeter",
      "source.read:greeter", "source.write:greeter", "build.run:greeter",
      "test.run:greeter", "remix.publish:private"], "combine greeter remixes",
      withGenerations = true)
    template f: Fixture = fixture.acquire()
    template g1: string = f.initialGeneration
    template launcher: string = f.backend.driver.launcherDir / "greeter"
    template intent: Intent = f.sessionIntent
    var staged: seq[string]

    # The suite runner runs every case in a process of its own, so a case
    # must not rely on a Remix or generation an earlier case made
    # (Test-Suite-Architecture-Guidelines, "Every case MUST pass when run
    # alone"). The three Remixes are staged at most once per process, on
    # first use.
    proc remixes(): tuple[a, b, c: string] =
      ## A (v2 in main.c), B (the banner) and C (main.c's same line as A).
      if staged.len == 0:
        staged = @[
          f.stageChange(intent, @[("src/main.c", greeterV2),
            ("tests/expected.txt", "hello from greeter v2\n")]),
          f.stageChange(intent, @[("src/banner.txt", "banner from remix B\n")]),
          f.stageChange(intent, @[("src/main.c",
            greeterV1.replace("hello from greeter v1", "hello from greeter C"))])]
      (staged[0], staged[1], staged[2])

    test "compatible Remixes compose into a healthy generation with lineage":
      let (a, b, _) = remixes()
      let composed = f.runPlan(intent, @[op(okRemixCompose, "greeter",
        {"releases": a & "," & b})], @["workspace.create:greeter"])
      checkpoint composed[0].detail & "\n" & composed[0].output
      check composed[0].status == osCompleted
      check composed[0].output.startsWith("composition=")
      check "permissions=\n" in composed[0].output
      let ws = composed[0].detail
      let root = f.host.workspaces[ws].root
      check readFile(root / "greeter" / "src" / "banner.txt") ==
        "banner from remix B\n"
      check "greeter v2" in readFile(root / "greeter" / "src" / "main.c")
      let built = f.runPlan(intent, @[op(okBuildRun, ws, {"target": InstallTarget}),
                                       op(okTestRun, ws)],
                            @["build.run:greeter", "test.run:greeter"])
      check built.allIt(it.status == osCompleted)
      let staged = f.approved(intent, @[op(okGenerationStage, ws,
        {"target": InstallTarget, "intent": "A and B together",
         "health": "command-exit-zero:greeter"})], @["system.generation:stage"])
      check staged[0].status == osCompleted
      let ab = staged[0].detail.split(' ')[0]["release=".len .. ^1]
      # Lineage: the composition is a release whose parents are its members.
      let raw = readFile(f.backend.staged[ab].manifestPath)
      var bytes = newSeq[byte](raw.len)
      for i, ch in raw: bytes[i] = byte(ord(ch))
      let parents = decodeAndVerify(bytes).manifest.parents.mapIt(toHex(it))
      check parents.toHashSet == [a, b].toHashSet
      check f.backend.activeGeneration() == g1
      let act = f.approved(intent, @[op(okGenerationActivate, ab)],
                           @["system.generation:activate"])
      checkpoint act[0].detail
      check act[0].status == osCompleted
      check f.backend.activeGeneration() != g1
      check exeOutput(launcher) == "hello from greeter v2"

    test "a patch conflict stops the composition before anything exists":
      let (a, _, c) = remixes()
      let activeBefore = f.backend.activeGeneration()
      let workspacesBefore = f.host.workspaces.len
      let rs = f.runPlan(intent, @[op(okRemixCompose, "greeter",
        {"releases": a & "," & c})], @["workspace.create:greeter"])
      checkpoint rs[0].detail
      check rs[0].status == osFailed
      check "patch" in rs[0].detail
      check f.host.workspaces.len == workspacesBefore
      check f.backend.activeGeneration() == activeBefore

    test "a blocked member stops the composition before anything exists":
      let (a, b, _) = remixes()
      let activeBefore = f.backend.activeGeneration()
      f.backend.blocked.incl b
      let workspacesBefore = f.host.workspaces.len
      let rs = f.runPlan(intent, @[op(okRemixCompose, "greeter",
        {"releases": a & "," & b})], @["workspace.create:greeter"])
      checkpoint rs[0].detail
      check rs[0].status == osFailed
      check "blocked" in rs[0].detail
      check f.host.workspaces.len == workspacesBefore
      check f.backend.activeGeneration() == activeBefore

    fixture.release()
