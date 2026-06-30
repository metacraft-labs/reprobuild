## Workspace-Manifest-Optional MO-7 — the full workspace pipeline operates
## for a NESTED (non-star) topology with NO org-root workspace repo.
##
## The campaign's exit shape: a SINGLE project repo with its develop-mode
## dependency NESTED under it (``./deps/<dep>``) and a committed
## ``repro.lock`` (MO-1) is a complete, **manifest-free**, **star-free**
## workspace. The org-root ``<org>/repro-workspace`` repo (RA-31) and a
## sibling/star arrangement around it are OPTIONAL, not required
## (Workspace-And-Develop-Mode.md §"Checkout Topologies").
##
## Fixture (built ``./build/bin/repro``, black-box):
##
##   <ws>/                         a git repo, the workspace itself
##     repro.nim                   ``package nestedhost:`` + one aggregate
##     repro.solver                solvable variant+package graph (MO-1)
##     repro.lock                  the committed solved-graph lock (MO-1)
##     deps/nesteddep/             a NESTED develop-mode dep — its OWN git repo
##       repro.nim                 ``projectExtension nestedext, nestedhost:``
##   (NO `.repo/manifests`, NO `.repo/workspace.toml`, NO `<org>/repro-workspace`)
##
## Asserts the pipeline operates WITHOUT the star/org-root layout:
##
##   1. The workspace is RECOGNIZED via the committed lock (MO-2 marker) —
##      ``repro workspace sync --dry-run`` operates and its plan folds the
##      NESTED dep into the participating set (``[update] deps/nesteddep``),
##      alongside the workspace repo itself (``[update] .``) — neither raising
##      "no manifest"/"requires <project>" nor "not a workspace".
##   2. ``repro check --mode=pre-push`` operates (validates the committed
##      lock — the MO-1 advisory "committed solved-graph lock OK") and PASSES
##      (exit 0) on the clean+published nested workspace; it does not no-op as
##      "not a workspace" nor demand an org-root repo.
##   3. ``repro build <ws> --print-solved-graph`` consumes the COMMITTED LOCK
##      (``# source: lock``) — the build operates in the no-org-root workspace.
##   4. ``repro build <ws> --list-targets --json`` consumes the NESTED dep:
##      the nested ``projectExtension``'s ``nestedext-aggregate`` is folded
##      into ``nestedhost``'s graph alongside the base ``host-aggregate`` —
##      the nested dep is treated as a develop-mode participant by presence.
##   5. The nested dep is in the GATE's enforcement scope: dirtying it makes
##      ``repro check`` REFUSE (exit 2) naming the nested dep with property
##      ``dirty`` — proving the nested dep participates in the gate, not just
##      the workspace repo.
##   6. NO org-root repo is needed: the workspace dir carries no
##      ``repro-workspace`` directory and no ``.repo`` at all.
##
## Falsifiability: each assertion FAILS if a star/org-root requirement is
## reintroduced or the nested-topology handling is removed. If the committed-
## lock-derived set stopped folding nested deps (MO-7 fix reverted), (1)'s
## ``deps/nesteddep`` plan line and (5)'s dirty-refusal both vanish; if the
## build's projectExtension discovery stopped scanning the nested dirs, (4)'s
## ``nestedext-aggregate`` disappears; if the MO-2 fallback were removed, (1)
## raises "requires <project>" and (2) prints "not a workspace".
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME
## or any shared cache. Skip rule: ``git`` missing on PATH, or repro unbuilt.

