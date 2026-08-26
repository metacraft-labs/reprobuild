## DS-5 (CLI/develop.md §"Which record, for a commit-addressed backend") —
## **`--at=<rev>` and the first-parent ancestry walk**.
##
##   > Commit-addressed backends (git-checkout `locks/<project>/<repo>/<sha>.toml`)
##   > are keyed by a commit, and the key is **the workspace root repo's
##   > `HEAD`**, walking first-parent ancestry to the nearest locked ancestor
##   > when `HEAD` itself carries no record […] `--at=<rev>` overrides the key.
##   > There is no branch-tip fallback: a backend that yields no record for the
##   > resolved key contributes nothing and says so.
##
## and the resolver behaviour Workspace-Manifests.md §"No shared lock index"
## already specifies: "The resolver walks first-parent ancestry to the nearest
## locked commit when an exact commit has no lock yet."
##
## Why this is not cosmetic. A workspace publishes a lock record when it
## pushes, not on every commit, so the ORDINARY state of a working workspace is
## "HEAD carries no record". Before this milestone the commit-keyed read asked
## about `HEAD` and nothing else: one unpublished commit on the root repo and
## the whole commit-keyed seed went empty, so every repo silently fell through
## to a different resolver — a pin from somewhere other than the commit the
## user is standing on, with nothing said. And `--at` did not exist at all, so
## a CI run that wanted the pins of `$GITHUB_SHA` had no way to ask for them.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline):
##
##   <scratch>/
##     origin-lib.git / seed-lib   — a TEAM repo with TWO commits (libSha1,
##                                   libSha2), so two different records can
##                                   pin it to two different revisions
##     ws/                         — the workspace root, itself a git repo with
##                                   a THREE-commit first-parent history
##                                   C1 -> C2 -> C3(HEAD)
##       .repro/manifests/         — the TEAM backend (a git checkout)
##         projects/mix.toml       — declares `ws-root` at path "." (the
##                                   workspace ROOT repo, which is what keys a
##                                   commit-addressed backend) and `lib`
##         locks/mix/ws-root/<sha>.toml — hand-written records, so the test
##                                   controls exactly which commits are locked
##       .git/repro/config.toml    — layer 5: team -> git-checkout
##
## Asserts:
##   1. HEAD (C3) carries no record: the walk finds C1 (2 commits back), NAMES
##      it, and `lib` resolves to the revision C1's record pins (libSha1);
##   2. publishing a record at C3 makes the exact key win — no walk, no notice,
##      and `lib` resolves to libSha2;
##   3. `--at=<C1>` overrides the key: exact hit, libSha1;
##   4. `--at=<C2>` walks ONE commit back to C1 and says so;
##   5. NO BRANCH-TIP FALLBACK: a record published on a commit that is NOT an
##      ancestor of the key (a sibling branch's tip) is never used — the
##      backend reports it holds nothing for the key nor for any first-parent
##      ancestor, and the repo contributes nothing;
##   6. an `--at` that names no commit of the root repository REFUSES rather
##      than silently keying on HEAD.
##
## Falsifiability / pre-fix failure: against ``391a892a`` this test fails at
## (1) — `--at` and `--list` do not exist, so the binary exits 1 with
##
##   repro develop: error: unsupported `repro develop --all` argument: --at=<sha>
##
## Mutation check: deleting the ancestry walk from
## ``lockRecordAtCommitOrAncestor`` (returning ``none`` when the exact commit
## has no record) fails (1) and (4); dropping the `foundAt != key` notice fails
## (1) and (4)'s ancestor-naming assertions; making the walk fall back to the
## backend's newest record regardless of ancestry fails (5).
##
## Mocks: NONE. Real git repositories on the real filesystem, a real manifest
## checkout, a real layer-5 config inside a real ``.git``, the real ``repro``
## binary, the real git-checkout lock backend.
##
## Hermetic: fresh tempdir; layers 2 and 3 are silenced via the
## ``REPROBUILD_*_CONFIG`` overrides; layer 5 resolves from the fixture's own
## ``.git/repro/config.toml``. Skip: ``git`` missing or ``repro`` unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]
from repro_test_support import fileUrl

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check` or `quit`: this is a HELPER, outside any
  ## `test` body. `unittest.check` there cannot see the `testStatusIMPL`
  ## the `test` template injects, so it prints "Check failed" and the case
  ## still reports `[OK]`; `quit 1` tears the process down mid-case, so
  ## `unittest` emits no `[FAILED]` marker and every later case in the file
  ## silently never runs. `doAssert` raises an `AssertionDefect`, which the
  ## `test` template's own `except Exception` catches and reports as a
  ## failure from any call depth.
  let res = run(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"DS5 Tester\"")

proc commitIn(gitBin, repo, name: string): string =
  writeFile(repo / name, name & "\n")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " commit -m " & q(name))
  requireGit(q(gitBin) & " -C " & q(repo) & " rev-parse HEAD").strip()

proc seedGitOrigin(gitBin, originPath, workPath: string):
    tuple[first, second: string] =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  let a = commitIn(gitBin, workPath, "one.txt")
  let b = commitIn(gitBin, workPath, "two.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  (first: a, second: b)

proc projectToml(libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/ws-root.toml\",\n  \"repos/lib.toml\",\n]\n"

proc repoFragment(name, path, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & path & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc lockRecord(rootSha, libSha: string): string =
  ## The exact ``reprobuild.workspace.lock.v1`` body the git-checkout backend
  ## writes and ``shasFromBody`` reads: a flat ``[[repo]]`` array of
  ## ``path``/``revision`` pairs.
  "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
  "[lock]\n" &
  "project = \"mix\"\n" &
  "created_at = \"2026-01-01T00:00:00Z\"\n" &
  "created_by = \"ds5 fixture\"\n\n" &
  "[[repo]]\nname = \"ws-root\"\npath = \".\"\nremote = \"lib-origin\"\n" &
  "revision = \"" & rootSha & "\"\nbranch = \"main\"\n\n" &
  "[[repo]]\nname = \"lib\"\npath = \"lib\"\nremote = \"lib-origin\"\n" &
  "revision = \"" & libSha & "\"\nbranch = \"main\"\n"

suite "DS-5: --at and the first-parent walk to the nearest locked ancestor":

  test "t_develop_at_rev_walks_to_nearest_locked_ancestor":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds5-at-", "")
      defer: removeDir(scratch)

      let libOrigin = scratch / "origin-lib.git"
      let libShas = seedGitOrigin(gitBin, libOrigin, scratch / "seed-lib")
      check libShas.first.len == 40
      check libShas.second.len == 40
      check libShas.first != libShas.second

      # ---- the workspace ROOT repo, with a three-commit first-parent chain.
      let ws = scratch / "workspace"
      initGitRepo(gitBin, ws)

      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml(fileUrl(libOrigin)))
      writeFile(manifestsRoot / "repos" / "ws-root.toml",
        repoFragment("ws-root", ".", "lib-origin"))
      writeFile(manifestsRoot / "repos" / "lib.toml",
        repoFragment("lib", "lib", "lib-origin"))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      discard requireGit(q(gitBin) & " clone " & q(fileUrl(libOrigin)) &
        " " & q(ws / "lib"))

      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n")

      let layer5Dir = ws / ".git" / "repro"
      createDir(layer5Dir)
      writeFile(layer5Dir / "config.toml",
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"ws-root\", \"lib\"] }]\n")

      # ``.repro/manifests`` is a nested git repo; keep it out of the root
      # repo's index so the root's own commits stay small and deterministic.
      writeFile(ws / ".gitignore", ".repro/\nlib/\n")
      let c1 = commitIn(gitBin, ws, "c1.txt")
      let c2 = commitIn(gitBin, ws, "c2.txt")
      let c3 = commitIn(gitBin, ws, "c3.txt")
      check c1.len == 40 and c2.len == 40 and c3.len == 40

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      proc publishRecord(rootSha, libSha: string) =
        let dir = manifestsRoot / "locks" / "mix" / "ws-root"
        createDir(dir)
        writeFile(dir / (rootSha & ".toml"), lockRecord(rootSha, libSha))
        discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
        discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
          " commit -m " & q("lock " & rootSha))

      proc listAt(rev = ""): tuple[code: int; output: string] =
        run(repro & " develop --list --tool-provisioning=path" &
          (if rev.len > 0: " --at=" & q(rev) else: ""), cwd = ws)

      proc libRow(output: string): string =
        for line in output.splitLines():
          if line.startsWith("lib "): return line
        ""

      # ---- (5) NO BRANCH-TIP FALLBACK, established FIRST. ----------------
      # A record published on a commit that is NOT an ancestor of HEAD (a
      # sibling branch tip) must never be used. Publish one there and nowhere
      # else, then ask about HEAD.
      discard requireGit(q(gitBin) & " -C " & q(ws) & " checkout -b sidebranch")
      let side = commitIn(gitBin, ws, "side.txt")
      discard requireGit(q(gitBin) & " -C " & q(ws) & " checkout main")
      check requireGit(q(gitBin) & " -C " & q(ws) &
        " rev-parse HEAD").strip() == c3
      publishRecord(side, libShas.second)

      let noAncestor = listAt()
      if noAncestor.code != 0:
        checkpoint("develop --list output: " & noAncestor.output)
      check noAncestor.code == 0
      check ("holds no lock record for " & c3) in noAncestor.output
      check "nor for any first-parent ancestor" in noAncestor.output
      check "there is no branch-tip fallback" in noAncestor.output
      # The sibling branch's record pinned lib to libShas.second. It must not
      # have leaked into the answer: `lib` contributes NOTHING at all.
      check ("lib (tier=team backend=git-checkout)") in noAncestor.output
      check libRow(noAncestor.output).len == 0

      # ---- (1) HEAD carries no record; the walk finds C1 and NAMES it. ---
      publishRecord(c1, libShas.first)
      let walked = listAt()
      if walked.code != 0:
        checkpoint("develop --list output: " & walked.output)
      check walked.code == 0
      check ("holds no lock record for " & c3) in walked.output
      check ("nearest locked ancestor " & c1) in walked.output
      check "(2 commit(s) back)" in walked.output
      check libShas.first in libRow(walked.output)
      check libShas.second notin libRow(walked.output)

      # ---- (4) --at=<C2> walks exactly ONE commit back to C1. ------------
      let atC2 = listAt(c2)
      check atC2.code == 0
      check ("holds no lock record for " & c2) in atC2.output
      check ("nearest locked ancestor " & c1) in atC2.output
      check "(1 commit(s) back)" in atC2.output
      check libShas.first in libRow(atC2.output)

      # ---- (3) --at=<C1> is an EXACT hit: no walk, no notice. ------------
      let atC1 = listAt(c1)
      check atC1.code == 0
      check "nearest locked ancestor" notin atC1.output
      check libShas.first in libRow(atC1.output)

      # ---- (2) publishing at C3 makes the EXACT key win. -----------------
      publishRecord(c3, libShas.second)
      let exact = listAt()
      if exact.code != 0:
        checkpoint("develop --list output: " & exact.output)
      check exact.code == 0
      check "nearest locked ancestor" notin exact.output
      check libShas.second in libRow(exact.output)
      check libShas.first notin libRow(exact.output)
      # …and `--at` still reaches back past it to C1's record.
      let backToC1 = listAt(c1)
      check backToC1.code == 0
      check libShas.first in libRow(backToC1.output)

      # ---- (6) an unresolvable --at REFUSES, never falls back to HEAD. ---
      let bogus = listAt("0123456789012345678901234567890123456789")
      check bogus.code == 2
      check "does not resolve to a commit" in bogus.output
      check "never silently keys on a different one" in bogus.output
      check libRow(bogus.output).len == 0
