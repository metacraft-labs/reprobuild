## L1 REPRO-DEVELOP-ALL — ``repro develop --all`` clones every dependency at
## its LOCK-PINNED revision into sibling checkouts and records the develop-mode
## override mapping; a missing lock fails LOUD.
##
## Spec: reprobuild-specs/Reprobuild-Lock-Driven-Provisioning-And-Publish-
## Scope.milestones.org §L1; CLI/develop.md; Workspace-And-Develop-Mode.md;
## Locking-And-Solver.md.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline):
##
##   <scratch>/
##     liba.git / liba   — a published reprobuild dep repo (own git history)
##     libb.git / libb   — a second published reprobuild dep repo
##     app.git  / app    — the workspace repo; its committed ``repro.lock``
##                         pins liba + libb at their EXACT HEAD SHAs by URL,
##                         plus a root ``.`` dep (the consumer, never cloned)
##     deps/             — the ``--into`` checkout-placement root
##
## The lock references the two dep repos' local ``.git`` bare origins, so the
## clone is a REAL git clone but entirely offline (no network).
##
## Asserts:
##   1. ``repro develop --all --into=<deps>`` exits 0 and reports both deps
##      cloned; it does NOT clone the root ``.`` node.
##   2. Each sibling checkout exists under <deps>/ AND its HEAD is the EXACT
##      locked revision (not the branch tip in general — here the branch tip IS
##      the locked SHA, but the reset-to-SHA path is what pins it).
##   3. The M20 override file ``.repro/develop-overrides.toml`` records the
##      ``solved node -> local path`` mapping for both deps (and NOT the root).
##   4. A missing committed lock fails LOUD (exit 1, diagnostic names the lock
##      path) — no branch-tip fallback.
##
## Falsifiability: if ``--all`` cloned at a branch tip instead of the locked
## SHA, (2)'s exact-SHA assertion fails; if it cloned the root ``.`` node,
## (1)/(3) gain a spurious ``app`` entry; if it did not record overrides, (3)
## fails; if the missing-lock path silently succeeded, (4)'s exit-1 fails.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` missing on PATH, or repro unbuilt.

import std/[os, osproc, strutils, unittest]
from repro_test_support import fileUrl, tomlBasicString

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

