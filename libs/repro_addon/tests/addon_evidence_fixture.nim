## Shared fixture of the add-on's evidence unit tests: a real Evidence sink
## (reprobuild's ``repro_peer_cache/evidence`` server, its real on-disk
## store, its real TLS and append-only vocabulary) and a host laid out the
## way bootstrap lays one out -- its sink write credential, its attestation
## key, its outbox and its evidence configuration -- all under one scratch
## directory.
##
## The sink runs IN THIS PROCESS, on the same dispatcher as the appender.
## That is deliberate, not a mock: a falsifying build of the sink
## (``-d:reproAddonMutation=sink-credential-has-read-scope``) must be the
## sink the test talks to, and ``scripts/run_addon_unit_mutation.sh``
## compiles exactly one binary, the test. The VM gate
## ``e2e_addon_evidence_credential_is_append_only`` runs the sink as its
## own process on another host.
##
## Not a test file (no ``t_`` prefix).

import std/[net, os, strutils]

import repro_peer_cache/evidence
import repro_peer_cache/identity
import repro_peer_cache/pki
import repro_peer_cache/types

import repro_infra
import repro_deploy_agent/manifest

import repro_addon/agent_record
import repro_addon/attestation
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_ship

type
  SinkFixture* = object
    root*: string
    storeDir*: string
    anchorsDir*: string
    identityDir*: string
    keyDir*: string
    server*: EvidenceSinkServer
    hostId*: string

  HostFixture* = object
    root*: string
    site*: ShipSite
    evidence*: EvidenceSite
    conf*: EvidenceConf
    credentialHost*: string
    attestationKey*: string

proc startSink*(root: string): SinkFixture =
  result.root = root / "sink"
  result.storeDir = result.root / "store"
  result.anchorsDir = result.root / "anchors"
  result.identityDir = result.root / "identity"
  result.keyDir = result.root / "checkpoint-key"
  createDir(result.storeDir)
  createDir(result.anchorsDir)
  let identity = loadOrCreateHostIdentity(result.identityDir / "host-ca.crt",
                                          result.identityDir / "host-ca.key")
  result.hostId = $identity.hostId
  let store = openEvidenceStore(result.storeDir, result.keyDir)
  result.server = newEvidenceSinkServer(store, identity,
    loadTrustAnchorDir(result.anchorsDir), "127.0.0.1", Port(0),
    anchorsDir = result.anchorsDir)
  result.server.start()

proc endpoint*(s: SinkFixture): string =
  "127.0.0.1:" & $int(s.server.listenPort)

proc entries*(s: SinkFixture): seq[EvidenceEntry] =
  ## Read LOCALLY from the sink's store, as an investigator on the sink
  ## host would (EVID-3).
  readEvidenceStore(s.storeDir)

proc closedPort*(): int =
  ## A port nothing listens on (bound, read, released).
  let sock = newSocket()
  sock.bindAddr(Port(0), "127.0.0.1")
  result = int(sock.getLocalAddr()[1])
  sock.close()

proc newHost*(root, name: string; sink: SinkFixture;
              endpoint = ""): HostFixture =
  ## A host bootstrapped with ``sink``: its credential (not yet enrolled),
  ## its attestation key, its outbox and ``evidence.conf``.
  result.root = root / name
  let st = result.root / "evidence-state"
  createDir(st)
  result.site = ShipSite(confPath: result.root / "evidence.conf",
    sinkCaPath: result.root / "evidence-sink.crt",
    credentialCert: st / "host-ca.crt", credentialKey: st / "host-ca.key",
    stateDir: st, outbox: result.root / "evidence" / "outbox",
    aptHookLog: result.root / "apt-hook.log",
    dpkgLog: result.root / "dpkg.log",
    bootIdPath: result.root / "boot_id")
  let cred = loadOrCreateHostIdentity(result.site.credentialCert,
                                      result.site.credentialKey)
  result.credentialHost = $cred.hostId
  copyFile(sink.identityDir / "host-ca.crt", result.site.sinkCaPath)
  writeFile(result.site.bootIdPath, "boot-" & name & "\n")
  let ep = if endpoint.len > 0: endpoint else: sink.endpoint
  writeFile(result.site.confPath, "sink = " & ep & "\nsink-host = " &
    sink.hostId & "\nheartbeat-interval = 300\ntick-interval = 330\n")
  result.conf = loadEvidenceConf(result.site.confPath)
  let keyPath = result.root / "agent" / "attestation.key"
  result.attestationKey = ensureAttestationKey(keyPath).publicKeyHex
  result.evidence = EvidenceSite(stateDir: result.root / "state",
    dir: result.root / "evidence", outbox: result.site.outbox,
    confPath: result.site.confPath, attestationKey: keyPath, host: name,
    journal: false)

proc enrol*(sink: SinkFixture; h: HostFixture) =
  ## The operator's step: the host's credential certificate into the sink's
  ## anchor directory (re-read at every connection).
  copyFile(h.site.credentialCert, sink.anchorsDir / (h.credentialHost & ".crt"))

proc pointAt*(h: var HostFixture; endpoint: string) =
  var text = readFile(h.site.confPath)
  var lines: seq[string]
  for l in text.splitLines():
    if l.startsWith("sink ="): lines.add("sink = " & endpoint) else: lines.add(l)
  writeFile(h.site.confPath, lines.join("\n"))
  h.conf = loadEvidenceConf(h.site.confPath)

proc layGeneration*(stateDir, gen, ledger, profile: string;
                    rec: AgentRecord = AgentRecord(); current = true) =
  ## A committed generation as the switch leaves it: its ledger, its
  ## profile, its agent record, and (``current``) ``current`` pointing at it.
  let gd = generationDir(stateDir, gen)
  createDir(gd)
  writeFile(gd / GenerationLedgerName, ledger)
  writeFile(gd / GenerationUserProfileName, profile)
  if rec.present: writeFile(gd / AgentRecordName, render(rec))
  if current:
    let cur = currentPath(stateDir)
    if symlinkExists(cur): removeFile(cur)
    createSymlink(gd, cur)

proc recordOf*(m: DeployManifest): AgentRecord =
  ## What an apply of ``m`` records (``agent_switch.agentRecordOf``).
  AgentRecord(deploymentId: m.deploymentId, sequence: m.sequence,
    profileDigest: manifestProfileDigestOf(m),
    closuresDigest: closureDigestsDigest(m.closureDigests))
