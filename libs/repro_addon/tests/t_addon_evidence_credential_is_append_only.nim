## The Evidence sink write credential is per host and append-only (threat
## model G34; spec §10.4, §10.6): with a host's credential an append is
## acknowledged, and a list, a read, an overwrite and a delete are each
## refused -- unanswered, recorded by the sink, and the connection closed.
## A credential the sink does not know cannot even append, and one host's
## credential files records under that host's id only.
##
## This is the unit half of ``e2e_addon_evidence_credential_is_append_only``
## (the VM gate runs the same check from a guest's credential against a sink
## process on the build host).
##
## Falsifying build: ``sink-credential-has-read-scope`` -- the sink answers
## a list or a read from an appender, as a credential with read scope
## would get. The credential check must then report the list ANSWERED and
## this test goes red.
##
## Mocks: none (see ``addon_evidence_fixture``: the sink runs in this
## process so that the falsifying build of it is the one tested).

import std/[os, strutils, unittest]

import repro_peer_cache/evidence
import repro_peer_cache/types

import repro_addon/evidence_check
import repro_addon/evidence_ship

import ./addon_evidence_fixture

let root = getTempDir() / ("addon-evidence-cred-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

suite "the Evidence sink write credential is append-only":
  let sink = startSink(root)
  let a = newHost(root, "host-a", sink)
  let b = newHost(root, "host-b", sink)

  test "a credential the sink has not enrolled cannot append":
    let c = runCredentialCheck(a.site, a.conf, "host-a")
    check not c.appended
    check sink.entries().len == 0

  test "an enrolled credential appends, and cannot list, read, overwrite or delete":
    sink.enrol(a)
    let c = runCredentialCheck(a.site, a.conf, "host-a")
    check c.appended
    for (op, answered) in c.answered:
      checkpoint $op
      check not answered
    check credentialCheckOk(c)
    # The sink holds the probe, under the host id it verified, and one
    # refusal entry per forbidden operation, naming the verb.
    var probes, refused: int
    var verbs: seq[uint8]
    for e in sink.entries():
      if e.kind == ekRecord and e.record.trigger == "credential-probe":
        check $e.senderHostId == a.credentialHost
        inc probes
      if e.kind == ekRefusedVerb:
        check $e.senderHostId == a.credentialHost
        verbs.add(e.body[0])
        inc refused
    check probes == 1
    check refused == 4
    for op in ForbiddenOperation:
      check verbOf(op) in verbs

  test "the off-host check reports each probe of the sink (G34)":
    let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
      hosts: @[EnrolledHost(hostId: a.credentialHost)], nowMs: 1))
    var probes = 0
    for al in r.alerts:
      if al.detector == "G34" and al.trigger == "sink-probe": inc probes
    check probes == 4

  test "the credential is per host: another host's records carry its own id":
    sink.enrol(b)
    let c = runCredentialCheck(b.site, b.conf, "host-b")
    check credentialCheckOk(c)
    var seenB = false
    for e in sink.entries():
      if e.kind == ekRecord and e.record.field("host") == "host-b":
        check $e.senderHostId == b.credentialHost
        check $e.senderHostId != a.credentialHost
        seenB = true
    check seenB

  sink.server.stop()

removeDir(root)
