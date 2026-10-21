## ReproOS-Agent-Harbor-Integration M0 verification
## ``test_agent_harbor_reproos_permission_protocol``.
##
## "Allowed sessions perform only declared operations and confused-deputy,
## stale approval, path escape, and privilege-escalation fixtures fail."
##
## The host, its capability checks, approvals, path resolution and audit
## log are the real code, run against a real temporary filesystem: source
## reads and writes, and the symlink escapes, hit real files. The one
## stand-in is `FixtureBackend`, which records the build, generation and
## Remix operations the host delegates instead of running Reprobuild. That
## is justified here because M0's gate is about which operations the host
## lets through, not about what they do; the real backends are M3-M5's
## work and have their own gates. The backend's log is exactly what lets
## this test assert that nothing undeclared reached it.

import std/[algorithm, os, sequtils, strutils, tables, unittest]

import cbor
import repro_agent_protocol

type
  FixtureBackend = ref object of Backend
    calls: seq[string]
    active: string

method createCheckout(b: FixtureBackend; package, root: string): OpResult =
  b.calls.add "checkout " & package
  createDir(root / "src")
  writeFile(root / "src" / "main.c", "int main(void) { return 0; }\n")
  OpResult(status: osCompleted)

method resolveOwnership(b: FixtureBackend; target: string): OpResult =
  b.calls.add "ownership " & target
  OpResult(status: osCompleted, detail: "hello")

method runBuild(b: FixtureBackend; ws: Workspace; op: Operation): OpResult =
  b.calls.add "build " & ws.package
  OpResult(status: osCompleted)

method runTest(b: FixtureBackend; ws: Workspace; op: Operation): OpResult =
  b.calls.add "test " & ws.package
  OpResult(status: osCompleted)

method activeGeneration(b: FixtureBackend): string = b.active

method generation(b: FixtureBackend; ws: Workspace; op: Operation): OpResult =
  b.calls.add $op.kind & " " & op.target
  OpResult(status: osCompleted, detail: "gen-next")

var now = 1_800_000_000'i64
proc testClock(): int64 {.gcsafe, raises: [].} =
  {.cast(gcsafe).}: now

let scratch = getTempDir() / "t_agent_permission_protocol_" & $getCurrentProcessId()
removeDir(scratch)
createDir(scratch)
let outside = scratch / "outside"
createDir(outside)
writeFile(outside / "secret.txt", "outside the workspace\n")

proc reasonOf(body: proc ()): AgentRefusalReason =
  ## The refusal `body` raises; fails the test if it raises none.
  try:
    body()
  except AgentRefusal as e:
    return e.reason
  checkpoint "expected a refusal"
  fail()

template refuses(reason: AgentRefusalReason; body: untyped) =
  check reasonOf(proc () = body) == reason

proc op(kind: OperationKind; target: string;
        args: openArray[(string, string)] = []): Operation =
  result = Operation(kind: kind, target: target)
  for (n, v) in args:
    result.args.add OpArg(name: n, value: v)
  result.args = result.args.sortedByIt(it.name)

proc g(s: string): Grant = parseGrant(s)

const AllFamilies = {low(Family) .. high(Family)}

type Fixture = object
  host: Host
  backend: FixtureBackend
  consent: Connection

proc newFixture(name: string): Fixture =
  result.backend = FixtureBackend(active: "gen-1")
  result.host = newHost(result.backend, scratch / name / "workspaces",
                        auditPath = scratch / name / "audit.log",
                        clock = testClock)
  result.consent = newConnection(chConsent)
  discard result.host.hello(result.consent, ProtocolVersion, AllFamilies)

proc session(f: Fixture; grants: seq[string]): tuple[id, secret: string;
                                                      conn: Connection] =
  let (sid, secret) = f.host.createSession(f.consent, "agent-harbor",
                                           grants.map(g))
  let conn = newConnection(chProvider)
  discard f.host.hello(conn, ProtocolVersion, AllFamilies)
  f.host.attach(conn, sid, secret)
  (sid, secret, conn)

