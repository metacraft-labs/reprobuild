## A commitment that a verifier can check without the prompt, that a
## different prompt does not open, and that does not leak the prompt.
##
## ## The three properties, and why the third needs a demonstration
##
## The requirement is "privacy-preserving commitments so verification
## need not reveal private prompts, source, or outputs". That is three
## separate claims and each is checked separately:
##
##   1. **A verdict is reachable without the plaintext.** Structural: the
##      verifier's entry point has no plaintext parameter, and a full
##      acceptance is produced here from a statement whose plaintexts are
##      never handed to it. The type equality is asserted in the module
##      itself and again here, so a parameter added to satisfy some other
##      caller reddens two places.
##   2. **A different plaintext does not open the same commitment.**
##      Swept, in all three directions a commitment can be confused:
##      another plaintext, another salt, and the other domain.
##   3. **The commitment does not leak the plaintext.** This is the one a
##      bare hash fails, and the failure is *demonstrated* rather than
##      argued: the same dictionary attack is run against both
##      constructions. Against ``SHA-256(prompt)`` it finds the prompt.
##      Against the salted commitment it finds nothing. A gate that only
##      asserted the second half would be consistent with a scheme that
##      was no better than the first.
##
## ## The dictionary is the realistic one
##
## Prompts are short, and a very large share of them come from a small
## set anyone can enumerate: a template with one file name in it, a
## yes/no question, a handful of standing instructions. The corpus below
## is exactly that shape, and the *real* request plaintext the statement
## harness commits to is a member of it — so the attack is given the
## answer in its own candidate list and still fails against the salted
## form. An attack that could not have succeeded proves nothing.
##
## ## What this does NOT establish
##
## The hiding here is computational and rests on SHA-256 behaving as a
## random oracle over an unpredictable salt. A party who learns the salt
## can confirm a guess, and that is checked in both directions below
## rather than glossed: with the salt, the same dictionary attack
## succeeds again. Information-theoretic hiding would need a Pedersen
## commitment and a group this build does not carry. The module header
## says so and this gate measures the boundary.
##
## ## Mocking
##
## None. Real SHA-256, real operating-system randomness, the production
## verifier.

import std/[sets, strutils, unittest]

import repro_attest
import repro_attest/commitment
import repro_attest/inference_statement
import repro_attest_verify

import ./software_root_test_pki
import ./edge_attestation_harness
import ./inference_statement_harness

include ./attestation_verifier_harness

static:
  # This gate exercises the software-root test arm of the trust
  # classifier, and that arm exists only in a build that asked for it by
  # name. `evaluateInferenceStatement` compiles either way and simply
  # loses the arm, so without this the gate would build and then fail at
  # run time with a chain refusal that reads like a defect in the
  # verifier rather than like a missing define. The test-edge generator
  # names this file; this is what makes being dropped from that list a
  # compile error instead.
  doAssert defined(reproAttestSoftwareRootTestTrust),
    "this gate must be compiled with -d:reproAttestSoftwareRootTestTrust; " &
    "see needsSoftwareRootTestTrustDefine in the test-edge generator"

const
  GuessableCorpus = [
    "Summarise the security review in docs/review.md.",
    "Summarise the threat model in docs/threat.md.",
    "Summarise the release notes in docs/release.md.",
    "Fix the failing test.",
    "Explain this stack trace.",
    "Is this change safe to ship?",
    "yes",
    "no",
    "Refactor this function.",
    "Write a commit message for the staged diff.",
    "What does this error mean?",
    "Review the diff for security problems.",
  ]
    ## Twelve candidates of the shape a real prompt corpus has, and the
    ## harness's own request plaintext is the first of them — so the
    ## attack below is handed the answer and must still fail.

static:
  doAssert RequestPlaintext == GuessableCorpus[0],
    "the dictionary no longer contains the plaintext it is supposed to " &
    "find; an attack that cannot succeed proves nothing about the " &
    "construction that resists it"

proc bareHashOf(plaintext: string): string =
  ## What a scheme that skipped the salt would carry. Written out here
  ## rather than imported, because this repository does not implement it
  ## and must not start.
  DigestPrefix & sha256Hex(plaintext)

proc dictionaryAttack(target: string;
                      attempt: proc (candidate: string): string): int =
  ## How many of the twelve candidates the attacker can confirm. The
  ## attacker knows the construction and the corpus; what it may or may
  ## not know is the salt, which is what ``attempt`` decides.
  for candidate in GuessableCorpus:
    if attempt(candidate) == target: result.inc

