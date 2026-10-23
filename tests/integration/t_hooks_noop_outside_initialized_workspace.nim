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
## arms exit 0 and both leave a trace, so the ordering between them is
## invisible in the exit code and visible only in the trace — and outside
## a workspace the workspace answer is the true one. Part 2b pins that
## order with a real conflicting cherry-pick.
##
## AND NEITHER ARM WRITES INSIDE A NON-WORKSPACE. The trace for the
## non-workspace verdict is a stderr line, not a file: the report writers
## ``createDir`` recursively, so filing a report at a disclaimed root
## CREATES the ``.repro/`` that ``hasResolvedManifestCheckout`` — beside a
## resolved ``projects/*.toml`` — reads as an initialized workspace. That is
## the misclassification Part 4 exists for, and a hook that files its own
## "this is not a workspace" verdict into the root manufactures the marker
## that overturns it on the next run. The fifth case in this file asserts
## that property against a real ``git commit`` through the real installed
## hooks, and asserts its companion: a report is still written for a
## genuine workspace.
##
## AND A STORE THAT ALREADY HAS A ``.repro/`` IS STILL A STORE. Part 4's store
## has no ``.repro/``; the field store had one, left by an older engine that
## filed its hook reports into ``.repro/workspace/``. The sixth case pins the
## rule that keeps it a store — membership beside a top-level ``locks/``, with
## no settings or state file, is the record store — through real commits
## (including one ending a conflicting cherry-pick), the real pre-push gate, a
## real push, and real publication into the store.
##
## This suite is falsifiable + hermetic:
##   * Falsifiable — it asserts the EXACT no-op contract (exit 0, the
##     "not a workspace" diagnostic on stderr, no lock file written, and no
##     directory created inside the disclaimed root) for genuine
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

import std/[algorithm, json, os, osproc, streams, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
import repro_workspace_manifests
from repro_core/workspace_root import workspaceMarkerIn, discoverWorkspaceRoot,
  WorkspaceRootMarker
from git_tool import ensureGitToolResolvable, tpmPathOnly
from repro_cli_support import publishWorkspaceLock, LockPublishOutcome,
  newGitCheckoutLockStore
import repro_lock_store
import repro_cli_support/push_hook_protocol

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

proc stageGitSymlink(gitBin, repoPath, relPath, target, blobPath: string) =
  ## The guard reads committed trees. Stage an actual mode-120000 Git entry
  ## without requiring host symlink privileges (Windows Developer Mode/admin).
  writeFile(blobPath, target)
  let blob = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " hash-object -w " & q(blobPath)).strip()
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " update-index --add --cacheinfo " & q("120000," & blob & "," & relPath))

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

proc reproShellListing(root: string): seq[string] =
  ## Every path under ``<root>/.repro``, root-relative and sorted. "" for a
  ## root with no ``.repro/`` at all, which is distinct from a root whose
  ## shell is empty — the difference the no-op contract turns on.
  result = @[]
  let shell = root / ".repro"
  if not dirExists(shell):
    return
  for path in walkDirRec(shell, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}):
    result.add(relativePath(path, root))
  sort(result)

