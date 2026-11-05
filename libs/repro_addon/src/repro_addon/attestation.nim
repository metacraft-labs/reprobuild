## The signed GENERATION attestation an add-on host puts in its evidence
## records.
##
## WHAT IT IS. A statement, signed with a key generated on the host at
## bootstrap, of what the add-on itself activated: the generation it runs,
## the digest of that generation's ledger and of the profile text it
## applied, the deploy manifest it came from (sequence, ``deploymentId``,
## the producer-side profile digest and the closure digests that manifest
## pinned) and the digest of the add-on binary bootstrap installed. An
## off-host checker compares it with what the producer published for the
## same sequence (``evidence_check``): a generation modified locally, by
## anything that does not hold the attestation key, shows as a mismatch.
##
## WHAT IT IS NOT. It is never host attestation, and nothing here may name
## or present it as such. The kernel, the bootloader and every file the
## distribution's package manager owns (``/usr`` among them) are outside
## anything the add-on measures; a host whose base is compromised signs
## whatever the attacker likes with this key, and so does root on the
## host, which can read the key (threat model deviation D4). Every
## statement therefore carries its scope (``reprobuild.addon.generation-
## attestation.v1``) and what it does not cover (``notCovered``), and the
## record field is ``attestation`` beside a ``kind`` that is never
## ``host``. Remote attestation of a whole host is a full-ReproOS story.
##
## FORMAT. The statement is canonical text -- ``key=value`` lines in a fixed
## order, values free of line breaks -- so the signer and every verifier
## hash the same bytes. The signature is ECDSA-P256 over the SHA-256 of
## those bytes (``repro_peer_cache/auth.signMessage``), the same primitive
## that signs deploy manifests.

import std/[algorithm, os, strutils]

import repro_infra
import repro_peer_cache/auth as peerAuth
import repro_peer_cache/key_types
import repro_deploy_agent/manifest
import repro_deploy_agent/secrets

import ./agent_record
import ./fingerprint
import ./generation0
import ./mutations

const
  AttestationScope* = "reprobuild.addon.generation-attestation.v1"
    ## The statement's first line. A verifier refuses any other.
  AttestationNotCovered* = "kernel bootloader distribution-packages"
    ## What the attestation does NOT cover, carried in every statement so
    ## that no reader can take it for host attestation.
  GenerationLedgerName* = "addon-ledger"
    ## Under ``generations/<id>/``: the ledger the generation committed.
  GenerationUserProfileName* = "addon-user.profile"
    ## Under ``generations/<id>/``: the profile text the generation applied.
  BootstrapEvidenceName* = "bootstrap-evidence.json"
    ## Under ``<state dir>/addon/``: bootstrap's own record, which names the
    ## digest of the binary it installed.

type
  GenerationAttestation* = object
    host*: string
    generation*: string
    ledgerDigest*: string          ## ``sha256:<hex>`` of the generation's ledger
    profileDigest*: string         ## ``sha256:<hex>`` of the profile it applied
    sequence*: uint64              ## the deploy manifest's; 0 for an operator's
    deploymentId*: string
    manifestProfileDigest*: string
      ## The producer-side digest the apply verified the profile against:
      ## ``sha256:<hex>`` of a canonical ``profileText``, or the manifest's
      ## compiled-profile pin for a source profile. "" for an operator's.
    closuresDigest*: string
      ## ``closureDigestsDigest`` of the manifest's pinned closures; "" for
      ## an operator's apply.
    bootstrapDigest*: string       ## SHA-256 of the add-on binary bootstrap ran

  SignedAttestation* = object
    statement*: string             ## the canonical text that was signed
    signature*: string             ## hex (r || s)
    publicKey*: string             ## hex, uncompressed P-256

  AttestationError* = object of CatchableError

proc sha256Tagged(data: string): string = "sha256:" & sha256Hex(data)

proc closureDigestsDigest*(closures: openArray[ClosureDigest]): string =
  ## One digest for the closure set a manifest pins: ``sha256:`` of its
  ## ``<actionId> <digest>`` lines, sorted. "" for none. The producer side
  ## (``evidence_check``) derives the same value from the manifest.
  if closures.len == 0: return ""
  var lines: seq[string]
  for c in closures: lines.add(c.actionId & " " & c.digest)
  lines.sort()
  sha256Tagged(lines.join("\n") & "\n")

