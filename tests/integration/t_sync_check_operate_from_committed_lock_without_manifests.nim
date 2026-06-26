## Workspace-Manifest-Optional MO-2 — sync / check operate from the
## committed lock WITHOUT any manifest repo.
##
## A workspace whose dependencies are all public needs no manifest repo:
## the committed ``repro.lock`` (MO-1) + repo-local state are enough to
## resolve the participating repo set + locked revisions. This suite drives
## a built ``./build/bin/repro`` against a single git repo that carries a
## committed ``repro.lock`` (refreshed from a ``repro.solver`` sidecar) but
## has NO ``.repo/manifests`` and NO ``.repo/workspace.toml``. It asserts:
##
##   1. ``repro workspace sync --dry-run`` OPERATES — it resolves the
##      committed-lock-derived participating set (the repo itself) and
##      announces a plan, rather than raising "requires `.repo/workspace.toml`
##      or a <project> argument". Before MO-2 the resolver raised and the
##      command exited non-zero.
##   2. The top-level ``repro sync --dry-run`` shortcut behaves the same.
##   3. ``repro check --mode=pre-push`` OPERATES — it does NOT no-op as
##      "not a workspace" (the committed lock is a workspace marker) and it
##      runs the real gate against the committed-lock-derived repo set,
##      validating the committed lock (the MO-1 advisory prints
##      "committed solved-graph lock OK"). The gate passes (exit 0) because
##      the repo is clean + published. Before MO-2 the check no-op'd as
##      "not a workspace".
##
## Falsifiability: revert the committed-lock-derived fallback in
## ``resolveWorkspaceSyncProject`` and the marker extension in
## ``isInitializedWorkspace`` and (1) exits non-zero with the
## "requires ... <project>" error, while (3) prints "not a workspace" and
## never reaches the "committed solved-graph lock OK" advisory — both sets
## of checks then fail.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches
## ``$HOME`` or any shared cache. Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo: string; rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

suite "MO-2: sync/check operate from the committed lock without manifests":

  test "t_sync_check_operate_from_committed_lock_without_manifests":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo2-nomanifest-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- A bare origin + a clone that becomes the committed-lock-only
      # workspace repo. No `.repo/` of any kind is ever created. ----
      let origin = scratch / "origin.git"
      let repo = scratch / "work"
      check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
      # Seed the origin with one commit so the clone has a published base.
      let seed = scratch / "seed"
      check git(gitBin, "", "init -b main " & q(seed)).code == 0
      check git(gitBin, seed, "config user.email t@example.invalid").code == 0
      check git(gitBin, seed, "config user.name Tester").code == 0
      writeFile(seed / "README.md", "mo2 fixture\n")
      check git(gitBin, seed, "add README.md").code == 0
      check git(gitBin, seed, "commit -m seed").code == 0
      check git(gitBin, seed, "remote add origin " & q(origin)).code == 0
      check git(gitBin, seed, "push origin main").code == 0
      # Clone — this gives the work repo a real origin/main tracking ref.
      check run(q(gitBin) & " clone " & q(origin) & " " & q(repo)).code == 0
      check git(gitBin, repo, "config user.email t@example.invalid").code == 0
      check git(gitBin, repo, "config user.name Tester").code == 0

      # ---- Establish the committed-lock reproducibility boundary: write a
      # solver sidecar, refresh the committed lock, then commit + push so the
      # tree is clean and HEAD is published. ----
      writeFile(repo / "repro.solver", solverInputs)
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      check fileExists(repo / "repro.lock")
      check git(gitBin, repo, "add repro.solver repro.lock").code == 0
      check git(gitBin, repo, "commit -m lock").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      # Sanity: this is genuinely manifest-less.
      check not dirExists(repo / ".repo")

      # ---- (1) `repro workspace sync --dry-run` operates from the lock. ----
      let sync = run(reproBinary & " workspace sync --workspace-root=" &
        repo & " --dry-run")
      check sync.code == 0
      # The plan names the committed-lock-derived participating repo (the
      # repo itself, path ".") rather than raising a no-manifest error.
      check "work" in sync.output            # the repo name (basename)
      check "[update] ." in sync.output      # the single planned repo
      check "requires" notin sync.output     # NOT the missing-manifest error
      check "no project or variant" notin sync.output
      check "not a workspace" notin sync.output

      # ---- (2) top-level `repro sync --dry-run` shortcut behaves the same. ----
      let topSync = run(reproBinary & " sync --workspace-root=" & repo &
        " --dry-run")
      check topSync.code == 0
      check "[update] ." in topSync.output

      # ---- (3) `repro check --mode=pre-push` operates (not a no-op). ----
      let refs = scratch / "refs.txt"
      let head = git(gitBin, repo, "rev-parse HEAD").output.strip()
      let zero = "0000000000000000000000000000000000000000"
      writeFile(refs, "refs/heads/main " & head & " refs/heads/main " &
        zero & "\n")
      let chk = run(reproBinary & " check --mode=pre-push --workspace-root=" &
        repo & " --pushed-refs=" & refs)
      check chk.code == 0
      # The committed-lock-aware gate RAN: it validated the committed lock
      # (MO-1 advisory) and did NOT no-op as "not a workspace".
      check "committed solved-graph lock OK" in chk.output
      check "not a workspace" notin chk.output
