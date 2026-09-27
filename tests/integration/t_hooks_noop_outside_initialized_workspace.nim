## RA-10 — Workspace marker; hooks no-op outside an initialized workspace.
##
## The managed VCS hooks (pre-push gate + post-commit lock refresh) are
## installed per participating repo by ``repro hooks ensure --vcs`` and,
## at git time, dispatch into ``repro hooks dispatch <hook> --repo-root
## <repo> ...`` (pre-push additionally forwards ``--refs-file``). A
## managed hook may end up running under a *half-bootstrapped* or
## *non-workspace* parent — a plain git repo, or a bare ``.repro/`` that
## ``repo init`` left behind before the manifest repo was actually
## checked out. In that case there is nothing to enforce, and the hooks
## MUST no-op with success: they exit 0 and do nothing, never blocking
## the commit/push with a fatal error.
##
## The canonical "initialized workspace" marker is the presence of a
## *resolved manifest checkout* — a ``.repro/workspace.toml`` OR, inside
## the root's ``.repro/`` shell, at least one resolved ``projects/*.toml``
## / ``variants/*.toml`` — NOT merely a bare ``.repro/`` directory, and
## NOT a directory that merely happens to hold manifest-shaped
## subdirectories. The shared predicate ``isInitializedWorkspace``
## (re-exported from ``repro_workspace_manifests``) backs both the
## hook-skip logic and any init-skip logic.
##
## THE FIXTURE PART 4 EXISTS FOR. The three parents Parts 1-3 cover — a
## plain git repo, a half-bootstrapped bare ``.repro/``, and a real
## workspace — all passed while the field failed, because none of them is
## the parent that actually broke: the LOCK RECORD STORE. That store is
## the ``metacraft-manifests`` repo. It carries ``projects/``, ``repos/``
## and ``locks/`` at its TOP LEVEL, it has no ``.repro/workspace.toml``
## and no committed ``repro.lock``, and it is NOT a workspace — it is the
## place a workspace's membership and lock records are kept. Classified
## as a workspace on the strength of those directory names alone, it
## lands in a gap nothing covers: every non-workspace guard is skipped,
## the committed-lock fallback is gated on the same (wrong) answer so it
## is skipped too, no project can be named, and the resolver raises. The
## pre-push gate then exits 1 in a repo that has nothing to gate — and
## because store publication is a STAGE of that gate, that blocks pushes
## in every repo of the workspace. Part 4 is the falsification control
## for exactly that: a real manifests/record-store checkout, real
## installed managed hooks, and a real ``git push`` that must not be
## blocked.
##
## TWO "DO NOTHING" ARMS, AND WHICH ONE ANSWERS. The post-commit handler
## can also stand down because git is mid-rebase / mid-cherry-pick. Both
## arms exit 0 and both file a report, so the ordering between them is
## invisible in the exit code and visible only in the trace — and outside
## a workspace the workspace answer is the true one. Part 2b pins that
## order with a real conflicting cherry-pick.
##
## This suite is falsifiable + hermetic:
##   * Falsifiable — it asserts the EXACT no-op contract (exit 0, the
##     "not a workspace" diagnostic, no lock file written) for genuine
##     non-workspaces AND, by contrast, asserts that a REAL initialized
##     workspace's hooks still RUN (pre-push gate exits 0 only after the
##     actual checks pass; post-commit writes a lock). If the no-op were
##     to fire inside a real workspace, or fail to fire outside one,
##     these checks fail.
##   * Hermetic — every git repo and manifest checkout lives in a fresh
##     tempdir; nothing touches ``$HOME`` or any shared cache.
##
## NO MOCKS. Every repo here is a real git repo, every hook is a real
## managed hook installed by ``repro hooks ensure --vcs``, and Part 4's
## push is a real ``git push`` to a real (local, bare) origin. Nothing
## stubs the filesystem or the git boundary, so nothing can pass because
## a stub agreed with the code under test. Part 4 pins
## ``REPROBUILD_REPRO`` at the binary under test for the same reason: the
## generated hook body resolves ``repro`` from that variable FIRST and
## from ``command -v repro`` second, so a fixture that leaves it unset
## silently exercises whatever ``repro`` happens to be on PATH.
##
## Skip rule: ``git`` missing on PATH (same convention as M17 / M18 /
## M19).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

