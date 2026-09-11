## Conformance — reprobuild walks the ``test-certificates-spec`` vector suite.
##
## The vectors are the executable half of the standard: two implementations
## written from the same prose, by different people, in different languages,
## will differ wherever the prose can be misread, and a one-byte disagreement
## in the canonical payload produces signatures neither side can verify while
## everything else appears to agree.
##
## THIS WALKER IS REPROBUILD'S OWN, ON PURPOSE. The suite ships as plain data
## with no runner precisely so that each implementation writes its own: two
## implementations sharing a walker prove nothing about two implementations.
## Nothing here is imported, ported or copied from the spec repo's ``tools/``
## (explicitly non-normative) or from CodeTracer's walker; the only inputs are
## the directory contract in ``vectors/README.md`` and the bytes on disk.
##
## All three groups run, because partial conformance is not a status the
## standard recognises:
##   * ``payload/``   — byte-exact canonical serialization (17 cases)
##   * ``signature/`` — detached-signature verification (6 cases)
##   * ``verify/``    — the three-valued verification decision (15 cases)
## and ``index.json`` is cross-checked in BOTH directions, so a case that
## silently disappears is a failure rather than a quietly smaller suite.
##
## Skip rule: the ``test-certificates-spec`` sibling is absent (set
## ``TEST_CERTIFICATES_SPEC`` to point at it), or ``ssh-keygen`` is missing
## (the signature group needs the real ed25519 verifier).

import std/[algorithm, json, os, sequtils, sets, strutils, unittest]

import repro_cli_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc vectorsRoot(): string =
  ## ``$TEST_CERTIFICATES_SPEC`` first (an explicit operator override), then
  ## the workspace sibling. Returns "" when neither carries the suite.
  for candidate in [getEnv("TEST_CERTIFICATES_SPEC"),
                    repoRoot().parentDir / "test-certificates-spec"]:
    if candidate.len > 0 and fileExists(candidate / "vectors" / "index.json"):
      return candidate / "vectors"
  ""

# ---------------------------------------------------------------------------
# fields.json -> TestCertificate
#
# The values are INPUTS, not canonical output: targets and paths arrive in
# whatever order the producer observed them and may contain duplicates, and
# key_id / paths / worktree are absent when they do not apply. Sorting,
# deduplication and omission are the serializer's job, which is exactly what
# this group measures.
# ---------------------------------------------------------------------------

proc strings(node: JsonNode): seq[string] =
  if node == nil or node.kind != JArray: return
  for item in node: result.add(item.getStr())

proc certificateFromFields(fields: JsonNode): TestCertificate =
  result.schema = fields{"schema"}.getStr()
  let c = fields{"certificate"}
  result.framework = c{"framework"}.getStr()
  result.project = c{"project"}.getStr()
  result.platform = c{"platform"}.getStr()
  result.targets = strings(c{"targets"})
  result.result =
    if c{"result"}.getStr() == "failed": tcrFailed else: tcrPassed
  result.issuedAt = c{"issued_at"}.getStr()
  result.issuer = c{"issuer"}.getStr()
  if c.hasKey("key_id"): result.keyId = c["key_id"].getStr()
  let v = c{"vcs"}
  result.vcs.repo = v{"repo"}.getStr()
  result.vcs.commit = v{"commit"}.getStr()
  if v.hasKey("paths"): result.vcs.paths = strings(v["paths"])
  result.vcs.clean = v{"clean"}.getBool()
  result.vcs.untracked = v{"untracked"}.getBool()
  if v.hasKey("worktree"):
    let w = v["worktree"]
    result.vcs.worktree.present = true
    result.vcs.worktree.tree = w{"tree"}.getStr()
    result.vcs.worktree.format = w{"format"}.getStr()
    result.vcs.worktree.patchDigest = w{"patch_digest"}.getStr()
  if c.hasKey("command"):
    for entry in c["command"]:
      result.commands.add(TestCertificateCommand(argv: strings(entry{"argv"})))

proc renderBytes(value: string): string =
  ## A byte-level rendering for a failure message. A canonical-payload
  ## mismatch is often invisible (a trailing space, CRLF, a `\/`), so the
  ## report has to show bytes rather than glyphs.
  result = newStringOfCap(value.len * 4)
  for ch in value:
    let code = ord(ch)
    if code == 0x0A: result.add("\\n\n")
    elif code < 0x20 or code >= 0x7F: result.add("\\x" & toHex(code, 2))
    else: result.add(ch)

