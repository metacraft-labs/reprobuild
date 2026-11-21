## Gate ``e2e_addon_evidence_credential_is_append_only`` (milestone A11;
## spec §10.4, §10.6; threat model G34, EDGE-5, CRED-3).
##
## The gate creates its own Evidence sink on the build host (reprobuild's
## ``repro-evidence-sink``, its own process, store and identity) and
## bootstraps the guest to ship to it. Before the guest's credential is
## enrolled at the sink, it cannot even append (vacuity guard: the sink
## authenticates per host). After enrolment, with the host's own sink
## credential, from the guest, ``repro system addon evidence-credential-
## check``: an append is acknowledged, and a list, a read, an overwrite and
## a delete are each refused. The sink's store, read locally, holds the
## probe under the guest's host id and one refusal entry per forbidden
## operation; nothing in it was overwritten or removed (its chain and
## checkpoints verify, with the appender's receipt).
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=sink-credential-has-read-scope``,
## a build of the SINK): a credential with read scope lists the sink; the
## check reports the list answered and the gate goes red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_peer_cache/evidence
import repro_peer_cache/types

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support

const Gate = "e2e_addon_evidence_credential_is_append_only"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  var sink = startGateSink(g)
  defer: sink.stop()
  g.provideSinkCa(sink)
  let bs = g.bootstrapWithAgent(repro, step, extraFlags = sink.evidenceFlags)
  producer = bs.producer
  if not bs.ok: return
  record["sinkHost"] = %sink.hostId
  let before = g.exec(repro & " system addon evidence-credential-check")
  record["beforeEnrolment"] = %(before.stdout & before.stderr)
  step("vacuity guard: an unenrolled credential cannot append",
       before.exitCode != 0 and "append: NOT acknowledged" in before.stdout,
       before.stdout & before.stderr)
  let host = g.enrol(sink)
  record["guestHost"] = %host
  let c = g.exec(repro & " system addon evidence-credential-check")
  record["check"] = %(c.stdout & c.stderr)
  step("an append with the host's credential is acknowledged",
       "append: acknowledged" in c.stdout, c.stdout & c.stderr)
  for op in ["list", "read", "overwrite", "delete"]:
    step("a " & op & " with the host's credential is refused",
         (op & ": refused") in c.stdout, c.stdout)
  step("the check exits 0", c.exitCode == 0, $c.exitCode)
  var probes, refused = 0
  var verbs: seq[int]
  for e in sink.entries():
    if $e.senderHostId != host: continue
    if e.kind == ekRecord and e.record.trigger == "credential-probe": inc probes
    if e.kind == ekRefusedVerb:
      inc refused
      if e.body.len > 0: verbs.add(int(e.body[0]))
  record["sinkRefusedVerbs"] = %verbs
  step("the sink holds the probe under the guest's host id", probes == 1, $probes)
  step("the sink recorded each refused operation", refused == 4 and
       verbs.len == 4, $verbs)
  let r = verifyEvidenceStore(sink.storeDir,
    checkpointPublicKeyFromCert(sinkCheckpointCertPath(sink.keyDir)), @[],
    allowUnanchoredTail = true)
  step("the sink's chain and checkpoints verify (nothing overwritten or " &
       "removed)", r.ok, r.reason)

suite Gate:
  test "the Evidence sink write credential is append-only":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
