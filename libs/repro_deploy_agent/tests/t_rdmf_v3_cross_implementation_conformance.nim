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
##   * the pin's system selection (flags bit 2) has one encoding per
##     selection on both sides: `addOn` with no activity, or naming
##     `default`, is the add-on mode's `default` only (flags 7, one digest);
##     `full` with none is the pin without a selection (flags 3); both
##     validators refuse the other spellings, and both decoders refuse
##     flags 5 (bit 2 without bit 1);
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
## `python-lists-default` runs a copy whose canonicalisation keeps `default`
## in the activity list (the spelling the agent once could not be given);
## its pin for `addOn` + `default` is then not the add-on default's, and the
## one-encoding case goes red.
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

proc listsDefaultProducer(src: string): string =
  ## The second falsifying mutation: Python's canonicalisation keeps
  ## `default`, and its validator lets it through, so `addOn` + `default`
  ## is signed as a selection of its own.
  var text = readFile(src)
  for (needle, repl) in [
      ("""a.strip() for a in activities if a.strip() and a.strip() != "default"}""",
       """a.strip() for a in activities if a.strip()}"""),
      ("""            if not a or a == "default":""", """            if not a:""")]:
    doAssert needle in text, "the mutation no longer matches the producer: " & needle
    text = text.replace(needle, repl)
  result = work / "render-deploy-manifest-lists-default.py"
  writeFile(result, text)

