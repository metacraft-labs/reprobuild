## `repro push`'s clean probe must read git's ANSWER, not its diagnostics.
##
## `repro_cli_support`'s own git runner, ``gitRunPlain``, merges stderr into
## stdout (``poStdErrToStdOut``). That is the right shape for a caller that
## only tests the exit code, and for the few that read the merged text
## precisely BECAUSE they want git's message — but every probe that PARSES
## git's answer was reading that same merged stream, and a benign diagnostic
## is then indistinguishable from an answer.
##
## This is the SECOND, independent copy of the defect fixed in
## ``git_actions``'s ``runGit`` (see
## ``t_clean_probe_reads_stdout_not_git_diagnostics.nim``); this file pins the
## property for the ``repro_cli_support`` copy, whose probes gate `repro push`,
## the workspace lock writer and certificate issuance.
##
## The diagnostic that made it real is ``warning: unable to find all
## commit-graph files``. The split commit-graph is a DERIVED cache git writes
## and prunes on its own; a chain file left pointing at a pruned graph makes
## every git command in that repo print the warning on stderr while still
## exiting 0 and still printing the right answer on stdout. Measured in this
## workspace, in `codetracer-circom-recorder`:
##
##   git status --porcelain=v1  ->  exit 0, ZERO stdout bytes, one stderr line
##
## Merged, that one line is a porcelain entry that is not there, so:
##
##   * ``observeWorktreeState`` reported a PRISTINE tree as NOT clean — and it
##     is the certificate precondition, so it refused to issue at all;
##   * the post-commit workspace-lock writer skipped the lock, reporting a
##     "dirty sibling" with nothing to commit;
##   * the `repro push` preflight refused with "commit or stash changes in
##     <repo>", naming a repo with nothing to commit.
##
## The property pinned here is about the STREAM the probes read, not about
## this one warning:
##
##   1. A genuinely clean tree reads CLEAN even when git writes to stderr.
##   2. A genuinely modified tree still reads DIRTY, and an untracked file is
##      still MEASURED as untracked — so a "fix" that hardcodes clean, or that
##      filters lines by shape and swallows a real one, fails here.
##   3. A status that genuinely FAILS still surfaces git's message — which
##      lives on stderr, so a fix that simply drops stderr fails here.
##
## Hermetic: temp checkouts only, no network. Skips only when git is absent.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_cli_support
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
  ## Leave a split commit-graph CHAIN behind whose graph files are gone — the
  ## exact on-disk shape observed in the field. git keeps answering correctly
  ## on stdout and exits 0, but prints a warning on stderr first. Nothing
  ## about the working TREE is touched: the repo stays byte-for-byte as clean
  ## (or as dirty) as the caller left it.
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
  ## on each. Deliberately not ``execCmdEx``: it implies ``poStdErrToStdOut``,
  ## which is the very conflation under test, and ``poEvalCommand`` hands the
  ## raw string to ``CreateProcess`` on Windows (no shell), so a ``2>file``
  ## appended here would reach git as a literal pathspec, not a redirect.
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

suite "repro_cli_support worktree probes read stdout, not git's diagnostics":

  test "a clean tree whose git warns on stderr reads clean":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-worktreestate-", "")
      defer: removeDir(scratch)
      let repo = scratch / "checkout"
      seedRepo(repo)
      makeGitTalkOnStderr(repo)

      # --- the fixture must actually be the situation under test ----------
      # Falsifiable in both directions: if git stopped warning here the test
      # would pass vacuously, and if it started reporting a real change the
      # test would be measuring something else. Assert both halves.
      let porcelain = gitStreams(repo,
        ["status", "--porcelain=v1", "--untracked-files=all"])
      check porcelain.code == 0
      check porcelain.outText.strip().len == 0
      check porcelain.errText.strip().len > 0
      check porcelain.errText.contains("commit-graph")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # (1) THE PROPERTY. Before the fix this returned clean = false, and
      # because cleanliness is the certificate precondition, issuance stopped.
      let observed = observeWorktreeState(identity, repo)
      check observed.ok
      check observed.diagnostic.len == 0
      check observed.clean
      check not observed.untracked

  test "a modified tree whose git warns on stderr still reads dirty":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-worktreestate-dirty-", "")
      defer: removeDir(scratch)
      let repo = scratch / "checkout"
      seedRepo(repo)
      makeGitTalkOnStderr(repo)

      # One tracked file modified, one untracked file added.
      writeFile(repo / "file.txt", "changed\n")
      writeFile(repo / "extra.txt", "new\n")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # (2) Still dirty, and the untracked file is still SEEN — a fix that
      # answers "clean" unconditionally, or that drops stdout along with
      # stderr, dies here. ``clean`` and ``untracked`` are measured
      # separately and both must survive the split.
      let observed = observeWorktreeState(identity, repo)
      check observed.ok
      check not observed.clean
      check observed.untracked

  test "an untracked-only tree whose git warns on stderr is still untracked":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-worktreestate-untracked-", "")
      defer: removeDir(scratch)
      let repo = scratch / "checkout"
      seedRepo(repo)
      makeGitTalkOnStderr(repo)
      writeFile(repo / "extra.txt", "new\n")

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # The warning is NOT a `??` line, and a real `??` line is not a warning.
      # Pre-fix the warning was parsed as a status row whose code was `wa`,
      # which is neither — it made the tree read as MODIFIED rather than
      # merely untracked. Both halves are asserted so neither can be faked.
      let observed = observeWorktreeState(identity, repo)
      check observed.ok
      check observed.untracked
      check observed.clean

  test "a status that genuinely fails still surfaces its diagnostic":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-worktreestate-fail-", "")
      defer: removeDir(scratch)
      # A directory that is NOT a git checkout, and has no git ancestor.
      let notARepo = scratch / "plain"
      createDir(notARepo)

      let identity = ensureGitToolResolvable(tpmPathOnly, ambient.parentDir)

      # (3) git says WHY on stderr and nothing on stdout. A fix that reads
      # stdout and discards stderr reports a bare "failed (128): " here.
      # `ok` must be false: "we could not tell" may never become "clean".
      let observed = observeWorktreeState(identity, notARepo)
      check not observed.ok
      check not observed.clean
      check observed.diagnostic.contains("git status --porcelain failed")
      check observed.diagnostic.toLowerAscii().contains("not a git repository")
