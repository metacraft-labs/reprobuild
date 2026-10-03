## `post-commit` REPORTS a worktree-unsafe `core.hooksPath`. It does not
## rewrite it.
##
## THE TWO NAMESPACES, AND WHY ONE OF THEM IS NOT REPROBUILD'S TO EDIT
##
## `selfHealManagedHooks` runs from `post-commit`, `post-merge` and
## `post-checkout` — the three call sites where the operator issued no
## hooks-related command at all; they issued `git commit`, `git merge`,
## `git checkout`. What it repairs there is two different things wearing one
## name:
##
##   * `.git/hooks/*` — the managed dispatcher bundle. Outside version
##     control, installed by Reprobuild, routinely clobbered by the dev shell's
##     `git-hooks.nix` installer on every shell entry. Reprobuild owns this
##     namespace; re-asserting it from a hook is the whole point of the
##     self-heal and is unchanged.
##   * `core.hooksPath` — a key in the operator's `.git/config`. Shared by
##     every worktree, read by every tool that runs hooks, and not Reprobuild's
##     file. Rewriting it is a different category of act from restoring a file
##     Reprobuild wrote.
##
## The write is also very nearly redundant. This repository's dev shell runs
## `repro hooks ensure` on entry, `repro hooks ensure` / `reinstall` repair the
## path on demand, and the pre-push gate REFUSES at the publication boundary
## when the path is not worktree-safe — so the one moment where an unsafe value
## could do damage is already guarded by a refusal the operator sees. What a
## silent rewrite adds is the surprise: `git commit` changed a config key
## nobody asked it to change.
##
## So the diagnostic stays — loud, on stderr, naming the value, the
## consequence and the remedy — and the write goes.
##
## WHAT IS ASSERTED
##
##   1. A real `git commit` in a repo carrying the dev shell's relative
##      `core.hooksPath` leaves that value BYTE-IDENTICAL. (Falsifiable: the
##      engine that rewrote it turns `.git/hooks` into an absolute path here.)
##   2. The same commit SAYS so: the managed `post-commit` prints a diagnostic
##      naming `core.hooksPath`, what it costs in a linked worktree, and a
##      command that fixes it. Silence would be the worse half of the trade.
##   3. `repro hooks ensure --vcs` — a hooks command, issued deliberately —
##      still DOES rewrite it. The demotion is about which call site writes,
##      not about abandoning the repair.
##
## Assertion 3 is the control that keeps 1 from being satisfiable by simply
## deleting the repair.
##
## TEST DOUBLES: none. A real `git init --bare` origin over `file://`, a real
## clone, the engine-built `build/bin/repro`, the real `repro hooks ensure
## --vcs` installer, and git's own invocation of the installed `post-commit`.
##
## BINARY PROVENANCE. The generated hook body resolves `$REPROBUILD_REPRO`
## else `command -v repro`, so a fixture that sets neither silently exercises
## whichever `repro` the dev shell pins — a store build that is not the binary
## under test. `REPROBUILD_REPRO` is anchored at the engine-built binary for
## every child process this file starts.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  Fixture = object
    scratch, workspace, app, origin, gitBin: string

proc sh(fx: Fixture; command: string; cwd = ""):
    tuple[code: int; output: string] =
  runShell(shellCommand(@["sh", "-c", command],
    @[(name: "REPROBUILD_REPRO", value: reproBinary())]),
    cwd = (if cwd.len > 0: cwd else: fx.app))

proc git(fx: Fixture; args: string; cwd = ""):
    tuple[code: int; output: string] =
  fx.sh(q(fx.gitBin) & " " & args, cwd)

proc requireGit(fx: Fixture; args: string; cwd = ""): string =
  let res = fx.git(args, cwd)
  if res.code != 0:
    # stderr rather than `checkpoint`: unittest prints checkpoints only when a
    # check fails, and `quit` ends the process before any does.
    stderr.writeLine("git " & args & " failed (" & $res.code & "):\n" &
      res.output)
    quit 1
  res.output

proc hooksPathValue(fx: Fixture; scope = "--local"): string =
  let res = fx.git("config " & scope & " --get core.hooksPath")
  if res.code != 0: "" else: res.output.strip()

