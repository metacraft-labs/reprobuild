## Workspace-Manifest-Optional MO-8 — a lock-file-only workspace is fully
## DESCRIBED BY the committed lock's content, not re-derived from live HEAD.
##
## This is the load-bearing "self-described from the lock" property. Before
## MO-8 the committed-lock-only path (MO-2/MO-7) reconstructed the workspace
## from the filesystem + live ``git HEAD``, using ``repro.lock`` only as a
## presence marker. MO-8 populates the participating set + per-repo revisions
## from the LOCK's coordinates, so the resolved model reflects the LOCKED
## state even after the checkout's HEAD moves.
##
## Proof (built ``./build/bin/repro``, black-box):
##
##   1. A git workspace repo carries a ``repro.solver`` + a refreshed v2
##      ``repro.lock``. The lock pins the workspace dep at revision X
##      (HEAD at refresh time).
##   2. The checkout's HEAD is then moved to a DIFFERENT commit Y.
##   3. ``repro workspace sync --dry-run`` resolves the participating set from
##      the LOCK content: its plan reports the LOCKED revision X, NOT HEAD Y.
##      (The old MO-2 HEAD-derivation would have reported Y.)
##
## Falsifiability: if the committed-lock path re-derived from live HEAD instead
## of the lock content, the plan would carry Y and (3)'s "X present / Y absent"
## assertions FAIL.
##
## Hermetic: the git repo lives in a fresh tempdir. Skip rule: ``git`` missing
## or repro unbuilt.

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

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

suite "MO-8: lock-file-only workspace described from lock content, not HEAD":

  test "t_lock_file_only_workspace_fully_described_from_lock_not_head":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo8-fromlock-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let origin = scratch / "origin.git"
      let repo = scratch / "work"
      check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
      check run(q(gitBin) & " clone " & q(origin) & " " & q(repo)).code == 0
      check git(gitBin, repo, "config user.email t@example.invalid").code == 0
      check git(gitBin, repo, "config user.name Tester").code == 0

      # ---- (1) Establish the lock at revision X (HEAD at refresh). ----
      writeFile(repo / "README.md", "mo8 fixture\n")
      writeFile(repo / "repro.solver", solverInputs)
      check git(gitBin, repo, "add README.md repro.solver").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      check git(gitBin, repo, "push origin main").code == 0
      check run(reproBinary & " lock refresh " & q(repo)).code == 0

      let revX = git(gitBin, repo, "rev-parse HEAD").output.strip()
      check revX.len == 40
      # The lock genuinely pins X in its coordinates.
      check ("revision = \"" & revX & "\"") in readFile(repo / "repro.lock")

      # ---- (2) Move the checkout's HEAD to a DIFFERENT commit Y. ----
      writeFile(repo / "moved.txt", "head has moved past the lock\n")
      check git(gitBin, repo, "add moved.txt").code == 0
      check git(gitBin, repo, "commit -m move-head").code == 0
      let revY = git(gitBin, repo, "rev-parse HEAD").output.strip()
      check revY.len == 40
      check revY != revX

      # ---- (3) The resolved model is from the LOCK (X), not live HEAD (Y). ----
      let sync = run(reproBinary & " workspace sync --workspace-root=" & repo &
        " --dry-run")
      check sync.code == 0
      check "[update] ." in sync.output
      check revX in sync.output          # the LOCKED revision is reported
      check revY notin sync.output       # NOT the moved-on HEAD
      check "requires" notin sync.output
      check "not a workspace" notin sync.output
