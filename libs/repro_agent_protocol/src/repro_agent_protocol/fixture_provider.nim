## A minimal provider of the agent integration protocol: the conformance
## scenario `agent-v1` (spec §"Provider conformance"), and nothing else.
##
## It exists to prove the protocol is implementable from its messages
## alone (M7 verification): it uses only the socket client and the public
## record encoders, never the host, and runs as its own process. Agent
## Harbor implements the same scenario with its own crate.

import std/[asyncdispatch, os, strutils, times]

import cbor

import ./[types, capabilities, canonical, transport]

type ProviderError = object of CatchableError

proc env(name: string): string =
  result = getEnv(name)
  if result.len == 0:
    raise newException(ProviderError, name & " is not set")

proc call(c: HostClient; entries: openArray[CborPair]): CborItem =
  let resp = waitFor c.request(encodeDeterministic(cMap(entries)))
  if resp.len == 0:
    raise newException(ProviderError, "the host closed the connection")
  decodeItem(resp)

proc outcome(r: CborItem): string = r.field("outcome").text
proc reason(r: CborItem): string =
  let f = r.field("reason")
  if f.isNil: "" else: f.text

proc op(kind: OperationKind; target: string;
        args: openArray[(string, string)] = []): Operation =
  result = Operation(kind: kind, target: target)
  for (n, v) in args:
    result.args.add OpArg(name: n, value: v)

type Session = object
  client: HostClient
  sid, intent, base: string

proc plan(s: Session; ops: seq[Operation]; caps: seq[string];
          evidence: seq[Digest32] = @[]): Plan =
  var grants: seq[Grant]
  for g in caps:
    grants.add parseGrant(g)
  Plan(sessionId: s.sid, intentId: parseDigestHex(s.intent),
       baseGeneration: s.base, operations: ops,
       declaredCapabilities: grants, evidence: evidence)

proc submit(s: Session; p: Plan): CborItem =
  s.client.call([tp("kind", cText("plan.submit")),
                 tp("plan", encodePlanItem(p))])

proc execute(s: Session; planHex: string; approval = ""): seq[CborItem] =
  var entries = @[tp("kind", cText("plan.execute")), tp("plan", cText(planHex))]
  if approval.len > 0:
    entries.add tp("approval", cText(approval))
  let r = s.client.call(entries)
  if r.outcome != "ok":
    raise newException(ProviderError, "execute refused: " & r.reason)
  r.field("results").elems

proc run(s: Session; p: Plan): seq[CborItem] =
  let r = s.submit(p)
  if r.outcome != "ok":
    raise newException(ProviderError, "submit refused: " & r.reason)
  let results = s.execute(asDigest(r.field("plan"), "plan").hex)
  for x in results:
    if x.field("status").text != "completed":
      raise newException(ProviderError, "operation failed: " &
        x.field("detail").text)
  results

proc runFixtureProvider*(): int =
  ## Perform scenario `agent-v1`; 0 on completion. Prints
  ## `conformance-done` last.
  try:
    if env("REPROOS_CONFORMANCE_SCENARIO") != "agent-v1":
      raise newException(ProviderError, "unknown scenario")
    var s = Session(client: waitFor connectHost(env("REPROOS_AGENT_SOCKET")),
                    sid: env("REPROOS_AGENT_SESSION"),
                    intent: env("REPROOS_AGENT_INTENT"),
                    base: getEnv("REPROOS_AGENT_BASE_GENERATION"))
    defer: s.client.close()
    # 1. Hello and attach.
    let hello = s.client.call([tp("kind", cText("hello")),
      tp("protocol", cUInt(ProtocolVersion)),
      tp("families", cArray([cText("checkout.v1"), cText("source.v1"),
        cText("build.v1"), cText("test.v1"), cText("generation.v1")]))])
    if hello.outcome != "ok":
      raise newException(ProviderError, "hello refused: " & hello.reason)
    let attach = s.client.call([tp("kind", cText("session.attach")),
      tp("session", cText(s.sid)),
      tp("secret", cText(env("REPROOS_AGENT_SECRET")))])
    if attach.outcome != "ok":
      raise newException(ProviderError, "attach refused: " & attach.reason)
    # 2. Check out the fixture package.
    let ws = s.run(s.plan(@[op(okCheckoutCreate, "fixture")],
                          @["workspace.create:fixture"]))[0].field("detail").text
    # 3. Read its README.
    discard s.run(s.plan(@[op(okSourceRead, ws, {"path": "README.md"})],
                         @["source.read:fixture"]))
    # 4. Write the requested content, build and test.
    let built = s.run(s.plan(@[
      op(okSourceWrite, ws, {"content": env("REPROOS_CONFORMANCE_CONTENT"),
                             "path": "src/main.c"}),
      op(okBuildRun, ws), op(okTestRun, ws)],
      @["source.write:fixture", "build.run:fixture", "test.run:fixture"]))
    # 5. An escaping path must be refused, and the provider carries on.
    let escape = s.submit(s.plan(@[op(okSourceWrite, ws,
      {"content": "x", "path": "../escape"})], @["source.write:fixture"]))
    if escape.outcome != "refused" or escape.reason != "path-escape":
      raise newException(ProviderError, "an escaping path was not refused")
    # 6. Stage, citing the build and test results, after the user approves.
    let stage = s.submit(s.plan(@[op(okGenerationStage, ws)],
      @["system.generation:stage"],
      @[asDigest(built[1].field("result"), "result"),
        asDigest(built[2].field("result"), "result")]))
    if stage.outcome != "ok" or stage.field("approvalRequired").elems.len != 1:
      raise newException(ProviderError, "stage plan was not held for approval")
    let approvalFile = env("REPROOS_CONFORMANCE_APPROVAL_FILE")
    let deadline = epochTime() + 60
    while not fileExists(approvalFile):
      if epochTime() > deadline:
        raise newException(ProviderError, "no approval arrived")
      sleep(50)
    let staged = s.execute(asDigest(stage.field("plan"), "plan").hex,
                           readFile(approvalFile).strip)
    if staged[0].field("status").text != "completed":
      raise newException(ProviderError, "the approved stage failed")
    echo "conformance-done"
    0
  except ProviderError, AgentRefusal, OSError, IOError, ValueError:
    echo "conformance-failed: ", getCurrentExceptionMsg()
    1
