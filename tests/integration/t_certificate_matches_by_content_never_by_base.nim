## TC-8b — a certificate matches by CONTENT, and never by ``base``.
##
## The standard's 2026-10-09 revision binds a certificate to the content of
## the tracked files, not to a commit (Standard §2.1, Verification §4.1.1). A
## verifier takes the algorithm from ``vcs.content``, computes it over the
## certificate's scope for the STATE under evaluation — a commit's tree, the
## index being committed, a working tree — and compares the strings.
## ``vcs.base`` names the commit checked out at issuance and is never
## compared: a certificate issued on top of one commit routinely covers the
## next.
##
## Real repositories, real git, the real verifier. The certificate's content
## id is computed here by git itself (``git write-tree`` of a temporary index,
## ``git rev-parse <commit>^{tree}``), never by the library under test.
##
## Sub-cases:
##   1. NEVER BY BASE, both directions. A certificate issued on top of commit A
##      (``base = A``), for content later committed as B, covers B; the SAME
##      certificate does NOT cover A, though ``base`` names A exactly.
##   2. The match holds across everything that is not content: B amended with
##      a new message (same tree, new commit id) is covered; a commit C with
##      different content is not.
##   3. Every kind of state: the working tree before B was committed, and the
##      index that committed it, are covered too.
##   4. A ``git-tree-sha256`` certificate evaluated in a SHA-1 repository is
##      UNVERIFIABLE — the consumer has not established a mismatch — not "not
##      covered".
##   5. A malformed content id is decidably INVALID (rejected), never repaired
##      and never unverifiable.
##   6. The carriers find and judge by content too (TC-8c): the local
##      certificate store finds a certificate issued on top of another commit
##      under the content id of the evaluated tree and reports a record filed
##      under a directory it does not name; the note on the tree keeps an
##      other-base record and reports an other-content one as misattached.

import std/[os, strutils, unittest]

import repro_cli_support
import ./certificate_note_seed
import repro_cli_support/content_id
import content_id_fixture

proc certFor(content, base: string; platform = "linux/amd64"): TestCertificate =
  TestCertificate(
    schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId,
    project: "lib-a",
    platform: platform,
    targets: @["t-integration", "t-unit"],
    result: tcrPassed,
    issuedAt: "2026-10-11T10:00:00Z",
    issuer: "repro-test@tc8b",
    vcs: TestCertificateVcs(repo: "lib-a", content: content, untracked: false,
      base: base),
    commands: @[TestCertificateCommand(argv: @["repro", "test"])])

proc found(name: string; c: TestCertificate): FoundCertificate =
  ## Through the real reader, from the real serialized bytes.
  FoundCertificate(name: name,
    read: readCertificateRecord(serializeCertificateToToml(c)))

proc requirement(): VerificationRequirement =
  VerificationRequirement(
    frameworksImplemented: @[reprobuildFrameworkId],
    framework: reprobuildFrameworkId,
    targets: @["t-integration", "t-unit"],
    platforms: @["linux/amd64"],
    requireSignature: false)

proc evaluate(c: TestCertificate; state: CertificateState;
              name = "cert.toml"): VerificationReport =
  evaluateCertificates(@[found(name, c)], state, requirement(),
    RegisteredKeyStore())

proc treeOf(repo, commit: string): string =
  "git-tree-sha1:" & gitLine(repo, "rev-parse", commit & "^{tree}")

