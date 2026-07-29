## Protocol-v2 end-to-end publication through real installed Git hooks.
##
## Topology is ``app -> lib -> core`` plus unrelated ``other``. Every source
## and the manifest lock backend is a real worktree with a local bare remote;
## generated dispatchers/bodies are installed and the built single `repro`
## executable runs every hook process. The cases prove: an exact raw outgoing core
## HEAD passes; an unpublished dependency refuses a raw dependent push;
## ``repro push`` ignores unrelated unpublished work and publishes the closure
## dependency-first; exact source refs and exact remote lock paths are present;
## an already-published closure with no records fails twice without synthesizing
## locks; and a later lib receive failure retains/reports the already-published
## core prefix before a retry completes. The manifest's preserved hooks observe
## no capability/context, while successful nested pushes and empty capability
## storage prove one-use authorization was exercised. Nothing is mocked: only
## local Git processes, filesystem hooks, worktrees, and bare remotes are used.
## It runs cross-platform wherever Git supplies its hook shell; POSIX capability
## metadata has a dedicated suite. Wrong ordering, an advanced unrelated bare,
## a missing exact lock blob, or a hidden partial failure each falsifies a case.

import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles,
  unittest]

import repro_cli_support/push_hook_protocol
import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    stderr.writeLine("command failed: " & command & "\n" & res.output)
    quit 1
  res.output

proc root(): string = currentSourcePath().parentDir.parentDir.parentDir
proc reproBinary(): string =
  requireBinary(root() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc executable(path, body: string) =
  writeFile(path, body)
  var perms = getFilePermissions(path)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, perms)

proc seed(gitBin, bare, seedPath, label: string) =
  discard require(q(gitBin) & " init --bare -b main " & q(bare))
  discard require(q(gitBin) & " init -b main " & q(seedPath))
  discard require(q(gitBin) & " -C " & q(seedPath) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(seedPath) &
    " config user.name 'Protocol V2 Push Tester'")
  writeFile(seedPath / "README.md", label & "\n")
  discard require(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard require(q(gitBin) & " -C " & q(seedPath) & " commit -m seed")
  discard require(q(gitBin) & " -C " & q(seedPath) &
    " remote add origin " & q(bare))
  discard require(q(gitBin) & " -C " & q(seedPath) & " push origin main")

proc clone(gitBin, bare, path: string) =
  discard require(q(gitBin) & " clone " & q(fileUrl(bare)) & " " & q(path))
  discard require(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(path) &
    " config user.name 'Protocol V2 Push Tester'")

type Fixture = object
  scratch, workspace, manifests, manifestBare, reproBin: string
  app, lib, core, other: string
  appBare, libBare, coreBare, otherBare: string
  teamLocks, teamLocksBare, personalLocks, personalLocksBare: string
  manifestPrePushLog, manifestPostCommitLog: string

type
  EnvSnapshot = object
    existed: bool
    value: string

  RoutingConfigEnvironment = object
    system: EnvSnapshot
    user: EnvSnapshot
    vcsPrivate: EnvSnapshot

proc commit(fx: Fixture; gitBin, path, label: string): string =
  writeFile(path / (label & ".txt"), label & "\n")
  discard require(q(gitBin) & " -C " & q(path) & " add " & q(label & ".txt"))
  let prior = getEnv("REPROBUILD_REPRO")
  putEnv("REPROBUILD_REPRO", fx.reproBin)
  defer:
    if prior.len > 0: putEnv("REPROBUILD_REPRO", prior)
    else: delEnv("REPROBUILD_REPRO")
  discard require(q(gitBin) & " -C " & q(path) & " commit -m " & q(label))
  require(q(gitBin) & " -C " & q(path) & " rev-parse HEAD").strip()

proc projectToml(fx: Fixture): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"app-origin\"\nfetch = \"" & fileUrl(fx.appBare) &
    "\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & fileUrl(fx.libBare) &
    "\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & fileUrl(fx.coreBare) &
    "\"\n\n" &
  "[[remote]]\nname = \"other-origin\"\nfetch = \"" & fileUrl(fx.otherBare) &
    "\"\n\n" &
  "includes = [\"repos/app.toml\", \"repos/lib.toml\", " &
    "\"repos/core.toml\", \"repos/other.toml\"]\n"

proc repoToml(name, remote: string; depends: seq[string] = @[]): string =
  result = "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\nrevision = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [")
    for i, dep in depends:
      if i > 0: result.add(", ")
      result.add("\"" & dep & "\"")
    result.add("]\n")

