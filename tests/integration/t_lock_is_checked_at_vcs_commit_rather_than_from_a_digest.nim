## TC-7 — the lock is checked AT ``vcs.commit``, not read from a digest.
##
## Before this milestone a certificate carried ``lock = "blake3:…"`` and the
## verifier compared that string. That digest was information the commit
## already implied, at the cost of making the format ecosystem-specific: a
## consumer had to know what reprobuild hashes, and in what order, to say
## anything at all.
##
## reprobuild's lock RECORD is committed and keyed by the trigger commit
## (``<manifest-layer>/locks/<project>/<repo>/<sha>.toml``), so ``vcs.commit``
## already binds it. The verifier therefore RESOLVES the lock at that commit
## itself — the standard's framework-specific validity step, which the
## standard deliberately defines none of and leaves to the framework.
##
## The load-bearing distinction: a digest in the record is a CLAIM BY THE
## ISSUER; the record on disk at the named commit is a FACT THE VERIFIER
## ESTABLISHED. So the decisive assertion below is that the SAME certificate
## bytes reach opposite verdicts depending only on what is in the repository
## at ``vcs.commit`` — which is impossible for an implementation that reads a
## digest out of the record.
##
## Sub-cases:
##   1. the record carries NO lock field at all, and a stray one is not a
##      binding;
##   2. ``resolveLockAtCommit`` finds the record for the commit that has one;
##   3. …and reports ABSENT for a commit that has none, and CANNOT-TELL for a
##      lock subtree it cannot resolve — three states, not two;
##   4. the same certificate is COVERED at a commit whose lock resolves and
##      REJECTED at one whose lock does not;
##   5. an unresolvable lock subtree makes the outcome UNVERIFIABLE rather
##      than not-covered: "fix the configuration", not "run the tests".

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support
import repro_workspace_manifests

const
  lockedCommit = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"
  unlockedCommit = "b0000000000000000000000000000000000000b0"

  lockRecordBody = """schema = "reprobuild.workspace.lock.v1"

[lock]
project = "lib-a"
trigger_repo = "lib-a"
trigger_revision = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"

[[repo]]
name = "lib-a"
path = "lib-a"
revision = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"
"""

proc certAt(commit: string): TestCertificate =
  TestCertificate(
    schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId,
    project: "lib-a",
    platform: "linux/amd64",
    targets: @["t-integration", "t-unit"],
    result: tcrPassed,
    issuedAt: "2026-06-23T10:14:33Z",
    issuer: "repro-test@build-host-7",
    vcs: TestCertificateVcs(repo: "lib-a", commit: commit,
      clean: true, untracked: false),
    commands: @[TestCertificateCommand(argv: @["repro", "test"])])

proc found(name: string; c: TestCertificate): FoundCertificate =
  FoundCertificate(name: name,
    read: CertificateReadResult(status: crsOk, cert: c, schemaSeen: c.schema))

proc requirement(): VerificationRequirement =
  VerificationRequirement(
    frameworksImplemented: @[reprobuildFrameworkId],
    framework: reprobuildFrameworkId,
    targets: @["t-integration", "t-unit"],
    platforms: @["linux/amd64"],
    requireSignature: false)

suite "TC-7 — framework-specific validity: the lock at vcs.commit":

  test "t_lock_is_checked_at_vcs_commit_rather_than_from_a_digest":
    let scratch = createTempDir("repro-tc7-lock-", "")
    defer: removeDir(scratch)
    # A real per-repo lock subtree, in the RA-1 layout, holding a record for
    # exactly one commit.
    let manifestLayer = scratch / "manifests"
    let lockRecordsDir = lockRecordsDirFor(manifestLayer, "lib-a", "lib-a")
    createDir(lockRecordsDir)
    writeFile(lockRecordsDir / lockFileName(lockedCommit), lockRecordBody)

    # --- 1. the record carries no lock digest -----------------------------
    let cert = certAt(lockedCommit)
    let payload = canonicalCertificatePayload(cert)
    check "lock = " notin payload
    check "blake3:" notin payload
    # A stray ``lock`` key in a received record is an unknown key: ignored,
    # and emphatically not a binding the verifier would honour.
    let strayLock = readCertificateRecord(
      serializeCertificateToToml(cert).replace("[certificate.vcs]\n",
        "[certificate.vcs]\nlock = \"blake3:deadbeef\"\n"))
    check strayLock.status == crsOk
    check canonicalCertificatePayload(strayLock.cert) == payload

    # --- 2/3. three states, not two ---------------------------------------
    let present = resolveLockAtCommit(lockRecordsDir, lockedCommit)
    check present.status == lacPresent
    check present.path == lockRecordsDir / lockFileName(lockedCommit)

    let absent = resolveLockAtCommit(lockRecordsDir, unlockedCommit)
    check absent.status == lacAbsent
    check unlockedCommit in absent.detail

    let unknown = resolveLockAtCommit("", lockedCommit)
    check unknown.status == lacUnknown

    # A record that is present but says nothing is decidably invalid, not
    # "could not tell".
    let emptyDir = scratch / "empty-records"
    createDir(emptyDir)
    writeFile(emptyDir / lockFileName(lockedCommit), "\n")
    check resolveLockAtCommit(emptyDir, lockedCommit).status == lacAbsent

    # --- 4. the SAME certificate, opposite verdicts -----------------------
    # Nothing about the two records below differs except the commit they name,
    # and the verdict is decided by what the repository holds at that commit.
    let check1 = reprobuildLockValidity(lockRecordsDir)
    let atLocked = evaluateCertificates(@[found("locked.toml", cert)],
      VerificationState(repo: "lib-a", commit: lockedCommit),
      requirement(), RegisteredKeyStore(), ksaReadable, check1)
    check atLocked.outcome == voCovered

    let atUnlocked = evaluateCertificates(
      @[found("unlocked.toml", certAt(unlockedCommit))],
      VerificationState(repo: "lib-a", commit: unlockedCommit),
      requirement(), RegisteredKeyStore(), ksaReadable, check1)
    check atUnlocked.outcome == voNotCovered
    check atUnlocked.rejected.len == 1
    check "lock" in atUnlocked.rejected[0].why

    # Without the framework-specific step the second certificate would pass
    # the generic check — which is exactly why the step exists, and why no
    # consumer may invent a generic substitute for it.
    let withoutStep = evaluateCertificates(
      @[found("unlocked.toml", certAt(unlockedCommit))],
      VerificationState(repo: "lib-a", commit: unlockedCommit),
      requirement(), RegisteredKeyStore())
    check withoutStep.outcome == voCovered

    # --- 5. cannot-tell is unverifiable, not not-covered ------------------
    let blind = reprobuildLockValidity("")
    let cannotTell = evaluateCertificates(@[found("locked.toml", cert)],
      VerificationState(repo: "lib-a", commit: lockedCommit),
      requirement(), RegisteredKeyStore(), ksaReadable, blind)
    check cannotTell.outcome == voUnverifiable
    check cannotTell.unevaluated.len == 1
    check cannotTell.rejected.len == 0
