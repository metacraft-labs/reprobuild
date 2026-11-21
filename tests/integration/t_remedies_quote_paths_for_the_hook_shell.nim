## **A remedy outside the flake-pin family names each path as ONE word of the
## shell the hooks run in.**
##
## Spec: Unified-Locking-And-Hooks.md §"The named command must RUN where the
## message is printed", rule 3 ("Quote for the shell the hooks run in"): the
## managed hooks run under a POSIX `sh` on every host, Git's own on Windows,
## so each path in a remedy is one word of that shell, quoted for a POSIX
## shell whatever host printed it and spelled with `/` on Windows.
##
## Issue: reprobuild-pm
## `issues/2026-11-05-remedies-outside-the-flake-pin-family-print-bare-paths.md`.
## `t_flake_remedies_quote_paths_for_the_hook_shell` holds the flake-pin family
## to the rule; this case holds the rest: the hook remedies, the lock
## commands every refusal names, the branch-fork next step and the shared
## clone messages. They used to concatenate a path bare (or quote it with
## ``quoteShell``, which quotes for the HOST and leaves `M:\m\ws` unquoted on
## Windows), so a path with a space split in two in `sh` on every OS.
##
## ## What is asserted
##
##   1. `remedyPathWord` / `remedyProsePath` spell a Windows path with `/`,
##      the word quoted for a POSIX shell and the prose not quoted;
##   2. the hook-path diagnosis and refusal (`hooksPathDiagnosisLines`,
##      `hooksPathRefusalLines`): every command they print splits, under
##      `sh`, into words whose path words are exactly the repository and the
##      hooks directory; and the `git -C … config --local core.hooksPath …`
##      remedy, pasted into `sh` from ANOTHER directory, really sets the
##      value in a repository whose path has a space;
##   3. the foreign-contract refusal's `<self> hooks ensure --vcs
##      --re-anchor <repo>` keeps both paths whole;
##   4. `workspaceLockCommand` / `committedLockCommand`, the commands rule 2
##      makes every lock refusal name, keep the workspace root whole;
##   5. the branch-fork next step (`cd <root> && repro health`) lands in the
##      new workspace when `sh` runs it;
##   6. the shared-clone recovery messages' `displayPath` is one word;
##   7. the pre-push protocol refusal's `repro hooks ensure --vcs <repo>`
##      (`prePushProtocolRemediation`) keeps the repository whole.
##
## ## Mutations
##
##   * concatenate `repoRoot` bare in `hooksPathDiagnosisLines` ⇒ RED on (2);
##   * drop `remedyPathWord` from `workspaceLockCommand` ⇒ RED on (4);
##   * return `quoteShell(shown)` from `displayPath` ⇒ RED on (6) on Windows,
##     and returning `shown` bare ⇒ RED on (6) everywhere;
##   * drop the separator rewrite from `remedyProsePath` ⇒ RED on (1).
##
## Test-double policy: NO mocks, doubles or fakes. Every message is built by
## the production function that prints it, and every command is split and run
## by the real `sh` and the real `git` found on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_cli_support
import repro_cli_support/push_hook_protocol
import shared_clones
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShellPosix(value)

proc run(command: string; cwd: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath, poEvalCommand})
  (res.exitCode, res.output)

proc shellWords(command, cwd: string): seq[string] =
  ## The words `sh` makes of ``command``: exactly what a paste into the
  ## hook's shell passes to the program.
  let script = "set -- " & command & "; for w; do printf '%s\\n' \"$w\"; done"
  let res = run("sh -c " & q(script), cwd)
  checkpoint("sh words of `" & command & "`:\n" & res.output)
  check res.code == 0
  res.output.strip(leading = false, chars = {'\n'}).splitLines()

proc commandAfter(lines: seq[string]; marker: string): string =
  ## The command a line prints after ``marker`` ("fix it with:  …").
  for line in lines:
    let at = line.find(marker)
    if at >= 0:
      return line[at + marker.len .. ^1].strip()
  ""

