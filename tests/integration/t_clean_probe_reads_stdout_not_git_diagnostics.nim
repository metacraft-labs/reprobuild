## A git DIAGNOSTIC is not an ANSWER: the query probes must read stdout alone.
##
## ``runGit`` invokes git through ``execCmdEx``, which implies
## ``poStdErrToStdOut`` — git's stderr is merged into the string the caller
## gets back. That is right for the mutating actions (for ``clone`` and
## ``fetch`` the stderr text IS the payload) and wrong for every probe that
## PARSES git's answer, because a benign diagnostic then arrives
## indistinguishable from the answer itself.
##
## The diagnostic that made this real is ``warning: unable to find all
## commit-graph files``. The split commit-graph is a DERIVED cache that git
## writes and prunes on its own; a chain file left pointing at a pruned graph
## makes every git command in that repo print the warning on stderr while
## still exiting 0 and still printing the correct answer on stdout. Merged,
## that one line meant:
##
##   * ``isCleanQuery`` reported a PRISTINE working tree as dirty, because
##     "clean" is "the porcelain stream was empty" and the stream was not;
##   * the pre-push gate then refused the push with ``dirty — commit or stash
##     changes in <repo>``, naming a repo with nothing to commit. Deleting the
##     derived cache "fixed" it, which is the tell: no commit, no stash, no
##     change to the tree.
##   * ``extendedStatusQuery`` additionally counted the warning as a MODIFIED
##     FILE and reported a ``FileStatusEntry`` whose status code was ``wa``
##     and whose path was the tail of the warning text;
##   * ``headShaQuery`` returned the warning line where a SHA belongs.
##
## The properties pinned here are about the STREAM the probes read, not about
## this one warning:
##
##   1. A genuinely clean tree reads CLEAN even when git writes to stderr.
##   2. A genuinely modified tree still reads DIRTY, and the extended status
##      counts exactly the real entries — so a "fix" that hardcodes clean, or
##      that filters lines by shape and swallows a real one, fails here.
##   3. A ``git status`` that genuinely FAILS still surfaces git's message —
##      which lives on stderr, so a fix that simply drops stderr fails here.
##   4. ``headShaQuery`` answers with the SHA, not the warning.
##
## Hermetic: temp checkouts only, no network. Skips only when git is absent.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

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

proc seedRepo(path: string) =
  createDir(path)
  requireSuccess("git init -q -b main " & quoteShell(path))
  requireSuccess("git config user.email t@example.com", path)
  requireSuccess("git config user.name Test", path)
  writeFile(path / "file.txt", "seed\n")
  requireSuccess("git add file.txt", path)
  requireSuccess("git commit -q -m seed", path)

proc makeGitTalkOnStderr(path: string) =
  ## Leave a split commit-graph CHAIN behind whose graph files are gone. This
  ## is the exact on-disk shape that produced the field report: git keeps
  ## answering correctly on stdout and exits 0, but prints a warning on
  ## stderr first. Nothing about the working TREE is touched — the repo stays
  ## byte-for-byte as clean (or as dirty) as the caller left it.
  requireSuccess("git commit-graph write --reachable --split", path)
  let graphDir = path / ".git" / "objects" / "info" / "commit-graphs"
  var removed = 0
  for kind, entry in walkDir(graphDir):
    if kind == pcFile and entry.extractFilename.endsWith(".graph"):
      removeFile(entry)
      inc removed
  doAssert removed > 0,
    "fixture: git wrote no split graph file under " & graphDir

proc makeHeadRefnameAmbiguous(path: string) =
  ## A SECOND, unrelated way to make git talk on stderr, so the properties
  ## below do not hang on one git version still emitting one message. A ref
  ## literally named ``HEAD`` under ``refs/heads/`` makes ``git rev-parse
  ## HEAD`` print ``warning: refname 'HEAD' is ambiguous.`` on stderr while
  ## still printing the right SHA on stdout — and unlike the commit-graph
  ## chain it reaches ``rev-parse`` too, so the SHA probe is measurable.
  let sha = execCmdEx("git rev-parse HEAD", workingDir = path).output.strip()
  doAssert sha.len == 40, "fixture: unexpected HEAD sha " & sha
  requireSuccess("git update-ref refs/heads/HEAD " & sha, path)

proc gitStreams(path: string; args: openArray[string]):
    tuple[code: int; outText, errText: string] =
  ## Run git with the two streams KEPT APART, so the fixture can state what
  ## is on each. Deliberately not ``execCmdEx``: it implies
  ## ``poStdErrToStdOut``, which is the very conflation under test, and
  ## ``poEvalCommand`` hands the raw string to ``CreateProcess`` on Windows
  ## (no shell), so a ``2>file`` appended here would reach git as a literal
  ## pathspec rather than a redirect.
  ##
  ## Waiting BEFORE reading is safe only because these fixture commands write
  ## a few dozen bytes; a general-purpose runner must drain both pipes while
  ## the child runs or it deadlocks when one fills.
  let process = startProcess(findExe("git"), workingDir = path,
    args = @args, options = {poUsePath})
  defer: process.close()
  result.code = process.waitForExit()
  result.outText = process.outputStream.readAll()
  result.errText = process.errorStream.readAll()