suite "property 3 — the commitment does not leak what it commits to":
  test "the SAME dictionary attack BREAKS a bare hash — the hazard, demonstrated":
    # Not a strawman: this is what a commitment scheme looks like when
    # somebody reaches for `sha256(prompt)` because the prompt is
    # "obviously" high entropy. It is not, and the attacker needs twelve
    # guesses.
    let target = bareHashOf(RequestPlaintext)
    check dictionaryAttack(target, proc (c: string): string = bareHashOf(c)) == 1

  test "the same attack against the SALTED commitment finds NOTHING":
    let salt = newCommitmentSalt()
    let target = commitTo(cdRequest, salt, RequestPlaintext)
    # The attacker has the corpus and the construction and does not have
    # the salt, so it must guess one. Any wrong salt will do to model
    # that; a fresh one is the most favourable case for the attacker.
    let wrongSalt = newCommitmentSalt()
    check wrongSalt != salt
    check dictionaryAttack(target, proc (c: string): string =
      commitTo(cdRequest, wrongSalt, c)) == 0

  test "and WITH the salt the attack succeeds again — the hiding is computational":
    # Stated in the module header and measured here, because a reader who
    # took "hiding" for the information-theoretic kind would be wrong in
    # a way that matters when the salt is published.
    let salt = newCommitmentSalt()
    let target = commitTo(cdRequest, salt, RequestPlaintext)
    check dictionaryAttack(target, proc (c: string): string =
      commitTo(cdRequest, salt, c)) == 1

  test "two commitments to the SAME plaintext differ, so a repeat is not visible":
    # Without this, an observer who sees the same commitment twice learns
    # that the same prompt was asked twice — which is a leak even when
    # the prompt itself stays hidden.
    var seen = initHashSet[string]()
    for _ in 0 ..< 32:
      let c = commitTo(cdRequest, newCommitmentSalt(), RequestPlaintext)
      check c notin seen
      seen.incl c
    check seen.len == 32

suite "property 2 — a different plaintext does not open the same commitment":
  test "no two candidates in the corpus share a commitment under one salt":
    let salt = newCommitmentSalt()
    var seen = initHashSet[string]()
    for candidate in GuessableCorpus:
      let c = commitTo(cdRequest, salt, candidate)
      check c notin seen
      seen.incl c
    check seen.len == GuessableCorpus.len

  test "openCommitment answers yes for the plaintext and no for every other":
    let salt = newCommitmentSalt()
    let c = commitTo(cdRequest, salt, RequestPlaintext)
    check openCommitment(c, cdRequest, salt, RequestPlaintext)
    for candidate in GuessableCorpus:
      if candidate == RequestPlaintext: continue
      check not openCommitment(c, cdRequest, salt, candidate)

  test "the same plaintext under another salt does not open it":
    let salt = newCommitmentSalt()
    let c = commitTo(cdRequest, salt, RequestPlaintext)
    check not openCommitment(c, cdRequest, newCommitmentSalt(),
                             RequestPlaintext)

  test "a REQUEST commitment is not a RESPONSE commitment, even byte for byte":
    # The two travel side by side in one statement over the same
    # plaintext space. Without the domain inside the hash, an opening of
    # one is an opening of the other and the halves can be swapped.
    let salt = newCommitmentSalt()
    let asRequest = commitTo(cdRequest, salt, RequestPlaintext)
    let asResponse = commitTo(cdResponse, salt, RequestPlaintext)
    check asRequest != asResponse
    check not openCommitment(asRequest, cdResponse, salt, RequestPlaintext)
    check not openCommitment(asResponse, cdRequest, salt, RequestPlaintext)

  test "the framing: the CONSTRUCTED collision the salt prefix exists to close":
    # This case was rewritten after its first version was found green
    # under the mutation that deletes the salt's length prefix. The
    # original pair — ("AB","CD") against ("ABC","D") — does not collide
    # even unframed, because the plaintext's own prefix happens to fix
    # the split for inputs of that shape. Asserting two inequalities that
    # hold either way is not a framing test; it is the "a case titled
    # after the claim whose body asserts something weaker" shape, in this
    # file, found by running the mutation rather than by reading it.
    #
    # The real collision is built by putting the OTHER field's length
    # prefix inside the plaintext. Write L(n) for the four-byte prefix:
    #
    #   A = (salt "X",                 plaintext "abc" L(1) "Z")
    #   B = (salt "X" L(8) "abc",      plaintext "Z")
    #
    # Without the salt's prefix both spell
    #   X L(8) a b c L(1) Z
    # byte for byte — two different commitments to two different secrets
    # under two different salts, sharing one preimage.
    proc l(n: int): string =
      result = newString(4)
      result[0] = char((n shr 24) and 0xFF)
      result[1] = char((n shr 16) and 0xFF)
      result[2] = char((n shr 8) and 0xFF)
      result[3] = char(n and 0xFF)
    let
      saltA = "X"
      plainA = "abc" & l(1) & "Z"
      saltB = "X" & l(8) & "abc"
      plainB = "Z"
    # The collision is real: drop the salt prefix by hand and the two
    # tails are identical, which is what makes the assertion below mean
    # something.
    check saltA & l(plainA.len) & plainA == saltB & l(plainB.len) & plainB
    check (saltA, plainA) != (saltB, plainB)
    # And the framed construction keeps them apart.
    check commitmentPreimage(cdRequest, saltA, plainA) !=
          commitmentPreimage(cdRequest, saltB, plainB)

    # The versioned tag is the preimage's literal PREFIX, ahead of the
    # domain, and the domain is framed behind it. The statement's gate
    # pins its own tag exactly this way and this one did not — so
    # deleting `result = CommitmentDomainTag` left every case in this
    # file green while the construction lost the one thing that stops its
    # bytes being read as some other framed document in this library,
    # which is what the module header says the tag is for. Found by
    # review.
    let pre = commitmentPreimage(cdRequest, repeat("s", CommitmentSaltBytes),
                                 "p")
    check pre.startsWith(CommitmentDomainTag)
    let afterTag = pre[CommitmentDomainTag.len .. ^1]
    check afterTag.len > 4
    check afterTag[0 ..< 4] == l(($cdRequest).len)
    check afterTag[4 ..< 4 + ($cdRequest).len] == $cdRequest

  test "the salt discipline is enforced in BOTH directions":
    for bad in ["", "short", repeat("a", CommitmentSaltBytes - 1),
                repeat("a", CommitmentSaltBytes + 1)]:
      expect CommitmentError:
        discard commitTo(cdRequest, bad, RequestPlaintext)
    check newCommitmentSalt().len == CommitmentSaltBytes
    discard commitTo(cdRequest, repeat("a", CommitmentSaltBytes),
                     RequestPlaintext)
    # The length as a NUMBER, not as the constant compared against
    # itself. Every other assertion in this case is written in terms of
    # `CommitmentSaltBytes`, so shortening that constant to 8 would leave
    # all of them green — the salt would still be "exactly the declared
    # length", the dictionary attack would still find nothing, and the
    # module header's claim that the salt "is the whole of this
    # construction's hiding property" would have been cut to a quarter
    # with no case able to see it. The header names 32; 32 is pinned.
    check CommitmentSaltBytes == 32

