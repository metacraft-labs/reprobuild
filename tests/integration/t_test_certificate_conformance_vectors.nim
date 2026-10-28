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
## Every group runs, because partial conformance is not a status the standard
## recognises (counts at the pinned revision):
##   * ``payload/``   — byte-exact canonical serialization (16 cases), and the
##                      non-canonical ``received.toml`` rendering;
##   * ``signature/`` — detached-signature verification (6 cases), checking
##                      the REASON ``wrong-namespace`` fails, not only that it
##                      does;
##   * ``content/``   — content ids (7 cases, 29 ids) computed from the entry
##                      lists with the TC-8a library (``t_content_id_vectors_
##                      match_the_conformance_suite`` re-derives them through
##                      git three ways as well);
##   * ``verify/``    — the three-valued decision (17 cases), the state given
##                      as the content ids ``state.json`` lists, so an
##                      algorithm it does not list is one this consumer cannot
##                      compute;
##   * ``store/``     — the store path of each certificate (7 cases), derived
##                      from the PARSED certificate and compared with the
##                      hand-derived ``expected-path.txt``;
##   * ``notes/``     — note framing (9 cases): ``note.txt`` read through
##                      reprobuild's note reader (``readCertificateNote``),
##                      which must yield exactly the records and skipped pieces
##                      ``expected.json`` lists; and, for the four writer
##                      cases, ``add.txt`` added through the note writer
##                      (``addCertificateToNote``), which must produce
##                      ``expected-note.txt`` byte for byte.
## ``index.json`` is cross-checked in BOTH directions over every group, and a
## group the walker does not know — on disk or in the index — is a FAILURE:
## a fifth group once arrived that the previous walker silently ignored.
##
## Which revision: the suite is read at the revision pinned in
## ``content_id/test-certificates-spec-content-vectors.pin`` (``spec_vectors_
## pin``), extracted from the sibling's object store with ``git archive``. The
## walker prints that revision. An absent sibling, or a pin missing from its
## object store, FAILS naming what to fetch; it never skips.
## ``TEST_CERTIFICATES_SPEC`` still overrides where the sibling is.

import std/[algorithm, base64, json, os, sequtils, sets, strutils, tempfiles,
            unittest]

import repro_cli_support
import repro_cli_support/content_id
import spec_vectors_pin

const
  knownGroups = ["payload", "signature", "content", "verify", "store",
                 "notes"]
  expectedCounts = {"payload": 16, "signature": 6, "content": 7,
                    "verify": 17, "store": 7, "notes": 9}

# ---------------------------------------------------------------------------
# fields.json -> TestCertificate
#
# The values are INPUTS, not canonical output: targets and paths arrive in
# whatever order the producer observed them and may contain duplicates, and
# key_id / paths / base are absent when they do not apply. Sorting,
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
  if v.hasKey("paths"): result.vcs.paths = strings(v["paths"])
  result.vcs.content = v{"content"}.getStr()
  result.vcs.untracked = v{"untracked"}.getBool()
  if v.hasKey("base"): result.vcs.base = v["base"].getStr()
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

proc stateFromJson(node: JsonNode): CertificateState =
  ## The state is what the consumer can compute for it, handed over as ids.
  ## ``commit`` is informational and deliberately NOT carried: nothing may
  ## compare a certificate with it (Verification §4.1.1).
  var known: seq[KnownContentId]
  if node.hasKey("content"):
    for entry in node["content"]:
      known.add(KnownContentId(algorithm: entry{"algorithm"}.getStr(),
        paths: strings(entry{"paths"}), id: entry{"id"}.getStr()))
  stateWithKnownContent(known, repo = node{"repo"}.getStr())

proc namesOf(notes: seq[CertificateNote]): HashSet[string] =
  for n in notes: result.incl(n.certificate)

proc expectedNames(node: JsonNode; key: string): HashSet[string] =
  if node.hasKey(key):
    for entry in node[key]:
      result.incl(entry{"certificate"}.getStr())

