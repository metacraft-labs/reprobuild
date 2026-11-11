{.define: reproGitStdoutReaderTest.}

## A git reader's ANSWER comes from git's stdout alone; git's stderr is a
## diagnostic, reported separately (reprobuild-pm
## ``spec/Testing/Frozen-766-Git-Structured-Output.md``, "Authoritative
## requirements").
##
## The readers pinned here did not go through ``gitRunPlainQuery``: each ran
## git itself with stderr merged into stdout (``execCmdEx`` with
## ``poStdErrToStdOut``, or ``gitRunPlainEnv``) and ``strip()``ped the merged
## text into an object id, a path, a URL or a ref listing. git writes
## warnings to stderr while still exiting 0 with the right answer on stdout,
## so the warning became part of the answer.
##
## The properties:
##
##   1. ``revParse`` (the divergence check's local and remote tips) answers
##      the SHA for a name that is both a branch and a tag, where real git
##      prints ``warning: refname '<name>' is ambiguous.`` on stderr and exits
##      0. Through the merged stream the "SHA" carried the warning.
##   2. Each reader answers correctly when git writes a line to stderr before
##      answering: ``probeGitOperationInProgress`` (``rev-parse --git-path``,
##      where an extra line made the paths impossible to map back onto their
##      names, so a probe of an idle checkout answered "indeterminate"),
##      ``gitRemoteOriginUrl``, ``vcsPrivateMetadataDir``, the workspace-root
##      discovery's ``mainWorktreeRootFor`` (``rev-parse --git-common-dir`` /
##      ``--git-dir``), ``configuredPushLocationValues``
##      (``remote get-url --push --all``, where the warning counted as one
##      more push URL), ``advertisedPushHeads`` (``ls-remote``, where the
##      warning was a malformed advertisement and the read failed closed),
##      the hook-target probes behind ``inspectWorktreeSafeHooksPath``, and
##      the ``git --version`` banner a ``GitToolIdentity`` records.
##   3. A query that genuinely fails still surfaces git's message, which
##      lives on stderr -- so a fix that simply drops stderr fails here.
##
## THE STAND-IN GIT, AND WHY IT IS JUSTIFIED. Property 2 runs the readers
## against a tiny ``git`` wrapper script that writes one line to stderr and
## then ``exec``s the real git with the same arguments, so every answer is
## still the real git's answer from a real repository. It is a stand-in for
## ANY stderr diagnostic git can print while succeeding: a ``safe.directory``
## notice, a ``GIT_TRACE`` line, a deprecation warning. Real git does not warn
## for these particular commands in a fixture this test can build
## (``--git-path``, ``--git-common-dir``, ``config --get``, ``remote get-url``
## and ``ls-remote`` stay silent even in a checkout with a pruned split
## commit-graph chain, measured with git 2.54.0), so without the wrapper the
## shape could not be exercised at all. Where real git does warn (an
## ambiguous refname, property 1) the real condition is used and the fixture
## asserts git really warned. The wrapper needs ``/bin/sh``, so property 2
## runs on POSIX hosts only.
##
## The class-wide guard is ``scripts/check_git_run_plain_parses.py`` in
## ``just lint``, which refuses a parse of any merged run of git; this file
## measures the readers end to end.
##
## Hermetic: temp checkouts and a local bare remote only, no network.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_cli_support
import repro_test_support/reasoned_skip
import git_tool

const WrapperWarning = "warning: stand-in diagnostic written before the answer"

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

proc gitStreams(gitBin, path: string; args: openArray[string]):
    tuple[code: int; outText, errText: string] =
  ## Run ``gitBin`` with the two streams KEPT APART, so the fixture can state
  ## what is on each. Waiting before reading is safe only because these
  ## commands write a few dozen bytes.
  let process = startProcess(gitBin, workingDir = path, args = @args,
    options = {poUsePath})
  defer: process.close()
  result.code = process.waitForExit()
  result.outText = process.outputStream.readAll()
  result.errText = process.errorStream.readAll()

proc pushedCheckout(scratch: string): tuple[repo, remote: string] =
  ## A checkout of a local bare remote whose `main` is fully pushed.
  result.remote = scratch / "remote.git"
  requireSuccess("git init -q --bare -b main " & quoteShell(result.remote))
  result.repo = scratch / "checkout"
  requireSuccess("git clone -q " & quoteShell(result.remote) & " " &
    quoteShell(result.repo))
  requireSuccess("git checkout -q -b main", result.repo)
  commit(result.repo, "seed")
  requireSuccess("git push -q origin main", result.repo)

