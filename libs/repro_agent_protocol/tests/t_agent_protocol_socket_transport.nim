## ReproOS-Agent-Harbor-Integration M0: the channel separation of
## ``test_agent_harbor_reproos_permission_protocol`` holds over the real
## transport, not only through the in-process `Connection` handle.
##
## Real Unix domain sockets, real peer-credential checks and the real
## frame codec. Nothing is mocked; the backend is an empty `Backend`
## (checkout is the only delegated operation used, and it writes a real
## directory), because the subject is the transport.

import std/[asyncdispatch, os, tables, unittest]

import cbor
import repro_agent_protocol
import repro_agent_protocol/transport

type DirBackend = ref object of Backend

method createCheckout(b: DirBackend; package, root: string): OpResult =
  writeFile(root / "README", package)
  OpResult(status: osCompleted)

# Socket paths are bounded (104 bytes on macOS), so keep the directory short.
let dir = "/tmp/rap-" & $getCurrentProcessId()
removeDir(dir)

proc call(c: HostClient; entries: openArray[CborPair]): CborItem =
  let resp = waitFor c.request(encodeDeterministic(cMap(entries)))
  if resp.len == 0: nil else: decodeItem(resp)

proc hello(c: HostClient): CborItem =
  c.call([tp("kind", cText("hello")), tp("protocol", cUInt(1)),
          tp("families", cArray([cText("checkout.v1"), cText("source.v1"),
                                 cText("generation.v1")]))])

suite "M0 — the channels are separate sockets":
  let h = newHost(DirBackend(), dir / "workspaces")
  let server = startServer(h, dir / "run")

  test "the socket directory is private to the user":
    check getFilePermissions(dir / "run") ==
      {fpUserRead, fpUserWrite, fpUserExec}

  test "a session created on consent.sock is used on provider.sock":
    let consent = waitFor connectHost(consentSocketPath(dir / "run"))
    let provider = waitFor connectHost(providerSocketPath(dir / "run"))
    check consent.hello().field("outcome").text == "ok"
    check provider.hello().field("outcome").text == "ok"
    let created = consent.call([tp("kind", cText("session.create")),
      tp("provider", cText("agent-harbor")),
      tp("grants", cArray([cText("workspace.create:hello")]))])
    check created.field("outcome").text == "ok"
    let sid = created.field("session").text
    let secret = created.field("secret").text
    # The provider socket cannot create sessions, capture intents or
    # approve, whatever the request says.
    for kind in ["session.create", "intent.capture", "plan.approve"]:
      checkpoint kind
      let r = provider.call([tp("kind", cText(kind)),
        tp("provider", cText("x")), tp("grants", cArray([])),
        tp("session", cText(sid)), tp("text", cText("forged")),
        tp("plan", cText("00"))])
      check r.field("reason").text == "wrong-channel"
    check provider.call([tp("kind", cText("session.attach")),
      tp("session", cText(sid)), tp("secret", cText(secret))]).
      field("outcome").text == "ok"
    let intent = consent.call([tp("kind", cText("intent.capture")),
      tp("session", cText(sid)), tp("text", cText("check it out"))])
    let plan = Plan(sessionId: sid,
      intentId: asDigest(intent.field("intent"), "intent"),
      baseGeneration: "",
      operations: @[Operation(kind: okCheckoutCreate, target: "hello")],
      declaredCapabilities: @[parseGrant("workspace.create:hello")])
    let submitted = provider.call([tp("kind", cText("plan.submit")),
                                   tp("plan", encodePlanItem(plan))])
    check submitted.field("outcome").text == "ok"
    let pid = asDigest(submitted.field("plan"), "plan").hex
    let ran = provider.call([tp("kind", cText("plan.execute")),
                             tp("plan", cText(pid))])
    check ran.field("outcome").text == "ok"
    let ws = ran.field("results").elems[0].field("detail").text
    check readFile(h.workspaces[ws].root / "README") == "hello"
    # Closing the provider connection suspends the session.
    provider.close()
    for _ in 0 ..< 200:
      if h.sessionState(sid) == ssSuspended: break
      poll(10)
    check h.sessionState(sid) == ssSuspended
    consent.close()

  test "a consent peer the policy does not accept gets no response":
    let strictDir = dir / "strict"
    let strict = startServer(h, strictDir,
      consentPeer = proc (pid: int): bool {.gcsafe.} = false)
    let c = waitFor connectHost(consentSocketPath(strictDir))
    let r = waitFor c.request(encodeDeterministic(cMap([
      tp("kind", cText("hello")), tp("protocol", cUInt(1)),
      tp("families", cArray([]))])))
    check r.len == 0
    c.close()
    # The provider socket of the same server is unaffected by that policy.
    let p = waitFor connectHost(providerSocketPath(strictDir))
    check p.hello().field("outcome").text == "ok"
    p.close()
    strict.stop()

  test "a frame that is not CBOR is refused and the connection stays open":
    let c = waitFor connectHost(providerSocketPath(dir / "run"))
    check c.hello().field("outcome").text == "ok"
    let r = waitFor c.request(@[0xff'u8, 0x00])
    check decodeItem(r).field("reason").text == "malformed"
    check c.call([tp("kind", cText("session.attach")),
      tp("session", cText("s0")), tp("secret", cText("x"))]).
      field("reason").text == "session-unknown"
    c.close()

  server.stop()

removeDir(dir)
