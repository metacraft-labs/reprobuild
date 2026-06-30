## Workspace-Manifest-Optional MO-12 — SIBLING develop-mode deps (the RA-22
## develop-override set, one level up) are folded into the committed-lock-
## derived participating set AND the committed lock's ``deps``, and the
## pre-push gate ENFORCES them — exactly as MO-7 did for NESTED deps.
##
## Fixture (built ``./build/bin/repro``, black-box):
##
##   <scratch>/
##     work/                       the workspace repo (committed lock, no manifest)
##       repro.solver              the solver inputs the lock pins
##       repro.lock                the committed solved-graph lock (refreshed)
##       .repro/develop-overrides.toml   RA-22 override: package "sib" -> "../sib"
##     sib/                        a SIBLING develop-mode dep — its OWN git repo
##       repro.nim                 a reprobuild project (the discovery discriminator)
##   (NO `.repo/manifests`, NO `.repo/workspace.toml`, NO org-root repo)
##
## Asserts:
##   1. After ``repro lock refresh``, the committed lock carries the sibling as
##      a first-class ``deps`` entry: ``path = "../sib"`` with VCS coordinates
##      (``coord_kind = "vcs"`` + a ``revision``) AND a self-describing
##      ``integrity`` multihash — i.e. coordinates+integrity per the MO-8/MO-11
##      model — and the root repo gains a ``depends`` edge onto ``sib``.
##   2. ``repro workspace sync --dry-run`` folds the sibling into the plan
##      (``[update] ../sib`` alongside ``[update] .``) — it is in the
##      participating set, not just the workspace repo.
##   3. ``repro check --mode=pre-push`` PASSES (exit 0) on the clean tree.
##   4. The sibling is in the GATE's enforcement scope: dirtying it makes the
##      gate REFUSE (exit 2) naming ``../sib`` with property ``dirty`` — only
##      possible because the sibling was folded into the participating set.
##
## Falsifiability: if the sibling fold were reverted (``discoverSiblingDevelop
## Deps`` returning empty / ``committedLockDerivedProject`` +
## ``lockedDepsForWorkspace`` not consuming it), (1)'s ``../sib`` dep vanishes
## from the lock, (2)'s ``[update] ../sib`` plan line disappears, and (4) flips
## to exit 0 (the dirty sibling is no longer enforced) — each assertion fails.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` missing on PATH, or repro unbuilt.

import std/[json, os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

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

suite "MO-12: committed lock folds sibling develop deps":

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

      # ---- refresh the lock: it must fold the sibling into `deps`. ----
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      check fileExists(repo / "repro.lock")
      let lockBody = readFile(repo / "repro.lock")

      # (1) The sibling is a first-class locked dep: workspace-relative path,
      # VCS coordinates (kind + revision) + a self-describing integrity.
      check "path = \"../sib\"" in lockBody
      check "coord_kind = \"vcs\"" in lockBody
      # The sibling's locked entry carries the sibling's HEAD as the revision.
      let sibSha = git(gitBin, sib.work, "rev-parse HEAD").output.strip()
      check sibSha in lockBody                       # the sibling revision is pinned
      check "integrity = \"git-" in lockBody         # self-describing integrity
      # The root repo depends on the sibling.
      check "depends = \"sib\"" in lockBody or "depends = \"sib," in lockBody or
            ",sib\"" in lockBody or ",sib," in lockBody

      # Commit + publish the lock so the workspace tree is clean for the gate.
      writeFile(repo / ".gitignore", ".repro/\n")
      check git(gitBin, repo, "add repro.lock .gitignore").code == 0
      check git(gitBin, repo, "commit -m lock").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      # Sanity: genuinely manifest-less + star-free.
      check not dirExists(repo / ".repo")
      check not dirExists(scratch / "repro-workspace")

      # (2) sync --dry-run folds the sibling into the participating set.
      let sync = run(reproBinary & " workspace sync --workspace-root=" & repo &
        " --dry-run")
      check sync.code == 0
      check "[update] ." in sync.output            # the workspace repo itself
      check "[update] ../sib" in sync.output       # the SIBLING dep, folded in
      check "not a workspace" notin sync.output
      check "requires" notin sync.output

      # (3) check --mode=pre-push passes on the clean tree.
      let refs = scratch / "refs.txt"
      let headSha = git(gitBin, repo, "rev-parse HEAD").output.strip()
      let zero = "0000000000000000000000000000000000000000"
      writeFile(refs, "refs/heads/main " & headSha & " refs/heads/main " &
        zero & "\n")
      let chk = run(reproBinary & " check --mode=pre-push --workspace-root=" &
        repo & " --pushed-refs=" & refs)
      check chk.code == 0
      check "not a workspace" notin chk.output

      # (4) the sibling is in the GATE's enforcement scope: dirtying it REFUSES
      # the push (exit 2) naming ``../sib`` — only possible because the sibling
      # was folded into the committed-lock-derived participating set.
      writeFile(sib.work / "scratch.txt", "uncommitted\n")
      let dirtyChk = run(reproBinary &
        " check --mode=pre-push --workspace-root=" & repo &
        " --pushed-refs=" & refs)
      check dirtyChk.code == 2
      let reportPath = repo / ".repro" / "workspace" / "check-report.json"
      check fileExists(reportPath)
      let report = parseJson(readFile(reportPath))
      var sawSiblingDirty = false
      for failure in report{"failures"}:
        if failure{"property"}.getStr() == "dirty" and
            failure{"repo"}.getStr() == "../sib":
          sawSiblingDirty = true
      check sawSiblingDirty
      removeFile(sib.work / "scratch.txt")   # revert the induced dirt
