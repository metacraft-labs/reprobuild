## The publication predicate — "is HEAD on a remote-tracking branch" — is ONE
## history walk, whatever the number of remote-tracking refs.
##
## ``isPublishedQuery`` (``git_actions.remoteBranchContainsHead``) is the
## predicate behind the pre-push gate's ``unpublished`` stage, `repro health`'s
## ``unpublished-heads`` row and `repro branch`'s pre-flight. It used to ask
## ``git branch -r --contains HEAD``, which decides containment one ref at a
## time: its cost is the number of remote-tracking refs times the depth of
## history between them and HEAD. In a workspace holding the llvm-project
## reference tree (≈1,400 remote-tracking refs, a pool without a
## commit-graph) `repro health` sat in that one call for seven minutes and
## printed nothing (observed 2026-11-22 on a 154-repository workspace).
##
## Two halves, both against real git repositories and the real git binary:
##
##   1. **The predicate is unchanged.** Published, unpublished, no remotes at
##      all, detached HEAD on either side, branch names with ``/`` in them,
##      scoping to a configured remote, the any-remote fallback for a remote
##      the checkout does not have, a bare ``refs/remotes/<name>`` (not a
##      ``<remote>/<branch>`` ref, so never evidence), a dangling
##      ``<remote>/HEAD`` symref, a remote-tracking ref naming a missing
##      object (skipped, not fatal), and an unborn HEAD or a missing
##      revision — which must FAIL the
##      probe, never read as published. A false "published" lets an
##      unpublished HEAD through the reproducibility boundary, so every
##      ``true`` here is paired with a ``false`` that differs in one thing.
##   2. **The cost does not scale with the number of refs.** A synthetic
##      reference tree — 100,000 linear commits, commit-graph disabled, a HEAD
##      on no remote branch near the root — is probed with 20 and with 4,000
##      remote-tracking refs. The per-ref form took 0.5 s and 19.8 s there
##      (git 2.54, this host); one walk took 0.33 s and 0.5 s. The assertion
##      compares the two runs of the SAME build, so a slow or contended host
##      slows both sides and does not decide the outcome.
##
## No mocks: every answer comes from git over repositories on disk. Skips only
## when git is absent.

import std/[monotimes, os, osproc, strutils, tempfiles, times, unittest]

import git_actions
import git_tool
import repro_test_support/large_reference_tree
import repro_test_support/reasoned_skip

proc run(command: string; cwd = ""; input = ""):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd, input = input)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = ""; input = ""): string =
  let res = run(command, cwd, input)
  if res.code != 0:
    raise newException(OSError,
      "command failed: " & command & "\nexit=" & $res.code & "\n" & res.output)
  res.output

proc fileUrl(path: string): string =
  var normalized = absolutePath(path).replace('\\', '/')
  if not normalized.startsWith("/"):
    normalized = "/" & normalized
  "file://" & normalized

proc commitIn(repo, message: string): string =
  writeFile(repo / (message & ".txt"), message & "\n")
  discard requireSuccess("git add " & quoteShell(message & ".txt"), repo)
  discard requireSuccess("git commit -q -m " & quoteShell(message), repo)
  requireSuccess("git rev-parse HEAD", repo).strip()

proc identityOrSkip(): tuple[ok: bool; identity: GitToolIdentity] =
  let git = findExe("git")
  if git.len == 0:
    return (ok: false, identity: GitToolIdentity())
  (ok: true, identity: ensureGitToolResolvable(tpmPathOnly, git.parentDir))

proc published(identity: GitToolIdentity; repo, remote: string;
               localOnly = true): GitQueryResult =
  queryGitState(isPublishedQuery(repo, remote, localOnly), identity)

