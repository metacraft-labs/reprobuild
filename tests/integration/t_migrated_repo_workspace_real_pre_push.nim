## Legacy repo-workspaces migration compatibility through a real Git hook.
##
## The shipped repo-workspaces v2.10 migration wrote local workspace metadata
## to ``.repo/workspace.toml`` and an exact completion sentinel beside it.
## Reprobuild's later native-layout cutover made ``.repro/workspace.toml`` the
## canonical metadata path and root-level ``projects/`` / ``repos/`` the
## canonical membership. Existing migrated workspaces therefore have native
## membership but only the known legacy metadata artifact.
##
## This fixture reproduces the production Google Repo topology:
##
## * ``<repo>/.git`` is a symlink to ``.repo/projects/<repo>.git``;
## * that gitdir's ``objects`` and ``hooks`` are symlinks into
##   ``.repo/project-objects/<repo>.git``;
## * the installed dispatcher and managed body run from the shared hooks dir;
## * only root-level native membership is authoritative; a conflicting valid
##   project under ``.repo/manifests`` would fail if it were consulted.
##
## Ordinary non-empty ``git push`` invocations exercise the installed
## dispatcher and ``hooks dispatch pre-push``. The test proves exact workspace
## and current-repo discovery, a real dirty refusal, strict four-field ref
## transport, exact-destination remote-alias enforcement, and successful lock
## publication. Missing, forged, symlinked, or native-shadowed migration
## artifacts fail closed; no direct invocation mocks the hook boundary.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

type
  EnvSnapshot = object
    existed: bool
    value: string

  Fixture = object
    scratch, workspace, repo, projectGitDir, projectObjects: string
    origin, wrongOrigin, lockStore, lockOrigin, capture: string
    gitBin, reproBin: string

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc sourceRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  let candidate =
    if configured.len > 0: configured
    else: sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
  requireBinary(candidate, "reprobuild.apps.repro")

proc snapshotEnv(name: string): EnvSnapshot =
  EnvSnapshot(existed: existsEnv(name), value: getEnv(name))

proc restoreEnv(name: string; snapshot: EnvSnapshot) =
  if snapshot.existed:
    putEnv(name, snapshot.value)
  else:
    delEnv(name)

proc executable(path, body: string) =
  writeFile(path, body)
  var permissions = getFilePermissions(path)
  permissions.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, permissions)

proc git(fx: Fixture; args: openArray[string]; required = true):
    tuple[code: int; output: string] =
  var argv = @[fx.gitBin, "-C", fx.repo]
  argv.add(args)
  let res = runShell(shellCommand(argv))
  result = (res.code, res.output)
  if required and result.code != 0:
    checkpoint("git failed: " & argv.join(" ") & "\n" & result.output)
    quit 1

proc head(fx: Fixture): string =
  fx.git(["rev-parse", "HEAD"]).output.strip()

proc bareHead(gitBin, bare: string): string =
  require(q(gitBin) & " --git-dir=" & q(bare) &
    " rev-parse refs/heads/main").strip()

proc writeNativeMembership(fx: Fixture) =
  createDir(fx.workspace / "projects")
  createDir(fx.workspace / "repos")
  writeFile(fx.workspace / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"origin\"\nfetch = \"" &
      fileUrl(fx.origin).replace('\\', '/') & "\"\n\n" &
    "includes = [\"repos/app.toml\"]\n")
  writeFile(fx.workspace / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"origin\"\nrevision = \"main\"\n")

proc writeConflictingLegacyMembership(fx: Fixture) =
  ## This valid legacy project names a missing checkout. Any accidental
  ## ``.repo/manifests`` membership fallback makes the gate fail, so the happy
  ## path positively proves that only native root membership was resolved.
  let legacy = fx.workspace / ".repo" / "manifests"
  createDir(legacy / "projects")
  createDir(legacy / "repos")
  writeFile(legacy / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n\n" &
    "[[remote]]\nname = \"origin\"\nfetch = \"" &
      fileUrl(fx.origin).replace('\\', '/') & "\"\n\n" &
    "includes = [\"repos/legacy-ghost.toml\"]\n")
  writeFile(legacy / "repos" / "legacy-ghost.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"legacy-ghost\"\npath = \"legacy-ghost\"\n" &
    "remote = \"origin\"\nrevision = \"main\"\n")

proc writeLegacyMigrationArtifacts(fx: Fixture;
                                   marker = "reprobuild migration complete\n") =
  writeFile(fx.workspace / ".repo" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\n" &
    "projects = [\"app\", \"other-active-project\"]\n")
  writeFile(fx.workspace / ".repo" / ".repro-migration-complete", marker)

