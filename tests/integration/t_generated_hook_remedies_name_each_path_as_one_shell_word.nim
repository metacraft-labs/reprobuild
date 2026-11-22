## **A remedy a generated hook script prints names each path as ONE word of the
## shell the hook runs in.**
##
## Spec: Unified-Locking-And-Hooks.md §"The named command must RUN where the
## message is printed", rule 3 ("Quote for the shell the hooks run in"): each
## path in a remedy is one word of a POSIX `sh`, quoted for that shell whatever
## host printed it, and spelled with `/` on Windows.
##
## `t_flake_remedies_quote_paths_for_the_hook_shell` holds remedies that Nim
## code builds to the rule. This case holds the ones the generated hook
## SCRIPTS print: the dispatcher (`vcsDispatcherContent`) and the managed body
## (`vcsManagedHookBody`) expand `$REPO_ROOT` and the resolved `repro` in the
## shell when they run, so a Nim-side helper cannot reach them. They used to
## splice both bare into a double-quoted `echo`, and a repository or a `repro`
## under a directory with a space printed a command that split in two when
## pasted (reprobuild-pm issue
## `2026-11-18-generated-hook-scripts-print-repo-root-unquoted-in-their-remedies.md`).
##
## ## What is asserted
##
## The repository lives under `work space/it's my repo` and the resolved
## `repro` under `tool's (x86) dir`, so a bare path splits at the space, an
## unescaped `'` unbalances the word, and a bare `(` is a syntax error. Every
## command below is taken from what the INSTALLED hook printed and split by the
## real `sh`:
##
##   1. managed body, contract mismatch (probe status 3): the
##      `<repro> hooks ensure --vcs --re-anchor <repo>` line;
##   2. managed `pre-push` run without the dispatcher's protocol: the
##      `<repro> hooks ensure --vcs <repo>` remedy;
##   3. managed `pre-push` with no `repro` resolvable: the
##      `repro hooks ensure --vcs <repo>` remedy;
##   4. dispatcher running as `<hook>.legacy`: the "Restore it with" remedy;
##   5. dispatcher, chained hook whose interpreter is gone: `<repro> health`;
##   6. dispatcher, managed body missing: the `<repro> hooks ensure --vcs
##      <repo>` remedy, with the `repro` named by `$REPROBUILD_REPRO` and with
##      the one `command -v repro` finds on `PATH`. With the real binary
##      resolved, that printed command, pasted into `sh` from ANOTHER
##      directory, really reinstalls the body;
##   7. the CLI's own spelling of the same message (`hooks dispatch pre-push`
##      without `--protocol=2`) is the scripts' spelling: backticks, the
##      repository one word.
##
## Not exercised: the dispatcher's literal `repro` when none is on `PATH`
## (removing every `repro` from `PATH` would remove `git` and `sh` with it on
## some hosts). Section (3) covers the same literal in the managed body.
##
## ## Mutations
##
##   * print `$REPO_ROOT` bare in any of the six lines ⇒ RED on its section;
##   * print `$REPRO_CMD` / `$REPRO_REMEDY_CMD` bare ⇒ RED on (1), (2), (4),
##     (5), (6);
##   * make `repro_remedy_word` wrap in `'…'` without escaping `'` ⇒ RED
##     everywhere (the word no longer parses).
##
## Test-double policy: one STUB `repro`. Section (1) needs a build that
## answers the contract probe with status 3 ("I generate a different hook"),
## and no second real build can be produced hermetically inside a test
## (`t_managed_hooks_refuse_a_repro_that_does_not_speak_their_contract` gives
## the same reason). The other sections reuse it only as a `repro` at an
## awkward path: they stop before any dispatch, so nothing it answers is
## asserted. The stub answers `--version` and the probe, and exits 0 for
## everything else. The hooks, `repro hooks ensure`, `git` and `sh` are real.
##
## Hermetic: one ``createTempDir``, a local bare remote, no network.

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support/lock_consistency
import repro_test_support
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc must(args: openArray[string]; cwd: string): string =
  ## Fixture setup that must succeed. It raises, so the case fails and the
  ## scratch directory's `defer` still runs.
  let res = runShell(shellCommand(args), cwd)
  if res.code != 0:
    raise newException(IOError, "command failed: " & args.join(" ") &
      "\nexit=" & $res.code & "\n" & res.output)
  res.output

proc shellWords(sh, command, cwd: string): seq[string] =
  ## The words `sh` makes of ``command``: exactly what a paste into the
  ## hook's shell passes to the program.
  let script = "set -- " & command & "; for w; do printf '%s\\n' \"$w\"; done"
  let res = runShell(shellCommand(@[sh, "-c", script]), cwd)
  checkpoint("sh words of [" & command & "] (exit " & $res.code & "):\n" &
    res.output)
  if res.code != 0:
    return @["<sh could not parse the command>"]
  res.output.strip(leading = false, chars = {'\n', '\r'}).splitLines()

