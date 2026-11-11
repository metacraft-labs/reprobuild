## A chained `<hook>.repro-local` that fails because a program it names is
## gone says why, and `repro health` reports it before it fires.
##
## Dev-shell installers chain the pre-commit framework's shim (or a script
## that `exec`s it) as `<hook>.repro-local`, and those bodies name their tool
## by absolute Nix store path: a `#!/nix/store/...-bash/bin/bash` line, an
## `exec /nix/store/...-pre-commit/bin/pre-commit` line. Nothing roots that
## path, so a garbage collection deletes it, and from then on the dispatcher's
## first phase fails with a bare interpreter error from inside `.git/hooks`
## on every commit or push, naming neither the cause nor the repair.
##
## ## What is asserted
##
##   1. A `pre-commit.repro-local` whose `#!` interpreter is gone: the commit
##      fails, HEAD does not move, and stderr names the file, the missing
##      program, that it is a Nix store path, and the repair (re-enter the dev
##      shell, or delete the file).
##   2. A `pre-push.repro-local` that `exec`s a program that is gone: the push
##      fails with the same explanation and the remote receives no ref.
##   3. `repro health` reports the first as a `fail` (it cannot start at all)
##      and the second as a `warn` (it fails whenever that line runs), naming
##      each missing program, and `ok` once they are gone.
##   4. Nothing is blamed that is not at fault: a body that tests an optional
##      tool before it `exec`s it, a body that keeps the path in a variable
##      and falls back (prek's shim), and a body that exits 127 on its own all
##      keep their own outcome, with no explanation added and no health
##      finding.
##
## Test-double policy: the `repro` binary, `git`, `hooks ensure` and the
## commits and pushes are all real. The chained bodies are the condition under
## test: their shapes are those of the shims the installers write, with the
## store hashes replaced by paths that do not exist.
##
## Hermetic: a local repo and a bare remote under one temp dir; no network.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc must(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code & "\n" &
      res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  writeFile(path, content)
  var perms = getFilePermissions(path)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, perms)

const
  MissingBash = "/nix/store/00000000000000000000000000000000-bash-5.3p3/bin/bash"
  MissingPreCommit =
    "/nix/store/00000000000000000000000000000000-pre-commit-4.3.0/bin/pre-commit"
  MissingPrek = "/nix/store/00000000000000000000000000000000-prek-0.2.17/bin/prek"

proc chainedHooksRow(reproBin, repoPath: string): JsonNode =
  let res = run(q(reproBin) & " health " & q(repoPath) & " --json 2>/dev/null",
    repoPath)
  let start = res.output.find('{')
  if start < 0:
    checkpoint("health output: " & res.output)
    return newJNull()
  let doc =
    try: parseJson(res.output[start .. ^1])
    except CatchableError:
      checkpoint("health output: " & res.output)
      return newJNull()
  for check in doc{"checks"}.getElems():
    if check{"name"}.getStr() == "chained-hooks":
      return check
  checkpoint("no chained-hooks row in: " & res.output)
  newJNull()

