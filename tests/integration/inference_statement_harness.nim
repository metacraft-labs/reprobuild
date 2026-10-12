## Minting authenticated inference statements: an inference-signing
## certificate under a chosen hierarchy, and the detached signature over
## a statement's own bytes.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right — the convention
## ``software_root_test_pki.nim`` and ``edge_attestation_harness.nim``
## follow.
##
## ## THE HONEST DESCRIPTION OF WHAT THESE FIXTURES ARE
##
## Read this before reading any verdict this harness helps produce.
##
## **There is no inference in this build.** This workspace contains no
## inference server, no model registry, no agent identity surface and no
## agent-configuration identity. A statement minted here is a statement
## about an exchange that *did not happen*, signed by a key that never
## served one. Every gate built on this harness therefore establishes
## properties of the **format and of the binding algebra** — that all
## eleven fields are covered, that changing any one of them invalidates
## the signature, that a verdict is reachable without a plaintext — and
## establishes **nothing whatever** about any inference.
##
## That distinction is not a disclaimer, it is the result. A mutation
## table over authored fixtures proves the binding is a binding. It does
## not, and cannot, prove that an accepted statement describes something
## that occurred; the only thing that could is evidence from a machine's
## root of trust bound to the statement's own bytes, and no such binding
## exists here.
##
## ## Which values are real, and what "real" means for each
##
## Two of the eleven fields carry **published digests of real artifacts**,
## so that a mutation is a substitution of one real thing for another
## real thing rather than one invented string for another:
##
##   * ``agent`` — the SHA-256 the vendor of a real coding agent publishes
##     for its Linux x86-64 binary, transcribed from this repository's own
##     package recipe. Its mutation neighbour is the same vendor's digest
##     for the *previous release* of the same binary: two real digests of
##     two real builds of one program.
##   * ``model`` — the SHA-256 published for a real set of model weights,
##     likewise transcribed from this repository's package recipe.
##
## **Nothing in this build ran either of them**, and neither digest was
## computed here: both are transcriptions, and the transcription is
## checked at compile time against the file it came from (see
## ``ProvenanceChecked`` below), which is the only part of it this harness
## can establish.
##
## The remaining nine fields are authored: a configuration document, a
## serving-stack descriptor, a measurement manifest rendered by the
## production renderer, a policy parsed by the production parser, two
## commitments over authored plaintexts, a nonce from the production
## challenge minter, a timestamp, and the digest of a certificate minted
## here. Of those, the nonce and the certificate are real in the strong
## sense — the nonce comes from the operating system's random source and
## the certificate is real DER under a real ECDSA signature.
##
## ## Mocking
##
## None. Real ECDSA-P256 keys from the operating system's random source,
## real DER, real CBOR, real SHA-256, and the production chain evaluator.
## The only thing built here that production does not build is a
## producer: this repository ships no inference-statement signer.

import std/strutils

import cbor

import repro_attest
import repro_attest/commitment
import repro_attest/cose
import repro_attest/inference_statement
import repro_attest_verify

import ./software_root_test_pki
import ./edge_attestation_harness

const
  ClaudeCodeRecipe =
    staticRead("../../libs/repro_dsl_stdlib/src/repro_dsl_stdlib/" &
               "packages/claude_code.nim")
  WhisperRecipe =
    staticRead("../../libs/repro_dsl_stdlib/src/repro_dsl_stdlib/" &
               "packages/whisper_ggml_base.nim")
  PiperRecipe =
    staticRead("../../libs/repro_dsl_stdlib/src/repro_dsl_stdlib/" &
               "packages/piper_voice_lessac_medium.nim")

  RealAgentBinarySha256* =
    "849e007277a0442ab27570d3e3d6d43787507946590e8dd1947e5a39b7081f9e"
    ## The vendor-published SHA-256 of one real coding agent's Linux
    ## x86-64 binary, release 2.1.170, transcribed from
    ## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/claude_code.nim``.

  PreviousAgentBinarySha256* =
    "cf066bf360cbf7b51abeb8cb230012fc0f2fed4253b2ce305de48ccd6d49a39c"
    ## The same vendor's SHA-256 for the same binary at release 2.1.169.
    ## The ``agent`` axis mutates between these two, so that axis's case
    ## substitutes one real build of one program for another rather than
    ## flipping a character.

  OtherRealModelWeightsSha256* =
    "5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f"
    ## A SECOND real model artifact's published digest — a different
    ## voice model, transcribed from
    ## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/piper_voice_lessac_medium.nim``.
    ## The ``model`` axis mutates between this and the one below, so that
    ## axis substitutes one real set of weights for another rather than
    ## editing a digit.

  RealModelWeightsSha256* =
    "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
    ## The published SHA-256 of a real set of speech-recognition model
    ## weights, transcribed from
    ## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/whisper_ggml_base.nim``.
    ## It is not a language model and nothing here ran it; it is a real
    ## model artifact's real digest, which is the whole of the claim.

  ProvenanceChecked* = true
    ## Set by the ``static`` block below, which is what makes the three
    ## transcriptions above checkable rather than merely asserted. A
    ## digest edited here and not in the recipe stops the build.

