## Workspace-Manifest-Optional MO-2 — the "initialized workspace" marker
## accepts a committed-lock-only repo.
##
## ``isInitializedWorkspace`` is the shared predicate the managed hooks and
## the pre-push gate consult to decide whether there is anything to enforce.
## Before MO-2 it recognised ONLY a resolved manifest checkout
## (``.repo/workspace.toml`` or ``.repo/manifests/projects/*.toml``). MO-2
## extends it so a repo carrying a committed ``repro.lock`` (the manifest-
## optional reproducibility artifact) ALSO counts as an initialized
## workspace — otherwise an all-public, single-repo workspace would slip
## past the gate.
##
## We drive the predicate through ``repro check --mode=pre-push``, whose
## no-op decision IS ``isInitializedWorkspace``: when the marker is absent
## the gate prints "not a workspace; nothing to enforce" and no-ops; when it
## is present the gate proceeds and never prints that diagnostic. The suite
## asserts:
##
##   * A repo with a committed ``repro.lock`` and NO ``.repo/`` → marker
##     TRUE: the gate does NOT print "not a workspace".
##   * A bare git repo with NO lock and NO ``.repo/`` → marker FALSE: the
##     gate prints "not a workspace" and no-ops with success.
##
## Falsifiability: revert the committed-lock branch of
## ``isInitializedWorkspace`` and the committed-lock repo ALSO prints
## "not a workspace" — the first assertion then fails. The bare-repo
## assertion guards the other direction (the marker must stay FALSE for a
## genuine non-workspace, so the predicate is not vacuously true).
##
## Hermetic: fresh tempdir per run. Skip rule: ``git`` missing on PATH.

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

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo: string; rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initRepo(gitBin, path: string) =
  removeDir(path)
  doAssert git(gitBin, "", "init -b main " & q(path)).code == 0
  doAssert git(gitBin, path, "config user.email t@example.invalid").code == 0
  doAssert git(gitBin, path, "config user.name Tester").code == 0
  writeFile(path / "README.md", "marker fixture\n")
  doAssert git(gitBin, path, "add README.md").code == 0
  doAssert git(gitBin, path, "commit -m seed").code == 0

proc checkPrePush(repo: string): tuple[code: int; output: string] =
  run(reproBinary & " check --mode=pre-push --workspace-root=" & repo)

suite "MO-2: workspace marker accepts a committed-lock-only repo":

  test "t_workspace_marker_accepts_committed_lock_only_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo2-marker-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- Marker TRUE: a committed-lock-only repo. ----
      let lockRepo = scratch / "lock-repo"
      initRepo(gitBin, lockRepo)
      writeFile(lockRepo / "repro.solver", solverInputs)
      check run(reproBinary & " lock refresh " & q(lockRepo)).code == 0
      check fileExists(lockRepo / "repro.lock")
      check git(gitBin, lockRepo, "add repro.solver repro.lock").code == 0
      check git(gitBin, lockRepo, "commit -m lock").code == 0
      # No `.repo/` of any kind — the committed lock is the only marker.
      check not dirExists(lockRepo / ".repo")

      let lockChk = checkPrePush(lockRepo)
      # The marker is TRUE → the gate proceeds; it never prints the no-op
      # "not a workspace" diagnostic. (Exit code is intentionally not
      # asserted here — this test is about the marker decision, not the
      # gate verdict; the gate-passes path is covered by the companion
      # operate-from-lock suite.)
      check "not a workspace" notin lockChk.output

      # ---- Marker FALSE: a bare git repo with no lock and no `.repo/`. ----
      let bareRepo = scratch / "bare-repo"
      initRepo(gitBin, bareRepo)
      check not fileExists(bareRepo / "repro.lock")
      check not dirExists(bareRepo / ".repo")

      let bareChk = checkPrePush(bareRepo)
      # The marker is FALSE → the gate no-ops with success and the clear
      # "not a workspace" diagnostic.
      check bareChk.code == 0
      check "not a workspace" in bareChk.output