proc repoTomlWithLocalRemote(name, projectRemote, localRemote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
  "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
  "remote = \"" & localRemote & "\"\nrevision = \"main\"\n" &
  "remotes = [\n  { name = \"" & localRemote & "\", remote = \"" &
    projectRemote & "\" },\n]\n"

proc setup(gitBin, slug: string; customCoreRemote = false): Fixture =
  result.scratch = createTempDir("repro-v2-real-push-" & slug & "-", "")
  result.workspace = result.scratch / "workspace"
  result.manifests = result.workspace / ".repro" / "manifests"
  result.manifestBare = result.scratch / "manifest.git"
  result.appBare = result.scratch / "app.git"
  result.libBare = result.scratch / "lib.git"
  result.coreBare = result.scratch / "core.git"
  result.otherBare = result.scratch / "other.git"
  result.reproBin = reproBinary()
  seed(gitBin, result.appBare, result.scratch / "seed-app", "app")
  seed(gitBin, result.libBare, result.scratch / "seed-lib", "lib")
  seed(gitBin, result.coreBare, result.scratch / "seed-core", "core")
  seed(gitBin, result.otherBare, result.scratch / "seed-other", "other")
  createDir(result.manifests / "projects")
  createDir(result.manifests / "repos")
  writeFile(result.manifests / "projects" / "app.toml", result.projectToml())
  writeFile(result.manifests / "repos" / "app.toml",
    repoToml("app", "app-origin", @["lib"]))
  writeFile(result.manifests / "repos" / "lib.toml",
    repoToml("lib", "lib-origin", @["core"]))
  writeFile(result.manifests / "repos" / "core.toml",
    if customCoreRemote:
      repoTomlWithLocalRemote("core", "core-origin", "publish-upstream")
    else:
      repoToml("core", "core-origin"))
  writeFile(result.manifests / "repos" / "other.toml",
    repoToml("other", "other-origin"))
  discard require(q(gitBin) & " init --bare -b main " & q(result.manifestBare))
  discard require(q(gitBin) & " init -b main " & q(result.manifests))
  discard require(q(gitBin) & " -C " & q(result.manifests) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(result.manifests) &
    " config user.name 'Protocol V2 Push Tester'")
  discard require(q(gitBin) & " -C " & q(result.manifests) &
    " add projects repos")
  discard require(q(gitBin) & " -C " & q(result.manifests) &
    " commit -m 'seed manifest'")
  discard require(q(gitBin) & " -C " & q(result.manifests) &
    " remote add origin " & q(result.manifestBare))
  discard require(q(gitBin) & " -C " & q(result.manifests) &
    " push -u origin main")
  result.app = result.workspace / "app"
  result.lib = result.workspace / "lib"
  result.core = result.workspace / "core"
  result.other = result.workspace / "other"
  clone(gitBin, result.appBare, result.app)
  clone(gitBin, result.libBare, result.lib)
  clone(gitBin, result.coreBare, result.core)
  clone(gitBin, result.otherBare, result.other)
  if customCoreRemote:
    discard require(q(gitBin) & " -C " & q(result.core) &
      " remote rename origin publish-upstream")
  writeWorkspaceBranch(result.workspace, project = "app", branch = "main")
  result.manifestPrePushLog = result.scratch / "manifest-pre-push.log"
  result.manifestPostCommitLog = result.scratch / "manifest-post-commit.log"

proc installHooks(fx: Fixture) =
  let manifestPrePush = require("git -C " & q(fx.manifests) &
    " rev-parse --path-format=absolute --git-path hooks/pre-push").strip()
  let manifestPostCommit = require("git -C " & q(fx.manifests) &
    " rev-parse --path-format=absolute --git-path hooks/post-commit").strip()
  createDir(manifestPrePush.parentDir())
  executable(manifestPrePush,
    "#!/usr/bin/env sh\n" &
    "printf 'cap=%s legacy=%s context=%s\\n' \"${" & HookCapabilityEnv &
      ":-}\" \"${" & LegacyHookSentinelEnv & ":-}\" \"${" &
      InternalHookContextEnv & ":-}\" >> " & q(fx.manifestPrePushLog) &
      "\ncat >/dev/null\nexit 0\n")
  executable(manifestPostCommit,
    "#!/usr/bin/env sh\n" &
    "printf 'context=%s\\n' \"${" & InternalHookContextEnv &
      ":-}\" >> " & q(fx.manifestPostCommitLog) & "\nexit 0\n")
  var targets = @[fx.workspace, fx.manifests]
  for path in [fx.teamLocks, fx.personalLocks]:
    if path.len > 0: targets.add(path)
  for path in targets:
    let ensured = runShell(shellCommand(@[fx.reproBin, "hooks", "ensure",
      "--vcs",
      "--workspace-root=" & path]))
    if ensured.code != 0:
      stderr.writeLine("hook ensure failed for " & path & ":\n" &
          ensured.output)
      quit 1

proc seedLockBackend(gitBin, root, bare, label: string) =
  discard require(q(gitBin) & " init --bare -b main " & q(bare))
  discard require(q(gitBin) & " init -b main " & q(root))
  discard require(q(gitBin) & " -C " & q(root) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(root) &
    " config user.name 'Protocol V2 Push Tester'")
  writeFile(root / "README.md", label & "\n")
  discard require(q(gitBin) & " -C " & q(root) & " add README.md")
  discard require(q(gitBin) & " -C " & q(root) & " commit -m seed")
  discard require(q(gitBin) & " -C " & q(root) &
    " remote add origin " & q(bare))
  discard require(q(gitBin) & " -C " & q(root) &
    " push -u origin main")

proc routedConfig(fx: Fixture): string =
  fx.workspace / ".repro" / "config.toml"

proc snapshotEnv(name: string): EnvSnapshot =
  EnvSnapshot(existed: existsEnv(name), value: getEnv(name))

proc restoreEnv(name: string; snapshot: EnvSnapshot) =
  if snapshot.existed:
    putEnv(name, snapshot.value)
  else:
    delEnv(name)

proc snapshotRoutingConfig(): RoutingConfigEnvironment =
  ## Snapshot every variable before changing any of them. In particular,
  ## present-but-empty values are distinct from absent values.
  result.system = snapshotEnv("REPROBUILD_SYSTEM_CONFIG")
  result.user = snapshotEnv("REPROBUILD_USER_CONFIG")
  result.vcsPrivate = snapshotEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc restoreRoutingConfig(environment: RoutingConfigEnvironment) =
  restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", environment.vcsPrivate)
  restoreEnv("REPROBUILD_USER_CONFIG", environment.user)
  restoreEnv("REPROBUILD_SYSTEM_CONFIG", environment.system)

proc isolateRoutingConfig(fx: Fixture): RoutingConfigEnvironment =
  ## Keep all layered config reads inside this fixture. If an override itself
  ## raises, roll back the already-written variables before propagating.
  result = snapshotRoutingConfig()
  try:
    putEnv("REPROBUILD_SYSTEM_CONFIG", fx.scratch / "no-system.toml")
    putEnv("REPROBUILD_USER_CONFIG", fx.scratch / "no-user.toml")
    putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", fx.routedConfig())
  except:
    restoreRoutingConfig(result)
    raise

proc failAfterRoutingIsolation(fx: Fixture) =
  ## Exercise the same immediate-defer pattern used by the real fixtures.
  let environment = isolateRoutingConfig(fx)
  defer: restoreRoutingConfig(environment)
  doAssert getEnv("REPROBUILD_SYSTEM_CONFIG") ==
    fx.scratch / "no-system.toml"
  doAssert getEnv("REPROBUILD_USER_CONFIG") == fx.scratch / "no-user.toml"
  doAssert getEnv("REPROBUILD_VCS_PRIVATE_CONFIG") == fx.routedConfig()
  raise newException(ValueError, "routing isolation teardown probe")

proc enableRoutedBackends(gitBin: string; fx: var Fixture) =
  fx.teamLocks = fx.scratch / "team-locks"
  fx.teamLocksBare = fx.scratch / "team-locks.git"
  fx.personalLocks = fx.scratch / "personal-locks"
  fx.personalLocksBare = fx.scratch / "personal-locks.git"
  seedLockBackend(gitBin, fx.teamLocks, fx.teamLocksBare, "team locks")
  seedLockBackend(gitBin, fx.personalLocks, fx.personalLocksBare,
    "personal locks")
  writeFile(fx.routedConfig(),
    "schema = \"reprobuild.config.v1\"\n\n" &
    "[locking]\nroute = [\n" &
    "  { visibility = \"team\", backend = \"git-checkout\", path = \"" &
      fx.teamLocks.replace('\\', '/') & "\", repos = [\"core\", \"app\"] },\n" &
    "  { visibility = \"personal\", backend = \"git-checkout\", path = \"" &
      fx.personalLocks.replace('\\', '/') & "\", repos = [\"lib\"] },\n" &
    "]\n")

proc bareHasLock(gitBin, bare, repo, sha: string): bool =
  let path = "locks/app/" & repo & "/" & sha & ".toml"
  run(q(gitBin) & " -C " & q(bare) & " cat-file -e " &
    q("refs/heads/main:" & path)).code == 0

proc withHookCli(fx: Fixture; command: string): tuple[code: int;
    output: string] =
  let prior = getEnv("REPROBUILD_REPRO")
  putEnv("REPROBUILD_REPRO", fx.reproBin)
  defer:
    if prior.len > 0: putEnv("REPROBUILD_REPRO", prior)
    else: delEnv("REPROBUILD_REPRO")
  run(command)

proc invokePush(fx: Fixture): tuple[code: int; output: string] =
  runShell(shellCommand(@[fx.reproBin, "push", "--report", "app", "--no-certify",
    "--workspace-root=" & fx.workspace, "--current-repo=" & fx.app,
    "--json"], @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

proc remoteHead(gitBin, bare: string): string =
  require(q(gitBin) & " -C " & q(bare) & " rev-parse refs/heads/main").strip()

proc branchExists(gitBin, bare: string): bool =
  run(q(gitBin) & " -C " & q(bare) &
    " rev-parse --verify refs/heads/main").code == 0

proc validLockRecord(repoName, repoPath, oid: string): string =
  "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
  "[lock]\nproject = \"app\"\n" &
  "created_at = \"2026-07-23T00:00:00Z\"\n\n" &
  "[[repo]]\nname = \"" & repoName & "\"\n" &
  "path = \"" & repoPath & "\"\nremote = \"origin\"\n" &
  "revision = \"" & oid & "\"\n"

proc writeLockRecord(backend, repoName, repoPath, oid: string;
    body = "") =
  let rel = "locks/app/" & repoName & "/" & oid & ".toml"
  let path = backend / rel
  createDir(path.parentDir())
  writeFile(path,
    if body.len > 0: body else: validLockRecord(repoName, repoPath, oid))

proc backendRecordState(gitBin, backend: string): string =
  require(q(gitBin) & " -C " & q(backend) &
    " ls-tree -r --full-tree HEAD").strip()

proc sourceStorageSnapshot(gitBin, repo: string): string =
  ## Snapshot the source state that a read-only publication probe must not
  ## mutate: exact HEAD/admin files, refs and reflogs, index/config and
  ## FETCH_HEAD presence/body, plus every object/pack/info entry's type, mode,
  ## size, and content hash. Directory traversal does not follow symlinks.
  let gitDir = require(q(gitBin) & " -C " & q(repo) &
    " rev-parse --absolute-git-dir").strip()
  let commonDir = require(q(gitBin) & " -C " & q(repo) &
    " rev-parse --path-format=absolute --git-common-dir").strip()

  proc metadata(path: string): string =
    if not fileExists(path) and not dirExists(path) and
        not symlinkExists(path):
      return "<absent>"
    let info = getFileInfo(path, followSymlink = false)
    result = $info.kind & ":" & $info.permissions & ":" & $info.size
    case info.kind
    of pcFile:
      result.add(":" & require(q(gitBin) &
        " hash-object --no-filters " & q(path)).strip())
    of pcLinkToFile, pcLinkToDir:
      result.add(":" & expandSymlink(path))
    else:
      discard

  proc treeSnapshot(label, root: string): string =
    result.add(label & "=<root>:" & metadata(root) & "\n")
    if not dirExists(root) or symlinkExists(root): return
    var entries: seq[tuple[rel, path: string]]
    proc gather(current, relRoot: string) =
      var children: seq[tuple[kind: PathComponent; path: string]]
      for kind, path in walkDir(current):
        children.add((kind, path))
      children.sort(proc(a, b: tuple[kind: PathComponent; path: string]): int =
        cmp(a.path, b.path))
      for child in children:
        let rel = if relRoot.len == 0: child.path.extractFilename()
          else: relRoot & "/" & child.path.extractFilename()
        entries.add((rel, child.path))
        if child.kind == pcDir:
          gather(child.path, rel)
    gather(root, "")
    for entry in entries:
      result.add(label & "=" & entry.rel.replace('\\', '/') & ":" &
        metadata(entry.path) & "\n")

  result.add("resolved-head=" & require(q(gitBin) & " -C " & q(repo) &
    " rev-parse HEAD").strip() & "\n")
  result.add("semantic-refs=\n" & require(q(gitBin) & " -C " & q(repo) &
    " for-each-ref --format='%(refname) %(objectname)'"))

  let indexPath = require(q(gitBin) & " -C " & q(repo) &
    " rev-parse --path-format=absolute --git-path index").strip()
  let fetchHeadPath = require(q(gitBin) & " -C " & q(repo) &
    " rev-parse --path-format=absolute --git-path FETCH_HEAD").strip()
  var administrativeFiles: seq[tuple[label, path: string]] = @[
    ("worktree-HEAD", gitDir / "HEAD"),
    ("common-HEAD", commonDir / "HEAD"),
    ("index", indexPath),
    ("FETCH_HEAD", fetchHeadPath),
    ("common-config", commonDir / "config"),
    ("common-config-worktree", commonDir / "config.worktree"),
    ("worktree-config-worktree", gitDir / "config.worktree"),
    ("packed-refs", commonDir / "packed-refs"),
    ("shallow", commonDir / "shallow")]
  administrativeFiles.sort(proc(a, b: tuple[label, path: string]): int =
    cmp(a.label, b.label))
  for item in administrativeFiles:
    result.add("admin=" & item.label & ":" & metadata(item.path) & "\n")

  result.add(treeSnapshot("common-refs", commonDir / "refs"))
  result.add(treeSnapshot("common-reflogs", commonDir / "logs"))
  if gitDir != commonDir:
    result.add(treeSnapshot("worktree-refs", gitDir / "refs"))
    result.add(treeSnapshot("worktree-reflogs", gitDir / "logs"))
  result.add(treeSnapshot("objects", commonDir / "objects"))

proc replaceWithLinkedWorktree(gitBin, path, primary: string) =
  moveDir(path, primary)
  discard require(q(gitBin) & " -C " & q(primary) &
    " checkout --detach")
  discard require(q(gitBin) & " -C " & q(primary) &
    " worktree add " & q(path) & " main")

proc report(fx: Fixture): JsonNode =
  parseFile(fx.workspace / ".repro" / "build" / "reports" / "push-report.json")

proc remoteHasLock(gitBin: string; fx: Fixture; repo, sha: string): bool =
  let path = "locks/app/" & repo & "/" & sha & ".toml"
  run(q(gitBin) & " -C " & q(fx.manifestBare) &
    " cat-file -e " & q("refs/heads/main:" & path)).code == 0

proc capabilityDir(gitBin: string; fx: Fixture): string =
  let common = require(q(gitBin) & " -C " & q(fx.manifests) &
    " rev-parse --git-common-dir").strip()
  let absCommon = if common.isAbsolute: common else: fx.manifests / common
  absCommon / "reprobuild" / "hook-capabilities"

suite "protocol v2 real-hook repro push closure":
  test "routing config isolation restores exact ambient values after exception":
    let original = snapshotRoutingConfig()
    defer: restoreRoutingConfig(original)
    let fx = Fixture(
      scratch: getTempDir() / "routing isolation scratch",
      workspace: getTempDir() / "routing isolation workspace")

    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG"]:
      delEnv(name)
    expect ValueError:
      failAfterRoutingIsolation(fx)
    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG"]:
      check not existsEnv(name)

    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG"]:
      putEnv(name, "")
    expect ValueError:
      failAfterRoutingIsolation(fx)
    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG"]:
      check existsEnv(name)
      check getEnv(name) == ""

    let hostile = [
      ("REPROBUILD_SYSTEM_CONFIG", "system ; $(not-run) = 'hostile value'"),
      ("REPROBUILD_USER_CONFIG", "user & | < > = \"hostile value\""),
      ("REPROBUILD_VCS_PRIVATE_CONFIG", "vcs * ? [ ] = hostile value")]
    for entry in hostile:
      putEnv(entry[0], entry[1])
    expect ValueError:
      failAfterRoutingIsolation(fx)
    for entry in hostile:
      check existsEnv(entry[0])
      check getEnv(entry[0]) == entry[1]

  test "custom remote accepts a detached HEAD contained by an advertised tip":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "detached-advertised-ancestor",
        customCoreRemote = true)
      defer: removeDir(fx.scratch)
      let detachedHead = require(q(gitBin) & " -C " & q(fx.core) &
        " rev-parse HEAD").strip()
      let peer = fx.scratch / "core-peer"
      clone(gitBin, fx.coreBare, peer)
      discard require(q(gitBin) & " -C " & q(peer) &
        " commit --allow-empty -m 'advertised descendant'")
      discard require(q(gitBin) & " -C " & q(peer) &
        " push origin HEAD:main")
      let advertisedTip = remoteHead(gitBin, fx.coreBare)
      check advertisedTip != detachedHead
      discard require(q(gitBin) & " -C " & q(fx.core) &
        " checkout --detach " & q(detachedHead))
      installHooks(fx)
      # The descendant exists only at the non-origin push destination. The
      # classification must inspect it through an isolated probe, not fetch it
      # (or anything else) into this detached source checkout.
      check run(q(gitBin) & " -C " & q(fx.core) & " cat-file -e " &
        q(advertisedTip & "^{commit}")).code != 0
      let sourceBefore = sourceStorageSnapshot(gitBin, fx.core)

      # Missing lock records make final completion fail, but source
      # classification must already have accepted the detached ancestor as
      # published through the manifest-selected non-origin remote.
      let stopped = invokePush(fx)
      check stopped.code != 0
      let stoppedReport = report(fx)
      check stoppedReport["stoppedStage"].getStr() ==
        "final-lock-verification"
      check stoppedReport["repos"][0]["name"].getStr() == "core"
      check stoppedReport["repos"][0]["branch"].getStr() == ""
      check stoppedReport["repos"][0]["headSha"].getStr() == detachedHead
      check stoppedReport["repos"][0]["outcome"].getStr() ==
        "already-published"
      check remoteHead(gitBin, fx.coreBare) == advertisedTip
      check run(q(gitBin) & " -C " & q(fx.core) & " cat-file -e " &
        q(advertisedTip & "^{commit}")).code != 0
      check sourceStorageSnapshot(gitBin, fx.core) == sourceBefore

  test "linked source worktree is discovered and published through real hooks":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "linked-source")
      defer: removeDir(fx.scratch)
      replaceWithLinkedWorktree(gitBin, fx.core,
        fx.scratch / "core-primary")
      let coreSha = commit(fx, gitBin, fx.core, "linked-core-outgoing")
      installHooks(fx)
      let pushed = fx.withHookCli(q(gitBin) & " -C " & q(fx.core) &
        " push origin HEAD:main")
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHasLock(gitBin, fx, "core", coreSha)

  test "linked lock backend stages commits and completes exact publication":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "linked-backend")
      defer: removeDir(fx.scratch)
      replaceWithLinkedWorktree(gitBin, fx.manifests,
        fx.scratch / "manifest-primary")
      let coreSha = commit(fx, gitBin, fx.core, "linked-backend-outgoing")
      installHooks(fx)
      let pushed = fx.withHookCli(q(gitBin) & " -C " & q(fx.core) &
        " push origin HEAD:main")
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHasLock(gitBin, fx, "core", coreSha)

  test "raw outgoing control and dependency-first closure publish exact locks":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "success")
      defer: removeDir(fx.scratch)
      let coreSha = commit(fx, gitBin, fx.core, "core-outgoing")
      installHooks(fx)
      let rawCore = fx.withHookCli(q(gitBin) & " -C " & q(fx.core) &
        " push origin HEAD:main")
      if rawCore.code != 0: checkpoint(rawCore.output)
      check rawCore.code == 0
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHasLock(gitBin, fx, "core", coreSha)

      let libSha = commit(fx, gitBin, fx.lib, "lib-outgoing")
      let appSha = commit(fx, gitBin, fx.app, "app-outgoing")
      discard commit(fx, gitBin, fx.other, "unrelated-outgoing")
      let pushed = invokePush(fx)
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      check remoteHead(gitBin, fx.libBare) == libSha
      check remoteHead(gitBin, fx.appBare) == appSha
      check remoteHasLock(gitBin, fx, "lib", libSha)
      check remoteHasLock(gitBin, fx, "app", appSha)
      check remoteHead(gitBin, fx.otherBare) !=
        require(q(gitBin) & " -C " & q(fx.other) & " rev-parse HEAD").strip()
      let r = report(fx)
      check r["order"][0].getStr() == "core"
      check r["order"][1].getStr() == "lib"
      check r["order"][2].getStr() == "app"
      check r["lockPublished"].getBool()
      check readFile(fx.manifestPrePushLog).splitLines().allIt(
        it.len == 0 or it == "cap= legacy= context=")
      check readFile(fx.manifestPostCommitLog).splitLines().allIt(
        it.len == 0 or it == "context=")
      let capDir = capabilityDir(gitBin, fx)
      if dirExists(capDir):
        check toSeq(walkDir(capDir)).len == 0

  test "raw dependent refuses unpublished dependency":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "dependency-refusal")
      defer: removeDir(fx.scratch)
      discard commit(fx, gitBin, fx.core, "core-unpublished")
      discard commit(fx, gitBin, fx.lib, "lib-outgoing")
      installHooks(fx)
      let refused = fx.withHookCli(q(gitBin) & " -C " & q(fx.lib) &
        " push origin HEAD:main")
      check refused.code != 0
      check "core" in refused.output
      check "unpublished" in refused.output

  test "already-published closure without records fails honestly on retry":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "missing-lock")
      defer: removeDir(fx.scratch)
      installHooks(fx)
      let before = remoteHead(gitBin, fx.manifestBare)
      for attempt in 0 .. 1:
        let failed = invokePush(fx)
        check failed.code != 0
        let r = report(fx)
        check r["stoppedStage"].getStr() == "final-lock-verification"
        check "repro workspace lock" in r["retryCommand"].getStr()
        check r["repos"][0]["outcome"].getStr() == "already-published"
        check remoteHead(gitBin, fx.manifestBare) == before

  test "three-repo retry resumes verified core backend prefix":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "backend-prefix-recovery")
      defer: removeDir(fx.scratch)
      let coreSha = commit(fx, gitBin, fx.core, "core-prefix-recovery")
      let libSha = commit(fx, gitBin, fx.lib, "lib-prefix-recovery")
      let appSha = commit(fx, gitBin, fx.app, "app-prefix-recovery")
      installHooks(fx)
      let sourceBefore = @[
        remoteHead(gitBin, fx.coreBare),
        remoteHead(gitBin, fx.libBare),
        remoteHead(gitBin, fx.appBare)]
      let backendBefore = remoteHead(gitBin, fx.manifestBare)
      let reject = fx.manifestBare / "hooks" / "pre-receive"
      executable(reject,
        "#!/usr/bin/env sh\ncat >/dev/null\nexit 73\n")

      let failed = invokePush(fx)
      if failed.code == 0: checkpoint(failed.output)
      check failed.code != 0
      check remoteHead(gitBin, fx.coreBare) == sourceBefore[0]
      check remoteHead(gitBin, fx.libBare) == sourceBefore[1]
      check remoteHead(gitBin, fx.appBare) == sourceBefore[2]
      check remoteHead(gitBin, fx.manifestBare) == backendBefore
      let retained = require(q(gitBin) & " -C " & q(fx.manifests) &
        " rev-parse HEAD").strip()
      check retained != backendBefore
      check run(q(gitBin) & " -C " & q(fx.manifests) & " cat-file -e " &
        q(retained & ":locks/app/core/" & coreSha & ".toml")).code == 0
      check run(q(gitBin) & " -C " & q(fx.manifests) & " cat-file -e " &
        q(retained & ":locks/app/lib/" & libSha & ".toml")).code != 0
      check run(q(gitBin) & " -C " & q(fx.manifests) & " cat-file -e " &
        q(retained & ":locks/app/app/" & appSha & ".toml")).code != 0

      removeFile(reject)
      let retried = invokePush(fx)
      if retried.code != 0: checkpoint(retried.output)
      check retried.code == 0
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHead(gitBin, fx.libBare) == libSha
      check remoteHead(gitBin, fx.appBare) == appSha
      check remoteHasLock(gitBin, fx, "core", coreSha)
      check remoteHasLock(gitBin, fx, "lib", libSha)
      check remoteHasLock(gitBin, fx, "app", appSha)
      let completedBackend = remoteHead(gitBin, fx.manifestBare)
      check completedBackend ==
        require(q(gitBin) & " -C " & q(fx.manifests) &
          " rev-parse HEAD").strip()
      check run(q(gitBin) & " -C " & q(fx.manifestBare) &
        " merge-base --is-ancestor " & q(retained) & " " &
        q(completedBackend)).code == 0

  test "three-repo backend-ahead recovery rejects every invalid prefix shape":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      for failure in ["unexpected-valid", "tampered-prefix", "gap"]:
        let fx = setup(gitBin, "invalid-backend-prefix-" & failure)
        defer: removeDir(fx.scratch)
        let coreSha = commit(fx, gitBin, fx.core,
          "core-invalid-prefix-" & failure)
        let libSha = commit(fx, gitBin, fx.lib,
          "lib-invalid-prefix-" & failure)
        let appSha = commit(fx, gitBin, fx.app,
          "app-invalid-prefix-" & failure)
        let otherSha = remoteHead(gitBin, fx.otherBare)

        case failure
        of "unexpected-valid":
          # A real expected first record followed by a structurally valid but
          # operation-external record is still not a recoverable prefix.
          writeLockRecord(fx.manifests, "core", "core", coreSha)
          writeLockRecord(fx.manifests, "other", "other", otherSha)
        of "tampered-prefix":
          # Preserve valid TOML and the expected pathname while binding its
          # typed source revision to a different closure member.
          writeLockRecord(fx.manifests, "core", "core", coreSha,
            validLockRecord("core", "core", coreSha).replace(
              "revision = \"" & coreSha & "\"",
              "revision = \"" & libSha & "\""))
        of "gap":
          # The second topological member cannot appear without the first.
          writeLockRecord(fx.manifests, "lib", "lib", libSha)
        else:
          check false
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " add locks")
        discard require(q(gitBin) & " -C " & q(fx.manifests) &
          " commit --no-verify -m " & q("invalid recovery " & failure))
        installHooks(fx)

        let sourceLocal = @[
          require(q(gitBin) & " -C " & q(fx.core) &
            " rev-parse HEAD").strip(),
          require(q(gitBin) & " -C " & q(fx.lib) &
            " rev-parse HEAD").strip(),
          require(q(gitBin) & " -C " & q(fx.app) &
            " rev-parse HEAD").strip()]
        let sourceRemote = @[
          remoteHead(gitBin, fx.coreBare),
          remoteHead(gitBin, fx.libBare),
          remoteHead(gitBin, fx.appBare)]
        check sourceLocal == @[coreSha, libSha, appSha]
        let backendLocal = require(q(gitBin) & " -C " & q(fx.manifests) &
          " rev-parse HEAD").strip()
        let backendRemote = remoteHead(gitBin, fx.manifestBare)
        let backendRefs = require(q(gitBin) & " -C " & q(fx.manifests) &
          " for-each-ref --format='%(refname) %(objectname)'")
        let backendStatus = require(q(gitBin) & " -C " & q(fx.manifests) &
          " status --porcelain")
        let recordState = backendRecordState(gitBin, fx.manifests)

        let stopped = invokePush(fx)
        if stopped.code == 0: checkpoint(stopped.output)
        check stopped.code != 0
        let stoppedReport = report(fx)
        check stoppedReport["stoppedStage"].getStr() ==
          "lock-backend-preflight"
        check "unverified lock backend ahead chain" in
          stoppedReport["lockDiagnostic"].getStr()
        for index, source in [fx.core, fx.lib, fx.app]:
          check require(q(gitBin) & " -C " & q(source) &
            " rev-parse HEAD").strip() == sourceLocal[index]
        check remoteHead(gitBin, fx.coreBare) == sourceRemote[0]
        check remoteHead(gitBin, fx.libBare) == sourceRemote[1]
        check remoteHead(gitBin, fx.appBare) == sourceRemote[2]
        check require(q(gitBin) & " -C " & q(fx.manifests) &
          " rev-parse HEAD").strip() == backendLocal
        check remoteHead(gitBin, fx.manifestBare) == backendRemote
        check require(q(gitBin) & " -C " & q(fx.manifests) &
          " for-each-ref --format='%(refname) %(objectname)'") == backendRefs
        check require(q(gitBin) & " -C " & q(fx.manifests) &
          " status --porcelain") == backendStatus
        check backendRecordState(gitBin, fx.manifests) == recordState

  test "later receive failure reports prefix and retry resumes":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "partial")
      defer: removeDir(fx.scratch)
      let coreSha = commit(fx, gitBin, fx.core, "core-partial")
      let libSha = commit(fx, gitBin, fx.lib, "lib-partial")
      let appSha = commit(fx, gitBin, fx.app, "app-partial")
      installHooks(fx)
      let reject = fx.libBare / "hooks" / "pre-receive"
      executable(reject, "#!/usr/bin/env sh\ncat >/dev/null\nexit 73\n")
      let failed = invokePush(fx)
      check failed.code != 0
      let first = report(fx)
      check first["repos"][0]["name"].getStr() == "core"
      check first["repos"][0]["outcome"].getStr() == "pushed"
      check first["repos"][0]["headSha"].getStr() == coreSha
      check first["repos"][1]["name"].getStr() == "lib"
      check first["repos"][1]["outcome"].getStr() == "failed"
      check first["stoppedRepo"].getStr() == "lib"
      check first["stoppedStage"].getStr() == "source-push"
      check first["retryCommand"].getStr() == "repro push --sync --rebase"
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHead(gitBin, fx.libBare) != libSha
      check remoteHead(gitBin, fx.appBare) != appSha
      removeFile(reject)
      let retried = invokePush(fx)
      if retried.code != 0: checkpoint(retried.output)
      check retried.code == 0
      check remoteHead(gitBin, fx.libBare) == libSha
      check remoteHead(gitBin, fx.appBare) == appSha

  test "first source drift after global preflight is caught before transport":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "first-revalidation")
      defer: removeDir(fx.scratch)
      discard commit(fx, gitBin, fx.core, "core-first-revalidation")
      discard commit(fx, gitBin, fx.lib, "lib-first-revalidation")
      discard commit(fx, gitBin, fx.app, "app-first-revalidation")
      installHooks(fx)
      let beforeCore = remoteHead(gitBin, fx.coreBare)
      let beforeLib = remoteHead(gitBin, fx.libBare)
      let beforeApp = remoteHead(gitBin, fx.appBare)
      let once = fx.scratch / "upload-pack-mutated"
      let uploadPack = fx.scratch / "mutating-upload-pack"
      executable(uploadPack,
        "#!/usr/bin/env sh\nset -eu\n" &
        "if [ ! -e " & q(once) & " ]; then\n" &
        "  : > " & q(once) & "\n" &
        "  printf '%s\\n' drift > " & q(fx.core / "preflight-drift.txt") &
          "\nfi\n" &
        "exec " & q(gitBin) & " upload-pack \"$1\"\n")
      discard require(q(gitBin) & " -C " & q(fx.core) &
        " remote set-url --push origin " &
        q("ext::" & uploadPack & " " & fx.coreBare))
      let priorAllowedProtocols = getEnv("GIT_ALLOW_PROTOCOL")
      putEnv("GIT_ALLOW_PROTOCOL", "ext:file")
      defer:
        if priorAllowedProtocols.len > 0:
          putEnv("GIT_ALLOW_PROTOCOL", priorAllowedProtocols)
        else:
          delEnv("GIT_ALLOW_PROTOCOL")
      let stopped = invokePush(fx)
      check stopped.code != 0
      let stoppedReport = report(fx)
      check stoppedReport["stoppedRepo"].getStr() == "core"
      check stoppedReport["stoppedStage"].getStr() == "source-revalidation"
      check remoteHead(gitBin, fx.coreBare) == beforeCore
      check remoteHead(gitBin, fx.libBare) == beforeLib
      check remoteHead(gitBin, fx.appBare) == beforeApp

  test "later source drift after an earlier push stops the remaining suffix":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "later-revalidation")
      defer: removeDir(fx.scratch)
      let coreSha = commit(fx, gitBin, fx.core, "core-later-revalidation")
      discard commit(fx, gitBin, fx.lib, "lib-later-revalidation")
      discard commit(fx, gitBin, fx.app, "app-later-revalidation")
      let beforeLib = remoteHead(gitBin, fx.libBare)
      let beforeApp = remoteHead(gitBin, fx.appBare)
      executable(fx.core / ".git" / "hooks" / "pre-push",
        "#!/usr/bin/env sh\nset -eu\n" &
        "printf '%s\\n' drift > " & q(fx.lib / "earlier-push-drift.txt") &
          "\ncat >/dev/null\n")
      installHooks(fx)
      let stopped = invokePush(fx)
      check stopped.code != 0
      let stoppedReport = report(fx)
      check stoppedReport["stoppedRepo"].getStr() == "lib"
      check stoppedReport["stoppedStage"].getStr() == "source-revalidation"
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHead(gitBin, fx.libBare) == beforeLib
      check remoteHead(gitBin, fx.appBare) == beforeApp

  test "published-at-preflight later member is revalidated after earlier hook":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      for drift in ["dirty", "head", "branch", "remote"]:
        let fx = setup(gitBin, "published-revalidation-" & drift)
        defer: removeDir(fx.scratch)
        let coreSha = remoteHead(gitBin, fx.coreBare)
        let beforeLib = remoteHead(gitBin, fx.libBare)
        let beforeApp = remoteHead(gitBin, fx.appBare)
        let beforeManifest = remoteHead(gitBin, fx.manifestBare)
        # An attached notes ref makes the already-published core execute a real
        # pre-push hook without moving its source branch. The preserved hook
        # mutates the later published member; source revalidation must catch it
        # before either that member or the backend is transported.
        discard require(q(gitBin) & " -C " & q(fx.core) &
          " notes --ref=refs/notes/reprobuild/certificates add -m " &
          q("revalidation fixture " & drift) & " HEAD")
        let alternate = fx.scratch / "alternate-lib.git"
        if drift == "remote":
          discard require(q(gitBin) & " clone --bare " & q(fx.libBare) &
            " " & q(alternate))
        let mutation =
          case drift
          of "dirty":
            "printf '%s\\n' drift > " &
              q(fx.lib / "published-preflight-drift.txt")
          of "head":
            q(gitBin) & " -C " & q(fx.lib) &
              " commit --allow-empty --no-verify -m drift"
          of "branch":
            q(gitBin) & " -C " & q(fx.lib) & " branch drift HEAD\n" &
              q(gitBin) & " -C " & q(fx.lib) &
              " symbolic-ref HEAD refs/heads/drift"
          of "remote":
            q(gitBin) & " -C " & q(fx.lib) &
              " remote set-url --push origin " & q(fileUrl(alternate))
          else: ""
        executable(fx.core / ".git" / "hooks" / "pre-push",
          "#!/usr/bin/env sh\nset -eu\n" & mutation &
            "\ncat >/dev/null\nexit 73\n")
        installHooks(fx)
        let stopped = invokePush(fx)
        if stopped.code == 0: checkpoint(stopped.output)
        check stopped.code != 0
        let stoppedReport = report(fx)
        check stoppedReport["repos"][0]["name"].getStr() == "core"
        check stoppedReport["repos"][0]["outcome"].getStr() ==
          "already-published"
        check stoppedReport["repos"][1]["name"].getStr() == "lib"
        check stoppedReport["repos"][1]["outcome"].getStr() == "failed"
        check stoppedReport["stoppedRepo"].getStr() == "lib"
        check stoppedReport["stoppedStage"].getStr() ==
          "source-revalidation"
        let diagnostic =
          stoppedReport["repos"][1]["diagnostic"].getStr()
        case drift
        of "dirty": check "working tree changed after preflight" in diagnostic
        of "head": check "HEAD changed after preflight" in diagnostic
        of "branch": check "branch changed after preflight" in diagnostic
        of "remote":
          check "remote location changed after preflight" in diagnostic
        else: check false

        # The preserved hook deliberately refuses its notes transport after
        # causing the fixture drift. The carry is best-effort, so `repro push`
        # continues to the later member and must revalidate it; no source ref
        # or lock backend may advance.
        check remoteHead(gitBin, fx.coreBare) == coreSha
        check remoteHead(gitBin, fx.libBare) == beforeLib
        check remoteHead(gitBin, fx.appBare) == beforeApp
        check remoteHead(gitBin, fx.manifestBare) == beforeManifest
        check not remoteHasLock(gitBin, fx, "core", coreSha)
        check not remoteHasLock(gitBin, fx, "lib", beforeLib)
        check not remoteHasLock(gitBin, fx, "app", beforeApp)

  test "fresh push advertisements catch a later remote branch deletion":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "published-remote-deletion")
      defer: removeDir(fx.scratch)
      let libMirror = fx.scratch / "lib-mirror.git"
      discard require(q(gitBin) & " clone --bare " & q(fx.libBare) & " " &
        q(libMirror))
      # Exercise Git's plural push-url semantics: a no-op is valid only when
      # HEAD is advertised as reachable at every destination.
      discard require(q(gitBin) & " -C " & q(fx.lib) &
        " remote set-url --add --push origin " & q(fileUrl(fx.libBare)))
      discard require(q(gitBin) & " -C " & q(fx.lib) &
        " remote set-url --add --push origin " & q(fileUrl(libMirror)))

      discard require(q(gitBin) & " -C " & q(fx.core) &
        " notes --ref=refs/notes/reprobuild/certificates add -m " &
        q("delete later advertised branch") & " HEAD")
      executable(fx.core / ".git" / "hooks" / "pre-push",
        "#!/usr/bin/env sh\nset -eu\n" &
        q(gitBin) & " --git-dir=" & q(fx.libBare) &
          " update-ref -d refs/heads/main\n" &
        "cat >/dev/null\nexit 73\n")
      installHooks(fx)

      let localHeads = @[
        require(q(gitBin) & " -C " & q(fx.core) & " rev-parse HEAD").strip(),
        require(q(gitBin) & " -C " & q(fx.lib) & " rev-parse HEAD").strip(),
        require(q(gitBin) & " -C " & q(fx.app) & " rev-parse HEAD").strip()]
      let sourceState = @[
        sourceStorageSnapshot(gitBin, fx.core),
        sourceStorageSnapshot(gitBin, fx.lib),
        sourceStorageSnapshot(gitBin, fx.app)]
      let coreRemote = remoteHead(gitBin, fx.coreBare)
      let deletedLibRemote = remoteHead(gitBin, fx.libBare)
      let mirrorRemote = remoteHead(gitBin, libMirror)
      let appRemote = remoteHead(gitBin, fx.appBare)
      let backendLocal = require(q(gitBin) & " -C " & q(fx.manifests) &
        " rev-parse HEAD").strip()
      let backendRemote = remoteHead(gitBin, fx.manifestBare)
      let backendStatus = require(q(gitBin) & " -C " & q(fx.manifests) &
        " status --porcelain")
      let backendRecords = backendRecordState(gitBin, fx.manifests)

      let stopped = invokePush(fx)
      if stopped.code == 0: checkpoint(stopped.output)
      check stopped.code != 0
      let stoppedReport = report(fx)
      check stoppedReport["repos"][0]["name"].getStr() == "core"
      check stoppedReport["repos"][0]["outcome"].getStr() ==
        "already-published"
      check stoppedReport["repos"][1]["name"].getStr() == "lib"
      check stoppedReport["repos"][1]["outcome"].getStr() == "failed"
      check stoppedReport["stoppedRepo"].getStr() == "lib"
      check stoppedReport["stoppedStage"].getStr() == "source-revalidation"
      check "exact destination advertisement changed after preflight" in
        stoppedReport["repos"][1]["diagnostic"].getStr()

      check not branchExists(gitBin, fx.libBare)
      check deletedLibRemote == localHeads[1]
      check remoteHead(gitBin, libMirror) == mirrorRemote
      check remoteHead(gitBin, fx.coreBare) == coreRemote
      check remoteHead(gitBin, fx.appBare) == appRemote
      check remoteHead(gitBin, fx.manifestBare) == backendRemote
      check require(q(gitBin) & " -C " & q(fx.manifests) &
        " rev-parse HEAD").strip() == backendLocal
      check require(q(gitBin) & " -C " & q(fx.manifests) &
        " status --porcelain") == backendStatus
      check backendRecordState(gitBin, fx.manifests) == backendRecords
      for index, source in [fx.core, fx.lib, fx.app]:
        check require(q(gitBin) & " -C " & q(source) &
          " rev-parse HEAD").strip() == localHeads[index]
        check sourceStorageSnapshot(gitBin, source) == sourceState[index]
      check not remoteHasLock(gitBin, fx, "core", localHeads[0])
      check not remoteHasLock(gitBin, fx, "lib", localHeads[1])
      check not remoteHasLock(gitBin, fx, "app", localHeads[2])

  test "divergent second push URL refuses globally without any mutation":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      let fx = setup(gitBin, "divergent-second-push-url")
      defer: removeDir(fx.scratch)
      let second = fx.scratch / "core-second.git"
      discard require(q(gitBin) & " clone --bare " & q(fx.coreBare) & " " &
        q(second))
      let peer = fx.scratch / "core-second-peer"
      clone(gitBin, second, peer)
      discard require(q(gitBin) & " -C " & q(peer) &
        " commit --allow-empty -m 'second destination divergence'")
      discard require(q(gitBin) & " -C " & q(peer) &
        " push origin HEAD:main")
      let firstBefore = remoteHead(gitBin, fx.coreBare)
      let secondBefore = remoteHead(gitBin, second)
      let outgoing = commit(fx, gitBin, fx.core,
        "first-destination-fast-forwardable")
      check outgoing != firstBefore
      check outgoing != secondBefore
      discard require(q(gitBin) & " -C " & q(fx.core) &
        " remote set-url --add --push origin " &
        q(fileUrl(fx.coreBare)))
      discard require(q(gitBin) & " -C " & q(fx.core) &
        " remote set-url --add --push origin " &
        q(fileUrl(second)))
      installHooks(fx)

      let sourceBefore = @[
        sourceStorageSnapshot(gitBin, fx.core),
        sourceStorageSnapshot(gitBin, fx.lib),
        sourceStorageSnapshot(gitBin, fx.app)]
      let sourceRemoteBefore = @[
        remoteHead(gitBin, fx.coreBare),
        remoteHead(gitBin, fx.libBare),
        remoteHead(gitBin, fx.appBare)]
      let backendHeadBefore = require(q(gitBin) & " -C " & q(fx.manifests) &
        " rev-parse HEAD").strip()
      let backendRemoteBefore = remoteHead(gitBin, fx.manifestBare)
      let backendStatusBefore = require(q(gitBin) & " -C " &
        q(fx.manifests) & " status --porcelain")
      let backendRecordsBefore = backendRecordState(gitBin, fx.manifests)

      let stopped = invokePush(fx)
      if stopped.code == 0: checkpoint(stopped.output)
      check stopped.code != 0
      let stoppedReport = report(fx)
      check stoppedReport["stoppedRepo"].getStr() == "core"
      check stoppedReport["stoppedStage"].getStr() ==
        "divergence-preflight"
      let diagnostic = stoppedReport["repos"][0]["diagnostic"].getStr()
      check "divergent exact push destination branch" in diagnostic
      check fx.coreBare notin diagnostic
      check second notin diagnostic

      check remoteHead(gitBin, fx.coreBare) == firstBefore
      check remoteHead(gitBin, second) == secondBefore
      check remoteHead(gitBin, fx.libBare) == sourceRemoteBefore[1]
      check remoteHead(gitBin, fx.appBare) == sourceRemoteBefore[2]
      check require(q(gitBin) & " -C " & q(fx.manifests) &
        " rev-parse HEAD").strip() == backendHeadBefore
      check remoteHead(gitBin, fx.manifestBare) == backendRemoteBefore
      check require(q(gitBin) & " -C " & q(fx.manifests) &
        " status --porcelain") == backendStatusBefore
      check backendRecordState(gitBin, fx.manifests) ==
        backendRecordsBefore
      for index, source in [fx.core, fx.lib, fx.app]:
        check sourceStorageSnapshot(gitBin, source) == sourceBefore[index]

  test "routed team and personal backends preflight and complete independently":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      var fx = setup(gitBin, "routed")
      defer: removeDir(fx.scratch)
      let routingEnvironment = isolateRoutingConfig(fx)
      defer: restoreRoutingConfig(routingEnvironment)
      enableRoutedBackends(gitBin, fx)
      installHooks(fx)
      let coreSha = commit(fx, gitBin, fx.core, "core-routed")
      let libSha = commit(fx, gitBin, fx.lib, "lib-routed")
      let appSha = commit(fx, gitBin, fx.app, "app-routed")
      let pushed = invokePush(fx)
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      check bareHasLock(gitBin, fx.teamLocksBare, "core", coreSha)
      check bareHasLock(gitBin, fx.teamLocksBare, "app", appSha)
      check not bareHasLock(gitBin, fx.teamLocksBare, "lib", libSha)
      check bareHasLock(gitBin, fx.personalLocksBare, "lib", libSha)
      check not bareHasLock(gitBin, fx.personalLocksBare, "app", appSha)

      # Personal-tier failure is deliberately non-blocking: shared records and
      # source refs still land, while the unavailable personal record does not.
      let personalManaged = fx.personalLocks / ".git" / "hooks" /
        "pre-push.repro-managed"
      writeFile(personalManaged,
        "#!/usr/bin/env sh\n# reprobuild managed pre-push hook protocol=2\nexit 0\n")
      let stoppedCoreSha = commit(fx, gitBin, fx.core,
        "core-preflight-stop")
      let stoppedLibSha = commit(fx, gitBin, fx.lib,
        "lib-preflight-stop")
      let stoppedAppSha = commit(fx, gitBin, fx.app,
        "app-preflight-stop")
      let stopped = invokePush(fx)
      if stopped.code != 0: checkpoint(stopped.output)
      check stopped.code == 0
      let stoppedReport = report(fx)
      check stoppedReport["stoppedStage"].getStr() == ""
      check stoppedReport["lockDiagnostic"].getStr().contains(
        "warning: personal")
      check remoteHead(gitBin, fx.coreBare) == stoppedCoreSha
      check remoteHead(gitBin, fx.libBare) == stoppedLibSha
      check remoteHead(gitBin, fx.appBare) == stoppedAppSha
      check bareHasLock(gitBin, fx.teamLocksBare, "core", coreSha)
      check bareHasLock(gitBin, fx.teamLocksBare, "app", appSha)
      check bareHasLock(gitBin, fx.personalLocksBare, "lib", libSha)
      check bareHasLock(gitBin, fx.teamLocksBare, "core", stoppedCoreSha)
      check bareHasLock(gitBin, fx.teamLocksBare, "app", stoppedAppSha)
      check not bareHasLock(gitBin, fx.personalLocksBare, "lib", stoppedLibSha)

  test "every later shared backend failure is discovered before source mutation":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      for failure in ["dirty", "auth", "divergent", "unverified-ahead"]:
        var fx = setup(gitBin, "backend-preflight-" & failure)
        defer: removeDir(fx.scratch)
        let routingEnvironment = isolateRoutingConfig(fx)
        defer: restoreRoutingConfig(routingEnvironment)
        enableRoutedBackends(gitBin, fx)
        let routing = fx.routedConfig()
        writeFile(routing, readFile(routing).replace(
          "visibility = \"personal\"", "visibility = \"team\""))
        discard commit(fx, gitBin, fx.core, "core-before-" & failure)
        discard commit(fx, gitBin, fx.lib, "lib-before-" & failure)
        discard commit(fx, gitBin, fx.app, "app-before-" & failure)

        case failure
        of "dirty":
          writeFile(fx.personalLocks / "operator-dirty.txt", "preserve\n")
        of "auth":
          discard require(q(gitBin) & " -C " & q(fx.personalLocks) &
            " remote set-url origin " & q(fx.scratch / "missing-auth.git"))
        of "divergent":
          discard commit(fx, gitBin, fx.personalLocks, "local-divergence")
          let peer = fx.scratch / "personal-peer"
          clone(gitBin, fx.personalLocksBare, peer)
          discard commit(fx, gitBin, peer, "remote-divergence")
          discard require(q(gitBin) & " -C " & q(peer) &
            " push origin HEAD:main")
        of "unverified-ahead":
          discard commit(fx, gitBin, fx.personalLocks, "non-lock-ahead")
        else:
          discard
        installHooks(fx)

        let sourceHeads = [
          remoteHead(gitBin, fx.coreBare),
          remoteHead(gitBin, fx.libBare),
          remoteHead(gitBin, fx.appBare)]
        let backendLocal = require(q(gitBin) & " -C " & q(fx.personalLocks) &
          " rev-parse HEAD").strip()
        let backendRemote = remoteHead(gitBin, fx.personalLocksBare)
        let backendStatus = require(q(gitBin) & " -C " & q(fx.personalLocks) &
          " status --porcelain")
        let stopped = invokePush(fx)
        check stopped.code != 0
        let stoppedReport = report(fx)
        check stoppedReport["stoppedStage"].getStr() ==
          "lock-backend-preflight"
        check remoteHead(gitBin, fx.coreBare) == sourceHeads[0]
        check remoteHead(gitBin, fx.libBare) == sourceHeads[1]
        check remoteHead(gitBin, fx.appBare) == sourceHeads[2]
        check require(q(gitBin) & " -C " & q(fx.personalLocks) &
          " rev-parse HEAD").strip() == backendLocal
        check remoteHead(gitBin, fx.personalLocksBare) == backendRemote
        check require(q(gitBin) & " -C " & q(fx.personalLocks) &
          " status --porcelain") == backendStatus
