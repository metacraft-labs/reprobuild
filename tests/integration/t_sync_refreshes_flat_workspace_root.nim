## `repro sync` fast-forwards the workspace ROOT when the root is itself the
## manifest checkout (the flat shape: `<org>/repro-workspace` cloned as the
## workspace, with `projects/` and `repos/` at its top level).
##
## `Workspace-And-Develop-Mode.md` §"Manifest Auto-Refresh": sync
## "fast-forwards every configured manifest layer" before reconciling, which
## "makes manual sync sufficient". Before this case existed the refresh only
## covered `url` layers under `.repro/`, so in the flat shape sync never moved
## the root: a fragment change published upstream — a new repo, a moved
## `path`, a declared rename — was never seen, and every other machine kept
## reconciling against whatever manifest it had last pulled by hand.
##
## The end-to-end case is the one that motivated the fix: a repo moved under a
## new directory with `[extensions] previously`, published from another clone
## of the root. ONE sync on the stale machine must pick up the manifest and
## relocate the checkout.
##
## Asserted:
##   1. one sync advances the root to the published manifest and relocates the
##      checkout to the new path, carrying its `.git` along; the report
##      names the root refresh (`workspace-root`, `refreshed`);
##   2. a second sync reports the root `up_to_date` and moves nothing;
##   3. a root with an unpublished local commit is left exactly where it is
##      (`skipped_divergent`), and a root with an edited tracked file likewise
##      (`skipped_dirty`) — sync never rewrites the operator's manifest work;
##   4. untracked entries in the root (every sibling checkout lives there) do
##      not block the refresh — case 1 runs with the clone present.
##
## NO MOCKS, for the reason `declared_rename_fixture.nim` gives: the decision
## under test is read out of real git state and moves real directories, so a
## fake git would remove exactly what can be wrong. Real bare origins over
## `file://`, real clones and the real `repro` binary.

import repro_test_support/reasoned_skip
import std/[json, os, strutils, unittest]
import declared_rename_fixture

proc rootLayer(report: JsonNode): JsonNode =
  ## The report's `workspace-root` manifest-layer entry, or nil.
  for entry in report["manifestLayers"]:
    if entry["provenance"].getStr() == "workspace-root":
      return entry
  nil

proc gitIn(gitBin, dir, args: string): string =
  requireGit(q(gitBin) & " -C " & q(dir) & " " & args).strip()

proc makeRootACheckout(fx: RenameFixture; gitBin: string): string =
  ## Turn the fixture's workspace root into a clone of a bare "manifest
  ## repository" origin, tracking `main`. Returns the bare origin's path.
  let rootOrigin = fx.scratch / "workspace-origin.git"
  let root = fx.workspaceRoot
  discard requireGit(q(gitBin) & " init --bare -b main " & q(rootOrigin))
  discard requireGit(q(gitBin) & " init -b main " & q(root))
  discard gitIn(gitBin, root, "config user.email tester@example.invalid")
  discard gitIn(gitBin, root, "config user.name \"Rename Tester\"")
  writeFile(root / ".gitignore", "/.repro/\n")
  discard gitIn(gitBin, root, "add -A")
  discard gitIn(gitBin, root, "commit -m manifests")
  discard gitIn(gitBin, root, "remote add origin " & q(rootOrigin))
  discard gitIn(gitBin, root, "push -u origin main")
  rootOrigin

proc publishMove(fx: RenameFixture; gitBin, rootOrigin: string): string =
  ## From a SEPARATE clone of the manifest repository (the machine that made
  ## the change), move `widget` to `moved/widget` with a declared previous
  ## path, and publish it. Returns the published commit.
  let admin = fx.scratch / "admin"
  discard requireGit(q(gitBin) & " clone " & q(rootOrigin) & " " & q(admin))
  discard gitIn(gitBin, admin, "config user.email tester@example.invalid")
  discard gitIn(gitBin, admin, "config user.name \"Rename Tester\"")
  writeFile(admin / "repos" / "widget.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"widget\"\npath = \"moved/widget\"\n" &
    "url_prefix = \"local\"\nbranch = \"main\"\n\n" &
    "[extensions]\npreviously = [{ path = \"widget\" }]\n")
  discard gitIn(gitBin, admin, "commit -am \"move widget under moved/\"")
  discard gitIn(gitBin, admin, "push origin main")
  gitIn(gitBin, admin, "rev-parse HEAD")

