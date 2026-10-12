#!/usr/bin/env python3
"""Run the inference-binding mutation table: one edit at a time, rebuild AND run the gate
it targets, record the observed result, restore, and prove the restore by
full sha256 of the mutated file.

Each row names the ONE line it changes and the gate that must go red.
A row whose defeating mutation has not been executed is not yet known to
be a check, which is the whole reason this file exists.

Usage (from the repository root, inside the dev shell):
    python3 tools/attestation-mutations/inference_binding_mutations.py
    python3 tools/attestation-mutations/inference_binding_mutations.py N3 N7
"""
import hashlib
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.environ.get("MUTATION_OUT", "/tmp/inference-binding-mutations")
DEFINE = "-d:reproAttestSoftwareRootTestTrust"

STMT = "libs/repro_attest/src/repro_attest/inference_statement.nim"
COMMIT = "libs/repro_attest/src/repro_attest/commitment.nim"
VERIFY = "libs/repro_attest_verify/src/repro_attest_verify/inference.nim"
GEN = "scripts/generate_test_edges.nim"
G_MUT = "tests/integration/t_authenticated_inference_binding_mutations.nim"
G_COM = "tests/integration/t_inference_commitment_is_hiding_and_binding.nim"
G_E2E = "tests/integration/t_e2e_authenticated_inference_local_and_cloud.nim"