import std/[json, os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

const hostRecipe = """
import repro_project_dsl

package nestedhost:
  build:
    discard aggregate("host-aggregate", actions = @[])
"""

const nestedExtensionRecipe = """
import repro_project_dsl

projectExtension nestedext, nestedhost:
  build:
    discard aggregate("nestedext-aggregate", actions = @[])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo: string; rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initPublishedRepo(gitBin, scratch, name: string): tuple[origin, work: string] =
  ## A bare origin + a clone seeded with one published commit, so the clone's
  ## HEAD is clean and published (origin/main tracking).
  let origin = scratch / (name & ".git")
  let work = scratch / name
  check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
  check run(q(gitBin) & " clone " & q(origin) & " " & q(work)).code == 0
  check git(gitBin, work, "config user.email t@example.invalid").code == 0
  check git(gitBin, work, "config user.name Tester").code == 0
  (origin: origin, work: work)

proc listTargetNames(projectDir: string):
    tuple[names: seq[string]; rc: int; output: string] =
  putEnv("REPROBUILD_NO_RUNQUOTA", "1")
  let (output, rc) = execCmdEx(reproBinary & " build " & q(projectDir) &
    " --list-targets --json --tool-provisioning=path --no-runquota")
  var names: seq[string] = @[]
  let firstBrace = output.find('{')
  let lastBrace = output.rfind('}')
  if rc == 0 and firstBrace >= 0 and lastBrace > firstBrace:
    try:
      let node = parseJson(output[firstBrace .. lastBrace])
      let targets = node{"targets"}
      if not targets.isNil and targets.kind == JArray:
        for entry in targets:
          names.add(entry{"name"}.getStr())
    except CatchableError:
      discard
  (names: names, rc: rc, output: output)

suite "MO-7: nested-topology full pipeline without an org-root repo":

  test "t_nested_topology_full_pipeline_without_org_root_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo7-nested-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- The workspace IS a single project repo (no org-root repo). ----
      let host = initPublishedRepo(gitBin, scratch, "work")
      let repo = host.work
      writeFile(repo / "repro.nim", hostRecipe)
      writeFile(repo / "repro.solver", solverInputs)
      # `deps/` carries the nested dep's own git checkout; gitignore it (and
      # the `.repro/` work/report tree the CLI writes) so the workspace tree
      # stays clean and the nested repo is a nested checkout, not tracked
      # content.
      writeFile(repo / ".gitignore", "/deps/\n.repro/\n")

      # Commit the base tree FIRST, then refresh the lock. `lock refresh`
      # records a stable VCS-native (`git-sha`) integrity over the COMMITTED
      # tree once HEAD exists. Refreshing on a still-uncommitted repo (no
      # HEAD) instead records a transient pre-commit `blake3:` NAR tree hash
      # (computeDepIntegrity's headSha-empty branch); any later edit to the
      # working tree — adding `.gitignore`, the nested `deps/` checkout, or
      # committing `repro.lock` — then changes the recomputed tree hash and
      # the MO-13 `check` integrity verification fails with
      # `locked-integrity-mismatch`. Committing before refreshing keeps the
      # integrity pinned to a stable object id.
      check git(gitBin, repo,
        "add repro.nim repro.solver .gitignore").code == 0
      check git(gitBin, repo, "commit -m host-base").code == 0
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      check fileExists(repo / "repro.lock")

      # ---- A NESTED develop-mode dependency under `./deps/<dep>`: its own
      # git repo carrying a projectExtension recipe extending `nestedhost`. ----
      createDir(repo / "deps")
      let dep = initPublishedRepo(gitBin, repo / "deps", "nesteddep")
      let nestedDir = dep.work
      writeFile(nestedDir / "repro.nim", nestedExtensionRecipe)
      check git(gitBin, nestedDir, "add repro.nim").code == 0
      check git(gitBin, nestedDir, "commit -m nested-ext").code == 0
      check git(gitBin, nestedDir, "push origin main").code == 0

      # Commit + publish the refreshed lock.
      check git(gitBin, repo, "add repro.lock").code == 0
      check git(gitBin, repo, "commit -m host-lock").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      # Sanity: genuinely manifest-less AND star-free — no `.repo`, and the
      # workspace carries no org-root `repro-workspace` repo of any kind.
      check not dirExists(repo / ".repo")
      check not dirExists(repo / "repro-workspace")
      check not dirExists(scratch / "repro-workspace")

      # ---- (1) sync --dry-run folds the nested dep into the participating set.
      let sync = run(reproBinary & " workspace sync --workspace-root=" & repo &
        " --dry-run")
      check sync.code == 0
      check "[update] ." in sync.output            # the workspace repo itself
      check "[update] deps/nesteddep" in sync.output  # the NESTED dep, folded in
      check "requires" notin sync.output
      check "no project or variant" notin sync.output
      check "not a workspace" notin sync.output

      # ---- (2) check --mode=pre-push operates + passes on the clean tree.
      let refs = scratch / "refs.txt"
      let headSha = git(gitBin, repo, "rev-parse HEAD").output.strip()
      let zero = "0000000000000000000000000000000000000000"
      writeFile(refs, "refs/heads/main " & headSha & " refs/heads/main " &
        zero & "\n")
      let chk = run(reproBinary & " check --mode=pre-push --workspace-root=" &
        repo & " --pushed-refs=" & refs)
      check chk.code == 0
      check "committed solved-graph lock OK" in chk.output
      check "not a workspace" notin chk.output
      check "repro-workspace" notin chk.output

      # ---- (3) the nested dep is in the GATE's enforcement scope. Dirtying it
      # REFUSES the push (exit 2) naming the nested dep — this only happens if
      # the nested dep was folded into the committed-lock-derived participating
      # set (the MO-7 fix). Done BEFORE the build steps, which write `.repro/`
      # work artifacts into the (gitignored, so still clean) base tree.
      writeFile(nestedDir / "scratch.txt", "uncommitted\n")
      let dirtyChk = run(reproBinary &
        " check --mode=pre-push --workspace-root=" & repo &
        " --pushed-refs=" & refs)
      check dirtyChk.code == 2
      let reportPath = repo / ".repro" / "workspace" / "check-report.json"
      check fileExists(reportPath)
      let report = parseJson(readFile(reportPath))
      # The gate reports the offending repo by its workspace-relative PATH
      # (``deps/nesteddep``) — that path only appears in the participating set
      # because the nested dep was folded into the committed-lock-derived
      # workspace.
      var sawNestedDirty = false
      for failure in report{"failures"}:
        if failure{"property"}.getStr() == "dirty" and
            failure{"repo"}.getStr() == "deps/nesteddep":
          sawNestedDirty = true
      check sawNestedDirty
      removeFile(nestedDir / "scratch.txt")   # revert the induced dirt

      # ---- (4) build consumes the committed lock (no org-root needed).
      let graph = run(reproBinary & " build " & q(repo) & " --print-solved-graph")
      check graph.code == 0
      check "# source: lock" in graph.output

      # ---- (5) build consumes the NESTED dep: its projectExtension target is
      # folded into the host project's graph by presence alone.
      let targets = listTargetNames(repo)
      checkpoint("list-targets exit=" & $targets.rc)
      checkpoint(targets.output)
      check targets.rc == 0
      check "host-aggregate" in targets.names           # base graph intact
      check "nestedext-aggregate" in targets.names      # nested dep contributes