proc planFor(f: Fixture; sid: string; intent: Intent;
             ops: seq[Operation]; declared: seq[string]): Plan =
  Plan(sessionId: sid, intentId: intentId(intent),
       baseGeneration: f.backend.active, operations: ops,
       declaredCapabilities: declared.map(g))

const EditGrants = @["context.package:hello", "workspace.create:hello",
                     "source.read:hello", "source.write:hello",
                     "build.run:hello"]

proc checkout(f: Fixture; sid: string; conn: Connection;
              intent: Intent): string =
  let p = f.planFor(sid, intent, @[op(okCheckoutCreate, "hello")],
                    @["workspace.create:hello"])
  let r = f.host.submitPlan(conn, p)
  check r.approvalRequired.len == 0
  let rep = f.host.execute(conn, r.planId.hex)
  check rep.results[0].status == osCompleted
  rep.results[0].detail

suite "M0 — an allowed session performs exactly its declared operations":
  test "checkout, edit, read back and build run without an approval":
    let f = newFixture("allowed")
    let (sid, _, conn) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid,
                                      "make hello print a greeting")
    let ws = f.checkout(sid, conn, intent)
    let content = "#include <stdio.h>\nint main(void) { puts(\"hi\"); }\n"
    let p = f.planFor(sid, intent, @[
      op(okSourceWrite, ws, {"path": "src/main.c", "content": content}),
      op(okSourceRead, ws, {"path": "src/main.c"}),
      op(okBuildRun, ws)],
      @["source.read:hello", "source.write:hello", "build.run:hello"])
    let r = f.host.submitPlan(conn, p)
    check r.approvalRequired.len == 0
    let rep = f.host.execute(conn, r.planId.hex)
    check rep.results.mapIt(it.status) == @[osCompleted, osCompleted,
                                            osCompleted]
    check rep.results[1].output == content
    check readFile(f.host.workspaces[ws].root / "src" / "main.c") == content
    # Nothing the plan did not declare reached the backend.
    check f.backend.calls == @["checkout hello", "build hello"]

  test "a generation stage runs only with the user's approval, once":
    let f = newFixture("approved")
    let (sid, _, conn) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid, "ship it")
    let ws = f.checkout(sid, conn, intent)
    let p = f.planFor(sid, intent, @[op(okGenerationStage, ws)],
                      @["system.generation:stage"])
    let r = f.host.submitPlan(conn, p)
    check r.approvalRequired == @[0]
    refuses(arApprovalRequired): discard f.host.execute(conn, r.planId.hex)
    check f.backend.calls == @["checkout hello"]
    # The consent surface shows the exact plan the host holds.
    check planId(f.host.showPlan(f.consent, r.planId.hex)) == r.planId
    let a = f.host.approvePlan(f.consent, r.planId.hex)
    let rep = f.host.execute(conn, r.planId.hex, a)
    check rep.results[0].status == osCompleted
    check f.backend.calls[^1] == "generation.stage " & ws

  test "the plan identity is a function of content, not of set order":
    let f = newFixture("identity")
    let (sid, _, _) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid, "x")
    let ops = @[op(okBuildRun, "w"), op(okTestRun, "w")]
    let a = f.planFor(sid, intent, ops, @["build.run:hello", "test.run:hello"])
    var b = a
    b.declaredCapabilities = @[g("test.run:hello"), g("build.run:hello")]
    check planId(a) == planId(b)
    check decodePlan(encodePlan(a)) == decodePlanItem(encodePlanItem(a))
    check planId(decodePlan(encodePlan(a))) == planId(a)
    var c = a
    c.operations = @[ops[1], ops[0]]
    check planId(c) != planId(a)