proc backticked(output, containing: string): string =
  ## The backticked chunk of ``output`` that contains ``containing``: the
  ## command a message offers to be pasted.
  ##
  ## A message that offers it in `'…'` instead (what these scripts printed
  ## before the fix) is read from the first `'` of its line to the last, so
  ## that reverting a line fails on the words `sh` makes of it and not on a
  ## command this reader could not find.
  let parts = output.split('`')
  var i = 1
  while i < parts.len:
    if containing in parts[i]:
      return parts[i]
    i += 2
  for line in output.splitLines():
    let first = line.find('\'')
    let last = line.rfind('\'')
    if containing in line and first >= 0 and last > first:
      return line[first + 1 ..< last]
  ""

proc lineCommand(output, containing: string): string =
  ## The command on the `repro hooks:` line of ``output`` that contains
  ## ``containing``, for a remedy printed on a line of its own.
  for line in output.splitLines():
    if containing in line:
      let at = line.find("repro hooks:")
      if at >= 0:
        return line[at + "repro hooks:".len .. ^1].strip()
  ""

proc writeDifferentBuildStub(path: string) =
  ## A `repro` that speaks the contract handshake and generates a DIFFERENT
  ## hook: probe status 3. It dispatches nothing.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'repro 0.0.0-stub'; exit 0; fi\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  case \" $* \" in\n" &
    "    *\" --hook-contract=\"*) echo 'stub: a different hook' >&2; exit 3 ;;\n" &
    "  esac\n" &
    "  echo 2\n" &
    "  exit 0\n" &
    "fi\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

