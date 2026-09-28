## A linked git worktree of a participating repo is GATED like any other
## checkout of it — and when it cannot be, the publication boundary refuses.
##
## THE DEFECT
##
## `git-hooks.nix`'s upstream installer, which this repository's dev shell runs
## on every entry, finishes by writing
##
##     git config --local core.hooksPath "$common_dir/hooks"
##
## with `common_dir` deliberately relativised against the worktree it ran in —
## so the stored value is the string `.git/hooks`. Measured on `dev`:
## `git config --local --get core.hooksPath` → `.git/hooks`.
##
## Three facts about that value, each measured rather than recalled:
##
##   1. `core.hooksPath` lives in `.git/config`, which is the COMMON git
##      directory's config — one value shared by the main worktree and every
##      linked worktree of the repo. (`git config --local` run from inside a
##      linked worktree writes into the main repo's `.git/config`.)
##   2. Git resolves a RELATIVE `core.hooksPath` against the top level of
##      whichever worktree is running the hook — not against the git common
##      dir, and not against the process's cwd. (Committing from a
##      subdirectory still found `<toplevel>/.git/hooks`.)
##   3. In a linked worktree `<toplevel>/.git` is a **file**, not a directory.
##      So `<toplevel>/.git/hooks` names nothing, Git finds no hooks directory,
##      and it runs **no hooks at all**.
##
## Put together: a `git worktree add` in a repository carrying that config
## silently un-gates the worktree. A commit there fires neither the managed
## `pre-commit` nor the managed `post-commit`, exits 0, publishes nothing, and
## says nothing. A push there runs no publication gate. It is the same complete
## bypass `--no-verify` is deliberately designed to make loud, reached with no
## flag at all.
##
## Reprobuild already noticed and carried on. `git worktree add` in the
## repository printed, from the self-heal inside the main worktree's hook:
##
##     repro hooks: could NOT repair post-merge in <worktree>: Failed to create
##     '<worktree>/.git/'
##
## — it tried to `mkdir` a path that is a file, warned, and installed nothing.
## `CLI/hooks.md` § "Contract Handshake And Stand-Down" is explicit that "I
## cannot tell" is not "nothing is happening": when the probe cannot answer the
## hook is inert **and says so**. Falling through to *not* acting, silently, is
## that same error inverted.
##
## WHAT IS ASSERTED
##
##   1. With `core.hooksPath` set exactly the way the dev shell sets it, a real
##      `git commit` in a real linked worktree runs the managed hook bundle;
##   2. a real `git push` from that worktree reaches the publication gate;
##   3. when the hook path cannot be made worktree-safe, the publication
##      boundary REFUSES and names the value, the consequence and the remedy —
##      it does not publish past a gate it knows is not in force.
##
## HOW A VACUOUS GREEN IS AVOIDED
##
## "The hook ran" is asserted through a user hook the installer PRESERVES and
## CHAINS: `ensure` moves a pre-existing `post-commit` to
## `post-commit.repro-local` and the dispatcher runs it first. Its marker file
## therefore proves that **git found the hooks directory and ran the
## dispatcher** — the exact thing the defect prevents — without depending on
## anything the managed body computes. The managed body's own evidence
## (`post-commit-lock.log` under the workspace's disposable report tree) is
## asserted beside it, so a dispatcher that ran but dispatched nothing also
## fails.
##
## Every case also asserts the negative control that makes the topology real:
## `<worktree>/.git` exists and is a FILE, not a directory. A fixture in which
## it were a directory would pass for reasons unrelated to the defect.
##
## BINARY PROVENANCE
##
## The managed hook body resolves `$REPROBUILD_REPRO` else `command -v repro`.
## A fixture that sets neither runs whatever `repro` the dev shell pins — a
## store build that is NOT the binary under test — and that has already
## produced both a false green and a false red in this area. (Measured while
## writing this file: with the dev shell's `repro` on PATH the fall-through
## self-healed the hook set to a DIFFERENT build's bodies, printing
## `refreshed-drifted` for all five.)
##
## So `REPROBUILD_REPRO` is anchored to the engine-built `build/bin/repro`, and
## a TRAP is prepended to PATH: a `repro` that records the call and exits 97.
## Deleting the pinned binary's directory from PATH is not an option here — on
## this machine it is also the directory that supplies `git` — and a trap is
## the better instrument anyway: it turns a fall-through into a loud failure
## AND leaves evidence. Every case asserts the trap was never reached.
##
## TEST DOUBLES: none. Real `git init --bare` origins over `file://`, real
## clones, a real `git worktree add`, the engine-built `build/bin/repro`, the
## real `repro hooks ensure --vcs` installer and git's own hook invocations.
## The two user hooks this file writes are its own subject rather than stand-ins
## for anything: a project's own `post-commit` / `pre-push` script is exactly
## what `ensure` preserves and chains, and the dispatcher cannot tell the
## difference.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  Fixture = object
    scratch, workspace, app, worktree, origin, cacheHome, gitBin, marks,
      trapBin: string

