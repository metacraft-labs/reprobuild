## TC-8b — an EARLIER-DRAFT certificate is rejected with a re-issue remedy,
## and is never translated.
##
## Until the standard's 2026-10-09 revision a ``test-certificate.v1`` record
## named a ``commit`` with a ``clean`` flag; TC-7 issued exactly that shape.
## The revision kept the schema id and made ``content`` required, so such a
## record now lacks a required field: it is DECIDABLY INVALID — not covered,
## never unverifiable (Canonical-Payload §7.1, Standard §7). The remedy is to
## run the tests again, which issues a record in the current shape.
##
## It MUST NOT be translated. Deriving ``content`` from the record's commit
## and keeping its signature would present a payload its signer never signed;
## the test proves no such path exists by trying it: the signature, genuine
## over the earlier-draft bytes, verifies over no translation of them.
##
## Sub-cases:
##   1. a verbatim TC-7 record, SIGNED with a real ed25519 key over its own
##      (earlier-draft) canonical payload — the premise is checked: that
##      signature verifies over those bytes;
##   2. the reader classifies it as an earlier-draft record, apart from a
##      damaged one, and the message names re-issuing (``repro test`` /
##      ``repro certify``) and says it is not translated; the raising reader
##      and the note reader carry the same refusal;
##   3. the three-valued evaluator REJECTS it (not-covered, nothing
##      unevaluated) at the very commit it names, whose tree is real;
##   4. the translation, attempted: its own fields with ``content`` taken from
##      that commit's tree (with and without ``base``) — the signature
##      verifies over none of it, under the real key store.

import std/[os, osproc, strutils, unittest]

import repro_cli_support
import repro_cli_support/content_id
import content_id_fixture

const keyId = "tc7-era-key"

proc earlierDraftPayload(commit: string): string =
  ## Byte for byte, the canonical payload TC-7 signed: ``repo``, ``commit``,
  ## ``clean``, ``untracked`` in ``[certificate.vcs]``.
  "schema = \"test-certificate.v1\"\n\n" &
  "[certificate]\n" &
  "framework = \"reprobuild\"\n" &
  "project = \"lib-a\"\n" &
  "platform = \"linux/amd64\"\n" &
  "targets = [\"t-integration\", \"t-unit\"]\n" &
  "result = \"passed\"\n" &
  "issued_at = \"2026-06-23T10:14:33Z\"\n" &
  "issuer = \"repro-test@build-host-7\"\n" &
  "key_id = \"" & keyId & "\"\n\n" &
  "[certificate.vcs]\n" &
  "repo = \"lib-a\"\n" &
  "commit = \"" & commit & "\"\n" &
  "clean = true\n" &
  "untracked = false\n\n" &
  "[[certificate.command]]\n" &
  "argv = [\"repro\", \"test\", \"--targets\", \"t-integration,t-unit\"]\n"

proc sshSign(keyPath, payload, scratch: string): string =
  ## A real detached SSH signature over ``payload`` under the standard's
  ## namespace, as the single-line base64 blob a record carries.
  let payloadPath = scratch / "payload.txt"
  writeFile(payloadPath, payload)
  # ``ssh-keygen -Y sign`` does not replace an existing ``.sig``.
  removeFile(payloadPath & ".sig")
  let res = execCmdEx(quoteShellCommand(@[findExe("ssh-keygen"), "-Y", "sign",
    "-f", keyPath, "-n", certificateSignatureNamespace, payloadPath]))
  doAssert res.exitCode == 0, "ssh-keygen -Y sign failed: " & res.output
  sshSignatureBlobBase64(readFile(payloadPath & ".sig"))

proc requirement(): VerificationRequirement =
  VerificationRequirement(
    frameworksImplemented: @[reprobuildFrameworkId],
    framework: reprobuildFrameworkId,
    targets: @["t-integration", "t-unit"],
    platforms: @["linux/amd64"],
    requireSignature: true)