proc talkativeGit(dir, realGit: string): string =
  ## The stand-in described in the header: ``<dir>/git`` writes
  ## ``WrapperWarning`` to stderr, then becomes the real git.
  createDir(dir)
  result = dir / "git"
  writeFile(result, "#!/bin/sh\nprintf '%s\\n' " & quoteShell(WrapperWarning) &
    " >&2\nexec " & quoteShell(realGit) & " \"$@\"\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc samePath(a, b: string): bool =
  ## ``sameFile`` that answers false, instead of raising, for a path that does
  ## not exist -- a wrong answer here must fail its check, not end the case.
  a.len > 0 and b.len > 0 and (dirExists(a) or fileExists(a)) and
    (dirExists(b) or fileExists(b)) and sameFile(a, b)

proc requireTalkative(wrapper, repo: string; args: openArray[string];
                      answer: string) =
  ## The wrapper must be the situation under test, in both directions: it
  ## exits 0, prints the real answer on stdout, and the warning on stderr.
  ## Otherwise the properties would pass vacuously.
  let streams = gitStreams(wrapper, repo, args)
  check streams.code == 0
  check streams.outText.strip() == answer
  check streams.errText.contains(WrapperWarning)

suite "direct git readers answer from git's stdout, not its warnings":

  test "revParse answers the SHA of an ambiguous refname git warns about":
    let ambient = findExe("git")
    if ambient.len == 0:
      skip("git is not on PATH")
    else:
      let scratch = createTempDir("repro-directreader-ambiguous-", "")
      defer: removeDir(scratch)
      let repo = pushedCheckout(scratch).repo
      commit(repo, "second")
      # `both` names a branch at HEAD~1 and a tag at HEAD.
      requireSuccess("git branch both HEAD~1", repo)
      requireSuccess("git tag both HEAD", repo)
      let tagged = gitStreams(ambient, repo, ["rev-parse", "refs/tags/both"])
      check tagged.code == 0
      let expected = tagged.outText.strip()
      # Real git, real condition: exit 0, the SHA alone on stdout, the
      # ambiguity warning on stderr.
      let streams = gitStreams(ambient, repo, ["rev-parse", "both"])
      check streams.code == 0
      check streams.outText.strip() == expected
      check streams.errText.contains("ambiguous")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      # (1) Through the merged stream this was
      # "warning: refname 'both' is ambiguous.\n<sha>".
      check revParseForTest(identity, repo, "both") == expected

  test "each reader answers correctly while git writes to stderr":
    let ambient = findExe("git")
    if ambient.len == 0:
      skip("git is not on PATH")
    elif defined(windows):
      skip("the stand-in git is a /bin/sh script")
    else:
      let scratch = createTempDir("repro-directreader-talkative-", "")
      defer: removeDir(scratch)
      let (repo, remote) = pushedCheckout(scratch)
      let linked = scratch / "linked"
      requireSuccess("git worktree add -q -b side " & quoteShell(linked), repo)
      let wrapperDir = scratch / "bin"
      let wrapper = talkativeGit(wrapperDir, ambient)
      let head = gitStreams(ambient, repo, ["rev-parse", "HEAD"]).outText.strip()
      requireTalkative(wrapper, repo, ["rev-parse", "HEAD"], head)
      requireTalkative(wrapper, repo,
        ["config", "--get", "remote.origin.url"], remote)

      # (2) The version banner is the real git's, not the wrapper's notice.
      let identity = ensureGitToolResolvable(tpmPathOnly, wrapperDir)
      check samePath(identity.binaryPath, wrapper)
      check identity.version.startsWith("git version ")

      check revParseForTest(identity, repo, "HEAD") == head

      let probe = probeGitOperationInProgress(identity, repo)
      check probe.state == gosIdle
      check probe.diagnostic == ""

      check gitRemoteOriginUrlForTest(identity, repo) == remote

      check vcsPrivateMetadataDir(repo, wrapper) ==
        os.normalizedPath(expandFilename(repo / ".git")) / "repro"

      check samePath(mainWorktreeRootForTest(linked, wrapper), repo)

      let locations = configuredPushLocationValuesForTest(identity, repo,
        "origin")
      check locations.ok
      check locations.values == @[remote]

      let advertised = advertisedPushHeadsForTest(identity, repo / ".git",
        remote, head.len)
      check advertised.ok
      check advertised.heads == @[(oid: head, refName: "refs/heads/main")]

      # The hook-target probes run the `git` on PATH.
      requireSuccess("git config core.hooksPath .githooks", repo)
      let savedPath = getEnv("PATH")
      putEnv("PATH", wrapperDir & PathSep & savedPath)
      defer: putEnv("PATH", savedPath)
      let finding = inspectWorktreeSafeHooksPath(repo)
      check finding.ok
      check finding.previous == ".githooks"
      check samePath(finding.resolved.parentDir, repo)
      check finding.resolved.extractFilename == ".githooks"

  test "a query that genuinely fails still surfaces git's message":
    let ambient = findExe("git")
    if ambient.len == 0:
      skip("git is not on PATH")
    else:
      let scratch = createTempDir("repro-directreader-fail-", "")
      defer: removeDir(scratch)
      # A directory with no git ancestor: git says why on stderr and prints
      # nothing on stdout.
      let notARepo = scratch / "plain"
      createDir(notARepo)
      let streams = gitStreams(ambient, notARepo,
        ["rev-parse", "--git-path", "rebase-merge"])
      check streams.code != 0
      check streams.outText.strip().len == 0
      check streams.errText.toLowerAscii().contains("not a git repository")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)
      # (3) "I could not tell" stays indeterminate, and it says why.
      let probe = probeGitOperationInProgress(identity, notARepo)
      check probe.state == gosIndeterminate
      check probe.diagnostic.toLowerAscii().contains("not a git repository")
      # A reader whose contract is "empty on failure" still answers empty,
      # not with git's message in place of a SHA.
      check revParseForTest(identity, notARepo, "HEAD") == ""
      check gitRemoteOriginUrlForTest(identity, notARepo) == ""