proc firstDifference(a, b: string): string =
  var i = 0
  while i < a.len and i < b.len and a[i] == b[i]: inc i
  if i == a.len and i == b.len: return "identical"
  result = "first difference at byte " & $i & ": got " &
    (if i < a.len: "0x" & toHex(ord(a[i]), 2) else: "<end>") &
    ", expected " &
    (if i < b.len: "0x" & toHex(ord(b[i]), 2) else: "<end>")

# ---------------------------------------------------------------------------
# verify/ inputs
# ---------------------------------------------------------------------------

proc requirementFromJson(node: JsonNode): VerificationRequirement =
  result.frameworksImplemented = strings(node{"frameworks_implemented"})
  result.framework = node{"framework"}.getStr()
  result.targets = strings(node{"targets"})
  result.platforms = strings(node{"platforms"})
  result.requireSignature = node{"require_signature"}.getBool()
  if node.hasKey("paths") and node["paths"].kind == JArray:
    result.paths = strings(node["paths"])

proc namesOf(notes: seq[CertificateNote]): HashSet[string] =
  for n in notes: result.incl(n.certificate)

proc expectedNames(node: JsonNode; key: string): HashSet[string] =
  if node.hasKey(key):
    for entry in node[key]:
      result.incl(entry{"certificate"}.getStr())