suite "M0 — confused deputy":
  test "consent operations are refused on the provider channel":
    let f = newFixture("deputy-channel")
    let (sid, _, conn) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid, "x")
    let ws = f.checkout(sid, conn, intent)
    let r = f.host.submitPlan(conn, f.planFor(sid, intent,
      @[op(okGenerationStage, ws)], @["system.generation:stage"]))
    refuses(arWrongChannel): discard f.host.approvePlan(conn, r.planId.hex)
    refuses(arWrongChannel):
      discard f.host.createSession(conn, "agent-harbor", @[g("source.read:x")])
    refuses(arWrongChannel): discard f.host.captureIntent(conn, sid, "forged")
    refuses(arWrongChannel): f.host.revokeGrant(conn, sid, g("build.run:hello"))
    refuses(arWrongChannel): discard f.host.showPlan(conn, r.planId.hex)
    # The same refusal over the wire, so the codec cannot route around it.
    let resp = decodeItem(f.host.handleMessage(conn, encodeDeterministic(cMap([
      tp("kind", cText("plan.approve")), tp("plan", cText(r.planId.hex))]))))
    check resp.field("outcome").text == "refused"
    check resp.field("reason").text == "wrong-channel"
    # And the consent channel cannot act as a provider.
    refuses(arWrongChannel): discard f.host.submitPlan(f.consent,
      f.planFor(sid, intent, @[op(okBuildRun, ws)], @["build.run:hello"]))

  test "intents, approvals, plans and workspaces of another session refuse":
    let f = newFixture("deputy-sessions")
    let (sa, _, ca) = f.session(EditGrants)
    let (sb, secretB, cb) = f.session(EditGrants)
    let ia = f.host.captureIntent(f.consent, sa, "a")
    let ib = f.host.captureIntent(f.consent, sb, "b")
    let wa = f.checkout(sa, ca, ia)
    let wb = f.checkout(sb, cb, ib)
    # A's plan quoting B's intent.
    refuses(arIntentNotInSession): discard f.host.submitPlan(ca,
      Plan(sessionId: sa, intentId: intentId(ib), baseGeneration: "gen-1",
           operations: @[op(okBuildRun, wa)],
           declaredCapabilities: @[g("build.run:hello")]))
    # A plan claiming to be B's, sent on A's connection.
    refuses(arIntentNotInSession): discard f.host.submitPlan(ca,
      f.planFor(sb, ib, @[op(okBuildRun, wb)], @["build.run:hello"]))
    # A writing into B's workspace, with every grant it would need.
    refuses(arImmutableTarget): discard f.host.submitPlan(ca,
      f.planFor(sa, ia, @[op(okSourceWrite, wb,
        {"path": "src/main.c", "content": "pwned"})], @["source.write:hello"]))
    check readFile(f.host.workspaces[wb].root / "src/main.c").startsWith("int")
    # B's approval used for A's plan, and for another plan of B.
    let pa = f.host.submitPlan(ca, f.planFor(sa, ia,
      @[op(okGenerationStage, wa)], @["system.generation:stage"]))
    let pb = f.host.submitPlan(cb, f.planFor(sb, ib,
      @[op(okGenerationStage, wb)], @["system.generation:stage"]))
    let ab = f.host.approvePlan(f.consent, pb.planId.hex)
    refuses(arApprovalWrongSession): discard f.host.execute(ca, pa.planId.hex, ab)
    let pb2 = f.host.submitPlan(cb, f.planFor(sb, ib,
      @[op(okGenerationStage, wb), op(okBuildRun, wb)],
      @["system.generation:stage", "build.run:hello"]))
    refuses(arApprovalPlanMismatch): discard f.host.execute(cb, pb2.planId.hex, ab)
    refuses(arApprovalUnknown):
      discard f.host.execute(cb, pb.planId.hex, "a-forged-by-the-provider")
    # Attaching to B's session needs B's secret.
    let thief = newConnection(chProvider)
    discard f.host.hello(thief, ProtocolVersion, AllFamilies)
    refuses(arSessionSecretMismatch): f.host.attach(thief, sb, "0".repeat(64))
    let rightful = newConnection(chProvider)
    discard f.host.hello(rightful, ProtocolVersion, AllFamilies)
    f.host.attach(rightful, sb, secretB)
    check f.backend.calls.countIt(it.startsWith("generation")) == 0