proc caseDirs(root, group: string): seq[string] =
  for kind, path in walkDir(root / group):
    if kind != pcDir: continue
    if group == "signature" and path.extractFilename == "keys":
      continue                      # the published, worthless keys
    result.add(path)
  sort(result)

suite "test-certificate.v1 conformance vectors":

  test "t_test_certificate_conformance_vectors":
    let scratch = createTempDir("repro-tc-vectors-", "")
    defer: removeDir(scratch)
    let extracted = extractPinnedVectors(scratch)
    if extracted.error.len > 0:
      checkpoint(extracted.error)
      fail()
    elif findExe("ssh-keygen").len == 0:
      # The signature group needs the real ed25519 verifier, and it is the
      # ONLY guard against the armored-signature framing defect TC-7 found, so
      # a missing verifier fails the walker rather than skipping a group.
      checkpoint("ssh-keygen is required for the signature group")
      fail()
    else:
      let root = extracted.root
      echo "  conformance vectors: test-certificates-spec ", extracted.pin,
        " (", extracted.sibling, ")"
      let index = parseFile(root / "index.json")
      # The suite's own namespace declaration must be the one we sign under.
      check index{"namespace"}.getStr() == certificateSignatureNamespace

      # --- the groups themselves ------------------------------------------
      # A group the walker does not know is a failure, in either place. The
      # previous walker silently ignored ``content/``; a sixth group must not
      # repeat that.
      var onDisk, inIndex: HashSet[string]
      for kind, path in walkDir(root):
        if kind == pcDir: onDisk.incl(path.extractFilename)
      for group, _ in index{"groups"}.pairs:
        inIndex.incl(group)
      let known = toHashSet(knownGroups)
      if onDisk != known or inIndex != known:
        checkpoint("vector groups: on disk " & $onDisk & ", in index.json " &
          $inIndex & ", walked by this walker " & $known)
      check onDisk == known
      check inIndex == known

      var walked: array[knownGroups.len, HashSet[string]]
      template walkedOf(group: string): untyped =
        walked[knownGroups.find(group)]

      # --- group 1: payload/ — byte-exact canonical serialization ---------
      for path in caseDirs(root, "payload"):
        let name = path.extractFilename
        walkedOf("payload").incl(name)
        let fields = parseFile(path / "fields.json")
        let expected = readFile(path / "canonical.txt")
        let produced = canonicalCertificatePayload(certificateFromFields(fields))
        if produced != expected:
          checkpoint("payload/" & name & ": " &
            firstDifference(produced, expected) &
            "\n--- produced ---\n" & renderBytes(produced) &
            "\n--- expected ---\n" & renderBytes(expected))
        check produced == expected
        # The canonical bytes, parsed back, reproduce themselves.
        let reread = readCertificateRecord(expected)
        if reread.status != crsOk:
          checkpoint("payload/" & name & "/canonical.txt: " & reread.detail)
        check reread.status == crsOk
        check canonicalCertificatePayload(reread.cert) == expected
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
      for path in caseDirs(root, "signature"):
        let name = path.extractFilename
        walkedOf("signature").incl(name)
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

      # --- group 3: content/ — content ids from entry lists ---------------
      var contentIds = 0
      for path in caseDirs(root, "content"):
        let name = path.extractFilename
        walkedOf("content").incl(name)
        var entries: seq[ContentEntry]
        for node in parseFile(path / "entries.json"):
          entries.add(ContentEntry(path: node["path"].getStr(),
            mode: node["mode"].getStr(),
            content: decode(node["content_b64"].getStr())))
        for expectedNode in parseFile(path / "expected.json"):
          let algorithmName = expectedNode["algorithm"].getStr()
          let scope = strings(expectedNode["paths"])
          let expected = expectedNode["id"].getStr()
          let (algorithmKnown, algorithm) = lookupContentAlgorithm(algorithmName)
          # Every algorithm the suite uses is one this implementation
          # computes; skipping an implemented algorithm's vectors would test
          # nothing.
          check algorithmKnown
          let produced =
            if algorithm == caManifestV1Sha256: manifestV1Sha256(entries, scope)
            else: gitTreeIdOfEntries(entries, algorithm, scope)
          if produced.id != expected:
            checkpoint("content/" & name & " " & algorithmName & " " &
              $scope & ": produced " & produced.id & " (" & produced.reason &
              "), expected " & expected)
          check produced.outcome == cioComputed
          check produced.id == expected
          inc contentIds
      check contentIds == 29

      # --- group 4: verify/ — the three-valued decision -------------------
      var verifyOutcomes: HashSet[string]
      for path in caseDirs(root, "verify"):
        let name = path.extractFilename
        walkedOf("verify").incl(name)
        let state = stateFromJson(parseFile(path / "state.json"))
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
        verifyOutcomes.incl(name & "=" & $report.outcome)
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
      # The cases the content binding exists for are REACHED, with the
      # outcome each pins (the loop above asserts it; this asserts they ran).
      for reached in ["content-matches-other-base=covered",
                      "content-differs=not-covered",
                      "content-unknown-algorithm=unverifiable",
                      "content-malformed=not-covered",
                      "earlier-draft-record=not-covered"]:
        check reached in verifyOutcomes

      # Direct API callers must obey the same content-id grammar as record
      # verification. Rejection happens before any store directory is touched.
      var invalidStoreIds = @["git-tree-sha1:abc", "future:xyz", "future:AB"]
      for algorithm in ["../escape", "future/hash", "future\\hash", ".", "..",
          "Upper", "future_hash", "future hash", "future\n", "future\0",
          "futuré", repeat('a', 65), "con", "prn", "aux", "nul"]:
        invalidStoreIds.add(algorithm & ":abc")
      for prefix in ["com", "lpt"]:
        for number in 1 .. 9:
          invalidStoreIds.add(prefix & $number & ":abc")
      let templateCert = readCertificateRecord(readFile(root / "store" /
        "unsigned" / "certificate.toml"))
      require templateCert.status == crsOk
      for id in invalidStoreIds:
        checkpoint("invalid store content id: " & id.escape())
        var cert = templateCert.cert
        cert.vcs.content = id
        check certificateStoreRelativePath(cert) == ""
        check not storeContentDir(id).ok
        let writeRoot = scratch / "invalid-store-root"
        # JSON string quoting supplies TOML-compatible escapes even for NUL,
        # which the canonical serializer rightly refuses to emit.
        let document = serializeCertificateToToml(templateCert.cert).replace(
          "content = " & $(%templateCert.cert.vcs.content),
          "content = " & $(%id))
        let published = publishCertificateDocument(writeRoot, document)
        check published.error.len > 0
        check published.path == ""
        check not dirExists(writeRoot)
        let roots = CertificateStoreRoots(user: writeRoot)
        let issued = publishCertificateToLocalStore(cert, "", roots)
        check not issued.written
        check issued.error.len > 0
        check issued.path == ""
        let state = stateWithKnownContent(@[KnownContentId(id: id)])
        let lookup = findCertificatesInLocalStore(state, roots)
        check lookup.searched.len == 0
        check lookup.problems.len > 0
        check not dirExists(writeRoot)

      # Relaying an opaque but well-formed claim must remain possible through
      # the same public APIs that reject the malformed inputs above.
      var unknownCert = templateCert.cert
      unknownCert.vcs.content = "future-v2:a"
      let unknownRoot = scratch / "unknown-store-root"
      let unknownPath = certificateStoreRelativePath(unknownCert)
      check unknownPath.startsWith("v1/future-v2/a/")
      let unknownDocument = serializeCertificateToToml(unknownCert)
      let relayed = publishCertificateDocument(unknownRoot, unknownDocument)
      check relayed.error == ""
      check relayed.path == unknownRoot / unknownPath.replace('/', DirSep)
      check fileExists(relayed.path)
      let unknownState = stateWithKnownContent(@[
        KnownContentId(algorithm: "future-v2", id: "future-v2:a")])
      let foundUnknown = findCertificatesInLocalStore(unknownState,
        CertificateStoreRoots(user: unknownRoot))
      check foundUnknown.problems.len == 0
      require foundUnknown.found.len == 1
      check foundUnknown.found[0].read.cert.vcs.content == "future-v2:a"

      # --- group 5: store/ — where the local store keeps a certificate ----
      for path in caseDirs(root, "store"):
        let name = path.extractFilename
        walkedOf("store").incl(name)
        # The name is derived from the PARSED certificate — its canonical
        # payload — never from the file, which may be non-canonical and may
        # carry a signature block (Transport §2.2).
        let read = readCertificateRecord(readFile(path / "certificate.toml"))
        if read.status != crsOk:
          checkpoint("store/" & name & "/certificate.toml: " & read.detail)
        check read.status == crsOk
        let canonical = readFile(path / "canonical.txt")
        let payload = canonicalCertificatePayload(read.cert)
        if payload != canonical:
          checkpoint("store/" & name & ": " & firstDifference(payload, canonical) &
            "\n--- produced ---\n" & renderBytes(payload))
        check payload == canonical
        # One line terminated by a single LF that is not part of the path.
        var expectedPath = readFile(path / "expected-path.txt")
        check expectedPath.endsWith("\n")
        expectedPath.setLen(expectedPath.len - 1)
        check '\n' notin expectedPath
        let produced = certificateStoreRelativePath(read.cert)
        if produced != expectedPath:
          checkpoint("store/" & name & ": produced " & produced &
            ", expected " & expectedPath)
        check produced == expectedPath
        # TC-8c: and the WRITER puts it there. The vector's own bytes, written
        # through the producer's store writer into an empty root, land at
        # exactly the expected path, verbatim.
        let writeRoot = scratch / "store-roots" / name
        let document = readFile(path / "certificate.toml")
        let published = publishCertificateDocument(writeRoot, document)
        check published.error == ""
        check published.path ==
          writeRoot / expectedPath.replace('/', DirSep)
        check fileExists(published.path) and
          readFile(published.path) == document

      # --- store/: a name collision (Transport §2.3) ----------------------
      # ``signed-non-canonical-no-block`` is ``signed`` with its signature
      # block removed: the same canonical payload, so the same name. Written
      # into one root, the SIGNED copy replaces an unsigned one, and an
      # unsigned one never replaces a signed one.
      block:
        let twins = scratch / "store-twins"
        let unsignedDoc = readFile(root / "store" /
          "signed-non-canonical-no-block" / "certificate.toml")
        let signedDoc = readFile(root / "store" / "signed" /
          "certificate.toml")
        let first = publishCertificateDocument(twins, unsignedDoc)
        check first.error == "" and not first.kept
        let second = publishCertificateDocument(twins, signedDoc)
        check second.error == "" and not second.kept
        check second.path == first.path
        check readFile(second.path) == signedDoc
        let third = publishCertificateDocument(twins, unsignedDoc)
        check third.error == "" and third.kept
        check readFile(third.path) == signedDoc

      # --- group 6: notes/ — note framing (Transport §3.1) ----------------
      # Through reprobuild's REAL note reader and writer — the code that reads
      # the note a push carries and writes the note an issuance attaches —
      # not a second splitter written for the test.
      let vectorKey = readFile(root / "signature" / "keys" /
        "insecure-test-key.pub").strip()
      var writerCases = 0
      for path in caseDirs(root, "notes"):
        let name = path.extractFilename
        walkedOf("notes").incl(name)
        let note = readFile(path / "note.txt")
        let want = parseFile(path / "expected.json"){"pieces"}
        let got = readCertificateNote(note)
        if got.len != want.len:
          checkpoint("notes/" & name & ": read " & $got.len &
            " pieces, expected " & $want.len)
        check got.len == want.len
        for i in 0 ..< min(got.len, want.len):
          let entry = got[i]
          let expected = want[i]
          let label = "notes/" & name & " piece " & $(i + 1)
          if expected{"skipped"}.getBool():
            # Reported and skipped: never yielded as a record. A leading
            # piece is never even parsed, though ``foreign-preamble``'s would
            # parse.
            if entry.read.status == crsOk:
              checkpoint(label & ": expected skipped, read a record")
            check entry.read.status != crsOk
            check entry.read.detail.len > 0
            if i == 0 and name == "foreign-preamble":
              check entry.piece.leading
              check certificateNoteDelimiter in entry.read.detail
            continue
          check not entry.piece.leading
          if entry.read.status != crsOk:
            checkpoint(label & ": " & entry.read.detail)
            check entry.read.status == crsOk
            continue
          # The canonical payload REBUILT FROM THE PARSED FIELDS.
          let payload = canonicalCertificatePayload(entry.read.cert)
          let expectedPayload = expected{"payload"}.getStr()
          if payload != expectedPayload:
            checkpoint(label & ": " & firstDifference(payload,
              expectedPayload) & "\n--- produced ---\n" & renderBytes(payload))
          check payload == expectedPayload
          check entry.read.cert.isSigned == expected{"signed"}.getBool()
          if entry.read.cert.isSigned:
            let verdict = verifyDetachedCertificateSignature(payload,
              vectorKey, entry.read.cert.signature.value)
            if verdict != scValid:
              checkpoint(label & ": signature " & $verdict)
            check verdict == scValid
          # A conforming note holds records in the §3.1 record form, which is
          # exactly what the writer renders.
          check certificateNoteRecord(entry.read.cert) == entry.piece.text
        # Writer half: add ``add.txt`` and produce ``expected-note.txt``.
        if fileExists(path / "add.txt"):
          inc writerCases
          check fileExists(path / "expected-note.txt")
          let addText = readFile(path / "add.txt")
          let added = readCertificateRecord(addText)
          if added.status != crsOk:
            checkpoint("notes/" & name & "/add.txt: " & added.detail)
          check added.status == crsOk
          # The record the writer renders for it is ``add.txt`` itself.
          check certificateNoteRecord(added.cert) == addText
          let produced = addCertificateToNote(note, added.cert)
          let expectedNote = readFile(path / "expected-note.txt")
          if produced.note != expectedNote:
            checkpoint("notes/" & name & ": " &
              firstDifference(produced.note, expectedNote) &
              "\n--- produced ---\n" & renderBytes(produced.note))
          check produced.note == expectedNote
          check produced.changed == (expectedNote != note)
        else:
          check not fileExists(path / "expected-note.txt")
      check writerCases == 4

      # --- index.json cross-check, BOTH directions, EVERY group -----------
      # A case that has silently gone missing is a case that stops testing
      # anything, and a case on disk that the index does not know about is a
      # suite drifting out of its own contract.
      let groups = index{"groups"}
      for group in knownGroups:
        var listed: HashSet[string]
        if groups.hasKey(group):
          for entry in groups[group]:
            listed.incl(entry{"name"}.getStr())
        let walkedHere = walkedOf(group)
        if listed != walkedHere:
          checkpoint("index.json/" & group & ": listed-but-absent " &
            $(listed - walkedHere) & ", present-but-unlisted " &
            $(walkedHere - listed))
        check listed == walkedHere
      # The counts at the pinned revision, so a suite that shrinks is loud.
      for (group, count) in expectedCounts:
        if walkedOf(group).len != count:
          checkpoint(group & ": walked " & $walkedOf(group).len &
            " cases, expected " & $count)
        check walkedOf(group).len == count
