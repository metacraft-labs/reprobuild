## RDMF v3: the two producers and this agent agree byte for byte.
##
## There are two implementations of the `RDMF` format: this library (producer
## and consumer) and an independent Python producer with its own decoder
## (`render-deploy-manifest.py`, kept with the deployment that serves the
## manifests). A round trip inside either one proves nothing about the other:
## a shared misreading of the layout would pass both. So this test makes each
## side read what the other wrote:
##
##   * Python renders and signs v3 manifests -- the attestation block with a
##     closure digest that matches an output and one that does not, a fresh
##     and a stale `issuedAt`, a rollback floor -- and this library decodes,
##     verifies and runs the agent's checks over them;
##   * this library renders and signs a v3 manifest with every field and a
##     sealed section, and the Python decoder reads it back, re-encodes the
##     prefix it read, and verifies the signature over it;
##   * one recipient-key rotation: Python seals to the new key, which opens
##     it, and the old key does not;
##   * a revoked recipient key: BOTH producers refuse to seal to it, given
##     the same list file;
##   * a key list with UTF-8 comments and a byte-order mark reads as the same
##     keys on both sides (the 2026-10-31 producer outage);
##   * the compiled-profile pin (flags bit 1): Python pins the digest of a
##     compile, this library computes the same digest over the same two
##     texts and refuses a compile that emitted anything else; and, given a
##     real profile compiler (`RDMF_PROFILE_COMPILER`, the engine's
##     `reprobuild`), Python compiles a source profile with it and this test
##     compiles the same source again, in another directory, and reproduces
##     the pin (`RDMF_PROFILE_COMPILER_REQUIRED=1` makes its absence a
##     failure).
##
## Where the Python producer comes from: `RDMF_PYTHON_PRODUCER` (the script)
## and `RDMF_PYTHON` (an interpreter with the `cryptography` package). When
## the producer is not available the test says so and passes, unless
## `RDMF_CONFORMANCE_REQUIRED=1` -- set by every gate run -- in which case its
## absence is a failure (a conformance check that silently checked nothing
## would be worse than none).
##
## Falsifying mutation (the gate's): `RDMF_CONFORMANCE_MUTATION=
## python-omits-closure-digests` runs a copy of the Python producer whose
## signed prefix leaves the closure digests out (the transformation is
## below, `mutatedProducer`); every manifest it renders must then be refused
## by this decoder, so the matching-digest case fails and the test goes red.
##
## Mocks: none. The apply hook is a recording closure because what is under
## test is the agent's verdict on the manifest, not an apply; every byte on
## the wire is produced and read by the real implementations, with real
## ECDSA-P256 keys and real ECIES seals.

import std/[algorithm, json, os, osproc, sets, strutils, times, unittest]

import repro_deploy_agent
import repro_deploy_agent/secrets
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const Target = "addon-host-1"
const DigestA = "blake3:" & repeat("a1", 32)
const DigestB = "blake3:" & repeat("b2", 32)

proc hexOf(b: openArray[byte]): string =
  for x in b: result.add(toHex(int(x), 2).toLowerAscii())

proc findProducer(): string =
  result = getEnv("RDMF_PYTHON_PRODUCER")
  if result.len > 0: return
  # A workspace that checks the deployment repository out beside this one.
  var dir = currentSourcePath().parentDir()
  for _ in 0 .. 8:
    let cand = dir / "infra" / "services" / "repro-deploy-manifest" /
               "render-deploy-manifest.py"
    if fileExists(cand): return cand
    dir = dir.parentDir()
  result = ""

let producerPath = findProducer()
let python = getEnv("RDMF_PYTHON", "python3")
let required = getEnv("RDMF_CONFORMANCE_REQUIRED") == "1"
let mutation = getEnv("RDMF_CONFORMANCE_MUTATION")
let work = getTempDir() / ("rdmf-v3-conformance-" & $getCurrentProcessId())