suite "property 1 — a verdict is reachable, and complete, without any plaintext":
  setup:
    let now = 1_789_000_000'i64
    let hierarchy = mintHierarchy(now, marked = true)
    let signerKey = newTestKey()
    let signer = mintInferenceSigner(hierarchy, key = signerKey)
    let challenge = mintChallenge(now * 1000)
    let statement = baseStatement(
      sampleManifestDigest(), DigestPrefix & sha256Hex(productionPolicyText()),
      challenge.challengeHex, certificateDigestOf(signer.cert.der), now,
      newCommitmentSalt(), newCommitmentSalt())
    let text = renderInferenceStatement(statement)
    let verdict = evaluateInferenceStatement(
      text, signStatement(signerKey, text), signer.chain,
      anchorsOf(hierarchy), crlsOf(hierarchy), challenge.challengeHex,
      default(InferenceExpectation),
      {itSoftwareRootTest, itProviderRooted}, now)

  test "the statement is ACCEPTED, and no plaintext was supplied to reach that":
    check verdict.outcome == ioAccepted
    check verdict.caveats.len == 3
    check UnopenedCommitmentsCaveat in verdict.caveats

  test "the evaluator has no plaintext parameter, and adding one stops the build":
    # The same equality the module asserts of itself. Asserted again from
    # outside so a parameter added to please another caller reddens here
    # as well as there — a type assertion inside the module it constrains
    # is one edit away from being edited with it.
    check typeof(evaluateInferenceStatement) is InferenceEvaluatorSignature

  test "neither plaintext appears in the statement, the verdict or the audit record":
    let record = auditRecordFor(verdict, text)
    for leak in [RequestPlaintext, ResponsePlaintext,
                 AgentConfigDocument.strip(), ServingStackDescriptor.strip()]:
      check leak notin text
      check leak notin verdict.detail
      check leak notin record
      for caveat in verdict.caveats:
        check leak notin caveat

  test "the audit record DOES carry the commitments, so a holder can still open them":
    # The complement, and it is not decoration: a record that leaked
    # nothing because it carried nothing would pass the case above and be
    # useless to the reviewer it exists for.
    let record = auditRecordFor(verdict, text)
    check statement.requestCommitment in record
    check statement.responseCommitment in record
    check verdict.statementDigest in record
    check InferenceAuditRecordSchema in record
    for f in InferenceField:
      check fieldOf(statement, f) in record

  test "every field of a statement is a digest, a nonce or a timestamp — so there is nothing to redact":
    # The structural reason the record above is safe. If a field were
    # ever allowed to carry free text, this case is what would fail.
    for f in InferenceField:
      let value = fieldOf(statement, f)
      case f
      of ifNonce:
        check value.len mod 2 == 0
        for c in value: check c in {'0' .. '9', 'a' .. 'f'}
      of ifTimestamp:
        check value.len == 20
        check value.endsWith("Z")
      else:
        check value.startsWith(DigestPrefix)
        check value.len == DigestPrefix.len + 64