suite "generated hook remedies name each path as one shell word":

  test "t_generated_hook_remedies_name_each_path_as_one_shell_word":
    const caseName =
      "t_generated_hook_remedies_name_each_path_as_one_shell_word"
    let git = findExe("git")
    let sh = findExe("sh")
    if git.len == 0 or sh.len == 0:
      skip(caseName & ": needs a real `git` and `sh` on PATH")
    else:
      let scratch = createTempDir("hook-remedy-words-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let repo = scratch / "work space" / "it's my repo"
      let origin = scratch / "origin.git"
      let elsewhere = scratch / "elsewhere"
      let toolDir = scratch / "tool's (x86) dir"
      createDir(repo)
      createDir(elsewhere)
      createDir(toolDir)
      let stub = toolDir / "repro"
      writeDifferentBuildStub(stub)

      discard must([git, "init", "-q", "--bare", "-b", "main", origin], scratch)
      discard must([git, "init", "-q", "-b", "main", repo], scratch)
      discard must([git, "-C", repo, "config", "user.email",
        "tester@example.invalid"], scratch)
      discard must([git, "-C", repo, "config", "user.name", "Remedy Tester"],
        scratch)
      writeFile(repo / "README.md", "remedy word fixture\n")
      discard must([git, "-C", repo, "add", "README.md"], scratch)
      discard must([git, "-C", repo, "commit", "-q", "--no-verify", "-m",
        "seed"], scratch)
      discard must([git, "-C", repo, "remote", "add", "origin", origin],
        scratch)

      let ensured = runShell(shellCommand(@[reproBin, "hooks", "ensure",
        "--vcs", repo]), scratch)
      checkpoint("hooks ensure:\n" & ensured.output)
      check ensured.code == 0
      let hooksDir = repo / ".git" / "hooks"
      let dispatcher = hooksDir / "pre-push"
      let managed = hooksDir / "pre-push.repro-managed"
      check fileExists(dispatcher)
      check fileExists(managed)

      # The repository the way the hook learns it (git's `--show-toplevel`,
      # `C:/...` on Windows), and the binary the way a remedy must spell it.
      let root = must([git, "-C", repo, "rev-parse", "--show-toplevel"],
        scratch).strip()
      let stubWord = remedyPathWord(stub)
      check shellWords(sh, stubWord, elsewhere).len == 1
      let stubPath = shellWords(sh, stubWord, elsewhere)[0]

      proc push(reproPath: string): CmdResult =
        runShell(shellCommand(@[git, "-C", repo, "push", "origin", "main"],
          @[(name: "REPROBUILD_REPRO", value: reproPath)]), scratch)

      # ---- (1) managed body: the resolved build generates another hook ----
      let different = push(stub)
      checkpoint("(1) push, different build:\n" & different.output)
      check different.code != 0
      check shellWords(sh, lineCommand(different.output, "--re-anchor"),
        elsewhere) == @[stubPath, "hooks", "ensure", "--vcs", "--re-anchor",
          root]

      # ---- (2) managed pre-push run without the dispatcher's protocol ------
      let direct = runShell(shellCommand(@[sh, managed, "origin", origin],
        @[(name: "REPROBUILD_REPRO", value: stub)]), repo)
      checkpoint("(2) managed pre-push, run directly:\n" & direct.output)
      check direct.code != 0
      check "hook protocol mismatch" in direct.output
      check shellWords(sh, backticked(direct.output, "hooks ensure"),
        elsewhere) == @[stubPath, "hooks", "ensure", "--vcs", root]

      # ---- (3) managed pre-push with no repro resolvable -------------------
      let absent = runShell(shellCommand(@[sh, managed, "origin", origin],
        @[(name: "REPROBUILD_REPRO", value: scratch / "no such" / "repro")]),
        repo)
      checkpoint("(3) managed pre-push, no repro:\n" & absent.output)
      check absent.code != 0
      check shellWords(sh, backticked(absent.output, "hooks ensure"),
        elsewhere) == @["repro", "hooks", "ensure", "--vcs", root]

      # ---- (4) the dispatcher, displaced to `<hook>.legacy` -----------------
      let legacy = hooksDir / "post-commit.legacy"
      copyFileWithPermissions(hooksDir / "post-commit", legacy)
      let displaced = runShell(shellCommand(@[sh, legacy],
        @[(name: "REPROBUILD_REPRO", value: stub)]), repo)
      removeFile(legacy)
      checkpoint("(4) dispatcher as post-commit.legacy:\n" & displaced.output)
      check "Restore it with" in displaced.output
      check shellWords(sh, backticked(displaced.output, "hooks ensure"),
        elsewhere) == @[stubPath, "hooks", "ensure", "--vcs", root]

      # ---- (5) the dispatcher, a chained hook that cannot start -------------
      let local = hooksDir / "pre-push.repro-local"
      writeFile(local, "#!/nix/store/" & "0".repeat(32) &
        "-bash-5.3p3/bin/bash\nexit 0\n")
      inclFilePermissions(local, {fpUserExec, fpGroupExec, fpOthersExec})
      let chained = push(stub)
      removeFile(local)
      checkpoint("(5) push, chained hook cannot start:\n" & chained.output)
      check chained.code != 0
      check shellWords(sh, backticked(chained.output, " health"),
        elsewhere) == @[stubPath, "health"]
      # The chained hook's own path, named in running text ("or delete
      # <path> if nothing installs ..."), is one word as well.
      let deleteAt = chained.output.find("or delete ")
      let ifAt = chained.output.find(" if nothing installs")
      check deleteAt >= 0 and ifAt > deleteAt
      if deleteAt >= 0 and ifAt > deleteAt:
        let deleteWord = chained.output[deleteAt + "or delete ".len ..< ifAt]
        check shellWords(sh, deleteWord, elsewhere) == @[local]

      # ---- (6) the dispatcher, managed body missing -------------------------
      removeFile(managed)
      let missingStub = push(stub)
      checkpoint("(6) push, managed body missing:\n" & missingStub.output)
      check missingStub.code != 0
      check "hook protocol mismatch" in missingStub.output
      check shellWords(sh, backticked(missingStub.output, "hooks ensure"),
        elsewhere) == @[stubPath, "hooks", "ensure", "--vcs", root]
      # The same remedy when the dispatcher finds `repro` on PATH
      # (`command -v`): an empty REPROBUILD_REPRO is an unset one to it.
      let onPath = runShell(shellCommand(@[git, "-C", repo, "push", "origin",
        "main"], @[(name: "REPROBUILD_REPRO", value: ""),
          (name: "PATH", value: toolDir & PathSep & getEnv("PATH"))]), scratch)
      checkpoint("(6) push, managed body missing, repro from PATH:\n" &
        onPath.output)
      check onPath.code != 0
      check shellWords(sh, backticked(onPath.output, "hooks ensure"),
        elsewhere) == @[stubPath, "hooks", "ensure", "--vcs", root]
      # With the real binary resolved the printed command is the repair, and
      # pasted into `sh` from a directory that is NOT the repository it
      # reinstalls the body in the repository it names.
      let missingReal = push(reproBin)
      checkpoint("(6) push, managed body missing, real repro:\n" &
        missingReal.output)
      check missingReal.code != 0
      let repair = backticked(missingReal.output, "hooks ensure")
      check repair.len > 0
      check not fileExists(managed)
      let repaired = runShell(shellCommand(@[sh, "-c", repair]), elsewhere)
      checkpoint("sh -c [" & repair & "]:\n" & repaired.output)
      check repaired.code == 0
      check fileExists(managed)

      # ---- (7) the CLI's own spelling of the same message -------------------
      # One ref line, as Git writes it on the hook's stdin: with nothing to
      # push the CLI has nothing to refuse.
      let head = must([git, "-C", repo, "rev-parse", "HEAD"], scratch).strip()
      let refs = scratch / "refs"
      writeFile(refs, "refs/heads/main " & head & " refs/heads/main " &
        "0".repeat(head.len) & "\n")
      let cli = runShell(shellCommand(@[reproBin, "hooks", "dispatch",
        "pre-push", "--repo-root", repo, "--refs-file", refs, "--", "origin",
        origin]), elsewhere)
      checkpoint("(7) hooks dispatch pre-push without --protocol=2:\n" &
        cli.output)
      check cli.code != 0
      check "hook protocol mismatch" in cli.output
      let cliWords = shellWords(sh, backticked(cli.output, "hooks ensure"),
        elsewhere)
      check cliWords.len == 5
      if cliWords.len == 5:
        check fileExists(cliWords[0])
        check cliWords[1 .. ^1] == @["hooks", "ensure", "--vcs", root]
