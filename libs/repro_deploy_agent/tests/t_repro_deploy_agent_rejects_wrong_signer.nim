## Windows-Runner-Binary-Cache-Deploy M5 gate 2 —
## ``t_repro_deploy_agent_rejects_wrong_signer``.
##
## Proves the trust gate + non-poisoning:
##
##   1. A manifest signed by a key NOT in the allowed-signers set is
##      REJECTED — the agent does NOT apply it, surfaces a verification
##      error, and the persisted last-applied-sequence does NOT advance.
##   2. A TAMPERED manifest (valid signer, but a byte flipped after signing
##      so the signature no longer verifies) is REJECTED the same way.
##   3. A manifest for a DIFFERENT target is IGNORED (per-target schema) —
##      it neither applies nor errors; the agent simply waits.
##
## The apply hook here is a RECORDING hook (not the production
## ``runInfraApply``): the whole point is to assert the apply NEVER runs on
## a rejected/ignored manifest, so we count invocations. A production apply
## would also work but adds nothing to the rejection assertion.

import std/[os, tempfiles, unittest]

import repro_deploy_agent
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile

const Target = "windows-runner-001"

proc writeManifestBytes(path: string; bytes: seq[byte]) =
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  writeFile(path, s)

proc trivialAction(id: string): ProfileBuildAction =
  ProfileBuildAction(id: id, argv: @["/bin/true"], cwd: "",
    outputs: @[], commandStatsId: "m5.noop",
    requiresElevation: false, cacheable: false)

suite "M5 — deploy agent rejects a manifest from a disallowed signer":

  test "t_repro_deploy_agent_rejects_wrong_signer":
    let tmpRoot = createTempDir("m5-reject-", "")
    defer:
      try: removeDir(tmpRoot) except CatchableError: discard

    # The ALLOWED signer and a DIFFERENT, disallowed signer.
    let allowedSigner = peerAuth.generateKeypair()
    let evilSigner = peerAuth.generateKeypair()
    check allowedSigner.publicKey != evilSigner.publicKey
    let anchors = anchorsFromKeypairs(@[allowedSigner.publicKey])

    let agentStateDir = tmpRoot / "agent-state"
    createDir(agentStateDir)
    let manifestPath = tmpRoot / "manifests" / "latest.rdm"

    # A recording apply hook — MUST NOT be called on a rejected manifest.
    var applyCalls = 0
    let recordingApply: ApplyHook =
      proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
        {.cast(gcsafe).}: inc applyCalls
        (ok: true, message: "recorded")

    let cfg = AgentConfig(
      target: Target,
      sources: @[manifestPath],
      anchors: anchors,
      stateDir: agentStateDir,
      fetchTimeoutMs: 5000)
    let deps = AgentDeps(apply: recordingApply)

    # ------------------------------------------------------------------
    # 1. WRONG SIGNER — signed by evilSigner (not an allowed signer).
    # ------------------------------------------------------------------
    var wrong = DeployManifest(
      target: Target, sequence: 5'u64, deploymentId: "evil-5",
      profileText: "", buildActions: @[trivialAction("evil")])
    signManifest(evilSigner, wrong)
    # Sanity: the signature is cryptographically VALID (evilSigner really
    # signed it) — the ONLY reason it's rejected is the trust set. This
    # proves the gate is the allowed-signers check, not a broken signature.
    check verifySignature(wrong)
    check not verifyTrusted(wrong, anchors)

    writeManifestBytes(manifestPath, encodeManifest(wrong))
    let r1 = runAgentTick(cfg, deps)
    check r1.kind == aoRejected
    check r1.errorCode == "verification_failed"
    check applyCalls == 0                      # NEVER applied
    check readLastAppliedSequence(cfg) == 0'u64  # floor did NOT advance

    # ------------------------------------------------------------------
    # 2. TAMPERED — allowed signer, but a byte flipped after signing.
    # ------------------------------------------------------------------
    var good = DeployManifest(
      target: Target, sequence: 6'u64, deploymentId: "good-6",
      profileText: "hello", buildActions: @[trivialAction("good")])
    signManifest(allowedSigner, good)
    check verifyTrusted(good, anchors)         # the untampered form is fine
    var tampered = encodeManifest(good)
    # Flip a byte in the trailing SIGNATURE (the last 64 bytes) so the
    # envelope still decodes (target/sequence/deploymentId intact — the
    # per-target gate passes) but the signature no longer verifies. This
    # isolates the SIGNATURE-verification failure from the wrong-target
    # path: the manifest IS for us, yet it's rejected because the crypto
    # doesn't check out.
    let flipAt = tampered.len - 1
    tampered[flipAt] = byte(tampered[flipAt] xor 0xff'u8)
    writeManifestBytes(manifestPath, tampered)
    let r2 = runAgentTick(cfg, deps)
    check r2.kind == aoRejected
    check r2.errorCode == "verification_failed"
    check applyCalls == 0
    check readLastAppliedSequence(cfg) == 0'u64

    # ------------------------------------------------------------------
    # 3. WRONG TARGET — validly signed by the allowed signer, but for a
    #    different target. Per-target schema: IGNORED, not applied.
    # ------------------------------------------------------------------
    var other = DeployManifest(
      target: "some-other-host", sequence: 99'u64,
      deploymentId: "other-99", profileText: "",
      buildActions: @[trivialAction("other")])
    signManifest(allowedSigner, other)
    check verifyTrusted(other, anchors)        # signature is fine…
    writeManifestBytes(manifestPath, encodeManifest(other))
    let r3 = runAgentTick(cfg, deps)
    check r3.kind == aoWaiting                 # …but it's not for us
    check applyCalls == 0
    check readLastAppliedSequence(cfg) == 0'u64

    # ------------------------------------------------------------------
    # 4. Control: a PROPERLY signed, correct-target manifest DOES apply,
    #    proving the rejections above were the trust/target gates and not
    #    a blanket "never apply".
    # ------------------------------------------------------------------
    writeManifestBytes(manifestPath, encodeManifest(good))
    let r4 = runAgentTick(cfg, deps)
    check r4.kind == aoApplied
    check r4.sequence == 6'u64
    check applyCalls == 1
    check readLastAppliedSequence(cfg) == 6'u64
