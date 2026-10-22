## The provider conformance harness (ReproOS-Agent-Harbor-Integration M7;
## spec `ReproOS-Agent-Integration-Protocol.md` §"Provider conformance").
##
## It runs a real host on its real sockets with a fixture backend, starts
## the provider under test as a SEPARATE PROCESS that knows only what the
## protocol hands a provider (the provider socket, a session id and secret,
## an intent), and judges the provider by what the host recorded: the audit
## log, the operations that reached the backend, the consent socket left
## alone, and the provider's exit status. Nothing about the provider's
## implementation is inspected, which is the point: an alternative agent
## passes or fails on the protocol alone (I-AGT-10).
##
## The fixture backend is a stand-in by design: conformance is about the
## provider's use of the protocol, and a real build would make the verdict
## depend on a toolchain. It performs checkout and records build, test,
## stage and Remix calls against a real temporary filesystem; its build of
## target `long` runs until it is cancelled (at most `LongBuildSeconds`),
## which is how the scenario exercises cancellation.

import std/[asyncdispatch, os, osproc, sequtils, sets, streams, strtabs,
            strutils, tables, times]

import repro_core/ambient_execution

import ./[types, capabilities, canonical, audit, host, transport]

const
  ScenarioV1* = "agent-v1"
  FixturePackage* = "fixture"
  FixtureReadme* = "# fixture\nThe conformance fixture package.\n"
  ConformanceTimeoutSeconds* = 120
  LongBuildSeconds* = 60
  FixtureRelease* = "fixture-release-1"

type
  ConformanceBackend = ref object of Backend
    calls*: seq[string]

  ConformanceReport* = object
    passed*: bool
    failures*: seq[string]
    providerExit*: int
    providerOutput*: string
    backendCalls*: seq[string]

method createCheckout(b: ConformanceBackend; package, root: string): OpResult =
  b.calls.add "checkout " & package
  createDir(root / "src")
  writeFile(root / "README.md", FixtureReadme)
  writeFile(root / "src" / "main.c", "int main(void) { return 0; }\n")
  OpResult(status: osCompleted)

method runBuild(b: ConformanceBackend; ws: Workspace; op: Operation): OpResult =
  if op.arg("target") == "long":
    b.calls.add "build-long " & ws.package
    let deadline = epochTime() + LongBuildSeconds
    while epochTime() < deadline:
      if b.checkpoint():
        b.calls[^1].add " cancelled"
        b.raiseCancelled()
    b.calls[^1].add " timed-out"
    return OpResult(status: osFailed, detail: "the long build was not cancelled")
  b.calls.add "build " & ws.package
  OpResult(status: osCompleted, detail: "built")

method runTest(b: ConformanceBackend; ws: Workspace; op: Operation): OpResult =
  b.calls.add "test " & ws.package
  OpResult(status: osCompleted, detail: "tests passed")

method activeGeneration(b: ConformanceBackend): string = "gen-1"

method generation(b: ConformanceBackend; ws: Workspace; op: Operation): OpResult =
  b.calls.add $op.kind & " " & ws.package
  OpResult(status: osCompleted, detail: "release=" & FixtureRelease)

method remix(b: ConformanceBackend; ws: Workspace; op: Operation): OpResult =
  b.calls.add $op.kind & " " & ws.package & " " & op.arg("release")
  OpResult(status: osCompleted, detail: $op.kind & "=" & op.arg("release"))

const ScenarioGrants = ["workspace.create:fixture", "source.read:fixture",
  "source.write:fixture", "build.run:fixture", "test.run:fixture",
  "remix.publish:private"]

proc scenarioContent*(nonce: string): string =
  ## The file content the scenario asks the provider to write: unique per
  ## run, so a provider cannot pass by replaying an old run.
  "/* conformance " & nonce & " */\nint main(void) { return 0; }\n"

