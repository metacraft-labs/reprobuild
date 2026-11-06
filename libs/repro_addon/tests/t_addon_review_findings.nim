## The A11 code review's findings (reprobuild-pm ``issues/2026-11-06-addon-*``,
## at ``0cf5dec4``), each held at unit level through the real code: the real
## Evidence sink and store, the real off-host check, the real apt realiser
## and local store under a scratch root, the real static tree and custody
## pass.
##
## 1. An altered closure MEMBER, its union intact, is rebuilt from its
##    archive; the fetch stages the archive of a missing member.
## 2. Every path that renders the fetch unit renders the same bytes.
## 3. A containment is honoured only through its own signed statement: one
##    whose generation attestation was copied from a tick, or a replay after
##    a release, is refused.
## 4. A hand-over to the sender's own id or another enrolled id is refused;
##    a retired id needs an enrolled successor.
## 5. A committed static tree that lost or truncated a file is an
##    alteration (evidence, record); only a write the crash marker names is
##    a crash tear.
## 6. A contained host's engine agent neither fetches nor applies.
## 7. Lag counts from the first publication the check has seen, with only
##    the re-signed copy in the manifest directory.
## 8. The own-object migration re-renders a stale shipping path unit.
## 9. An acknowledgement handles the alert it names, not every alert of the
##    record.
## 10. Custody keeps the expected digest until the rebuild is verified,
##     files a crashed recovery's leftovers, writes a record a crash
##     interrupted (once), and bounds the cross-filesystem copy.
## 11. The shipping backoff is bounded and doubles; the outbox holds only
##     complete entries.
## 12. A store path outside every prefix is named, so custody refuses it.
## 13. Refused packets the sets no longer attribute alert; one check records
##     a bounded number of destinations.
## 14. Evidence entries age by their name's stamp.
## 15. A self-test absorbs only the four documented verbs, once each.
## 16. ``retired@`` is honoured in any field.
##
## Falsifying builds (each turns its own step red):
## ``apt-closure-member-stays-missing`` (1), ``fetch-skips-missing-member``
## (1), ``fetch-unit-paths-diverge`` (2), ``containment-unbound`` (3),
## ``handover-to-enrolled-id`` (4), ``retired-without-successor-ok`` (4),
## ``tree-tear-by-shape`` (5), ``contained-agent-applies`` (6),
## ``lag-ignores-check-state`` (7), ``path-unit-not-migrated`` (8),
## ``ack-by-sequence-only`` (9), ``custody-forgets-before-rebuild`` (10),
## ``evidence-copy-unbounded`` (10), ``custody-ignores-leftovers`` (10),
## ``custody-skips-unrecorded`` (10), ``outbox-temporary-inside`` (11),
## ``custody-prefixes-only`` (12), ``egress-ignores-counter`` (13),
## ``evidence-aged-by-mtime`` (14), ``self-test-any-verb`` (15),
## ``hosts-retired-fifth-only`` (16).
##
## Mocks: the ``.deb`` fetcher reads the fixture archive from a local path,
## standing for the fetch unit's staged copy (or fails: none staged); the
## engine tick's apply hook records that it was reached. Time is the check's
## ``nowMs``.

import std/[asyncdispatch, os, sequtils, strutils, tables, times, unittest]
from std/posix import Stat, stat

import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence
import repro_peer_cache/evidence_record
import repro_peer_cache/types
import repro_local_store/store as localStore
import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_deploy_agent/tick_status
import repro_dsl_stdlib/packages/apt_closure

import repro_addon/addon_apply
import repro_addon/agent_repin
import repro_addon/agent_split
import repro_addon/attestation
import repro_addon/contain_marker
import repro_addon/containment
import repro_addon/egress_observer
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship
import repro_addon/evidence_sink_cli
import repro_addon/generation0
import repro_addon/own_profile
import repro_addon/static_tree
import repro_addon/store_custody
import repro_addon/store_root
import repro_addon/tick_evidence

