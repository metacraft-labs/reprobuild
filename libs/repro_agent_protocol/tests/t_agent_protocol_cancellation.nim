## ReproOS-Agent-Harbor-Integration M0: cancellation of running operations
## (spec `ReproOS-Agent-Integration-Protocol.md` §"Cancellation").
##
## The host is real and, in the first two cases, so are its sockets: the
## cancellation travels as a `plan.cancel` frame while the host is inside a
## backend call, which is the whole difficulty. `SlowBackend` stands in for
## Reprobuild because the subject is the host: its build runs a REAL child
## process (`sleep`) and waits for it at the host's cancellation checkpoint
## the way `ReprobuildBackend.run` does, so the test can show the process
## is gone; its activation has a preparation phase, a commit point and a
## health phase, so the test can cancel on either side of the commit.
##
## The remaining cases drive the host directly and deliver the cancellation
## through `Host.pump`, the hook the socket server installs: the pump is
## exactly where a cancellation can enter a running execution.

import std/[asyncdispatch, os, osproc, posix, sequtils, unittest]

import cbor
import repro_core/ambient_execution
import repro_agent_protocol
import repro_agent_protocol/transport

type SlowBackend = ref object of Backend
  childPid: int        ## the build's child process, 0 before it started
  childAlive: bool
  tests: int           ## test.run calls that ran
  active: string       ## the active generation
  prepared, healthChecked: int

method createCheckout(b: SlowBackend; package, root: string): OpResult =
  writeFile(root / "README.md", package)
  OpResult(status: osCompleted)

method runBuild(b: SlowBackend; ws: Workspace; op: Operation): OpResult =
  # `sleep` from PATH: a fixed `/bin/sleep` does not exist on every Linux
  # (NixOS has no `/bin` beyond `/bin/sh`), and a child that never starts
  # leaves the socket cases waiting for it forever.
  let p = uncontrolledStartProcess(findExe("sleep"), args = ["30"], options = {})
  defer: p.close()
  b.childPid = p.processID
  b.childAlive = true
  while p.running:
    if b.checkpoint():
      p.terminate()
      discard p.waitForExit()
      b.childAlive = false
      b.raiseCancelled()
  b.childAlive = false
  OpResult(status: osCompleted, detail: "built")

method runTest(b: SlowBackend; ws: Workspace; op: Operation): OpResult =
  inc b.tests
  OpResult(status: osCompleted)

method activeGeneration(b: SlowBackend): string = b.active

method generation(b: SlowBackend; ws: Workspace; op: Operation): OpResult =
  # Preparing (checking the staged closure, say) can be abandoned...
  for _ in 0 ..< 5:
    inc b.prepared
    if b.checkpoint(1):
      b.raiseCancelled()
  # ...the switch cannot.
  b.commit()
  b.active = op.target
  for _ in 0 ..< 5:
    inc b.healthChecked
    discard b.checkpoint(1)
  OpResult(status: osCompleted, detail: "generation=" & op.target)

proc g(s: string): Grant = parseGrant(s)
proc op(kind: OperationKind; target: string): Operation =
  Operation(kind: kind, target: target)

proc processExists(pid: int): bool =
  pid > 0 and posix.kill(Pid(pid), 0) == 0

const Grants = ["workspace.create:hello", "build.run:hello", "test.run:hello"]

type Fixture = object
  b: SlowBackend
  h: Host
  consent, agent: Connection
  sid: string
  intent: Intent
  ws: string

proc newFixture(name: string): Fixture =
  let root = getTempDir() / "t_cancel_" & name & "_" & $getCurrentProcessId()
  removeDir(root)
  result.b = SlowBackend(active: "gen-1")
  result.h = newHost(result.b, root / "ws")
  result.consent = newConnection(chConsent)
  discard result.h.hello(result.consent, ProtocolVersion,
                         {low(Family) .. high(Family)})
  let (sid, secret) = result.h.createSession(result.consent, "agent-harbor",
                                             Grants.toSeq.map(g))
  result.sid = sid
  result.agent = newConnection(chProvider)
  discard result.h.hello(result.agent, ProtocolVersion,
                         {low(Family) .. high(Family)})
  result.h.attach(result.agent, sid, secret)
  result.intent = result.h.captureIntent(result.consent, sid, "change hello")
  result.ws = result.h.execute(result.agent, result.h.submitPlan(result.agent,
    Plan(sessionId: sid, intentId: intentId(result.intent),
         baseGeneration: "gen-1", operations: @[op(okCheckoutCreate, "hello")],
         declaredCapabilities: @[g("workspace.create:hello")])).planId.hex).
    results[0].detail

