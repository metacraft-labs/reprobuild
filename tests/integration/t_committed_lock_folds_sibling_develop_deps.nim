## Workspace-Manifest-Optional MO-12, as amended 2026-11-16 — a SIBLING
## develop override (the RA-22 develop-override set, one level up) is a
## workspace MEMBER of a committed-lock-only workspace, but it is not a
## dependency: `repro lock refresh` does not record it, and the pre-push gate of
## the pushed repo does not check it, unless it substitutes a dependency the
## recipe derives.
##
## Spec: Unified-Locking-And-Hooks.md §14.2 item 2 ("an override contributes
## only when it substitutes a dependency items 1 and 3 derive");
## Workspace-And-Develop-Mode.md §"Which develop overrides the push gate
## checks". Issue: reprobuild-pm `issues/2026-11-16-the-pre-push-gate-refuses-
## over-develop-overrides-outside-the-pushed-repo-closure.md` — before the fix
## every override was written into the committed lock and became a root
## `depends` edge, so an override made for an unrelated repo was a closure
## member and blocked the push whatever stage 3 did.
##
## Fixture (built ``./build/bin/repro``, black-box):
##
##   <scratch>/
##     work/                       the workspace repo (committed lock, no manifest)
##       repro.solver              the solver inputs the lock pins (no `uses:`)
##       repro.lock                the committed solved-graph lock (refreshed)
##       .repro/develop-overrides.toml   RA-22 override: package "sib" -> "../sib"
##     sib/                        a SIBLING develop-mode checkout — its OWN git
##       repro.nim                 repo, a reprobuild project nothing uses
##   (NO root `projects/`, NO `.repro/workspace.toml`, NO org-root repo)
##
## Asserts:
##   1. After ``repro lock refresh``, the committed lock does NOT carry the
##      sibling: no ``sib`` entry, and the root has no ``depends`` edge onto it.
##   2. ``repro workspace sync --dry-run`` still folds the sibling into the plan
##      (``[update] ../sib`` alongside ``[update] .``): it is a member.
##   3. ``repro check --mode=pre-push`` PASSES (exit 0) on the clean tree.
##   4. Dirtying the sibling and giving it an unpublished commit does NOT block
##      the push of the workspace repo (``--current-repo`` names it, as the
##      managed hook does): the sibling is outside its closure.
##   5. Without a pushed repo the gate falls back to the whole workspace and
##      still refuses the dirty sibling, so (4) passes for the closure rule and
##      not because the sibling went unobserved.
##
## Falsifiability: with the pre-fix fold (``lockedDepsForWorkspace`` recording
## every override, ``committedLockDerivedProject`` adding a root edge onto it),
## (1) finds ``sib`` in the lock and (4) refuses with ``dirty`` on ``../sib``.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` missing on PATH, or repro unbuilt.

import std/[json, os, osproc, strutils, unittest]

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory.
  ##
  ## The previous spelling (``"./build/bin/" & addFileExt("repro", ExeExt)``)
  ## made the working directory an unstated fixture input: from the repo root
  ## the case ran, from any other directory ``fileExists`` was false and it
  ## SKIPPED, and from a scratch directory that happened to carry a staged
  ## ``build/bin/repro`` it ran against THAT binary and reported failures that
  ## read as product refusals. ``currentSourcePath()`` is absolute on both
  ## platforms, so this constant is the same from every cwd.
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