import ./addon_evidence_fixture
import ../../../tests/e2e/addon/deb_fixture_support

let root = getTempDir() / ("addon-review-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc statDevice(path: string): uint64 =
  ## The device a path lives on (``stat(2)`` ``st_dev``).
  var st: Stat
  doAssert stat(path.cstring, st) == 0, path
  uint64(st.st_dev)

proc scratchSite(name: string): CustodySite =
  let st = root / name / "state"
  createDir(st / "addon")
  writeFile(root / name / "evidence.conf", "sink = 127.0.0.1:1\n")
  createDir(root / name / "store")
  custodySite(st, root / name / "store").withEvidence(EvidenceSite(
    stateDir: st, dir: root / name / "ev", outbox: root / name / "ev" / "outbox",
    confPath: root / name / "evidence.conf", attestationKey: root / "none",
    host: "h", journal: false))

proc bootstrapHost(h: HostFixture) =
  createDir(h.evidence.stateDir / "addon")
  layGeneration(h.evidence.stateDir, "g0", "ledger 0\n", "")
  discard recordEvidence(EvidenceEvent(detector: edBootstrap,
    category: ecAudit, trigger: "bootstrap", attest: true), h.evidence)

proc tick(h: HostFixture) =
  recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: aoConverged,
    target: "t")), AgentApplyContext(), h.evidence)

proc ship(h: HostFixture) =
  let r = runEvidenceShip(h.site, h.conf, h.evidence.host, forceHeartbeat = true)
  doAssert r.error == "", r.error

proc statusOf(r: CheckReport; host, det: string): string =
  for s in r.statuses:
    if s.host == host and s.detector == det: return s.status
  "absent"

proc fastHost(sink: SinkFixture; name: string): HostFixture =
  ## One-second ticks: a three-second silence window.
  result = newHost(root, name, sink)
  writeFile(result.site.confPath,
    readFile(result.site.confPath).replace("tick-interval = 330",
                                           "tick-interval = 1"))
  result.conf = loadEvidenceConf(result.site.confPath)
  sink.enrol(result)
  bootstrapHost(result)