proc manifestProfileDigestOf*(m: DeployManifest): string =
  ## What an apply of ``m`` verifies its profile against, as the producer
  ## publishes it: the signed text's own digest when the profile ships as
  ## canonical text, otherwise the compiled-profile pin (the apply refuses a
  ## compile with any other digest, ``agent_checks.compiledProfileCheck``).
  if m.compiledProfile.digest.len > 0: m.compiledProfile.digest
  else: sha256Tagged(m.profileText)

proc oneLine(v, what: string): string =
  ## A value never spans lines: the statement is one ``key=value`` per line
  ## and is split at the first ``=``, so ``=`` inside a value is harmless.
  if v.find({'\n', '\r'}) >= 0:
    raise newException(AttestationError, what & " holds a line break")
  v

proc statement*(a: GenerationAttestation): string =
  ## The canonical text that is signed.
  when mutated("attestation-claims-host"):
    # FALSIFYING BUILD: presented as host attestation, with nothing said
    # about what it does not cover.
    result = "scope=reprobuild.host-attestation.v1\n"
  else:
    result = "scope=" & AttestationScope & "\n"
    result.add("notCovered=" & AttestationNotCovered & "\n")
  result.add("host=" & oneLine(a.host, "host") & "\n")
  result.add("generation=" & oneLine(a.generation, "generation") & "\n")
  result.add("ledgerDigest=" & oneLine(a.ledgerDigest, "ledgerDigest") & "\n")
  result.add("profileDigest=" & oneLine(a.profileDigest, "profileDigest") & "\n")
  result.add("sequence=" & $a.sequence & "\n")
  result.add("deploymentId=" & oneLine(a.deploymentId, "deploymentId") & "\n")
  result.add("manifestProfileDigest=" &
    oneLine(a.manifestProfileDigest, "manifestProfileDigest") & "\n")
  result.add("closuresDigest=" & oneLine(a.closuresDigest, "closuresDigest") & "\n")
  result.add("bootstrapDigest=" & oneLine(a.bootstrapDigest, "bootstrapDigest") & "\n")

proc parseStatement*(text: string): GenerationAttestation =
  ## The fields of a statement, refusing one of another scope or an
  ## incomplete one. Does not check a signature (``verifyAttestation``).
  var seen: seq[string]
  for line in text.splitLines():
    if line.len == 0: continue
    let eq = line.find('=')
    if eq <= 0:
      raise newException(AttestationError, "malformed statement line: " & line)
    let (k, v) = (line[0 ..< eq], line[eq + 1 .. ^1])
    seen.add(k)
    case k
    of "scope":
      if v != AttestationScope:
        raise newException(AttestationError, "not a generation attestation: " &
          "scope " & v)
    of "notCovered": discard
    of "host": result.host = v
    of "generation": result.generation = v
    of "ledgerDigest": result.ledgerDigest = v
    of "profileDigest": result.profileDigest = v
    of "sequence":
      try: result.sequence = parseBiggestUInt(v).uint64
      except ValueError:
        raise newException(AttestationError, "malformed sequence " & v)
    of "deploymentId": result.deploymentId = v
    of "manifestProfileDigest": result.manifestProfileDigest = v
    of "closuresDigest": result.closuresDigest = v
    of "bootstrapDigest": result.bootstrapDigest = v
    else:
      raise newException(AttestationError, "unknown statement field " & k)
  for need in ["scope", "notCovered", "host", "generation", "ledgerDigest",
               "sequence"]:
    if need notin seen:
      raise newException(AttestationError, "statement without " & need)

proc fromHex(hex: string; n: int; what: string): seq[byte] =
  if hex.len != 2 * n or not hex.allCharsInSet(HexDigits):
    raise newException(AttestationError, what & " is not " & $n & " bytes of hex")
  result = newSeq[byte](n)
  for i in 0 ..< n: result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b:
    result.add(d[int(x) shr 4]); result.add(d[int(x) and 15])