proc producer(): string =
  if mutation == "python-omits-closure-digests": mutatedProducer(producerPath)
  elif mutation == "python-lists-default": listsDefaultProducer(producerPath)
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

  test "a pin with a system selection: Python signs and binds it as this library does":
    let canon = work / "selected.canonical"
    let acts = work / "selected.actions"
    writeFile(canon, readFile(profile))
    writeFile(acts, "[]")
    let path = render("selected", @["--max-age-seconds", "3600",
      "--issued-at", $(now - 10), "--sequence", "12",
      "--compiled-canonical", canon, "--compiled-actions", acts,
      "--compile-platform", "linux", "--compile-arch", "x86_64",
      "--compile-host", "validator-01", "--compiler-revision", "abc123",
      "--compile-system-mode", "addOn",
      "--compile-system-activities", "vaultwarden,ethereum_validator"])
    let m = decodeManifest(cast[seq[byte]](readFile(path)))
    check verifyTrusted(m, anchors)
    check m.wireFlags == 7'u16   # attestations, pin, selection
    check m.compiledProfile.systemMode == "addOn"
    check m.compiledProfile.systemActivities ==
      @["ethereum_validator", "vaultwarden"]
    let sel = systemSelectionText(m.compiledProfile)
    check m.compiledProfile.digest ==
      compiledProfileDigest(readFile(profile), "[]", sel)
    # The selection is bound: the same compile pinned without it differs.
    check m.compiledProfile.digest != compiledProfileDigest(readFile(profile), "[]")
    check compiledProfileRefusal(m, readFile(profile), "[]", "abc123") == ""
    # A pin re-encoded here round-trips to the same bytes Python signed.
    check encodeManifest(m) == cast[seq[byte]](readFile(path))

  test "a selection has one encoding: addOn alone (or naming default) is the add-on default":
    # This library's canonicalisation, the producer-side half.
    check canonicalSystemSelection("addOn", []) == ("addOn", newSeq[string]())
    check canonicalSystemSelection("addOn", ["default"]) ==
      ("addOn", newSeq[string]())
    check canonicalSystemSelection("addOn", [" ", "web", "default", "web"]) ==
      ("addOn", @["web"])
    check canonicalSystemSelection("full", []) == ("", newSeq[string]())
    check canonicalSystemSelection("full", ["default"]) == ("", newSeq[string]())
    check canonicalSystemSelection("", ["b", "a"]) == ("full", @["a", "b"])
    check canonicalSystemSelection("", []) == ("", newSeq[string]())
    # Python renders every spelling of the add-on default; each verifies
    # here and is the same pin: flags 7, addOn with an empty list, and the
    # digest that frames exactly "addOn\n".
    let canon = work / "addon-default.canonical"
    let acts = work / "addon-default.actions"
    writeFile(canon, readFile(profile))
    writeFile(acts, "[]")
    proc renderSelection(name: string; selection: seq[string]): DeployManifest =
      let path = render(name, @["--max-age-seconds", "3600",
        "--issued-at", $(now - 10), "--sequence", "13",
        "--compiled-canonical", canon, "--compiled-actions", acts,
        "--compile-platform", "linux", "--compile-arch", "x86_64",
        "--compile-host", "addon-host-1", "--compiler-revision", "abc123"] &
        selection)
      result = decodeManifest(cast[seq[byte]](readFile(path)))
      check verifyTrusted(result, anchors)
      check encodeManifest(result) == cast[seq[byte]](readFile(path))
    let addOnDigest = compiledProfileDigest(readFile(profile), "[]", "addOn\n")
    let noSelection = compiledProfileDigest(readFile(profile), "[]")
    check addOnDigest != noSelection
    for (name, selection) in [
        ("addon-alone", @["--compile-system-mode", "addOn"]),
        ("addon-default", @["--compile-system-mode", "addOn",
                            "--compile-system-activities", "default"]),
        ("addon-blanks", @["--compile-system-mode", "addOn",
                           "--compile-system-activities", " ,default, "])]:
      checkpoint name
      let m = renderSelection(name, selection)
      check m.wireFlags == 7'u16
      check m.compiledProfile.systemMode == "addOn"
      check m.compiledProfile.systemActivities.len == 0
      check systemSelectionText(m.compiledProfile) == "addOn\n"
      check m.compiledProfile.digest == addOnDigest
      check compiledProfileRefusal(m, readFile(profile), "[]", "abc123") == ""
    # `full` alone, or naming only `default`, is the pin without a selection.
    for (name, selection) in [
        ("full-alone", @["--compile-system-mode", "full"]),
        ("full-default", @["--compile-system-mode", "full",
                           "--compile-system-activities", "default"])]:
      checkpoint name
      let m = renderSelection(name, selection)
      check m.wireFlags == 3'u16
      check not m.compiledProfile.hasSystemSelection
      check m.compiledProfile.digest == noSelection

  test "the other spellings are refused by both validators, and flags 5 by both decoders":
    var m = DeployManifest(target: Target, sequence: 20'u64,
      deploymentId: "non-canonical", profileText: "p", issuedAt: uint64(now),
      maxAgeSeconds: 600'u64)
    m.compiledProfile = CompiledProfilePin(digest: "sha256:" & repeat("ab", 32),
      compilerRevision: "r", platform: "linux", arch: "x86_64", host: "h")
    let probe = work / "pin_error_probe.py"
    writeFile(probe, "import importlib.util, sys\n" &
      "spec = importlib.util.spec_from_file_location('rdm', sys.argv[1])\n" &
      "mod = importlib.util.module_from_spec(spec); sys.modules['rdm'] = mod; spec.loader.exec_module(mod)\n" &
      "acts = sys.argv[3].split(',') if sys.argv[3] else []\n" &
      "p = mod.CompiledProfilePin(digest='sha256:' + 'ab' * 32, compilerRevision='r',\n" &
      "    platform='linux', arch='x86_64', host='h', systemMode=sys.argv[2], systemActivities=acts)\n" &
      "print(mod.compiled_profile_pin_error(p) or 'OK')\n")
    proc pyPinError(mode, acts: string): string =
      let r = execCmdEx(quoteShellCommand(@[python, "-I", probe, producer(), mode, acts]))
      check r.exitCode == 0
      r.output.strip()
    for (mode, acts, ok) in [("addOn", "", true), ("addOn", "web", true),
                             ("full", "web", true), ("full", "", false),
                             ("addOn", "default", false),
                             ("full", "default", false),
                             ("addOn", "default,web", false)]:
      checkpoint mode & " / " & acts
      m.compiledProfile.systemMode = mode
      m.compiledProfile.systemActivities =
        (if acts.len > 0: acts.split(',') else: @[])
      let nimErr = compiledProfilePinError(m.compiledProfile)
      check (nimErr.len == 0) == ok
      let pyErr = pyPinError(mode, acts)
      check (pyErr == "OK") == ok
      if not ok:
        check "non-canonical" in nimErr
        check "non-canonical" in pyErr
        # This library will neither sign nor encode such a pin.
        expect DeployManifestCodecError:
          signManifest(signer, m)
        expect DeployManifestCodecError:
          discard encodeManifest(m)
    # flags 5: the selection bit without the pin bit, which it extends.
    var plain = DeployManifest(target: Target, sequence: 21'u64,
      deploymentId: "flags-5", profileText: "p", issuedAt: uint64(now),
      maxAgeSeconds: 600'u64)
    signManifest(signer, plain)
    var bytes = encodeManifest(plain)
    check bytes[6] == 1'u8 and bytes[7] == 0'u8
    bytes[6] = 5'u8
    expect DeployManifestCodecError:
      discard decodeManifest(bytes)
    let f5 = work / "flags-5.rdm"
    writeFile(f5, cast[string](bytes))
    let d = py(@["inspect", "--manifest", f5])
    check d.code != 0
    check "flags word is 5" in d.output

  test "a real compiler: Python's pin is reproduced by a second compile here":
    let compiler = getEnv("RDMF_PROFILE_COMPILER")
    # Configured but unusable is a failure, never a skip: a measurement
    # that names a compiler must have compiled with it. Only an unset
    # RDMF_PROFILE_COMPILER skips, and RDMF_PROFILE_COMPILER_REQUIRED=1
    # turns that into a failure too.
    let usable = compiler.len > 0 and fileExists(compiler) and
      fpUserExec in getFilePermissions(compiler) and
      execCmdEx(quoteShellCommand(@[compiler, "--version"])).exitCode == 0
    if compiler.len == 0:
      check getEnv("RDMF_PROFILE_COMPILER_REQUIRED") != "1"
      echo "SKIPPED: no RDMF_PROFILE_COMPILER (the engine's reprobuild); the " &
        "compile determinism half is NOT checked here"
    elif not usable:
      checkpoint "RDMF_PROFILE_COMPILER=" & compiler & " is set but is not " &
        "an executable that answers --version"
      check usable
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
    # And with a system selection (flags bit 2).
    var ms = m
    ms.sequence = 10'u64
    ms.compiledProfile.systemMode = "full"
    ms.compiledProfile.systemActivities = @["backup", "web"]
    ms.compiledProfile.digest = compiledProfileDigest("canonical", "[]",
      systemSelectionText(ms.compiledProfile))
    signManifest(signer, ms)
    writeFile(work / "nim-selected.rdm", cast[string](encodeManifest(ms)))
    let rs = py(@["inspect", "--manifest", work / "nim-selected.rdm"])
    check rs.code == 0
    let js = parseJson(rs.output)
    check js["flags"].getInt == 7
    check js["signatureVerifies"].getBool
    check js["attestations"]["compiledProfile"]["systemMode"].getStr == "full"
    check js["attestations"]["compiledProfile"]["systemActivities"].len == 2
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

  test "an issuedAt of 2^63 or more is malformed in both codecs, never a crash":
    # The agent compares issuedAt with its clock in signed arithmetic. A
    # u64 above int64's range must be refused at decode -- before this it
    # decoded, and the freshness check overflowed (a RangeDefect, which no
    # tick handler catches).
    check MaxIssuedAt == uint64(high(int64))
    let atMax = render("issued-max", @["--max-age-seconds", "3600",
      "--issued-at", $high(int64), "--sequence", "13"])
    let okm = decodeManifest(cast[seq[byte]](readFile(atMax)))
    check okm.issuedAt == MaxIssuedAt
    let over = py(@["render", "--target", Target, "--profile", profile,
      "--signing-key", signerKey, "--state-dir", work / "state-issued-over",
      "--output", work / "issued-over.rdm", "--producer", "conformance",
      "--max-age-seconds", "3600", "--sequence", "13",
      "--issued-at", "9223372036854775808"])
    checkpoint over.output
    check over.code != 0
    check "issuedAt" in over.output
    check "Traceback" notin over.output
    var bad = okm
    bad.issuedAt = MaxIssuedAt + 1
    expect DeployManifestCodecError:
      discard encodeManifest(bad)
    # The same envelope with only the u64 field raised past int64 (its
    # signature no longer matters: the block is checked before it).
    var wire = readFile(atMax)
    let needle = "\xff\xff\xff\xff\xff\xff\xff\x7f"
    check wire.count(needle) == 1
    wire = wire.replace(needle, "\x00\x00\x00\x00\x00\x00\x00\x80")
    let overPath = work / "issued-over-patched.rdm"
    writeFile(overPath, wire)
    expect DeployManifestCodecError:
      discard decodeManifest(cast[seq[byte]](wire))
    var applied: seq[DeployManifest]
    let o = tickOf(overPath, anchors, now, applied)
    check o.kind == aoRejected
    check o.errorCode == "malformed_manifest"
    check applied.len == 0
    let pi = py(@["inspect", "--manifest", overPath])
    checkpoint pi.output
    check pi.code != 0
    check "Traceback" notin pi.output

  test "key lists: both readers accept and refuse exactly the same lines":
    let k = peerAuth.generateKeypair().publicKey
    let good = hexOf(k)
    let probe = work / "keys_grammar.py"
    writeFile(probe, "import importlib.util, sys\n" &
      "spec = importlib.util.spec_from_file_location('rdm', sys.argv[1])\n" &
      "mod = importlib.util.module_from_spec(spec); sys.modules['rdm'] = mod; spec.loader.exec_module(mod)\n" &
      "try:\n" &
      "    a = sorted(k.hex() for k in mod.load_trust_anchors(sys.argv[2]))\n" &
      "    r = sorted(k.hex() for k in mod.load_revoked_recipient_keys(sys.argv[2]))\n" &
      "    print('KEYS ' + ' '.join(a)); print('KEYS ' + ' '.join(r))\n" &
      "except mod.ManifestError as e:\n" &
      "    print('REFUSED ' + str(e))\n")
    proc pyReads(file: string): string =
      let r = execCmdEx(quoteShellCommand(@[python, "-I", probe, producer(), file]))
      checkpoint r.output
      check r.exitCode == 0
      r.output.strip()
    proc nimReads(file: string): string =
      try:
        var keys: seq[string]
        for x in peerAuth.loadTrustAnchors(file).publicKeys: keys.add(hexOf(x))
        keys.sort()
        discard loadRevokedRecipientKeys(file)
        "KEYS " & keys.join(" ")
      except CatchableError:
        "REFUSED"
    # A comment holding bytes that are not UTF-8 is still only a comment.
    let latin = work / "keys-latin1.txt"
    writeFile(latin, "# revoked (caf\xe9, \xff\xfe not UTF-8)\n" & good & "\n")
    check nimReads(latin) == "KEYS " & good
    check pyReads(latin) == "KEYS " & good & "\nKEYS " & good
    # Lines one side used to accept and the other refuse: spaces between
    # bytes (bytes.fromhex skips them), a 05 point prefix, and pairs that
    # Nim's parseHexInt read as hex ("_f", "#f").
    let spaced = good[0 ..< 64] & " " & good[64 ..< 126] & " " & good[126 .. ^1]
    var bads = @[("spaces", good[0 ..< 2] & " " & good[3 .. ^1]),
                 ("spaces-short", spaced[0 ..< 130]),
                 ("prefix-05", "05" & good[2 .. ^1]),
                 ("underscore", good[0 ..< 10] & "_f" & good[12 .. ^1]),
                 ("hash", good[0 ..< 10] & "#f" & good[12 .. ^1]),
                 ("0x", good[0 ..< 10] & "0x" & good[12 .. ^1])]
    for (name, line) in bads:
      let f = work / ("keys-bad-" & name & ".txt")
      writeFile(f, "# " & name & "\n" & line & "\n")
      checkpoint name
      check nimReads(f) == "REFUSED"
      check pyReads(f).startsWith("REFUSED")

  test "strings that are not UTF-8 round-trip through Python byte for byte":
    # The format's strings are bytes; Python's decoder reads them with
    # surrogateescape, and its encoder must write them back unchanged.
    var m = DeployManifest(target: Target, sequence: 14'u64,
      deploymentId: "nim-\xff\xfe-caf\xe9-14", profileText: "x\xff\n",
      issuedAt: uint64(now - 30), maxAgeSeconds: 900'u64)
    signManifest(signer, m)
    let path = work / "nim-bytes.rdm"
    writeFile(path, cast[string](encodeManifest(m)))
    let probe = work / "reencode-bytes.py"
    writeFile(probe, "import importlib.util, sys\n" &
      "spec = importlib.util.spec_from_file_location('rdm', sys.argv[1])\n" &
      "mod = importlib.util.module_from_spec(spec); sys.modules['rdm'] = mod; spec.loader.exec_module(mod)\n" &
      "buf = open(sys.argv[2], 'rb').read()\n" &
      "m, sig = mod.decode_manifest(buf)\n" &
      "print('IDENTICAL' if m.unsigned_prefix() + sig == buf else 'DIFFERENT')\n")
    let b = execCmdEx(quoteShellCommand(@[python, "-I", probe, producer(), path]))
    checkpoint b.output
    check b.exitCode == 0
    check b.output.strip() == "IDENTICAL"
    let v = py(@["inspect", "--manifest", path])
    checkpoint v.output
    check v.code == 0
    check parseJson(v.output)["signatureVerifies"].getBool

  test "a system selection without a compiled profile is refused by both producers":
    # Before, this library's encoder ignored a pin that held only a
    # selection (the pin counted as absent) and signed the envelope
    # without it, while Python refuses the pin for its missing digest.
    var m = DeployManifest(target: Target, sequence: 15'u64,
      deploymentId: "nim-15", profileText: "x\n",
      issuedAt: uint64(now - 30), maxAgeSeconds: 900'u64,
      compiledProfile: CompiledProfilePin(systemMode: "addOn",
        systemActivities: @["web"]))
    check m.hasCompiledProfilePin
    # Signing encodes the prefix, so the refusal comes there already.
    expect DeployManifestCodecError:
      signManifest(signer, m)
    expect DeployManifestCodecError:
      discard encodeManifest(m)
    let probe = work / "selection_only.py"
    writeFile(probe, "import importlib.util, sys\n" &
      "spec = importlib.util.spec_from_file_location('rdm', sys.argv[1])\n" &
      "mod = importlib.util.module_from_spec(spec); sys.modules['rdm'] = mod; spec.loader.exec_module(mod)\n" &
      "p = mod.CompiledProfilePin(digest='', compilerRevision='', platform='', arch='', host='', systemMode='addOn', systemActivities=['web'])\n" &
      "print('REFUSED' if mod.compiled_profile_pin_error(p) else 'ACCEPTED')\n")
    let r = execCmdEx(quoteShellCommand(@[python, "-I", probe, producer()]))
    checkpoint r.output
    check r.exitCode == 0
    check r.output.strip() == "REFUSED"

removeDir(work)