# id, description, [(file, old, new), ...], gate stem, [no_define]
#
# `no_define` compiles the gate as a build that did NOT ask for the
# software-root test-trust arm. It exists because the generator-list row was MEANINGLESS
# without it: this driver passes the define on every compile, so removing
# a path from the generator's list changed nothing it could observe, and
# the row came back GREEN while proving nothing. A row whose mutation the
# driver itself masks is worse than no row.
ROWS = [
    ("N1", "commitmentPreimage: drop the salt's length prefix",
     [(COMMIT, '  result.add be32Prefix(salt.len)\n  result.add salt\n',
               '  result.add salt\n')], G_COM),
    ("N2", "commitTo: stop validating the salt's length",
     [(COMMIT, '  validateCommitmentSalt("the commitment salt", salt)\n', '')],
     G_COM),
    ("N3", "commitmentPreimage: drop the domain from the preimage",
     [(COMMIT, '  let d = $domain\n  result.add be32Prefix(d.len)\n  result.add d\n',
               '  let d = $domain\n  discard d\n')], G_COM),
    ("N4", "newCommitmentSalt: return a constant salt instead of OS randomness",
     [(COMMIT, '  var buf = newSeq[byte](CommitmentSaltBytes)\n  if not urandom(buf):',
               '  var buf = newSeq[byte](CommitmentSaltBytes)\n  if false:')],
     G_COM),
    ("N5", "inferenceStatementPreimage: drop each field VALUE's length prefix",
     [(STMT, '    result.add be32Prefix(value.len)\n    result.add value\n',
             '    result.add value\n')], G_MUT),
    ("N6", "inferenceStatementPreimage: drop the field NAME from the preimage",
     [(STMT, '    result.add be32Prefix(name.len)\n    result.add name\n', '')],
     G_MUT),
    ("N7", "inferenceStatementPreimage: drop the domain tag and schema prefix",
     [(STMT, '  result = InferenceStatementDomainTag\n  result.add be32Prefix(InferenceStatementSchema.len)\n  result.add InferenceStatementSchema\n',
             '  result = ""\n')], G_MUT),
    ("N8", "fieldOf: bind ifModel to the empty string",
     [(STMT, '  of ifModel: s.model\n', '  of ifModel: ""\n')], G_MUT),
    ("N9", "the verifier stops comparing the bound certificate against the accepted one",
     [(VERIFY, '  if leafDigest != statement.certificate:',
               '  if false:')], G_MUT),
    ("N10", "the verifier stops comparing a pinned field against the statement",
     [(VERIFY, '    if fieldOf(statement, f) != expect[f]:', '    if false:')],
     G_MUT),
    ("N11", "an unknown signer key becomes 'did not verify' instead of its own refusal",
     [(VERIFY, '    of cxeKeyNotFound:\n      no(ioSignerKeyNotTheCertificates,',
               '    of cxeKeyNotFound:\n      no(ioSignatureDidNotVerify,')],
     G_MUT),
    ("N12", "the verifier stops comparing the statement's nonce with the issued challenge",
     [(VERIFY, '  if statement.nonce != expectedNonceHex:', '  if false:')],
     G_MUT),
    ("N13", "the verifier stops applying the freshness window",
     [(VERIFY, '  if age > freshnessSeconds or age < -freshnessSeconds:',
               '  if false:')], G_MUT),
    ("N14", "a pin for an unpinnable field is ignored instead of refused",
     [(VERIFY, '    if unpinnable:\n      no(ioUnpinnableField,',
               '    if false:\n      no(ioUnpinnableField,')], G_MUT),
    ("N15", "classify the software-root TEST arm before production",
     [(VERIFY, '''  let production = evaluateProductionChain(chainDer, anchors, crls, expect)
  if production.isAccepted:
    return (true, itProviderRooted, production)
  when defined(reproAttestSoftwareRootTestTrust):
    let test = evaluateSoftwareRootTestChain(chainDer, anchors, crls, expect)
    if test.isAccepted:
      return (true, itSoftwareRootTest, test)
''',
               '''  when defined(reproAttestSoftwareRootTestTrust):
    let test = evaluateSoftwareRootTestChain(chainDer, anchors, crls, expect)
    if test.isAccepted:
      return (true, itProviderRooted, test)
  let production = evaluateProductionChain(chainDer, anchors, crls, expect)
  if production.isAccepted:
    return (true, itProviderRooted, production)
''')], G_E2E),
    ("N16", "an accepted test-hierarchy statement stops carrying the test caveat",
     [(VERIFY, '  if trustClass == itSoftwareRootTest:\n    result.caveats.add SoftwareRootTestCaveat',
               '  if false:\n    result.caveats.add SoftwareRootTestCaveat')],
     G_E2E),
    ("N17", "the verifier stops checking the trust class against the admitted set",
     [(VERIFY, '  if trustClass notin admitted:', '  if false:')], G_E2E),
    ("N18", "the audit record stops carrying the bound fields",
     [(STMT, '''  result.add "  \\"bound\\": {\\n"
  for f in InferenceField:
    result.add "    " & q($f) & ": " & q(fieldOf(s, f))
    result.add (if f == high(InferenceField): "\\n" else: ",\\n")
  result.add "  }\\n"''',
             '''  result.add "  \\"bound\\": {\\n"
  result.add "  }\\n"''')], G_COM),
    ("N19", "validateField stops applying the nonce's freshness floor",
     [(STMT, '''  of ifNonce:
    try:
      validateChallengeHex(value)
    except BindingError as err:
      fail("nonce: " & err.msg)''',
             '''  of ifNonce:
    discard value''')], G_MUT),
    ("N20", "the marker loses its trailing ' is ', so 'agent' matches 'agentConfig'",
     [(G_MUT, '  "the statement\'s " & $f & " is "', '  "the statement\'s " & $f')],
     G_MUT),
    ("N21", "a member added to InferenceField with no fieldOf arm",
     [(STMT, "    ifCertificate = \"certificate\"\n",
             "    ifCertificate = \"certificate\"\n    ifSpare = \"spare\"\n")],
     G_MUT),
    ("N22", "a member added to InferenceField, wired everywhere EXCEPT the gate's row table",
     [(STMT, "    ifCertificate = \"certificate\"\n",
             "    ifCertificate = \"certificate\"\n    ifSpare = \"spare\"\n"),
      (STMT, "  of ifCertificate: s.certificate\n",
             "  of ifCertificate: s.certificate\n  of ifSpare: \"\"\n"),
      (STMT, "  of ifCertificate: result.certificate = value\n",
             "  of ifCertificate: result.certificate = value\n  of ifSpare: discard\n"),
      (STMT, "  of ifRequestCommitment, ifResponseCommitment:\n    requireDigest($f, value)\n",
             "  of ifRequestCommitment, ifResponseCommitment:\n    requireDigest($f, value)\n  of ifSpare: discard\n")],
     G_MUT),
    ("N23", "the e2e gate's file is dropped from the generator's define list, "
            "and the gate is then built the way that list would have built it",
     [(GEN, '    path.endsWith("/t_e2e_authenticated_inference_local_and_cloud.nim") or\n', '')],
     G_E2E, True),
    ("N25", "be32Prefix returns four zero bytes — mutating the FIX, not the "
            "rule it repairs",
     [("libs/repro_attest/src/repro_attest/binding.nim",
       "  result = newString(4)\n  result[0] = char((n shr 24) and 0xFF)",
       "  result = newString(4)\n  if true: return\n  result[0] = char((n shr 24) and 0xFF)")],
     None),
    ("N26", "commitmentPreimage: drop the PLAINTEXT's length prefix (expected "
            "GREEN — the last field's prefix is redundant, and this row is "
            "what establishes that rather than assuming it)",
     [(COMMIT, '  result.add be32Prefix(plaintext.len)\n  result.add plaintext\n',
               '  result.add plaintext\n')], G_COM),
    ("N27", "inferenceSignerKid returns a constant, so any key's identifier "
            "matches the certificate's",
     [(VERIFY, "  let hex = sha256Hex(raw)\n", "  let hex = sha256Hex(\"\")\n")],
     G_MUT),
    # --- Rows added by review. Each targets a property the original
    # --- table asserted in prose and left unmeasured; each was run
    # --- against the tree BEFORE its repair (all four GREEN) and after.
    ("R1", "the salt is shortened from 32 bytes to 8 — the hiding property "
           "cut to a quarter while every relative assertion stays true",
     [(COMMIT, "  CommitmentSaltBytes* = 32\n",
               "  CommitmentSaltBytes* = 8\n")], G_COM),
    ("R2", "UnpinnableFields keeps its LENGTH but loses two members, so a "
           "pin for the timestamp and the certificate becomes honoured",
     [(VERIFY, "    [ifNonce, ifTimestamp, ifCertificate]\n",
               "    [ifNonce, ifNonce, ifNonce]\n")], G_MUT),
    ("R3", "the pins are evaluated BEFORE the signature, so a pin refusal "
           "names a field about bytes that were in fact altered",
     [(VERIFY, '''
  # The pins. After the signature, so a refusal here is never a signature
  # failure wearing a field's name; before the nonce, because a statement
  # about the wrong model is wrong whether or not it is fresh.
  for f in InferenceField:
    if expect[f].len == 0: continue
    var unpinnable = false
    for u in UnpinnableFields:
      if u == f: unpinnable = true
    if unpinnable:
      no(ioUnpinnableField, "a pin was given for the statement's " & $f &
        ", which this verifier already decides from its own source of " &
        "truth; two rules deciding one field are two answers to one " &
        "question, so the pin is refused rather than preferred or ignored")
    if fieldOf(statement, f) != expect[f]:
      no(ioPinnedFieldDiffers, "the statement's " & $f & " is " &
        fieldOf(statement, f) & " and this verifier accepts only " &
        expect[f] & "; the signature over this statement is valid, so " &
        "what is refused is what it says and not whether it was altered")
''', "\n"),
      (VERIFY, "  result.trust = trustClass\n  result.trustEstablished = true\n",
       '''  result.trust = trustClass
  result.trustEstablished = true
  for f in InferenceField:
    if expect[f].len == 0: continue
    var unpinnable = false
    for u in UnpinnableFields:
      if u == f: unpinnable = true
    if unpinnable:
      no(ioUnpinnableField, "a pin was given for the statement's " & $f &
        ", which this verifier already decides from its own source of " &
        "truth; two rules deciding one field are two answers to one " &
        "question, so the pin is refused rather than preferred or ignored")
    if fieldOf(statement, f) != expect[f]:
      no(ioPinnedFieldDiffers, "the statement's " & $f & " is " &
        fieldOf(statement, f) & " and this verifier accepts only " &
        expect[f] & "; the signature over this statement is valid, so " &
        "what is refused is what it says and not whether it was altered")
''')],
     G_MUT),
    ("R4", "the trust-class refusal names the ADMITTED set where it should "
           "name the class the chain earned, and vice versa",
     [(VERIFY, '''      chainVerdict.evaluator & ", giving trust class " & $trustClass &
      ", and this verifier was asked to admit only " & admittedText)''',
               '''      chainVerdict.evaluator & ", giving trust class " & admittedText &
      ", and this verifier was asked to admit only " & $trustClass)''')],
     G_E2E),
    ("R5", "validateField stops applying the field LENGTH ceiling — the "
           "other arm of the rule whose per-field half was defect 5",
     [(STMT, '''  if value.len > MaxFieldLen:
    fail($f & " is " & $value.len & " characters; no field of a statement " &
      "is a payload and at most " & $MaxFieldLen & " are read")
''', "  discard\n")], G_MUT),
    ("R6", "commitmentPreimage: drop the versioned domain TAG, which the "
           "statement's preimage pins and the commitment's did not",
     [(COMMIT, "  result = CommitmentDomainTag\n", '  result = ""\n')],
     G_COM),
    ("N24", "CONTROL: a comment-only edit in the verifier",
     [(VERIFY, "## ## Mocking\n##\n## None. Real ECDSA, real DER, the production chain evaluator.",
               "## ## Mocking\n##\n## None. Real ECDSA, real DER, the production chain evaluator.\n## (control edit)")],
     None),
]


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def build_and_run(stem, tag, no_define=False):
    src = "tests/integration/%s.nim" % stem
    binary = os.path.join(OUT, "%s.%s" % (stem, tag))
    log = binary + ".log"
    with open(log, "w") as fh:
        cmd = ["nim", "c"] + ([] if no_define else [DEFINE]) + ["-o:" + binary, src]
        rc = subprocess.call(cmd,
                             cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT)
    if rc != 0:
        return "COMPILE-REFUSED", log
    with open(log, "a") as fh:
        rc = subprocess.call([binary], cwd=ROOT, stdout=fh,
                             stderr=subprocess.STDOUT)
    return ("GREEN" if rc == 0 else "RED"), log


