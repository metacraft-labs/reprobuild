## ``isPublishedQuery`` must not assume the remote is called ``origin``.
##
## `git branch -r --contains HEAD` reports refs as ``<remote>/<branch>``, and
## the publication check filters those lines by prefix. When the prefix is
## hardcoded to ``origin/`` it answers "unpublished" for any worktree whose
## remote carries a different name — and the `repo` tool names remotes after
## the ORG (``metacraft-labs/dev``, not ``origin/dev``). Every commit in such a
## checkout then looks unpublished, including ones sitting on the remote's own
## default branch, which is enough to block a push through the workspace
## pre-push check.
##
## The contract pinned here:
##
##   1. An EMPTY remote name means "any remote-tracking branch" — the question
##      the `not on any remote-tracking branch` diagnostic has always claimed
##      to ask. A commit reachable from ``metacraft-labs/main`` is published.
##      (Falsifiable: the pre-fix code built the needle ``"/"`` and matched
##      nothing, so this returned false.)
##   2. A name that is NOT a configured remote of the worktree degrades to the
##      any-remote answer. `gitRemoteNameFor` returns a hardcoded "origin"
##      whenever the manifest entry carries no remote name, so callers
##      routinely arrive asking about a remote that does not exist here — and
##      in a `repo`-tool workspace it never does. Treating that guess as a
##      constraint reported commits on the remote's own default branch as
##      unpublished, which is a hard block on correct work.
##   3. Scoping is still REAL when the named remote does exist: a configured
##      remote that does not contain HEAD answers unpublished. The fallback in
##      (2) must not collapse every scoped query into "any".
##   4. A genuinely unpublished commit is still reported as unpublished under
##      the "any remote" mode — the fix must not degrade into "always true".
##
## Hermetic: one temp root holds a local bare upstream and a clone made with
## ``--origin metacraft-labs``. No network. Skips only when git is absent.

import std/[os, osproc, strutils, tempfiles, unittest]

import git_actions
import git_tool

proc whichGit(): string = findExe("git")

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = "") =
  let res = run(command, cwd)
  if res.code != 0:
    raise newException(OSError,
      "command failed: " & command & "\nexit=" & $res.code & "\n" & res.output)

proc fileUrl(path: string): string =
  var normalized = absolutePath(path).replace('\\', '/')
  if not normalized.startsWith("/"):
    normalized = "/" & normalized
  "file://" & normalized

suite "isPublishedQuery — remote naming":

  test "head on a non-origin remote counts as published":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ispublished-", "")
      defer: removeDir(scratch)

      # --- a bare upstream with one commit on `main` ---------------------
      let originPath = scratch / "upstream.git"
      let seedWork = scratch / "seed"
      createDir(seedWork)
      requireSuccess("git init -q -b main " & quoteShell(seedWork))
      requireSuccess("git config user.email t@example.com", seedWork)
      requireSuccess("git config user.name Test", seedWork)
      writeFile(seedWork / "file.txt", "seed\n")
      requireSuccess("git add file.txt", seedWork)
      requireSuccess("git commit -q -m seed", seedWork)
      requireSuccess("git clone -q --bare " & quoteShell(seedWork) & " " &
        quoteShell(originPath))

      # --- clone it with the remote named like the `repo` tool names it ---
      let clonePath = scratch / "checkout"
      requireSuccess("git clone -q --origin metacraft-labs " &
        quoteShell(fileUrl(originPath)) & " " & quoteShell(clonePath))

      # Precondition: the remote really is not called `origin`.
      let remotes = run("git remote", clonePath).output.strip()
      check remotes == "metacraft-labs"

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # (1) any-remote mode sees the commit as published
      let anyRes = queryGitState(isPublishedQuery(clonePath, ""), identity)
      check anyRes.status == gqsOk
      check anyRes.isPublished

      # (2) a name that is NOT a configured remote here — exactly what
      #     `gitRemoteNameFor`'s "origin" fallback produces — degrades to the
      #     any-remote answer instead of a confident falsehood.
      let originRes =
        queryGitState(isPublishedQuery(clonePath, "origin"), identity)
      check originRes.status == gqsOk
      check originRes.isPublished

      # (2b) the explicit, RIGHT remote name also answers published
      let namedRes =
        queryGitState(isPublishedQuery(clonePath, "metacraft-labs"), identity)
      check namedRes.status == gqsOk
      check namedRes.isPublished

      # (3) scoping is still real: a remote that IS configured but does not
      #     contain HEAD answers unpublished. Point a second remote at an
      #     unrelated upstream so the distinction is observable.
      let otherOrigin = scratch / "other.git"
      let otherWork = scratch / "otherseed"
      createDir(otherWork)
      requireSuccess("git init -q -b main " & quoteShell(otherWork))
      requireSuccess("git config user.email t@example.com", otherWork)
      requireSuccess("git config user.name Test", otherWork)
      writeFile(otherWork / "other.txt", "unrelated\n")
      requireSuccess("git add other.txt", otherWork)
      requireSuccess("git commit -q -m unrelated", otherWork)
      requireSuccess("git clone -q --bare " & quoteShell(otherWork) & " " &
        quoteShell(otherOrigin))
      requireSuccess("git remote add other " & quoteShell(fileUrl(otherOrigin)),
        clonePath)
      requireSuccess("git fetch -q other", clonePath)

      let scopedRes =
        queryGitState(isPublishedQuery(clonePath, "other"), identity)
      check scopedRes.status == gqsOk
      check not scopedRes.isPublished

      # (4) a local commit that was never pushed is still unpublished, so the
      #     any-remote mode has not collapsed into "always true".
      requireSuccess("git config user.email t@example.com", clonePath)
      requireSuccess("git config user.name Test", clonePath)
      writeFile(clonePath / "local.txt", "local\n")
      requireSuccess("git add local.txt", clonePath)
      requireSuccess("git commit -q -m local", clonePath)

      let afterLocal = queryGitState(isPublishedQuery(clonePath, ""), identity)
      check afterLocal.status == gqsOk
      check not afterLocal.isPublished
