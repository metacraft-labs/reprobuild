## L1 REPRO-DEVELOP-ALL POST-CONDITION — ``repro develop --all`` must not
## report a checkout it cannot show you.
##
## Spec: reprobuild-specs/Reprobuild-Lock-Driven-Provisioning-And-Publish-
## Scope.milestones.org §L1; CLI/develop.md §"Action axis".
##
## Every mode the command reports as done is a claim that a checkout of the
## node is on disk at the printed path. ``cloned``/``reset`` claim THIS run put
## it there; ``adopted``/``idempotent`` claim it was already there. None of them
## was ever checked against the filesystem after the fact: the claim came from a
## helper's exit status, or from an override record written on an earlier run.
##
## The consequence is a success report for work that was not done. A workspace
## whose sibling checkout has been deleted — a cleaned CI runner, an operator
## reclaiming disk, a half-finished clone removed by hand — still has the
## override entry, so the next run answers "already in develop mode at <path>"
## about a path that does not exist, exits 0, and every consumer that reads that
## dependency from disk then fails somewhere far away with a missing module or
## an unparseable manifest.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline): one
## published dependency repo, one workspace repo whose committed ``repro.lock``
## pins it at an exact SHA, and a ``--into`` placement root. Mirrors
## t_develop_all_clones_deps_at_locked_revisions.nim.
##
## Asserts:
##   1. The first ``repro develop --all --into=<deps>`` clones the dependency,
##      exits 0, and records the override — the baseline this test then breaks.
##   2. With the checkout DELETED and the override left in place, a second run
##      exits NON-ZERO, names the node, and names the absent path. Before the
##      post-condition existed this exact run printed "already in develop mode
##      … (no change)" and exited 0.
##   3. The diagnostic reaches the ``--json`` consumer too, as an ``error``
##      node with ``ok = false`` — the two surfaces answer the same question.
##   4. Restoring the checkout makes the same command succeed again, so the
##      refusal tracks the state of the tree and is not a permanent poisoning
##      of the override record.
##
## Falsifiability: revert the post-condition and (2) fails on the exit code and
## on both substring checks; weaken it to a warning and (2) fails on the exit
## code alone; make it fire unconditionally and (1) and (4) fail.
##
## No mocks: a real ``git init --bare`` origin, the real clone path, and the
## engine-built ``build/bin/repro``. Hermetic + offline: every git repo lives in
## a fresh tempdir; nothing touches $HOME. Skip rule: ``git`` missing on PATH,
## or repro unbuilt.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const depRecipe = """
import repro_project_dsl

package liba:
  build:
    discard aggregate("liba-agg", actions = @[])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initPublishedRepo(gitBin, scratch, name: string):
    tuple[origin, work: string] =
  let origin = scratch / (name & ".git")
  let work = scratch / name
  check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
  check run(q(gitBin) & " clone " & q(origin) & " " & q(work)).code == 0
  check git(gitBin, work, "config user.email t@example.invalid").code == 0
  check git(gitBin, work, "config user.name Tester").code == 0
  (origin: origin, work: work)

proc depInline(name, path, url, sha, depends: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"" &
    (if sha.len > 0: "git-sha1:" & sha else: "") &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"" & depends & "\", groups = \"\" }"

suite "L1: repro develop --all verifies what it reports":

  test "t_develop_all_refuses_to_report_an_absent_checkout":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = getTempDir() / "l1-develop-absent-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- One published dependency repo, pinned at its exact HEAD. ----
      let (libOrigin, libWork) = initPublishedRepo(gitBin, scratch, "liba")
      writeFile(libWork / "repro.nim", depRecipe)
      check git(gitBin, libWork, "add repro.nim").code == 0
      check git(gitBin, libWork, "commit -m liba").code == 0
      check git(gitBin, libWork, "push origin main").code == 0
      let lockedSha = git(gitBin, libWork, "rev-parse HEAD").output.strip()
      check lockedSha.len == 40

      # ---- The workspace repo with a committed lock pinning liba. ----
      let host = initPublishedRepo(gitBin, scratch, "app")
      let repo = host.work
      writeFile(repo / "README.md", "absent-checkout fixture\n")
      check git(gitBin, repo, "add README.md").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      let appSha = git(gitBin, repo, "rev-parse HEAD").output.strip()
      let rootDep = depInline("app", ".", host.origin, "", "liba").replace(
        "revision = \"\"", "revision = \"" & appSha & "\"")
      writeFile(repo / "repro.lock",
        "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
        "[lock]\n" &
        "platform = \"x86_64-linux\"\n" &
        "optimal = true\n" &
        "inputs_digest = \"absent-checkout-fixture\"\n" &
        "variants = []\n" &
        "packages = []\n" &
        "deps = [" & rootDep & ", " &
        depInline("liba", "liba", libOrigin, lockedSha, "") & "]\n")

      let deps = scratch / "deps"
      createDir(deps)
      let placed = deps / "liba"

      # ---- (1) Baseline: the first run really does place the checkout. ----
      let first = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = repo)
      check first.code == 0
      check "cloned" in first.output
      check dirExists(placed)
      check git(gitBin, placed, "rev-parse HEAD").output.strip() == lockedSha
      let ovPath = repo / ".repro" / "develop-overrides.toml"
      check fileExists(ovPath)
      check ("local_path = \"" & placed & "\"") in readFile(ovPath)

      # ---- (2) Delete the checkout; the override record survives. This is
      #      the CI runner that was cleaned between jobs. The command has
      #      nothing on disk to point at and must say so. ----
      removeDir(placed)
      check not dirExists(placed)
      check fileExists(ovPath)

      let absent = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = repo)
      check absent.code != 0
      # It names the node and the path it cannot show you, not just "failed".
      check "liba" in absent.output
      check placed in absent.output
      # And it does NOT report the work as done.
      check "already in develop mode" notin absent.output

      # ---- (3) The machine-readable surface carries the same verdict. ----
      let absentJson = run(repro & " develop --all --json --into=" & q(deps) &
        " --tool-provisioning=path", cwd = repo)
      check absentJson.code != 0
      check "\"ok\": false" in absentJson.output
      check "\"mode\": \"error\"" in absentJson.output
      check "liba" in absentJson.output

      # ---- (4) Restore the checkout and the same command is happy again:
      #      the refusal tracks the tree, it does not poison the record. ----
      check run(q(gitBin) & " clone " & q(libOrigin) & " " & q(placed)).code == 0
      check git(gitBin, placed, "checkout --detach " & lockedSha).code == 0
      let restored = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = repo)
      check restored.code == 0
      check "already in develop mode" in restored.output