suite "M0 — stale approvals":
  proc staged(name: string): tuple[f: Fixture; sid, secret: string;
                                   conn: Connection; intent: Intent;
                                   ws: string; receipt: PlanReceipt;
                                   approval: string] =
    let f = newFixture(name)
    let (sid, secret, conn) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid, "stage it")
    let ws = f.checkout(sid, conn, intent)
    let r = f.host.submitPlan(conn, f.planFor(sid, intent,
      @[op(okGenerationStage, ws)], @["system.generation:stage"]))
    (f, sid, secret, conn, intent, ws, r,
     f.host.approvePlan(f.consent, r.planId.hex))

  test "a plan changed after approval does not run under it":
    let s = staged("stale-changed")
    var changed = s.f.planFor(s.sid, s.intent, @[op(okGenerationStage, s.ws)],
                              @["system.generation:stage"])
    changed.evidence = @[id("x", "a different diff".toBytes)]
    let r2 = s.f.host.submitPlan(s.conn, changed)
    check r2.planId != s.receipt.planId
    refuses(arApprovalPlanMismatch):
      discard s.f.host.execute(s.conn, r2.planId.hex, s.approval)

  test "an approval executes once":
    let s = staged("stale-consumed")
    discard s.f.host.execute(s.conn, s.receipt.planId.hex, s.approval)
    let again = s.f.host.submitPlan(s.conn, s.f.planFor(s.sid, s.intent,
      @[op(okGenerationStage, s.ws)], @["system.generation:stage"]))
    check again.planId == s.receipt.planId
    refuses(arApprovalConsumed):
      discard s.f.host.execute(s.conn, again.planId.hex, s.approval)
    check s.f.backend.calls.countIt(it.startsWith("generation")) == 1

  test "an approval expires":
    let s = staged("stale-expired")
    now += DefaultApprovalLifetimeSeconds
    refuses(arApprovalExpired):
      discard s.f.host.execute(s.conn, s.receipt.planId.hex, s.approval)
    check s.f.backend.calls.countIt(it.startsWith("generation")) == 0

  test "a revocation in between voids the approval":
    let s = staged("stale-epoch")
    s.f.host.revokeGrant(s.f.consent, s.sid, g("context.package:hello"))
    refuses(arApprovalStaleEpoch):
      discard s.f.host.execute(s.conn, s.receipt.planId.hex, s.approval)
    check s.f.backend.calls.countIt(it.startsWith("generation")) == 0

  test "a provider disconnect voids the approval":
    let s = staged("stale-disconnect")
    s.f.host.disconnect(s.conn)
    check s.f.host.sessionState(s.sid) == ssSuspended
    refuses(arNotAttached):
      discard s.f.host.execute(s.conn, s.receipt.planId.hex, s.approval)
    # Re-attaching resumes the session but not its old approvals.
    let back = newConnection(chProvider)
    discard s.f.host.hello(back, ProtocolVersion, AllFamilies)
    s.f.host.attach(back, s.sid, s.secret)
    check s.f.host.sessionState(s.sid) == ssActive
    refuses(arApprovalStaleEpoch):
      discard s.f.host.execute(back, s.receipt.planId.hex, s.approval)

  test "a generation change in between makes the plan stale":
    let s = staged("stale-base")
    s.f.backend.active = "gen-2"
    refuses(arApprovalStaleBase):
      discard s.f.host.execute(s.conn, s.receipt.planId.hex, s.approval)
    check s.f.backend.calls.countIt(it.startsWith("generation")) == 0