suite "the publication predicate is unchanged":

  test "published, unpublished, detached, scoped and malformed refs":
    let (haveGit, identity) = identityOrSkip()
    if not haveGit:
      skip("git is not on PATH; the predicate is a question asked of git")
    else:
      let scratch = createTempDir("repro-pubwalk-", "")
      defer: removeDir(scratch)
      let seed = scratch / "seed"
      createDir(seed)
      discard requireSuccess("git init -q -b main " & quoteShell(seed))
      discard requireSuccess("git config user.email t@example.invalid", seed)
      discard requireSuccess("git config user.name Test", seed)
      let base = commitIn(seed, "base")
      let onNested = commitIn(seed, "nested")
      discard requireSuccess("git branch users/a/b " & onNested, seed)
      discard requireSuccess("git reset -q --hard " & base, seed)
      let upstream = scratch / "upstream.git"
      discard requireSuccess("git clone -q --bare " & quoteShell(seed) & " " &
        quoteShell(upstream))
      let co = scratch / "checkout"
      discard requireSuccess("git clone -q " & quoteShell(fileUrl(upstream)) &
        " " & quoteShell(co))
      discard requireSuccess("git config user.email t@example.invalid", co)
      discard requireSuccess("git config user.name Test", co)

      # HEAD on origin/main.
      var r = published(identity, co, "origin")
      check r.status == gqsOk
      check r.isPublished
      check r.publishedScope == "origin"
      r = published(identity, co, "")
      check r.status == gqsOk and r.isPublished and r.publishedScope == ""

      # A commit on top of it, pushed nowhere: unpublished under every scope.
      let local = commitIn(co, "local")
      for scope in ["origin", ""]:
        r = published(identity, co, scope)
        check r.status == gqsOk
        check not r.isPublished

      # Detached HEAD: on the published base, then on the unpublished commit.
      discard requireSuccess("git checkout -q --detach " & base, co)
      r = published(identity, co, "origin")
      check r.status == gqsOk and r.isPublished
      discard requireSuccess("git checkout -q --detach " & local, co)
      r = published(identity, co, "origin")
      check r.status == gqsOk and not r.isPublished

      # Only a branch whose NAME has slashes holds HEAD: `origin/*` must still
      # cover `origin/users/a/b`, as the old `startsWith("origin/")` did.
      discard requireSuccess("git checkout -q --detach " & onNested, co)
      check requireSuccess("git branch -r --contains HEAD", co).strip() ==
        "origin/users/a/b"
      r = published(identity, co, "origin")
      check r.status == gqsOk and r.isPublished

      # Scoping is real: a configured remote that does not hold HEAD answers
      # unpublished even though `origin` holds it…
      let other = scratch / "other.git"
      discard requireSuccess("git init -q --bare " & quoteShell(other))
      discard requireSuccess("git remote add other " &
        quoteShell(fileUrl(other)), co)
      discard requireSuccess("git push -q other " & base & ":refs/heads/b", co)
      discard requireSuccess("git fetch -q other", co)
      r = published(identity, co, "other")
      check r.status == gqsOk
      check not r.isPublished
      check r.publishedScope == "other"
      # …and a remote the checkout does not have degrades to every remote.
      r = published(identity, co, "not-a-remote")
      check r.status == gqsOk and r.isPublished and r.publishedScope == ""

      # A bare `refs/remotes/<name>` is not a `<remote>/<branch>` tracking
      # ref, so it is never evidence — exactly as the old parser, which
      # demanded the `/`, treated it.
      discard requireSuccess("git checkout -q --detach " & local, co)
      discard requireSuccess("git update-ref refs/remotes/flat " & local, co)
      r = published(identity, co, "")
      check r.status == gqsOk
      check not r.isPublished
      # Control: the same commit under `<remote>/<branch>` IS evidence.
      discard requireSuccess("git update-ref refs/remotes/other/x " & local, co)
      r = published(identity, co, "")
      check r.status == gqsOk and r.isPublished
      discard requireSuccess("git update-ref -d refs/remotes/other/x", co)
      discard requireSuccess("git update-ref -d refs/remotes/flat", co)

      # A dangling `origin/HEAD` symref neither fails the probe nor answers
      # for the branch it no longer names.
      discard requireSuccess("git symbolic-ref refs/remotes/origin/HEAD " &
        "refs/remotes/origin/gone", co)
      r = published(identity, co, "origin")
      check r.status == gqsOk and not r.isPublished
      discard requireSuccess("git checkout -q --detach " & base, co)
      r = published(identity, co, "origin")
      check r.status == gqsOk and r.isPublished

      # A remote-tracking ref naming an object the checkout does not have (a
      # stale ref into a pool that pruned it) is skipped, as `branch -r
      # --contains` skipped it: it neither fails the probe nor stands as
      # evidence. Written as a loose ref because `update-ref` refuses a
      # missing object.
      let missingOid = "1234567890123456789012345678901234567890"
      createDir(co / ".git/refs/remotes/origin")
      writeFile(co / ".git/refs/remotes/origin/pruned", missingOid & "\n")
      r = published(identity, co, "origin")
      check r.status == gqsOk and r.isPublished          # HEAD is on `base`
      discard requireSuccess("git checkout -q --detach " & local, co)
      for scope in ["origin", ""]:
        r = published(identity, co, scope)
        check r.status == gqsOk
        check not r.isPublished
      # The revision under test must itself exist: a missing one is a failed
      # probe, never "contained" (the walk ignores missing inputs, so this is
      # what keeps that from reading as published).
      let ghost = revisionOnRemoteTrackingRef(identity, co, missingOid, "")
      check not ghost.ok
      check not ghost.contained
      check ghost.diagnostic.len > 0
      removeFile(co / ".git/refs/remotes/origin/pruned")
      discard requireSuccess("git checkout -q --detach " & base, co)

      # The full query (`localOnly = false`) and the extended status agree
      # with the local one on an unpublished HEAD.
      discard requireSuccess("git checkout -q --detach " & local, co)
      r = published(identity, co, "origin", localOnly = false)
      check r.status == gqsOk and not r.isPublished
      let extended = queryGitState(extendedStatusQuery(co, "main",
        queryStashes = false, queryFiles = false, queryAheadBehind = false,
        queryUnmerged = false, remoteName = "origin"), identity)
      check not extended.isPublished

      # The revision-level helper the health rows use answers for any ref.
      discard requireSuccess("git branch -f side " & local, co)
      let side = revisionOnRemoteTrackingRef(identity, co,
        "refs/heads/side", "")
      check side.ok and not side.contained
      let mainRef = revisionOnRemoteTrackingRef(identity, co,
        "refs/heads/main", "")
      check mainRef.ok
      check not mainRef.contained   # `main` carries `local` on top of base
      discard requireSuccess("git branch -f side " & base, co)
      check revisionOnRemoteTrackingRef(identity, co, "refs/heads/side",
        "origin").contained

  test "no remotes at all, and an unborn HEAD":
    let (haveGit, identity) = identityOrSkip()
    if not haveGit:
      skip("git is not on PATH; the predicate is a question asked of git")
    else:
      let scratch = createTempDir("repro-pubwalk-bare-", "")
      defer: removeDir(scratch)
      let repo = scratch / "lonely"
      createDir(repo)
      discard requireSuccess("git init -q -b main " & quoteShell(repo))
      discard requireSuccess("git config user.email t@example.invalid", repo)
      discard requireSuccess("git config user.name Test", repo)

      # Unborn: there is no HEAD commit to judge, so the probe FAILS. It must
      # not come back as a confident answer either way.
      var r = published(identity, repo, "origin")
      check r.status == gqsFailed
      check not r.isPublished
      check r.diagnostic.len > 0

      # Born, with no remote and no remote-tracking ref: unpublished, not an
      # error — there is simply nothing that could contain it.
      discard commitIn(repo, "only")
      for scope in ["origin", ""]:
        r = published(identity, repo, scope)
        check r.status == gqsOk
        check not r.isPublished
        check r.publishedScope == ""