const siblingRecipe = """
import repro_project_dsl

package sib:
  build:
    discard aggregate("sib-aggregate", actions = @[])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initPublishedRepo(gitBin, scratch, name: string): tuple[origin, work: string] =
  let origin = scratch / (name & ".git")
  let work = scratch / name
  check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
  check run(q(gitBin) & " clone " & q(origin) & " " & q(work)).code == 0
  check git(gitBin, work, "config user.email t@example.invalid").code == 0
  check git(gitBin, work, "config user.name Tester").code == 0
  (origin: origin, work: work)

suite "MO-12: a sibling develop override is a member, not a dependency":

  test "t_committed_lock_folds_sibling_develop_deps":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo12-sibling-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- A SIBLING develop-mode dep one level up: its own published git
      # repo carrying a reprobuild project recipe (the discovery discriminator).
      let sib = initPublishedRepo(gitBin, scratch, "sib")
      writeFile(sib.work / "repro.nim", siblingRecipe)
      check git(gitBin, sib.work, "add repro.nim").code == 0
      check git(gitBin, sib.work, "commit -m sib").code == 0
      check git(gitBin, sib.work, "push origin main").code == 0

      # ---- The workspace IS a single committed-lock project repo (no manifest).
      let host = initPublishedRepo(gitBin, scratch, "work")
      let repo = host.work
      writeFile(repo / "README.md", "mo12 fixture\n")
      writeFile(repo / "repro.solver", solverInputs)
      check git(gitBin, repo, "add README.md repro.solver").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      # ---- The RA-22 develop-override registering the sibling (one level up).
      createDir(repo / ".repro")
      writeFile(repo / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "sib"
local_path = "../sib"
state = "editable"
created_at = "2026-06-27T00:00:00Z"
""")

      # ---- refresh the lock: the override is not a dependency. ----
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      check fileExists(repo / "repro.lock")
      let lockBody = readFile(repo / "repro.lock")

      # (1) Nothing the recipe derives is substituted by the override, so the
      # lock records neither the sibling nor an edge onto it.
      checkpoint("repro.lock:\n" & lockBody)
      check "name = \"sib\"" notin lockBody
      let sibSha = git(gitBin, sib.work, "rev-parse HEAD").output.strip()
      check sibSha notin lockBody
      check "\"sib\"" notin lockBody and "sib," notin lockBody and
        ",sib" notin lockBody

      # Commit + publish the lock so the workspace tree is clean for the gate.
      writeFile(repo / ".gitignore", ".repro/\n")
      check git(gitBin, repo, "add repro.lock .gitignore").code == 0
      check git(gitBin, repo, "commit -m lock").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      # Sanity: genuinely manifest-less + star-free.
      check not dirExists(repo / ".repro" / "manifests")
      check not dirExists(scratch / "repro-workspace")

      # (2) sync --dry-run still folds the sibling into the participating set.
      let sync = run(reproBinary & " workspace sync --workspace-root=" & repo &
        " --dry-run")
      check sync.code == 0
      check "[update] ." in sync.output            # the workspace repo itself
      check "[update] ../sib" in sync.output       # the SIBLING, a member
      check "not a workspace" notin sync.output
      check "requires" notin sync.output

      # (3) check --mode=pre-push passes on the clean tree.
      let refs = scratch / "refs.txt"
      let headSha = git(gitBin, repo, "rev-parse HEAD").output.strip()
      let zero = "0000000000000000000000000000000000000000"
      writeFile(refs, "refs/heads/main " & headSha & " refs/heads/main " &
        zero & "\n")
      let gate = reproBinary &
        " check --mode=pre-push --write-report --workspace-root=" & repo &
        " --pushed-refs=" & refs
      let chk = run(gate & " --current-repo=" & repo)
      check chk.code == 0
      check "not a workspace" notin chk.output

      # (4) An unpublished commit and uncommitted work in the sibling do not
      # block the push of the workspace repo: the override substitutes nothing
      # in its closure.
      writeFile(sib.work / "work.txt", "unpublished\n")
      check git(gitBin, sib.work, "add work.txt").code == 0
      check git(gitBin, sib.work, "commit -m unpublished").code == 0
      writeFile(sib.work / "scratch.txt", "uncommitted\n")
      let scoped = run(gate & " --current-repo=" & repo)
      checkpoint("scoped gate:\n" & scoped.output)
      check scoped.code == 0
      check "../sib" notin scoped.output
      check "develop_override" notin scoped.output

      # (5) The whole-workspace fallback (no pushed repo) still observes it.
      let whole = run(gate)
      checkpoint("whole-workspace gate:\n" & whole.output)
      check whole.code == 2
      let reportPath = repo / ".repro" / "build" / "reports" / "check-report.json"
      check fileExists(reportPath)
      let report = parseJson(readFile(reportPath))
      var sawSiblingDirty = false
      for failure in report{"failures"}:
        if failure{"property"}.getStr() in ["dirty", "develop_override_dirty"] and
            "sib" in failure{"repo"}.getStr():
          sawSiblingDirty = true
      check sawSiblingDirty
