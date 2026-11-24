## t_later_added_file_breaks_an_old_certificate -- a certificate's content id
## stops matching once a later commit adds a file the earlier tree did not have.
##
## Test-Certificates.md "Absence observations" rests on this: a path absent
## from the certified tree is pinned by the content id, not by a record field.
## So a file that is absent when a certificate is issued and later committed
## changes the id, and the old claim must be refused. Content-Id §4 and §5 say
## a verifier compares the claimed id with the id it computes for the state
## under verification; this test drives that comparison on a real repository.
##
## The claim is computed from the real tree after the base commit. Nothing is
## mocked: the repository, the commits and the id computation are real git.

import std/unittest

import repro_cli_support/content_id
import content_id_fixture

suite "a later-added file breaks an old certificate":

  test "t_later_added_file_breaks_an_old_certificate":
    let scratch = enterHermeticGit()
    defer: leaveHermeticGit(scratch)
    let repo = newRepo(scratch, "later-added-repo", "sha1")
    writeEntryFile(repo, "src/main.c", "int main(void);\n")
    commitAll(repo, "base")

    # The certificate's claim: the id of the tree as it was at the base commit.
    let issued = computeContentId(repo, commitState("HEAD"), caGitTreeSha1)
    check issued.outcome == cioComputed
    let claim = issued.id
    check evaluateClaimedContentId(claim, repo,
                                   commitState("HEAD")).evaluation == ceMatches

    # A later commit adds the file the earlier tree did not have.
    writeEntryFile(repo, "tests/nim.cfg", "--path:src\n")
    commitAll(repo, "add the test configuration")

    # The old claim is refused against the new tree, in both the committed
    # and the working-tree state, and the new tree has its own id.
    check evaluateClaimedContentId(claim, repo,
                                   commitState("HEAD")).evaluation == ceDiffers
    check evaluateClaimedContentId(claim, repo,
                                   workingTreeState()).evaluation == ceDiffers
    let current = computeContentId(repo, commitState("HEAD"), caGitTreeSha1)
    check current.outcome == cioComputed
    check current.id != claim
