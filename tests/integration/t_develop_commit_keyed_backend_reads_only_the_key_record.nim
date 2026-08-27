## W7 (CLI/develop.md §"Which record, for a commit-addressed backend") —
## **a commit-addressed backend contributes the resolved key's record and
## NOTHING ELSE**.
##
##   > Commit-addressed backends (git-checkout `locks/<project>/<repo>/<sha>.toml`)
##   > are keyed by a commit, and the key is **the workspace root repo's
##   > `HEAD`** […] There is no branch-tip fallback: a backend that yields no
##   > record for the resolved key contributes nothing and says so.
##
## DS-5 (`t_develop_at_rev_walks_to_nearest_locked_ancestor`) owns the WALK —
## which commits the key is allowed to reach. This file owns the complementary
## half, which the walk cannot state on its own: what the backend may do with
## every OTHER record it holds. The answer is "nothing", and the reason it needs
## its own case is that the product had two separate ways of reaching those
## records and each one hid the other:
##
##   * `latestLockShas(project)` folds every trigger-keyed candidate in the
##     store, newest-first by Git history, with no ancestry test at all; and
##   * `latestLock(project, <repo>)` takes the newest candidate under one repo's
##     own `locks/<project>/<repo>/` subtree — also with no ancestry test.
##
## Suppressing only the first restores DS-5 to green while the second still
## supplies the workspace ROOT repo's pin from a sibling branch's commit, which
## DS-5 never looks at (the root repo is excluded from the develop set, so it
## has no row). That is measurable, was measured, and is why "DS-5 is green"
## is not evidence for this property. Case (2) below is the assertion that is.
##
## Asserts, over ONE real git-checkout backend in three workspace shapes:
##
##   1. THE KEY'S RECORD IS READ, and its body pins every sibling it names. A
##      partition written once under the root repo's trigger at the root's
##      `HEAD` — the ordinary `repro workspace lock` output for a workspace
##      whose root repo triggered the lock — resolves the sibling. Without this
##      half, "contribute nothing" could be satisfied by contributing nothing
##      ever.
##   2. A RECORD AT ANOTHER COORDINATE IS NOT READ, even when its BODY is
##      correct about the key. The only record in the store is filed under the
##      SIBLING's trigger (`locks/mix/lib/<libSha>.toml`) and its body pins the
##      root repo to exactly the commit under test. It is still not the key's
##      record: the develop key is the root repo's `HEAD`, and a partition
##      anchored at a sibling answers "what did the workspace look like at THAT
##      repo's commit" (Unified-Locking-And-Hooks.md §6 Decision 1 consequence
##      2) — reachable by the consumer keyed on the sibling, and not an answer
##      about the root's commit. The backend therefore contributes NOTHING, the
##      union is empty, and DS-1's one lock-set failure fires.
##   3. THE RULE IS SCOPED TO "A KEY RESOLVED". A workspace whose manifest
##      places NO repo at path `"."` has no commit-addressed key at all, so the
##      project-wide partition read applies unchanged and a sibling named only
##      by ANOTHER repo's trigger-keyed partition still resolves. This is the
##      shape a routed workspace normally has, and it is the reason (2) is a
##      key rule rather than a ban on reading partitions.
##
## Falsifiability / mutation checks. Each was RUN against a rebuilt `repro`,
## and the case named is the one that actually caught it:
##   * *delete the `elif keyedOnly: ""` arm* in `composeDevelopLockSet`'s
##     `backendRev`, so the project-wide fold returns — (2), which then lists
##     `lib` at a revision only a non-key record carries. DS-5 goes red too;
##     the eight contrast `t_develop_*` cases all stay green.
##   * *the REJECTED FIX SHAPE* — that same deletion PLUS reverting
##     `3f86455e`'s project-wide widening of `lockedShaFromStore`, i.e.
##     "narrow to `latestLock(project, repoName)`" — (2) AND (3). (2) because
##     the non-key record sits under `lib`'s own subtree, so the exact-key
##     read serves it anyway; (3) because the widening is what lets a sibling
##     be pinned by another repo's partition at all. DS-5 goes red on its
##     ws-root and exit-code assertions ONLY — exactly the shape it has
##     against a `repro` built from `3f86455e^`, where its original
##     assertions were all green.
##   * *`keyedOnly` always true* (the "a key resolved" half of the scope
##     dropped) — (3) alone in this file, plus four unrelated `t_develop_*`
##     cases whose workspaces declare no repo at `"."`. The collateral IS the
##     argument for the scope. DS-5 stays GREEN under this one, which is
##     precisely why (3) has to exist as its own case.
##   * *`isCommitAddressedLockStore` always false* — (1) and (2). (1) because
##     the key read stops finding the partition and the "holds no lock record"
##     notice appears where an exact hit was asserted.
##
## Mocks: NONE. Real git repositories on the real filesystem, a real manifest
## checkout, a real layer-5 config inside a real ``.git``, the real ``repro``
## binary, the real git-checkout lock backend.
##
## Hermetic: fresh tempdir per case; layers 2 and 3 are silenced via the
## ``REPROBUILD_*_CONFIG`` overrides; layer 5 resolves from the fixture's own
## ``.git/repro/config.toml``. Skip: ``git`` missing or ``repro`` unbuilt.

