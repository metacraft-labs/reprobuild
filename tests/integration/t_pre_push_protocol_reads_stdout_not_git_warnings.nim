## The pre-push protocol's own reads of the repository parse git's STDOUT,
## and a read that genuinely fails names a remedy that can help.
##
## The gate independently observes ``HEAD`` (``git rev-parse --verify
## HEAD^{commit}``) and classifies the update's shape (``git cat-file -t
## <remote-old>``). Both answers are PARSED: the first must be exactly one
## full-length hex object id, the second exactly ``commit``. When git's stderr
## was merged into the text being parsed, a repository whose split
## commit-graph chain names a pruned graph file — git then prints ``warning:
## unable to find all commit-graph files`` on stderr, exits 0, and prints the
## right answer on stdout — had its valid HEAD refused as "could not
## independently observe HEAD as a commit", and the refusal told the operator
## to reinstall the hooks, which succeeded, changed nothing, and was followed
## by the same refusal.
##
## Properties pinned here:
##
##   1. With git warning on stderr, a well-formed one-record stream that
##      carries the real HEAD to the agreed remote is protocol-valid, its
##      ``headOid`` is that HEAD, and it is ``outgoing-current``.
##   2. With git warning on stderr, a fast-forward is classified
##      ``fast-forward``, a rewrite ``rewrite``, and the rewrite's discarded
##      commits (``git rev-list``, which does warn) are exactly the real ones,
##      with no warning text read as an object id.
##   3. Strict validation is intact: a HEAD Git cannot resolve still refuses,
##      and the refusal carries git's own message and names the git command
##      to run — NOT the hooks reinstall, which cannot repair a repository.
##   4. A directory Git cannot read at all refuses the same way.
##   5. A malformed refs stream still refuses as a refs-stream fault and keeps
##      the hooks-reinstall remedy.
##
## Each fixture first asserts that it is the situation under test (git really
## does warn on stderr and really does answer on stdout), so the suite cannot
## pass vacuously on a git that stopped warning.
##
## No mocks: real git, temporary repositories and a local bare remote only.
## Skips only when git is absent.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_cli_support/push_hook_protocol
import repro_test_support/reasoned_skip

proc gitBin(): string = findExe("git")