def stem_of(path):
    return os.path.basename(path)[:-4]


def main():
    os.makedirs(OUT, exist_ok=True)
    wanted = set(sys.argv[1:])
    rows = [r for r in ROWS if not wanted or r[0] in wanted]

    # Pre-flight: every row's original string must be present exactly once,
    # and no mutated form may already be in the tree. A contaminated tree
    # turns the whole table into noise.
    for row in rows:
        rid, edits = row[0], row[2]
        for path, old, new in edits:
            body = open(os.path.join(ROOT, path)).read()
            if body.count(old) != 1:
                print("PREFLIGHT FAIL %s: %s occurs %d times in %s"
                      % (rid, old[:50].replace("\n", "\\n"),
                         body.count(old), path))
                return 2
    print("preflight: %d rows, every original string present exactly once"
          % len(rows))

    results = []
    for row in rows:
        rid, desc, edits, gate = row[0], row[1], row[2], row[3]
        no_define = len(row) > 4 and row[4]
        originals = {}
        for path, _, _ in edits:
            full = os.path.join(ROOT, path)
            if full not in originals:
                originals[full] = open(full).read()
        before = {p: sha(p) for p in originals}
        try:
            for path, old, new in edits:
                full = os.path.join(ROOT, path)
                body = open(full).read()
                assert body.count(old) == 1, (rid, path)
                open(full, "w").write(body.replace(old, new, 1))
            targets = [gate] if gate else [G_MUT, G_COM, G_E2E]
            observed = []
            for t in targets:
                started = time.time()
                verdict, log = build_and_run(stem_of(t), rid, no_define)
                cases = 0
                failed = 0
                try:
                    text = open(log).read()
                    cases = text.count("[OK]")
                    failed = text.count("[FAILED]")
                except OSError:
                    pass
                observed.append("%s %s (%d OK / %d FAILED, %ds)"
                                % (stem_of(t), verdict, cases, failed,
                                   int(time.time() - started)))
            results.append((rid, desc, "; ".join(observed)))
        finally:
            for path, body in originals.items():
                open(path, "w").write(body)
            for path, digest in before.items():
                assert sha(path) == digest, "restore failed for " + path
        print("%-4s %s\n      %s" % (rid, desc, results[-1][2]), flush=True)

    with open(os.path.join(OUT, "executed.tsv"), "w") as fh:
        fh.write("id\tmutation\tobserved\n")
        for rid, desc, obs in results:
            fh.write("%s\t%s\t%s\n" % (rid, desc, obs))
    print("\nwrote %s/executed.tsv" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