static:
  doAssert RealAgentBinarySha256 in ClaudeCodeRecipe,
    "the transcribed agent digest is not in the recipe it claims to come " &
    "from; a provenance note that does not match its source is worse than " &
    "no note"
  doAssert PreviousAgentBinarySha256 in ClaudeCodeRecipe,
    "the transcribed previous-release agent digest is not in the recipe"
  doAssert RealAgentBinarySha256 != PreviousAgentBinarySha256,
    "the two agent digests are equal, so the agent axis would mutate to " &
    "itself and its case would pass without the binding doing anything"
  doAssert RealModelWeightsSha256 in WhisperRecipe,
    "the transcribed model-weights digest is not in the recipe it claims " &
    "to come from"
  doAssert OtherRealModelWeightsSha256 in PiperRecipe,
    "the transcribed second model-weights digest is not in the recipe"
  doAssert RealModelWeightsSha256 != OtherRealModelWeightsSha256,
    "the two model digests are equal, so the model axis would mutate to " &
    "itself"

const
  InferenceSignerCn* = "software-root test inference signer"
  OtherInferenceSignerCn* = "software-root test OTHER inference signer"
  Day* = 86_400'i64

type
  SignerCert* = object
    ## An inference-signing leaf and the chain it presents.
    cert*: MintedCert
    chain*: seq[string]

proc mintInferenceSigner*(h: TestHierarchy; cn = InferenceSignerCn;
                          key = newTestKey()): SignerCert =
  ## A leaf certified by ``h``'s intermediate, carrying the purpose OID
  ## and the subject alternative name the inference verifier requires.
  ##
  ## The hierarchy decides whether the chain is marked, so one call site
  ## produces the local-test arm and the provider-rooted arm; nothing
  ## about the signer differs between them, which is what makes the two
  ## arms comparable.
  result.cert = mintCert(key, h.intermediate.key, CertOptions(
    subjectCn: cn, issuerName: h.intermediate.subjectName,
    serial: randomSerial(),
    notBefore: h.now - Day, notAfter: h.now + 365 * Day,
    keyUsageBits: @[0], eku: @[InferenceSignerEku],
    sanDnsNames: @[InferenceSignerSubjectAltName], marked: h.marked))
  result.chain = @[result.cert.der, h.intermediate.der, h.root.der]

proc signStatement*(key: TestKey; statementText: string): seq[byte] =
  ## A detached ``COSE_Sign1`` over the statement's own bytes, in
  ## production algorithms and production encodings.
  ##
  ## The Sig_structure is ``edge_attestation_harness``'s, which is built
  ## by hand from RFC 9052 §4.4 rather than by calling ``cose``'s
  ## ``sigStructureSign1`` — see that file's header for why a gate that
  ## asked the library to assemble the bytes would agree with the
  ## verifier by construction.
  ##
  ## The key identifier is the production convention: SHA-256 of the
  ## signer's own public point. The verifier derives the same identifier
  ## from the CERTIFICATE it accepted, so a certificate that does not
  ## carry this key produces a lookup failure rather than a signature
  ## failure, and the two are distinguishable.
  var point: seq[byte] = @[]
  for b in key.pub: point.add b
  let kid = inferenceSignerKid(point)
  let protectedBytes = protectedHeader(kid)
  var payload: seq[byte] = @[]
  for c in statementText: payload.add byte(c)
  let tbs = encodeItem(cArray([cText("Signature1"),
                               cBytes(protectedBytes),
                               cBytes(newSeq[byte]()),
                               cBytes(payload)]))
  let (r, s) = signRawEcdsa(key, tbs)
  var sig: seq[byte] = @[]
  for c in r: sig.add byte(c)
  for c in s: sig.add byte(c)
  encodeItem(cTag(CoseSign1Tag,
    cArray([cBytes(protectedBytes), cMap([]), cNull(), cBytes(sig)])))

# `anchorsOf` and `crlsOf` are NOT redefined here. `software_root_test_pki`
# already exports both, and a second answer to "what is this hierarchy's
# trust store" is the shape that lets one gate be evaluated against an
# anchor set another gate never installed.

# ---------------------------------------------------------------------
# The statement under test
# ---------------------------------------------------------------------