suite "M0 — path escape":
  test "non-canonical paths are refused at submission":
    let f = newFixture("paths")
    let (sid, _, conn) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid, "x")
    let ws = f.checkout(sid, conn, intent)
    let bads = ["../outside/secret.txt", "/etc/passwd", "src/../../x",
                "./src/main.c", "src//main.c", "src/", "", "src\\main.c",
                "src/main.c\0.txt", "src/.", "a/" & "b".repeat(256)]
    for bad in bads:
      checkpoint "path " & bad.escape
      refuses(arPathEscape): discard f.host.submitPlan(conn, f.planFor(sid,
        intent, @[op(okSourceRead, ws, {"path": bad})], @["source.read:hello"]))
    check f.host.audit.records.countIt(it.reason == "path-escape") == bads.len
    check f.backend.calls == @["checkout hello"]

  test "a symlink inside the workspace that leads outside is not followed":
    let f = newFixture("symlinks")
    let (sid, _, conn) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid, "x")
    let ws = f.checkout(sid, conn, intent)
    let root = f.host.workspaces[ws].root
    createSymlink(outside / "secret.txt", root / "leak")
    createSymlink(outside, root / "src" / "out")
    createSymlink("main.c", root / "src" / "alias")
    for path in ["leak", "src/out/secret.txt"]:
      checkpoint path
      let r = f.host.submitPlan(conn, f.planFor(sid, intent,
        @[op(okSourceRead, ws, {"path": path})], @["source.read:hello"]))
      let rep = f.host.execute(conn, r.planId.hex)
      check rep.results[0].status == osFailed
      check rep.results[0].detail.startsWith("path-escape")
      check rep.results[0].output.len == 0
    for path in ["leak", "src/out/secret.txt", "src/alias"]:
      checkpoint "write " & path
      let r = f.host.submitPlan(conn, f.planFor(sid, intent,
        @[op(okSourceWrite, ws, {"path": path, "content": "overwritten"})],
        @["source.write:hello"]))
      let rep = f.host.execute(conn, r.planId.hex)
      check rep.results[0].status == osFailed
      check rep.results[0].detail.startsWith("path-escape")
    check readFile(outside / "secret.txt") == "outside the workspace\n"
    # A symlink that stays inside the workspace is an ordinary read.
    let r = f.host.submitPlan(conn, f.planFor(sid, intent,
      @[op(okSourceRead, ws, {"path": "src/alias"})], @["source.read:hello"]))
    check f.host.execute(conn, r.planId.hex).results[0].output.startsWith("int")

suite "M0 — privilege escalation":
  test "operations need grants that are held, declared and approved":
    let f = newFixture("escalation")
    let (sid, _, conn) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid, "x")
    let ws = f.checkout(sid, conn, intent)
    # test.run is not held.
    refuses(arCapabilityNotHeld): discard f.host.submitPlan(conn,
      f.planFor(sid, intent, @[op(okTestRun, ws)], @["test.run:hello"]))
    # build.run is held but not declared.
    refuses(arCapabilityNotDeclared): discard f.host.submitPlan(conn,
      f.planFor(sid, intent, @[op(okBuildRun, ws)], @[]))
    # A widened scope: a grant for another package is not held.
    refuses(arCapabilityNotHeld): discard f.host.submitPlan(conn,
      f.planFor(sid, intent, @[op(okBuildRun, ws)],
                @["build.run:hello", "source.write:other"]))
    # Network beyond the sandbox is approval-only.
    let r = f.host.submitPlan(conn, f.planFor(sid, intent,
      @[op(okBuildRun, ws, {"network": "crates-io"})],
      @["build.run:hello", "network.egress:crates-io"]))
    check r.approvalRequired == @[0]
    refuses(arApprovalRequired): discard f.host.execute(conn, r.planId.hex)
    # A revocation after submission is enforced at execution.
    let ok = f.host.submitPlan(conn, f.planFor(sid, intent,
      @[op(okBuildRun, ws)], @["build.run:hello"]))
    f.host.revokeGrant(f.consent, sid, g("build.run:hello"))
    refuses(arCapabilityNotHeld): discard f.host.execute(conn, ok.planId.hex)
    check f.backend.calls == @["checkout hello"]

  test "sessions cannot hold approval-only, unknown or ill-scoped grants":
    let f = newFixture("grants")
    for bad in ["system.generation:activate", "network.egress:any",
                "credentials.use:github", "remix.publish:marketplace"]:
      checkpoint bad
      refuses(arApprovalOnlyGrant):
        discard f.host.createSession(f.consent, "agent-harbor", @[g(bad)])
    refuses(arUnknownCapability): discard g("system.root")
    refuses(arUnknownCapability): discard g("filesystem.write:/etc")
    refuses(arBadScope): discard g("source.write:../hello")
    refuses(arBadScope): discard g("source.write:/nix/store")
    refuses(arBadScope): discard g("context.file:relative/path")
    refuses(arBadScope): discard g("context.selection:anything")
    refuses(arBadScope): discard g("system.generation:everything")
    # remix.publish:private is the one publication a session may hold.
    let (sid, _) = f.host.createSession(f.consent, "agent-harbor",
                                        @[g("remix.publish:private")])
    check f.host.sessionGrants(sid) == @[g("remix.publish:private")]

  test "context items in an intent must be held grants":
    let f = newFixture("context")
    let (sid, _, _) = f.session(@["context.selection"])
    refuses(arCapabilityNotHeld): discard f.host.captureIntent(f.consent, sid,
      "x", @[g("context.file:/home/user/.ssh/id_ed25519")])
    let ok = f.host.captureIntent(f.consent, sid, "x",
                                  @[g("context.selection")])
    check ok.contextItems == @[g("context.selection")]

  test "unknown protocol versions, families and request kinds refuse":
    let f = newFixture("versions")
    let c = newConnection(chProvider)
    let early = decodeItem(f.host.handleMessage(c, encodeDeterministic(cMap([
      tp("kind", cText("plan.execute")), tp("plan", cText("00"))]))))
    check early.field("reason").text == "malformed"
    refuses(arUnsupportedProtocol): discard f.host.hello(c, 2, AllFamilies)
    let (sid, secret) = f.host.createSession(f.consent, "alt", @[
      g("workspace.create:hello"), g("build.run:hello")])
    let narrow = newConnection(chProvider)
    let resp = decodeItem(f.host.handleMessage(narrow, encodeDeterministic(
      cMap([tp("kind", cText("hello")), tp("protocol", cUInt(1)),
            tp("families", cArray([cText("checkout.v1"), cText("build.v9"),
                                   cText("teleport.v1")]))]))))
    check resp.field("outcome").text == "ok"
    check resp.field("families").elems.mapIt(it.text) == @["checkout.v1"]
    f.host.attach(narrow, sid, secret)
    let intent = f.host.captureIntent(f.consent, sid, "x")
    refuses(arUnsupportedFamily): discard f.host.submitPlan(narrow,
      f.planFor(sid, intent, @[op(okBuildRun, "w")], @["build.run:hello"]))
    let unknown = decodeItem(f.host.handleMessage(narrow, encodeDeterministic(
      cMap([tp("kind", cText("system.exec"))]))))
    check unknown.field("reason").text == "unsupported-family"

