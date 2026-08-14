## Deploy agent — sealed-secrets tick gate.
##
## `secrets.nim` and the v2 envelope are proven separately. This proves the
## TICK behaviour, where the ordering matters more than the crypto:
##
##   * secrets are on disk BEFORE the apply hook runs, because the apply is
##     what consumes them (`register-runner.ps1` reads the token);
##   * a sealed section the agent cannot open does NOT fall through to the
##     apply, and does NOT advance the monotonic floor -- converging desired
##     state whose secrets never arrived yields a box that looks applied and
##     cannot run a job;
##   * a v1 manifest still applies untouched on an agent configured with a
##     key, so enabling this on a box does not disturb targets without
##     secrets.
##
## The apply hook is `{.gcsafe.}`, so the recording state it touches lives at
## module scope behind a `cast(gcsafe)` rather than being captured.

import std/[os, strutils, unittest]

import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../src/repro_deploy_agent/agent
import ../src/repro_deploy_agent/manifest
import ../src/repro_deploy_agent/secrets

var gApplyRan = false
var gTokenSeenByApply = ""
var gSecretsDir = ""

proc recordingApply(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
  {.cast(gcsafe).}:
    gApplyRan = true
    let p = gSecretsDir / "mcl.token"
    if fileExists(p):
      gTokenSeenByApply = readFile(p)
  (ok: true, message: "applied")

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc hexOf(priv: peerAuth.PrivateKeyBytes): string =
  result = ""
  for b in priv:
    result.add(toHex(int(b), 2).toLowerAscii)

type Harness = object
  root: string
  secretsDir: string
  sourcePath: string
  producer: peerAuth.PeerKeypair
  recipient: peerAuth.PeerKeypair
  cfg: AgentConfig

proc newHarness(name: string; withKey: bool): Harness =
  result.root = getTempDir() / ("rdmf-secrets-" & name & "-" &
                                $getCurrentProcessId())
  removeDir(result.root)
  createDir(result.root)
  result.secretsDir = result.root / "secrets"
  result.sourcePath = result.root / "latest.rdm"
  result.producer = peerAuth.generateKeypair()
  result.recipient = peerAuth.generateKeypair()
  let keyPath = result.root / "recipient.key"
  if withKey:
    writeFile(keyPath, "ecdsa-p256:" & hexOf(result.recipient.privateKey) & "\n")
  result.cfg = AgentConfig(
    target: "win-ci-bare-001",
    sources: @[result.sourcePath],
    anchors: anchorsFromKeypairs([result.producer.publicKey]),
    stateDir: result.root / "state",
    fetchTimeoutMs: 5000,
    secretsKeyPath: (if withKey: keyPath else: ""),
    secretsDir: (if withKey: result.secretsDir else: ""))
  gApplyRan = false
  gTokenSeenByApply = ""
  gSecretsDir = result.secretsDir

proc writeManifest(h: Harness; sequence: uint64; withSecrets: bool;
                   sealTo: peerAuth.PublicKeyBytes) =
  var m = DeployManifest(
    target: h.cfg.target,
    sequence: sequence,
    deploymentId: "deployment-" & $sequence,
    profileText: "profile \"x\":\n  resources:\n    discard\n")
  if withSecrets:
    m.hasSecrets = true
    m.secrets = sealSecrets(sealTo, h.cfg.target,
      @[SecretFile(path: "mcl.token", mode: 0o600'u32,
                   content: bytesOf("REGISTRATION-TOKEN-" & $sequence))])
  signManifest(h.producer, m)
  var wire = newString(0)
  for b in encodeManifest(m):
    wire.add(char(b))
  writeFile(h.sourcePath, wire)

let deps = AgentDeps(apply: recordingApply)

suite "deploy agent materialises sealed secrets":

  test "secrets land on disk BEFORE the apply hook runs":
    let h = newHarness("order", withKey = true)
    h.writeManifest(7'u64, withSecrets = true, sealTo = h.recipient.publicKey)

    let outcome = runAgentTick(h.cfg, deps)
    check outcome.kind == aoApplied
    check gTokenSeenByApply == "REGISTRATION-TOKEN-7"
    check readFile(h.secretsDir / "mcl.token") == "REGISTRATION-TOKEN-7"

  test "a rotated secret overwrites the previous one":
    let h = newHarness("rotate", withKey = true)

    h.writeManifest(1'u64, withSecrets = true, sealTo = h.recipient.publicKey)
    check runAgentTick(h.cfg, deps).kind == aoApplied
    check readFile(h.secretsDir / "mcl.token") == "REGISTRATION-TOKEN-1"

    h.writeManifest(2'u64, withSecrets = true, sealTo = h.recipient.publicKey)
    check runAgentTick(h.cfg, deps).kind == aoApplied
    check readFile(h.secretsDir / "mcl.token") == "REGISTRATION-TOKEN-2"

  test "an unopenable sealed section does not apply and does not advance":
    # Sealed to somebody else: the box holds the wrong recipient key.
    let h = newHarness("wrongkey", withKey = true)
    let stranger = peerAuth.generateKeypair()
    h.writeManifest(9'u64, withSecrets = true, sealTo = stranger.publicKey)

    let outcome = runAgentTick(h.cfg, deps)
    check outcome.kind == aoSecretsFailed
    check outcome.errorCode == "secrets_failed"
    check not gApplyRan
    check not fileExists(h.secretsDir / "mcl.token")
    # The monotonic floor must be untouched, so a corrected manifest at the
    # SAME sequence can still be applied later.
    check readLastAppliedSequence(h.cfg) == 0'u64

  test "secrets with no configured key is a hard failure, not a silent apply":
    let h = newHarness("nokey", withKey = false)
    h.writeManifest(3'u64, withSecrets = true, sealTo = h.recipient.publicKey)

    let outcome = runAgentTick(h.cfg, deps)
    check outcome.kind == aoSecretsFailed
    check outcome.errorCode == "secrets_not_configured"
    check not gApplyRan
    check readLastAppliedSequence(h.cfg) == 0'u64

  test "a v1 manifest still applies on a secrets-configured agent":
    let h = newHarness("v1", withKey = true)
    h.writeManifest(5'u64, withSecrets = false, sealTo = h.recipient.publicKey)

    let outcome = runAgentTick(h.cfg, deps)
    check outcome.kind == aoApplied
    check gApplyRan