proc trapMarkerPath(fx: Fixture): string = fx.marks / "path-repro-trap.used"

proc installPathReproTrap(fx: Fixture) =
  ## The `repro` that answers a PATH fall-through here. It cannot service a
  ## hook and does not try: it records that it was reached and fails.
  createDir(fx.trapBin)
  let path = fx.trapBin / addFileExt("repro", ExeExt)
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "echo \"$*\" >> " & q(trapMarkerPath(fx)) & "\n" &
    "echo 'FIXTURE TRAP: a PATH repro was resolved; this case anchors " &
    "REPROBUILD_REPRO' >&2\n" &
    "exit 97\n")
  var perms = getFilePermissions(path)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, perms)

proc trapWasUsed(fx: Fixture): bool = fileExists(trapMarkerPath(fx))

proc sh(fx: Fixture; command: string): tuple[code: int; output: string] =
  ## Run a command with the engine-built `repro` ANCHORED on
  ## `REPROBUILD_REPRO` and the trap shadowing every `repro` on PATH.
  let prefixed = "PATH=" & q(fx.trapBin) & ":$PATH " &
    "XDG_CACHE_HOME=" & q(fx.cacheHome) & " " &
    "REPROBUILD_REPRO=" & q(reproBinary()) & " " & command
  let res = execCmdEx(prefixed, options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc git(fx: Fixture; args: string; cwd = ""): tuple[code: int; output: string] =
  let dir = if cwd.len > 0: cwd else: fx.app
  fx.sh(q(fx.gitBin) & " -C " & q(dir) & " " & args)

proc requireGit(fx: Fixture; args: string; cwd = ""): string =
  let res = fx.git(args, cwd)
  if res.code != 0:
    checkpoint("git " & args & " failed: exit=" & $res.code & "\n" & res.output)
    fail()
  res.output

proc markerPath(fx: Fixture; hook: string): string =
  fx.marks / (hook & ".ran")

proc markerRuns(fx: Fixture; hook: string): int =
  let path = markerPath(fx, hook)
  if not fileExists(path): return 0
  for line in readFile(path).splitLines():
    if line.strip().len > 0: inc result

proc writeUserHook(fx: Fixture; hook: string) =
  ## A project's own hook, installed BEFORE `ensure` so the installer preserves
  ## it as `<hook>.repro-local` and the dispatcher chains it. Its marker is the
  ## positive control: it can only gain a line if git found the hooks directory
  ## and ran the dispatcher there.
  let dir = fx.app / ".git" / "hooks"
  createDir(dir)
  let path = dir / hook
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "echo \"$(pwd)\" >> " & q(markerPath(fx, hook)) & "\n" &
    "exit 0\n")
  var perms = getFilePermissions(path)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, perms)

proc postCommitLog(fx: Fixture): string =
  let path = fx.workspace / ".repro" / "build" / "reports" /
    "post-commit-lock.log"
  if fileExists(path): readFile(path) else: ""

