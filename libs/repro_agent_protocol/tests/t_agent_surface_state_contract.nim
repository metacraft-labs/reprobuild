## ReproOS-Agent-Harbor-Integration M2, headless: every state the desktop
## surface must render (idle, consent, planning, running, preview,
## conflict, error, completion) is a state `surfaceViewOf` derives from a
## real host, and the view carries what the pane must show in it.
##
## The host is real; `ScriptBackend` stands in for Reprobuild because the
## subject is the derivation, and it is what lets the test look at the
## view WHILE an operation runs (the backend reads it from inside its own
## call) and choose each operation's outcome.

import std/[os, sequtils, sets, tables, unittest]

import repro_agent_protocol

type ScriptBackend = ref object of Backend
  host: Host
  sid: string
  seenWhileRunning: seq[SurfaceView]
  failBuild: bool

method createCheckout(b: ScriptBackend; package, root: string): OpResult =
  writeFile(root / "README.md", "x")
  OpResult(status: osCompleted)

method runBuild(b: ScriptBackend; ws: Workspace; op: Operation): OpResult =
  b.seenWhileRunning.add surfaceViewOf(b.host, b.sid)
  if b.failBuild: OpResult(status: osFailed, detail: "compile error")
  else: OpResult(status: osCompleted)

method preview(b: ScriptBackend; ws: Workspace; op: Operation): OpResult =
  OpResult(status: osCompleted, output: "after")

method reapplyCheckout(b: ScriptBackend; package, root: string;
                       op: Operation): OpResult =
  OpResult(status: osCompleted, output: "reapply=conflict\nrejected=x.rej\n")

method activeGeneration(b: ScriptBackend): string = "gen-1"

proc g(s: string): Grant = parseGrant(s)
proc op(kind: OperationKind; target: string;
        args: openArray[(string, string)] = []): Operation =
  result = Operation(kind: kind, target: target)
  for (n, v) in args:
    result.args.add OpArg(name: n, value: v)

suite "M2 — the consent surface's states":
  test "every required state is derived, with what the pane must show":
    let root = getTempDir() / "t_surface_" & $getCurrentProcessId()
    removeDir(root)
    let b = ScriptBackend()
    let h = newHost(b, root / "ws")
    b.host = h
    let consent = newConnection(chConsent)
    discard h.hello(consent, ProtocolVersion, {low(Family) .. high(Family)})
    let (sid, secret) = h.createSession(consent, "agent-harbor", @[
      g("workspace.create:hello"), g("build.run:hello"),
      g("preview.run:hello")])
    b.sid = sid
    let agent = newConnection(chProvider)
    discard h.hello(agent, ProtocolVersion, {low(Family) .. high(Family)})
    h.attach(agent, sid, secret)
    let profile = ProviderProfile(model: "local-model", inference: "local")
    var seen = initHashSet[SurfaceState]()
    proc view(): SurfaceView =
      result = surfaceViewOf(h, sid, profile)
      seen.incl result.state

    check view().state == svIdle
    # Grants in the vocabulary's order, as the host holds them.
    check view().grants == @["workspace.create:hello", "build.run:hello",
                             "preview.run:hello"]
    check view().canRevoke and not view().canCancel

    let intent = h.captureIntent(consent, sid, "make it say hi")
    check view().state == svPlanning

    proc run(ops: seq[Operation]; caps: seq[string]): seq[OpResult] =
      let r = h.submitPlan(agent, Plan(sessionId: sid,
        intentId: intentId(intent), baseGeneration: "gen-1",
        operations: ops, declaredCapabilities: caps.map(g)))
      h.execute(agent, r.planId.hex).results

    let ws = run(@[op(okCheckoutCreate, "hello")],
                 @["workspace.create:hello"])[0].detail
    check view().state == svCompletion

    discard run(@[op(okBuildRun, ws)], @["build.run:hello"])
    check b.seenWhileRunning[^1].state == svRunning
    check b.seenWhileRunning[^1].running == "build.run"
    check b.seenWhileRunning[^1].canCancel
    seen.incl svRunning

    discard run(@[op(okPreviewStart, ws, {"executable": "bin/x"})],
                @["preview.run:hello"])
    check view().state == svPreview
    check view().lastResults[^1].kind == "preview.start"

    b.failBuild = true
    discard run(@[op(okBuildRun, ws)], @["build.run:hello"])
    check view().state == svError
    check view().lastResults[^1].detail == "compile error"
    b.failBuild = false

    discard run(@[op(okCheckoutReapply, "hello", {"release": "r"})],
                @["workspace.create:hello"])
    check view().state == svConflict

    let staged = h.submitPlan(agent, Plan(sessionId: sid,
      intentId: intentId(intent), baseGeneration: "gen-1",
      operations: @[op(okGenerationStage, ws)],
      declaredCapabilities: @[g("system.generation:stage")]))
    let v = view()
    check v.state == svConsent
    check v.pending.len == 1
    check v.pending[0].planId == staged.planId.hex
    check v.pending[0].operations == @["generation.stage"]
    check v.pending[0].capabilities == @["system.generation:stage"]
    check v.profile.inference == "local"

    h.revokeSession(consent, sid)
    check not view().canRevoke

    check seen == toHashSet([svIdle, svConsent, svPlanning, svRunning,
                             svPreview, svConflict, svError, svCompletion])
    removeDir(root)