proc porcelain(gitBin, repo: string): string =
  ## ``git status --porcelain`` with untracked files listed INDIVIDUALLY.
  ## The default collapses a wholly-untracked directory to one ``?? dir/``
  ## entry, which would report the same string whether a stood-down hook
  ## added files inside an already-untracked ``.repro/`` or not.
  requireGit(q(gitBin) & " -C " & q(repo) &
    " status --porcelain --untracked-files=all").strip()

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
      # ``skipped-no-workspace`` with the "not a workspace" diagnostic ON
      # STDERR, and NOTHING WRITTEN INSIDE THE NON-WORKSPACE.
      #
      # The trace used to be a JSON report + log filed in this bare
      # ``.repro/``. It is stderr now, and the change is not cosmetic: the
      # writers ``createDir`` recursively, so that report is how a root
      # acquires the ``.repro/`` that ``hasResolvedManifestCheckout`` reads —
      # beside a resolved ``projects/*.toml`` — as an initialized workspace.
      # A hook cannot be allowed to manufacture the marker that makes the
      # next run overturn its own verdict; the record store in Part 4 is
      # exactly the shape that pair of facts misclassifies. Git relays a
      # commit hook's stderr to the terminal, so the diagnostic reaches a
      # human rather than a file inside a repo nobody considers a workspace.
      let pcHalf = invokeDispatchPostCommit(fx, halfRepo)
      check pcHalf.code == 0
      check pcHalf.output.contains("skipped-no-workspace")
      check pcHalf.output.contains("not a workspace")
      # The bare shell is exactly as bare as it was: no report tree, no lock
      # subtree, nothing at all.
      check reproShellListing(halfRoot).len == 0
      check not dirExists(halfRoot / ".repro" / "build")
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
      # The marker check is asked FIRST, so the verdict is about the
      # workspace, not about git's in-flight operation. Read from stderr for
      # the reason given at Part 2: neither arm may file anything here.
      check pcHalfMid.output.contains("skipped-no-workspace")
      check pcHalfMid.output.contains("not a workspace")
      check not pcHalfMid.output.contains("a git operation is in progress")
      check reproShellListing(halfRoot).len == 0
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
      check not fileExists(store.path / ".repro" / "workspace-state.toml") and
        not fileExists(store.path / ".repro" / "workspace.toml")
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

  test "t_workspace_init_records_the_marker_even_with_no_branch_to_record":
    ## THE MARKER IS RECORDED WHENEVER A WORKSPACE IS ESTABLISHED.
    ##
    ## ``repro workspace init`` used to write ``.repro/workspace.toml`` only
    ## when it had a BRANCH to put in it: the resolver's ``trunk``, else its
    ## ``defaultRevision``. Both come from ``[project]`` keys that are
    ## ``Option`` — a manifest whose repo fragments each pin their own
    ## ``revision`` needs neither, and ``readProjectManifest`` accepts it.
    ##
    ## Measured against the previous engine with exactly the manifest below:
    ## init cloned both repos and exited 0, ``.repro/`` was created (engine
    ## cache, clone receipts, prompt cache), ``repro hooks ensure --vcs`` then
    ## installed ten hooks across two repos — and no ``workspace.toml`` existed
    ## anywhere. A working workspace with no marker — so every predicate that
    ## asks for the marker answered "not a workspace" for a workspace that
    ## plainly was one, and ``repro health``'s ``workspace`` layer reported
    ## ``fail`` with a remedy that had already been run.
    ##
    ## "This directory is an initialized workspace" is not a fact about
    ## branches, so init records it whenever it establishes one. Falsifiable:
    ## against an engine that writes the marker only alongside a branch value,
    ## the ``workspace.toml`` assertion below fails.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real origins and a real " &
        "`repro workspace init` that clones them")
    else:
      putEnv("REPROBUILD_REPRO", reproBinary())
      let fx = setupFixture(gitBin, "init-marker")
      defer: removeDir(fx.scratch)

      # A SECOND workspace root, laid out flat, whose project manifest carries
      # NEITHER ``default_revision`` NOR ``trunk``. Every repo fragment pins
      # its own revision, so nothing needs a project-level default and the
      # manifest is schema-valid exactly as written.
      let root = fx.scratch / "branchless-workspace"
      createDir(root / "projects")
      createDir(root / "repos")
      writeFile(root / "projects" / "lib-a.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"lib-a\"\n\n" &
        "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
        fileUrl(fx.libA.origin) & "\"\n\n" &
        "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" &
        fileUrl(fx.libB.origin) & "\"\n\n" &
        "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n")
      writeFile(root / "repos" / "lib-a.toml", libAFragmentToml)
      writeFile(root / "repos" / "lib-b.toml", libBFragmentToml)
      check not fileExists(root / ".repro" / "workspace-state.toml") and
        not fileExists(root / ".repro" / "workspace.toml")

      let inited = runShell(shellCommand(@[
        fx.reproBin, "workspace", "init", "lib-a",
        "--workspace-root=" & root,
      ], @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("workspace init output: " & inited.output)
      check inited.code == 0

      # The init really did establish a workspace — both declared repos are
      # checked out — so what follows is about a workspace, not about a failed
      # command that wrote nothing for a different reason.
      check dirExists(root / "lib-a" / ".git")
      check dirExists(root / "lib-b" / ".git")

      # THE MARKER. Falsifiable: the previous engine leaves this absent.
      check fileExists(root / ".repro" / "workspace-state.toml")
      check readWorkspaceProjects(root) == @["lib-a"]
      check isInitializedWorkspace(root)
      check hasResolvedManifestCheckout(root)

  test "t_a_stood_down_commit_hook_manufactures_no_workspace_state":
    ## A HOOK THAT HAS DECIDED IT HAS NOTHING TO DO LEAVES NOTHING BEHIND.
    ##
    ## The RA-10 guard above and the classifier fix in
    ## ``hasResolvedManifestCheckout`` are both load-bearing on an ABSENCE: a
    ## root counts as an initialized workspace when its ``.repro/`` shell sits
    ## beside a resolved ``projects/*.toml``, so the lock RECORD STORE — which
    ## carries the manifests and no ``.repro/`` — correctly answers "not a
    ## workspace". The system used to create the very thing that absence
    ## depends on. ``writePostCommitReport`` and ``appendPostCommitLog``
    ## ``createDir`` their destination RECURSIVELY, and the non-workspace
    ## branch handed them the nearest ``.repro/`` shell at or above the
    ## committing repo. So a post-commit that stood down *because the root is
    ## not a workspace* still wrote
    ## ``<root>/.repro/build/reports/post-commit-report.json`` — with
    ## ``"outcome": "skipped-no-workspace"`` — plus ``post-commit-lock.log``,
    ## inside the very repo it had just disclaimed. A diagnostic that
    ## fabricates the marker its own verdict denies is not a diagnostic.
    ##
    ## WHAT THAT COSTS, and why it is not tidiness. The two files are
    ## untracked content in a git checkout, which is what the lock publisher's
    ## dirty-outside-``locks/`` guard refuses on — and it refuses PERMANENTLY,
    ## because the publisher's own next commit fires the same hook and
    ## regenerates them. `t_post_commit_report_lands_in_the_disposable_build
    ## _tree` records that outage for a workspace root; this is the same
    ## mechanism one level out, in a root that has no workspace to own the
    ## disposable tree at all. What this case does NOT claim is that the skip
    ## branch could create the ``.repro/`` from nothing: its anchor required a
    ## pre-existing one, so the shell in the fixture below is a PRECONDITION
    ## of the retired behaviour, not a product of it.
    ##
    ## THE FIXTURE is the reachable shape of that root: a plain git repo, not
    ## under any workspace, that carries a ``.repro/`` shell because something
    ## ran there once — and carries it TRACKED and committed, so the working
    ## tree is genuinely clean before the commit and any file a hook drops
    ## inside it shows up as dirt. No ``workspace.toml``, no
    ## ``projects/*.toml``, no committed ``repro.lock``: ``isInitializedWorkspace``
    ## is false, asserted rather than assumed, both before and after.
    ##
    ## FALSIFIABLE, in both directions:
    ##   * against the engine at ``89d4b87d`` the post-commit report tree
    ##     appears under the disclaimed root's ``.repro/`` and the porcelain
    ##     goes dirty — both checks below fail;
    ##   * the companion assertion keeps the fix honest the other way: a
    ##     GENUINE workspace still gets its ``post-commit-report.json`` and
    ##     its log. Deleting the diagnostic instead of relocating it fails
    ##     that. It does NOT separate ``isInitializedWorkspace`` from
    ##     ``dirExists(.repro)`` — every workspace fixture here has a shell.
    ##   * silence is a regression of its own — the code comment on this
    ##     branch records that it "turned this branch into a black hole in
    ##     the field" — so the verdict is asserted ON STDERR, which is where
    ##     git relays a commit hook's output.
    ##
    ## NO MOCKS: real git repos, real managed hooks installed by the real
    ## ``repro hooks ensure --vcs``, a real ``git commit`` firing them, and
    ## ``REPROBUILD_REPRO`` pinned at the binary under test (see the header
    ## note — an unset value silently exercises whatever ``repro`` is on PATH).
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs a real repo, real managed " &
        "hooks and a real commit")
    else:
      putEnv("REPROBUILD_REPRO", reproBinary())
      let fx = setupFixture(gitBin, "no-state")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      # ---- the disclaimed root -------------------------------------------
      let plain = fx.scratch / "plain-repo-with-a-repro-shell"
      createDir(plain)
      discard requireGit(q(gitBin) & " init -b main " & q(plain))
      discard requireGit(q(gitBin) & " -C " & q(plain) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(plain) &
        " config user.name \"RA10 Tester\"")
      createDir(plain / ".repro")
      writeFile(plain / ".repro" / ".gitkeep", "")
      writeFile(plain / "README.md", "a plain repo, not a workspace\n")
      discard requireGit(q(gitBin) & " -C " & q(plain) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(plain) &
        " commit -m \"seed a repo that is not a workspace\"")

      # The trap is real: a ``.repro/`` shell IS present (so the retired
      # behaviour had somewhere to file), the root is NOT a workspace by the
      # canonical marker, and the tree is clean.
      check dirExists(plain / ".repro")
      check not fileExists(plain / ".repro" / "workspace-state.toml") and
        not fileExists(plain / ".repro" / "workspace.toml")
      check not fileExists(plain / "repro.lock")
      check not isInitializedWorkspace(plain)
      check not hasResolvedManifestCheckout(plain)
      check porcelain(gitBin, plain) == ""
      let shellBefore = reproShellListing(plain)
      check shellBefore == @[".repro" / ".gitkeep"]

      # Real managed hooks, installed by the real installer. Installation
      # itself leaves the tree clean — everything it writes lives in ``.git/``.
      let ensurePlain = invokeEnsureAt(fx, plain)
      if ensurePlain.code != 0:
        checkpoint("ensure(plain) output: " & ensurePlain.output)
      check ensurePlain.code == 0
      for hookName in ["pre-commit", "post-commit", "post-merge",
                       "post-checkout", "pre-push"]:
        check fileExists(plain / ".git" / "hooks" / hookName)
      check porcelain(gitBin, plain) == ""

      # ---- a REAL commit through the REAL hooks --------------------------
      writeFile(plain / "README.md", "still not a workspace\n")
      discard requireGit(q(gitBin) & " -C " & q(plain) & " add README.md")
      let committed = runShell(shellCommand(
        @[gitBin, "-C", plain, "commit", "-m", "a commit in a non-workspace"],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("commit(plain) output: " & committed.output)
      check committed.code == 0

      # THE PROPERTY. The tree is exactly as clean as it was, and the
      # ``.repro/`` shell holds exactly what it held.
      check porcelain(gitBin, plain) == ""
      check reproShellListing(plain) == shellBefore
      check not fileExists(plain / ".repro" / "build" / "reports" /
        "post-commit-report.json")
      check not fileExists(plain / ".repro" / "build" / "reports" /
        "post-commit-lock.log")
      check not fileExists(plain / ".repro" / "build" / "reports" /
        "pre-commit-lock.log")
      # ...so the verdict still holds on the next run: nothing the hook did
      # makes this root answer the workspace marker differently.
      check not isInitializedWorkspace(plain)
      check not hasResolvedManifestCheckout(plain)

      # NOT SILENT. The dispatched hook body says so where git relays it.
      let pcPlain = invokeDispatchPostCommit(fx, plain)
      check pcPlain.code == 0
      check pcPlain.output.contains("skipped-no-workspace")
      check pcPlain.output.contains("not a workspace")
      check reproShellListing(plain) == shellBefore
      check porcelain(gitBin, plain) == ""

      # ---- the companion: a GENUINE workspace still gets its report ------
      # Same binary, same verb, one root over. If the fix had deleted the
      # diagnostic rather than moved it, this half fails.
      let realRepo = fx.workspaceRoot / "lib-a"
      let pcReal = invokeDispatchPostCommit(fx, realRepo)
      if pcReal.code != 0:
        checkpoint("dispatch post-commit(workspace) output: " & pcReal.output)
      check pcReal.code == 0
      let realReport = postCommitReport(fx, fx.workspaceRoot)
      check realReport["exitCode"].getInt() == 0
      check realReport["outcome"].getStr() != "skipped-no-workspace"
      check not realReport["diagnostic"].getStr().contains("not a workspace")
      check realReport["workspaceRoot"].getStr() == fx.workspaceRoot
      check fileExists(fx.workspaceRoot / ".repro" / "build" / "reports" /
        "post-commit-lock.log")

  test "t_a_record_store_that_acquired_a_repro_dir_is_still_not_a_workspace":
    ## THE FIELD STATE PART 4 DOES NOT HAVE: A RECORD STORE WITH A ``.repro/``.
    ##
    ## Part 4 proves the hooks stand down in a record store and manufacture no
    ## ``.repro/`` there. That leaves the store whose ``.repro/`` came from
    ## somewhere else — and the field store had one. An older engine filed
    ## ``.repro/workspace/post-commit-{lock.log,report.json}`` into it;
    ## deleting those two files, the documented unblock, leaves
    ## ``.repro/workspace/`` behind, and any ``repro`` verb an operator runs
    ## inside the store can create the directory too. With a ``.repro/`` beside
    ## its top-level ``projects/*.toml``, ``hasResolvedManifestCheckout`` used
    ## to read the store as a metadata-less workspace (its own doc and the
    ## ``DISCLOSED LIMIT`` note in ``workspace_branch.nim`` admitted as much).
    ## Every commit there then filed ``.repro/build/reports/*`` into the
    ## store's working tree, the lock publisher refused the store as "dirty
    ## outside locks/", and its own next publish commit fired the hook that
    ## regenerated the dirt: the self-sustaining wedge.
    ##
    ## The rule this pins: membership beside a top-level ``locks/``, with no
    ## settings or state file in the root, is a record store whatever else
    ## sits beside it (Workspace-Manifests.md §"Metadata and records are
    ## separate repositories").
    ##
    ## TWO STRAY SHAPES, because git sees them differently and both are real:
    ##   * ``.repro/workspace/`` left EMPTY — what deleting the two files
    ##     leaves. Git shows no empty directory, so the tree is clean and the
    ##     only trace is on disk.
    ##   * ``.repro/`` IGNORED (``.git/info/exclude``) and still holding a
    ##     leftover report — an operator who hid the dirt instead of deleting
    ##     it. Also clean to git, and also a ``.repro/`` on disk.
    ##
    ## FALSIFIABLE against the engine before this rule (``608d9110``): the
    ## real commit through the real hooks leaves
    ## ``?? .repro/build/reports/post-commit-report.json`` (and its log) in the
    ## porcelain, the pre-push gate does not say "not a workspace", and the
    ## publish below refuses as ``lpoRefusedDirty``.
    ##
    ## NO MOCKS: real git repos and a real bare origin, managed hooks installed
    ## by the real ``repro hooks ensure --vcs``, real commits (one of them the
    ## ``cherry-pick --continue`` that ends a real conflicting cherry-pick), a
    ## real ``git push`` through the installed pre-push hook, and the real
    ## ``publishWorkspaceLock`` into the store's real upstream.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real repos, real managed " &
        "hooks, real commits and a real push")
    else:
      putEnv("REPROBUILD_REPRO", reproBinary())
      let fx = setupFixture(gitBin, "stray-shell")
      defer: removeDir(fx.scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      for variant in ["empty-workspace-dir", "ignored-leftover-report"]:
        checkpoint("variant: " & variant)
        let store = seedManifestsRecordStore(gitBin, fx, "store-" & variant)
        discard requireGit(q(gitBin) & " -C " & q(store.path) &
          " branch --set-upstream-to=origin/main main")

        # ---- the stray ``.repro/`` ----------------------------------------
        createDir(store.path / ".repro" / "workspace")
        var shellBefore = @[".repro" / "workspace"]
        if variant == "ignored-leftover-report":
          writeFile(store.path / ".git" / "info" / "exclude", ".repro/\n")
          writeFile(store.path / ".repro" / "workspace" /
            "post-commit-report.json", "{\"outcome\": \"skipped\"}\n")
          shellBefore.add(".repro" / "workspace" / "post-commit-report.json")

        # The trap is real, asserted rather than assumed: a ``.repro/`` IS on
        # disk beside resolvable membership and a top-level ``locks/``, no
        # workspace marker of the root's own, and git calls the tree clean.
        check dirExists(store.path / ".repro")
        check dirExists(store.path / "locks")
        check fileExists(store.path / "projects" / "lib-a.toml")
        check not fileExists(store.path / ".repro" / "workspace-state.toml") and
          not fileExists(store.path / ".repro" / "workspace.toml")
        check not fileExists(store.path / "repro-workspace.toml") and
          not fileExists(store.path / ".repro-workspace.toml")
        check not fileExists(store.path / "repro.lock")
        check porcelain(gitBin, store.path) == ""
        check reproShellListing(store.path) == shellBefore

        # THE CLASSIFICATION. Falsifiable in-process: the old predicate
        # answered true here on the strength of the shell alone.
        check not hasResolvedManifestCheckout(store.path)
        check not isInitializedWorkspace(store.path)
        check workspaceMarkerIn(store.path) == WorkspaceRootMarker.wrmNone
        check discoverWorkspaceRoot(store.path).root != store.path

        # Real managed hooks, by the real installer, into the store itself.
        let ensureStore = invokeEnsureAt(fx, store.path)
        if ensureStore.code != 0:
          checkpoint("ensure(store) output: " & ensureStore.output)
        check ensureStore.code == 0
        for hookName in ["pre-commit", "pre-push", "post-commit",
                         "post-merge", "post-checkout"]:
          check fileExists(store.path / ".git" / "hooks" / hookName)
        check porcelain(gitBin, store.path) == ""

        # ---- (a) a REAL commit through the REAL hooks ---------------------
        writeFile(store.path / "NOTES.md", "base\n")
        discard requireGit(q(gitBin) & " -C " & q(store.path) &
          " add NOTES.md")
        let committed = runShell(shellCommand(
          @[gitBin, "-C", store.path, "commit", "-m", "notes"],
          @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
        checkpoint("commit(store) output: " & committed.output)
        check committed.code == 0
        # THE PROPERTY. Before the rule this porcelain carried the hook's
        # report and log as untracked files.
        check porcelain(gitBin, store.path) == ""
        check not dirExists(store.path / ".repro" / "build")
        check reproShellListing(store.path) == shellBefore

        # Not silent: the dispatched body names the verdict where git relays
        # it.
        let pcStore = invokeDispatchPostCommit(fx, store.path)
        check pcStore.code == 0
        check pcStore.output.contains("skipped-no-workspace")
        check pcStore.output.contains("not a workspace")
        check reproShellListing(store.path) == shellBefore

        # ---- (b) the same store CAUGHT MID-OPERATION ----------------------
        # A genuinely conflicting cherry-pick — the rebase-shaped repair that
        # fired post-commit in the field. The marker check is asked first, so
        # the verdict is about the workspace, and nothing is filed.
        discard requireGit(q(gitBin) & " -C " & q(store.path) &
          " checkout -q -b side")
        writeFile(store.path / "NOTES.md", "side\n")
        discard requireGit(q(gitBin) & " -C " & q(store.path) &
          " commit -q -am \"side edit\"")
        discard requireGit(q(gitBin) & " -C " & q(store.path) &
          " checkout -q main")
        writeFile(store.path / "NOTES.md", "main\n")
        discard requireGit(q(gitBin) & " -C " & q(store.path) &
          " commit -q -am \"main edit\"")
        let pick = runCmd(q(gitBin) & " -C " & q(store.path) &
          " cherry-pick side")
        check pick.code != 0
        check fileExists(store.path / ".git" / "CHERRY_PICK_HEAD")
        let pcMid = invokeDispatchPostCommit(fx, store.path)
        check pcMid.code == 0
        check pcMid.output.contains("skipped-no-workspace")
        check not pcMid.output.contains("a git operation is in progress")
        check reproShellListing(store.path) == shellBefore
        # Resolve and CONTINUE: a real commit made while the sequencer is
        # active, through the real installed hooks.
        writeFile(store.path / "NOTES.md", "resolved\n")
        discard requireGit(q(gitBin) & " -C " & q(store.path) &
          " add NOTES.md")
        let continued = runShell(shellCommand(
          @[gitBin, "-C", store.path, "-c", "core.editor=true",
            "cherry-pick", "--continue"],
          @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
        checkpoint("cherry-pick --continue output: " & continued.output)
        check continued.code == 0
        check porcelain(gitBin, store.path) == ""
        check not dirExists(store.path / ".repro" / "build")
        check reproShellListing(store.path) == shellBefore

        # ---- (c) the pre-push gate, and a real push through it ------------
        let storeHead = requireGit(q(gitBin) & " -C " & q(store.path) &
          " rev-parse HEAD").strip()
        let storeRefs = fx.scratch / ("refs-" & variant & ".txt")
        writeRefsFile(storeRefs, "refs/heads/main", storeHead)
        let ppStore = invokeCheckPrePushByWalk(fx,
          currentRepo = store.path, refsFile = storeRefs)
        if ppStore.code != 0:
          checkpoint("check(store) output: " & ppStore.output)
        check ppStore.code == 0
        check ppStore.output.contains("not a workspace")
        let pushRes = runShell(shellCommand(
          @[gitBin, "-C", store.path, "push", "origin", "main"],
          @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
        if pushRes.code != 0:
          checkpoint("git push(store) output: " & pushRes.output)
        check pushRes.code == 0
        check requireGit(q(gitBin) & " -C " & q(store.origin) &
          " rev-parse refs/heads/main").strip() == storeHead
        check porcelain(gitBin, store.path) == ""

        # ---- (d) publication INTO the store is not wedged -----------------
        # The real publisher, the one the workspace's pre-push gate routes a
        # record through. Its commit fires the store's own post-commit hook;
        # before the rule, that hook's report was the dirt the NEXT publish
        # refused on — so publish twice and require both to land.
        for i, sha in ["a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
                       "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"]:
          let dir = store.path / "locks" / "lib-a" / "lib-a"
          createDir(dir)
          writeFile(dir / (sha & ".toml"),
            "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
            "[lock]\nproject = \"lib-a\"\n" &
            "created_at = \"2026-10-14T00:00:00Z\"\n\n" &
            "[[repo]]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
            "remote = \"origin\"\nrevision = \"" & sha & "\"\n")
          let pub = publishWorkspaceLock(identity, store.path)
          checkpoint("publish #" & $i & " diagnostic: " & pub.diagnostic)
          check pub.outcome == LockPublishOutcome.lpoPublished
          check requireGit(q(gitBin) & " -C " & q(store.origin) &
            " ls-tree -r --name-only refs/heads/main").contains(
              "locks/lib-a/lib-a/" & sha & ".toml")
          check porcelain(gitBin, store.path) == ""
          check not dirExists(store.path / ".repro" / "build")
        check reproShellListing(store.path) == shellBefore
        check not isInitializedWorkspace(store.path)

  test "nested and explicitly registered record stores enforce immutable raw pushes":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "store-boundary")
    defer: removeDir(fx.scratch)
    putEnv("REPROBUILD_REPRO", fx.reproBin)
    cloneAll(gitBin, fx)
    seedWorkspaceToml(fx)
    let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
    # A custom backend is not registered until publication. Its FIRST record
    # commit must keep private dispatcher context out of a raw user hook too.
    let firstStore = fx.scratch / "first-custom-backend"
    discard seedGitOrigin(gitBin, firstStore & "-origin.git", firstStore)
    let firstLog = fx.scratch / "first-backend-user-hook.log"
    let firstHook = firstStore / ".git/hooks/post-commit"
    writeFile(firstHook, "#!/bin/sh\nprintf 'context=%s\\n' " &
      "\"${REPROBUILD_INTERNAL_HOOK_CONTEXT-}\" >> " & q(firstLog) & "\n")
    setFilePermissions(firstHook, {fpUserRead, fpUserWrite, fpUserExec})
    let firstBackend = newGitCheckoutLockStore(identity, firstStore)
    var firstPut: StorePutResult
    block:
      let hadContext = existsEnv(InternalHookContextEnv)
      let previousContext = getEnv(InternalHookContextEnv)
      putEnv(InternalHookContextEnv, InternalLockCommitContext)
      try:
        firstPut = firstBackend.putLock(StoreLockRecord(
          key: StoreLockKey(project: "lib-a", repo: "lib-a", sha: repeat('1', 40)),
          body: "[[repo]]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
            "revision = \"" & repeat('1', 40) & "\"\n"))
      finally:
        if hadContext: putEnv(InternalHookContextEnv, previousContext)
        else: delEnv(InternalHookContextEnv)
    checkpoint(firstPut.diagnostic)
    require firstPut.outcome == spoOk
    check readFile(firstLog) == "context=\n"
    check not dirExists(firstStore / ".repro")
    for store in [fx.workspaceRoot / ".repro" / "manifests",
                  fx.scratch / "custom-record-store"]:
      if dirExists(store): removeDir(store)
      let origin = store & "-origin.git"
      discard seedGitOrigin(gitBin, origin, store)
      let record = "locks/lib-a/lib-a/" & repeat('a', 40) & ".toml"
      createDir(store / "projects")
      createDir(store / "repos")
      writeFile(store / "projects/lib-a.toml", readFile(fx.workspaceRoot / "projects/lib-a.toml"))
      writeFile(store / "repos/lib-a.toml", libAFragmentToml)
      createDir(parentDir(store / record))
      writeFile(store / record, "published = true\n")
      discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m record")
      discard requireGit(q(gitBin) & " -C " & q(store) & " push origin main")
      let published = requireGit(q(gitBin) & " -C " & q(store) & " rev-parse HEAD").strip()
      # Migrate an old full managed bundle, preserving a chained user hook.
      let oldBundle = fx.scratch / ("old-hooks-" & lastPathPart(store))
      createDir(oldBundle)
      discard requireGit(q(gitBin) & " init -b main " & q(oldBundle))
      writeFile(oldBundle / ".git/hooks/post-commit", "#!/bin/sh\nexit 0\n")
      setFilePermissions(oldBundle / ".git/hooks/post-commit", {fpUserRead, fpUserWrite, fpUserExec})
      require invokeEnsureAt(fx, oldBundle).code == 0
      for hook in ["pre-commit", "post-commit", "post-merge", "post-checkout", "pre-push"]:
        for suffix in ["", ".repro-managed", ".repro-local"]:
          let source = oldBundle / ".git/hooks" / (hook & suffix)
          if fileExists(source): copyFileWithPermissions(source, store / ".git/hooks" / (hook & suffix))
      var ensureArgs = @[fx.reproBin, "hooks", "ensure", "--vcs"]
      if store == fx.scratch / "custom-record-store":
        ensureArgs.add("--record-store")
      ensureArgs.add(store)
      let installed = runShell(shellCommand(ensureArgs))
      checkpoint(installed.output)
      require installed.code == 0
      check fileExists(store / ".git/hooks/pre-push")
      let managedPush = readFile(store / ".git/hooks/pre-push.repro-managed")
      check managedPush.contains("# reprobuild pre-push publication-policy: immutable-records-v1")
      check not managedPush.contains("--hook-contract=reprobuild.managed-hook.v1.pre-push.c7f752fbbad9dd07")
      for hook in ["pre-commit", "post-merge", "post-checkout"]:
        check not fileExists(store / ".git/hooks" / hook)
      check readFile(store / ".git/hooks/post-commit") == "#!/bin/sh\nexit 0\n"
      # Idempotent repair must retain the store's registered identity.
      require invokeEnsureAt(fx, store).code == 0
      for hook in ["pre-commit", "post-merge", "post-checkout"]:
        check not fileExists(store / ".git/hooks" / hook)
      let refs = fx.scratch / "nested-refs.txt"
      writeRefsFile(refs, "refs/heads/main", published)
      let checked = invokeCheckPrePushByWalk(fx, store, refs)
      check checked.code == 0
      check checked.output.contains("not a workspace")
      for hook in ["pre-commit", "post-commit", "post-merge", "post-checkout"]:
        check invokeDispatchNonBlocking(fx, hook, store).code == 0
      check not dirExists(store / ".repro")
      check porcelain(gitBin, store) == ""
      let added = "locks/lib-a/lib-a/" & repeat('b', 40) & ".toml"
      writeFile(store / added, "added = true\n")
      writeFile(store / "README.md", "editable membership metadata\n")
      discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
      let unusualRecord = "locks/lib-a/lib-a/tab\tnewline\nrecord.toml"
      let blobFile = fx.scratch / "unusual-record-body.toml"
      writeFile(blobFile, "unusual_record = true\n")
      let blob = requireGit(q(gitBin) & " -C " & q(store) & " hash-object -w " & q(blobFile)).strip()
      discard requireGit(q(gitBin) & " -C " & q(store) &
        " update-index --add --cacheinfo " & q("100644," & blob & "," & unusualRecord))
      let unusualTree = requireGit(q(gitBin) & " -C " & q(store) & " write-tree").strip()
      let unusualCommit = requireGit(q(gitBin) & " -C " & q(store) & " commit-tree " & unusualTree & " -p HEAD -m unusual-record").strip()
      discard requireGit(q(gitBin) & " -C " & q(store) & " update-ref refs/heads/unusual " & unusualCommit)
      discard requireGit(q(gitBin) & " -C " & q(store) & " update-index --force-remove -- " & q(unusualRecord))
      discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m additions")
      # A real stale split graph makes Git succeed while warning on stderr.
      # Neither that warning nor line breaks in a path belong to -z framing.
      discard requireGit(q(gitBin) & " -C " & q(store) & " commit-graph write --reachable --split")
      let graphDir = store / ".git/objects/info/commit-graphs"
      var graphFiles = 0
      for kind, path in walkDir(graphDir):
        if kind == pcFile and path.endsWith(".graph"):
          removeFile(path)
          inc graphFiles
      require graphFiles > 0
      let treeProcess = startProcess(gitBin, workingDir = store,
        args = @["ls-tree", "-r", "-z", unusualCommit, "--", "locks"], options = {poUsePath})
      let treeCode = treeProcess.waitForExit()
      let treeBytes = treeProcess.outputStream.readAll()
      let treeWarning = treeProcess.errorStream.readAll()
      treeProcess.close()
      require treeCode == 0
      require treeWarning.contains("unable to find all commit-graph files")
      check treeBytes.contains(unusualRecord & "\0")
      let accepted = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "main"]))
      checkpoint(accepted.output)
      require accepted.code == 0
      let unusualPush = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "refs/heads/unusual"]))
      require unusualPush.code == 0
      removeDir(graphDir)
      writeFile(blobFile, "unusual_record = false\n")
      let changedBlob = requireGit(q(gitBin) & " -C " & q(store) & " hash-object -w " & q(blobFile)).strip()
      discard requireGit(q(gitBin) & " -C " & q(store) &
        " update-index --add --cacheinfo " & q("100644," & changedBlob & "," & unusualRecord))
      let changedTree = requireGit(q(gitBin) & " -C " & q(store) & " write-tree").strip()
      let changedCommit = requireGit(q(gitBin) & " -C " & q(store) & " commit-tree " & changedTree & " -p " & unusualCommit & " -m mutate-unusual-record").strip()
      discard requireGit(q(gitBin) & " -C " & q(store) & " update-index --force-remove -- " & q(unusualRecord))
      discard requireGit(q(gitBin) & " -C " & q(store) & " update-ref refs/heads/unusual " & changedCommit)
      let unusualMutation = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "refs/heads/unusual"]))
      check unusualMutation.code != 0
      check unusualMutation.output.contains("immutable")
      var acceptedSha = requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip()
      check acceptedSha == requireGit(q(gitBin) & " -C " & q(store) & " rev-parse HEAD").strip()
      if store == fx.workspaceRoot / ".repro" / "manifests":
        let expiryRecord = "locks/lib-a/lib-a/" & repeat('f', 40) & ".toml"
        writeFile(store / expiryRecord, "expired_cap_addition = true\n")
        discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
        discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m expired-cap-addition")
        let expiryHead = requireGit(q(gitBin) & " -C " & q(store) & " rev-parse HEAD").strip()
        let expiring = issueHookCapability(gitBin, store, "origin", origin,
          "HEAD", expiryHead, "refs/heads/main", acceptedSha)
        require expiring.ok
        let pending = store / ".git/reprobuild/hook-capabilities" / (expiring.token & ".pending")
        require fileExists(pending)
        # Keep the genuine issuing process alive past the public TTL; neither
        # editing a token nor making the issuer disappear proves expiry.
        sleep(int(CapabilityTtlMilliseconds + 1000))
        require fileExists(pending)
        let expiredPush = runShell(shellCommand(
          @[gitBin, "-C", store, "push", "origin", "HEAD:refs/heads/main"],
          @[(name: HookCapabilityEnv, value: expiring.token)]))
        checkpoint(expiredPush.output)
        require expiredPush.code == 0
        check requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip() == expiryHead
        check not fileExists(pending)
        discardHookCapability(gitBin, store, expiring.token)
        let invalidRecord = "locks/lib-a/lib-a/" & repeat('9', 40) & ".toml"
        writeFile(store / invalidRecord, "invalid_cap_addition = true\n")
        discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
        discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m invalid-cap-addition")
        let invalidPush = runShell(shellCommand(
          @[gitBin, "-C", store, "push", "origin", "HEAD:refs/heads/main"],
          @[(name: HookCapabilityEnv, value: "invalid-token")]))
        require invalidPush.code == 0
        acceptedSha = requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip()
        check acceptedSha == requireGit(q(gitBin) & " -C " & q(store) & " rev-parse HEAD").strip()
      for change in ["edit", "delete", "rename", "mode"]:
        discard requireGit(q(gitBin) & " -C " & q(store) & " reset --hard " & acceptedSha)
        case change
        of "edit": writeFile(store / record, "published = false\n")
        of "delete": removeFile(store / record)
        of "rename": moveFile(store / record, store / (record & ".renamed"))
        else: discard requireGit(q(gitBin) & " -C " & q(store) & " update-index --chmod=+x " & q(record))
        if change != "mode":
          discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
        discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m " & change)
        let refused = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "main"]))
        checkpoint(refused.output)
        check refused.code != 0
        check refused.output.contains("immutable")
        check requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip() == acceptedSha
        if change == "edit":
          let invalidMutation = runShell(shellCommand(
            @[gitBin, "-C", store, "push", "origin", "main"],
            @[(name: HookCapabilityEnv, value: "invalid-token")]))
          check invalidMutation.code != 0
          check invalidMutation.output.contains("immutable")
          check requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip() == acceptedSha
          let head = requireGit(q(gitBin) & " -C " & q(store) & " rev-parse HEAD").strip()
          # Replacement refs change Git's interpretation, not the pushed
          # objects. They cannot make a mutation look like the published tree.
          discard requireGit(q(gitBin) & " -C " & q(store) & " replace " & head & " " & acceptedSha)
          # Replacement changes effective ancestry, so force is needed to
          # reach the hook rather than Git's earlier fast-forward rejection.
          let replacedPush = runShell(shellCommand(@[gitBin, "-C", store, "push", "--force", "origin", "main"]))
          checkpoint(replacedPush.output)
          check replacedPush.code != 0
          check replacedPush.output.contains("immutable")
          check requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip() == acceptedSha
          discard requireGit(q(gitBin) & " -C " & q(store) & " replace -d " & head)
          let issued = issueHookCapability(gitBin, store, "origin", origin,
            "HEAD", head, "refs/heads/main", acceptedSha)
          require issued.ok
          let capabilityPush = runShell(shellCommand(
            @[gitBin, "-C", store, "push", "origin", "HEAD:refs/heads/main"],
            @[(name: HookCapabilityEnv, value: issued.token)]))
          check capabilityPush.code != 0
          check capabilityPush.output.contains("immutable")
          discardHookCapability(gitBin, store, issued.token)
          let atomic = runShell(shellCommand(@[gitBin, "-C", store, "push", "--atomic", "origin",
            "HEAD:refs/heads/main", acceptedSha & ":refs/heads/clean-addition"]))
          check atomic.code != 0
          check atomic.output.contains("immutable")
          check requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip() == acceptedSha
          check runCmd(q(gitBin) & " -C " & q(origin) & " rev-parse --verify refs/heads/clean-addition").code != 0
          discard requireGit(q(gitBin) & " -C " & q(store) & " tag mutated-tag")
          let tagPush = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "refs/tags/mutated-tag"]))
          check tagPush.code != 0
          check tagPush.output.contains("immutable")

        # Publishing the same mutation under a fresh branch is no exemption.
        let fresh = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "HEAD:refs/heads/fresh-" & change]))
        if change in ["edit", "mode"]:
          check fresh.code != 0
          check fresh.output.contains("immutable")
          check runCmd(q(gitBin) & " -C " & q(origin) & " rev-parse --verify refs/heads/fresh-" & change).code != 0
        else:
          check fresh.code == 0
      discard requireGit(q(gitBin) & " -C " & q(store) & " reset --hard " & acceptedSha)
      # A symlink key would let an editable non-record target change the
      # record's contents without changing the key's Git object identity.
      writeFile(store / "editable-target.txt", "record_content = true\n")
      let linkedRecord = "locks/lib-a/lib-a/" & repeat('e', 40) & ".toml"
      discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
      stageGitSymlink(gitBin, store, linkedRecord, "../../../editable-target.txt", fx.scratch / "symlink-body")
      discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m symlink-record")
      let symlinkPush = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "main"]))
      check symlinkPush.code != 0
      check symlinkPush.output.contains("not a regular file")
      check requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip() == acceptedSha
      discard requireGit(q(gitBin) & " -C " & q(store) & " reset --hard " & acceptedSha)
      createDir(store / "records-via-link")
      writeFile(store / "records-via-link/example.toml", "indirect_record = true\n")
      discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
      stageGitSymlink(gitBin, store, "locks/hidden", "../records-via-link", fx.scratch / "symlink-body")
      discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m symlink-lock-directory")
      let directoryPush = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "main"]))
      check directoryPush.code != 0
      check directoryPush.output.contains("lock namespace entry")
      check requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip() == acceptedSha
      discard requireGit(q(gitBin) & " -C " & q(store) & " reset --hard " & acceptedSha)
      discard requireGit(q(gitBin) & " -C " & q(store) & " tag valid-tag " & acceptedSha)
      check runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "refs/tags/valid-tag"])).code == 0
      # A second publisher advances the remote without updating this checkout's
      # tracking ref or importing the remote commit. The guard must fetch the
      # actual destination tree rather than trusting local publication hints.
      let other = fx.scratch / ("other-" & lastPathPart(store))
      cloneInto(gitBin, origin, other)
      let conflictPath = "locks/lib-a/lib-a/" & repeat('c', 40) & ".toml"
      writeFile(other / conflictPath, "published_remotely = true\n")
      discard requireGit(q(gitBin) & " -C " & q(other) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(other) & " commit -m remote-record")
      discard requireGit(q(gitBin) & " -C " & q(other) & " push origin main")
      let remoteSha = requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip()
      check runCmd(q(gitBin) & " -C " & q(store) & " cat-file -e " & remoteSha).code != 0
      writeFile(store / conflictPath, "published_remotely = false\n")
      discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m conflicting-record")
      let conflict = runShell(shellCommand(@[gitBin, "-C", store, "push", "--force", "origin", "main"]))
      check conflict.code != 0
      check conflict.output.contains("immutable")
      check requireGit(q(gitBin) & " -C " & q(origin) & " rev-parse refs/heads/main").strip() == remoteSha
      discard requireGit(q(gitBin) & " -C " & q(store) & " reset --hard " & acceptedSha)
      let deleted = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", ":refs/heads/main"]))
      check deleted.code != 0
      check deleted.output.contains("immutable")
      check not dirExists(store / ".repro")
    # A top-level namespace symlink must be visible even when there are no
    # published records yet; a trailing-slash tree pathspec would hide it.
    let rootLinkStore = fx.scratch / "root-link-store"
    let rootLinkOrigin = fx.scratch / "root-link-origin.git"
    discard seedGitOrigin(gitBin, rootLinkOrigin, rootLinkStore)
    let externalRecords = fx.scratch / "external-records"
    createDir(externalRecords)
    writeFile(externalRecords / "example.toml", "external_record = true\n")
    discard requireGit(q(gitBin) & " -C " & q(rootLinkStore) & " add -A")
    stageGitSymlink(gitBin, rootLinkStore, "locks", externalRecords, fx.scratch / "symlink-body")
    discard requireGit(q(gitBin) & " -C " & q(rootLinkStore) & " commit -m linked-root")
    require runShell(shellCommand(@[fx.reproBin, "hooks", "ensure", "--vcs", "--record-store", rootLinkStore])).code == 0
    let rootLinkPush = runShell(shellCommand(@[gitBin, "-C", rootLinkStore, "push", "origin", "main"]))
    check rootLinkPush.code != 0
    check rootLinkPush.output.contains("lock namespace entry locks")
    # An independent unguarded writer can leave malformed published data.
    # Subsequent guarded pushes must report that integrity failure, not treat
    # the destination's hidden namespace as an empty record set.
    let unguardedWriter = fx.scratch / "unguarded-root-writer"
    cloneInto(gitBin, rootLinkOrigin, unguardedWriter)
    discard requireGit(q(gitBin) & " -C " & q(unguardedWriter) & " add -A")
    stageGitSymlink(gitBin, unguardedWriter, "locks", externalRecords, fx.scratch / "symlink-body")
    discard requireGit(q(gitBin) & " -C " & q(unguardedWriter) & " commit -m malformed-published-root")
    discard requireGit(q(gitBin) & " -C " & q(unguardedWriter) & " push origin main")
    writeFile(rootLinkStore / "README.md", "metadata repair cannot hide broken records\n")
    discard requireGit(q(gitBin) & " -C " & q(rootLinkStore) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(rootLinkStore) & " commit -m metadata-repair")
    let corruptDestination = runShell(shellCommand(@[gitBin, "-C", rootLinkStore, "push", "--force", "origin", "main"]))
    check corruptDestination.code != 0
    check corruptDestination.output.contains("lock namespace entry locks")
    # A backend can retain an ordinary workspace-repo role. Its immutable
    # boundary runs before both a normal gate and a valid publisher capability.
    let dual = fx.workspaceRoot / "lib-a"
    let dualRecord = "locks/lib-a/lib-a/" & repeat('d', 40) & ".toml"
    createDir(parentDir(dual / dualRecord))
    writeFile(dual / dualRecord, "shared_backend = true\n")
    discard requireGit(q(gitBin) & " -C " & q(dual) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(dual) & " commit -m shared-backend")
    discard requireGit(q(gitBin) & " -C " & q(dual) & " push origin main")
    let dualPublished = requireGit(q(gitBin) & " -C " & q(dual) & " rev-parse HEAD").strip()
    discard requireGit(q(gitBin) & " -C " & q(dual) & " config --local reprobuild.recordStoreBackend true")
    let dualUserLog = fx.scratch / "dual-backend-user-hook.log"
    let dualUserHook = dual / ".git/hooks/post-commit"
    writeFile(dualUserHook, "#!/bin/sh\nprintf 'context=%s\\n' " &
      "\"${REPROBUILD_INTERNAL_HOOK_CONTEXT-}\" >> " & q(dualUserLog) & "\n")
    setFilePermissions(dualUserHook, {fpUserRead, fpUserWrite, fpUserExec})
    require invokeEnsureAt(fx, dual).code == 0
    for hook in ["pre-commit", "post-commit", "post-merge", "post-checkout", "pre-push"]:
      check fileExists(dual / ".git/hooks" / hook)
    writeFile(dual / dualRecord, "shared_backend = false\n")
    discard requireGit(q(gitBin) & " -C " & q(dual) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(dual) & " commit -m mutate-shared-record")
    let dualHead = requireGit(q(gitBin) & " -C " & q(dual) & " rev-parse HEAD").strip()
    let dualPush = runShell(shellCommand(@[gitBin, "-C", dual, "push", "origin", "main"]))
    check dualPush.code != 0
    check dualPush.output.contains("immutable")
    let dualCap = issueHookCapability(gitBin, dual, "origin", fx.libA.origin,
      "HEAD", dualHead, "refs/heads/main", dualPublished)
    require dualCap.ok
    let dualCapPush = runShell(shellCommand(@[gitBin, "-C", dual, "push", "origin", "HEAD:refs/heads/main"],
      @[(name: HookCapabilityEnv, value: dualCap.token)]))
    check dualCapPush.code != 0
    check dualCapPush.output.contains("immutable")
    discardHookCapability(gitBin, dual, dualCap.token)
    check requireGit(q(gitBin) & " -C " & q(fx.libA.origin) & " rev-parse refs/heads/main").strip() == dualPublished
    discard requireGit(q(gitBin) & " -C " & q(dual) & " reset --hard " & dualPublished)
    # A shared workspace backend still suppresses its managed post-commit
    # bookkeeping, while the managed wrapper scrubs context for its user hook.
    let reportPath = fx.workspaceRoot / ".repro/build/reports/post-commit-report.json"
    let reportBefore = if fileExists(reportPath): readFile(reportPath) else: ""
    writeFile(dualUserLog, "")
    let dualBackend = newGitCheckoutLockStore(identity, dual)
    let dualPut = dualBackend.putLock(StoreLockRecord(
      key: StoreLockKey(project: "lib-a", repo: "lib-a", sha: repeat('2', 40)),
      body: "[[repo]]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "revision = \"" & repeat('2', 40) & "\"\n"))
    checkpoint(dualPut.diagnostic)
    require dualPut.outcome == spoOk
    check readFile(dualUserLog) == "context=\n"
    check (if fileExists(reportPath): readFile(reportPath) else: "") == reportBefore
    discard requireGit(q(gitBin) & " -C " & q(dual) & " reset --hard " & dualPublished)
    # The store exclusion must not exempt an ordinary participating repo.
    writeFile(fx.workspaceRoot / "lib-a" / "README.md", "dirty sibling\n")
    let ordinaryRefs = fx.scratch / "ordinary-refs.txt"
    writeRefsFile(ordinaryRefs, "refs/heads/main", dualPublished)
    let ordinary = invokeCheckPrePush(fx, fx.workspaceRoot,
      fx.workspaceRoot / "lib-a", ordinaryRefs)
    check ordinary.code != 0
    check ordinary.output.contains("dirty") or ordinary.output.contains("uncommitted")
    check not ordinary.output.contains("not a workspace")

  test "record store recognition preserves workspace roles and independent owners":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "store-recognition")
    defer: removeDir(fx.scratch)
    putEnv("REPROBUILD_REPRO", fx.reproBin)
    cloneAll(gitBin, fx)
    discard requireGit(q(gitBin) & " init -b main " & q(fx.workspaceRoot))

    # A settings root can declare an ordinary repo before writing local state.
    # Registration must not convert that declared repo into a store-only repo.
    writeFile(fx.workspaceRoot / settingsFileName,
      "schema = \"reprobuild.workspace.settings.v1\"\n")
    let ordinary = fx.workspaceRoot / "lib-a"
    let refused = runShell(shellCommand(@[fx.reproBin, "hooks", "ensure",
      "--record-store", ordinary]))
    checkpoint(refused.output)
    check refused.code != 0
    check refused.output.contains("cannot register workspace repo")
    check runCmd(q(gitBin) & " -C " & q(ordinary) &
      " config --local --get reprobuild.recordStore").code != 0
    # Even a stale registration cannot weaken the normal hook role.
    discard requireGit(q(gitBin) & " -C " & q(ordinary) &
      " config --local reprobuild.recordStore true")
    let ordinaryEnsure = invokeEnsureAt(fx, ordinary)
    checkpoint(ordinaryEnsure.output)
    require ordinaryEnsure.code == 0
    for hook in ["pre-commit", "pre-push", "post-commit", "post-merge", "post-checkout"]:
      check fileExists(ordinary / ".git/hooks" / hook)
    let ordinaryLinked = fx.scratch / "ordinary-linked"
    discard requireGit(q(gitBin) & " -C " & q(ordinary) &
      " worktree add -b ordinary-linked " & q(ordinaryLinked))
    require invokeEnsureAt(fx, ordinaryLinked).code == 0
    for hook in ["pre-commit", "pre-push", "post-commit", "post-merge", "post-checkout"]:
      check fileExists(ordinary / ".git/hooks" / hook)
    let linkedOrdinaryRefused = runShell(shellCommand(@[fx.reproBin, "hooks",
      "ensure", "--record-store", ordinaryLinked]))
    check linkedOrdinaryRefused.code != 0
    check linkedOrdinaryRefused.output.contains("cannot register workspace repo")

    # A malformed unrelated owner must not prevent a conventional checkout
    # from enforcing its independent immutable-record publication boundary.
    createDir(fx.workspaceRoot / ".repro")
    writeFile(fx.workspaceRoot / ".repro/workspace-state.toml", "[malformed\n")
    writeFile(fx.workspaceRoot / "projects/lib-a.toml", "[malformed\n")
    let conventional = fx.workspaceRoot / ".repro/records"
    let conventionalOrigin = fx.scratch / "conventional-origin.git"
    discard seedGitOrigin(gitBin, conventionalOrigin, conventional)
    require invokeEnsureAt(fx, conventional).code == 0
    check fileExists(conventional / ".git/hooks/pre-push")
    for hook in ["pre-commit", "post-commit", "post-merge", "post-checkout"]:
      check not fileExists(conventional / ".git/hooks" / hook)
    writeFile(conventional / "README.md", "editable backend metadata\n")
    discard requireGit(q(gitBin) & " -C " & q(conventional) & " add README.md")
    discard requireGit(q(gitBin) & " -C " & q(conventional) & " commit -m metadata")
    let conventionalPush = runShell(shellCommand(@[gitBin, "-C", conventional,
      "push", "origin", "main"]))
    checkpoint(conventionalPush.output)
    check conventionalPush.code == 0
    check not dirExists(conventional / ".repro")
    let protected = "locks/lib-a/lib-a/" & repeat('d', 40) & ".toml"
    createDir(parentDir(conventional / protected))
    writeFile(conventional / protected, "published = true\n")
    discard requireGit(q(gitBin) & " -C " & q(conventional) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(conventional) & " commit -m record")
    require runShell(shellCommand(@[gitBin, "-C", conventional, "push",
      "origin", "main"])).code == 0
    # No explicit registration hides this control: a conventional backend's
    # external linked worktree must inherit identity from its main checkout.
    check runCmd(q(gitBin) & " -C " & q(conventional) &
      " config --local --get reprobuild.recordStoreBackend").code != 0
    let conventionalLinked = fx.scratch / "conventional-linked"
    discard requireGit(q(gitBin) & " -C " & q(conventional) &
      " worktree add -b conventional-linked " & q(conventionalLinked))
    check fileExists(conventionalLinked / ".git")
    writeFile(conventionalLinked / protected, "published = false\n")
    discard requireGit(q(gitBin) & " -C " & q(conventionalLinked) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(conventionalLinked) & " commit -m mutation")
    let linkedMutation = runShell(shellCommand(@[gitBin, "-C", conventionalLinked,
      "push", "origin", "conventional-linked"]))
    checkpoint(linkedMutation.output)
    check linkedMutation.code != 0
    check linkedMutation.output.contains("immutable")
    check not dirExists(conventionalLinked / ".repro")

    # Standalone registration survives subsequent repair in a linked worktree.
    let custom = fx.scratch / "standalone-backend"
    let customOrigin = fx.scratch / "standalone-origin.git"
    discard seedGitOrigin(gitBin, customOrigin, custom)
    let registered = runShell(shellCommand(@[fx.reproBin, "hooks", "ensure",
      "--record-store", custom]))
    checkpoint(registered.output)
    require registered.code == 0
    check requireGit(q(gitBin) & " -C " & q(custom) &
      " config --local --bool --get reprobuild.recordStore").strip() == "true"
    let linked = fx.scratch / "linked-backend"
    discard requireGit(q(gitBin) & " -C " & q(custom) &
      " worktree add -b linked " & q(linked))
    check fileExists(linked / ".git")
    require invokeEnsureAt(fx, linked).code == 0
    let refs = fx.scratch / "linked-refs.txt"
    let linkedHead = requireGit(q(gitBin) & " -C " & q(linked) & " rev-parse HEAD").strip()
    writeRefsFile(refs, "refs/heads/linked", linkedHead)
    let linkedCheck = invokeCheckPrePushByWalk(fx, linked, refs)
    checkpoint(linkedCheck.output)
    check linkedCheck.code == 0
    check linkedCheck.output.contains("not a workspace")
    let linkedPush = runShell(shellCommand(@[gitBin, "-C", linked,
      "push", "origin", "linked"]))
    checkpoint(linkedPush.output)
    check linkedPush.code == 0
    check not dirExists(linked / ".repro")

    # Own explicit state has precedence even when malformed. It cannot be
    # silently replaced with a backend role to avoid a workspace gate.
    let own = fx.scratch / "own-workspace"
    discard seedGitOrigin(gitBin, fx.scratch / "own-origin.git", own)
    createDir(own / ".repro")
    writeFile(own / ".repro/workspace-state.toml", "[malformed\n")
    let ownRefused = runShell(shellCommand(@[fx.reproBin, "hooks", "ensure",
      "--record-store", own]))
    checkpoint(ownRefused.output)
    check ownRefused.code != 0
    check ownRefused.output.contains("cannot register workspace repo")
    check runCmd(q(gitBin) & " -C " & q(own) &
      " config --local --get reprobuild.recordStore").code != 0

  test "duplicate Git record paths cannot shadow immutable published content":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "duplicate-record-path")
    defer: removeDir(fx.scratch)
    putEnv("REPROBUILD_REPRO", fx.reproBin)
    let store = fx.workspaceRoot / ".repro" / "records"
    let origin = fx.scratch / "duplicate-origin.git"
    discard seedGitOrigin(gitBin, origin, store)
    # A .toml suffix does not turn a project directory into a record file.
    let record = "locks/project.toml/repo/key.toml"
    createDir(parentDir(store / record))
    writeFile(store / record, "published = true\n")
    discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m published-record")
    discard requireGit(q(gitBin) & " -C " & q(store) & " push origin main")
    require invokeEnsureAt(fx, store).code == 0
    check readFile(store / ".git/hooks/pre-push.repro-managed").contains(
      "# Lock namespace policy: unique paths before record indexing.")
    let originalBlob = requireGit(q(gitBin) & " -C " & q(store) &
      " rev-parse HEAD:" & record).strip()
    let blobInput = fx.scratch / "changed-record-body"
    writeFile(blobInput, "published = false\n")
    let changedBlob = requireGit(q(gitBin) & " -C " & q(store) &
      " hash-object -w " & q(blobInput)).strip()

    proc rawTree(entries: openArray[tuple[mode, name, oid: string]]): string =
      # Git's ordinary index/mktree prevent duplicates. --literally constructs
      # real Git objects that receive-pack accepts, not a stubbed tree reply.
      var body = ""
      for entry in entries:
        body.add(entry.mode & " " & entry.name & "\0")
        for i in countup(0, entry.oid.len - 2, 2):
          body.add(char(parseHexInt(entry.oid[i .. i + 1])))
      let input = fx.scratch / "raw-tree-body"
      writeFile(input, body)
      requireGit(q(gitBin) & " -C " & q(store) &
        " hash-object --literally -t tree -w " & q(input)).strip()

    proc commitTree(tree, parent: string): string =
      requireGit(q(gitBin) & " -C " & q(store) & " commit-tree " & tree &
        " -p " & parent & " -m record-tree").strip()

    proc wrapLeaf(leaf: string): string =
      let project = rawTree([("40000", "repo", leaf)])
      let locks = rawTree([("40000", "project.toml", project)])
      rawTree([("40000", "locks", locks)])

    # Valid additions remain pushable, including through .toml-named dirs.
    writeFile(store / "locks/project.toml/repo/added.toml", "added = true\n")
    discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(store) & " commit -m valid-addition")
    let validPush = runShell(shellCommand(@[gitBin, "-C", store, "push", "origin", "main"]))
    checkpoint(validPush.output)
    require validPush.code == 0
    let published = requireGit(q(gitBin) & " -C " & q(origin) &
      " rev-parse refs/heads/main").strip()
    let addedBlob = requireGit(q(gitBin) & " -C " & q(store) &
      " rev-parse HEAD:locks/project.toml/repo/added.toml").strip()
    let originalLeaf = rawTree([("100644", "added.toml", addedBlob),
      ("100644", "key.toml", originalBlob)])
    let otherLeaf = rawTree([("100644", "other.toml", changedBlob)])
    let originalProject = rawTree([("40000", "repo", originalLeaf)])
    let originalLocks = rawTree([("40000", "project.toml", originalProject)])
    let otherProject = rawTree([("40000", "repo", otherLeaf)])
    let otherLocks = rawTree([("40000", "other-project", otherProject)])
    let duplicateLeaf = rawTree([("100644", "added.toml", addedBlob),
      ("100644", "key.toml", changedBlob), ("100644", "key.toml", originalBlob)])
    let identicalLeaf = rawTree([("100644", "added.toml", addedBlob),
      ("100644", "key.toml", originalBlob), ("100644", "key.toml", originalBlob)])
    let duplicateDirectory = rawTree([("40000", "repo", otherLeaf),
      ("40000", "repo", originalLeaf)])
    let duplicateDirLocks = rawTree([("40000", "project.toml", duplicateDirectory)])
    let roots = [wrapLeaf(duplicateLeaf), wrapLeaf(identicalLeaf),
      rawTree([("40000", "locks", otherLocks), ("40000", "locks", originalLocks)]),
      rawTree([("40000", "locks", duplicateDirLocks)])]
    for tree in roots:
      let ambiguous = commitTree(tree, published)
      discard requireGit(q(gitBin) & " -C " & q(store) &
        " update-ref refs/heads/main " & ambiguous)
      let refused = runShell(shellCommand(@[gitBin, "-C", store, "push", "--force", "origin", "main"]))
      checkpoint(refused.output)
      check refused.code != 0
      check refused.output.contains("duplicate lock namespace path")
      check requireGit(q(gitBin) & " -C " & q(origin) &
        " rev-parse refs/heads/main").strip() == published
      check requireGit(q(gitBin) & " -C " & q(origin) &
        " show main:" & record).strip() == "published = true"