proc mutatedProducer(src: string): string =
  ## The falsifying mutation: the Python producer's signed prefix without
  ## the closure digests (the count and the entries).
  var text = readFile(src)
  let needle = """                out += _u32(len(self.closureDigests))
                for d in self.closureDigests:
                    out += _text(d.actionId)
                    out += _text(d.digest)
"""
  doAssert needle in text, "the mutation no longer matches the producer"
  text = text.replace(needle, "")
  # Its own self-check would refuse what it now writes; the mutation is of
  # the encoder, so the check is bypassed the same way.
  text = text.replace("    decoded, decoded_sig = decode_manifest(envelope)\n",
    "    return _mutated_publish(args, envelope, sequence, digest, deployment_id, pubkey, manifest)\n    decoded, decoded_sig = decode_manifest(envelope)\n")
  text.add("""

def _mutated_publish(args, envelope, sequence, digest, deployment_id, pubkey, manifest):
    _atomic_write(args.output, envelope)
    _write_state(args.state_dir, args.target, {"sequence": sequence, "digest": digest,
        "deploymentId": deployment_id, "producerPubKey": pubkey.hex(),
        "issuedAt": manifest.issuedAt})
    return 0
""")
  result = work / "render-deploy-manifest-mutated.py"
  writeFile(result, text)

proc producer(): string =
  if mutation == "python-omits-closure-digests": mutatedProducer(producerPath)
  elif mutation.len > 0:
    raise newException(ValueError, "unknown RDMF_CONFORMANCE_MUTATION " & mutation)
  else: producerPath

proc py(args: seq[string]): tuple[output: string; code: int] =
  let cmd = quoteShellCommand(@[python, "-I", producer()] & args)
  let r = execCmdEx(cmd)
  (r.output, r.exitCode)

