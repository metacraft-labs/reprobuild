## Workspace-Manifest-Optional MO-5 — an EVIDENCE-ONLY private repo
## participates in the build by publishing ONLY its source-free
## ``WorkspaceVcsEvidence`` (head-sha / is-clean / is-published) through its
## MO-4-assigned locking backend, NEVER its source.
##
## The owner of the private repo (the one that HAS the source) observes the
## three-scalar evidence triple from its local checkout
## (``gatherRepoEvidence``) and publishes it through the store
## (``putEvidence`` — MO-3). We then assert:
##
##   * the published record CARRIES the evidence — head-sha, is-clean,
##     is-published — and round-trips back losslessly via ``getEvidence``;
##   * the persisted on-disk blob exposes NO source: no working-tree file
##     content, no file blobs, none of the repo's secret contents appear in
##     the published evidence bytes (the security property at the heart of
##     evidence-only participation);
##   * ``gatherRepoEvidence`` produces exactly the three observation ops and
##     nothing source-bearing.
##
## Falsifiable: if the evidence record were to carry source (or if the codec
## leaked working-tree bytes), the "NO source content" assertion trips. If the
## published record did not round-trip, the read-back equality fails.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_lock_store
import repro_cli_support
import git_tool
import evidence as wvev

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

# A string the private repo's WORKING TREE contains but that must NEVER leak
# into the published source-free evidence record.
const secretContent = "TOP-SECRET-PROPRIETARY-ALGORITHM-d3adb33f"

proc seedPrivateRepoWithOrigin(gitBin, originPath, workPath: string): string =
  ## A clean, PUBLISHED private repo whose working tree holds ``secretContent``.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"MO-5 Tester\"")
  writeFile(workPath / "secret_source.txt", secretContent & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add secret_source.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m secret")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

suite "MO-5 — evidence-only private participation without source exposure":

  test "t_private_repo_participates_via_evidence_without_source_exposure":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = createTempDir("repro-mo5-evidence-", "")
      defer: removeDir(ws)

      # The owner's private checkout + its origin (a clean, published repo
      # carrying secret source in its working tree).
      let origin = ws / "origin-secret.git"
      let secretWork = ws / "secret"
      let headSha = seedPrivateRepoWithOrigin(gitBin, origin, secretWork)

      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # The evidence-only repo routes to a committed-file backend (records in a
      # repo-local dir). NO source is ever written into this store.
      let storeDir = ws / "evidence-store"
      let store: LockStore = newCommittedFileLockStore(storeDir)

      # ---- 1. OWNER gathers the source-free triple from the local checkout --
      let triple = gatherRepoEvidence(
        identity, secretWork, "secret", "deadbeef", 1234'i64)
      check triple.len == 3
      # Exactly the three observation ops, head-sha resolved + matching HEAD.
      var sawHead, sawClean, sawPub = false
      for rec in triple:
        case rec.op
        of wvqHeadSha:
          sawHead = true
          check rec.status == wvesResolved
          check rec.headSha == headSha
        of wvqIsClean:
          sawClean = true
          check rec.status == wvesResolved
          check rec.isClean            # the checkout is clean
        of wvqIsPublished:
          sawPub = true
          check rec.status == wvesResolved
          check rec.isPublished        # HEAD is on origin/main
      check sawHead and sawClean and sawPub

      # ---- 2. publish the evidence through the backend (MO-3 putEvidence) ---
      let put = store.putEvidence("demo", "secret", triple)
      check put.outcome == spoOk

      # ---- 3. NO source is exposed in the persisted store ------------------
      # The committed-file backend persists evidence under evidence/<proj>/.
      let evFile = storeDir / "evidence" / "demo" / "secret.ev"
      check fileExists(evFile)
      # The persisted evidence is a base64 SSZ envelope, so a plaintext scan is
      # NOT sufficient (a leaked secret would be base64-obscured). DECODE the
      # stored blob back to its records and assert NO record FIELD carries the
      # secret working-tree content, the secret filename, or any working-tree
      # body — only the three observation scalars (head-sha / clean / published)
      # and their non-source metadata may be present.
      let decoded = decodeEvidenceBlob(readFile(evFile))
      check decoded.len == 3
      for rec in decoded:
        for field in [rec.path, rec.headSha, rec.diagnostic,
                      rec.vcsToolDigestHex]:
          check secretContent notin field
          check "secret_source.txt" notin field
        # The record path is the workspace-relative repo path, never source.
        check rec.path == "secret"
      # Also a raw scan of every store file for the plaintext secret (belt and
      # braces — catches any unencoded leak path).
      for path in walkDirRec(storeDir):
        check secretContent notin readFile(path)

      # ---- 4. round-trip back via getEvidence (MO-3) -----------------------
      let readBack = store.getEvidence("demo", "secret")
      check readBack.len == 3
      # The read-back evidence is byte-identical to what we published (SSZ
      # envelope round-trip), proving the record carries the evidence losslessly
      # while still exposing no source.
      check wvev.toSsz(readBack) == wvev.toSsz(triple)
      var rbHead = ""
      var rbClean, rbPub = false
      for rec in readBack:
        case rec.op
        of wvqHeadSha: rbHead = rec.headSha
        of wvqIsClean: rbClean = rec.isClean
        of wvqIsPublished: rbPub = rec.isPublished
      check rbHead == headSha
      check rbClean
      check rbPub
