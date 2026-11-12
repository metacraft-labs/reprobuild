## The managed `pre-commit` hook re-pins the committed `repro.lock`'s sibling
## entries from observed state and stages the result into the commit being
## formed (Unified-Locking-And-Hooks.md §13.3, "The `repro.lock` contract").
##
## WHY. A committed lock is in-tree, so the pre-push gate cannot produce it
## (§13.1): the only point where "the siblings were at X, Y, Z" can be written
## into the revision it describes is while that revision is being formed.
## Without this, committed sibling pins go stale exactly the way hand-written
## `=<sha>` sibling entries did.
##
## Fixture: `committed_lock_siblings_fixture.nim` (a real manifest workspace,
## app → lib-b → lib-c, lib-d unrelated). The lock is first written by the
## explicit `repro lock refresh` and published. Then a REAL `.git/hooks/
## pre-commit` in app issues the byte-identical dispatch the managed hook body
## issues (`repro hooks dispatch pre-commit --repo-root "$REPO_ROOT"`), naming
## the built binary by absolute path so a dev-shell `repro` on PATH cannot
## stand in for the one under test. Every case observes what a real
## `git commit` produced.
##
## Cases:
##   1. No sibling moved → the commit does not touch repro.lock.
##   2. lib-b advanced → the commit carries repro.lock pinning lib-b's new
##      HEAD with matching `git-sha1:` integrity; lib-c keeps its pin; the
##      `packages` line (the solve) is byte-identical; nothing is left
##      unstaged.
##   3. The manifest gains the edge app → lib-d → the next commit adds a
##      `../lib-d` entry and the root `depends` names it.
##   4. A dirty sibling does not refuse the commit; the hook pins its HEAD and
##      names it as not describing the working tree.
##   5. A `deps` array laid out as TOML continuation lines is read whole and
##      rewritten as one canonical line: the committed lock parses as TOML
##      and pins every sibling once.
##
## Falsifiability (observed): before the hook learned `repro.lock`, case 2's
## commit carries no repro.lock and the lock still names lib-b's old commit.
##
## NO MOCKS. The one arrangement is writing the hook file by hand instead of
## `repro hooks ensure --vcs`, for the PATH reason above; its body is the
## managed body's dispatch line.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_lock
import ./committed_lock_siblings_fixture
from test_certificates/toml as tctoml import nil

proc installPreCommit(fx: SiblingFixture) =
  let hook = fx.app / ".git" / "hooks" / "pre-commit"
  createDir(hook.parentDir)
  writeFile(hook,
    "#!/usr/bin/env sh\nset -eu\n" &
    "REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n" &
    "cd \"$REPO_ROOT\"\nREPRO_STATUS=0\n" &
    q(fx.repro) & " hooks dispatch pre-commit --repo-root \"$REPO_ROOT\" " &
      "-- \"$@\" || REPRO_STATUS=$?\nexit $REPRO_STATUS\n")
  var perms = getFilePermissions(hook)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(hook, perms)

proc commitInApp(fx: SiblingFixture; label: string): tuple[code: int; output: string] =
  writeFile(fx.app / (label & ".txt"), label & "\n")
  discard fx.git(fx.app, "add " & q(label & ".txt"))
  runCmd(q(fx.gitBin) & " -C " & q(fx.app) & " commit -m " & q(label))

proc filesInHead(fx: SiblingFixture): string =
  fx.git(fx.app, "show --name-only --format= HEAD")

