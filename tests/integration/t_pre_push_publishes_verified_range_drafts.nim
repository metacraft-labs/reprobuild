## A push publishes the verified drafts of the commits below its tip.
##
## The rule under test. The managed ``post-commit`` hook files an untracked
## draft ``locks/<project>/<repo>/<sha>.toml`` in the record store for every
## commit. The pre-push gate used to anchor and publish only the record of the
## pushed tip, so a push that carried several commits published source for all
## of them and a record for one. The drafts of the others were never published
## (nothing anchored them) and never swept (a remote branch reached their
## commits, so they were not orphans). They stayed untracked for good, and the
## commits they describe stayed published with no record that sibling
## resolution can read.
##
## Now the gate also anchors each untracked draft of the pushed repo whose
## commit is a proper ancestor of the pushed tip, provided the draft passes
## publication verification: it parses as a workspace lock of this project,
## its entry for the pushed repo names the key commit, and every other
## revision it pins is reachable from a remote-tracking ref of that repo's
## checkout in this workspace. A draft that passes is published byte for byte
## with the tip. A draft that fails stays a draft, is reported, never fails the
## push, and is examined again by the next push of the repo. A draft whose key
## is already published upstream is never rewritten: identical bytes are a
## no-op, different bytes leave the published record alone and are reported.
## The gate never writes a record for a commit that has no draft.
##
## The ``post-commit`` publication probe follows the same rule. A pushed
## commit's draft that sits below a published record is HELD (verification
## kept it back, or an older build left it); only a pushed commit with no
## published record at or above it on the upstream is STRANDED, the one state
## that says publication is not running. The probe bounds the drafts it
## inspects, not the published records beside them, and marks every count it
## truncated with ``+``.
##
## Topology. Two unrelated repos, ``app`` and ``lib``, each with a local bare
## upstream, in one workspace whose ``.repro/manifests`` is both the manifest
## layer and the record store, with its own bare upstream and
## ``publish_locks = true``. ``repro hooks ensure --vcs`` installs the real
## generated hooks in every checkout and in the store, and every git process
## runs them with ``REPROBUILD_REPRO`` naming the ``repro`` under test: commits
## fire the real ``post-commit`` (which writes the drafts), pushes fire the
## real ``pre-push`` gate (which publishes). The only commits that do not run
## the hooks are the ones a case makes without hooks on purpose (a commit with
## no draft, a push that went out without the gate), and the bulk commits the
## probe cases create with ``git commit-tree``, whose drafts the case writes
## itself. Those are fixtures for a state the probe must classify, not
## substitutes for the code under test.
##
## Cases and what each asserts:
##
##   1. A three-commit push publishes three records; the two range records are
##      byte-identical to the drafts ``post-commit`` wrote, and the store keeps
##      no untracked draft of the pushed repo.
##   2. A range draft pinning a ``lib`` revision that no remote-tracking ref
##      of ``lib`` reaches stays untracked and is named in the push output;
##      the push succeeds. Once ``lib`` is pushed, the next push of ``app``
##      publishes that draft unchanged.
##   3. A range draft at a key another workspace already published with
##      DIFFERENT bytes leaves the published record untouched, and one at a
##      key published with IDENTICAL bytes is a no-op; the push succeeds and
##      the conflict is named.
##   4. A draft whose commit the pushed tip does not reach (a side branch) is
##      not published.
##   5. No record is written for a range commit that has no draft.
##   6. Probe: published records do not consume the scan bound; a draft held
##      below a published tip is counted as held, a pushed commit with no
##      published record at or above it as stranded; a truncated scan marks
##      every count with ``+``.
##
## Falsifiability. Against the tip-only gate, case 1 finds the two range
## records missing upstream and their drafts still untracked; case 2 never
## sees the held draft published; case 3 fails the push (the untracked drafts
## at published keys stop the record store's replay onto its upstream). Against
## the old probe, case 6 reads the held draft as stranded, has no held count,
## and counts published records toward its bound (a ``+`` on a one-draft
## backlog).
##
## Platform: POSIX hosts with git (the generated hooks are shell scripts).
## Nothing is mocked: real git, real hooks, the real ``repro`` binary, local
## bare remotes and the real filesystem. Skips only when git is missing.

