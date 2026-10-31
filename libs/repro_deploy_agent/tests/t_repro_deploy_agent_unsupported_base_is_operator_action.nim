## ``t_repro_deploy_agent_unsupported_base_is_operator_action``.
##
## An add-on host whose distribution was upgraded to a base outside the
## supported matrix refuses every apply with ``EAddOnUnsupportedBase``
## (ReproOS add-on mode, distribution release upgrades). The agent must
## report that as ``aoUnsupportedBase`` -- exit 2, an operator must act --
## not as a retryable ``aoApplyFailed`` the timer would repeat forever, and
## it must not record the sequence as applied, so the same manifest applies
## once the base is fixed. The refusal is the typed ``EAddOnUnsupportedBase``
## the apply hook lets through, never recognised by its message: a hook that
## returns ``ok = false`` with a message that merely starts with the name
## stays ``aoApplyFailed``. Also here: the drift probe of a recorded tick
## runs on a converged tick and lands in the tick status record.
##
## *Mocking.* The apply hook is a recording stub returning the add-on
## apply's refusal text: what is under test is the agent's classification
## of a refused apply, and the add-on apply that produces the refusal is
## gated on real guests (the release-upgrade gates). Manifest signing,
## verification and the state directory are the real ones.

import std/[json, os, strutils, unittest]

import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../src/repro_deploy_agent/agent
import ../src/repro_deploy_agent/manifest
import ../src/repro_deploy_agent/tick_status
import ../src/repro_deploy_agent/tick_event_log
import ../src/repro_deploy_agent/tick_record
import repro_infra/addon_diagnostics

var gReply = ""
var gRaise = false

proc refusingApply(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
  {.cast(gcsafe).}:
    if gRaise:
      raise newAddOnUnsupportedBase("ubuntu 28.04", "the base is ID=ubuntu " &
        "VERSION_ID=28.04, which is not in the add-on's supported matrix")
    if gReply.len == 0: (ok: true, message: "applied")
    else: (ok: false, message: gReply)

proc setup(name: string): tuple[cfg: AgentConfig; source: string;
                                 producer: peerAuth.PeerKeypair] =
  let root = getTempDir() / ("rdmf-base-" & name & "-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  result.producer = peerAuth.generateKeypair()
  result.source = root / "latest.rdm"
  result.cfg = AgentConfig(target: "addon-host", sources: @[result.source],
    anchors: anchorsFromKeypairs([result.producer.publicKey]),
    stateDir: root / "state", fetchTimeoutMs: 5000)

proc publish(source: string; producer: peerAuth.PeerKeypair; target: string;
             sequence: uint64) =
  var m = DeployManifest(target: target, sequence: sequence,
    deploymentId: "deployment-" & $sequence,
    profileText: "profile \"x\":\n  resources:\n    discard\n")
  signManifest(producer, m)
  var wire = ""
  for b in encodeManifest(m): wire.add(char(b))
  writeFile(source, wire)

suite "an unsupported base is an operator action":
  test "EAddOnUnsupportedBase -> aoUnsupportedBase, exit 2, sequence not recorded":
    let h = setup("refused")
    publish(h.source, h.producer, h.cfg.target, 7)
    gRaise = true
    let o = runAgentTick(h.cfg, AgentDeps(apply: refusingApply))
    check o.kind == aoUnsupportedBase
    check deployAgentExitCode(o.kind) == 2
    check "ubuntu" in o.message
    check o.errorCode == "unsupported_base"
    check readLastAppliedSequence(h.cfg) == 0'u64
    check tickEventId($o.kind) == EventIdTickUnsupportedBase
    # Fixed base: the same sequence applies on the next tick.
    gRaise = false
    gReply = ""
    let again = runAgentTick(h.cfg, AgentDeps(apply: refusingApply))
    check again.kind == aoApplied
    check readLastAppliedSequence(h.cfg) == 7'u64

  test "any other refused apply stays retryable":
    let h = setup("other")
    publish(h.source, h.producer, h.cfg.target, 3)
    gReply = "EDrift: /etc/x changed out of band"
    let o = runAgentTick(h.cfg, AgentDeps(apply: refusingApply))
    check o.kind == aoApplyFailed
    check deployAgentExitCode(o.kind) == 1
    # A message that only LOOKS like the refusal is not one.
    gReply = "EAddOnUnsupportedBase: said by a hook that returned instead of raising"
    check runAgentTick(h.cfg, AgentDeps(apply: refusingApply)).kind == aoApplyFailed

  test "the drift probe runs on a converged tick and is recorded":
    let h = setup("drift")
    publish(h.source, h.producer, h.cfg.target, 4)
    gReply = ""
    gRaise = false
    discard runAgentTick(h.cfg, AgentDeps(apply: refusingApply))
    var calls = 0
    let probe: DriftProbe = proc(): seq[string] {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        @["finding package p now owns ledger path /etc/x"]
    let t = runAgentTickRecorded(h.cfg, AgentDeps(apply: refusingApply,
                                                  driftProbe: probe))
    check t.outcome.kind == aoConverged
    check t.exitCode == 0
    check calls == 1
    check t.addOnDrift == @["finding package p now owns ledger path /etc/x"]
    let rec = parseJson(readFile(tickStatusPath(h.cfg.stateDir, h.cfg.target)))
    check rec["addOnDrift"].len == 1
    check rec["outcome"].getStr() == "aoConverged"