proc setup(gitBin: string): Fixture =
  ## A workspace with one declared participating repo, plus the relative
  ## `core.hooksPath` the dev shell's `git-hooks.nix` installer writes.
  result.gitBin = gitBin
  result.scratch = createTempDir("repro-worktree-gate-", "")
  result.workspace = result.scratch / "workspace"
  result.app = result.workspace / "app"
  result.worktree = result.workspace / "app-wt"
  result.origin = result.scratch / "origin.git"
  result.cacheHome = result.scratch / "cache"
  result.marks = result.scratch / "marks"
  result.trapBin = result.scratch / "trap-bin"
  createDir(result.workspace)
  createDir(result.cacheHome)
  createDir(result.marks)
  createDir(result.workspace / ".repro" / "workspace")
  installPathReproTrap(result)

  let fx = result
  discard fx.sh(q(gitBin) & " init --quiet --bare -b main " & q(fx.origin))

  let seed = fx.scratch / "seed"
  discard fx.sh(q(gitBin) & " init --quiet -b main " & q(seed))
  discard fx.requireGit("config user.email t@example.invalid", seed)
  discard fx.requireGit("config user.name Tester", seed)
  writeFile(seed / "README.md", "seed\n")
  discard fx.requireGit("add -A", seed)
  discard fx.requireGit("commit --quiet -m seed", seed)
  discard fx.requireGit("remote add origin " & q(fileUrl(fx.origin)), seed)
  discard fx.requireGit("push --quiet --no-verify origin main", seed)

  discard fx.sh(q(gitBin) & " clone --quiet " & q(fileUrl(fx.origin)) & " " &
    q(fx.app))
  discard fx.requireGit("config user.email t@example.invalid")
  discard fx.requireGit("config user.name Tester")

  # THE FIELD CONDITION, spelled exactly as `git-hooks.nix` spells it. This one
  # line is the whole defect: it is stored in the shared `.git/config` and it
  # is relative.
  discard fx.requireGit("config --local core.hooksPath " & q(".git/hooks"))

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

proc requireHooks(fx: Fixture) =
  let ensured = fx.installHooks()
  checkpoint("hooks ensure (exit " & $ensured.code & "):\n" & ensured.output)
  if ensured.code != 0:
    fail()

proc addWorktree(fx: Fixture) =
  discard fx.requireGit("worktree add --quiet " & q(fx.worktree) & " -b wt")

proc effectiveHooksPath(fx: Fixture; cwd = ""): string =
  let res = fx.git("config --get core.hooksPath", cwd)
  if res.code != 0: "" else: res.output.strip()

