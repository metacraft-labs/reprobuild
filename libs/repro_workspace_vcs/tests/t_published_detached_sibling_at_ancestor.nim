## t_published_detached_sibling_at_ancestor -- the publication probe answers
## "is HEAD published?" for a detached sibling whose HEAD is an ancestor of a
## remote branch tip, not the tip itself.
##
## A pinned dependency is checked out detached at the commit its lock names.
## The remote branch has usually moved past that commit, so HEAD is the tip of
## no branch. Asking only "is HEAD a branch tip?" reported such a commit as
## unpublished, although the remote holds it. The gate then told the operator
## to push a commit the remote already has.
##
## Three cases, each on real git repositories (no mocks):
##   1. HEAD is an ancestor of the remote's main tip (a detached sibling at the
##      pinned commit), with no remote-tracking refs locally: published.
##   2. HEAD is a local commit never pushed: unpublished.
##   3. The remote cannot be reached: a probe error (not "unpublished"), so the
##      operator is told the remote could not be asked.
##
## Falsifiable: restore the tip-only check and case 1 reports unpublished.

import std/[os, osproc, strutils, tempfiles, unittest]

import git_actions
import git_tool

proc gitIn(dir: string; args: openArray[string]): string =
  let cmd = "git -C " & quoteShell(dir) & " -c user.email=t@t -c user.name=t " &
    args.join(" ")
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "git failed: " & cmd & "\n" & output
  result = output.strip()

proc identityForGit(): GitToolIdentity =
  GitToolIdentity(binaryPath: "git", version: "", platformOs: hostOS,
    platformCpu: hostCPU, installMethod: "path")

suite "a detached sibling at an ancestor of a remote branch is published":

  test "t_published_detached_sibling_at_ancestor":
    let scratch = createTempDir("published-ancestor-", "")
    defer: removeDir(scratch)
    let remote = scratch / "remote.git"
    let work = scratch / "work"
    let sib = scratch / "sib"

    # The remote, with two commits on main: A (the pinned one) then B.
    discard gitIn(scratch, ["init", "--bare", "-q", quoteShell(remote)])
    discard gitIn(scratch, ["init", "-q", quoteShell(work)])
    writeFile(work / "f.txt", "a\n")
    discard gitIn(work, ["add", "f.txt"])
    discard gitIn(work, ["commit", "-q", "-m", "A"])
    let shaA = gitIn(work, ["rev-parse", "HEAD"])
    writeFile(work / "f.txt", "b\n")
    discard gitIn(work, ["commit", "-q", "-am", "B"])
    discard gitIn(work, ["push", "-q", quoteShell(remote), "HEAD:refs/heads/main"])

    # The sibling: fetched at A by SHA, detached, with origin set to the remote
    # and no remote-tracking refs for it. This is the CI-cloned shape.
    discard gitIn(scratch, ["init", "-q", quoteShell(sib)])
    discard gitIn(sib, ["remote", "add", "origin", quoteShell(remote)])
    discard gitIn(sib, ["fetch", "-q", "--no-tags", "origin", shaA])
    discard gitIn(sib, ["checkout", "-q", "--detach", "FETCH_HEAD"])
    check gitIn(sib, ["rev-parse", "HEAD"]) == shaA

    # Case 1: HEAD (A) is an ancestor of main's tip (B): published.
    let published = queryGitState(isPublishedQuery(sib, "origin"),
      identityForGit())
    check published.status == gqsOk
    check published.isPublished

    # Case 2: a local commit that was never pushed: unpublished.
    writeFile(sib / "g.txt", "local\n")
    discard gitIn(sib, ["add", "g.txt"])
    discard gitIn(sib, ["commit", "-q", "-m", "local-only"])
    let unpublished = queryGitState(isPublishedQuery(sib, "origin"),
      identityForGit())
    check unpublished.status == gqsOk
    check not unpublished.isPublished

    # Case 3: the remote cannot be reached: a probe error, not "unpublished".
    discard gitIn(sib, ["remote", "set-url", "origin",
      quoteShell(scratch / "no-such-remote.git")])
    let unreachable = queryGitState(isPublishedQuery(sib, "origin"),
      identityForGit())
    check unreachable.status == gqsFailed
    check "cannot reach remote" in unreachable.diagnostic