const
  AgentConfigDocument* = """
{
  "tools": ["read", "write", "bash"],
  "sandbox": "deny-network",
  "maxTurns": 40
}
"""
    ## An authored agent configuration. Its content is arbitrary; what
    ## matters is that it is a document with a digest, so the
    ## ``agentConfig`` axis mutates between two configurations that
    ## differ in one setting rather than between two random strings.

  RelaxedAgentConfigDocument* = """
{
  "tools": ["read", "write", "bash"],
  "sandbox": "allow-network",
  "maxTurns": 40
}
"""
    ## The same configuration with its sandbox opened. This is the
    ## substitution the ``agentConfig`` field exists to prevent, so it is
    ## what that axis's case actually performs.

  ServingStackDescriptor* = """
{
  "server": "openai-compatible",
  "quantisation": "q4_K_M",
  "sampler": "top-p",
  "contextWindow": 131072
}
"""
    ## AUTHORED, and there is nothing behind it. This workspace packages
    ## no inference server, so there is no build output to take a digest
    ## of. Stated here rather than in a footnote: the
    ## ``inferenceServer`` axis is the one whose fixture has no real
    ## artifact anywhere in the tree.

  OtherServingStackDescriptor* = """
{
  "server": "openai-compatible",
  "quantisation": "q8_0",
  "sampler": "top-p",
  "contextWindow": 131072
}
"""
    ## The same stack at a different quantisation. Two servings of one
    ## set of weights that do not produce the same answers, which is why
    ## the weights are not the whole of a model's identity.

  OtherRequestPlaintext* = "Summarise the threat model in docs/threat.md."
  OtherResponsePlaintext* =
    "The threat model records three adversaries and one out of scope."

  RequestPlaintext* = "Summarise the security review in docs/review.md."
    ## Deliberately SHORT and deliberately ordinary. The hiding gate
    ## draws candidate prompts from a small set of exactly this shape,
    ## because a short, guessable prompt is the case a bare hash fails
    ## and the salted commitment must not.

  ResponsePlaintext* =
    "The review records four defects, all fixed, and two open items."

proc sampleAgentConfigDigest*(): string =
  DigestPrefix & sha256Hex(AgentConfigDocument)

proc relaxedAgentConfigDigest*(): string =
  DigestPrefix & sha256Hex(RelaxedAgentConfigDocument)

proc servingStackDigest*(): string =
  DigestPrefix & sha256Hex(ServingStackDescriptor)

proc otherServingStackDigest*(): string =
  DigestPrefix & sha256Hex(OtherServingStackDescriptor)

proc timestampOf*(unixSeconds: int64): string =
  ## ``YYYY-MM-DDTHH:MM:SSZ`` for a unix instant, built here rather than
  ## through ``std/times`` so the gate's spelling of an instant is
  ## independent of the library's parser for one.
  var days = unixSeconds div 86_400
  var rem = unixSeconds mod 86_400
  if rem < 0:
    rem += 86_400
    days -= 1
  var z = days + 719_468
  let era = (if z >= 0: z else: z - 146_096) div 146_097
  let doe = z - era * 146_097
  let yoe = (doe - doe div 1460 + doe div 36_524 - doe div 146_096) div 365
  var y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = (if mp < 10: mp + 3 else: mp - 9)
  if m <= 2: y.inc
  proc pad(v, width: int): string =
    result = $v
    while result.len < width: result = "0" & result
  pad(int(y), 4) & "-" & pad(int(m), 2) & "-" & pad(int(d), 2) & "T" &
    pad(int(rem div 3600), 2) & ":" & pad(int((rem div 60) mod 60), 2) & ":" &
    pad(int(rem mod 60), 2) & "Z"

proc baseStatement*(manifestDigest, policyDigest, nonceHex,
                    certificateDigest: string;
                    nowSeconds: int64;
                    requestSalt, responseSalt: string): InferenceStatement =
  ## The statement every case starts from: real where this tree has
  ## something real, authored where it does not, and every value produced
  ## by the production procedure that produces such values.
  ##
  ## The two commitments go through ``commitTo``, so the statement a gate
  ## signs carries a commitment and not a hash of a prompt — which is the
  ## difference the whole privacy argument rests on.
  InferenceStatement(
    agent: DigestPrefix & RealAgentBinarySha256,
    agentConfig: sampleAgentConfigDigest(),
    model: DigestPrefix & RealModelWeightsSha256,
    inferenceServer: servingStackDigest(),
    systemGeneration: manifestDigest,
    policy: policyDigest,
    requestCommitment: commitTo(cdRequest, requestSalt, RequestPlaintext),
    responseCommitment: commitTo(cdResponse, responseSalt, ResponsePlaintext),
    nonce: nonceHex,
    timestamp: timestampOf(nowSeconds),
    certificate: certificateDigest)