suite "managed hooks gate every worktree of a participating repo":

  test "t_a_commit_in_a_linked_worktree_runs_the_managed_hooks":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real repositories and a real " &
        "`git worktree add`")
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)

      fx.writeUserHook("post-commit")
      fx.requireHooks()
      check fileExists(fx.app / ".git" / "hooks" / "post-commit")
      check fileExists(fx.app / ".git" / "hooks" / "post-commit.repro-local")

      fx.addWorktree()
      # NEGATIVE CONTROL for the topology: a linked worktree's `.git` is a
      # FILE. A fixture where it were a directory would gate for reasons that
      # have nothing to do with this defect.
      check fileExists(fx.worktree / ".git")
      check not dirExists(fx.worktree / ".git")
      check not dirExists(fx.worktree / ".git" / "hooks")

      let runsBefore = fx.markerRuns("post-commit")
      writeFile(fx.worktree / "in-worktree.txt", "one\n")
      discard fx.requireGit("add -A", fx.worktree)
      let committed = fx.git("commit --quiet -m " & q("worktree commit"),
        fx.worktree)
      checkpoint("worktree commit output:\n" & committed.output)
      checkpoint("core.hooksPath after ensure: " & fx.effectiveHooksPath())
      check committed.code == 0

      # THE DEFECT. Git ran the hooks directory the repo's config names, so the
      # preserved project hook ran and the managed body dispatched.
      checkpoint("post-commit marker:\n" &
        (if fileExists(fx.markerPath("post-commit")):
           readFile(fx.markerPath("post-commit")) else: "<absent>"))
      check fx.markerRuns("post-commit") == runsBefore + 1
      checkpoint("post-commit log:\n" & fx.postCommitLog())
      check fx.postCommitLog().len > 0

      # ...and the commit really happened, so the case cannot pass by virtue
      # of nothing having been committed.
      check fx.requireGit("log --oneline -1", fx.worktree).contains(
        "worktree commit")

      # PROVENANCE. Nothing fell through to a `repro` on PATH, so every
      # assertion above is about the binary this case built its hooks from.
      checkpoint("PATH repro trap:\n" &
        (if fx.trapWasUsed(): readFile(trapMarkerPath(fx)) else: "<unused>"))
      check not fx.trapWasUsed()

  test "t_a_push_from_a_linked_worktree_reaches_the_publication_gate":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real repositories and a real " &
        "`git worktree add`")
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)

      fx.writeUserHook("pre-push")
      fx.requireHooks()
      check fileExists(fx.app / ".git" / "hooks" / "pre-push.repro-local")

      fx.addWorktree()
      check fileExists(fx.worktree / ".git")
      check not dirExists(fx.worktree / ".git")

      writeFile(fx.worktree / "in-worktree.txt", "one\n")
      discard fx.requireGit("add -A", fx.worktree)
      discard fx.requireGit("commit --quiet -m " & q("worktree commit"),
        fx.worktree)

      let runsBefore = fx.markerRuns("pre-push")
      let pushed = fx.git("push origin wt", fx.worktree)
      checkpoint("worktree push output:\n" & pushed.output)

      # The chained project hook proves git found the hooks directory for a
      # PUSH from the linked worktree, which is the boundary the gate sits on.
      check fx.markerRuns("pre-push") == runsBefore + 1
      # ...and the managed pre-push body spoke: it either refused the push or
      # passed it, but it was consulted. A gate that never ran says nothing at
      # all, which is what this case exists to rule out. Both lines are
      # asserted because the gate's verdict and the gate's PROVENANCE are
      # different claims, and "repro" on its own also matches the fixture's own
      # `file:///tmp/repro-worktree-gate-.../origin.git` in git's push summary.
      check pushed.output.contains("repro check: mode=pre-push")
      check pushed.output.contains("resolved from REPROBUILD_REPRO")
      check not fx.trapWasUsed()

  test "t_publication_refuses_when_the_hook_path_cannot_be_made_worktree_safe":
    ## THE STAND-DOWN. `CLI/hooks.md` § "Contract Handshake And Stand-Down":
    ## when the probe cannot answer, the hook is inert AND SAYS SO rather than
    ## falling through to acting. A gate that cannot be installed in every
    ## worktree of the repo it guards is that rule inverted — it falls through
    ## to NOT acting — so the publication boundary must refuse, not proceed.
    ##
    ## The unrepairable state is staged by making the shared `.git` directory
    ## read-only: Git rewrites `config` through a `config.lock` beside it, so
    ## the value cannot be changed while the directory cannot be written. It is
    ## staged AFTER the commit under test, because an index write needs that
    ## same directory.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real repositories and a real " &
        "`git worktree add`")
    else:
      let fx = setup(gitBin)
      defer: removeDirEventually(fx.scratch)

      fx.requireHooks()
      fx.addWorktree()

      writeFile(fx.app / "on-main.txt", "one\n")
      discard fx.requireGit("add -A")
      discard fx.requireGit("commit --quiet -m " & q("main commit"))

      # Put the relative value back, then take away the ability to change it.
      # The MAIN worktree still resolves `.git/hooks`, so the gate DOES run
      # here — and it must refuse rather than publish while every linked
      # worktree of this repo is ungated and cannot be gated.
      discard fx.requireGit("config --local core.hooksPath " & q(".git/hooks"))
      let gitDir = fx.app / ".git"
      setFilePermissions(gitDir, {fpUserRead, fpUserExec, fpGroupRead,
        fpGroupExec, fpOthersRead, fpOthersExec})
      defer: setFilePermissions(gitDir, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

      let probe = fx.git("config --local core.hooksPath " & q("probe/hooks"))
      if probe.code == 0:
        # A user who can write through a read-only directory (root). The
        # condition under test cannot be staged here; say so rather than pass.
        skip("this user can write into a read-only .git (root?), so a " &
          "core.hooksPath that cannot be repaired cannot be staged here")
      else:
        let pushed = fx.git("push origin main")
        checkpoint("push output:\n" & pushed.output)
        check pushed.code != 0
        check pushed.output.contains("refusing to publish")
        check pushed.output.contains("core.hooksPath")
        check pushed.output.contains("linked worktree")
        # The refusal hands over a command. An operator who cannot act on a
        # refusal reaches for `--no-verify`, which also disables the gates that
        # were working.
        check pushed.output.contains("config --local core.hooksPath")
        check not fx.trapWasUsed()