proc writeKey(path: string; kp: PeerKeypair) =
  writeFile(path, "ecdsa-p256:" & hexOf(kp.privateKey) & "\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite})

var tickCount = 0

proc tickOf(manifestPath: string; anchors: TrustAnchors; now: int64;
            applied: var seq[DeployManifest]): AgentOutcome =
  # A fresh agent per tick: two ticks in one second must not share the
  # agent's state (its last accepted issuedAt among it).
  inc tickCount
  let stateDir = work / ("agent-" & $tickCount)
  createDir(stateDir)
  let cfg = AgentConfig(target: Target, sources: @[manifestPath],
    anchors: anchors, stateDir: stateDir, requireAttestations: true)
  var seen: seq[DeployManifest]
  var deps: AgentDeps
  deps.apply = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    {.cast(gcsafe).}:
      seen.add(m)
    (true, "recorded")
  deps.nowUnix = proc(): int64 {.gcsafe.} = now
  result = runAgentTick(cfg, deps)
  applied.add(seen)

if producerPath.len == 0 or not fileExists(producerPath):
  if required:
    echo "FAIL: RDMF_CONFORMANCE_REQUIRED=1 but no Python producer was found " &
      "(set RDMF_PYTHON_PRODUCER)"
    quit(1)
  echo "SKIPPED: no Python RDMF producer (set RDMF_PYTHON_PRODUCER and " &
    "RDMF_PYTHON); the cross-implementation half is NOT checked here"
  quit(0)

createDir(work)
let signer = peerAuth.generateKeypair()
let signerKey = work / "signer.key"
writeKey(signerKey, signer)
let anchors = anchorsFromKeypairs([signer.publicKey])
let profile = work / "profile.txt"
writeFile(profile, "fs.systemFile {\n  path = \"/etc/repro-conformance\"\n" &
  "  content = \"x\"\n}\n")
let revokedKey = peerAuth.generateKeypair()
let revokedList = work / "revoked-recipient-keys.txt"
writeFile(revokedList, "# revoked\n" & hexOf(revokedKey.publicKey) & "\n")
let emptyRevoked = work / "revoked-none.txt"
writeFile(emptyRevoked, "# none\n")

proc render(name: string; extra: seq[string]): string =
  result = work / (name & ".rdm")
  let r = py(@["render", "--target", Target, "--profile", profile,
    "--signing-key", signerKey, "--state-dir", work / ("state-" & name),
    "--output", result, "--producer", "conformance"] & extra)
  if r.code != 0:
    raise newException(IOError, "python render " & name & " failed: " & r.output)

suite "RDMF v3 cross-implementation conformance":
  let now = getTime().toUnix()

  test "Python v3 with a matching closure digest verifies and applies here":
    let path = render("matching", @["--max-age-seconds", "3600",
      "--issued-at", $(now - 10), "--rollback-floor", "1", "--sequence", "4",
      "--closure-digest", "prefix-b=" & DigestB,
      "--closure-digest", "prefix-a=" & DigestA])
    let m = decodeManifest(cast[seq[byte]](readFile(path)))
    check m.formatVersion == 3'u16
    check m.hasAttestations
    check m.issuedAt == uint64(now - 10)
    check m.maxAgeSeconds == 3600'u64
    check m.rollbackFloor == 1'u64
    check m.closureDigests == @[ClosureDigest(actionId: "prefix-a", digest: DigestA),
                                ClosureDigest(actionId: "prefix-b", digest: DigestB)]
    check verifyTrusted(m, anchors)
    check closureDigestRefusal(m, "prefix-a", DigestA) == ""
    check closureDigestRefusal(m, "prefix-b", DigestB) == ""
    var applied: seq[DeployManifest]
    let o = tickOf(path, anchors, now, applied)
    check o.kind == aoApplied
    check applied.len == 1

  test "Python v3 whose pinned digest does not match the output is refused":
    let path = render("mismatching", @["--max-age-seconds", "3600",
      "--issued-at", $(now - 10), "--sequence", "5",
      "--closure-digest", "prefix-a=" & DigestB])
    let m = decodeManifest(cast[seq[byte]](readFile(path)))
    check verifyTrusted(m, anchors)
    # The output actually has DigestA; the producer pinned DigestB.
    check "closure digest mismatch" in closureDigestRefusal(m, "prefix-a", DigestA)

  test "Python v3 past its maximum age is aoStale here; a fresh one is not":
    let stale = render("stale", @["--max-age-seconds", "600",
      "--issued-at", $(now - 3600), "--sequence", "6"])
    var applied: seq[DeployManifest]
    let o = tickOf(stale, anchors, now, applied)
    check o.kind == aoStale
    check applied.len == 0
    check deployAgentExitCode(o.kind) == 2
    let fresh = render("fresh", @["--max-age-seconds", "600",
      "--issued-at", $(now - 60), "--sequence", "6"])
    let o2 = tickOf(fresh, anchors, now, applied)
    check o2.kind == aoApplied

  test "a v2 manifest from Python is refused by an agent that requires v3":
    let recipient = peerAuth.generateKeypair()
    let pubFile = work / "recipient-v2.pub"
    writeFile(pubFile, hexOf(recipient.publicKey) & "\n")
    let secret = work / "secret-v2"
    writeFile(secret, "s3cret")
    let path = render("v2", @["--recipient-pubkey", pubFile,
      "--revoked-recipient-keys", emptyRevoked, "--secret", "web/token=" & secret])
    let m = decodeManifest(cast[seq[byte]](readFile(path)))
    check m.formatVersion == 2'u16
    var applied: seq[DeployManifest]
    let o = tickOf(path, anchors, now, applied)
    check o.kind == aoRejected
    check o.errorCode == "attestations_required"
    check applied.len == 0

  test "one rotation: Python seals to the new key, which opens it; the old does not":
    let oldKey = peerAuth.generateKeypair()
    let newKey = peerAuth.generateKeypair()
    let pubFile = work / "recipient-new.pub"
    writeFile(pubFile, hexOf(newKey.publicKey) & "\n")
    let secret = work / "secret-rot"
    writeFile(secret, "rotated-secret")
    let path = render("rotation", @["--max-age-seconds", "3600",
      "--issued-at", $(now - 5), "--sequence", "7",
      "--recipient-pubkey", pubFile, "--revoked-recipient-keys", emptyRevoked,
      "--secret", "web/token=" & secret])
    let m = decodeManifest(cast[seq[byte]](readFile(path)))
    check m.formatVersion == 3'u16 and m.hasSecrets
    check verifyTrusted(m, anchors)
    let files = openSecrets(newKey.privateKey, Target, m.secrets)
    check files.len == 1 and files[0].path == "web/token"
    check cast[string](files[0].content) == "rotated-secret"
    expect SecretsError:
      discard openSecrets(oldKey.privateKey, Target, m.secrets)

  test "a revoked recipient key: both producers refuse to seal to it":
    let pubFile = work / "recipient-revoked.pub"
    writeFile(pubFile, hexOf(revokedKey.publicKey) & "\n")
    let secret = work / "secret-rev"
    writeFile(secret, "never-sealed")
    let output = work / "revoked.rdm"
    let r = py(@["render", "--target", Target, "--profile", profile,
      "--signing-key", signerKey, "--state-dir", work / "state-revoked",
      "--output", output, "--max-age-seconds", "3600",
      "--recipient-pubkey", pubFile, "--revoked-recipient-keys", revokedList,
      "--secret", "web/token=" & secret])
    check r.code != 0
    check "revoked recipient-key list" in r.output
    check not fileExists(output)
    # Without the list the Python producer will not seal at all.
    let r2 = py(@["render", "--target", Target, "--profile", profile,
      "--signing-key", signerKey, "--state-dir", work / "state-revoked2",
      "--output", output, "--recipient-pubkey", pubFile,
      "--secret", "web/token=" & secret])
    check r2.code != 0
    check "--revoked-recipient-keys" in r2.output
    # The same list file, through this library's producer.
    let list = loadRevokedRecipientKeys(revokedList)
    check list.isRevoked(revokedKey.publicKey)
    expect RecipientKeyRevoked:
      discard sealSecrets(revokedKey.publicKey, Target,
        @[SecretFile(path: "web/token", mode: 0o400,
                     content: cast[seq[byte]]("never-sealed"))], list)
    # A key that is not on it still seals.
    let other = peerAuth.generateKeypair()
    discard sealSecrets(other.publicKey, Target,
      @[SecretFile(path: "web/token", mode: 0o400,
                   content: cast[seq[byte]]("ok"))], list)

  test "Python's compiled-profile pin is the digest this library computes; another compile is refused":
    let canon = work / "compiled.canonical"
    let acts = work / "compiled.actions"
    writeFile(canon, readFile(profile))
    writeFile(acts, "[]")
    let path = render("compiled", @["--max-age-seconds", "3600",
      "--issued-at", $(now - 10), "--sequence", "10",
      "--compiled-canonical", canon, "--compiled-actions", acts,
      "--compile-platform", "linux", "--compile-arch", "arm32",
      "--compile-host", "rpi2", "--compiler-revision", "abc123"])
    let m = decodeManifest(cast[seq[byte]](readFile(path)))
    check verifyTrusted(m, anchors)
    check m.compiledProfile.digest == compiledProfileDigest(readFile(profile), "[]")
    check m.compiledProfile.platform == "linux"
    check m.compiledProfile.arch == "arm32"
    check m.compiledProfile.host == "rpi2"
    check m.compiledProfile.compilerRevision == "abc123"
    check compiledProfileRefusal(m, readFile(profile), "[]", "abc123") == ""
    let evil = readFile(profile) & "systemd.systemUnit {}\n"
    check "digest mismatch" in compiledProfileRefusal(m, evil, "[]", "abc123")
    check "digest mismatch" in compiledProfileRefusal(m, readFile(profile),
      "[{\"id\":\"x\"}]", "abc123")
    check CompilerRevisionMismatch in compiledProfileRefusal(m,
      readFile(profile), "[]", "def456")

  test "a real compiler: Python's pin is reproduced by a second compile here":
    let compiler = getEnv("RDMF_PROFILE_COMPILER")
    if compiler.len == 0:
      check getEnv("RDMF_PROFILE_COMPILER_REQUIRED") != "1"
      echo "SKIPPED: no RDMF_PROFILE_COMPILER (the engine's reprobuild); the " &
        "compile determinism half is NOT checked here"
    else:
      let src = work / "source.nim"
      writeFile(src, "import repro_profile\n\nprofile \"conformance\":\n" &
        "  resources:\n    fsSystemFile(path = \"/etc/repro-conformance\", " &
        "content = \"x\\n\",\n      address = \"conf\")\n")
      let r = py(@["render", "--target", Target, "--profile", src,
        "--signing-key", signerKey, "--state-dir", work / "state-real",
        "--output", work / "real.rdm", "--producer", "conformance",
        "--max-age-seconds", "3600", "--sequence", "11",
        "--profile-compiler", compiler, "--compile-platform", "linux",
        "--compile-arch", "x86_64", "--compile-host", "conformance-host"])
      check r.code == 0
      let m = decodeManifest(cast[seq[byte]](readFile(work / "real.rdm")))
      let again = work / "again"
      createDir(again / "src")
      let module = stageProfileSources(again / "src", m.profileText,
                                       m.profileFiles)
      let c = execCmdEx(quoteShellCommand(@[compiler, "deploy-agent",
        "compile-profile", "--staged", module, "--canonical-out",
        again / "c", "--actions-out", again / "a", "--state-dir",
        again / "state", "--host", m.compiledProfile.host, "--platform",
        m.compiledProfile.platform, "--arch", m.compiledProfile.arch,
        "--revision-out", again / "r"]))
      check c.exitCode == 0
      check m.compiledProfile.compilerRevision ==
        readFile(again / "r").strip()
      check compiledProfileRefusal(m, readFile(again / "c"),
        readFile(again / "a"), readFile(again / "r").strip()) == ""

  test "key lists with UTF-8 comments read the same in both (the 2026-10-31 incident)":
    # infra's committed revoked-keys file carries "§10.3" in a comment; the
    # Python producer opened it as ASCII and every render failed. Both
    # sides must read such a file -- and one with a byte-order mark -- as
    # the same set of keys.
    let k1 = peerAuth.generateKeypair().publicKey
    let k2 = peerAuth.generateKeypair().publicKey
    let listFile = work / "utf8-keys.txt"
    writeFile(listFile, "\xEF\xBB\xBF# revoked (ReproOS Add-On Mode §10.3, CRED-2)\n" &
      "# naïve café — “quoted” ✓\n" & hexOf(k1) & "\r\n  # ✓ indented\n" &
      hexOf(k2) & "\n")
    var nimKeys: seq[string]
    for k in peerAuth.loadTrustAnchors(listFile).publicKeys: nimKeys.add(hexOf(k))
    nimKeys.sort()
    check nimKeys.len == 2
    let revoked = loadRevokedRecipientKeys(listFile)
    check revoked.isRevoked(k1) and revoked.isRevoked(k2)
    let probe = work / "keys_probe.py"
    writeFile(probe, "import importlib.util, sys\n" &
      "spec = importlib.util.spec_from_file_location('rdm', sys.argv[1])\n" &
      "mod = importlib.util.module_from_spec(spec); sys.modules['rdm'] = mod; spec.loader.exec_module(mod)\n" &
      "a = sorted(k.hex() for k in mod.load_trust_anchors(sys.argv[2]))\n" &
      "r = sorted(k.hex() for k in mod.load_revoked_recipient_keys(sys.argv[2]))\n" &
      "print(' '.join(a)); print(' '.join(r))\n")
    let p = execCmdEx(quoteShellCommand(@[python, "-I", probe, producer(), listFile]))
    checkpoint p.output
    check p.exitCode == 0
    let lines = p.output.strip().splitLines()
    check lines.len == 2
    if lines.len == 2:
      check lines[0] == nimKeys.join(" ")
      check lines[1] == nimKeys.join(" ")

  test "this library's v3 manifest decodes in Python, byte for byte":
    let recipient = peerAuth.generateKeypair()
    var m = DeployManifest(target: Target, sequence: 9'u64,
      deploymentId: "nim-9", profileText: readFile(profile),
      profileFiles: @[ProfileFile(path: "locks/a.lock", content: "lock\n")],
      issuedAt: uint64(now - 30), maxAgeSeconds: 900'u64, rollbackFloor: 8'u64,
      closureDigests: @[ClosureDigest(actionId: "prefix-a", digest: DigestA),
                        ClosureDigest(actionId: "prefix-b", digest: DigestB)],
      compiledProfile: CompiledProfilePin(
        digest: compiledProfileDigest("canonical", "[]"),
        compilerRevision: "nim-rev", platform: "linux",
        arch: "x86_64", host: "nim-host"),
      buildActions: @[], hasSecrets: true,
      secrets: sealSecrets(recipient.publicKey, Target,
        @[SecretFile(path: "web/token", mode: 0o400,
                     content: cast[seq[byte]]("nim-sealed"))],
        loadRevokedRecipientKeys(emptyRevoked)))
    signManifest(signer, m)
    let wire = encodeManifest(m)
    let path = work / "nim.rdm"
    writeFile(path, cast[string](wire))
    let r = py(@["inspect", "--manifest", path])
    check r.code == 0
    let j = parseJson(r.output)
    check j["formatVersion"].getInt == 3
    check j["flags"].getInt == 3
    check j["attestations"]["compiledProfile"]["digest"].getStr ==
      compiledProfileDigest("canonical", "[]")
    check j["attestations"]["compiledProfile"]["host"].getStr == "nim-host"
    check j["attestations"]["compiledProfile"]["compilerRevision"].getStr ==
      "nim-rev"
    check j["sequence"].getInt == 9
    check j["signatureVerifies"].getBool
    check j["attestations"]["issuedAt"].getBiggestInt == now - 30
    check j["attestations"]["maxAgeSeconds"].getInt == 900
    check j["attestations"]["rollbackFloor"].getInt == 8
    check j["attestations"]["closureDigests"].len == 2
    check j["attestations"]["closureDigests"][0]["digest"].getStr == DigestA
    check j["sealedSecrets"]["present"].getBool
    let anchorsFile = work / "anchors.txt"
    writeFile(anchorsFile, hexOf(signer.publicKey) & "\n")
    let v = py(@["verify", "--manifest", path, "--allowed-signers", anchorsFile,
                 "--target", Target])
    check v.code == 0
    # Byte for byte: Python's own encoder, fed what its decoder read, emits
    # exactly the bytes this library signed.
    let probe = work / "reencode.py"
    writeFile(probe, "import importlib.util, sys\n" &
      "spec = importlib.util.spec_from_file_location('rdm', sys.argv[1])\n" &
      "mod = importlib.util.module_from_spec(spec); sys.modules['rdm'] = mod; spec.loader.exec_module(mod)\n" &
      "buf = open(sys.argv[2], 'rb').read()\n" &
      "m, sig = mod.decode_manifest(buf)\n" &
      "print('IDENTICAL' if m.unsigned_prefix() + sig == buf else 'DIFFERENT')\n")
    let b = execCmdEx(quoteShellCommand(@[python, "-I", probe, producer(), path]))
    check b.exitCode == 0
    check b.output.strip() == "IDENTICAL"

removeDir(work)