proc setup(gitBin: string): Fixture =
  result.gitBin = gitBin
  result.scratch = createTempDir("repro-selfheal-hookspath-", "")
  result.workspace = result.scratch / "workspace"
  result.app = result.workspace / "app"
  result.origin = result.scratch / "origin.git"
  createDir(result.workspace)

  let fx = result
  discard fx.sh(q(gitBin) & " init --quiet --bare -b main " & q(fx.origin),
    fx.scratch)

  let seed = fx.scratch / "seed"
  discard fx.sh(q(gitBin) & " init --quiet -b main " & q(seed), fx.scratch)
  discard fx.requireGit("config user.email t@example.invalid", seed)
  discard fx.requireGit("config user.name Tester", seed)
  writeFile(seed / "README.md", "seed\n")
  discard fx.requireGit("add -A", seed)
  discard fx.requireGit("commit --quiet -m seed", seed)
  discard fx.requireGit("remote add origin " & q(fileUrl(fx.origin)), seed)
  discard fx.requireGit("push --quiet --no-verify origin main", seed)

  discard fx.sh(q(gitBin) & " clone --quiet " & q(fileUrl(fx.origin)) & " " &
    q(fx.app), fx.scratch)
  discard fx.requireGit("config user.email t@example.invalid")
  discard fx.requireGit("config user.name Tester")

  # A real initialized workspace, so `post-commit` has work to do rather than
  # standing down as "not a workspace" before it reaches the self-heal.
  createDir(fx.workspace / ".repro")
  createDir(fx.workspace / "projects")
  createDir(fx.workspace / "repos")
  writeFile(fx.workspace / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\nprojects = [\"app\"]\n")
  writeFile(fx.workspace / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"origin\"\nfetch = \"" & fileUrl(fx.origin) &
    "\"\n\nincludes = [\"repos/app.toml\"]\n")
  writeFile(fx.workspace / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"origin\"\nrevision = \"main\"\n")

proc installHooks(fx: Fixture): tuple[code: int; output: string] =
  fx.sh(q(reproBinary()) & " hooks ensure --vcs " & q(fx.workspace))

const DevShellRelativeHooksPath = ".git/hooks"
  ## Verbatim what `git-hooks.nix`'s installer leaves behind — it computes the
  ## common dir absolutely and then strips the worktree prefix back off.

suite "post-commit reports a worktree-unsafe core.hooksPath without rewriting it":

  test "t_post_commit_reports_the_relative_hook_path_and_leaves_it_alone":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs a real repository and a real " &
        "managed post-commit")
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)

      let ensured = fx.installHooks()
      checkpoint("hooks ensure (exit " & $ensured.code & "):\n" &
        ensured.output)
      check ensured.code == 0
      check fileExists(fx.app / ".git" / "hooks" / "post-commit")

      # THE FIELD CONDITION, set AFTER `ensure` so the value the commit meets
      # is the one the dev shell leaves on its next entry. `.git/hooks` still
      # resolves in the MAIN worktree, so the managed post-commit does run —
      # which is what makes its behaviour observable at all.
      discard fx.requireGit("config --local core.hooksPath " &
        q(DevShellRelativeHooksPath))
      check fx.hooksPathValue() == DevShellRelativeHooksPath

      writeFile(fx.app / "one.txt", "one\n")
      discard fx.requireGit("add -A")
      let committed = fx.git("commit -m " & q("a commit"))
      checkpoint("commit output:\n" & committed.output)
      check committed.code == 0
      # The managed post-commit really ran, so what follows is a statement
      # about what it did rather than about a hook that never fired.
      check committed.output.contains("repro")

      # (1) THE SHARED CONFIG IS UNTOUCHED. Falsifiable: the engine that
      # rewrote it leaves the absolute `<app>/.git/hooks` here.
      check fx.hooksPathValue() == DevShellRelativeHooksPath
      check not fx.hooksPathValue().isAbsolute

      # (2) AND IT SAID SO. A silent stand-down would trade one surprise for a
      # worse one.
      check committed.output.contains("core.hooksPath")
      check committed.output.contains(DevShellRelativeHooksPath)
      # It names the consequence...
      check committed.output.contains("linked worktree")
      # ...and a command the operator can run.
      check committed.output.contains("repro hooks ensure")

  test "t_hooks_ensure_still_repairs_the_relative_hook_path":
    ## The control for the case above: the repair is DEMOTED from the hook
    ## call sites, not removed. A `hooks ensure` the operator typed is a
    ## hooks-related command, and it still rewrites the shared value.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs a real repository")
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)

      discard fx.requireGit("config --local core.hooksPath " &
        q(DevShellRelativeHooksPath))
      check fx.hooksPathValue() == DevShellRelativeHooksPath

      let ensured = fx.installHooks()
      checkpoint("hooks ensure (exit " & $ensured.code & "):\n" &
        ensured.output)
      check ensured.code == 0

      let after = fx.hooksPathValue()
      checkpoint("core.hooksPath after ensure: " & after)
      check after.isAbsolute
      check after == fx.app / ".git" / "hooks"