suite "TC-8b — content matching":

  test "t_certificate_matches_by_content_never_by_base":
    let scratch = enterHermeticGit()
    let repo = newRepo(scratch, "lib-a")
    writeEntryFile(repo, "src/lib.nim", "proc f*() = discard\n")
    writeEntryFile(repo, "README.md", "lib-a\n")
    commitAll(repo, "A")
    let commitA = gitLine(repo, "rev-parse", "HEAD")

    # --- the developer edits, and the run certifies the WORKING TREE --------
    # on top of A. The content id is what git writes for those tracked files,
    # computed in a throwaway index so the user's index is untouched.
    writeEntryFile(repo, "src/lib.nim", "proc f*() = echo 1\n")
    let scratchIndex = scratch / "scratch-index"
    copyFile(repo / ".git" / "index", scratchIndex)
    discard runGitIn(repo, ["add", "--update"],
      env = [("GIT_INDEX_FILE", scratchIndex)])
    let testedTree = runGitIn(repo, ["write-tree"],
      env = [("GIT_INDEX_FILE", scratchIndex)]).stdout.strip()
    let tested = "git-tree-sha1:" & testedTree
    let cert = certFor(tested, base = commitA)
    check parseContentId(tested).form == cifWellFormed

    # --- 3a. the working tree it was issued for is covered ------------------
    let atWorkingTree = evaluate(cert, workingTreeUnderEvaluation(repo, "lib-a"))
    check atWorkingTree.outcome == voCovered

    # --- 3b. …and so is the index that commits exactly that ----------------
    discard git(repo, "add", "src/lib.nim")
    let atIndex = evaluate(cert, indexUnderEvaluation(repo, "lib-a"))
    check atIndex.outcome == voCovered

    discard git(repo, "commit", "-q", "-m", "B")
    let commitB = gitLine(repo, "rev-parse", "HEAD")
    check commitB != commitA
    check treeOf(repo, commitB) == tested

    # --- 1. NEVER BY BASE, both directions ----------------------------------
    # base = A, content = B's tree: covers B…
    let atB = evaluate(cert, commitUnderEvaluation(repo, commitB, "lib-a"))
    check atB.outcome == voCovered
    check atB.rejected.len == 0
    # …and does NOT cover A, although base names A exactly. A verifier that
    # compared base would get both of these wrong.
    let atA = evaluate(cert, commitUnderEvaluation(repo, commitA, "lib-a"))
    check atA.outcome == voNotCovered
    check atA.rejected.len == 1
    check atA.unevaluated.len == 0
    check "content" in atA.rejected[0].why
    # The relevance predicate every gate shares agrees.
    let reqB = CoverageRequirement(framework: reprobuildFrameworkId,
      state: commitUnderEvaluation(repo, commitB, "lib-a"),
      platform: "linux/amd64", requiredTargets: @["t-unit"])
    let reqA = CoverageRequirement(framework: reprobuildFrameworkId,
      state: commitUnderEvaluation(repo, commitA, "lib-a"),
      platform: "linux/amd64", requiredTargets: @["t-unit"])
    check certificateMatches(cert, reqB)
    check not certificateMatches(cert, reqA)
    # A certificate whose base IS the commit but whose content is not its
    # tree, evaluated at that commit: still not covered.
    let baseIsB = certFor(treeOf(repo, commitA), base = commitB)
    check evaluate(baseIsB, commitUnderEvaluation(repo, commitB)).outcome ==
      voNotCovered
    # Without a base at all (a repository's first commit is certified on top
    # of nothing) it matches exactly as well.
    check evaluate(certFor(tested, base = ""),
      commitUnderEvaluation(repo, commitB)).outcome == voCovered

    # --- 2. everything that is not content does not matter ------------------
    discard git(repo, "commit", "-q", "--amend", "-m", "B, reworded")
    let amended = gitLine(repo, "rev-parse", "HEAD")
    check amended != commitB
    check treeOf(repo, amended) == tested
    check evaluate(cert, commitUnderEvaluation(repo, amended)).outcome ==
      voCovered
    writeEntryFile(repo, "src/lib.nim", "proc f*() = echo 2\n")
    commitAll(repo, "C")
    let commitC = gitLine(repo, "rev-parse", "HEAD")
    let atC = evaluate(cert, commitUnderEvaluation(repo, commitC))
    check atC.outcome == voNotCovered
    check atC.rejected.len == 1
    # A covering certificate's ``missing`` is empty; at C the gap is named.
    check atC.missing.len == 1
    check atC.missing[0].targets == @["t-integration", "t-unit"]

    # --- 4. an algorithm the repository cannot compute: UNVERIFIABLE --------
    let sha256Cert = certFor("git-tree-sha256:" & "ab".repeat(32),
      base = amended)
    let sha256Report = evaluate(sha256Cert,
      commitUnderEvaluation(repo, amended), "sha256.toml")
    check sha256Report.outcome == voUnverifiable
    check sha256Report.unevaluated.len == 1
    check sha256Report.rejected.len == 0
    check certificateBindsState(sha256Cert, CoverageRequirement(
      state: commitUnderEvaluation(repo, amended))).binding ==
        sbUnreproducible
    # …and once a certificate this consumer CAN evaluate covers the
    # requirement, covered wins (Verification §7.1), with the unevaluated
    # record still named.
    let both = evaluateCertificates(@[found("sha256.toml", sha256Cert),
        found("sha1.toml", cert)],
      commitUnderEvaluation(repo, amended), requirement(),
      RegisteredKeyStore())
    check both.outcome == voCovered
    check both.unevaluated.len == 1

    # --- 5. a malformed content id is INVALID, never repaired ---------------
    # Built from the REAL id, so any repair (lowercasing, re-adding the
    # algorithm, accepting a prefix) would match.
    for (label, malformed) in [
        ("uppercase", "git-tree-sha1:" & testedTree.toUpperAscii()),
        ("abbreviated", "git-tree-sha1:" & testedTree[0 ..< 12]),
        ("no algorithm", testedTree),
        ("second colon", "git-tree-sha1:sha1:" & testedTree)]:
      checkpoint(label)
      let bad = certFor(malformed, base = commitA)
      let report = evaluate(bad, commitUnderEvaluation(repo, amended),
        label & ".toml")
      check report.outcome == voNotCovered
      check report.rejected.len == 1
      check report.unevaluated.len == 0
      check "malformed" in report.rejected[0].why
      check certificateBindsState(bad, CoverageRequirement(
        state: commitUnderEvaluation(repo, amended))).binding == sbInvalid

    # --- 6. the carriers judge by content, not by the commit -----------------
    # TC-8c: the local certificate store is addressed by CONTENT, so the
    # certificate issued on top of A is found for B — and for B amended —
    # under the content id of their tree, and a record filed under a content
    # directory it does not name is reported and ignored (Transport §2.4).
    let store = scratch / "store"
    let roots = CertificateStoreRoots(user: store)
    check publishCertificateDocument(store,
      serializeCertificateToToml(cert)).error == ""
    let certC = certFor(treeOf(repo, commitC), base = commitC,
      platform = "linux/other")
    check publishCertificateDocument(store,
      serializeCertificateToToml(certC)).error == ""
    let storedForB = findCertificatesInLocalStore(
      commitUnderEvaluation(repo, amended), roots)
    check storedForB.certificates.len == 1
    check storedForB.certificates[0].vcs.content == tested
    check storedForB.certificates[0].vcs.base == commitA
    let storedForC = findCertificatesInLocalStore(
      commitUnderEvaluation(repo, commitC), roots)
    check storedForC.certificates.len == 1
    check storedForC.certificates[0].platform == "linux/other"
    # Misfiled: B's certificate copied into C's content directory.
    let cDir = store / "v1" / "git-tree-sha1" /
      treeOf(repo, commitC)["git-tree-sha1:".len .. ^1]
    copyFile(store / certificateStoreRelativePath(cert), cDir / "misfiled.toml")
    let misfiled = findCertificatesInLocalStore(
      commitUnderEvaluation(repo, commitC), roots)
    check misfiled.certificates.len == 1
    check misfiled.certificates[0].platform == "linux/other"
    check misfiled.problems.len == 1
    check "misfiled.toml" in misfiled.problems.join("\n")
    # Notes are keyed by the TREE the content names (Transport §3): the
    # certificate issued on top of A is noted on the tested tree, and found
    # from the amended commit by its tree. A record attached to that tree but
    # naming other content is ignored and reported as misattached.
    let gitBin = findExe("git")
    check seedCertificateNote(gitBin, repo, cert).ok
    check seedCertificateRecord(gitBin, repo, tested["git-tree-sha1:".len .. ^1],
      certFor(treeOf(repo, commitC), base = amended, platform = "linux/x")).ok
    let attached = readAttachedCertificatesFrom(gitBin, repo, amended,
      certificateNotesRef)
    check attached.certs.len == 1
    check attached.certs[0].vcs.base == commitA
    check attached.certs[0].vcs.content == tested
    check attached.misattached.len == 1

    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)
