## TC-8b — reprobuild's lock is read FROM THE CONTENT under evaluation.
##
## A certificate carries no lock digest (TC-7). By default a repository's
## ``repro.lock`` is committed (Unified-Locking-And-Hooks §14), so it is one
## of the tracked files ``vcs.content`` binds, and reprobuild's
## framework-specific validity step (Verification §4.2) reads it out of the
## state being evaluated — a commit's tree, the index, a working tree — and
## parses it. A digest in the record would be the ISSUER's claim; the lock in
## the evaluated content is a fact the verifier establishes.
##
## The decisive assertion: the SAME certificate bytes reach opposite verdicts
## depending only on the ``repro.lock`` in the state. The certificate is
## SCOPED to ``src`` so that its content id is identical in every state below
## — the states differ only in their lock, outside the scope — and the
## requirement asks for ``src``. (reprobuild does not ISSUE scoped
## certificates; a verifier must evaluate any conforming producer's.)
##
## Sub-cases, committed-lock project (no lock record store anywhere in this
## fixture):
##   1. covered at a commit whose ``repro.lock`` parses;
##   2. REJECTED (not covered, not unverifiable) at a commit with no
##      ``repro.lock``, and at one whose ``repro.lock`` does not parse —
##      while the generic check alone would cover both, which is why the step
##      exists;
##   3. the lock is the EVALUATED state's: a working tree whose tracked
##      ``repro.lock`` was broken after the commit is rejected while the
##      commit is covered; an UNTRACKED ``repro.lock`` is not part of the
##      content and counts as absent; the index being committed is read as
##      staged;
##   4. a state whose content cannot be read is UNVERIFIABLE — "I could not
##      look" is not "there is no lock".
## Record-store project (the opt-in; the half kept from the retired
## ``t_lock_is_checked_at_vcs_commit_rather_than_from_a_digest``):
##   5. ``resolveLockAtCommit`` answers present / absent / could-not-ask, and
##      a record that pins nothing is absent;
##   6. evaluated at a COMMIT, the lock still resolves through the record
##      store, keyed by that commit (never by ``base``): covered where a
##      record exists, rejected where none does, unverifiable when the store
##      cannot be resolved;
##   7. the same project evaluated at the INDEX is covered by the certificate
##      alone: the record-store lock is not part of that content, so there is
##      no lock lookup — even an unresolvable store does not make it
##      unverifiable (operator decision D8).

import std/[os, strutils, unittest]

import repro_cli_support
import repro_cli_support/content_id
import repro_lock
import repro_workspace_manifests
import content_id_fixture

const
  lockRecordBody = """schema = "reprobuild.workspace.lock.v1"

[lock]
project = "lib-a"
trigger_repo = "lib-a"
trigger_revision = "$1"

[[repo]]
name = "lib-a"
path = "lib-a"
revision = "$1"
"""

proc committedLock(revision: string): string =
  ## A real committed lock, written by the real serializer.
  serializeLockedDependencies(LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    deps: @[LockedDep(
      name: "lib-a", path: ".",
      coordinates: Coordinates(kind: ckVcs, gitRef: "main",
        revision: revision),
      integrity: "git-sha1:" & revision,
      visibility: "public")]))

proc scopedCert(content, base: string): TestCertificate =
  TestCertificate(
    schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId,
    project: "lib-a",
    platform: "linux/amd64",
    targets: @["t-integration", "t-unit"],
    result: tcrPassed,
    issuedAt: "2026-10-11T10:00:00Z",
    issuer: "repro-test@tc8b",
    vcs: TestCertificateVcs(repo: "lib-a", paths: @["src"], content: content,
      untracked: false, base: base),
    commands: @[TestCertificateCommand(argv: @["repro", "test"])])

proc requirement(): VerificationRequirement =
  VerificationRequirement(
    frameworksImplemented: @[reprobuildFrameworkId],
    framework: reprobuildFrameworkId,
    targets: @["t-integration", "t-unit"],
    platforms: @["linux/amd64"],
    requireSignature: false,
    paths: @["src"])

proc evaluate(c: TestCertificate; state: CertificateState;
              check: FrameworkValidityCheck): VerificationReport =
  evaluateCertificates(@[FoundCertificate(name: "cert.toml",
      read: readCertificateRecord(serializeCertificateToToml(c)))],
    state, requirement(), RegisteredKeyStore(), ksaReadable, check)