suite "the A11 code review's findings":
  let sink = startSink(root)
  writeFile(sink.storeDir / SinkHostName, sink.hostId & "\n")
  proc inputs(hosts: seq[EnrolledHost]; nowMs = int64(epochTime() * 1000);
              state = ""): CheckInputs =
    CheckInputs(storeDir: sink.storeDir, hosts: hosts, nowMs: nowMs,
      silenceFactor: 3, sinkHostId: sinkHostOf(sink.storeDir),
      statePath: state)

  test "1: an altered closure member, its union intact, is rebuilt":
    let site = scratchSite("wedge")
    let store = site.storeRoot
    let cache = root / "wedge" / "cache"
    let deb = root / "wedge.deb"
    writeDeb(deb, @[dir("./"), dir("./usr/"), dir("./usr/share/"),
      dir("./usr/share/wedge/"),
      ("./usr/share/wedge/ok.txt", '0', 0o644, "wedge\n", "")])
    let lock = fixtureLock("wedge", deb)
    let union = aptClosurePrefixPath(store, lock)
    let member = aptDebPrefixPath(store, lock.debs[0])
    let staged: AptDebFetcher = proc (url, dest: string; size: int64) =
      copyFile(deb, dest)
    let none: AptDebFetcher = proc (url, dest: string; size: int64) =
      raise newException(IOError, "no copy of " & url & " was staged")
    proc pass(fetch: AptDebFetcher): CustodyResult =
      custodyPass(site, [
        StoreObjectRef(path: union, kind: sokAptClosure, referrer: "u"),
        StoreObjectRef(path: member, kind: sokAptClosure, referrer: "u")],
        proc (o: StoreObjectRef): Recovery =
          closureRecovery(o, [lock], site, fetch, store, cache),
        mayRecover = true)
    let log = AptRealisationLog()
    discard realiseAptClosure(lock, store, cache, staged, log = log)
    for (p, d) in log.published: recordRealised(site, p, d)
    check pass(none).refusals.len == 0
    writeFile(member / "usr/share/wedge/planted", "x\n")
    # No archive staged: refused, the member moved aside -- and then the
    # fetch stages its archive, the union notwithstanding.
    check pass(none).refusals.len == 1
    check not dirExists(member)
    check dirExists(union)
    check debNeedsStaging(lock, lock.debs[0], store)
    # With the archive staged, the next pass rebuilds the member.
    let r = pass(staged)
    check r.refusals.len == 0
    check dirExists(member)
    check not fileExists(member / "usr/share/wedge/planted")
    check pass(none).refusals.len == 0

  test "2: every path renders the fetch unit the same":
    let exe = "/repro/store/prefixes/repro-addon/1-x/bin/repro"
    var a = AgentUnitsInputs(target: "t", sources: @["http://10.0.0.1/m"],
      allowedAddresses: @["10.0.0.1"], pollIntervalSec: 60)
    let observed = Gen0Inputs(reproExe: exe, agent: a,
      egress: EgressObserverInputs(nft: "/usr/sbin/nft",
                                   allowedAddresses: a.allowedAddresses))
    var unobserved = observed
    unobserved.egress = EgressObserverInputs()
    let bootstrapUnit = generation0Objects(observed).filterIt(
      it.unit == AgentFetchUnit)[0].content
    let ownObservedText = renderOwnProfile(generation0Objects(observed), "/f")
    let ownPlain = renderOwnProfile(generation0Objects(unobserved), "/f")
    # evidence-enrol: the installed (unobserved) unit, re-rendered observed.
    let installed = unitContentOf(ownPlain, AgentFetchUnit)
    let enrolUnit = agentFetchUnit(fetchUnitExe(installed),
      fetchUnitInputsOf(installed), observed = true)
    # agent-repin on an observed host, the same origins.
    let repinUnit = unitContentOf(repinOwnProfile(ownObservedText, a, "").ownText,
                                  AgentFetchUnit)
    # The own-object migration.
    let migratedUnit = unitContentOf(migrateOwnProfile(ownObservedText),
                                     AgentFetchUnit)
    check enrolUnit == bootstrapUnit
    check repinUnit == bootstrapUnit
    check migratedUnit == bootstrapUnit
    check "Slice=" & AgentSlice in repinUnit

  test "3: a containment counts only through its own signed statement":
    let h = fastHost(sink, "contain3")
    h.tick()
    h.ship()
    # A record carrying a tick's generation attestation, copied: refused.
    var forged = newEvidenceRecord(ecAudit, "addon-containment",
      "operator-contained", [("operator", "mallory"), ("reason", "x")],
      nowMs = int64(epochTime() * 1000))
    for e in sink.entries():
      if e.kind == ekRecord and $e.senderHostId == h.credentialHost and
          e.record.detector == "addon-agent-tick":
        for k in ["attestation", "attestationSignature", "attestationKey"]:
          forged.fields.add((k, e.record.field(k)))
    writeOutboxRecord(h.site.outbox, forged, "forged")
    h.ship()
    let hosts = @[EnrolledHost(hostId: h.credentialHost, target: "t")]
    let later = int64(epochTime() * 1000) + 3_600_000
    let r1 = runEvidenceCheck(inputs(hosts, later))
    check statusOf(r1, h.credentialHost, "addon-agent-tick") == "silent"
    check r1.alerts.anyIt(it.trigger == "containment-invalid")
    # A genuine statement, then a replay of it after a release.
    let h2 = fastHost(sink, "contain3b")
    h2.tick()
    h2.ship()
    discard recordContainmentAs(h2.evidence, h2.credentialHost,
      "contain", "alice", "drill", 1)
    # Keep the shipped entry's bytes: the replay below sends them again.
    var genuine = ""
    for kind, p in walkDir(h2.site.outbox):
      if p.endsWith("-contained.evr"): genuine = readFile(p)
    check genuine.len > 0
    h2.ship()
    let hosts2 = @[EnrolledHost(hostId: h2.credentialHost, target: "t")]
    check statusOf(runEvidenceCheck(inputs(hosts2, later)), h2.credentialHost,
                   "addon-agent-tick") == "contained"
    discard recordContainmentAs(h2.evidence, h2.credentialHost, "release",
      "alice", "done", 2)
    h2.tick()
    h2.ship()
    writeOutboxEntry(h2.site.outbox, "99999999999999999999-1-replay.evr",
                     genuine)                                 # the same bytes
    h2.ship()
    let r3 = runEvidenceCheck(inputs(hosts2, later))
    check statusOf(r3, h2.credentialHost, "addon-agent-tick") == "silent"
    check r3.alerts.anyIt(it.trigger == "containment-replayed")

  test "4: a hand-over to an enrolled id is refused; a retirement needs a successor":
    let h = newHost(root, "handover4", sink)
    sink.enrol(h)
    bootstrapHost(h)
    let other = "ef".repeat(32)
    let hv = KeyHandover(host: "handover4", oldKey: h.attestationKey,
      newKey: h.attestationKey, newCredentialHost: h.credentialHost, atMs: 1)
    let own = signHandover(hv, h.evidence.attestationKey)
    writeOutboxRecord(h.site.outbox, newEvidenceRecord(ecAudit, $edKeys,
      "rekey-handover", [("handover", own.statement),
      ("handoverSignature", own.signature)], nowMs = 1), "own")
    h.ship()
    let hosts = @[EnrolledHost(hostId: h.credentialHost, target: "t",
                               attestationKey: h.attestationKey),
                  EnrolledHost(hostId: other, target: "t")]
    let followed = enrolFromStore(hosts, sink.storeDir)
    check followed.hosts[0].retiredAt == 0'u64
    check runEvidenceCheck(inputs(hosts)).alerts.anyIt(
      it.trigger == "handover-invalid")
    var retired = hosts[0 .. 0]
    retired[0].retiredAt = 5
    check runEvidenceCheck(inputs(retired)).alerts.anyIt(
      it.trigger == "retired-without-successor")

  test "5: a committed tree that lost a file is an alteration, not a tear":
    let site = scratchSite("tree5")
    let files = @[
      StaticFile(path: "/etc/ssh/sshd_config.d/50-hardening.conf",
                 content: "PasswordAuthentication no\nPermitRootLogin no\n"),
      StaticFile(path: "/etc/sudoers.d/50-ops", content: "Defaults use_pty\n")]
    let first = realiseStaticTree(files, site)
    check not fileExists(treeRealisingMarker(site))
    let f = first.path / staticRelPath(files[0].path)
    setFilePermissions(f, {fpUserRead, fpUserWrite})
    writeFile(f, "PasswordAuthentication no\n")        # a truncation
    let again = realiseStaticTree(files, site)
    check readFile(again.path / staticRelPath(files[0].path)) == files[0].content
    check evidenceEntries(site).len == 1
    check evidenceRecords("store-recovered", site.evidence.dir).len == 1
    # A tear the crash marker names is repaired silently.
    removeFile(again.path / staticRelPath(files[1].path))
    writeFile(treeRealisingMarker(site), again.path & "\n")
    discard realiseStaticTree(files, site)
    check evidenceEntries(site).len == 1

  test "6: a contained host's engine agent does not apply":
    let st = root / "engine6"
    createDir(st / "addon")
    writeFile(containedMarkerPath(st), "operator=alice\n")
    let kp = peerAuth.generateKeypair()
    var m = DeployManifest(target: "h1", sequence: 3, deploymentId: "d3",
      profileText: "x\n", issuedAt: uint64(getTime().toUnix()),
      maxAgeSeconds: 3600)
    signManifest(kp, m)
    writeFile(st / "m.rdm", cast[string](encodeManifest(m)))
    let anchors = peerAuth.newTrustAnchors()
    anchors.addAnchor(kp.publicKey)
    var reached {.global.} = false
    var deps: AgentDeps
    deps.apply = proc(m: DeployManifest): tuple[ok: bool; message: string]
        {.gcsafe.} =
      {.cast(gcsafe).}: reached = true
      (true, "applied")
    let site = EvidenceSite(stateDir: st, dir: st / "ev", outbox: st / "ev" / "o",
      confPath: st / "none", attestationKey: st / "none", host: "e",
      journal: false)
    discard engineAgentTick(AgentConfig(target: "h1", sources: @[st / "m.rdm"],
      anchors: anchors, stateDir: st / "agent"), deps, site)
    check not reached

  test "7: lag counts from the first publication the check saw":
    let h = newHost(root, "lag7", sink)
    sink.enrol(h)
    bootstrapHost(h)
    let kp = peerAuth.generateKeypair()
    proc pub(seqNo: uint64; issuedAgo: int64): DeployManifest =
      result = DeployManifest(target: "lag", sequence: seqNo,
        deploymentId: "d" & $seqNo, profileText: "p\n",
        issuedAt: uint64(getTime().toUnix() - issuedAgo), maxAgeSeconds: 60)
      signManifest(kp, result)
    let state = root / "lag7.state"
    let hosts = @[EnrolledHost(hostId: h.credentialHost, target: "lag")]
    var inp = inputs(hosts, state = state)
    inp.manifests = @[pub(2, 7200)]          # the first copy, seen once
    discard runEvidenceCheck(inp)
    inp.manifests = @[pub(2, 10)]            # only the re-signed copy now
    check runEvidenceCheck(inp).alerts.anyIt(it.detector == "DET-AO-10")

  test "8: a stale shipping path unit is migrated":
    let stale = evidenceShipPathUnit().replace("DirectoryNotEmpty=", "PathChanged=")
    let own = "systemd.systemUnit {\n  name = \"" & EvidenceShipPathUnit &
      "\"\n  content = \"" & stale & "\"\n  enabled = true\n}\n"
    let migrated = migrateOwnProfile(own)
    check unitContentOf(migrated, EvidenceShipPathUnit) == evidenceShipPathUnit()
    check migrateOwnProfile(migrated) == migrated

  test "9: an acknowledgement handles the alert it names, only":
    let h = newHost(root, "ack9", sink)
    sink.enrol(h)
    bootstrapHost(h)
    # A detection signed by another key: two alerts, one sequence.
    let other = root / "ack9-other.key"
    discard ensureAttestationKey(other)
    var ev = h.evidence
    ev.attestationKey = other
    discard recordEvidence(EvidenceEvent(detector: edApplyRefusal,
      category: ecDetection, trigger: "apply-refused", attest: true), ev)
    h.ship()
    let hosts = @[EnrolledHost(hostId: h.credentialHost, target: "t",
                               attestationKey: h.attestationKey)]
    let before = runEvidenceCheck(inputs(hosts))
    let det = before.alerts.filterIt(it.trigger == "apply-refused")
    check det.len == 1
    check before.alerts.anyIt(it.trigger == "attestation-invalid" and
                              it.sinkSeq == det[0].sinkSeq)
    let inbox = sink.storeDir / OperatorInboxName
    createDir(inbox)
    writeFile(inbox / "9.ack", $det[0].sinkSeq & "\n" & det[0].detector & "/" &
      det[0].trigger & "\nalice\nhandled\n")
    discard processOperatorInbox(sink.server.store, peerIdOfHex(sink.hostId),
                                 inbox)
    let after = runEvidenceCheck(inputs(hosts))
    check not after.alerts.anyIt(it.trigger == "apply-refused")
    check after.alerts.anyIt(it.trigger == "attestation-invalid")

  test "10: custody keeps the expectation, files leftovers, bounds the copy":
    let site = scratchSite("crash10")
    let obj = site.storeRoot / "prefixes" / "x" / "1-a"
    createDir(obj)
    writeFile(obj / "f", "good\n")
    let good = storeTreeDigest(obj)
    recordRealised(site, obj, good)
    writeFile(obj / "f", "evil\n")
    # A rebuild that fails: the expectation stays (the index was its only
    # record), so a later pass can still recover it.
    let failing = proc (o: StoreObjectRef): Recovery =
      Recovery(ok: true, source: "t", realise: proc (): string =
        raise newException(IOError, "no source now"))
    discard custodyPass(site, [StoreObjectRef(path: obj, kind: sokFiles,
      referrer: "x")], failing, true)
    check readRealised(site).getOrDefault(obj, "") == good
    # A crash after the move aside: the next pass files it.
    createDir(obj)
    writeFile(obj / "f", "evil again\n")
    discard moveAside(site, obj)
    let entriesBefore = evidenceEntries(site).len
    fileLeftoverAsides(site)
    check evidenceEntries(site).len == entriesBefore + 1
    check evidenceRecords("store-recovery-interrupted", site.evidence.dir).len == 1
    check not dirExists(asideRoot(site)) or
      toSeq(walkDir(asideRoot(site))).len == 0
    # Across filesystems (the evidence directory on /dev/shm, a tmpfs; the
    # store here) the altered object is copied, at most the bound: a larger
    # one keeps its manifest and record only.
    var far = site
    far.evidenceDir = "/dev/shm" / ("a11-review10-" & $getCurrentProcessId())
    far.evidenceMaxBytes = 64
    removeDir(far.evidenceDir)
    defer: removeDir(far.evidenceDir)
    check statDevice(far.evidenceDir.parentDir) != statDevice(site.storeRoot)
    let big = site.storeRoot / "prefixes" / "x" / "3-c"
    createDir(big)
    writeFile(big / "f", "x".repeat(4096))
    let bigEntry = fileEvidence(far, moveAside(far, big), big, "e", "o", "big")
    check fileExists(bigEntry / "manifest") and fileExists(bigEntry / "record")
    check not dirExists(bigEntry / "tree")
    check "manifest only" in readFile(bigEntry / "record")
    let small = site.storeRoot / "prefixes" / "x" / "4-d"
    createDir(small)
    writeFile(small / "f", "tiny\n")
    let smallEntry = fileEvidence(far, moveAside(far, small), small, "e", "o",
                                  "small")
    check readFile(smallEntry / "tree" / "f") == "tiny\n"
    # A crash after the entry was filed and the object rebuilt, before its
    # record: the next pass records it, once.
    let obj2 = site.storeRoot / "prefixes" / "x" / "2-b"
    createDir(obj2)
    writeFile(obj2 / "f", "good\n")
    let d2 = storeTreeDigest(obj2)
    recordRealised(site, obj2, d2)
    writeFile(obj2 / "f", "evil\n")
    let entry2 = fileEvidence(site, moveAside(site, obj2), obj2, d2,
                              storeTreeDigest(asideRoot(site)), "test")
    createDir(obj2)
    writeFile(obj2 / "f", "good\n")                  # the verified rebuild
    flushUnrecorded(site)
    check fileExists(entry2 / "recorded")
    check evidenceRecords("store-recovered", site.evidence.dir).len == 1
    flushUnrecorded(site)
    check evidenceRecords("store-recovered", site.evidence.dir).len == 1

  test "11: the shipping backoff is bounded; the outbox holds only entries":
    check shipBackoffSec(0, 300) == 5
    check shipBackoffSec(1, 300) == 10
    check shipBackoffSec(20, 300) == 300
    check shipBackoffSec(20, 30) == 30
    let ob = root / "outbox11" / "outbox"
    createDir(ob)
    writeOutboxEntry(ob, "1-x.evr", "bytes")
    for kind, p in walkDir(ob):
      check p.endsWith(".evr")
    # Written beside the outbox first, then renamed in.
    check dirExists(outboxStaging(ob))
    # Every run that leaves the outbox non-empty waits, longer each time in
    # a row; an empty outbox ends the backoff.
    let ss = ShipSite(stateDir: root / "outbox11" / "state", outbox: ob)
    check shipRunWait(ss, 300) == 5
    check shipRunWait(ss, 300) == 10
    check shipRunWait(ss, 300) == 20
    for kind, p in walkDir(ob): removeFile(p)
    check shipRunWait(ss, 300) == 0
    writeOutboxEntry(ob, "2-x.evr", "bytes")
    check shipRunWait(ss, 300) == 5

  test "12: a store path outside every prefix is named":
    let named = storeObjectsNamedIn("ExecStart=/repro/store/tmp/evil/bin/sh -c x\n" &
      "BindReadOnlyPaths=/repro/store/loose:/opt/x\n" &
      "RequiresMountsFor=/repro/store\n")
    check "/repro/store/tmp" in named
    check "/repro/store/loose" in named
    check "/repro/store" notin named

  test "13: packets the full sets do not attribute alert":
    let state = root / "egress13.state"
    var un = 0'i64
    discard freshSince(@[("1.1.1.1", 5'i64)], state, "t", 5, addr un)
    check un == 0
    discard freshSince(@[("1.1.1.1", 6'i64)], state, "t", 106, addr un)
    check un == 100      # 101 refused, one of them the grown element
    var many: seq[RefusedDestination]
    for i in 0 ..< EgressDetectionsMax + 10: many.add(("10.9." & $i & ".1", 1'i64))
    let ev = EvidenceSite(stateDir: root / "egress13", dir: root / "egress13" / "ev",
      outbox: root / "egress13" / "ev" / "o", confPath: root / "none",
      attestationKey: root / "none", host: "e", journal: false)
    recordEgressCheck(EgressCheck(present: true, fresh: many), ev, 30_000)
    check evidenceRecords("egress-refused", ev.dir).len == EgressDetectionsMax
    check evidenceRecords("egress-refused-summary", ev.dir).len == 1

  test "14: evidence entries age by their name's stamp":
    let site = scratchSite("age14")
    createDir(site.evidenceDir / "20200101T000000Z-x-1")
    pruneEvidence(site)
    check evidenceEntries(site).len == 0

  test "15: a self-test absorbs the four documented verbs once each":
    let h = newHost(root, "probe15", sink)
    sink.enrol(h)
    let a = openAppender(h.site, h.conf)
    a.append(newEvidenceRecord(ecAudit, "addon-evidence-ship",
      "credential-probe", [("host", "probe15")], nowMs = 1))
    discard a.drain(5000)
    # One documented verb twice: the second is a probe.
    for op in [foList, foList]:
      discard waitFor(a.probeForbiddenOperation(op))
    a.close()
    let r = runEvidenceCheck(inputs(@[EnrolledHost(hostId: h.credentialHost)]))
    check r.alerts.filterIt(it.detector == "G34" and
                            it.trigger == "sink-probe").len == 1

  test "16: retired@ is honoured in any field":
    let id = "ab".repeat(32)
    let succ = "cd".repeat(32)
    let hs = parseHosts(id & " t retired@7:" & succ & "\n")
    check hs[0].retiredAt == 7'u64
    check hs[0].successor == succ
    check hs[0].attestationKey == ""
    check parseHosts(renderHosts(hs)) == hs

removeDir(root)
