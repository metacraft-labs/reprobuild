## `repro workspace migrate` never moves a HEAD that carries work existing
## nowhere else — and says exactly why, and what to do about it.
##
## Why this is the important half. Reattaching a detached HEAD is a mechanical
## fix nobody would think twice about, right up until the tree it runs against
## has a half-finished change in it. Then it is data loss delivered by a hook
## the developer did not invoke, on a repo they were not thinking about, as a
## side effect of `git pull`. The whole automatic-migration idea is only
## defensible if the refusal is as reliable as the fix, so the refusal is what
## gets the tests.
##
## The gate is `repoRemovalBlockers` — the same work-loss test `repro
## workspace disable` runs before an `rm -rf`, reused rather than reimplemented
## so the two verbs can never drift into disagreeing about what "work that
## exists nowhere else" means. It is reused with ONE addition, because it has a
## structural blind spot here: its unpushed-commit probe is `rev-list
## --branches --not --remotes`, and a commit made while HEAD is detached
## belongs to no branch, so `--branches` does not cover it. That is precisely
## the commit reattaching would strand in the reflog, so it gets its own probe
## and its own case below.
##
## Asserted:
##   1. A checkout with UNCOMMITTED changes is skipped, not migrated: HEAD
##      stays detached, the working-tree change is still there, the report
##      names the blocker and a remedy, and the exit code is 2.
##   2. A checkout with UNPUSHED commits on a local branch is skipped the same
##      way.
##   3. A checkout whose commits exist ONLY at the detached HEAD is skipped —
##      the case the reused gate cannot see on its own.
##   4. A checkout with a STASH entry is skipped.
##   5. A repo whose HEAD is deferred still has its REMOTES reconciled in the
##      same pass. Renaming a remote cannot lose a commit, so gating it behind
##      the work-loss refusal would strand the workspace half-migrated for as
##      long as somebody has an uncommitted file open. The test asserts the
##      split explicitly: remotes converge, HEAD does not.
##   6. A checkout that is not ours at all — remotes matching no manifest URL,
##      HEAD not at the declared revision — is left completely alone.
##
## No mocks: real `git init --bare` origins over `file://`, real clones with
## real dirty state, and the engine-built `build/bin/repro`. Skipped only when
## `git` is missing from PATH.

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

proc commitIn(gitBin, checkout, file, body, message: string): string =
  writeFile(checkout / file, body)
  discard requireGit(gitBin, "-C " & q(checkout) & " add " & q(file))
  discard requireGit(gitBin, "-C " & q(checkout) &
    " -c user.email=t@example.invalid -c user.name=t commit --quiet -m " &
    q(message))
  requireGit(gitBin, "-C " & q(checkout) & " rev-parse HEAD").strip()