proc scopedTreeId(repo, revision: string): string =
  ## The ``src``-scoped content id, by git alone (the Content-Id §4.1 recipe
  ## in a scratch index), so the certificate does not come from the library
  ## under test.
  let index = repo / ".git" / "tc8b-scoped-index"
  let listed = runGitIn(repo, ["--literal-pathspecs", "ls-tree", "-r", "-z",
    "--full-tree", revision, "--", "src"]).stdout
  discard runGitIn(repo, ["read-tree", "--empty"],
    env = [("GIT_INDEX_FILE", index)])
  discard runGitIn(repo, ["update-index", "-z", "--index-info"],
    input = listed, env = [("GIT_INDEX_FILE", index)])
  result = "git-tree-sha1:" & runGitIn(repo, ["write-tree"],
    env = [("GIT_INDEX_FILE", index)]).stdout.strip()
  removeFile(index)

suite "TC-8b — the lock comes from the content":

  test "t_lock_is_read_from_the_content_under_evaluation":
    let scratch = enterHermeticGit()
    let repo = newRepo(scratch, "lib-a")
    writeEntryFile(repo, "src/lib.nim", "proc f*() = discard\n")
    writeEntryFile(repo, "repro.lock", committedLock("1".repeat(40)))
    commitAll(repo, "locked")
    let locked = gitLine(repo, "rev-parse", "HEAD")
    discard git(repo, "rm", "-q", "repro.lock")
    commitAll(repo, "no lock")
    let unlocked = gitLine(repo, "rev-parse", "HEAD")
    writeEntryFile(repo, "repro.lock", "this is not a lock\n")
    commitAll(repo, "broken lock")
    let broken = gitLine(repo, "rev-parse", "HEAD")
    writeEntryFile(repo, "repro.lock", committedLock("2".repeat(40)))
    commitAll(repo, "locked again")
    let relocked = gitLine(repo, "rev-parse", "HEAD")

    # ONE certificate. Its scoped content is the same in all four commits.
    let content = scopedTreeId(repo, locked)
    for commit in [unlocked, broken, relocked]:
      check scopedTreeId(repo, commit) == content
    let cert = scopedCert(content, base = locked)
    let fromContent = reprobuildLockValidity(committedLockSource())

    # --- 1. covered where the content's repro.lock parses -------------------
    let atLocked = evaluate(cert, commitUnderEvaluation(repo, locked),
      fromContent)
    check atLocked.outcome == voCovered
    check evaluate(cert, commitUnderEvaluation(repo, relocked),
      fromContent).outcome == voCovered

    # --- 2. rejected where it is absent or does not parse -------------------
    let atUnlocked = evaluate(cert, commitUnderEvaluation(repo, unlocked),
      fromContent)
    check atUnlocked.outcome == voNotCovered
    check atUnlocked.rejected.len == 1
    check atUnlocked.unevaluated.len == 0
    check "repro.lock" in atUnlocked.rejected[0].why
    let atBroken = evaluate(cert, commitUnderEvaluation(repo, broken),
      fromContent)
    check atBroken.outcome == voNotCovered
    check atBroken.rejected.len == 1
    check "repro.lock" in atBroken.rejected[0].why
    # The generic check alone covers both: the step is what decides.
    for commit in [unlocked, broken]:
      check evaluate(cert, commitUnderEvaluation(repo, commit),
        nil).outcome == voCovered
    # The same verdicts from the lock read itself.
    check readLockFromContent(commitUnderEvaluation(repo, locked)).status ==
      licPresent
    check readLockFromContent(commitUnderEvaluation(repo, unlocked)).status ==
      licAbsent
    check readLockFromContent(commitUnderEvaluation(repo, broken)).status ==
      licUnparseable

    # --- 3. it is the EVALUATED state's lock, not HEAD's --------------------
    # HEAD (relocked) is covered; break the TRACKED lock in the working tree
    # and the working tree is rejected while the commit is still covered.
    writeEntryFile(repo, "repro.lock", "broken after the commit\n")
    check evaluate(cert, workingTreeUnderEvaluation(repo),
      fromContent).outcome == voNotCovered
    check evaluate(cert, commitUnderEvaluation(repo, relocked),
      fromContent).outcome == voCovered
    # The index still holds the committed lock until it is staged…
    check evaluate(cert, indexUnderEvaluation(repo),
      fromContent).outcome == voCovered
    discard git(repo, "add", "repro.lock")
    # …and is read as staged once it is.
    check evaluate(cert, indexUnderEvaluation(repo),
      fromContent).outcome == voNotCovered
    discard git(repo, "reset", "-q", "--hard", unlocked)
    # An UNTRACKED repro.lock is not part of the content: absent.
    writeEntryFile(repo, "repro.lock", committedLock("3".repeat(40)))
    check readLockFromContent(workingTreeUnderEvaluation(repo)).status ==
      licAbsent
    check evaluate(cert, workingTreeUnderEvaluation(repo),
      fromContent).outcome == voNotCovered
    removeFile(repo / "repro.lock")

    # --- 4. could not look: UNVERIFIABLE, not "no lock" ---------------------
    # A consumer handed only content ids has no content to read a lock from.
    let blind = stateWithKnownContent([KnownContentId(
      algorithm: "git-tree-sha1", paths: @["src"], id: content)])
    let atBlind = evaluate(cert, blind, fromContent)
    check atBlind.outcome == voUnverifiable
    check atBlind.unevaluated.len == 1
    check atBlind.rejected.len == 0

    # --- 5. record-store project: three states, not two ---------------------
    let manifestLayer = scratch / "manifests"
    let lockRecordsDir = lockRecordsDirFor(manifestLayer, "lib-a", "lib-a")
    createDir(lockRecordsDir)
    writeFile(lockRecordsDir / lockFileName(unlocked),
      lockRecordBody % [unlocked])
    let present = resolveLockAtCommit(lockRecordsDir, unlocked)
    check present.status == lacPresent
    check present.path == lockRecordsDir / lockFileName(unlocked)
    let absent = resolveLockAtCommit(lockRecordsDir, broken)
    check absent.status == lacAbsent
    check broken in absent.detail
    check resolveLockAtCommit("", unlocked).status == lacUnknown
    check resolveLockAtCommit(scratch / "nowhere", unlocked).status ==
      lacUnknown
    let emptyDir = scratch / "empty-records"
    createDir(emptyDir)
    writeFile(emptyDir / lockFileName(unlocked), "\n")
    check resolveLockAtCommit(emptyDir, unlocked).status == lacAbsent

    # --- 6. …evaluated at a commit, through the record store ----------------
    # ``unlocked`` has no repro.lock in its tree, and is covered all the same:
    # this project's lock is the record, found by the commit under evaluation.
    let fromStore = reprobuildLockValidity(recordStoreLockSource(lockRecordsDir))
    check evaluate(cert, commitUnderEvaluation(repo, unlocked),
      fromStore).outcome == voCovered
    # ``locked`` has a perfectly good committed repro.lock and NO record: the
    # opted-in project is judged by its record store, so it is rejected — and
    # the certificate's ``base`` (= locked) is not what was looked up.
    let noRecord = evaluate(cert, commitUnderEvaluation(repo, locked),
      fromStore)
    check noRecord.outcome == voNotCovered
    check noRecord.rejected.len == 1
    check locked in noRecord.rejected[0].why
    # An unresolvable store at a commit: could not ask.
    let unresolvable = reprobuildLockValidity(
      recordStoreLockSource(scratch / "nowhere"))
    let cannotTell = evaluate(cert, commitUnderEvaluation(repo, unlocked),
      unresolvable)
    check cannotTell.outcome == voUnverifiable
    check cannotTell.unevaluated.len == 1
    check cannotTell.rejected.len == 0

    # --- 7. …evaluated at the INDEX: the certificate alone decides (D8) -----
    discard git(repo, "reset", "-q", "--hard", locked)
    for source in [recordStoreLockSource(lockRecordsDir),
                   recordStoreLockSource(scratch / "nowhere")]:
      let atIndex = evaluate(cert, indexUnderEvaluation(repo),
        reprobuildLockValidity(source))
      check atIndex.outcome == voCovered
      check atIndex.unevaluated.len == 0
      check atIndex.rejected.len == 0
      check reprobuildLockVerdict(source, indexUnderEvaluation(repo)).verdict ==
        fvValid

    # The record carries no lock digest, and a stray one is no binding.
    let payload = canonicalCertificatePayload(cert)
    check "lock = " notin payload
    check "blake3:" notin payload
    let stray = readCertificateRecord(serializeCertificateToToml(cert).replace(
      "[certificate.vcs]\n", "[certificate.vcs]\nlock = \"blake3:deadbeef\"\n"))
    check stray.status == crsOk
    check canonicalCertificatePayload(stray.cert) == payload

    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)