proc requireSuccess(cwd: string; args: openArray[string]): string =
  let process = startProcess(gitBin(), workingDir = cwd, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  result = process.outputStream.readAll()
  let code = process.waitForExit()
  if code != 0:
    raise newException(OSError, "git " & args.join(" ") & " failed (" &
      $code & "):\n" & result)

proc gitStreams(cwd: string; args: openArray[string]):
    tuple[code: int; outText, errText: string] =
  ## The two streams KEPT APART, so the fixture can state what is on each.
  ## Waiting before reading is safe only because these commands write a few
  ## dozen bytes.
  let process = startProcess(gitBin(), workingDir = cwd, args = @args,
    options = {poUsePath})
  defer: process.close()
  result.code = process.waitForExit()
  result.outText = process.outputStream.readAll()
  result.errText = process.errorStream.readAll()

proc commit(repo, message: string) =
  discard requireSuccess(repo, ["-c", "user.name=Test",
    "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty",
    "-m", message])

proc headOf(repo: string; rev = "HEAD"): string =
  requireSuccess(repo, ["rev-parse", rev]).strip()

proc breakCommitGraphChain(repo: string) =
  ## A two-layer split commit-graph whose BASE layer file is gone, the shape
  ## measured in the field. Git keeps answering correctly on stdout and exits
  ## 0, but warns on stderr. Nothing about refs, objects or the tree changes.
  discard requireSuccess(repo, ["commit-graph", "write", "--reachable",
    "--split"])
  commit(repo, "after-first-graph")
  discard requireSuccess(repo, ["commit-graph", "write", "--reachable",
    "--split=no-merge"])
  let graphDir = repo / ".git" / "objects" / "info" / "commit-graphs"
  let chain = readFile(graphDir / "commit-graph-chain").splitLines()
  doAssert chain.len >= 2 and chain[1].len > 0,
    "fixture: expected a two-layer chain, got " & $chain
  removeFile(graphDir / ("graph-" & chain[0] & ".graph"))

type Fixture = object
  scratch: string
  repo: string
  remote: string

proc setup(): Fixture =
  result.scratch = createTempDir("repro-prepush-stdout-", "")
  result.repo = result.scratch / "repo"
  result.remote = result.scratch / "remote.git"
  discard requireSuccess(result.scratch, ["init", "-q", "--bare",
    result.remote])
  discard requireSuccess(result.scratch, ["init", "-q", "-b", "main",
    result.repo])
  commit(result.repo, "one")
  commit(result.repo, "two")
  discard requireSuccess(result.repo, ["remote", "add", "origin",
    result.remote])

proc writeRefs(f: Fixture; content: string): string =
  result = f.scratch / "refs.txt"
  writeFile(result, content)

proc zeroOid(): string = repeat('0', 40)

proc assertGitWarnsButAnswers(repo: string; args: openArray[string]) =
  let res = gitStreams(repo, args)
  check res.code == 0
  check res.outText.strip().len > 0
  check "commit-graph" in res.errText

suite "pre-push protocol reads stdout, not git's warnings":

  test "a valid HEAD is observed despite a stale commit-graph chain":
    if gitBin().len == 0:
      skip("git not on PATH; this case drives real git repositories")
    else:
      var f = setup()
      defer: removeDir(f.scratch)
      breakCommitGraphChain(f.repo)
      let head = headOf(f.repo)
      # The fixture is the situation under test.
      assertGitWarnsButAnswers(f.repo, ["rev-parse", "--verify",
        "HEAD^{commit}"])

      let refs = f.writeRefs("refs/heads/main " & head & " refs/heads/main " &
        zeroOid() & "\n")
      let decision = evaluateOutgoingCurrent(gitBin(), f.repo, refs,
        "origin", f.remote, "origin", f.remote)
      check decision.protocolOk
      check decision.cause == ppcNone
      check decision.diagnostic == ""
      check decision.headOid == head
      check decision.outgoingCurrent
      check decision.updateShape == ouCreate

  test "a fast-forward and a rewrite are classified despite the warning":
    if gitBin().len == 0:
      skip("git not on PATH; this case drives real git repositories")
    else:
      var f = setup()
      defer: removeDir(f.scratch)
      let base = headOf(f.repo)
      commit(f.repo, "three")
      breakCommitGraphChain(f.repo)
      let head = headOf(f.repo)

      let ff = f.writeRefs("refs/heads/main " & head & " refs/heads/main " &
        base & "\n")
      let forward = evaluateOutgoingCurrent(gitBin(), f.repo, ff,
        "origin", f.remote, "origin", f.remote)
      check forward.protocolOk
      check forward.outgoingCurrent
      check forward.updateShape == ouFastForward

      # A rewrite: the remote tip is a commit this HEAD does not contain.
      discard requireSuccess(f.repo, ["checkout", "-q", "-b", "side", base])
      commit(f.repo, "side-only")
      let sideTip = headOf(f.repo)
      discard requireSuccess(f.repo, ["checkout", "-q", "main"])
      let rw = f.writeRefs("refs/heads/main " & head & " refs/heads/main " &
        sideTip & "\n")
      # ``rev-list`` is the parsed query that warns here (``cat-file -t`` on a
      # full object id does not load the commit graph on current git).
      assertGitWarnsButAnswers(f.repo, ["rev-list", sideTip, "^" & head])
      let rewrite = evaluateOutgoingCurrent(gitBin(), f.repo, rw,
        "origin", f.remote, "origin", f.remote)
      check rewrite.protocolOk
      check rewrite.updateShape == ouRewrite
      check commitsMadeUnreachable(gitBin(), f.repo, sideTip, head) ==
        @[sideTip]

  test "a HEAD git cannot resolve refuses with git's words and a git remedy":
    if gitBin().len == 0:
      skip("git not on PATH; this case drives real git repositories")
    else:
      var f = setup()
      defer: removeDir(f.scratch)
      let head = headOf(f.repo)
      # HEAD now names a branch that does not exist: an unborn HEAD. The
      # stream itself is well-formed, so only the gate's own read can fail.
      discard requireSuccess(f.repo, ["symbolic-ref", "HEAD",
        "refs/heads/does-not-exist"])
      check gitStreams(f.repo, ["rev-parse", "--verify", "HEAD^{commit}"])
        .code != 0

      let refs = f.writeRefs("refs/heads/main " & head & " refs/heads/main " &
        zeroOid() & "\n")
      let decision = evaluateOutgoingCurrent(gitBin(), f.repo, refs,
        "origin", f.remote, "origin", f.remote)
      check not decision.protocolOk
      check not decision.outgoingCurrent
      check decision.diagnostic ==
        "could not independently observe HEAD as a commit"
      check decision.cause == ppcRepositoryObservation
      check "rev-parse --verify" in decision.failedObservation
      check f.repo in decision.failedObservation
      # Git's own message, not a paraphrase.
      check "exited 128" in decision.observationEvidence
      check "fatal:" in decision.observationEvidence

      let remedy = prePushProtocolRemediation(decision.cause, f.repo,
        decision.failedObservation)
      check "hooks ensure" notin remedy
      check decision.failedObservation in remedy
      let evidence = prePushProtocolEvidence(decision.diagnostic,
        decision.cause, decision.observationEvidence)
      check evidence.startsWith(decision.diagnostic)
      check "fatal:" in evidence

  test "a directory git cannot read refuses as a repository observation":
    if gitBin().len == 0:
      skip("git not on PATH; this case drives real git repositories")
    else:
      let scratch = createTempDir("repro-prepush-norepo-", "")
      defer: removeDir(scratch)
      let notRepo = scratch / "plain"
      createDir(notRepo)
      let refs = scratch / "refs.txt"
      writeFile(refs, "")
      let stream = parsePrePushRefStream(gitBin(), notRepo, refs)
      check not stream.ok
      check stream.diagnostic == "unsupported or unreadable Git object format"
      check stream.cause == ppcRepositoryObservation
      check "--show-object-format=storage" in stream.failedObservation
      check "fatal:" in stream.observationEvidence
      check "hooks ensure" notin prePushProtocolRemediation(stream.cause,
        notRepo, stream.failedObservation)

  test "a malformed stream is still a refs-stream fault with the hooks remedy":
    if gitBin().len == 0:
      skip("git not on PATH; this case drives real git repositories")
    else:
      var f = setup()
      defer: removeDir(f.scratch)
      breakCommitGraphChain(f.repo)
      let head = headOf(f.repo)
      let refs = f.writeRefs("refs/heads/main  " & head & " refs/heads/main " &
        zeroOid() & "\n")
      let decision = evaluateOutgoingCurrent(gitBin(), f.repo, refs,
        "origin", f.remote, "origin", f.remote)
      check not decision.protocolOk
      check decision.diagnostic ==
        "pre-push refs record is not canonically spaced"
      check decision.cause == ppcRefsStream
      check decision.observationEvidence == ""
      check prePushProtocolRemediation(decision.cause, f.repo,
        decision.failedObservation) ==
        "reinstall the managed hooks with 'repro hooks ensure --vcs " &
          f.repo & "' and retry the push"
      check prePushProtocolEvidence(decision.diagnostic, decision.cause,
        decision.observationEvidence) == decision.diagnostic