proc runConformance*(providerCmd: seq[string]; workRoot: string;
                     extraEnv: seq[(string, string)] = @[];
                     timeoutSeconds = ConformanceTimeoutSeconds):
    ConformanceReport =
  ## Run scenario `agent-v1` against the provider started by
  ## `providerCmd` (argv; no shell). `workRoot` must be empty or absent and
  ## short enough for Unix socket paths.
  let backend = ConformanceBackend()
  let h = newHost(backend, workRoot / "workspaces",
                  auditPath = workRoot / "audit.log")
  var consentAttempts = 0
  let server = startServer(h, workRoot / "run",
    consentPeer = proc (pid: int): bool {.gcsafe.} =
      # The harness drives consent in process; ANY socket peer on the
      # consent socket is a provider reaching for consent.
      {.cast(gcsafe).}: inc consentAttempts
      false)
  defer: server.stop()
  let consent = newConnection(chConsent)
  discard h.hello(consent, ProtocolVersion, {low(Family) .. high(Family)})
  # This host exists to examine the provider under test, so it admits the
  # scenario's provider identity itself; production admission is
  # `admitAfterConformance`.
  h.admitProvider(consent, "conformance", default(Digest32))
  var grants: seq[Grant]
  for g in ScenarioGrants:
    grants.add parseGrant(g)
  let (sid, secret) = h.createSession(consent, "conformance", grants)
  let nonce = id("reproos.agent.conformance-nonce.v1",
                 ($epochTime()).toBytes).hex[0 ..< 16]
  let intent = h.captureIntent(consent, sid,
    "conformance scenario " & ScenarioV1)
  let approvalFile = workRoot / "approval"
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  for (k, v) in extraEnv:
    env[k] = v
  env["REPROOS_AGENT_SOCKET"] = providerSocketPath(workRoot / "run")
  env["REPROOS_AGENT_SESSION"] = sid
  env["REPROOS_AGENT_SECRET"] = secret
  env["REPROOS_AGENT_INTENT"] = intentId(intent).hex
  env["REPROOS_AGENT_BASE_GENERATION"] = backend.activeGeneration()
  env["REPROOS_CONFORMANCE_SCENARIO"] = ScenarioV1
  env["REPROOS_CONFORMANCE_CONTENT"] = scenarioContent(nonce)
  env["REPROOS_CONFORMANCE_APPROVAL_FILE"] = approvalFile
  # The provider under test is, by definition, a binary this harness does
  # not control.
  let p = uncontrolledStartProcess(providerCmd[0], args = providerCmd[1 .. ^1],
                                   env = env, options = {poStdErrToStdOut})
  defer: p.close()
  var approved = initHashSet[string]()
  let deadline = epochTime() + float(timeoutSeconds)
  var output = ""
  while p.running and epochTime() < deadline:
    poll(20)
    # Approve the stage plan once the provider has submitted it, the way a
    # user at the consent surface would, and hand the approval id over.
    var waiting: seq[string]
    for pid, plan in h.pendingPlansNeedingApproval(sid):
      if pid notin approved:
        waiting.add pid
    for pid in waiting:
      approved.incl pid
      writeFile(approvalFile & ".tmp", h.approvePlan(consent, pid))
      moveFile(approvalFile & ".tmp", approvalFile)
  if p.running:
    p.terminate()
    result.failures.add "the provider did not finish within " &
      $timeoutSeconds & "s"
  result.providerExit = p.waitForExit()
  result.providerOutput = p.outputStream.readAll()
  for _ in 0 ..< 50:
    poll(10) # let the host observe the disconnect
  result.backendCalls = backend.calls

  # --- The verdict, from what the host recorded. ---
  template fail(msg: string) = result.failures.add msg
  if result.providerExit != 0:
    fail "the provider exited " & $result.providerExit
  if consentAttempts > 0:
    fail "the provider connected to the consent socket " &
      $consentAttempts & " time(s)"
  if not h.audit.verify():
    fail "the audit chain does not verify"
  let recs = h.audit.records
  let mine = recs.filterIt(it.sessionId == sid)
  # The long build is either cancelled while it runs or withdrawn before
  # it starts (the provider cannot tell when the host starts it); either
  # way it must not run to its timeout.
  let longCalls = backend.calls.filterIt(it.startsWith("build-long "))
  if not mine.anyIt(it.kind == "attach" and it.decision == "allowed"):
    fail "the provider never attached to its session"
  # A withdrawn long build makes its execute refuse `plan-unknown`; that
  # refusal is the protocol working, not the provider misbehaving.
  let refusals = mine.filterIt(it.decision == "refused" and
    not (it.kind == "execute" and it.reason == "plan-unknown" and
         longCalls.len == 0))
  if refusals.mapIt(it.reason) != @["path-escape"]:
    fail "expected exactly one refusal (path-escape), got " &
      $refusals.mapIt(it.kind & ":" & it.reason)
  let otherCalls = backend.calls.filterIt(not it.startsWith("build-long "))
  let expectedCalls = @["checkout fixture", "build fixture", "test fixture",
    "generation.stage fixture",
    "remix.capture fixture " & FixtureRelease,
    "remix.export fixture " & FixtureRelease]
  if otherCalls != expectedCalls:
    fail "the backend saw " & $otherCalls & ", expected " & $expectedCalls
  if longCalls.len > 1 or
      (longCalls.len == 1 and longCalls[0] != "build-long fixture cancelled"):
    fail "the long build was not cancelled: " & $longCalls
  if not mine.anyIt(it.kind == "cancel" and it.decision == "cancel" and
                    it.reason == "the provider"):
    fail "the provider never cancelled its long build"
  let consumed = mine.filterIt(it.kind == "consume" and
                               it.decision == "consume")
  if consumed.len != 2:
    fail "expected the provider to execute 2 approved plans, saw " &
      $consumed.len
  if approved.len != 2:
    fail "expected two plans needing approval, saw " & $approved.len
  let reads = mine.filterIt(it.kind == "source.read" and
                            it.decision == "result" and it.reason == "completed")
  if reads.len != 1:
    fail "expected one completed source.read"
  # The provider must have written exactly the content asked for.
  var wrote = false
  for ws in h.workspaces.values:
    if ws.sessionId == sid and fileExists(ws.root / "src" / "main.c") and
        readFile(ws.root / "src" / "main.c") == scenarioContent(nonce):
      wrote = true
  if not wrote:
    fail "the workspace does not hold the content the scenario asked for"
  if "conformance-done" notin result.providerOutput:
    fail "the provider did not report completion"
  result.passed = result.failures.len == 0

proc reportDigest*(r: ConformanceReport): Digest32 =
  ## The identity of a verdict: scenario, pass/fail, failures, exit status
  ## and the backend calls, in order.
  var text = ScenarioV1 & "\n" & $r.passed & "\n" & $r.providerExit & "\n"
  for f in r.failures: text.add "failure " & f & "\n"
  for c in r.backendCalls: text.add "call " & c & "\n"
  id("reproos.agent.conformance-report.v1", text.toBytes)

proc admitAfterConformance*(h: Host; conn: Connection; provider: string;
                            report: ConformanceReport) =
  ## Admit `provider` on the strength of a PASSING report, and only then.
  if not report.passed:
    refuse(arProviderNotAdmitted, provider & " failed conformance: " &
      report.failures.join("; "))
  h.admitProvider(conn, provider, reportDigest(report))
