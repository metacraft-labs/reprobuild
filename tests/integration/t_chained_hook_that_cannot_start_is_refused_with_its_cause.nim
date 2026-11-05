## A chained `<hook>.repro-local` that cannot start is refused with its cause,
## and `repro health` reports it.
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
##      is refused, HEAD does not move, and stderr names the file, the missing
##      program, that it is a Nix store path, and the repair (re-enter the dev
##      shell, or delete the file).
##   2. A `pre-push.repro-local` that `exec`s a program that is gone: the push
##      is refused with the same cause and the remote receives no ref.
##   3. Not a false refusal: a body that keeps the store path in a variable
##      and falls back when it is missing (prek's shim does this) still runs
##      and the commit goes through.
##   4. `repro health` on the repository reports a failing `chained-hooks`
##      row naming each body that cannot start and its missing program, and
##      an `ok` row once they are gone.
##
## Test-double policy: the `repro` binary, `git`, `hooks ensure` and the
## commits and pushes are all real. The chained bodies are the condition under
## test: their shapes are those of the shims the installers write, with the
## store hashes replaced by paths that do not exist.
##
## Hermetic: a local repo and a bare remote under one temp dir; no network.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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

  test "t_chained_hook_that_cannot_start_is_refused_with_its_cause":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
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

      # ---- 1. pre-commit: the `#!` interpreter is gone ----------------
      let localPreCommit = hooksDir / "pre-commit.repro-local"
      writeExecutable(localPreCommit,
        "#!" & MissingBash & "\n" &
        "# File generated by pre-commit: https://pre-commit.com\n" &
        "echo ran >> " & q(marker) & "\n" &
        "exec " & MissingPreCommit & " \"$@\"\n")
      let headBefore = must(git & " -C " & q(repo) & " rev-parse HEAD").strip()
      writeFile(repo / "a.txt", "a\n")
      discard must(git & " -C " & q(repo) & " add a.txt")
      let refused = run(env & git & " -C " & q(repo) & " commit -q -m a")
      checkpoint("refused commit output: " & refused.output)
      check refused.code != 0
      check must(git & " -C " & q(repo) & " rev-parse HEAD").strip() ==
        headBefore
      check refused.output.contains("refusing pre-commit")
      check refused.output.contains(localPreCommit & " cannot start")
      check refused.output.contains(MissingBash)
      check refused.output.contains("Nix store path")
      check refused.output.contains("re-enter this repository's dev shell")
      check not fileExists(marker)

      # ---- 2. pre-push: the program a line `exec`s is gone ------------
      let localPrePush = hooksDir / "pre-push.repro-local"
      writeExecutable(localPrePush,
        "#!/usr/bin/env sh\n" &
        "echo ran >> " & q(marker) & "\n" &
        "exec " & MissingPreCommit & " hook-impl --hook-type=pre-push \"$@\"\n")
      let pushed = run(env & git & " -C " & q(repo) &
        " push -q origin HEAD:refs/heads/x")
      checkpoint("refused push output: " & pushed.output)
      check pushed.code != 0
      check pushed.output.contains("refusing pre-push")
      check pushed.output.contains(localPrePush & " cannot start")
      check pushed.output.contains(MissingPreCommit)
      check run(git & " -C " & q(remote) &
        " rev-parse --verify -q refs/heads/x").code != 0
      check not fileExists(marker)

      # ---- 4. health names both ---------------------------------------
      let failing = chainedHooksRow(reproBin, repo)
      check failing{"status"}.getStr() == "fail"
      let failingText = $failing
      check failingText.contains("pre-commit.repro-local runs " & MissingBash)
      check failingText.contains("pre-push.repro-local runs " &
        MissingPreCommit)

      # ---- 3. a guarded store path still runs -------------------------
      writeExecutable(localPreCommit,
        "#!/usr/bin/env sh\n" &
        "# File generated by prek: https://github.com/j178/prek\n" &
        "PREK=\"" & MissingPrek & "\"\n" &
        "if [ ! -x \"$PREK\" ]; then PREK=true; fi\n" &
        "echo ran >> " & q(marker) & "\n" &
        "exec \"$PREK\" hook-impl --hook-type=pre-commit \"$@\"\n")
      removeFile(localPrePush)
      let committed = run(env & git & " -C " & q(repo) & " commit -q -m a")
      checkpoint("guarded commit output: " & committed.output)
      check not committed.output.contains("cannot start")
      check fileExists(marker)
      check committed.code == 0
      check must(git & " -C " & q(repo) & " rev-parse HEAD").strip() !=
        headBefore

      let healthy = chainedHooksRow(reproBin, repo)
      check healthy{"status"}.getStr() == "ok"