import std/[json, os, sequtils, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_test_support/process_fixtures
import repro_workspace_manifests

const ProbeScanBound = 256
  ## The probe's documented bound (``PostCommitBacklogScanLimit``). The probe
  ## cases create more drafts than this on purpose.

type
  Fixture = object
    scratch, workspace, store, storeBare, reproBin: string
    app, lib, appBare, libBare: string
    noHooks: string ## an empty hooks directory, for the hook-less fixtures

proc root(): string = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(root() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc hookEnv(fx: Fixture): seq[tuple[name, value: string]] =
  ## Every git process the cases start runs the installed hooks through the
  ## binary under test, never through whatever ``repro`` the host has on PATH.
  @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]

proc git(fx: Fixture; args: varargs[string]): CmdResult =
  let gitBin = findExe("git")
  result = runShell(shellCommand(@[gitBin] & @args, fx.hookEnv()))

proc must(fx: Fixture; args: varargs[string]): string =
  let res = fx.git(args)
  if res.code != 0:
    raise newException(OSError, "git " & @args.join(" ") & " exited " &
      $res.code & ":\n" & res.output)
  res.output.strip()

proc configIdentity(fx: Fixture; repo: string) =
  discard fx.must("-C", repo, "config", "user.email", "tester@example.invalid")
  discard fx.must("-C", repo, "config", "user.name", "Range Draft Tester")
  discard fx.must("-C", repo, "config", "commit.gpgsign", "false")

proc seedUpstream(fx: Fixture; bare, seedDir, label: string) =
  discard fx.must("init", "--bare", "-b", "main", bare)
  discard fx.must("init", "-b", "main", seedDir)
  fx.configIdentity(seedDir)
  writeFile(seedDir / "README.md", label & " seed\n")
  discard fx.must("-C", seedDir, "add", "README.md")
  discard fx.must("-C", seedDir, "commit", "-m", "seed " & label)
  discard fx.must("-C", seedDir, "remote", "add", "origin", bare)
  discard fx.must("-C", seedDir, "push", "origin", "main")

proc projectToml(fx: Fixture): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" & fileUrl(fx.appBare) &
    "\"\n\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & fileUrl(fx.libBare) &
    "\"\n\n" &
    "includes = [\"repos/app.toml\", \"repos/lib.toml\"]\n"

proc repoToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nmainline = \"main\"\n"

proc setup(slug: string): Fixture =
  result.scratch = createTempDir("repro-range-drafts-" & slug & "-", "")
  releaseDirAtProcessExit(result.scratch)
  result.reproBin = reproBinary()
  result.workspace = result.scratch / "workspace"
  result.store = result.workspace / ".repro" / "manifests"
  result.storeBare = result.scratch / "store.git"
  result.appBare = result.scratch / "app.git"
  result.libBare = result.scratch / "lib.git"
  result.app = result.workspace / "app"
  result.lib = result.workspace / "lib"
  result.noHooks = result.scratch / "no-hooks"
  createDir(result.noHooks)
  result.seedUpstream(result.appBare, result.scratch / "seed-app", "app")
  result.seedUpstream(result.libBare, result.scratch / "seed-lib", "lib")

  createDir(result.store / "projects")
  createDir(result.store / "repos")
  writeFile(result.store / "projects" / "app.toml", result.projectToml())
  writeFile(result.store / "repos" / "app.toml", repoToml("app"))
  writeFile(result.store / "repos" / "lib.toml", repoToml("lib"))
  discard result.must("init", "--bare", "-b", "main", result.storeBare)
  discard result.must("init", "-b", "main", result.store)
  result.configIdentity(result.store)
  discard result.must("-C", result.store, "add", "projects", "repos")
  discard result.must("-C", result.store, "commit", "-m", "seed manifest")
  discard result.must("-C", result.store, "remote", "add", "origin",
    result.storeBare)
  discard result.must("-C", result.store, "push", "-u", "origin", "main")

  for (bare, dir) in [(result.appBare, result.app),
      (result.libBare, result.lib)]:
    discard result.must("clone", "--branch", "main", fileUrl(bare), dir)
    result.configIdentity(dir)
  writeWorkspaceBranch(result.workspace, project = "app", branch = "main")
  writeFile(result.workspace / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[records]\n" &
    "url = \"" & fileUrl(result.storeBare) & "\"\n" &
    "branch = \"main\"\n" &
    "publish_locks = true\n")
  # The real generated hooks, in every participating checkout and in the store.
  for target in [result.workspace, result.store]:
    let ensured = runShell(shellCommand(@[result.reproBin, "hooks", "ensure",
      "--vcs", "--workspace-root=" & target], result.hookEnv()))
    if ensured.code != 0:
      raise newException(OSError, "repro hooks ensure --vcs for " & target &
        " failed:\n" & ensured.output)

proc draftRel(repo, sha: string): string =
  "locks/app/" & repo & "/" & sha & ".toml"

proc draftPath(fx: Fixture; repo, sha: string): string =
  fx.store / draftRel(repo, sha).replace('/', DirSep)

proc commitIn(fx: Fixture; repo, label: string): string =
  ## One commit through the real hooks: ``post-commit`` drafts it.
  writeFile(repo / (label & ".txt"), label & "\n")
  discard fx.must("-C", repo, "add", label & ".txt")
  discard fx.must("-C", repo, "commit", "-m", label)
  fx.must("-C", repo, "rev-parse", "HEAD")

proc commitWithoutHooks(fx: Fixture; repo, label: string): string =
  ## A commit no hook sees, so no draft is ever written for it.
  writeFile(repo / (label & ".txt"), label & "\n")
  discard fx.must("-C", repo, "add", label & ".txt")
  discard fx.must("-C", repo, "-c", "core.hooksPath=" & fx.noHooks, "commit",
    "-m", label)
  fx.must("-C", repo, "rev-parse", "HEAD")

proc push(fx: Fixture; repo: string): CmdResult =
  ## A raw ``git push``: the real managed ``pre-push`` gate runs and publishes.
  result = fx.git("-C", repo, "push", "origin", "main")
  checkpoint("push of " & repo & " (exit " & $result.code & "):\n" &
    result.output)

proc pushWithoutGate(fx: Fixture; repo: string) =
  ## A push that went out without the gate: the state a stranded record
  ## describes.
  discard fx.must("-C", repo, "push", "--no-verify", "origin", "main")

proc upstreamRecord(fx: Fixture; rel: string): tuple[found: bool;
    body: string] =
  let res = fx.git("-C", fx.storeBare, "show", "main:" & rel)
  (res.code == 0, if res.code == 0: res.output else: "")

proc upstreamBlobBytes(fx: Fixture; rel: string): string =
  ## The exact bytes, read through ``cat-file`` so nothing trims them.
  let blob = fx.must("-C", fx.storeBare, "rev-parse", "main:" & rel)
  let res = runShell(shellCommand(@[findExe("git"), "-C", fx.storeBare,
    "cat-file", "blob", blob]))
  check res.code == 0
  res.output

proc untrackedDrafts(fx: Fixture; repo: string): seq[string] =
  let res = fx.must("-C", fx.store, "ls-files", "--others", "--",
    "locks/app/" & repo)
  res.splitLines().filterIt(it.strip().len > 0)

proc makeCommitsWithoutHooks(fx: Fixture; repo: string; count: int;
    label: string): seq[string] =
  ## ``count`` commits on ``repo``'s ``main`` made with ``git commit-tree``,
  ## oldest first. The tree never changes, so the checkout stays clean.
  var parent = fx.must("-C", repo, "rev-parse", "HEAD")
  let tree = fx.must("-C", repo, "rev-parse", "HEAD^{tree}")
  for i in 1 .. count:
    parent = fx.must("-C", repo, "commit-tree", tree, "-p", parent, "-m",
      label & " " & $i)
    result.add(parent)
  discard fx.must("-C", repo, "update-ref", "refs/heads/main", parent)
  discard fx.must("-C", repo, "reset", "--hard", "-q", parent)

proc postCommitReport(fx: Fixture): JsonNode =
  parseFile(fx.workspace / ".repro" / "build" / "reports" /
    "post-commit-report.json")

template withGit(body: untyped) =
  if findExe("git").len == 0:
    skip("git not on PATH; this case needs real repositories and hooks")
  else:
    body

suite "a push publishes the verified drafts of the commits below its tip":

  test "a three-commit push publishes three records, the range ones byte-identical to their drafts":
    withGit:
      let fx = setup("three")
      let c1 = fx.commitIn(fx.app, "c1")
      let c2 = fx.commitIn(fx.app, "c2")
      let c3 = fx.commitIn(fx.app, "c3")
      # Positive control: post-commit really drafted every commit.
      for sha in [c1, c2, c3]:
        check fileExists(fx.draftPath("app", sha))
      let draft1 = readFile(fx.draftPath("app", c1))
      let draft2 = readFile(fx.draftPath("app", c2))

      let pushed = fx.push(fx.app)
      check pushed.code == 0

      for sha in [c1, c2, c3]:
        check fx.upstreamRecord(draftRel("app", sha)).found
      if fx.upstreamRecord(draftRel("app", c1)).found:
        check fx.upstreamBlobBytes(draftRel("app", c1)) == draft1
      if fx.upstreamRecord(draftRel("app", c2)).found:
        check fx.upstreamBlobBytes(draftRel("app", c2)) == draft2
      # Nothing of the pushed repo is left behind as debris.
      check fx.untrackedDrafts("app").len == 0

  test "a range draft pinning an unpublished sibling revision is held, reported, and published by a later push":
    withGit:
      let fx = setup("held")
      # lib moves to a commit no remote has; app's next commits pin it.
      let lib1 = fx.commitIn(fx.lib, "lib1")
      let a1 = fx.commitIn(fx.app, "a1")
      let a2 = fx.commitIn(fx.app, "a2")
      check fileExists(fx.draftPath("app", a1))
      let draftA1 = readFile(fx.draftPath("app", a1))
      check lib1 in draftA1

      let first = fx.push(fx.app)
      check first.code == 0
      # The tip is published as before; the range draft is held back.
      check fx.upstreamRecord(draftRel("app", a2)).found
      check not fx.upstreamRecord(draftRel("app", a1)).found
      check draftRel("app", a1) in fx.untrackedDrafts("app")
      check readFile(fx.draftPath("app", a1)) == draftA1
      # ...and the push said which draft and why.
      check draftRel("app", a1) in first.output
      check lib1 in first.output

      # Once lib's revision is on its remote, the next push of app retries the
      # held draft and publishes it unchanged.
      check fx.push(fx.lib).code == 0
      let a3 = fx.commitIn(fx.app, "a3")
      let second = fx.push(fx.app)
      check second.code == 0
      check fx.upstreamRecord(draftRel("app", a3)).found
      check fx.upstreamRecord(draftRel("app", a1)).found
      if fx.upstreamRecord(draftRel("app", a1)).found:
        check fx.upstreamBlobBytes(draftRel("app", a1)) == draftA1
      check fx.untrackedDrafts("app").len == 0

  test "a range draft at an already-published key never rewrites the published record":
    withGit:
      let fx = setup("published-key")
      let b0 = fx.commitIn(fx.app, "b0")
      let b1 = fx.commitIn(fx.app, "b1")
      let b2 = fx.commitIn(fx.app, "b2")
      let draftB0 = readFile(fx.draftPath("app", b0))
      let draftB1 = readFile(fx.draftPath("app", b1))

      # Another workspace publishes records at b0 (the same bytes) and at b1
      # (different bytes) before this store has fetched them.
      let other = fx.scratch / "other-store"
      discard fx.must("clone", "--branch", "main", fileUrl(fx.storeBare), other)
      fx.configIdentity(other)
      let otherB1 = draftB1 & "# filed by another workspace\n"
      createDir(other / "locks" / "app" / "app")
      writeFile(other / draftRel("app", b0).replace('/', DirSep), draftB0)
      writeFile(other / draftRel("app", b1).replace('/', DirSep), otherB1)
      discard fx.must("-C", other, "add", "locks")
      discard fx.must("-C", other, "-c", "core.hooksPath=" & fx.noHooks,
        "commit", "-m", "publish from another workspace")
      discard fx.must("-C", other, "-c", "core.hooksPath=" & fx.noHooks,
        "push", "origin", "main")

      let pushed = fx.push(fx.app)
      check pushed.code == 0
      # The published records are untouched, and the tip is published.
      check fx.upstreamBlobBytes(draftRel("app", b1)) == otherB1
      check fx.upstreamBlobBytes(draftRel("app", b0)) == draftB0
      check fx.upstreamRecord(draftRel("app", b2)).found
      # The conflict is named.
      check draftRel("app", b1) in pushed.output
      # The store checkout now carries the published records, not the drafts.
      check fx.untrackedDrafts("app").len == 0

  test "a draft whose commit the pushed tip does not reach is not published":
    withGit:
      let fx = setup("side")
      discard fx.must("-C", fx.app, "checkout", "-q", "-b", "side")
      let s1 = fx.commitIn(fx.app, "s1")
      discard fx.must("-C", fx.app, "checkout", "-q", "main")
      let m1 = fx.commitIn(fx.app, "m1")
      let m2 = fx.commitIn(fx.app, "m2")
      check fileExists(fx.draftPath("app", s1))
      check fx.push(fx.app).code == 0
      check fx.upstreamRecord(draftRel("app", m1)).found
      check fx.upstreamRecord(draftRel("app", m2)).found
      check not fx.upstreamRecord(draftRel("app", s1)).found
      check draftRel("app", s1) in fx.untrackedDrafts("app")

  test "no record is written for a range commit that has no draft":
    withGit:
      let fx = setup("no-draft")
      let n1 = fx.commitWithoutHooks(fx.app, "n1")
      check not fileExists(fx.draftPath("app", n1))
      let n2 = fx.commitIn(fx.app, "n2")
      let n3 = fx.commitIn(fx.app, "n3")
      check fx.push(fx.app).code == 0
      check fx.upstreamRecord(draftRel("app", n2)).found
      check fx.upstreamRecord(draftRel("app", n3)).found
      check not fx.upstreamRecord(draftRel("app", n1)).found
      check not fileExists(fx.draftPath("app", n1))

  test "the post-commit probe tells held drafts from stranded ones and bounds only the drafts":
    withGit:
      let fx = setup("probe")
      # ---- published records do not consume the scan bound -----------------
      # More than the bound of commits, each with a VALID draft (the template
      # is a real post-commit draft with its key commit substituted), pushed
      # through the gate, which publishes every one of them.
      let r = fx.commitIn(fx.app, "template")
      let draftOfR = readFile(fx.draftPath("app", r))
      check r in draftOfR
      let bulk = fx.makeCommitsWithoutHooks(fx.app, ProbeScanBound + 20,
        "bulk")
      for sha in bulk:
        writeFile(fx.draftPath("app", sha), draftOfR.replace(r, sha))
      check fx.push(fx.app).code == 0
      check fx.untrackedDrafts("app").len == 0
      let published = fx.must("-C", fx.storeBare, "ls-tree", "--name-only",
        "main", "locks/app/app/").splitLines().filterIt(it.len > 0)
      check published.len > ProbeScanBound
      let afterBulk = fx.commitIn(fx.app, "after-bulk")
      let quiet = fx.postCommitReport()
      checkpoint("report after bulk publication: " & $quiet)
      check quiet["pendingRecords"].getInt() == 1
      check quiet{"backlogTruncated"}.getBool(true) == false
      check quiet["strandedRecords"].getInt() == 0
      check quiet{"heldRecords"}.getInt(-1) == 0
      check "+" notin quiet["diagnostic"].getStr()

      # ---- held below a published tip vs stranded above it ------------------
      let lib1 = fx.commitIn(fx.lib, "lib1")
      let h1 = fx.commitIn(fx.app, "h1") # pins lib1: verification holds it
      discard fx.commitIn(fx.app, "h2")  # the tip: published
      check lib1 in readFile(fx.draftPath("app", h1))
      check fx.push(fx.app).code == 0
      check draftRel("app", h1) in fx.untrackedDrafts("app")
      let s1 = fx.commitIn(fx.app, "s1")
      fx.pushWithoutGate(fx.app)          # s1 went out without its record
      discard fx.commitIn(fx.app, "z1")   # post-commit probes the backlog
      let mixed = fx.postCommitReport()
      checkpoint("report with one held and one stranded draft: " & $mixed)
      # after-bulk went out below h2 with a valid draft, so the gate published
      # it. h1 (held below the published h2), s1 (pushed, nothing published at
      # or above it) and z1 (not pushed) are the backlog.
      check fx.upstreamRecord(draftRel("app", afterBulk)).found
      check draftRel("app", s1) in fx.untrackedDrafts("app")
      check mixed["pendingRecords"].getInt() == 3
      check mixed["strandedRecords"].getInt() == 1
      check mixed{"heldRecords"}.getInt(-1) == 1
      check mixed{"backlogTruncated"}.getBool(true) == false
      check "ALREADY-PUSHED" in mixed["diagnostic"].getStr()
      check "held" in mixed["diagnostic"].getStr()

      # ---- a truncated scan marks every count -------------------------------
      # More than the bound of drafts the gate holds back (each names the
      # template commit, not its key, as the pushed repo's revision), pushed
      # through the gate; then a few more pushed without it, so the backlog
      # holds both held and stranded drafts.
      let heldBulk = fx.makeCommitsWithoutHooks(fx.app, ProbeScanBound + 10,
        "held")
      for sha in heldBulk:
        writeFile(fx.draftPath("app", sha), draftOfR)
      check fx.push(fx.app).code == 0
      let strandedBulk = fx.makeCommitsWithoutHooks(fx.app, 40, "stranded")
      for sha in strandedBulk:
        writeFile(fx.draftPath("app", sha), draftOfR)
      fx.pushWithoutGate(fx.app)
      discard fx.commitIn(fx.app, "z2")
      let truncated = fx.postCommitReport()
      checkpoint("report over a truncated scan: " & $truncated)
      check truncated{"backlogTruncated"}.getBool(false)
      check truncated["pendingRecords"].getInt() == ProbeScanBound
      check truncated["strandedRecords"].getInt() > 0
      check truncated{"heldRecords"}.getInt(-1) > 0
      let diagnostic = truncated["diagnostic"].getStr()
      check ($ProbeScanBound & "+ unpublished") in diagnostic
      check ($truncated["strandedRecords"].getInt() & "+ of them") in
        diagnostic
      check ($truncated{"heldRecords"}.getInt(-1) & "+ held") in diagnostic