proc publicKeyOf*(hex: string): PublicKeyBytes =
  let raw = fromHex(hex, P256PubLen, "attestation public key")
  for i in 0 ..< P256PubLen: result[i] = raw[i]

proc verifyAttestation*(s: SignedAttestation; expectedKeyHex: string): string =
  ## "" when ``s`` is a well-formed statement of this scope signed by the
  ## key ``expectedKeyHex`` (the host's enrolled attestation key), otherwise
  ## why not. The key the record itself names is not trusted.
  if expectedKeyHex.len == 0:
    return "no attestation key is enrolled for the host"
  if s.publicKey.toLowerAscii() != expectedKeyHex.toLowerAscii():
    return "signed with " & s.publicKey[0 ..< min(16, s.publicKey.len)] &
      "..., not the host's enrolled attestation key " &
      expectedKeyHex[0 ..< min(16, expectedKeyHex.len)] & "..."
  try: discard parseStatement(s.statement)
  except AttestationError as e: return e.msg
  var sig: SignatureBytes
  try:
    let raw = fromHex(s.signature, sig.len, "attestation signature")
    for i in 0 ..< sig.len: sig[i] = raw[i]
  except AttestationError as e: return e.msg
  let key = try: publicKeyOf(expectedKeyHex)
            except AttestationError as e: return e.msg
  if not peerAuth.verifySignature(key, cast[seq[byte]](s.statement), sig):
    return "the attestation signature does not verify"
  ""

proc ensureAttestationKey*(path = AttestationKeyPath): tuple[publicKeyHex: string;
                                                             created: bool] =
  ## The host's attestation key: generated on first use with the deploy
  ## agent's own key generation (``0400``, created exclusively, never
  ## replacing an existing key), read thereafter.
  let k = ensureRecipientKeyFile(path)
  (peerAuth.publicKeyHex(k.publicKey), k.created)

proc signAttestation*(a: GenerationAttestation;
                      keyPath = AttestationKeyPath): SignedAttestation =
  ## Sign ``a`` with the key at ``keyPath``. Raises when there is no key: a
  ## record that should be attested must not silently go out unsigned (the
  ## caller decides whether a host without one ships unattested records).
  if not fileExists(keyPath):
    raise newException(AttestationError, "no attestation key at " & keyPath)
  var kp: PeerKeypair
  kp.privateKey = peerAuth.loadPrivateKeyFile(keyPath)
  try:
    kp.publicKey = peerAuth.derivePublicKey(kp.privateKey)
    result.statement = statement(a)
    let signed = when mutated("attestation-unsigned"): result.statement & "x"
                 else: result.statement
    let sig = peerAuth.signMessage(kp, cast[seq[byte]](signed))
    result.signature = toHex(sig)
    result.publicKey = peerAuth.publicKeyHex(kp.publicKey)
  finally:
    for i in 0 ..< kp.privateKey.len: kp.privateKey[i] = 0

proc readBootstrapDigest*(stateDir: string): string =
  ## The add-on binary's digest as bootstrap recorded it ("" if unknown).
  let p = stateDir / "addon" / BootstrapEvidenceName
  if not fileExists(p): return ""
  try:
    for line in readFile(p).split({',', '{', '}'}):
      let l = line.strip()
      if l.startsWith("\"binarySha256\""):
        return l.split(':', 1)[1].strip().strip(chars = {'"'})
  except CatchableError:
    discard
  ""

proc currentAttestation*(stateDir, host: string;
                         generation = ""): GenerationAttestation =
  ## The attestation of ``generation`` (default: the current one) from the
  ## generation's own committed files. Raises when there is no committed
  ## generation to attest.
  let gen = if generation.len > 0: generation
            else: readCurrentGenerationId(stateDir)
  if gen.len == 0:
    raise newException(AttestationError, "no committed add-on generation")
  let gd = generationDir(stateDir, gen)
  result.host = host
  result.generation = gen
  let ledger = gd / GenerationLedgerName
  result.ledgerDigest = if fileExists(ledger): "sha256:" & sha256OfFile(ledger)
                        else: ""
  let profile = gd / GenerationUserProfileName
  result.profileDigest = if fileExists(profile): "sha256:" & sha256OfFile(profile)
                         else: ""
  let rec = readAgentRecord(stateDir, gen)
  result.sequence = rec.sequence
  result.deploymentId = rec.deploymentId
  result.manifestProfileDigest = rec.profileDigest
  result.closuresDigest = rec.closuresDigest
  result.bootstrapDigest = readBootstrapDigest(stateDir)