suite "query probes read stdout, not git's diagnostics":

  test "a clean tree whose git warns on stderr reads clean":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-cleanprobe-", "")
      defer: removeDir(scratch)
      let repo = scratch / "checkout"
      seedRepo(repo)
      makeGitTalkOnStderr(repo)

      # --- the fixture must actually be the situation under test ---------
      # Falsifiable in both directions: if git stopped warning here the test
      # would pass vacuously, and if it started reporting a real change the
      # test would be measuring something else. Assert both halves.
      let porcelain = gitStreams(repo, ["status", "--porcelain"])
      check porcelain.code == 0
      check porcelain.outText.strip().len == 0
      check porcelain.errText.strip().len > 0
      check porcelain.errText.contains("commit-graph")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # (1) THE PROPERTY. Before the fix this returned isClean = false and the
      # pre-push gate refused the push.
      let cleanRes = queryGitState(isCleanQuery(repo), identity)
      check cleanRes.status == gqsOk
      check cleanRes.diagnostic.len == 0
      check cleanRes.isClean

      # The extended path runs its own `status --porcelain` and parses the
      # status columns out of it, so it is a SECOND reader of the same stream.
      let extended = queryGitState(
        extendedStatusQuery(repo, "main", queryStashes = true,
          queryFiles = true, queryAheadBehind = true, queryUnmerged = true,
          queryFileDetails = true), identity)
      check extended.status == gqsOk
      check extended.isClean
      check extended.untrackedCount == 0
      check extended.modifiedCount == 0
      check extended.fileDetails.len == 0
      # `git stash list` COUNTS its non-empty stdout lines, so the warning was
      # a phantom stash. There are no stashes in this fixture.
      check extended.stashCount == 0
      # `git branch --no-merged` names one branch per line; `main` is the only
      # branch and it is the trunk, so the answer is empty.
      check extended.unmergedBranches.len == 0

      # (4) ... and the SHA probe answers with a SHA.
      let headRes = queryGitState(headShaQuery(repo), identity)
      check headRes.status == gqsOk
      check headRes.headSha.len == 40
      for c in headRes.headSha:
        check c in HexDigits

  test "a modified tree whose git warns on stderr still reads dirty":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-cleanprobe-dirty-", "")
      defer: removeDir(scratch)
      let repo = scratch / "checkout"
      seedRepo(repo)
      makeGitTalkOnStderr(repo)

      # One tracked file modified, one untracked file added.
      writeFile(repo / "file.txt", "changed\n")
      writeFile(repo / "extra.txt", "new\n")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # (2) Still dirty — a fix that answers "clean" unconditionally, or that
      # drops stdout along with stderr, dies here.
      let cleanRes = queryGitState(isCleanQuery(repo), identity)
      check cleanRes.status == gqsOk
      check not cleanRes.isClean

      # EXACT counts, so a filter that ate a real porcelain line (or let the
      # warning through as a phantom entry) is caught. Pre-fix this reported
      # modifiedCount = 2 — the real change plus a `wa`-coded warning row.
      let extended = queryGitState(
        extendedStatusQuery(repo, "main", queryStashes = true,
          queryFiles = true, queryAheadBehind = true, queryUnmerged = true,
          queryFileDetails = true), identity)
      check extended.status == gqsOk
      check not extended.isClean
      check extended.stashCount == 0
      check extended.modifiedCount == 1
      check extended.untrackedCount == 1
      check extended.fileDetails.len == 2
      var seen: seq[string] = @[]
      for entry in extended.fileDetails:
        check entry.code.strip().len > 0
        check not entry.code.startsWith("wa")
        seen.add(entry.path)
      check "file.txt" in seen
      check "extra.txt" in seen

  test "a git status that genuinely fails still surfaces its diagnostic":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-cleanprobe-fail-", "")
      defer: removeDir(scratch)
      # A directory that is NOT a git checkout, and has no git ancestor.
      let notARepo = scratch / "plain"
      createDir(notARepo)

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # (3) git says WHY on stderr and nothing on stdout. A fix that reads
      # stdout and discards stderr reports a bare "failed (128): " here.
      let cleanRes = queryGitState(isCleanQuery(notARepo), identity)
      check cleanRes.status == gqsFailed
      check cleanRes.diagnostic.len > 0
      check cleanRes.diagnostic.contains("git status --porcelain failed")
      check cleanRes.diagnostic.toLowerAscii().contains("not a git repository")

      # The SHA probe carries the same obligation.
      let headRes = queryGitState(headShaQuery(notARepo), identity)
      check headRes.status == gqsFailed
      check headRes.diagnostic.toLowerAscii().contains("not a git repository")

  test "an ambiguous-refname warning does not become the answer":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-cleanprobe-amb-", "")
      defer: removeDir(scratch)
      let repo = scratch / "checkout"
      seedRepo(repo)
      let trueSha =
        execCmdEx("git rev-parse HEAD", workingDir = repo).output.strip()
      makeHeadRefnameAmbiguous(repo)

      # Precondition: git warns on stderr and still answers on stdout.
      let probe = gitStreams(repo, ["rev-parse", "HEAD"])
      check probe.code == 0
      check probe.outText.strip() == trueSha
      check probe.errText.contains("ambiguous")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # The SHA probe must answer with the SHA. Merged, it answered with the
      # warning line, and every consumer that compares or records a HEAD SHA
      # recorded that instead.
      let headRes = queryGitState(headShaQuery(repo), identity)
      check headRes.status == gqsOk
      check headRes.headSha == trueSha

      # ... and the clean probe holds under a diagnostic that has nothing to
      # do with the commit-graph.
      let cleanRes = queryGitState(isCleanQuery(repo), identity)
      check cleanRes.status == gqsOk
      check cleanRes.isClean
