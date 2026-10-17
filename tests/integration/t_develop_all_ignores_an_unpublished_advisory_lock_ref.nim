## ``repro develop --all`` places a node from its EXACT locked revision, and
## the lock record's advisory ``ref`` can neither help nor veto that.
##
## THE DEFECT THIS PINS. ``cloneNodeAtLockedRevision`` used to hand the lock's
## ``ref`` to ``gitCloneAction`` as its ``revision``, which ``executeClone``
## turns into ``git clone --branch <ref>`` for any value that is not a 40-hex
## commit id. git refuses such a clone outright when the remote does not
## advertise that branch, so an ADVISORY field had a hard veto over a pin the
## remote could serve.
##
## It fired in production. ``codetracer-native-recorder``'s committed
## ``repro.lock`` carries a self-record written on 2026-09-18 whose ``ref`` is
## ``reprolock-declare`` — the LOCAL, never-pushed branch the refresh happened
## to run on, captured before ``resolvePublishedRef`` existed (379e5dbdd,
## "record only published refs"). ``participatingRepoCommittedLocks`` folds a
## repo's self-record into the workspace lock set, where it OUTRANKS the root
## repo's entry for the same repo, so reprobuild's CI step "Reconcile CodeTracer
## source dependencies" (``repro develop --all --reset``) asked GitHub for a
## branch that exists nowhere and the graph made no progress — while the
## revision that same record names is on ``dev`` and fetches fine. The writer is
## fixed; every lock refreshed before that fix still carries the stale field,
## which is why the CONSUMER must not be breakable by it.
##
## Spec: CLI/develop.md ("A revision comes from a lock record or not at all");
## Unified-Locking-And-Hooks.md §3 (the public row: a repo publishes its own
## coordinates); Reprobuild-Lock-Driven-Provisioning-And-Publish-Scope
## .milestones.org §L1.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline). Mirrors
## t_develop_all_clones_deps_at_locked_revisions.nim's shape: real local git
## repos, ``file://`` origins, no network.
##
##   <scratch>/
##     liba.git / liba  — a published dep repo on ``main``; the locked SHA is
##                        an ANCESTOR of the tip, so landing on the pin is a
##                        real event and not the default-branch checkout
##     app.git  / app   — the workspace repo, whose committed ``repro.lock``
##                        pins liba at that SHA with
##                        ``ref = "reprolock-declare"`` — a branch no remote
##                        carries, spelled exactly as the production record
##     ghost/           — a second workspace repo whose lock keeps the same
##                        bogus ``ref`` AND names a revision that does not
##                        exist, to prove the failure path still fails
##     deps/, deps2/    — ``--into`` checkout-placement roots
##
## Asserts:
##   1. ``develop --all --into=<deps>`` exits 0 and reports ``cloned liba @
##      <locked sha>`` although ``ref`` names an unpublished branch.
##   2. ``<deps>/liba`` HEAD is the EXACT locked SHA — not the ``main`` tip the
##      bogus ref would have been resolved against had it existed.
##   3. The run's output never mentions the bogus ref: it played no part.
##   4. An UNOBTAINABLE revision still fails LOUD (exit 1) and is diagnosed as
##      a REVISION problem naming that revision — NOT as the absent branch.
##      The clone-branch-missing reason keeps its job for a manifest that
##      declares a branch (where the branch IS the pin); it must never be the
##      verdict on a lock-pinned placement.
##   5. The failed placement leaves NO checkout behind.
##
## Falsifiability: restore ``revision = cloneBranch`` at the clone and (1), (2)
## and (4) all fail — (1)/(2) with "fatal: Remote branch reprolock-declare not
## found in upstream origin", (4) with the branch diagnosis in place of the
## revision one. Make the clone tolerate an unresolvable pin instead and (4)'s
## exit-1 and (5) fail.
##
## Mocks: none. Real ``git``, real clones, the real ``repro`` binary.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` missing on PATH, or repro unbuilt.

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip
from repro_test_support import fileUrl

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const UnpublishedRef = "reprolock-declare"
  ## The production value, kept literal: this case exists because THIS string
  ## reached a ``git clone --branch``.

const MissingRevision = "0123456789abcdef0123456789abcdef01234567"
  ## Exactly 40 lowercase hex (so ``isExactLockedRevision`` admits it and the
  ## refusal under test is the CLONE's, not the composer's), and an object no
  ## repo has.

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
  ## ``doAssert``, not ``check``: these helpers run outside any ``test`` body,
  ## where ``unittest.check`` cannot see ``testStatusIMPL`` and a failure
  ## prints but still reports ``[OK]``.
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