suite "TC-8b — the earlier-draft boundary":

  test "t_earlier_draft_certificate_is_rejected_with_a_reissue_remedy":
    if findExe("ssh-keygen").len == 0:
      checkpoint("ssh-keygen is required: the record under test is signed")
      fail()
    else:
      let scratch = enterHermeticGit()
      let repo = newRepo(scratch, "lib-a")
      writeEntryFile(repo, "src/lib.nim", "proc f*() = discard\n")
      commitAll(repo, "tested")
      let commit = gitLine(repo, "rev-parse", "HEAD")
      let tree = "git-tree-sha1:" & gitLine(repo, "rev-parse", "HEAD^{tree}")

      # --- 1. a verbatim TC-7 record, genuinely signed --------------------
      let keyPath = scratch / "tc7-key"
      let gen = execCmdEx(quoteShellCommand(@[findExe("ssh-keygen"), "-q",
        "-t", "ed25519", "-N", "", "-C", keyId, "-f", keyPath]))
      doAssert gen.exitCode == 0, gen.output
      let publicKey = readFile(keyPath & ".pub").strip()
      let oldPayload = earlierDraftPayload(commit)
      let signature = sshSign(keyPath, oldPayload, scratch)
      # The premise: the signature is real, over exactly these bytes.
      check verifyDetachedCertificateSignature(oldPayload, publicKey,
        signature) == scValid
      let record = oldPayload & "\n[certificate.signature]\n" &
        "algorithm = \"ed25519\"\nvalue = \"" & signature & "\"\n"
      var store = RegisteredKeyStore()
      registerKey(store, keyId, publicKey)

      # --- 2. classified as an earlier draft, with the re-issue remedy ----
      let read = readCertificateRecord(record)
      check read.status == crsEarlierDraft
      check read.status != crsMalformed      # not "this file is damaged"
      check read.schemaSeen == testCertificateSchemaV1
      let detail = read.detail.toLowerAscii()
      check "re-issue" in detail
      check "repro test" in detail
      check "repro certify" in detail
      check "not translated" in detail
      check "vcs.content" in detail
      var raised = ""
      try:
        discard parseCertificateFromToml(record)
      except TestCertificateParseError as err:
        raised = err.msg
      check "re-issue" in raised
      # A damaged v1 record is a different finding, with no re-issue remedy.
      let damaged = readCertificateRecord(record.replace(
        "clean = true", "clean = maybe"))
      check damaged.status == crsMalformed
      check "re-issue" notin damaged.detail
      # The note carrier does not hand it to a gate as evidence either. (Noted
      # on the commit's TREE, where a reader evaluating the commit looks,
      # TC-8c; it is handed on as the earlier-draft record it is, so the
      # verifier reports it with the re-issue remedy.)
      writeFile(scratch / "note.txt", "# --- test-certificate ---\n" &
        record)
      discard execCmdEx(quoteShellCommand(@[findExe("git"), "-C", repo,
        "notes", "--ref", certificateNotesRef, "add", "-F",
        scratch / "note.txt", commit & "^{tree}"]))
      let noted = readAttachedCertificatesFrom(findExe("git"), repo, commit,
        certificateNotesRef)
      check noted.status == gorPresent
      check noted.certs.len == 0
      check noted.found.len == 1 and
        noted.found[0].read.status == crsEarlierDraft

      # --- 3. REJECTED at the commit it names — not unverifiable ----------
      let atCommit = commitUnderEvaluation(repo, commit, "lib-a")
      let report = evaluateCertificates(@[FoundCertificate(
          name: "earlier-draft.toml", read: read)],
        atCommit, requirement(), store)
      check report.outcome == voNotCovered
      check report.rejected.len == 1
      check report.rejected[0].certificate == "earlier-draft.toml"
      check "re-issue" in report.rejected[0].why
      check report.unevaluated.len == 0
      check report.missing.len == 1

      # --- 4. the translation, attempted, verifies against nothing --------
      # Its own fields, ``content`` synthesised from its commit's tree — the
      # one translation that would make it cover that commit.
      var translated = read.cert
      check translated.vcs.content.len == 0   # the reader invented nothing
      translated.vcs.content = tree
      check readCertificateRecord(serializeCertificateToToml(translated)).status ==
        crsOk                                 # well-formed in the new shape…
      for base in ["", commit]:
        translated.vcs.base = base
        checkpoint("translated, base = '" & base & "'")
        # …and its signature covers none of it.
        check verifyCertificateSignature(translated, store) != svValid
        check verifyDetachedCertificateSignature(
          canonicalCertificatePayload(translated), publicKey, signature) ==
            scInvalid
        let translatedReport = evaluateCertificates(@[FoundCertificate(
            name: "translated.toml",
            read: readCertificateRecord(serializeCertificateToToml(translated)))],
          atCommit, requirement(), store)
        check translatedReport.outcome == voNotCovered
        check translatedReport.rejected.len == 1
      # The content binding itself is not what failed: an honestly RE-ISSUED
      # record for the same commit, signed over its own payload, is covered.
      var reissued = translated
      reissued.vcs.base = commit
      reissued.signature = TestCertificateSignature(algorithm: "ed25519",
        value: sshSign(keyPath, canonicalCertificatePayload(reissued), scratch))
      let reissuedReport = evaluateCertificates(@[FoundCertificate(
          name: "reissued.toml",
          read: readCertificateRecord(serializeCertificateToToml(reissued)))],
        atCommit, requirement(), store)
      check reissuedReport.outcome == voCovered
      removeDir(scratch)
