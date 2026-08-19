## The managed `post-merge` hook reconciles workspace-local git state, so a
## developer who already has the workspace checked out needs no more than
## `git pull`.
##
## This is the trigger half of the migration, and it is the half with the
## strictest constraints. A hook body runs on somebody else's command: it may
## not fail that command, it may not be slow enough to notice, and it may not
## speak unless it has something worth saying. But it also may not act
## silently — rewriting a developer's git remotes without telling them is not
## acceptable merely because it happened inside a hook.
##
## `post-merge` rather than a new hook: it already exists, is already installed
## by `repro hooks ensure --vcs`, and already means "something may have arrived
## from a remote" — which is exactly the event that makes a checkout stale
## against a converted manifest. Bolting a second hook onto the same event
## would double the ways this can be half-installed.
##
## Asserted:
##   1. Dispatching `post-merge` against a stale workspace reconciles it: the
##      prefix-named remote becomes `origin` and the detached HEAD attaches to
##      the declared branch.
##   2. It reports what it changed, per repo, on stderr — the migration is not
##      allowed to be silent about mutating somebody's `.git/config`.
##   3. It exits 0. Git aborts nothing on a non-zero `post-merge`, but the
##      contract is that this can never be the reason a pull looks broken, so
##      the exit code is asserted rather than assumed.
##   4. A second dispatch against the now-consistent workspace is SILENT and
##      still exits 0. A hook that narrates every pull is a hook people learn
##      to ignore.
##   5. A workspace it cannot resolve at all does not turn into a failed
##      `git pull`: exit 0, no crash.
##
## No mocks: real `git init --bare` origins over `file://`, a real clone, and
## the engine-built `build/bin/repro` invoked exactly as the installed hook
## body invokes it. Skipped only when `git` is missing from PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc git(gitBin, args: string): tuple[code: int; output: string] =
  let res = execCmdEx(q(gitBin) & " " & args)
  (code: res.exitCode, output: res.output)

proc requireGit(gitBin, args: string): string =
  let res = git(gitBin, args)
  if res.code != 0:
    checkpoint("git " & args & " failed: exit=" & $res.code & "\n" & res.output)
    fail()
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedBare(gitBin, bareDir, branch, marker: string) =
  let work = bareDir & "-seed"
  createDir(work)
  discard requireGit(gitBin, "init --quiet --initial-branch " & q(branch) &
    " " & q(work))
  writeFile(work / "README.md", marker & "\n")
  discard requireGit(gitBin, "-C " & q(work) & " add .")
  discard requireGit(gitBin, "-C " & q(work) &
    " -c user.email=t@example.invalid -c user.name=t commit --quiet -m " &
    q("seed " & marker))
  discard requireGit(gitBin, "clone --quiet --bare " & q(work) & " " &
    q(bareDir))
  removeDir(work)

proc headBranch(gitBin, checkout: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc remoteNames(gitBin, checkout: string): seq[string] =
  for line in requireGit(gitBin, "-C " & q(checkout) &
      " remote").strip().splitLines():
    let name = line.strip()
    if name.len > 0:
      result.add(name)

proc dispatchPostMerge(repoPath, cacheHome: string): CmdResult =
  ## Exactly the argv the installed managed hook body uses: the hook name, the
  ## repo git was operating in, and git's own positional arg after `--`.
  ## `XDG_CACHE_HOME` is redirected so the hook's log lands in the scratch dir
  ## rather than the developer's real cache.
  runShell(shellCommand(
    @[reproBinary(), "hooks", "dispatch", "post-merge",
      "--repo-root=" & repoPath, "--", "0"],
    @[("XDG_CACHE_HOME", cacheHome)]))

suite "the post-merge hook reconciles workspace-local git state":

  test "t_post_merge_reconciles_then_goes_quiet":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-posthook-migrate-", "")
      defer: removeDirEventually(scratch)
      let cacheHome = scratch / "cache"
      createDir(cacheHome)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBare(gitBin, remotes / "lib-a", "dev", "lib-a")
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      createDir(root / "projects")
      createDir(root / "repos")
      createDir(root / ".repro")
      writeFile(root / "repos" / "lib-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "remote = \"metacraft-labs\"\nbranch = \"dev\"\n")
      writeFile(root / "projects" / "demo.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"demo\"\n\n" &
        "[[remote]]\nname = \"metacraft-labs\"\nfetch = \"" & prefix &
        "\"\n\nincludes = [\"repos/lib-a.toml\"]\n")
      writeFile(root / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\nprojects = [\"demo\"]\n")

      let checkout = root / "lib-a"
      discard requireGit(gitBin, "clone --quiet --origin metacraft-labs " &
        q(prefix & "/lib-a") & " " & q(checkout))
      discard requireGit(gitBin, "-C " & q(checkout) &
        " checkout --quiet --detach HEAD")

      # The hook fires in the participating repo, exactly as git would fire it
      # after a merge landed there.
      let first = dispatchPostMerge(checkout, cacheHome)
      checkpoint("first dispatch: " & first.output)
      check first.code == 0

      check "origin" in remoteNames(gitBin, checkout)
      check "metacraft-labs" notin remoteNames(gitBin, checkout)
      check headBranch(gitBin, checkout) == "dev"

      # It said what it did. Both halves matter: the repo it touched, and the
      # change it made.
      check first.output.contains("lib-a")
      check first.output.contains("renamed to 'origin'")
      check first.output.contains("detached HEAD attached")
      # ...and pointed at the surface that can re-run it.
      check first.output.contains("repro workspace migrate")

      # The same trace is durable, not just a one-shot line on a terminal that
      # has since scrolled.
      let logPath = cacheHome / "repro" / "manifest-refresh.log"
      check fileExists(logPath)
      check readFile(logPath).contains("local-state")

      # Second dispatch on a now-consistent workspace: nothing to say.
      let second = dispatchPostMerge(checkout, cacheHome)
      checkpoint("second dispatch: " & second.output)
      check second.code == 0
      check not second.output.contains("renamed")
      check not second.output.contains("detached HEAD attached")
      check not second.output.contains("reconciled workspace-local")

  test "t_post_merge_never_fails_the_pull_for_an_unresolvable_workspace":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-posthook-unresolvable-", "")
      defer: removeDirEventually(scratch)
      let cacheHome = scratch / "cache"
      createDir(cacheHome)

      # A workspace whose recorded active set names something no manifest
      # carries. Resolution raises; the hook must absorb it.
      let root = scratch / "workspace"
      createDir(root / "projects")
      createDir(root / "repos")
      createDir(root / ".repro")
      writeFile(root / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"gone\"\nprojects = [\"gone\"]\n")
      let checkout = root / "lib-a"
      createDir(checkout)
      discard requireGit(gitBin, "init --quiet --initial-branch dev " &
        q(checkout))

      let res = dispatchPostMerge(checkout, cacheHome)
      checkpoint("dispatch: " & res.output)
      check res.code == 0