proc depInline(name, path, url, gitRef, sha, depends: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url &
    "\", ref = \"" & gitRef & "\"" &
    ", revision = \"" & sha & "\", integrity = \"" &
    (if sha.len > 0: "git-sha1:" & sha else: "") &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"" & depends & "\", groups = \"\" }"

proc lockBody(deps: openArray[string]): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
    "[lock]\n" &
    "platform = \"x86_64-linux\"\n" &
    "optimal = true\n" &
    "inputs_digest = \"advisory-ref-fixture\"\n" &
    "variants = []\n" &
    "packages = []\n" &
    "deps = [" & deps.join(", ") & "]\n"

proc seedWorkspaceRepo(gitBin, scratch, name: string):
    tuple[origin, work, sha: string] =
  let host = initPublishedRepo(gitBin, scratch, name)
  writeFile(host.work / "README.md", "advisory-ref fixture\n")
  mustRun(git(gitBin, host.work, "add README.md"), "git add in " & host.work)
  mustRun(git(gitBin, host.work, "commit -m seed"),
    "git commit in " & host.work)
  (origin: host.origin, work: host.work,
   sha: git(gitBin, host.work, "rev-parse HEAD").output.strip())

suite "develop --all ignores an unpublished advisory lock ref":

  test "t_develop_all_ignores_an_unpublished_advisory_lock_ref":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real local git repositories")
    elif not fileExists(reproBinary):
      skip("./build/bin/repro is not built; this case drives the real binary")
    else:
      let repro = absolutePath(reproBinary)
      let scratch = getTempDir() / "develop-advisory-ref-" &
        $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- A published dep repo whose LOCKED SHA is an ancestor of `main`. --
      let liba = initPublishedRepo(gitBin, scratch, "liba")
      writeFile(liba.work / "repro.nim", depRecipe.replace("PKG", "liba"))
      mustRun(git(gitBin, liba.work, "add repro.nim"), "git add liba recipe")
      mustRun(git(gitBin, liba.work, "commit -m liba"), "git commit liba")
      let libaPin = git(gitBin, liba.work, "rev-parse HEAD").output.strip()
      check libaPin.len == 40
      # Advance `main` past the pin, so "landed on the pin" is distinguishable
      # from "landed on whatever branch the clone checked out".
      writeFile(liba.work / "moved.txt", "past the lock\n")
      mustRun(git(gitBin, liba.work, "add moved.txt"), "git add liba move")
      mustRun(git(gitBin, liba.work, "commit -m move"), "git commit liba move")
      mustRun(git(gitBin, liba.work, "push origin main"), "git push liba")
      let libaTip = git(gitBin, liba.work, "rev-parse HEAD").output.strip()
      check libaTip != libaPin

      # The bogus ref is bogus: the origin advertises `main` and nothing else.
      let advertised = run(q(gitBin) & " ls-remote --heads " &
        q(fileUrl(liba.origin))).output
      check UnpublishedRef notin advertised
      check "main" in advertised

      # ---- (1)/(2)/(3) the obtainable pin is placed; ref plays no part. ----
      let app = seedWorkspaceRepo(gitBin, scratch, "app")
      writeFile(app.work / "repro.lock", lockBody([
        depInline("app", ".", fileUrl(app.origin), UnpublishedRef,
          app.sha, "liba"),
        depInline("liba", "liba", fileUrl(liba.origin), UnpublishedRef,
          libaPin, "")]))

      let deps = scratch / "deps"
      let res = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = app.work)
      check res.code == 0
      check ("cloned liba @ " & libaPin) in res.output
      # The advisory ref is not consulted, so it is not reported either.
      check UnpublishedRef notin res.output
      check "not found in upstream" notin res.output

      check dirExists(deps / "liba")
      let placed = git(gitBin, deps / "liba", "rev-parse HEAD").output.strip()
      check placed == libaPin          # the LOCKED SHA
      check placed != libaTip          # not the branch the clone checked out

      # ---- (4)/(5) an unobtainable pin still fails, and says WHY. ----
      # Same bogus ref, but now the revision itself cannot be had. The verdict
      # must be about the REVISION: that is the fact an operator can act on,
      # and conflating it with a missing branch is what sent the CI operator
      # looking for a branch nobody had pinned.
      let ghost = seedWorkspaceRepo(gitBin, scratch, "ghost")
      writeFile(ghost.work / "repro.lock", lockBody([
        depInline("ghost", ".", fileUrl(ghost.origin), UnpublishedRef,
          ghost.sha, "liba"),
        depInline("liba", "liba", fileUrl(liba.origin), UnpublishedRef,
          MissingRevision, "")]))

      let deps2 = scratch / "deps2"
      let bad = run(repro & " develop --all --into=" & q(deps2) &
        " --tool-provisioning=path", cwd = ghost.work)
      check bad.code == 1
      check MissingRevision in bad.output
      # Diagnosed as a revision that could not be obtained, NOT as an absent
      # branch — the old code's answer here named the branch instead.
      check "does not advertise requested checkout branch" notin bad.output
      check UnpublishedRef notin bad.output
      # (5) nothing half-cloned is left behind for the next run to adopt.
      check not dirExists(deps2 / "liba")