suite "the publication probe on a large reference tree":

  test "its cost does not grow with the number of remote-tracking refs":
    let (haveGit, identity) = identityOrSkip()
    if not haveGit:
      skip("git is not on PATH; the cost measured is git's")
    else:
      let scratch = createTempDir("repro-pubwalk-large-", "")
      defer: removeDir(scratch)
      let repo = scratch / "reference-tree"
      discard requireSuccess("git init -q -b main " & quoteShell(repo))
      # No commit-graph, as in the pool the issue was measured against: with
      # generation numbers git prunes both forms and the difference shrinks
      # to what a fast host hides.
      discard requireSuccess("git config core.commitGraph false", repo)
      const
        manyRefs = 4_000
        fewRefs = 20
      # One linear history; each remote-tracking ref is its own commit on a
      # point near the tip, as release and user branches are; HEAD is a
      # commit on no remote branch whose parent is near the ROOT, so every
      # walk must come down the whole history to decide it.
      let tree = LargeReferenceTree(commits: 100_000, branches: manyRefs,
        mainRef: "refs/heads/main", branchPrefix: "refs/remotes/origin/")
      buildLargeReferenceTree(findExe("git"), repo, tree)
      discard commitOffOldBase(findExe("git"), repo, tree,
        "refs/heads/pinned", 100)
      discard requireSuccess("git symbolic-ref HEAD refs/heads/pinned", repo)
      check requireSuccess("git for-each-ref refs/remotes", repo).
        splitLines().len >= manyRefs
      # A remote, so the scope `origin` is the configured one.
      discard requireSuccess("git remote add origin " &
        quoteShell(fileUrl(scratch / "absent.git")), repo)

      proc probe(): float =
        ## Seconds for the gate's local publication probe, best of two:
        ## the first run also pays for reading the pack into the OS cache.
        result = Inf
        for attempt in 0 .. 1:
          let started = getMonoTime()
          let r = published(identity, repo, "origin")
          let elapsed = (getMonoTime() - started).inNanoseconds.float / 1e9
          check r.status == gqsOk
          check not r.isPublished   # the answer, not only the cost
          result = min(result, elapsed)

      let withMany = probe()
      var deletions = ""
      for b in fewRefs ..< manyRefs:
        deletions.add("delete refs/remotes/origin/b" & $b & "\n")
      discard requireSuccess("git update-ref --stdin", repo, input = deletions)
      let withFew = probe()
      checkpoint("publication probe: " & $fewRefs & " refs " &
        withFew.formatFloat(ffDecimal, 2) & " s, " & $manyRefs & " refs " &
        withMany.formatFloat(ffDecimal, 2) & " s")
      # One walk: 200x the refs costs little more than the refs' own tips.
      # The per-ref form costs ~40x here, far beyond this bound.
      check withMany <= 4.0 * withFew + 2.0

      # A published HEAD deep in the same history: still one walk, and the
      # answer is still "published".
      discard requireSuccess("git checkout -q --detach main~90000", repo)
      let deep = published(identity, repo, "origin")
      check deep.status == gqsOk
      check deep.isPublished
