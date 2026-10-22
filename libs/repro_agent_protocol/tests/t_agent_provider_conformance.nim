## ReproOS-Agent-Harbor-Integration M7 verification, the fixture half of
## ``e2e_reproos_agent_provider_conformance``: "a minimal fixture provider
## proves the interface is implementable without privileged shortcuts".
##
## The harness (`conformance.runConformance`) runs a real host on real
## sockets and starts the provider as a separate process: this test binary
## re-executed with `REPROOS_CONFORMANCE_ROLE` set, so no helper binary is
## compiled. The provider uses only the socket client and the public
## record encoders. The two negative controls show the harness fails a
## provider that reaches for the consent socket and one that does nothing.

import std/[asyncdispatch, os, sequtils, strutils, tempfiles, unittest]

import cbor
import repro_agent_protocol
import repro_agent_protocol/[conformance, fixture_provider, transport]

proc reachForConsent(): int =
  ## A provider that tries the consent socket before behaving.
  let consentPath = getEnv("REPROOS_AGENT_SOCKET").parentDir / "consent.sock"
  try:
    let c = waitFor connectHost(consentPath)
    discard waitFor c.request(encodeDeterministic(cMap([
      tp("kind", cText("hello")), tp("protocol", cUInt(1)),
      tp("families", cArray([]))])))
    c.close()
  except CatchableError:
    discard
  runFixtureProvider()

case getEnv("REPROOS_CONFORMANCE_ROLE")
of "provider": quit(runFixtureProvider())
of "consent-reacher": quit(reachForConsent())
of "idle": quit(0)
else: discard

proc conformanceOf(role: string): ConformanceReport =
  let root = createTempDir("rac-", "")
  defer: removeDir(root)
  runConformance(@[getAppFilename()], root,
                 extraEnv = @[("REPROOS_CONFORMANCE_ROLE", role)],
                 timeoutSeconds = 60)

suite "M7 — provider conformance":
  test "the minimal fixture provider passes scenario agent-v1":
    let r = conformanceOf("provider")
    checkpoint r.providerOutput
    checkpoint r.failures.join("\n")
    check r.passed
    # The long build is cancelled while it runs or, when the cancellation
    # overtakes it, withdrawn before it starts.
    check r.backendCalls.filterIt(it != "build-long fixture cancelled") ==
      @["checkout fixture", "build fixture", "test fixture",
        "generation.stage fixture",
        "remix.capture fixture " & FixtureRelease,
        "remix.export fixture " & FixtureRelease,
        "generation.activate " & FixtureRelease,
        "generation.rollback " & FixtureBase,
        "compose fixture " & FixtureRelease]

  test "a provider that reaches for the consent socket fails":
    let r = conformanceOf("consent-reacher")
    check not r.passed
    check r.failures.anyIt("consent socket" in it)

  test "a provider that does nothing fails":
    let r = conformanceOf("idle")
    check not r.passed
    check r.failures.anyIt("never attached" in it)

type NoBackend = ref object of Backend

suite "M7 — admission follows conformance":
  test "only Agent Harbor is admitted by default; others need a passing report":
    let root = createTempDir("rac-admit-", "")
    defer: removeDir(root)
    let h = newHost(NoBackend(), root / "ws")
    let consent = newConnection(chConsent)
    discard h.hello(consent, ProtocolVersion, {low(Family) .. high(Family)})
    check h.isAdmitted(DefaultProvider)
    discard h.createSession(consent, DefaultProvider, @[])
    expect AgentRefusal:
      discard h.createSession(consent, "other-agent", @[])
    # A failing report admits nothing.
    let failing = conformanceOf("idle")
    expect AgentRefusal:
      h.admitAfterConformance(consent, "other-agent", failing)
    check not h.isAdmitted("other-agent")
    # A passing one admits, and the audit log names the evidence.
    let passing = conformanceOf("provider")
    h.admitAfterConformance(consent, "other-agent", passing)
    check h.isAdmitted("other-agent")
    discard h.createSession(consent, "other-agent", @[])
    check h.audit.records.anyIt(it.decision == "admit" and
      it.grant == "other-agent" and it.resultDigest == reportDigest(passing).hex)
    # The provider channel cannot admit.
    let agent = newConnection(chProvider)
    expect AgentRefusal:
      h.admitProvider(agent, "rogue", default(Digest32))