proc initRepoManagedWorktree(fx: Fixture) =
  createDir(fx.repo)
  createDir(fx.projectGitDir.parentDir)
  createDir(fx.projectObjects.parentDir)
  discard require(q(fx.gitBin) & " init --bare -b main " &
    q(fx.projectObjects))
  discard require(q(fx.gitBin) & " init --separate-git-dir=" &
    q(fx.projectGitDir) & " -b main " & q(fx.repo))

  # Match Google's Repo checkout indirection, including the shared hook
  # directory in project-objects.
  removeDir(fx.projectGitDir / "objects")
  createSymlink("../../project-objects/app.git/objects",
    fx.projectGitDir / "objects")
  removeDir(fx.projectGitDir / "hooks")
  createSymlink("../../project-objects/app.git/hooks",
    fx.projectGitDir / "hooks")
  removeFile(fx.repo / ".git")
  createSymlink("../.repo/projects/app.git", fx.repo / ".git")
  discard require(q(fx.gitBin) & " -C " & q(fx.repo) &
    " config core.hooksPath " & q(fx.projectGitDir / "hooks"))
  discard require(q(fx.gitBin) & " -C " & q(fx.repo) &
    " config user.email tester@example.invalid")
  discard require(q(fx.gitBin) & " -C " & q(fx.repo) &
    " config user.name 'Migrated Workspace Tester'")
  discard require(q(fx.gitBin) & " -C " & q(fx.repo) &
    " remote add metacraft-labs " & q(fileUrl(fx.origin)))
  discard require(q(fx.gitBin) & " -C " & q(fx.repo) &
    " remote add wrong " & q(fileUrl(fx.wrongOrigin)))

proc seedSource(fx: Fixture) =
  writeFile(fx.repo / "README.md", "seed\n")
  discard fx.git(["add", "README.md"])
  discard fx.git(["commit", "-m", "seed"])
  discard fx.git(["push", "--no-verify", "-u", "metacraft-labs", "main"])
  discard fx.git(["push", "--no-verify", "wrong", "main"])

proc initLockStore(fx: Fixture) =
  createDir(fx.lockStore)
  discard require(q(fx.gitBin) & " init -b main " & q(fx.lockStore))
  discard require(q(fx.gitBin) & " -C " & q(fx.lockStore) &
    " config user.email tester@example.invalid")
  discard require(q(fx.gitBin) & " -C " & q(fx.lockStore) &
    " config user.name 'Migrated Workspace Tester'")
  writeFile(fx.lockStore / "README.md", "lock store\n")
  discard require(q(fx.gitBin) & " -C " & q(fx.lockStore) & " add README.md")
  discard require(q(fx.gitBin) & " -C " & q(fx.lockStore) &
    " commit -m seed")
  discard require(q(fx.gitBin) & " -C " & q(fx.lockStore) &
    " remote add origin " & q(fileUrl(fx.lockOrigin)))
  discard require(q(fx.gitBin) & " -C " & q(fx.lockStore) &
    " push --no-verify -u origin main")

