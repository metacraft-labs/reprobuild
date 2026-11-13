## Gate ``e2e_addon_staging_swap_after_verify_is_refused`` (milestone A8;
## spec §9.1, threat model G33, T38).
##
## The apply unit pauses (seam build) after it copied the staging area and
## verified the copy. The gate then swaps the staged envelope for a forged
## one whose profile writes other bytes, and plants a symbolic link in the
## staging directory. On resume the activated bytes are the verified ones;
## the swapped bytes reach neither the store nor ``/etc``. A later fetch's
## staging is copied afresh, so the gate also checks the next tick applies
## normally.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-rereads-staging``): the
## apply re-reads the staging path after verification and activates the
## swapped bytes: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (seam build).
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_staging_swap_after_verify_is_refused"
  Path = "/etc/repro/a8-swap"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile(Path, "verified\n")))
  g.armApplySeam("agent-apply-after-verify")
  g.startFetchNoWait()
  let paused = g.waitSeam(ApplySeamDir, "agent-apply-after-verify")
  step("the apply unit paused after verifying its copy", paused, "")
  if paused:
    # A forged envelope, signed by a key the host does not anchor.
    var forged = DeployManifest(target: AgentTarget, sequence: 1,
      deploymentId: "a8-1", profileText: canonicalFile(Path, "swapped\n"),
      issuedAt: uint64(getTime().toUnix()), maxAgeSeconds: 86_400'u64)
    signManifest(peerAuth.generateKeypair(), forged)
    let bytes = encodeManifest(forged)
    var s = newString(bytes.len)
    for i, b in bytes: s[i] = char(b)
    writeFile(g.runDir / "forged.rdm", s)
    g.copyTo(g.runDir / "forged.rdm", "/root/forged.rdm")
    let root = "/var/lib/private/repro-agent-fetch/staging"
    let sw = g.exec("d=" & root & "/$(cat " & root & "/latest) && " &
      "cp /root/forged.rdm $d/manifest.rdm && ln -s /etc/shadow $d/planted")
    step("the staged envelope was swapped and a link planted", sw.exitCode == 0,
         sw.stderr)
    g.resumeSeam(ApplySeamDir)
  g.waitApplyIdle()
  let t = g.lastTick()
  record["tick"] = %($t)
  let content = g.exec("cat " & Path).stdout
  step("the activated bytes are the verified ones (or the apply refused)",
       content == "verified\n" or (t.outcome != "aoApplied" and content == ""),
       "content " & content.escape & "; " & $t)
  step("the swapped bytes reached neither /etc nor the store",
       g.exec("grep -rqs swapped /etc/repro /repro/store/prefixes").exitCode != 0, "")
  # The next cycle copies a fresh staging area and applies normally.
  discard producer.publish(PublishSpec(sequence: 2,
    profileText: canonicalFile(Path, "two\n")))
  let t2 = g.tickUnits()
  step("the next tick applies", t2.outcome == "aoApplied", $t2 & t2.applyLog)

suite Gate:
  test "a staging swap after verification never reaches the host":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