suite "chained hook that cannot start":

  test "t_chained_hook_that_cannot_start_names_its_cause":
    let gitBin = findExe("git")
    let shBin = findExe("sh")
    if gitBin.len == 0 or shBin.len == 0:
      skip("git or sh not on PATH; this case commits and pushes in a real " &
        "repository")
    else:
      let scratch = createTempDir("repro-chained-unstartable-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let git = q(gitBin)
      let remote = scratch / "remote.git"
      let repo = scratch / "repo"
      discard must(git & " init -q --bare -b main " & q(remote))
      discard must(git & " init -q -b main " & q(repo))
      discard must(git & " -C " & q(repo) &
        " config user.email tester@example.invalid")
      discard must(git & " -C " & q(repo) & " config user.name Tester")
      discard must(git & " -C " & q(repo) & " remote add origin " & q(remote))
      writeFile(repo / "README.md", "fixture\n")
      discard must(git & " -C " & q(repo) & " add README.md")
      discard must(git & " -C " & q(repo) & " commit -q -m fixture")

      let ensured = run(q(reproBin) & " hooks ensure --vcs " & q(repo), repo)
      if ensured.code != 0:
        checkpoint("ensure output: " & ensured.output)
      check ensured.code == 0
      let hooksDir = repo / ".git" / "hooks"
      check readFile(hooksDir / "pre-commit").contains(
        "reprobuild hook dispatcher")
      check readFile(hooksDir / "pre-push").contains(
        "reprobuild hook dispatcher")

      let env = "env REPROBUILD_REPRO=" & q(reproBin) & " "
      let marker = scratch / "chained-ran.txt"
      proc commit(message: string): tuple[code: int; output: string] =
        writeFile(repo / (message & ".txt"), message & "\n")
        discard must(git & " -C " & q(repo) & " add " & q(message & ".txt"))
        run(env & git & " -C " & q(repo) & " commit -q -m " & q(message))
      proc head(): string =
        must(git & " -C " & q(repo) & " rev-parse HEAD").strip()

      # ---- 1. pre-commit: the `#!` interpreter is gone ----------------
      let localPreCommit = hooksDir / "pre-commit.repro-local"
      writeExecutable(localPreCommit,
        "#!" & MissingBash & "\n" &
        "# File generated by pre-commit: https://pre-commit.com\n" &
        "echo ran >> " & q(marker) & "\n" &
        "exec " & MissingPreCommit & " \"$@\"\n")
      let headBefore = head()
      let refused = commit("a")
      checkpoint("failed commit output: " & refused.output)
      check refused.code != 0
      check head() == headBefore
      check refused.output.contains("pre-commit: the chained hook " &
        localPreCommit & " cannot start: its interpreter, " & MissingBash)
      check refused.output.contains(MissingBash)
      check refused.output.contains("Nix store path")
      check refused.output.contains("re-enter this repository's dev shell")
      check not fileExists(marker)

      # ---- 2. pre-push: the program a line `exec`s is gone ------------
      let localPrePush = hooksDir / "pre-push.repro-local"
      writeExecutable(localPrePush,
        "#!/usr/bin/env sh\n" &
        "exec " & MissingPreCommit & " hook-impl --hook-type=pre-push \"$@\"\n")
      let pushed = run(env & git & " -C " & q(repo) &
        " push -q origin HEAD:refs/heads/x")
      checkpoint("failed push output: " & pushed.output)
      check pushed.code != 0
      check pushed.output.contains("pre-push: the chained hook " &
        localPrePush & " failed, likely because the program it execs, " &
        MissingPreCommit)
      check pushed.output.contains(MissingPreCommit)
      check run(git & " -C " & q(remote) &
        " rev-parse --verify -q refs/heads/x").code != 0

      # ---- 3. health: fail for the interpreter, warn for the exec -----
      let failing = chainedHooksRow(reproBin, repo)
      check failing{"status"}.getStr() == "fail"
      check ($failing).contains("interpreter " & MissingBash)
      check ($failing).contains("execs " & MissingPreCommit)

      # ---- 4. nothing blamed that is not at fault ---------------------
      # An optional tool, tested before it is exec'd: the commit goes
      # through, and health no longer reports pre-commit.
      writeExecutable(localPreCommit,
        "#!/usr/bin/env sh\n" &
        "[ -x " & MissingPreCommit & " ] || exit 0\n" &
        "exec " & MissingPreCommit & " \"$@\"\n")
      let guarded = commit("b")
      checkpoint("guarded commit output: " & guarded.output)
      check guarded.code == 0
      check not guarded.output.contains("the chained hook")
      check head() != headBefore
      let warning = chainedHooksRow(reproBin, repo)
      check warning{"status"}.getStr() == "warn"
      check not ($warning).contains("pre-commit.repro-local")
      check ($warning).contains("execs " & MissingPreCommit)

      # A body that exits 127 by itself, every program it names present:
      # the commit fails with the body's own status and nothing is added.
      writeExecutable(localPreCommit,
        "#!/usr/bin/env sh\n" &
        "exec " & shBin & " -c 'exit 127'\n")
      let own = commit("c")
      checkpoint("own-127 commit output: " & own.output)
      check own.code != 0
      check not own.output.contains("the chained hook")

      # prek's shape: the store path in a variable, with a fallback.
      writeExecutable(localPreCommit,
        "#!/usr/bin/env sh\n" &
        "# File generated by prek: https://github.com/j178/prek\n" &
        "PREK=\"" & MissingPrek & "\"\n" &
        "if [ ! -x \"$PREK\" ]; then PREK=true; fi\n" &
        "echo ran >> " & q(marker) & "\n" &
        "exec \"$PREK\" hook-impl --hook-type=pre-commit \"$@\"\n")
      let before = head()
      let prek = commit("d")
      checkpoint("prek commit output: " & prek.output)
      check prek.code == 0
      check not prek.output.contains("the chained hook")
      check fileExists(marker)
      check head() != before

      # A body that tests the path, then fails 127 on a line of its own: the
      # path it never ran is not blamed.
      writeExecutable(localPreCommit,
        "#!/usr/bin/env sh\n" &
        "if [ -x " & MissingPreCommit & " ]; then\n" &
        "exec " & MissingPreCommit & " \"$@\"\n" &
        "fi\n" &
        "exit 127\n")
      let guardedOwn = commit("e")
      checkpoint("guarded own-127 commit output: " & guardedOwn.output)
      check guardedOwn.code != 0
      check not guardedOwn.output.contains("the chained hook")

      removeFile(localPrePush)

      # Displaced: a framework moved the dispatcher to `.legacy` and runs it;
      # the dispatcher skips that framework's generated shim, so health does
      # not report the shim's missing interpreter.
      writeExecutable(localPreCommit,
        "#!" & MissingBash & "\n" &
        "# File generated by pre-commit: https://pre-commit.com\n" &
        "exec " & MissingPreCommit & " \"$@\"\n")
      moveFile(hooksDir / "pre-commit", hooksDir / "pre-commit.legacy")
      writeExecutable(hooksDir / "pre-commit",
        "#!/usr/bin/env sh\n" &
        "exec \"$(dirname \"$0\")/pre-commit.legacy\" \"$@\"\n")
      let displaced = commit("f")
      checkpoint("displaced commit output: " & displaced.output)
      check displaced.code == 0
      let displacedRow = chainedHooksRow(reproBin, repo)
      check displacedRow{"status"}.getStr() == "ok"
      removeFile(localPreCommit)

      let healthy = chainedHooksRow(reproBin, repo)
      check healthy{"status"}.getStr() == "ok"
