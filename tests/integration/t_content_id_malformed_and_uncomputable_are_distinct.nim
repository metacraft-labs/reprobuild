## TC-8a — a malformed content id and one that cannot be computed are
## different answers, and no input is ever repaired into validity.
##
## Content-Id §1 and §5. A malformed id is decidably invalid: a verifier
## rejects it. A well-formed id in an algorithm this implementation does not
## know, or a ``git-tree-sha256`` id in a SHA-1 repository (and the reverse),
## may describe the state perfectly; the verifier cannot tell, and reports it
## as unverifiable. Collapsing the two passes every test that checks only
## "did it match".
##
## The claims are built from REAL ids of a real repository, so a repair would
## not merely be tolerated, it would MATCH: the uppercase spelling of the
## correct digest, its 12-digit abbreviation, the bare digest and the digest
## with a second ``:`` are each one transformation away from ``ceMatches``,
## and each must be ``ceMalformed`` instead.

import std/[os, strutils, unittest]

import repro_cli_support/content_id
import content_id_fixture

suite "malformed and uncomputable content ids are distinct":

  test "t_content_id_malformed_and_uncomputable_are_distinct":
    let scratch = enterHermeticGit()
    let sha1Repo = newRepo(scratch, "sha1-repo", "sha1")
    let sha256Repo = newRepo(scratch, "sha256-repo", "sha256")
    for repo in [sha1Repo, sha256Repo]:
      writeEntryFile(repo, "src/main.c", "int main(void);\n")
      writeEntryFile(repo, "README.md", "# example\n")
      commitAll(repo, "base")

    let real = computeContentId(sha1Repo, workingTreeState(), caGitTreeSha1)
    check real.outcome == cioComputed
    check parseContentId(real.id).form == cifWellFormed
    let digest = real.digest
    check digest.len == 40
    check digest != digest.toUpperAscii()   # it has letters to uppercase

    # The real id matches; that is what every repair below would reach.
    check evaluateClaimedContentId(real.id, sha1Repo,
                                   workingTreeState()).evaluation == ceMatches

    # --- malformed: decidably invalid, and never repaired -------------------
    let malformed = [
      ("uppercase digest", "git-tree-sha1:" & digest.toUpperAscii()),
      ("one uppercase digit", "git-tree-sha1:" &
         digest.replace(digest[digest.find({'a'..'f'})],
                        digest[digest.find({'a'..'f'})].toUpperAscii())),
      ("abbreviated digest", "git-tree-sha1:" & digest[0 ..< 12]),
      ("digest one too long", "git-tree-sha1:" & digest & "0"),
      ("no algorithm", digest),
      ("empty algorithm", ":" & digest),
      ("second colon", "git-tree-sha1:sha1:" & digest),
      ("empty digest", "git-tree-sha1:"),
      ("non-hex digest", "git-tree-sha1:" & digest[0 ..< 39] & "g"),
      ("surrounding whitespace", "git-tree-sha1:" & digest & "\n"),
      ("empty string", ""),
      ("manifest digest of sha1 length", "manifest-v1-sha256:" & digest)]
    for (label, text) in malformed:
      checkpoint(label & ": " & text.escape())
      let parsed = parseContentId(text)
      check parsed.form == cifMalformed
      check parsed.problem.len > 0
      check parsed.text == text
      let claim = evaluateClaimedContentId(text, sha1Repo, workingTreeState())
      check claim.evaluation == ceMalformed
      check claim.evaluation != ceMatches

    # The split is at the FIRST colon: with a second one, the algorithm is
    # still `git-tree-sha1`, and the digest is what fails.
    let second = parseContentId("git-tree-sha1:sha1:" & digest)
    check second.algorithmName == "git-tree-sha1"
    check second.digest == "sha1:" & digest

    # --- cannot compute: well-formed, but not evaluable here ----------------
    let unknown = [
      ("unknown algorithm", "git-tree-sha512:" & digest & digest),
      ("unknown algorithm, short digest", "vcs-snapshot:abc123"),
      ("algorithm in the wrong case", "GIT-TREE-SHA1:" & digest)]
    for (label, text) in unknown:
      checkpoint(label & ": " & text)
      let parsed = parseContentId(text)
      check parsed.form == cifUnknownAlgorithm
      let claim = evaluateClaimedContentId(text, sha1Repo, workingTreeState())
      check claim.evaluation == ceCannotCompute
      check claim.computed.outcome == cioCannotCompute
      check claim.computed.reason.len > 0
      check computeContentId(sha1Repo, workingTreeState(),
        parsed.algorithmName).outcome == cioCannotCompute

    # git-tree-sha256 in a SHA-1 repository, and the reverse, for every state.
    let real256 = computeContentId(sha256Repo, workingTreeState(),
                                   caGitTreeSha256)
    check real256.outcome == cioComputed
    check real256.digest.len == 64
    for state in [workingTreeState(), indexState(), commitState("HEAD")]:
      let across = computeContentId(sha1Repo, state, caGitTreeSha256)
      checkpoint(across.reason)
      check across.outcome == cioCannotCompute
      check across.id == ""
      let back = computeContentId(sha256Repo, state, caGitTreeSha1)
      check back.outcome == cioCannotCompute
      check back.id == ""
      check evaluateClaimedContentId(real256.id, sha1Repo,
                                     state).evaluation == ceCannotCompute
      check evaluateClaimedContentId(real.id, sha256Repo,
                                     state).evaluation == ceCannotCompute
      check evaluateClaimedContentId(real256.id, sha256Repo,
                                     state).evaluation == ceMatches

    # A well-formed id of the right algorithm that names other content is an
    # ordinary mismatch, neither malformed nor uncomputable.
    let other = "git-tree-sha1:" & repeat('0', 40)
    check parseContentId(other).form == cifWellFormed
    check evaluateClaimedContentId(other, sha1Repo,
                                   workingTreeState()).evaluation == ceDiffers

    # manifest-v1-sha256 is computable in either object format, and agrees.
    let m1 = computeContentId(sha1Repo, workingTreeState(), caManifestV1Sha256)
    let m256 = computeContentId(sha256Repo, workingTreeState(),
                                caManifestV1Sha256)
    check m1.outcome == cioComputed
    check m1.id == m256.id
    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)
