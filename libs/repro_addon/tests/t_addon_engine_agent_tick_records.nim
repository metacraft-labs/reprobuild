## The full engine's ``repro deploy-agent`` on an add-on host records its
## ticks as the add-on's own agent units do (spec §10.4, decision 29;
## threat model DET-AO-8, DET-AO-10): a manifest it rejects leaves an
## ``addon-manifest`` detection and every tick a heartbeat, so a host run by
## that agent is neither silent nor "nothing detected" to the off-host
## checks. ``engineAgentTick`` is what ``repro_cli_support/deploy_agent``
## runs on the add-on route.
##
## Falsifying build: ``engine-tick-unrecorded`` -- the engine's tick leaves
## no record; both steps go red.
##
## Mocks: none. A real tick over a real manifest signed by a key the
## agent does not anchor, read from a plain-path source; the apply hook is
## a refusal that must never be reached.

import std/[os, strutils, times, unittest]

import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import repro_addon/evidence as addonEvidence
import repro_addon/tick_evidence

let root = getTempDir() / ("addon-engine-tick-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

suite "the engine's deploy-agent ticks are recorded on an add-on host":
  let conf = root / "evidence.conf"
  writeFile(conf, "sink = 127.0.0.1:1\nsink-host = " & "a".repeat(64) &
    "\nheartbeat-interval = 300\ntick-interval = 330\n")
  let site = EvidenceSite(stateDir: root / "state", dir: root / "evidence",
    outbox: root / "evidence" / "outbox", confPath: conf,
    attestationKey: root / "no-key", host: "engine-host", journal: false)
  # Signed by a key the agent does not anchor.
  var m = DeployManifest(target: "h1", sequence: 3, deploymentId: "d3",
    profileText: "x\n", issuedAt: uint64(getTime().toUnix()),
    maxAgeSeconds: 3600)
  signManifest(peerAuth.generateKeypair(), m)
  writeFile(root / "m.rdm", cast[string](encodeManifest(m)))
  let anchors = peerAuth.newTrustAnchors()
  anchors.addAnchor(peerAuth.generateKeypair().publicKey)
  let cfg = AgentConfig(target: "h1", sources: @[root / "m.rdm"],
    anchors: anchors, stateDir: root / "agent")
  var deps: AgentDeps
  deps.apply = proc(m: DeployManifest): tuple[ok: bool; message: string]
      {.gcsafe.} = (false, "the apply must not be reached")

  test "a rejected manifest leaves its detection":
    let t = engineAgentTick(cfg, deps, site)
    check not t.raised
    check t.outcome.kind == aoRejected
    var kinds: seq[string]
    for p in outboxEntries(site.outbox): kinds.add(p.splitFile.name)
    var detection, beat = false
    for k in kinds:
      if k.endsWith("-addon-manifest-refused"): detection = true
      if k.endsWith("-tick"): beat = true
    check detection
    check beat
    check evidenceRecords("addon-manifest-refused", site.dir).len == 1

removeDir(root)