import std/[os, osproc, strutils, tables, tempfiles, unittest]
from repro_test_support import fileUrl

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check` or `quit`: this is a HELPER, outside any `test`
  ## body. `unittest.check` there cannot see the `testStatusIMPL` the `test`
  ## template injects, so it prints "Check failed" and the case still reports
  ## `[OK]`; `quit 1` tears the process down mid-case, so `unittest` emits no
  ## `[FAILED]` marker and every later case in the file silently never runs.
  ## `doAssert` raises an `AssertionDefect`, which the `test` template's own
  ## `except Exception` catches and reports as a failure from any call depth.
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
    " config user.name \"W7 Tester\"")

proc commitIn(gitBin, repo, name: string): string =
  ## The file BODY carries the repository's own path, never just `name`. A
  ## constant body plus a constant author gives git a constant tree and a
  ## commit timestamp with one-second resolution, so two fixtures seeded inside
  ## the same second produce the SAME sha — and every "these two revisions
  ## differ" assertion downstream passes vacuously. Deriving the body from the
  ## work path makes the collision impossible rather than unlikely.
  writeFile(repo / name, name & "\n" & repo & "\n")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " commit -m " & q(name))
  requireGit(q(gitBin) & " -C " & q(repo) & " rev-parse HEAD").strip()

proc seedOrigin(gitBin, originPath, workPath: string): tuple[first, second: string] =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  let a = commitIn(gitBin, workPath, "one.txt")
  let b = commitIn(gitBin, workPath, "two.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  doAssert a.len == 40 and b.len == 40 and a != b,
    "seeded origin produced degenerate revisions: '" & a & "' '" & b & "'"
  (first: a, second: b)

proc projectToml(remoteUrl: string; repoNames: openArray[string]): string =
  var includes = ""
  for n in repoNames: includes.add("  \"repos/" & n & ".toml\",\n")
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & remoteUrl & "\"\n\n" &
  "includes = [\n" & includes & "]\n"

proc repoFragment(name, path: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & path & "\"\n" &
  "remote = \"lib-origin\"\n" &
  "revision = \"main\"\n"

proc lockBody(pins: openArray[(string, string, string)]): string =
  ## The exact ``reprobuild.workspace.lock.v1`` partition body the git-checkout
  ## backend writes and ``shasFromBody`` reads: a flat ``[[repo]]`` array of
  ## name / path / revision triples. ONE document naming every sibling routed
  ## to the backend (Unified-Locking-And-Hooks.md §6 Decision 1) — there is no
  ## per-sibling duplicate to find, which is precisely why the question "which
  ## coordinate may be read" has to be answered rather than assumed.
  result = "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
    "[lock]\n" &
    "project = \"mix\"\n" &
    "created_at = \"2026-01-01T00:00:00Z\"\n" &
    "created_by = \"w7 fixture\"\n"
  for (name, path, revision) in pins:
    result.add("\n[[repo]]\nname = \"" & name & "\"\npath = \"" & path &
      "\"\nremote = \"lib-origin\"\nrevision = \"" & revision &
      "\"\nbranch = \"main\"\n")

type Fixture = object
  scratch: string
  ws: string
  manifestsRoot: string
  gitBin: string
  repro: string
  originShas: Table[string, tuple[first, second: string]]

proc buildFixture(gitBin, repro: string;
                  repos: openArray[(string, string)]): Fixture =
  ## ``repos`` is a (name, path) list; a path of ``"."`` declares the workspace
  ## ROOT repo, which is what makes a commit-addressed backend keyed on a
  ## commit at all. Every non-root repo gets its own bare origin with TWO
  ## commits, so a record can pin it to a revision its checkout is not at.
  result.gitBin = gitBin
  result.repro = repro
  result.scratch = createTempDir("w7-key-", "")
  result.originShas = initTable[string, tuple[first, second: string]]()
  result.ws = result.scratch / "workspace"
  initGitRepo(gitBin, result.ws)
  result.manifestsRoot = result.ws / ".repro" / "manifests"
  createDir(result.manifestsRoot / "projects")
  createDir(result.manifestsRoot / "repos")

  var names: seq[string]
  var routed: seq[string]
  var anyOrigin = ""
  for (name, path) in repos:
    names.add(name)
    routed.add("\"" & name & "\"")
    writeFile(result.manifestsRoot / "repos" / (name & ".toml"),
      repoFragment(name, path))
    if path != ".":
      let origin = result.scratch / ("origin-" & name & ".git")
      result.originShas[name] =
        seedOrigin(gitBin, origin, result.scratch / ("seed-" & name))
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
        q(result.ws / path))
      if anyOrigin.len == 0: anyOrigin = fileUrl(origin)
  writeFile(result.manifestsRoot / "projects" / "mix.toml",
    projectToml(anyOrigin, names))
  initGitRepo(gitBin, result.manifestsRoot)
  discard requireGit(q(gitBin) & " -C " & q(result.manifestsRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(result.manifestsRoot) &
    " commit -m manifests")

  createDir(result.ws / ".repro")
  writeFile(result.ws / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"mix\"\nbranch = \"main\"\n")
  writeFile(result.ws / ".repro-workspace.toml",
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\nurl = \"https://example.invalid/manifests.git\"\n")
  createDir(result.ws / ".git" / "repro")
  writeFile(result.ws / ".git" / "repro" / "config.toml",
    "schema = \"reprobuild.config.v1\"\n\n" &
    "[locking]\n" &
    "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
    "path = \".repro/manifests\", repos = [" & routed.join(", ") & "] }]\n")

  # ``.repro/manifests`` and every cloned sibling are nested git repos; keep
  # them out of the root repo's index so its own commits stay deterministic.
  var ignore = ".repro/\n"
  for (_, path) in repos:
    if path != ".": ignore.add(path & "/\n")
  writeFile(result.ws / ".gitignore", ignore)

proc publish(f: Fixture; triggerRepo, triggerSha: string;
             pins: openArray[(string, string, string)]) =
  let dir = f.manifestsRoot / "locks" / "mix" / triggerRepo
  createDir(dir)
  writeFile(dir / (triggerSha & ".toml"), lockBody(pins))
  discard requireGit(q(f.gitBin) & " -C " & q(f.manifestsRoot) & " add -A")
  discard requireGit(q(f.gitBin) & " -C " & q(f.manifestsRoot) &
    " commit -m " & q("lock " & triggerRepo & " " & triggerSha))

proc list(f: Fixture): tuple[code: int; output: string] =
  run(f.repro & " develop --list --tool-provisioning=path", cwd = f.ws)

proc rowFor(output, repo: string): string =
  for line in output.splitLines():
    if line.startsWith(repo & " "): return line
  ""

suite "W7: a commit-addressed backend reads the key's record and nothing else":

  setup:
    let gitBin = findExe("git")
    let haveTools = gitBin.len > 0 and fileExists(reproBinary)
    let repro = if haveTools: absolutePath(reproBinary) else: ""

  test "t_develop_commit_keyed_partition_at_the_key_pins_every_sibling":
    if not haveTools:
      skip()
    else:
      var f = buildFixture(gitBin, repro, {"ws-root": ".", "lib": "lib"})
      defer: removeDir(f.scratch)
      putEnv("REPROBUILD_SYSTEM_CONFIG", f.scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", f.scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      let head = commitIn(gitBin, f.ws, "c1.txt")
      let libShas = f.originShas["lib"]
      # ONE partition, written under the ROOT repo's trigger at the key itself,
      # naming both repos. This is the ordinary shape.
      f.publish("ws-root", head,
        [("ws-root", ".", head), ("lib", "lib", libShas.first)])

      let res = f.list()
      if res.code != 0:
        checkpoint("develop --list output: " & res.output)
      check res.code == 0
      # The key was hit exactly, so there is no ancestry notice at all.
      check "nearest locked ancestor" notin res.output
      check "holds no lock record for" notin res.output
      check ("[keyed on " & head & "]") in res.output
      # The sibling's pin came out of the partition's BODY: there is no
      # `locks/mix/lib/…` record anywhere in this store.
      check libShas.first in rowFor(res.output, "lib")
      check libShas.second notin rowFor(res.output, "lib")

  test "t_develop_commit_keyed_backend_ignores_a_record_at_another_coordinate":
    if not haveTools:
      skip()
    else:
      var f = buildFixture(gitBin, repro, {"ws-root": ".", "lib": "lib"})
      defer: removeDir(f.scratch)
      putEnv("REPROBUILD_SYSTEM_CONFIG", f.scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", f.scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      let head = commitIn(gitBin, f.ws, "c1.txt")
      let libShas = f.originShas["lib"]
      # The ONLY record in the store is filed under the SIBLING's trigger, at
      # the sibling's own commit. Its BODY is not wrong about anything — it
      # even pins the root repo to the very commit under test — but it is not
      # the record the develop key names, and nothing may make it one.
      f.publish("lib", libShas.second,
        [("ws-root", ".", head), ("lib", "lib", libShas.second)])

      let res = f.list()
      checkpoint("develop --list output: " & res.output)
      # "a backend that yields no record for the resolved key contributes
      # nothing AND SAYS SO" — both halves are asserted, because the defect
      # this case exists for printed the sentence and then contributed anyway.
      check ("holds no lock record for " & head) in res.output
      check "nor for any first-parent ancestor" in res.output
      check "there is no branch-tip fallback" in res.output
      check rowFor(res.output, "lib").len == 0
      check libShas.second notin res.output
      # Both routed repos are NAMED as contributing nothing — including the
      # root repo, which has no `--list` row of its own and is therefore where
      # a partial fix hides.
      check "lib (tier=team backend=git-checkout)" in res.output
      check "ws-root (tier=team backend=git-checkout)" in res.output
      # Nothing contributed, so the union is empty, which CLI/develop.md
      # §"Composing the lock set" makes the one lock-set failure.
      check res.code == 1
      check "is EMPTY" in res.output

  test "t_develop_without_a_root_repo_keeps_the_project_wide_partition_read":
    if not haveTools:
      skip()
    else:
      var f = buildFixture(gitBin, repro, {"alpha": "alpha", "beta": "beta"})
      defer: removeDir(f.scratch)
      putEnv("REPROBUILD_SYSTEM_CONFIG", f.scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", f.scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      discard commitIn(gitBin, f.ws, "c1.txt")
      let alphaShas = f.originShas["alpha"]
      let betaShas = f.originShas["beta"]
      # No manifest entry places a repo at ``.``, so nothing keys this backend
      # on a commit and it is not commit-addressed IN THIS WORKSPACE. The one
      # partition is filed under `alpha`'s trigger and names `beta` too; the
      # project-wide read is the only thing that can find `beta`'s pin, and
      # suppressing it here would delete the routed-partition behaviour this
      # rule exists to preserve.
      f.publish("alpha", alphaShas.second,
        [("alpha", "alpha", alphaShas.first),
         ("beta", "beta", betaShas.first)])

      let res = f.list()
      if res.code != 0:
        checkpoint("develop --list output: " & res.output)
      check res.code == 0
      check alphaShas.first in rowFor(res.output, "alpha")
      check betaShas.first in rowFor(res.output, "beta")
      check "there is no branch-tip fallback" notin res.output