suite "remedies outside the flake-pin family quote paths for the hook shell":

  test "t_remedies_quote_paths_for_the_hook_shell":
    const caseName = "t_remedies_quote_paths_for_the_hook_shell"
    # ---- (1) one spelling, whatever host built the message ---------------
    check remedyPathWord("C:\\Users\\a b\\ws", windowsHost = true) ==
      "'C:/Users/a b/ws'"
    check remedyProsePath("M:\\m\\ws", windowsHost = true) == "M:/m/ws"
    check remedyProsePath("/tmp/a b", windowsHost = false) == "/tmp/a b"

    let git = findExe("git")
    let sh = findExe("sh")
    if git.len == 0 or sh.len == 0:
      skip(caseName & ": needs a real `git` and `sh` on PATH")
    else:
      # The space is the point: every path below lives under it, so a bare
      # path anywhere in a remedy splits at it.
      let scratch = createTempDir("remedy-quoting-", "")
      defer: removeDir(scratch)
      let spaced = scratch / "work space"
      let repo = spaced / "my repo"
      createDir(repo)
      let elsewhere = scratch / "elsewhere"
      createDir(elsewhere)
      check run(q(git) & " init -q " & q(repo), scratch).code == 0
      let fragment = spaced[0 ..< spaced.find(' ')]

      proc noSplitPath(command: string) =
        for w in shellWords(command, elsewhere):
          check not w.endsWith(fragment)

      # ---- (2) hook-path diagnosis and refusal ---------------------------
      let hooksDir = repo / ".git" / "hooks"
      let finding = HooksPathRepair(ok: true, previous: ".git/hooks",
        resolved: hooksDir)
      let diagnosis = hooksPathDiagnosisLines(repo, finding)
      checkpoint("diagnosis:\n" & diagnosis.join("\n"))
      let ensure = commandAfter(diagnosis, "fix it with:")
      check shellWords(ensure, elsewhere) ==
        @["repro", "hooks", "ensure", "--vcs", repo]
      let direct = commandAfter(diagnosis, "or directly:")
      check shellWords(direct, elsewhere) ==
        @["git", "-C", repo, "config", "--local", "core.hooksPath", hooksDir]
      # Pasted into `sh` from a directory that is NOT the repository, the
      # remedy really sets the value in the repository it names.
      let ran = run("sh -c " & q(direct), elsewhere)
      checkpoint("sh -c `" & direct & "`:\n" & ran.output)
      check ran.code == 0
      let got = run(q(git) & " -C " & q(repo) &
        " config --local --get core.hooksPath", elsewhere)
      check got.output.strip() == hooksDir

      let refusal = hooksPathRefusalLines(repo, HooksPathRepair(ok: false,
        previous: ".git/hooks", resolved: hooksDir, diagnostic: "probe"))
      checkpoint("refusal:\n" & refusal.join("\n"))
      check shellWords(refusal[^1].split(":", 1)[1], elsewhere) ==
        @["git", "-C", repo, "config", "--local", "core.hooksPath", hooksDir]

      # ---- (3) the foreign-contract refusal ------------------------------
      let foreign = foreignContractRefusalLines("my repo", repo, "pre-push",
        repo / ".git" / "hooks" / "pre-push")
      checkpoint("foreign-contract refusal:\n" & foreign.join("\n"))
      let reanchor = shellWords(foreign[^1].split(":", 1)[1], elsewhere)
      check reanchor.len == 6
      if reanchor.len == 6:
        check reanchor[0].len > 0
        check reanchor[1 .. ^1] ==
          @["hooks", "ensure", "--vcs", "--re-anchor", repo]

      # ---- (4) the lock commands every lock refusal names ----------------
      check shellWords(workspaceLockCommand(spaced), elsewhere) ==
        @["repro", "workspace", "lock", "--workspace-root=" & spaced]
      check shellWords(committedLockCommand(spaced), elsewhere) ==
        @["repro", "lock", "refresh", spaced]

      # ---- (5) the branch-fork next step ---------------------------------
      let fork = renderBranchTextLines(BranchReport(form: "fork",
        branch: "feature", workspaceRoot: repo,
        sourceWorkspaceRoot: elsewhere, exitCode: 0))
      checkpoint("fork report:\n" & fork.join("\n"))
      let next = commandAfter(fork, "workspace branch: cd ")
      check next.endsWith(" && repro health")
      if next.endsWith(" && repro health"):
        let cdOnly = "cd " & next[0 ..< next.len - " && repro health".len] &
          " && pwd"
        let landed = run("sh -c " & q(cdOnly), elsewhere)
        checkpoint("sh -c `" & cdOnly & "`:\n" & landed.output)
        check landed.code == 0
        check landed.output.strip() == repo

      # ---- (6) the shared-clone recovery messages ------------------------
      # `displayPath` is relative to the current directory when the path is
      # inside it, so the word is resolved against that same directory.
      let shown = shellWords(displayPath(repo), getCurrentDir())
      check shown.len == 1
      if shown.len == 1:
        check absolutePath(shown[0]) == repo

      # ---- (7) the pre-push protocol refusal's reinstall remedy ----------
      let reinstall = prePushProtocolRemediation(ppcRefsStream, repo, "")
      checkpoint("pre-push protocol remedy: " & reinstall)
      let quotedStart = reinstall.find("'repro hooks ensure")
      check quotedStart >= 0
      if quotedStart >= 0:
        let tail = reinstall[quotedStart + 1 .. ^1]
        let command = tail[0 ..< tail.rfind("' and retry")]
        check shellWords(command, elsewhere) ==
          @["repro", "hooks", "ensure", "--vcs", repo]

      # And no command printed above leaves a fragment of a split path.
      for command in [ensure, direct, workspaceLockCommand(spaced),
          committedLockCommand(spaced)]:
        noSplitPath(command)
