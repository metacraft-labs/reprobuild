## A synthetic stand-in for a large vendored reference tree (llvm-project and
## the like): a long linear history and thousands of branches, built in a few
## seconds with ``git fast-import``.
##
## The shape is what makes per-ref history queries expensive in a real one:
## every branch is its own commit hanging off a point near the tip of one
## long history, so a question asked about a commit near the ROOT has to come
## down the whole history once per branch when git answers it one branch at a
## time (``git branch -r --contains``), and once in total when it is asked as
## a single walk. Commits carry no files, so the pack stays small (about 15 MB
## for 100,000 commits and 4,000 branches).
##
## The stream format is git's: https://git-scm.com/docs/git-fast-import

import std/[os, strtabs, strutils, tempfiles]

import repro_core/process_env
import ../repro_test_support

proc gitIn(gitBin, repoPath: string; args: openArray[string];
           env: openArray[(string, string)] = []): string =
  ## Run ``git -C repoPath <args>`` and return its stdout ALONE: the answers
  ## read here are object ids, and a stray warning on stderr (``unable to
  ## find all commit-graph files`` and the like) would otherwise be read as
  ## part of one. Raises with git's stderr on failure, so a fixture that
  ## could not be built never reads as a test result. ``env`` overlays this
  ## process's environment.
  var childEnv = inheritedEnvTable()
  for (key, value) in env:
    childEnv[key] = value
  let res = runProgramSplit(gitBin, @["-C", repoPath] & @args,
    env = childEnv)
  if res.code != 0:
    raise newException(OSError, "git " & args.join(" ") & " in " &
      repoPath & " exited " & $res.code & ":\n" & res.stderr & res.stdout)
  res.stdout.strip()

type
  LargeReferenceTree* = object
    commits*: int        ## length of the linear history on ``mainRef``
    branches*: int       ## branches, each one commit off a point near the tip
    mainRef*: string     ## ref holding the linear history
    branchPrefix*: string
      ## Each branch is ``<branchPrefix>b<n>``: ``refs/heads/`` for an origin a
      ## checkout will clone, ``refs/remotes/origin/`` to give a checkout the
      ## remote-tracking refs directly.

const fixtureEpoch = 1_000_000_000
  ## Commit timestamps start here and rise with the history, so date-ordered
  ## walks see the history in the order a real repository presents it.

proc commitTime(position: int): int = fixtureEpoch + position * 10

proc branchBase*(tree: LargeReferenceTree; branch: int): int =
  ## The position on ``mainRef`` (1-based, from the root) that branch
  ## ``branch`` grows from: every third commit counting back from the tip.
  max(tree.commits - branch * 3, 1)

proc fastImportStream*(tree: LargeReferenceTree): string =
  ## The ``git fast-import`` input that builds ``tree``. Marks ``:1`` ..
  ## ``:<commits>`` are the history, root first.
  doAssert tree.commits >= 1
  doAssert tree.mainRef.startsWith("refs/")
  doAssert tree.branchPrefix.startsWith("refs/") and
    tree.branchPrefix.endsWith("/")
  result = newStringOfCap(tree.commits * 90 + tree.branches * 120)
  for i in 1 .. tree.commits:
    result.add("commit " & tree.mainRef & "\nmark :" & $i &
      "\ncommitter Fixture <fixture@example.invalid> " & $commitTime(i) &
      " +0000\ndata 1\nx")
    if i > 1:
      result.add("from :" & $(i - 1) & "\n")
  for b in 0 ..< tree.branches:
    let base = tree.branchBase(b)
    result.add("commit " & tree.branchPrefix & "b" & $b & "\nmark :" &
      $(tree.commits + 1 + b) & "\ncommitter Fixture <fixture@example.invalid> " &
      $(commitTime(base) + 5) & " +0000\ndata 1\nbfrom :" & $base & "\n")

proc buildLargeReferenceTree*(gitBin, repoPath: string;
                              tree: LargeReferenceTree) =
  ## Import ``tree`` into the EXISTING repository at ``repoPath`` (bare or
  ## not). Raises with git's output when the import fails, so a fixture that
  ## could not be built never reads as a test result.
  # ``fast-import`` reads the stream on stdin. It is handed over as a file
  # redirected by ``/bin/sh``, so no pipe has to be fed while the child's
  # output is drained.
  let (streamFile, streamPath) = createTempFile("large-reference-tree-",
    ".fi")
  defer: removeFile(streamPath)
  streamFile.write(tree.fastImportStream())
  streamFile.close()
  let res = runProgramSplit("/bin/sh", ["-c",
    "exec \"$0\" -C \"$1\" fast-import --quiet < \"$2\"",
    gitBin, repoPath, streamPath])
  if res.code != 0:
    raise newException(OSError, "git fast-import into " & repoPath &
      " exited " & $res.code & ":\n" & res.stderr & res.stdout)

proc commitOffOldBase*(gitBin, repoPath: string; tree: LargeReferenceTree;
                       branchRef: string; position: int): string =
  ## Point ``branchRef`` at ONE new commit (empty tree) whose parent is the
  ## ``position``-th commit of ``tree``'s history counting from the root, and
  ## return its id. That commit is on no other ref: it is what makes "is this
  ## on a remote branch?" come down the whole history. It is dated just after
  ## its parent, as a commit made on an old pinned base is. ``repoPath`` must
  ## hold ``tree.mainRef`` as imported (its tip is position ``commits``).
  doAssert position in 1 .. tree.commits
  proc git(args: openArray[string]; env: openArray[(string, string)] = []):
      string =
    gitIn(gitBin, repoPath, args, env)
  let parent = git(["rev-parse", "--verify",
    tree.mainRef & "~" & $(tree.commits - position) & "^{commit}"])
  # The parent's own tree: a commit that changes nothing is still a commit
  # on no remote branch, which is all the fixture needs it to be.
  let date = $(commitTime(position) + 7) & " +0000"
  let id = git(["commit-tree", "-p", parent, "-m", "off an old base",
    parent & "^{tree}"], [("GIT_COMMITTER_DATE", date),
    ("GIT_AUTHOR_DATE", date), ("GIT_COMMITTER_NAME", "Fixture"),
    ("GIT_COMMITTER_EMAIL", "fixture@example.invalid"),
    ("GIT_AUTHOR_NAME", "Fixture"),
    ("GIT_AUTHOR_EMAIL", "fixture@example.invalid")])
  discard git(["update-ref", branchRef, id])
  id
