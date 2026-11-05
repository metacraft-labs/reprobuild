## A git probe that COUNTS commits must count git's answer, not its warnings.
##
## ``repro_cli_support`` runs git through two readers. ``gitRunPlain`` merges
## stderr into stdout, which is right for a command whose exit status is the
## answer and for text that is only quoted back in an error message.
## ``gitRunPlainQuery`` keeps stdout alone in ``output`` and the merged text in
## ``diagnostic``, which is the reader for a command whose stdout IS the
## answer. Parse sites that used the merged reader took a stderr warning for
## part of the answer.
##
## The warning that made it real is ``warning: unable to find all
## commit-graph files``. git prints it in a checkout whose split commit-graph
## chain names a pruned graph file, while still exiting 0 with the right
## answer on stdout. ``rev-list --count`` is one of the commands that print
## it, so through the merged reader the answer was ``warning: ...\n0``,
## ``parseInt`` refused it, and the checkout-safety probes below reported
## "unexpected output" as a BLOCKER: ``repro workspace migrate`` refused to
## attach a detached HEAD, and repo removal refused to delete a checkout with
## nothing to lose.
##
## The properties pinned here are about the stream the probes read:
##
##   1. A fully pushed checkout whose git warns on stderr has no blocker.
##   2. Real unpushed work is still COUNTED, exactly, with git still warning --
##      so a fix that ignores the count, or that reports "nothing" whenever it
##      cannot parse, fails here.
##   3. A probe that genuinely fails still surfaces git's message, which lives
##      on stderr -- so a fix that simply drops stderr fails here.
##
## The class-wide guard is ``scripts/check_git_run_plain_parses.py`` in
## ``just lint``; this file measures three representative sites end to end.
##
## Hermetic: temp checkouts and a local bare remote only, no network.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_cli_support
import git_tool

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = "") =
  let res = run(command, cwd)
  if res.code != 0:
    raise newException(OSError,
      "command failed: " & command & "\nexit=" & $res.code & "\n" & res.output)

proc commit(path, message: string) =
  requireSuccess("git -c user.email=t@example.com -c user.name=Test " &
    "commit -q --allow-empty -m " & quoteShell(message), path)

proc pushedCheckout(scratch: string): string =
  ## A checkout of a local bare remote whose `main` is fully pushed.
  let remote = scratch / "remote.git"
  requireSuccess("git init -q --bare -b main " & quoteShell(remote))
  result = scratch / "checkout"
  requireSuccess("git clone -q " & quoteShell(remote) & " " &
    quoteShell(result))
  requireSuccess("git checkout -q -b main", result)
  commit(result, "seed")
  requireSuccess("git push -q origin main", result)

proc makeGitTalkOnStderr(path: string) =
  ## Leave a split commit-graph CHAIN behind whose graph files are gone, the
  ## on-disk shape observed in the field. git keeps answering correctly on
  ## stdout and exits 0, but prints a warning on stderr first. Refs, objects
  ## and the working tree are untouched.
  requireSuccess("git commit-graph write --reachable --split", path)
  let graphDir = path / ".git" / "objects" / "info" / "commit-graphs"
  var removed = 0
  for kind, entry in walkDir(graphDir):
    if kind == pcFile and entry.extractFilename.endsWith(".graph"):
      removeFile(entry)
      inc removed
  doAssert removed > 0,
    "fixture: git wrote no split graph file under " & graphDir

proc gitStreams(path: string; args: openArray[string]):
    tuple[code: int; outText, errText: string] =
  ## Run git with the two streams KEPT APART, so the fixture can state what is
  ## on each. Waiting before reading is safe only because these commands
  ## write a few dozen bytes.
  let process = startProcess(findExe("git"), workingDir = path,
    args = @args, options = {poUsePath})
  defer: process.close()
  result.code = process.waitForExit()
  result.outText = process.outputStream.readAll()
  result.errText = process.errorStream.readAll()

proc requireWarningFixture(path: string; args: openArray[string];
                           answer: string) =
  ## The fixture must be the situation under test, in both directions: git
  ## exits 0, prints the expected answer on stdout, and warns on stderr. If
  ## git stopped warning here the properties would pass vacuously.
  let streams = gitStreams(path, args)
  check streams.code == 0
  check streams.outText.strip() == answer
  check streams.errText.contains("commit-graph")

suite "git answer probes read stdout, not git's warnings":

  test "a fully pushed checkout whose git warns on stderr has no blocker":
    let ambient = findExe("git")
    if ambient.len == 0:
      skip("git is not on PATH")
    else:
      let scratch = createTempDir("repro-answerprobe-clean-", "")
      defer: removeDir(scratch)
      let repo = pushedCheckout(scratch)
      makeGitTalkOnStderr(repo)
      requireWarningFixture(repo,
        ["rev-list", "--count", "--branches", "--not", "--remotes"], "0")
      requireWarningFixture(repo,
        ["rev-list", "--count", "refs/heads/main", "--not",
         "refs/remotes/origin/main"], "0")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      # (1) Through the merged reader each of these was one "unexpected
      # output 'warning: unable to find all commit-graph files\n0'" blocker.
      check unpushedCommitsBlocker(identity, repo).len == 0
      check branchAheadOfRemoteBlocker(identity, repo, "main", "origin").len == 0
      requireSuccess("git checkout -q --detach", repo)
      check detachedHeadOnlyCommits(identity, repo).len == 0

  test "unpushed work whose git warns on stderr is still counted":
    let ambient = findExe("git")
    if ambient.len == 0:
      skip("git is not on PATH")
    else:
      let scratch = createTempDir("repro-answerprobe-ahead-", "")
      defer: removeDir(scratch)
      let repo = pushedCheckout(scratch)
      commit(repo, "local one")
      commit(repo, "local two")
      requireSuccess("git checkout -q --detach", repo)
      commit(repo, "detached only")
      makeGitTalkOnStderr(repo)
      requireWarningFixture(repo,
        ["rev-list", "--count", "--branches", "--not", "--remotes"], "2")
      requireWarningFixture(repo,
        ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"],
        "1")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      # (2) The counts are git's stdout answers, exactly.
      check unpushedCommitsBlocker(identity, repo) ==
        @["2 unpushed commit(s)"]
      check branchAheadOfRemoteBlocker(identity, repo, "main", "origin") ==
        @["2 commit(s) on 'main' that origin/main does not carry"]
      check detachedHeadOnlyCommits(identity, repo) ==
        @["1 commit(s) reachable only from the detached HEAD"]

  test "a probe that genuinely fails still surfaces git's message":
    let ambient = findExe("git")
    if ambient.len == 0:
      skip("git is not on PATH")
    else:
      let scratch = createTempDir("repro-answerprobe-fail-", "")
      defer: removeDir(scratch)
      # A directory with no git ancestor: git says why on stderr and prints
      # nothing on stdout.
      let notARepo = scratch / "plain"
      createDir(notARepo)

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      # (3) "We could not tell" stays a blocker, and it says why.
      let unpushed = unpushedCommitsBlocker(identity, notARepo)
      check unpushed.len == 1
      check unpushed[0].startsWith("could not check for unpushed commits: ")
      check unpushed[0].toLowerAscii().contains("not a git repository")
      let detached = detachedHeadOnlyCommits(identity, notARepo)
      check detached.len == 1
      check detached[0].toLowerAscii().contains("not a git repository")