proc submit(f: Fixture; ops: seq[Operation]; caps: seq[string]): string =
  f.h.submitPlan(f.agent, Plan(sessionId: f.sid, intentId: intentId(f.intent),
    baseGeneration: f.b.active, operations: ops,
    declaredCapabilities: caps.map(g))).planId.hex

proc buildThenTest(f: Fixture): string =
  f.submit(@[op(okBuildRun, f.ws), op(okTestRun, f.ws)],
           @["build.run:hello", "test.run:hello"])

proc onceRunning(f: Fixture; action: proc ()) =
  ## Install a pump that performs `action` once the build's child runs,
  ## standing in for a cancellation arriving over a socket.
  var done = false
  f.h.pump = proc (waitMs: int) {.gcsafe.} =
    {.cast(gcsafe).}:
      if not done and f.b.childAlive:
        done = true
        action()
      sleep(waitMs)

proc auditKinds(f: Fixture): seq[string] =
  f.h.audit.records.filterIt(it.sessionId == f.sid).
    mapIt(it.kind & "/" & it.decision)

# Socket paths are bounded (104 bytes on macOS), so keep the directory short.
let sockRoot = "/tmp/rac-" & $getCurrentProcessId()

proc call(c: HostClient; entries: openArray[CborPair]): CborItem =
  let resp = waitFor c.request(encodeDeterministic(cMap(entries)))
  if resp.len == 0: nil else: decodeItem(resp)

proc hello(c: HostClient) =
  doAssert c.call([tp("kind", cText("hello")), tp("protocol", cUInt(1)),
    tp("families", cArray([cText("checkout.v1"), cText("build.v1"),
                           cText("test.v1")]))]).field("outcome").text == "ok"

proc socketFixture(name: string): tuple[f: Fixture; server: HostServer;
                                        consent, agent: HostClient;
                                        planHex: string] =
  ## A host on real sockets with a provider attached over provider.sock,
  ## a workspace, and a submitted build-then-test plan.
  var f = Fixture(b: SlowBackend(active: "gen-1"))
  removeDir(sockRoot / name)
  f.h = newHost(f.b, sockRoot / name / "ws")
  result.server = startServer(f.h, sockRoot / name / "run")
  result.consent = waitFor connectHost(consentSocketPath(sockRoot / name / "run"))
  result.agent = waitFor connectHost(providerSocketPath(sockRoot / name / "run"))
  result.consent.hello()
  result.agent.hello()
  var grants: seq[CborItem]
  for s in Grants: grants.add cText(s)
  let created = result.consent.call([tp("kind", cText("session.create")),
    tp("provider", cText("agent-harbor")), tp("grants", cArray(grants))])
  f.sid = created.field("session").text
  doAssert result.agent.call([tp("kind", cText("session.attach")),
    tp("session", cText(f.sid)),
    tp("secret", cText(created.field("secret").text))]).
    field("outcome").text == "ok"
  let intent = result.consent.call([tp("kind", cText("intent.capture")),
    tp("session", cText(f.sid)), tp("text", cText("change hello"))])
  let iid = asDigest(intent.field("intent"), "intent")
  proc plan(ops: seq[Operation]; caps: seq[string]): CborItem =
    encodePlanItem(Plan(sessionId: f.sid, intentId: iid,
      baseGeneration: "gen-1", operations: ops,
      declaredCapabilities: caps.map(g)))
  let co = result.agent.call([tp("kind", cText("plan.submit")),
    tp("plan", plan(@[op(okCheckoutCreate, "hello")],
                    @["workspace.create:hello"]))])
  f.ws = result.agent.call([tp("kind", cText("plan.execute")),
    tp("plan", cText(asDigest(co.field("plan"), "plan").hex))]).
    field("results").elems[0].field("detail").text
  let bt = result.agent.call([tp("kind", cText("plan.submit")),
    tp("plan", plan(@[op(okBuildRun, f.ws), op(okTestRun, f.ws)],
                    @["build.run:hello", "test.run:hello"]))])
  result.planHex = asDigest(bt.field("plan"), "plan").hex
  result.f = f