suite "pre-commit re-pins the committed lock's siblings":

  test "t_commit_repins_committed_lock_siblings":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var fx = setupSiblingFixture("commit-repin")
      defer: removeDir(fx.scratch)
      fx.refreshAndPublishLock()
      let before = readFile(fx.app / "repro.lock")
      let packagesBefore = linePrefixed(before, "packages = ")
      check packagesBefore.len > 0
      let libCPin = fx.headOf(fx.ws / "lib-c")
      fx.installPreCommit()

      # 1. nothing moved: repro.lock is not part of the commit.
      let c1 = fx.commitInApp("unrelated")
      checkpoint(c1.output)
      check c1.code == 0
      check "repro.lock" notin fx.filesInHead()
      check readFile(fx.app / "repro.lock") == before

      # 2. lib-b moved: the commit carries the re-pinned lock.
      let libBNext = fx.advance("lib-b")
      let c2 = fx.commitInApp("after-lib-b")
      checkpoint(c2.output)
      check c2.code == 0
      check "repro.lock" in fx.filesInHead()
      let committed = fx.git(fx.app, "show HEAD:repro.lock")
      let libB = depEntry(committed, "lib-b")
      check ("revision = \"" & libBNext & "\"") in libB
      check ("integrity = \"git-sha1:" & libBNext & "\"") in libB
      check ("revision = \"" & libCPin & "\"") in depEntry(committed, "lib-c")
      check linePrefixed(committed, "packages = ") == packagesBefore
      check fx.git(fx.app, "status --porcelain").strip().len == 0

      # 3. a newly declared develop-set sibling is added.
      fx.setAppDepends(@["lib-b", "lib-d"])
      let c3 = fx.commitInApp("after-edge")
      checkpoint(c3.output)
      check c3.code == 0
      let withD = fx.git(fx.app, "show HEAD:repro.lock")
      let libD = depEntry(withD, "lib-d")
      check ("revision = \"" & fx.headOf(fx.ws / "lib-d") & "\"") in libD
      check "lib-d" in depEntry(withD, ".")

      # 4. a dirty sibling is recorded at HEAD and named, never refused.
      writeFile(fx.ws / "lib-c" / "scratch.txt", "uncommitted\n")
      let libCNext = fx.advance("lib-b")
      let c4 = fx.commitInApp("dirty-sibling")
      checkpoint(c4.output)
      check c4.code == 0
      check "lib-c" in c4.output
      check "working tree" in c4.output
      check ("revision = \"" & libCNext & "\"") in
        depEntry(fx.git(fx.app, "show HEAD:repro.lock"), "lib-b")

  test "partial refresh migrates compact and CRLF v2 schema assignments":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      for compactSchema in ["schema=\"reprobuild.solved-graph-lock.v2\"",
                            "  schema  =  \"reprobuild.solved-graph-lock.v2\""]:
        var fx = setupSiblingFixture("compact-v2-repin")
        defer: removeDir(fx.scratch)
        fx.refreshAndPublishLock()
        let before = readFile(fx.app / "repro.lock")
        let packagesBefore = linePrefixed(before, "packages = ")
        var legacy = before.replace(
          "schema = \"reprobuild.solved-graph-lock.v3\"", compactSchema)
        let originalDeps = linePrefixed(legacy, "deps = ")
        var legacyDeps = originalDeps.replace(", self = \"true\"", "")
        for dep in parseLockedDependencies(before).deps:
          let opening = "{ name = \"" & dep.name & "\""
          legacyDeps = legacyDeps.replace(opening,
            opening & ", path = \"" & dep.path & "\"")
        legacy = legacy.replace(originalDeps, legacyDeps)
        legacy = "# Legacy lock with noncanonical schema spacing\n" & legacy
        if compactSchema.startsWith(" "):
          legacy = legacy.replace("\n", "\r\n")
        writeFile(fx.app / "repro.lock", legacy)
        discard fx.git(fx.app, "add repro.lock")
        discard fx.git(fx.app, "commit -m legacy-lock")
        fx.installPreCommit()
        let libBNext = fx.advance("lib-b")
        let committed = fx.commitInApp("migrate-v2")
        checkpoint(committed.output)
        check committed.code == 0
        let migrated = readFile(fx.app / "repro.lock")
        check "reprobuild.solved-graph-lock.v3" in migrated
        check "reprobuild.solved-graph-lock.v2" notin migrated
        check "path =" notin linePrefixed(migrated, "deps = ")
        check migrated.count("self = \"true\"") == 1
        check ("revision = \"" & libBNext & "\"") in depEntry(migrated, "lib-b")
        check linePrefixed(migrated, "packages = ") == packagesBefore

  test "a deps array written over continuation lines is re-pinned whole":
    # reprobuild-pm issue 2026-11-12-the-pre-commit-lock-rewrite-misreads-a-
    # multi-line-deps-entry-and-writes-invalid-toml. codetracer `a0efd6494`
    # committed its `deps` array as TOML continuation lines (valid TOML). The
    # next commit's re-pin read only the array's first physical line, spliced
    # its rewrite over that line alone and left the continuation lines behind:
    # a lock that no longer parses. Here the first physical line carries the
    # self entry and lib-b, the continuation line lib-c, and both siblings
    # move: lib-b is the pin the old reader saw, lib-c the one it did not.
    #
    # Falsifiability (observed against `agents` 3a64ddc14, the build before
    # the fix): the reader takes one dependency of the three, the commit
    # succeeds and records a repro.lock the strict TOML reader rejects
    # ("line 10: expected a key, found `,`"), with `{ name = "lib-c"` twice
    # in it.
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var fx = setupSiblingFixture("continuation-repin")
      defer: removeDir(fx.scratch)
      fx.refreshAndPublishLock()
      let canonical = readFile(fx.app / "repro.lock")
      let packagesBefore = linePrefixed(canonical, "packages = ")
      let depsLine = linePrefixed(canonical, "deps = ")
      # The issue's layout: a record on its own line, opened by the
      # separating comma.
      let spread = canonical.replace(depsLine,
        depsLine.replace("}, { name = \"lib-c\"", "}\n, { name = \"lib-c\""))
      check spread.count("\n, { name = \"lib-c\"") == 1
      check depEntry(spread, "lib-c").len > 0
      # The fixture is valid TOML, and the reader takes all of it.
      discard tctoml.parseToml(spread)
      check parseLockedDependencies(spread).deps.len == 3
      writeFile(fx.app / "repro.lock", spread)
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q -m spread-lock")
      fx.installPreCommit()

      let libBNext = fx.advance("lib-b")
      let libCNext = fx.advance("lib-c")
      let c = fx.commitInApp("after-lib-c")
      checkpoint(c.output)
      check c.code == 0
      check "repro.lock" in fx.filesInHead()
      let committed = fx.git(fx.app, "show HEAD:repro.lock")
      checkpoint(committed)
      # It parses as TOML — the whole of what the issue asks of a refresh.
      var parsesAsToml = true
      try: discard tctoml.parseToml(committed)
      except CatchableError as err:
        checkpoint("strict TOML: " & err.msg)
        parsesAsToml = false
      check parsesAsToml
      # Nothing of the old statement is left behind, and nothing is doubled.
      check "\n, { name" notin committed
      check committed.count("{ name = \"lib-c\"") == 1
      check committed.count("{ name = \"lib-b\"") == 1
      let ld = parseLockedDependencies(committed)
      check ld.deps.len == 3
      check ("revision = \"" & libCNext & "\"") in depEntry(committed, "lib-c")
      check ("revision = \"" & libBNext & "\"") in depEntry(committed, "lib-b")
      check linePrefixed(committed, "packages = ") == packagesBefore
      check fx.git(fx.app, "status --porcelain").strip().len == 0