suite "M0 — audit":
  test "every decision is chained, refusals included, and tampering shows":
    let f = newFixture("audit")
    let (sid, _, conn) = f.session(EditGrants)
    let intent = f.host.captureIntent(f.consent, sid, "x")
    let ws = f.checkout(sid, conn, intent)
    refuses(arCapabilityNotHeld): discard f.host.submitPlan(conn,
      f.planFor(sid, intent, @[op(okTestRun, ws)], @["test.run:hello"]))
    refuses(arWrongChannel): discard f.host.captureIntent(conn, sid, "forged")
    let log = f.host.audit
    check log.verify()
    check log.records.anyIt(it.decision == "refused" and
                            it.reason == "capability-not-held" and
                            it.sessionId == sid)
    check log.records.anyIt(it.decision == "refused" and
                            it.reason == "wrong-channel")
    check log.records.anyIt(it.decision == "grant" and
                            it.grant == "source.write:hello")
    # Execution is recorded before the operation's result.
    let allowed = log.records.mapIt(it.kind & "/" & it.decision)
    check allowed.find("checkout.create/allowed") <
          allowed.find("checkout.create/result")
    # The persisted log reloads to the same chain head.
    check newAuditLog(scratch / "audit" / "audit.log").head == log.head
    var tampered = log.records
    tampered[2].reason = "nothing to see"
    check verify(tampered) == 3
    var dropped = log.records
    dropped.delete(1)
    check verify(dropped) == 1
    # A corrupted file is refused rather than extended.
    let path = scratch / "audit" / "audit.log"
    var bytes = readFile(path)
    bytes[bytes.len div 2] = char(ord(bytes[bytes.len div 2]) xor 0x20)
    writeFile(scratch / "audit" / "corrupt.log", bytes)
    refuses(arAuditCorrupt):
      discard newAuditLog(scratch / "audit" / "corrupt.log")

removeDir(scratch)