proc request(kind, planHex: string; rid: uint64): seq[byte] =
  encodeDeterministic(cMap([tp("kind", cText(kind)),
    tp("plan", cText(planHex)), tp("requestId", cUInt(rid))]))

proc childStarted(b: SlowBackend) {.async.} =
  while not b.childAlive:
    await sleepAsync(5)

suite "M0 — cancellation of running operations":
  # In the socket cases the user and the provider act from inside the
  # dispatcher (async procs), because while the host executes, the test's
  # own frame is below the execution on the stack.

  test "the user cancels a running build over consent.sock":
    let (f, server, consent, agent, planHex) = socketFixture("user")
    defer: server.stop()
    let b = f.b
    var child = 0
    var wasAlive, wasExecuting = false
    var answer: CborItem
    proc user() {.async.} =
      await b.childStarted()
      child = b.childPid
      wasAlive = processExists(child)
      wasExecuting = f.h.executingPlan == planHex
      # The user presses cancel while the host waits on the build's child.
      answer = decodeItem(await consent.request(
        request("plan.cancel", planHex, 9)))
    let pressed = user()
    waitFor agent.send(request("plan.execute", planHex, 7))
    let ran = decodeItem(waitFor agent.receive())
    waitFor pressed
    check wasAlive and wasExecuting
    check answer.field("outcome").text == "ok"
    check answer.field("state").text == "cancelling"
    check asUInt(answer.field("requestId"), "id") == 9
    check asUInt(ran.field("requestId"), "id") == 7
    let rs = ran.field("results").elems
    check rs[0].field("status").text == "failed"
    check rs[0].field("detail").text == "cancelled: by the user"
    check rs[1].field("status").text == "not-run"
    check f.b.tests == 0
    check not processExists(child)
    check f.h.executingPlan == ""
    # Recorded before the build's result: audited before its effect.
    let kinds = f.auditKinds
    check kinds.find("cancel/cancel") in 0 ..< kinds.find("build.run/result")
    # The plan is gone, and the session is still usable.
    check consent.call([tp("kind", cText("plan.cancel")),
      tp("plan", cText(planHex))]).field("reason").text == "plan-unknown"
    check f.h.sessionState(f.sid) == ssActive

  test "the provider cancels its own plan on the same connection":
    let (f, server, consent, agent, planHex) = socketFixture("own")
    defer: server.stop()
    let b = f.b
    proc provider() {.async.} =
      await b.childStarted()
      await agent.send(request("plan.cancel", planHex, 2))
    let cancelling = provider()
    waitFor agent.send(request("plan.execute", planHex, 1))
    # The cancellation is answered first, then the execution it stopped.
    let first = decodeItem(waitFor agent.receive())
    let second = decodeItem(waitFor agent.receive())
    waitFor cancelling
    check asUInt(first.field("requestId"), "id") == 2
    check first.field("state").text == "cancelling"
    check asUInt(second.field("requestId"), "id") == 1
    check second.field("results").elems[0].field("detail").text ==
      "cancelled: by the provider"
    check not processExists(f.b.childPid)
    check f.h.audit.verify()
    consent.close()

  test "a provider that disconnects mid-build has the build cancelled":
    let f = newFixture("disconnect")
    f.onceRunning(proc () = f.h.disconnect(f.agent))
    let rep = f.h.execute(f.agent, f.buildThenTest())
    check rep.results.mapIt(it.status) == @[osFailed, osNotRun]
    check rep.results[0].detail ==
      "cancelled: by the provider's disconnection"
    check not processExists(f.b.childPid)
    check f.h.sessionState(f.sid) == ssSuspended
    check f.auditKinds.find("disconnect/suspend") <
          f.auditKinds.find("cancel/cancel")

  test "revoking a grant the running build uses cancels it; others do not":
    let f = newFixture("revoke")
    f.onceRunning(proc () =
      f.h.revokeGrant(f.consent, f.sid, g("test.run:hello"))
      check f.h.cancellable(f.sid)   # test.run is not running yet
      f.h.revokeGrant(f.consent, f.sid, g("build.run:hello")))
    let rep = f.h.execute(f.agent, f.buildThenTest())
    check rep.results[0].detail == "cancelled: by revocation of build.run:hello"
    check rep.results[1].status == osNotRun
    check f.auditKinds.count("cancel/cancel") == 1

  test "revoking the session cancels its running build":
    let f = newFixture("revoke-session")
    f.onceRunning(proc () = f.h.revokeSession(f.consent, f.sid))
    let rep = f.h.execute(f.agent, f.buildThenTest())
    check rep.results[0].detail == "cancelled: by revocation of the session"
    check not processExists(f.b.childPid)

  proc stagedActivation(f: Fixture): string =
    let hex = f.submit(@[op(okGenerationActivate, "gen-2")],
                       @["system.generation:activate"])
    discard f.h.approvePlan(f.consent, hex)
    hex

  proc approvalOf(f: Fixture; planHex: string): string =
    for r in f.h.audit.records:
      if r.kind == "approve" and r.planId == planHex:
        result = r.approvalId

  test "an activation cancelled before its commit point changes nothing":
    let f = newFixture("before-commit")
    let hex = f.stagedActivation()
    var asked = false
    f.h.pump = proc (waitMs: int) {.gcsafe.} =
      {.cast(gcsafe).}:
        if not asked and f.b.prepared == 2:
          asked = true
          check f.h.cancel(f.consent, hex) == "cancelling"
    let rep = f.h.execute(f.agent, hex, f.approvalOf(hex))
    check rep.results[0].status == osFailed
    check rep.results[0].detail == "cancelled: by the user"
    check f.b.active == "gen-1"
    check f.b.healthChecked == 0

  test "after the commit point a cancellation is too late":
    let f = newFixture("after-commit")
    let hex = f.stagedActivation()
    var answer = ""
    f.h.pump = proc (waitMs: int) {.gcsafe.} =
      {.cast(gcsafe).}:
        if answer.len == 0 and f.b.healthChecked == 1:
          try: discard f.h.cancel(f.consent, hex)
          except AgentRefusal as e: answer = $e.reason
          # Revocation cannot stop it either.
          f.h.revokeGrant(f.consent, f.sid, g("build.run:hello"))
    let rep = f.h.execute(f.agent, hex, f.approvalOf(hex))
    check answer == "too-late"
    check rep.results[0].status == osCompleted
    check f.b.active == "gen-2"
    check f.b.healthChecked == 5
    check f.h.audit.records.anyIt(it.kind == "cancel" and
      it.decision == "refused" and it.reason == "too-late")

  test "a plan that has not started is withdrawn":
    let f = newFixture("withdraw")
    let hex = f.stagedActivation()
    let approval = f.approvalOf(hex)
    check f.h.cancel(f.agent, hex) == "withdrawn"
    expect AgentRefusal:
      discard f.h.execute(f.agent, hex, approval)
    check f.b.active == "gen-1"

  test "one execution at a time, and only one's own plans":
    let f = newFixture("busy")
    # A second session on the same host, with a plan of its own.
    let (sid2, secret2) = f.h.createSession(f.consent, "agent-harbor",
                                            @[g("workspace.create:other")])
    let agent2 = newConnection(chProvider)
    discard f.h.hello(agent2, ProtocolVersion, {low(Family) .. high(Family)})
    f.h.attach(agent2, sid2, secret2)
    let intent2 = f.h.captureIntent(f.consent, sid2, "other")
    let otherPlan = f.h.submitPlan(agent2, Plan(sessionId: sid2,
      intentId: intentId(intent2), baseGeneration: "gen-1",
      operations: @[op(okCheckoutCreate, "other")],
      declaredCapabilities: @[g("workspace.create:other")])).planId.hex
    var busy, foreign = ""
    let hex = f.buildThenTest()
    f.onceRunning(proc () =
      # Another execution, of either session, waits its turn...
      try: discard f.h.execute(agent2, otherPlan)
      except AgentRefusal as e: busy = $e.reason
      # ...and a provider cannot cancel a plan that is not its own.
      try: discard f.h.cancel(f.agent, otherPlan)
      except AgentRefusal as e: foreign = $e.reason
      discard f.h.cancel(f.consent, hex))
    discard f.h.execute(f.agent, hex)
    check busy == "busy"
    check foreign == "plan-unknown"
    # The other session's plan is intact and runs now.
    check f.h.execute(agent2, otherPlan).results[0].status == osCompleted
    check f.h.audit.verify()

removeDir(sockRoot)