proc headBranch(gitBin, checkout: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc headSha(gitBin, checkout: string): string =
  requireGit(gitBin, "-C " & q(checkout) & " rev-parse HEAD").strip()

proc remoteNames(gitBin, checkout: string): seq[string] =
  for line in requireGit(gitBin, "-C " & q(checkout) &
      " remote").strip().splitLines():
    let name = line.strip()
    if name.len > 0:
      result.add(name)

proc remoteUrl(gitBin, checkout, name: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " remote get-url " & q(name))
  if res.code != 0: "" else: res.output.strip()

proc buildWorkspace(root, prefix: string; names: openArray[string]) =
  createDir(root / "projects")
  createDir(root / "repos")
  createDir(root / ".repro")
  var includes: seq[string]
  for name in names:
    writeFile(root / "repos" / (name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"" & name & "\"\npath = \"" & name & "\"\n" &
      "remote = \"metacraft-labs\"\nbranch = \"dev\"\n")
    includes.add("repos/" & name & ".toml")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"demo\"\n\n" &
    "[[remote]]\nname = \"metacraft-labs\"\nfetch = \"" & prefix & "\"\n\n" &
    "includes = [\n"
  for inc in includes:
    project.add("  \"" & inc & "\",\n")
  project.add("]\n")
  writeFile(root / "projects" / "demo.toml", project)
  writeFile(root / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"demo\"\nprojects = [\"demo\"]\n")

proc migrate(root: string): CmdResult =
  runShell(shellCommand(@[reproBinary(), "workspace", "migrate",
    "--workspace-root=" & root]))

suite "workspace migrate refuses to endanger work that exists nowhere else":

  test "t_migrate_skips_checkouts_carrying_work_and_reports_the_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-migrate-safety-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      const names = ["dirty-lib", "unpushed-lib", "detached-work-lib",
                     "stashed-lib"]
      for name in names:
        seedBare(gitBin, remotes / name, "dev", name)
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      buildWorkspace(root, prefix, names)

      # Every one of the four is cloned with the pre-model remote name AND a
      # detached HEAD, so each has exactly the same migration to do; only the
      # work in the tree differs. That isolates the gate as the variable.
      for name in names:
        discard requireGit(gitBin, "clone --quiet --origin metacraft-labs " &
          q(prefix & "/" & name) & " " & q(root / name))
        discard requireGit(gitBin, "-C " & q(root / name) &
          " checkout --quiet --detach HEAD")

      # (1) uncommitted changes.
      writeFile(root / "dirty-lib" / "README.md", "edited but not committed\n")

      # (2) commits on a local branch that no remote carries. The branch is
      # created off the detached HEAD and left un-checked-out, so the tree is
      # clean and the HEAD is still detached — the blocker is the ONLY
      # difference from a migratable repo.
      discard requireGit(gitBin, "-C " & q(root / "unpushed-lib") &
        " checkout --quiet -b private-work")
      discard commitIn(gitBin, root / "unpushed-lib", "wip.txt", "wip\n",
        "private work")
      discard requireGit(gitBin, "-C " & q(root / "unpushed-lib") &
        " checkout --quiet --detach HEAD")

      # (3) a commit made AT the detached HEAD: on no branch at all, so the
      # reused blocker probe cannot see it.
      let strandedSha = commitIn(gitBin, root / "detached-work-lib",
        "detached.txt", "made while detached\n", "detached work")

      # (4) a stash entry.
      writeFile(root / "stashed-lib" / "README.md", "to be stashed\n")
      discard requireGit(gitBin, "-C " & q(root / "stashed-lib") &
        " -c user.email=t@example.invalid -c user.name=t stash push --quiet")

      var detachedBefore: seq[string]
      for name in names:
        check headBranch(gitBin, root / name) == ""
        detachedBefore.add(headSha(gitBin, root / name))

      let res = migrate(root)
      checkpoint("migrate: " & res.output)

      # Exit 2 — "some checkouts were skipped to protect work" is a distinct
      # outcome from both success and failure, and a caller has to be able to
      # tell them apart without parsing prose.
      check res.code == 2

      for idx, name in names:
        # HEAD did not move: still detached, still at the same commit.
        check headBranch(gitBin, root / name) == ""
        check headSha(gitBin, root / name) == detachedBefore[idx]
        # ...and the report says so, per repo, with a remedy attached.
        check res.output.contains(name & ":")
        check res.output.contains("SKIPPED")
      check res.output.contains("uncommitted change")
      check res.output.contains("unpushed commit")
      check res.output.contains("reachable only from the detached HEAD")
      check res.output.contains("stash entr")
      check res.output.contains("remedy:")

      # The work itself is all still there.
      check readFile(root / "dirty-lib" / "README.md") ==
        "edited but not committed\n"
      check requireGit(gitBin, "-C " & q(root / "unpushed-lib") &
        " rev-parse --verify private-work").strip().len == 40
      check headSha(gitBin, root / "detached-work-lib") == strandedSha
      check requireGit(gitBin, "-C " & q(root / "stashed-lib") &
        " stash list").strip().len > 0

      # The deliberate split: the HEAD was deferred, but the REMOTES were
      # reconciled anyway. Renaming a remote cannot lose a commit, so gating it
      # behind the same refusal would leave a workspace half-migrated for as
      # long as somebody has an uncommitted file open.
      for name in names:
        check "origin" in remoteNames(gitBin, root / name)
        check "metacraft-labs" notin remoteNames(gitBin, root / name)
        check remoteUrl(gitBin, root / name, "origin") ==
          prefix & "/" & name

      # And the refusal is stable: re-running does not wear it down.
      let again = migrate(root)
      check again.code == 2
      for idx, name in names:
        check headBranch(gitBin, root / name) == ""
        check headSha(gitBin, root / name) == detachedBefore[idx]

  test "t_migrate_leaves_a_checkout_it_cannot_recognize_completely_alone":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-migrate-foreign-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBare(gitBin, remotes / "lib-a", "dev", "lib-a")
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      buildWorkspace(root, prefix, ["lib-a"])

      # Somebody else's repository, sitting at the declared path. Its remotes
      # match no manifest URL and its HEAD is at no declared revision, so
      # rewriting them would be re-pointing a stranger's checkout.
      let squatter = root / "lib-a"
      createDir(squatter)
      discard requireGit(gitBin, "init --quiet --initial-branch main " &
        q(squatter))
      discard commitIn(gitBin, squatter, "unrelated.txt", "not ours\n",
        "unrelated")
      discard requireGit(gitBin, "-C " & q(squatter) &
        " remote add origin https://git.example.invalid/somebody-else")
      discard requireGit(gitBin, "-C " & q(squatter) &
        " checkout --quiet --detach HEAD")
      let shaBefore = headSha(gitBin, squatter)

      let res = migrate(root)
      checkpoint("migrate: " & res.output)
      check res.code == 2

      check remoteUrl(gitBin, squatter, "origin") ==
        "https://git.example.invalid/somebody-else"
      check headBranch(gitBin, squatter) == ""
      check headSha(gitBin, squatter) == shaBefore
      check res.output.contains("match no manifest URL")