# ---------------------------------------------------------------------------
# The hand-over of a host's evidence keys to new ones (spec §13 decision 50;
# A11 drill finding D7).
# ---------------------------------------------------------------------------

const HandoverScope* = "reprobuild.addon.evidence-key-handover.v1"

type
  KeyHandover* = object
    host*: string
    oldKey*: string                ## the attestation key that signs it, hex
    newKey*: string                ## the next attestation key, hex
    newCredentialHost*: string     ## the next sink credential's host id
    atMs*: int64

proc handoverStatement*(h: KeyHandover): string =
  "scope=" & HandoverScope & "\nhost=" & h.host & "\noldKey=" & h.oldKey &
    "\nnewKey=" & h.newKey & "\nnewCredentialHost=" & h.newCredentialHost &
    "\nat=" & $h.atMs & "\n"

proc parseHandover*(text: string): KeyHandover =
  var scope = ""
  for line in text.splitLines():
    let eq = line.find('=')
    if eq <= 0: continue
    let (k, v) = (line[0 ..< eq], line[eq + 1 .. ^1])
    case k
    of "scope": scope = v
    of "host": result.host = v
    of "oldKey": result.oldKey = v.toLowerAscii()
    of "newKey": result.newKey = v.toLowerAscii()
    of "newCredentialHost": result.newCredentialHost = v.toLowerAscii()
    of "at":
      try: result.atMs = parseBiggestInt(v) except ValueError: discard
    else: discard
  if scope != HandoverScope:
    raise newException(AttestationError, "not a key hand-over statement")
  if result.newKey.len == 0 or result.newCredentialHost.len != 64:
    raise newException(AttestationError, "hand-over names no new key or " &
      "credential")

proc signHandover*(h: KeyHandover; keyPath = AttestationKeyPath):
    tuple[statement, signature: string] =
  ## Sign the hand-over with the CURRENT attestation key at ``keyPath``.
  var kp: PeerKeypair
  kp.privateKey = peerAuth.loadPrivateKeyFile(keyPath)
  try:
    kp.publicKey = peerAuth.derivePublicKey(kp.privateKey)
    result.statement = handoverStatement(h)
    result.signature = toHex(peerAuth.signMessage(kp,
      cast[seq[byte]](result.statement)))
  finally:
    for i in 0 ..< kp.privateKey.len: kp.privateKey[i] = 0

proc verifyHandover*(statement, signature, expectedKeyHex: string):
    tuple[ok: bool; why: string; h: KeyHandover] =
  ## The hand-over verifies when it is well-formed, names ``expectedKeyHex``
  ## (the enrolled key) as its old key, and that key signed it.
  try: result.h = parseHandover(statement)
  except AttestationError as e: return (false, e.msg, result.h)
  if expectedKeyHex.len == 0:
    return (false, "no attestation key is enrolled for the host", result.h)
  if result.h.oldKey != expectedKeyHex.toLowerAscii():
    return (false, "the hand-over names another old key", result.h)
  var sig: SignatureBytes
  try:
    let raw = fromHex(signature, sig.len, "hand-over signature")
    for i in 0 ..< sig.len: sig[i] = raw[i]
  except AttestationError as e: return (false, e.msg, result.h)
  let key = try: publicKeyOf(expectedKeyHex)
            except AttestationError as e: return (false, e.msg, result.h)
  when mutated("handover-unverified"):
    # FALSIFYING BUILD: any well-formed hand-over is followed.
    return (true, "", result.h)
  if not peerAuth.verifySignature(key, cast[seq[byte]](statement), sig):
    return (false, "the hand-over signature does not verify", result.h)
  (true, "", result.h)