suite "test-certificate.v1 conformance vectors":

  test "t_test_certificate_conformance_vectors":
    let root = vectorsRoot()
    if root.len == 0:
      checkpoint("test-certificates-spec sibling not found; set " &
        "TEST_CERTIFICATES_SPEC to the checkout that carries vectors/")
      skip()
    elif findExe("ssh-keygen").len == 0:
      checkpoint("ssh-keygen is required for the signature group")
      skip()
    else:
      let index = parseFile(root / "index.json")
      # The suite's own namespace declaration must be the one we sign under.
      check index{"namespace"}.getStr() == certificateSignatureNamespace

      # --- group 1: payload/ — byte-exact canonical serialization ---------
      var walkedPayload: HashSet[string]
      for kind, path in walkDir(root / "payload"):
        if kind != pcDir: continue
        let name = path.extractFilename
        walkedPayload.incl(name)
        let fields = parseFile(path / "fields.json")
        let expected = readFile(path / "canonical.txt")
        let produced = canonicalCertificatePayload(certificateFromFields(fields))
        if produced != expected:
          checkpoint("payload/" & name & ": " &
            firstDifference(produced, expected) &
            "\n--- produced ---\n" & renderBytes(produced) &
            "\n--- expected ---\n" & renderBytes(expected))
        check produced == expected
        # OPTIONAL: a deliberately non-canonical rendering of the SAME field
        # values must parse to exactly the same bytes. This is the property
        # that lets a cosmetically reformatted certificate still verify
        # against its own signature (Canonical-Payload §5).
        let received = path / "received.toml"
        if fileExists(received):
          let read = readCertificateRecord(readFile(received))
          if read.status != crsOk:
            checkpoint("payload/" & name & "/received.toml: " & read.detail)
          check read.status == crsOk
          let reserialized = canonicalCertificatePayload(read.cert)
          if reserialized != expected:
            checkpoint("payload/" & name & "/received.toml: " &
              firstDifference(reserialized, expected))
          check reserialized == expected

      # --- group 2: signature/ — verification, not reproduction -----------
      var walkedSignature: HashSet[string]
      for kind, path in walkDir(root / "signature"):
        if kind != pcDir: continue
        let name = path.extractFilename
        if name == "keys": continue      # the published, worthless keys
        walkedSignature.incl(name)
        let payload = readFile(path / "canonical.txt")
        let publicKey = readFile(path / "key.pub").strip()
        let signature = readFile(path / "signature.b64").strip()
        let expectVerify = readFile(path / "expect.txt").strip() == "verify"
        let verdict = verifyDetachedCertificateSignature(
          payload, publicKey, signature)
        if expectVerify:
          if verdict != scValid:
            checkpoint("signature/" & name & ": expected verify, got " & $verdict)
          check verdict == scValid
        else:
          if verdict == scValid:
            checkpoint("signature/" & name & ": expected fail, it verified")
          check verdict != scValid
        # CHECK THE REASON, NOT ONLY THE VERDICT. ``wrong-namespace`` carries a
        # GENUINE signature, by the right key, over exactly these bytes, made
        # under OpenSSH's ``git`` namespace — the one developers' commit and
        # tag signatures are made under. It must fail HERE and succeed THERE,
        # or the implementation has demonstrated nothing about domain
        # separation: it may simply have compared the payload wrongly.
        if name == "wrong-namespace":
          check verdict == scInvalid
          check verifyDetachedCertificateSignature(
            payload, publicKey, signature, namespace = "git") == scValid

      # --- group 3: verify/ — the three-valued decision -------------------
      var walkedVerify: HashSet[string]
      for kind, path in walkDir(root / "verify"):
        if kind != pcDir: continue
        let name = path.extractFilename
        walkedVerify.incl(name)
        let stateJson = parseFile(path / "state.json")
        let state = VerificationState(
          repo: stateJson{"repo"}.getStr(),
          commit: stateJson{"commit"}.getStr(),
          tree: stateJson{"tree"}.getStr())
        let requirement = requirementFromJson(parseFile(path / "requirement.json"))
        let loaded = readRegisteredKeyStoreChecked(path / "registered-keys.toml")
        var found: seq[FoundCertificate]
        var certNames: seq[string]
        for certKind, certPath in walkDir(path / "certificates"):
          if certKind == pcFile and certPath.endsWith(".toml"):
            certNames.add(certPath.extractFilename)
        sort(certNames)   # deterministic order; the decision must not depend on it
        for certName in certNames:
          found.add(FoundCertificate(name: certName,
            read: readCertificateRecord(
              readFile(path / "certificates" / certName))))
        # No framework-specific validity check: these certificates belong to
        # ``example-framework``, and applying reprobuild's own rules to another
        # framework's record is always wrong (Standard §4).
        let report = evaluateCertificates(found, state, requirement,
          loaded.store, loaded.availability)
        let expected = parseFile(path / "expected.json")
        if $report.outcome != expected{"outcome"}.getStr():
          checkpoint("verify/" & name & ": expected " &
            expected{"outcome"}.getStr() & ", got " & $report.outcome &
            " (rejected: " & report.rejected.mapIt(it.certificate & " — " &
              it.why).join("; ") &
            " | unevaluated: " & report.unevaluated.mapIt(it.certificate &
              " — " & it.why).join("; ") &
            " | ignored: " & report.ignored.mapIt(it.certificate).join("; ") & ")")
        check $report.outcome == expected{"outcome"}.getStr()
        # The GAPS are normative in content: which target, on which platform,
        # for which framework. The rendering is ours; the gaps are not.
        var producedMissing: HashSet[string]
        for m in report.missing:
          var targets = m.targets
          sort(targets)
          producedMissing.incl(m.framework & "|" & m.platform & "|" &
            targets.join(","))
        var expectedMissing: HashSet[string]
        if expected.hasKey("missing"):
          for m in expected["missing"]:
            var targets = strings(m{"targets"})
            sort(targets)
            expectedMissing.incl(m{"framework"}.getStr() & "|" &
              m{"platform"}.getStr() & "|" & targets.join(","))
        if producedMissing != expectedMissing:
          checkpoint("verify/" & name & ": missing mismatch — produced " &
            $producedMissing & ", expected " & $expectedMissing)
        check producedMissing == expectedMissing
        # ignored / rejected / unevaluated are normative in WHICH certificates
        # they name, because those three fates are the ones an implementation
        # confuses. The wording is ours and is not compared.
        for (label, produced, want) in [
            ("ignored", namesOf(report.ignored),
             expectedNames(expected, "ignored")),
            ("rejected", namesOf(report.rejected),
             expectedNames(expected, "rejected")),
            ("unevaluated", namesOf(report.unevaluated),
             expectedNames(expected, "unevaluated"))]:
          if produced != want:
            checkpoint("verify/" & name & ": " & label & " mismatch — " &
              "produced " & $produced & ", expected " & $want)
          check produced == want

      # --- index.json cross-check, BOTH directions ------------------------
      # A case that has silently gone missing is a case that stops testing
      # anything, and a case on disk that the index does not know about is a
      # suite drifting out of its own contract.
      let groups = index{"groups"}
      for (group, walked) in [("payload", walkedPayload),
                              ("signature", walkedSignature),
                              ("verify", walkedVerify)]:
        var listed: HashSet[string]
        for entry in groups{group}:
          listed.incl(entry{"name"}.getStr())
        if listed != walked:
          checkpoint("index.json/" & group & ": listed-but-absent " &
            $(listed - walked) & ", present-but-unlisted " & $(walked - listed))
        check listed == walked
      # The counts the milestone names, so a suite that shrinks is loud.
      check walkedPayload.len == 17
      check walkedSignature.len == 6
      check walkedVerify.len == 15