const depRecipe = """
import repro_project_dsl

package PKG:
  build:
    discard aggregate("PKG-agg", actions = @[])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc mustRun(res: tuple[code: int; output: string]; what: string) =
  ## `doAssert`, not `check`: the callers below are HELPERS, outside any
  ## `test` body, where `unittest.check` cannot see the `testStatusIMPL`
  ## the `test` template injects — it prints "Check failed" and the case
  ## still reports `[OK]`. `doAssert` raises an `AssertionDefect`, which
  ## the `test` template's own `except Exception` catches and reports as a
  ## failure from any call depth.
  doAssert res.code == 0,
    what & " failed (exit " & $res.code & "):\n" & res.output

proc initPublishedRepo(gitBin, scratch, name: string):
    tuple[origin, work: string] =
  let origin = scratch / (name & ".git")
  let work = scratch / name
  mustRun(git(gitBin, "", "init --bare -b main " & q(origin)),
    "git init --bare " & origin)
  mustRun(run(q(gitBin) & " clone " & q(origin) & " " & q(work)),
    "git clone " & origin)
  mustRun(git(gitBin, work, "config user.email t@example.invalid"),
    "git config user.email in " & work)
  mustRun(git(gitBin, work, "config user.name Tester"),
    "git config user.name in " & work)
  (origin: origin, work: work)

proc initDepRepo(gitBin, scratch, name: string): tuple[origin, sha: string] =
  let (origin, work) = initPublishedRepo(gitBin, scratch, name)
  writeFile(work / "repro.nim", depRecipe.replace("PKG", name))
  mustRun(git(gitBin, work, "add repro.nim"), "git add in " & work)
  mustRun(git(gitBin, work, "commit -m " & name), "git commit in " & work)
  mustRun(git(gitBin, work, "push origin main"), "git push in " & work)
  (origin: origin, sha: git(gitBin, work, "rev-parse HEAD").output.strip())

proc depInline(name, path, url, sha, depends: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"" &
    (if sha.len > 0: "git-sha1:" & sha else: "") &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"" & depends & "\", groups = \"\" }"

suite "L1: repro develop --all clones deps at locked revisions":

  test "t_develop_all_clones_deps_at_locked_revisions":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      # Resolve repro to an absolute path — the fixture runs commands with a
      # per-repo ``cwd`` where the ``./build/bin/repro`` relative path breaks.
      let repro = absolutePath(reproBinary)
      let scratch = getTempDir() / "l1-develop-all-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- Two published dependency repos, each a reprobuild project. ----
      let liba = initDepRepo(gitBin, scratch, "liba")
      let libb = initDepRepo(gitBin, scratch, "libb")
      check liba.sha.len == 40
      check libb.sha.len == 40

      # Advance liba's branch PAST the locked SHA so the branch tip differs from
      # the pin. This makes assertion (2) non-vacuous: a branch-tip clone would
      # land on ``libaTip``, only an exact reset-to-SHA lands on ``liba.sha``.
      writeFile(scratch / "liba" / "moved.txt", "past the lock\n")
      check git(gitBin, scratch / "liba", "add moved.txt").code == 0
      check git(gitBin, scratch / "liba", "commit -m move").code == 0
      check git(gitBin, scratch / "liba", "push origin main").code == 0
      let libaTip = git(gitBin, scratch / "liba", "rev-parse HEAD").output.strip()
      check libaTip != liba.sha

      # ---- The workspace repo with a committed lock pinning both deps. ----
      let host = initPublishedRepo(gitBin, scratch, "app")
      let repo = host.work
      # Seed a commit so ``git rev-parse HEAD`` yields a real SHA (a fresh
      # clone of an empty bare has no HEAD, which would poison the lock).
      writeFile(repo / "README.md", "l1 fixture\n")
      check git(gitBin, repo, "add README.md").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      let appSha = git(gitBin, repo, "rev-parse HEAD").output.strip()
      check appSha.len == 40
      let rootDep = depInline("app", ".", fileUrl(host.origin),
        # the root repo has no meaningful pinned rev here; it is never cloned.
        "", "liba,libb").replace("revision = \"\"",
          "revision = \"" & appSha & "\"")
      let lockBody = "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
        "[lock]\n" &
        "platform = \"x86_64-linux\"\n" &
        "optimal = true\n" &
        "inputs_digest = \"l1-fixture\"\n" &
        "variants = []\n" &
        "packages = []\n" &
        "deps = [" & rootDep & ", " &
        depInline("liba", "liba", fileUrl(liba.origin), liba.sha, "") & ", " &
        depInline("libb", "libb", fileUrl(libb.origin), libb.sha, "") & "]\n"
      writeFile(repo / "repro.lock", lockBody)

      let deps = scratch / "deps"

      # ---- (1) develop --all clones both deps; NOT the root. ----
      let res = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = repo)
      check res.code == 0
      check ("cloned liba @ " & liba.sha) in res.output
      check ("cloned libb @ " & libb.sha) in res.output
      check "app" notin res.output           # the root node is never cloned

      # ---- (2) each sibling checkout is at the EXACT locked revision. ----
      check dirExists(deps / "liba")
      check dirExists(deps / "libb")
      let libaHead = git(gitBin, deps / "liba", "rev-parse HEAD").output.strip()
      check libaHead == liba.sha       # the LOCKED SHA, not the moved-on tip
      check libaHead != libaTip        # branch-tip fallback would land here
      check git(gitBin, deps / "libb", "rev-parse HEAD").output.strip() ==
        libb.sha

      # ---- (3) the override file records solved node -> local path. ----
      let ovPath = repo / ".repro" / "develop-overrides.toml"
      check fileExists(ovPath)
      let ov = readFile(ovPath)
      check "package = \"liba\"" in ov
      check "package = \"libb\"" in ov
      # ``develop-overrides.toml`` is written by reprobuild, whose
      # ``develop_overrides.tomlEscape`` doubles a backslash — so the
      # expected spelling of a Windows path is the ESCAPED one. Asserting
      # the raw form was an assertion bug; on POSIX the two coincide.
      check ("local_path = \"" & tomlBasicString(deps / "liba") &
        "\"") in ov
      check ("local_path = \"" & tomlBasicString(deps / "libb") &
        "\"") in ov
      check "provenance = \"repro develop --all\"" in ov
      # The root ``.`` node did NOT get an override (it is the consumer).
      check "package = \"app\"" notin ov

      # ---- (4) a missing committed lock fails LOUD. ----
      let noLock = scratch / "nolock"
      createDir(noLock)
      let miss = run(repro & " develop --all --tool-provisioning=path",
        cwd = noLock)
      check miss.code == 1
      check "no committed lock" in miss.output
      check (noLock / "repro.lock") in miss.output