proc setup(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-migrated-repo-hook-", "")
  result.workspace = result.scratch / "workspace"
  result.repo = result.workspace / "app"
  result.projectGitDir = result.workspace / ".repo" / "projects" / "app.git"
  result.projectObjects =
    result.workspace / ".repo" / "project-objects" / "app.git"
  result.origin = result.scratch / "origin.git"
  result.wrongOrigin = result.scratch / "wrong.git"
  result.lockStore = result.workspace / ".repro" / "manifests"
  result.lockOrigin = result.scratch / "locks.git"
  result.capture = result.scratch / "preserved-pre-push.log"
  result.gitBin = gitBin
  result.reproBin = reproBinary()
  createDir(result.workspace)
  discard require(q(gitBin) & " init --bare -b main " & q(result.origin))
  discard require(q(gitBin) & " init --bare -b main " & q(result.wrongOrigin))
  discard require(q(gitBin) & " init --bare -b main " & q(result.lockOrigin))
  result.initRepoManagedWorktree()
  result.seedSource()
  result.writeNativeMembership()
  result.writeConflictingLegacyMembership()
  result.writeLegacyMigrationArtifacts()
  createDir(result.workspace / ".repro" / "workspace")
  result.initLockStore()

proc installRealHooks(fx: Fixture) =
  let sharedPrePush = fx.projectObjects / "hooks" / "pre-push"
  executable(sharedPrePush,
    "#!/usr/bin/env sh\n" &
    "set -eu\n" &
    "printf 'args=%s|%s\\n' \"$1\" \"$2\" >> " & q(fx.capture) & "\n" &
    "cat >> " & q(fx.capture) & "\n")
  for target in [fx.repo, fx.lockStore]:
    let ensured = runShell(shellCommand(@[
      fx.reproBin, "hooks", "ensure", "--vcs", target]))
    if ensured.code != 0:
      checkpoint("hook ensure failed for " & target & ":\n" & ensured.output)
      quit 1

  # Source commits manufactured by this test must not trigger the orthogonal
  # asynchronous post-commit lock/cache path. The pre-push dispatcher and body
  # remain the real installed files under the shared hooks symlink.
  for name in ["post-commit", "post-merge", "post-checkout"]:
    for suffix in ["", ".repro-managed", ".repro-local"]:
      let path = fx.projectObjects / "hooks" / (name & suffix)
      if fileExists(path):
        removeFile(path)

proc commit(fx: Fixture; label: string): string =
  writeFile(fx.repo / "README.md", label & "\n")
  discard fx.git(["add", "README.md"])
  discard fx.git(["commit", "-m", label])
  fx.head()

proc assertRefused(res: tuple[code: int; output: string]; needle = "") =
  if res.code == 0:
    checkpoint("push unexpectedly passed:\n" & res.output)
  check res.code != 0
  if needle.len > 0:
    check needle in res.output

proc checkReport(fx: Fixture): JsonNode =
  parseFile(fx.workspace / ".repro" / "workspace" / "check-report.json")

suite "migrated Google Repo workspace pre-push compatibility":
  test "real shared-gitdir hook uses only marker-bound legacy metadata":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setup(gitBin)
    defer: removeDir(fx.scratch)

    let priorRepro = snapshotEnv("REPROBUILD_REPRO")
    let priorSystem = snapshotEnv("REPROBUILD_SYSTEM_CONFIG")
    let priorUser = snapshotEnv("REPROBUILD_USER_CONFIG")
    let priorPrivate = snapshotEnv("REPROBUILD_VCS_PRIVATE_CONFIG")
    putEnv("REPROBUILD_REPRO", fx.reproBin)
    putEnv("REPROBUILD_SYSTEM_CONFIG", fx.scratch / "no-system.toml")
    putEnv("REPROBUILD_USER_CONFIG", fx.scratch / "no-user.toml")
    putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", fx.scratch / "no-private.toml")
    defer:
      restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", priorPrivate)
      restoreEnv("REPROBUILD_USER_CONFIG", priorUser)
      restoreEnv("REPROBUILD_SYSTEM_CONFIG", priorSystem)
      restoreEnv("REPROBUILD_REPRO", priorRepro)

    fx.installRealHooks()
    check symlinkExists(fx.repo / ".git")
    check symlinkExists(fx.projectGitDir / "objects")
    check symlinkExists(fx.projectGitDir / "hooks")
    check fileExists(fx.projectObjects / "hooks" / "pre-push")
    check fileExists(fx.projectObjects / "hooks" / "pre-push.repro-managed")
    check not fileExists(fx.workspace / ".repro" / "workspace.toml")

    let firstRemoteHead = bareHead(gitBin, fx.origin)
    let outgoing = fx.commit("outgoing")
    writeFile(fx.repo / "dirty.txt", "uncommitted\n")
    let dirtyPush = fx.git(["push", "metacraft-labs", "main"], required = false)
    dirtyPush.assertRefused("dirty")
    check bareHead(gitBin, fx.origin) == firstRemoteHead
    let dirtyReport = fx.checkReport()
    check dirtyReport["exitCode"].getInt() == 2
    check sameFile(dirtyReport["workspaceRoot"].getStr(), fx.workspace)
    check dirtyReport["project"].getStr() == "app"
    check sameFile(dirtyReport["currentRepo"].getStr(), fx.repo)
    check dirtyReport["failures"].len == 1
    check dirtyReport["failures"][0]["property"].getStr() == "dirty"
    check dirtyReport["failures"][0]["repo"].getStr() == "app"

    removeFile(fx.repo / "dirty.txt")
    let goodPush = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    if goodPush.code != 0:
      checkpoint("valid migrated-workspace push failed:\n" & goodPush.output)
    check goodPush.code == 0
    check bareHead(gitBin, fx.origin) == outgoing
    let goodReport = fx.checkReport()
    check goodReport["exitCode"].getInt() == 0
    check sameFile(goodReport["workspaceRoot"].getStr(), fx.workspace)
    check goodReport["project"].getStr() == "app"
    check sameFile(goodReport["currentRepo"].getStr(), fx.repo)
    check goodReport["failures"].len == 0
    check goodReport["lockUpdate"]["kind"].getStr() in
      ["created", "already-current"]

    let capture = readFile(fx.capture)
    let exactRefLine = "refs/heads/main " & outgoing &
      " refs/heads/main " & firstRemoteHead
    check capture.count(exactRefLine) == 2
    check "args=metacraft-labs|" & fileUrl(fx.origin) in capture

    # A second outgoing commit lets every negative prove that the destination
    # ref remains unchanged when legacy state is not exactly the known
    # migration artifact.
    let second = fx.commit("second-outgoing")
    let marker = fx.workspace / ".repo" / ".repro-migration-complete"
    removeFile(marker)
    let missingMarker = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    missingMarker.assertRefused("requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing

    # A byte-for-byte near miss (the producer's text without its terminating
    # newline) is not the completion sentinel.
    writeFile(marker, "reprobuild migration complete")
    let forgedMarker = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    forgedMarker.assertRefused("requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing

    removeFile(marker)
    let markerTarget = fx.scratch / "marker-target"
    writeFile(markerTarget, "reprobuild migration complete\n")
    createSymlink(markerTarget, marker)
    let symlinkMarker = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    symlinkMarker.assertRefused("requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing
    removeFile(marker)
    fx.writeLegacyMigrationArtifacts()

    removeFile(marker)
    createDir(marker)
    let directoryMarker = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    directoryMarker.assertRefused("requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing
    removeDir(marker)
    fx.writeLegacyMigrationArtifacts()

    let legacyMetadata = fx.workspace / ".repo" / "workspace.toml"
    let metadataTarget = fx.scratch / "workspace-metadata-target.toml"
    copyFile(legacyMetadata, metadataTarget)
    removeFile(legacyMetadata)
    createSymlink(metadataTarget, legacyMetadata)
    let symlinkMetadata = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    symlinkMetadata.assertRefused("requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing
    removeFile(legacyMetadata)
    fx.writeLegacyMigrationArtifacts()

    removeFile(legacyMetadata)
    createDir(legacyMetadata)
    let directoryMetadata = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    directoryMetadata.assertRefused("requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing
    removeDir(legacyMetadata)
    fx.writeLegacyMigrationArtifacts()

    writeFile(legacyMetadata,
      "schema = \"not-the-workspace-local-schema\"\n")
    let malformedLegacyMetadata =
      fx.git(["push", "metacraft-labs", "main"], required = false)
    malformedLegacyMetadata.assertRefused(
      "requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing
    fx.writeLegacyMigrationArtifacts()

    writeFile(legacyMetadata,
      "schema = \"reprobuild.workspace.local.v1\"\n\n" &
      "[workspace]\nproject = \"not-a-native-project\"\n")
    let nonNativeLegacyProject =
      fx.git(["push", "metacraft-labs", "main"], required = false)
    nonNativeLegacyProject.assertRefused(
      "requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing
    fx.writeLegacyMigrationArtifacts()

    # Even an otherwise-exact legacy artifact is inert without native
    # root-level project/variant membership.
    let nativeProjects = fx.workspace / "projects"
    let parkedProjects = fx.workspace / "projects.parked-for-test"
    moveDir(nativeProjects, parkedProjects)
    let noNativeMembership =
      runShell(shellCommand(@[
        fx.reproBin, "workspace", "lock",
        "--workspace-root", fx.workspace]))
    noNativeMembership.assertRefused("requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing
    moveDir(parkedProjects, nativeProjects)

    # The selected native membership file remains authoritative after the
    # narrow legacy-project-name lookup. Invalid native project metadata must
    # fail in the native resolver; it must never fall through to the valid
    # project under `.repo/manifests`.
    let nativeProject = nativeProjects / "app.toml"
    let validNativeProject = readFile(nativeProject)
    writeFile(nativeProject, "schema = \"not-a-project-schema\"\n")
    let malformedNativeProject =
      fx.git(["push", "metacraft-labs", "main"], required = false)
    malformedNativeProject.assertRefused()
    check bareHead(gitBin, fx.origin) == outgoing
    writeFile(nativeProject, validNativeProject)

    # Native metadata always wins. A malformed native file cannot be bypassed
    # by the otherwise-valid legacy artifact.
    writeFile(fx.workspace / ".repro" / "workspace.toml",
      "schema = \"not-the-native-schema\"\n")
    let nativeShadow = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    nativeShadow.assertRefused("requires either `.repro/workspace.toml`")
    check bareHead(gitBin, fx.origin) == outgoing
    removeFile(fx.workspace / ".repro" / "workspace.toml")

    # The remote-name alias is allowed only for the manifest's exact
    # destination. A different real bare cannot borrow the migration fallback
    # or the outgoing-HEAD provisional allowance.
    let wrongBefore = bareHead(gitBin, fx.wrongOrigin)
    let wrongPush = fx.git(["push", "wrong", "main"], required = false)
    wrongPush.assertRefused()
    check bareHead(gitBin, fx.wrongOrigin) == wrongBefore
    check bareHead(gitBin, fx.origin) == outgoing

    let finalPush = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    if finalPush.code != 0:
      checkpoint("restored exact migration artifact did not recover:\n" &
        finalPush.output)
    check finalPush.code == 0
    check bareHead(gitBin, fx.origin) == second