# ---- helpers --------------------------------------------------------------

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA10 Tester\"")
  writeFile(workPath / "README.md", "RA10 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA10 Tester\"")

proc projectTomlWith3Remotes(libAUrl, libBUrl, libCUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-c-origin\"\nfetch = \"" & libCUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

const libCFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
remote = "lib-c-origin"
revision = "main"
"""

type
  RepoSeed = object
    name: string
    origin: string
    seedPath: string
    sha: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra10-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libA.name = "lib-a"
  result.libA.origin = result.scratch / "origin-lib-a.git"
  result.libA.seedPath = result.scratch / "seed-lib-a"
  result.libA.sha = seedGitOrigin(gitBin, result.libA.origin,
    result.libA.seedPath)
  result.libB.name = "lib-b"
  result.libB.origin = result.scratch / "origin-lib-b.git"
  result.libB.seedPath = result.scratch / "seed-lib-b"
  result.libB.sha = seedGitOrigin(gitBin, result.libB.origin,
    result.libB.seedPath)
  result.libC.name = "lib-c"
  result.libC.origin = result.scratch / "origin-lib-c.git"
  result.libC.seedPath = result.scratch / "seed-lib-c"
  result.libC.sha = seedGitOrigin(gitBin, result.libC.origin,
    result.libC.seedPath)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith3Remotes(
      fileUrl(result.libA.origin),
      fileUrl(result.libB.origin),
      fileUrl(result.libC.origin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-c.toml", libCFragmentToml)
  # The "real workspace still enforces" case asserts a manifest lock RECORD is
  # produced, which happens only where a manifest-backed route is DECLARED
  # (Unified-Locking-And-Hooks.md §10, "No implicit team route"). Make
  # `.repro/manifests` a real git checkout so the route is declared rather than
  # inferred from a path. The no-op cases below are unaffected: they point at
  # directories that are not workspaces at all.
  let lockStore = workspaceRoot / ".repro" / "manifests"
  createDir(lockStore)
  discard requireGit(q(gitBin) & " init -b main " & q(lockStore))
  discard requireGit(q(gitBin) & " -C " & q(lockStore) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(lockStore) &
    " config user.name \"Hooks Noop Tester\"")
  writeFile(lockStore / ".gitkeep", "")
  discard requireGit(q(gitBin) & " -C " & q(lockStore) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(lockStore) &
    " commit -m \"seed lock store\"")
  result.workspaceRoot = workspaceRoot

proc cloneAll(gitBin: string; fx: Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc seedWorkspaceToml(fx: Fixture) =
  writeWorkspaceBranch(fx.workspaceRoot, project = "lib-a", branch = "main")

proc seedManifestsRecordStore(gitBin: string; fx: Fixture; slug: string):
    tuple[origin, path: string] =
  ## A LOCK RECORD STORE checkout, built to the shape the real
  ## ``metacraft-manifests`` repo has and nothing more: a git repo with a
  ## push destination, carrying ``projects/``, ``repos/`` and ``locks/`` at
  ## its TOP LEVEL, and carrying NEITHER a ``.repro/workspace.toml`` NOR a
  ## committed ``repro.lock``. It is deliberately NOT nested under any
  ## workspace, so the workspace walk has no ancestor to escape to and the
  ## classification of THIS directory is the only thing that decides what
  ## the hooks do.
  ##
  ## The project/repo fragments are the same ones the real workspace fixture
  ## uses. That is the point: the store's manifest data is genuinely
  ## resolvable — it is membership for repos that live somewhere ELSE — so
  ## nothing here can be dismissed as malformed manifest content.
  result.origin = fx.scratch / ("origin-" & slug & ".git")
  result.path = fx.scratch / slug
  discard requireGit(q(gitBin) & " init --bare -b main " & q(result.origin))
  discard requireGit(q(gitBin) & " init -b main " & q(result.path))
  discard requireGit(q(gitBin) & " -C " & q(result.path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(result.path) &
    " config user.name \"Record Store Tester\"")
  createDir(result.path / "projects")
  createDir(result.path / "repos")
  createDir(result.path / "locks")
  writeFile(result.path / "projects" / "lib-a.toml",
    projectTomlWith3Remotes(
      fileUrl(fx.libA.origin), fileUrl(fx.libB.origin),
      fileUrl(fx.libC.origin)))
  writeFile(result.path / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(result.path / "repos" / "lib-b.toml", libBFragmentToml)
  writeFile(result.path / "repos" / "lib-c.toml", libCFragmentToml)
  writeFile(result.path / "locks" / ".gitkeep", "")
  discard requireGit(q(gitBin) & " -C " & q(result.path) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(result.path) &
    " commit -m \"seed record store\"")
  discard requireGit(q(gitBin) & " -C " & q(result.path) &
    " remote add origin " & q(result.origin))
  discard requireGit(q(gitBin) & " -C " & q(result.path) &
    " push origin main")

proc invokeEnsure(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "ensure", "--vcs",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeDispatchPostCommit(fx: Fixture; repoRoot: string): CmdResult =
  ## Exact argv the managed post-commit hook body uses.
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "dispatch", "post-commit",
    "--repo-root", repoRoot, "--",
  ]))

proc writeRefsFile(path: string; localRef, localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, localRef & " " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

proc invokeDispatchPrePush(fx: Fixture; repoRoot, refsFile,
                           remoteLocation: string):
    CmdResult =
  ## Exact protocol-v2 argv the managed pre-push hook body uses, including
  ## Git's agreed remote name/location binding after ``--``.
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "dispatch", "pre-push",
    "--protocol=2",
    "--repo-root", repoRoot,
    "--refs-file", refsFile,
    "--", "origin", remoteLocation,
  ]))

proc invokeCheckPrePush(fx: Fixture; workspaceRoot, currentRepo,
                        refsFile: string): CmdResult =
  ## Direct ``repro check --mode=pre-push`` — the body the dispatcher
  ## calls into. We exercise it directly so the no-op decision is
  ## observable independent of the dispatch ``--refs-file`` short-circuit.
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & workspaceRoot,
    "--current-repo=" & currentRepo,
    "--pushed-refs=" & refsFile,
  ]))

proc invokeEnsureAt(fx: Fixture; targetPath: string): CmdResult =
  ## ``repro hooks ensure --vcs <path>`` — the positional form the
  ## generated hook bodies themselves recommend, used here to install the
  ## managed hooks into ONE repo that is not part of any workspace.
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "ensure", "--vcs", targetPath,
  ]))

proc invokeDispatchNonBlocking(fx: Fixture; hookName, repoRoot: string;
                               positional: openArray[string] = []): CmdResult =
  ## Exact argv the managed pre-commit / post-commit / post-merge /
  ## post-checkout hook bodies use: everything after ``--`` is git's own
  ## positional argument list for that hook.
  var argv = @[
    fx.reproBin, "hooks", "dispatch", hookName,
    "--repo-root", repoRoot, "--",
  ]
  for p in positional: argv.add(p)
  runShell(shellCommand(argv))

proc invokeCheckPrePushByWalk(fx: Fixture; currentRepo, refsFile: string):
    CmdResult =
  ## ``repro check --mode=pre-push`` WITHOUT ``--workspace-root``, so the
  ## workspace walk — not the caller — decides what this repo belongs to.
  ## That is the decision the managed hook body actually makes, and the one
  ## that misclassified the record store in the field.
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--current-repo=" & currentRepo,
    "--pushed-refs=" & refsFile,
  ]))

proc postCommitReport(fx: Fixture; workspaceRoot: string): JsonNode =
  let reportPath = workspaceRoot / ".repro" / "build" / "reports" /
    "post-commit-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite -------------------------------------------------------------

suite "RA-10 — hooks no-op outside an initialized workspace":

  test "t_hooks_noop_outside_initialized_workspace":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # WHICH BUILD THE HOOKS RUN. Every generated hook body resolves
      # ``repro`` from ``REPROBUILD_REPRO`` first and from ``command -v
      # repro`` second, and a managed post-commit / post-checkout run
      # re-ensures the repo's hooks — so a fixture that leaves the
      # variable unset hands that re-ensure to whatever ``repro`` is on
      # PATH (here: the pinned store build) and quietly rewrites the very
      # hooks under test with THAT build's contract. Measured while adding
      # Part 4: the store's hooks came back stamped with the pinned
      # build's pre-push contract, the dispatcher then refused the push as
      # a tooling mismatch, and the refusal looked exactly like the gate
      # failure the part is about. Exported once, here, for every child
      # process this case starts.
      putEnv("REPROBUILD_REPRO", reproBinary())
      # ============================================================
      # Part 1 — a genuine NON-workspace: a plain git repo whose parent
      # has NO ``.repro/`` at all. Install the managed hooks against a real
      # workspace first, then point the dispatched hook bodies at a
      # standalone repo that is not under any workspace. The hooks must
      # exit 0 and do nothing.
      # ============================================================
      let fx = setupFixture(gitBin, "noop")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      # Install the real managed hooks (proves the no-op is in the hook
      # COMMAND, not a side effect of skipping installation).
      let ensureRes = invokeEnsure(fx)
      if ensureRes.code != 0:
        checkpoint("ensure output: " & ensureRes.output)
      check ensureRes.code == 0

      # A plain git repo with NO ``.repro/`` anywhere above it.
      let lonePath = fx.scratch / "lone-repo"
      cloneInto(gitBin, fx.libA.origin, lonePath)
      let loneSha = requireGit(q(gitBin) & " -C " & q(lonePath) &
        " rev-parse HEAD").strip()

      # post-commit dispatched under the non-workspace → exit 0, no-op.
      let pcLone = invokeDispatchPostCommit(fx, lonePath)
      check pcLone.code == 0
      # No workspace root is reachable from the lone repo, so no report
      # is written there — and crucially NO lock file is produced.
      check not dirExists(lonePath / ".repro")

      # pre-push body dispatched under the non-workspace → exit 0, no-op,
      # with the clear "not a workspace" diagnostic.
      let loneRefs = fx.scratch / "lone-refs.txt"
      writeRefsFile(loneRefs, "refs/heads/main", loneSha)
      let ppLoneDispatch = invokeDispatchPrePush(fx, lonePath, loneRefs,
        fileUrl(fx.libA.origin))
      check ppLoneDispatch.code == 0
      # Direct ``repro check`` against the lone repo: walks up, finds no
      # ``.repro/`` (falls back to cwd), no resolved manifest checkout →
      # no-op exit 0 + diagnostic. (Falsifiable: before RA-10 this raised
      # a blocking exit 1.)
      let ppLoneCheck = invokeCheckPrePush(fx,
        workspaceRoot = lonePath, currentRepo = lonePath,
        refsFile = loneRefs)
      check ppLoneCheck.code == 0
      check ppLoneCheck.output.contains("not a workspace")

      # ============================================================
      # Part 2 — a HALF-BOOTSTRAPPED parent: a bare ``.repro/`` with NO
      # resolved manifest checkout (no workspace.toml, no projects/*.toml).
      # The canonical marker must reject this and the hooks must no-op.
      # ============================================================
      let halfRoot = fx.scratch / "half-bootstrapped"
      createDir(halfRoot / ".repro")            # bare .repro/, nothing else
      let halfRepo = halfRoot / "lib-a"
      cloneInto(gitBin, fx.libA.origin, halfRepo)
      let halfSha = requireGit(q(gitBin) & " -C " & q(halfRepo) &
        " rev-parse HEAD").strip()

      # post-commit under the half-bootstrapped parent → exit 0,
      # ``skipped-no-workspace`` with the "not a workspace" diagnostic,
      # NO lock file written.
      let pcHalf = invokeDispatchPostCommit(fx, halfRepo)
      check pcHalf.code == 0
      let halfReport = postCommitReport(fx, halfRoot)
      check halfReport["exitCode"].getInt() == 0
      check halfReport["outcome"].getStr() == "skipped-no-workspace"
      check halfReport["lockFilePath"].getStr() == ""
      check halfReport["diagnostic"].getStr().contains("not a workspace")
      # No lock subtree created under the bare ``.repro/``.
      check not dirExists(halfRoot / ".repro" / "manifests")

      # pre-push under the half-bootstrapped parent → exit 0 + diagnostic.
      let halfRefs = fx.scratch / "half-refs.txt"
      writeRefsFile(halfRefs, "refs/heads/main", halfSha)
      let ppHalf = invokeCheckPrePush(fx,
        workspaceRoot = halfRoot, currentRepo = halfRepo,
        refsFile = halfRefs)
      check ppHalf.code == 0
      check ppHalf.output.contains("not a workspace")

      # Part 2b — THE SAME NON-WORKSPACE, CAUGHT MID-OPERATION. The
      # post-commit handler has two "do nothing" arms: "git is mid-rebase,
      # stand down" and "this is not a workspace". Both exit 0 and both
      # leave a trace, so only the trace can tell which one fired — and
      # only the second is the truth here. A non-workspace is not a
      # workspace whose work is deferred; reporting a stand-down invites a
      # retry that will never behave differently and hides the fact that
      # these hooks are installed where they have nothing to do.
      #
      # Real git state, not a fabricated marker: a genuinely conflicting
      # cherry-pick, which is what leaves ``CHERRY_PICK_HEAD`` and the
      # sequencer behind. ``halfRepo`` has no installed hooks (the ensure
      # above targeted the workspace's repos), so nothing fires until the
      # dispatch below.
      writeFile(halfRepo / "README.md", "half: side\n")
      discard requireGit(q(gitBin) & " -C " & q(halfRepo) &
        " checkout -q -b side")
      discard requireGit(q(gitBin) & " -C " & q(halfRepo) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(halfRepo) &
        " commit -m \"side edit\"")
      discard requireGit(q(gitBin) & " -C " & q(halfRepo) &
        " checkout -q main")
      writeFile(halfRepo / "README.md", "half: main\n")
      discard requireGit(q(gitBin) & " -C " & q(halfRepo) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(halfRepo) &
        " commit -m \"main edit\"")
      # Expected to FAIL with a conflict — that is the state under test.
      let pick = runCmd(q(gitBin) & " -C " & q(halfRepo) &
        " cherry-pick side")
      check pick.code != 0
      check fileExists(halfRepo / ".git" / "CHERRY_PICK_HEAD")

      let pcHalfMid = invokeDispatchPostCommit(fx, halfRepo)
      check pcHalfMid.code == 0
      let halfMidReport = postCommitReport(fx, halfRoot)
      # The marker check is asked FIRST, so the verdict is about the
      # workspace, not about git's in-flight operation.
      check halfMidReport["outcome"].getStr() == "skipped-no-workspace"
      check halfMidReport["diagnostic"].getStr().contains("not a workspace")
      check not halfMidReport["diagnostic"].getStr().contains(
        "a git operation is in progress")
      discard requireGit(q(gitBin) & " -C " & q(halfRepo) &
        " cherry-pick --abort")

      # ============================================================
      # Part 3 — CONTRAST: a REAL initialized workspace still ENFORCES.
      # The no-op must fire ONLY for genuine non-workspaces. Here the
      # post-commit writes a lock and the pre-push gate runs the actual
      # checks (and passes only because the fixture is clean + published).
      # ============================================================
      let realRepo = fx.workspaceRoot / "lib-a"
      let pcReal = invokeDispatchPostCommit(fx, realRepo)
      check pcReal.code == 0
      let realReport = postCommitReport(fx, fx.workspaceRoot)
      check realReport["exitCode"].getInt() == 0
      # It RAN the lock refresh — a lock file was written. M19b: the outcome
      # names what happened to that record (this fixture's store has no
      # upstream, so it is local-only) rather than claiming a bare "ok".
      check realReport["outcome"].getStr() == "written-local-only"
      check realReport["lockWritten"].getBool()
      let realLock = realReport["lockFilePath"].getStr()
      check realLock.len > 0
      check fileExists(realLock)
      # The diagnostic is NOT the no-op message.
      check not realReport["diagnostic"].getStr().contains("not a workspace")

      # The real pre-push gate runs the actual checks and does NOT print
      # the no-op diagnostic.
      let realRefs = fx.scratch / "real-refs.txt"
      writeRefsFile(realRefs, "refs/heads/main", fx.libA.sha)
      let ppReal = invokeCheckPrePush(fx,
        workspaceRoot = fx.workspaceRoot, currentRepo = realRepo,
        refsFile = realRefs)
      check ppReal.code == 0
      check not ppReal.output.contains("not a workspace")

      # ============================================================
      # Part 4 — a MANIFESTS / LOCK-RECORD-STORE checkout. See the
      # "THE FIXTURE PART 4 EXISTS FOR" note in this file's header: this
      # is the parent that broke in the field, and the one shape Parts
      # 1-3 do not have. ``projects/`` + ``repos/`` + ``locks/`` at the
      # top level, no ``.repro/workspace.toml``, no committed
      # ``repro.lock``, not nested under any workspace.
      #
      # All five managed hooks must no-op with SUCCESS here, and a real
      # ``git push`` out of it must not be blocked.
      # ============================================================
      let store = seedManifestsRecordStore(gitBin, fx, "manifests-store")

      # The fixture is the shape the claim is about, asserted rather than
      # assumed: manifest-shaped directories present, both workspace
      # markers absent.
      check dirExists(store.path / "projects")
      check dirExists(store.path / "repos")
      check dirExists(store.path / "locks")
      check not fileExists(store.path / ".repro" / "workspace.toml")
      check not fileExists(store.path / "repro.lock")

      # Real managed hooks, installed by the real installer into the store
      # repo itself. Everything below therefore exercises the hook
      # COMMAND, not an absent hook.
      let ensureStore = invokeEnsureAt(fx, store.path)
      if ensureStore.code != 0:
        checkpoint("ensure(store) output: " & ensureStore.output)
      check ensureStore.code == 0
      for hookName in ["pre-commit", "pre-push", "post-commit",
                       "post-merge", "post-checkout"]:
        check fileExists(store.path / ".git" / "hooks" / hookName)

      let storeSha = requireGit(q(gitBin) & " -C " & q(store.path) &
        " rev-parse HEAD").strip()

      # (a) The pre-push GATE. Dispatched the way git dispatches it, and
      # also as the bare ``repro check`` the dispatcher calls into — with
      # NO ``--workspace-root``, so the walk decides. Both must exit 0
      # with the "not a workspace" verdict. This is the falsifiable one:
      # before the fix the walk answered "this IS a workspace", the
      # resolver could name no project, and this exited 1 with
      # "requires either `.repro/workspace.toml` or a <project> argument"
      # — a blocking refusal in a repo with nothing to gate.
      let storeRefs = fx.scratch / "store-refs.txt"
      writeRefsFile(storeRefs, "refs/heads/main", storeSha)
      let ppStoreCheck = invokeCheckPrePushByWalk(fx,
        currentRepo = store.path, refsFile = storeRefs)
      if ppStoreCheck.code != 0:
        checkpoint("check(store) output: " & ppStoreCheck.output)
      check ppStoreCheck.code == 0
      check ppStoreCheck.output.contains("not a workspace")
      check not ppStoreCheck.output.contains("requires either")
      let ppStoreDispatch = invokeDispatchPrePush(fx, store.path, storeRefs,
        store.origin)
      if ppStoreDispatch.code != 0:
        checkpoint("dispatch pre-push(store) output: " &
          ppStoreDispatch.output)
      check ppStoreDispatch.code == 0

      # (b) The four non-blocking hooks. They exit 0 by policy whatever
      # they decide, so the falsifiable assertion is not the code but the
      # DISK: a no-op must leave no ``.repro/`` behind in the store. It is
      # not tidiness — an untracked ``.repro/`` beside the store's tracked
      # files is dirt outside ``locks/``, which is exactly what the lock
      # publisher's dirty guard refuses, permanently, because its own next
      # commit regenerates it.
      check invokeDispatchNonBlocking(fx, "post-commit", store.path).code == 0
      check invokeDispatchNonBlocking(fx, "pre-commit", store.path).code == 0
      check invokeDispatchNonBlocking(fx, "post-merge", store.path,
        ["0"]).code == 0
      check invokeDispatchNonBlocking(fx, "post-checkout", store.path,
        [storeSha, storeSha, "1"]).code == 0
      check not dirExists(store.path / ".repro")

      # (c) The whole point, end to end: a real commit and a real
      # ``git push`` through the real installed pre-push hook.
      # ``REPROBUILD_REPRO`` pins which build the hook body resolves (see
      # the header note) so this cannot pass on a different binary.
      writeFile(store.path / "locks" / "note.txt", "a record\n")
      discard requireGit(q(gitBin) & " -C " & q(store.path) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(store.path) &
        " commit -m \"add a record\"")
      let pushRes = runShell(shellCommand(
        @[gitBin, "-C", store.path, "push", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      if pushRes.code != 0:
        checkpoint("git push(store) output: " & pushRes.output)
      check pushRes.code == 0
      # The push actually landed — a hook that refused would have left the
      # origin behind.
      check requireGit(q(gitBin) & " -C " & q(store.origin) &
        " rev-parse refs/heads/main").strip() ==
        requireGit(q(gitBin) & " -C " & q(store.path) &
          " rev-parse HEAD").strip()
      # Still no workspace state manufactured inside the store.
      check not dirExists(store.path / ".repro")