proc setUpSyncedWorkspace(gitBin, slug: string): tuple[fx: RenameFixture;
                                                       rootOrigin: string] =
  ## A workspace whose root is a manifest checkout and whose one repo,
  ## `widget`, has been cloned by a first sync.
  let fx = newRenameFixture(gitBin, slug)
  discard fx.seedOrigin(gitBin, "widget")
  fx.writeFragment("widget", "widget", "widget")
  fx.writeProject(["widget"])
  let rootOrigin = fx.makeRootACheckout(gitBin)
  let first = fx.invokeSync()
  checkpoint("initial sync output:\n" & first.output)
  check first.code == 0
  check dirExists(fx.workspaceRoot / "widget" / ".git")
  (fx: fx, rootOrigin: rootOrigin)

suite "sync refreshes a flat workspace root":

  test "t_sync_refreshes_flat_workspace_root_and_relocates_in_one_pass":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let (fx, rootOrigin) = setUpSyncedWorkspace(gitBin, "root-refresh")
      defer: removeDir(fx.scratch)
      let oldPath = fx.workspaceRoot / "widget"
      # State that exists only in this checkout's `.git`: if it is present at
      # the new path, the directory was moved, not re-cloned. A config entry
      # rather than a branch or a file, so the moved checkout still classifies
      # clean and the pass can exit 0.
      discard gitIn(gitBin, oldPath, "config --local test.marker moved")

      let published = fx.publishMove(gitBin, rootOrigin)

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 0
      # 1. The root advanced to the published manifest ...
      check gitIn(gitBin, fx.workspaceRoot, "rev-parse HEAD") == published
      let layer = fx.readReport().rootLayer()
      check not layer.isNil
      if not layer.isNil:
        check layer["status"].getStr() == "refreshed"
        check layer["afterSha"].getStr() == published
      # ... and the SAME pass relocated the checkout it declares.
      let newPath = fx.workspaceRoot / "moved" / "widget"
      check dirExists(newPath / ".git")
      check not dirExists(oldPath)
      check gitIn(gitBin, newPath, "config --local test.marker") == "moved"

      # 2. Nothing left to do.
      let again = fx.invokeSync()
      checkpoint("second sync output:\n" & again.output)
      check again.code == 0
      let layer2 = fx.readReport().rootLayer()
      check not layer2.isNil
      if not layer2.isNil:
        check layer2["status"].getStr() == "up_to_date"
      check dirExists(newPath / ".git")

  test "t_sync_leaves_a_root_with_unpublished_manifest_work_alone":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let (fx, rootOrigin) = setUpSyncedWorkspace(gitBin, "root-divergent")
      defer: removeDir(fx.scratch)
      discard fx.publishMove(gitBin, rootOrigin)
      # The operator's own manifest edit, committed and not pushed.
      writeFile(fx.workspaceRoot / "NOTES.md", "local manifest work\n")
      discard gitIn(gitBin, fx.workspaceRoot, "add NOTES.md")
      discard gitIn(gitBin, fx.workspaceRoot, "commit -m \"local work\"")
      let localHead = gitIn(gitBin, fx.workspaceRoot, "rev-parse HEAD")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      # 3. Root untouched, reported, and the sync still reconciled the repos
      #    against the manifest on disk (the old path stays put).
      check gitIn(gitBin, fx.workspaceRoot, "rev-parse HEAD") == localHead
      let layer = fx.readReport().rootLayer()
      check not layer.isNil
      if not layer.isNil:
        check layer["status"].getStr() == "skipped_divergent"
      check dirExists(fx.workspaceRoot / "widget" / ".git")
      check not dirExists(fx.workspaceRoot / "moved" / "widget")

  test "t_sync_leaves_a_root_with_tracked_edits_alone":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let (fx, rootOrigin) = setUpSyncedWorkspace(gitBin, "root-dirty")
      defer: removeDir(fx.scratch)
      discard fx.publishMove(gitBin, rootOrigin)
      let before = gitIn(gitBin, fx.workspaceRoot, "rev-parse HEAD")
      let projectFile = fx.workspaceRoot / "projects" / "myproject.toml"
      writeFile(projectFile, readFile(projectFile) & "# local edit\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check gitIn(gitBin, fx.workspaceRoot, "rev-parse HEAD") == before
      check readFile(projectFile).endsWith("# local edit\n")
      let layer = fx.readReport().rootLayer()
      check not layer.isNil
      if not layer.isNil:
        check layer["status"].getStr() == "skipped_dirty"
