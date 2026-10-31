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
## core prefix before a retry completes. A shared backend's preflight accepts
## untracked output under its ``.repro/build/`` and nothing else uncommitted.
## A dependency parked on a local-only ``reprobuild/pinned/<short-sha>`` branch
## at a commit its upstream already carries is classified already-published,
## never transmitted to (or creating a branch on) that upstream, while an
## existing remote branch of the checkout's own name that is behind HEAD is
## still advanced. The manifest's preserved hooks observe
## no capability/context, while successful nested pushes and empty capability
## storage prove one-use authorization was exercised. All source publication
## uses local Git processes, filesystem hooks, worktrees, and bare remotes.
## A stored certificate reaches each component member's remote through that
## member's own hook, a retained prefix's included.
## The interpreter-skew case alone stubs an obsolete CLI's protocol handshake:
## this isolates version negotiation without embedding an old release binary,
## and it refuses before any source Git transport can run.
## It runs cross-platform wherever Git supplies its hook shell; POSIX capability
## metadata has a dedicated suite. Wrong ordering, an advanced unrelated bare,
## a missing exact lock blob, or a hidden partial failure each falsifies a case.

import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles,
  unittest]

import repro_cli_support
import repro_cli_support/push_hook_protocol
import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests

const ObsoleteComponentProtocolEnv = "REPRO_TEST_OBSOLETE_COMPONENT_PROTOCOL"

# A native helper mode keeps the deliberately obsolete protocol peer usable
# on Windows too; CreateProcess cannot execute a bare POSIX script there.
if getEnv(ObsoleteComponentProtocolEnv) == "1":
  let args = commandLineParams()
  if args.len >= 2 and args[0] == "hooks" and args[1] == "protocol":
    if "--require-source-component" in args: quit(2)
    stdout.writeLine("2")
    quit(0)
  quit(87)

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
  "[project]\nname = \"app\"\n" &
  "\n" &
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
  result = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\nmainline = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [")
    for i, dep in depends:
      if i > 0: result.add(", ")
      result.add("\"" & dep & "\"")
    result.add("]\n")

proc repoTomlWithLocalRemote(name, projectRemote, localRemote: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
  "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
  "remote = \"" & localRemote & "\"\nmainline = \"main\"\n" &
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
  # Central lock publication is OPT-IN (MO-14, Workspace-Manifests.md
  # §"`publish_locks` — central publication is opt-in"). Without
  # `[manifest] publish_locks = true` a passing gate writes the record and
  # does NOT publish it, so every "the lock reached the manifest bare" check
  # below would be asking for something this workspace never enabled.
  writeFile(result.workspace / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[records]\n" &
    "url = \"" & fileUrl(result.manifestBare) & "\"\n" &
    "publish_locks = true\n")
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

proc storeCertificateForHead(gitBin: string; fx: Fixture; repo: string) =
  ## Put a certificate for ``repo``'s HEAD tree in a store private to this
  ## fixture (the children inherit its location), and write no note.
  putEnv("TEST_CERTIFICATES_DIR", fx.scratch / "store-user")
  putEnv("TEST_CERTIFICATES_SYSTEM_DIR", fx.scratch / "store-system")
  let head = require(q(gitBin) & " -C " & q(repo) & " rev-parse HEAD").strip()
  let tree = require(q(gitBin) & " -C " & q(repo) &
    " rev-parse HEAD^{tree}").strip()
  let cert = TestCertificate(schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId, project: repo.extractFilename,
    platform: currentPlatformTag(), targets: @["t-unit"], result: tcrPassed,
    issuedAt: "2026-10-31T00:00:00Z", issuer: "real-hooks-fixture",
    vcs: TestCertificateVcs(repo: repo.extractFilename,
      content: "git-tree-sha1:" & tree, base: head),
    commands: @[TestCertificateCommand(argv: @["true"])])
  doAssert publishCertificateToLocalStore(cert, repo).written

proc remoteNoteOnHeadTree(gitBin, bare: string): tuple[code: int; output: string] =
  ## The certificate note on the tree of ``bare``'s main branch.
  let tree = require(q(gitBin) & " -C " & q(bare) &
    " rev-parse refs/heads/main^{tree}").strip()
  run(q(gitBin) & " -C " & q(bare) &
    " notes --ref=refs/notes/test-certificates/certificates show " & tree)

proc invokePush(fx: Fixture): tuple[code: int; output: string] =
  runShell(shellCommand(@[fx.reproBin, "push", "--write-report", "app", "--no-certify",
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

proc pathsAddedSince(gitBin, repo, before: string): string =
  ## What the backend's ``repo`` gained on main since ``before``. A member that
  ## was really pushed publishes its own record; a refused one must add nothing.
  require(q(gitBin) & " -C " & q(repo) & " diff --name-status " & q(before) &
    " refs/heads/main").strip()

proc capabilityDir(gitBin: string; fx: Fixture): string =
  let common = require(q(gitBin) & " -C " & q(fx.manifests) &
    " rev-parse --git-common-dir").strip()
  let absCommon = if common.isAbsolute: common else: fx.manifests / common
  absCommon / "reprobuild" / "hook-capabilities"

proc checkSourceCapabilitiesEmpty(fx: Fixture; gitBin: string) =
  for repo in [fx.app, fx.lib, fx.core]:
    let common = require(q(gitBin) & " -C " & q(repo) &
      " rev-parse --path-format=absolute --git-common-dir").strip()
    let directory = common / "reprobuild" / "hook-capabilities"
    if dirExists(directory): check toSeq(walkDir(directory)).len == 0

proc configureCycle(fx: Fixture; gitBin: string) =
  writeFile(fx.manifests / "repos" / "core.toml",
    repoToml("core", "core-origin", @["app"]))
  discard require(q(gitBin) & " -C " & q(fx.manifests) & " add repos")
  discard require(q(gitBin) & " -C " & q(fx.manifests) & " commit -m cycle")
  discard require(q(gitBin) & " -C " & q(fx.manifests) & " push origin main")

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

  test "cyclic project siblings publish as a preflighted component":
    let gitBin = findExe("git")
    check gitBin.len > 0
    let fx = setup(gitBin, "cyclic-component")
    defer: removeDir(fx.scratch)
    # app -> lib -> core -> app is the reduced project-sibling deadlock.
    # The separate other member stays outside the publication closure.
    configureCycle(fx, gitBin)
    let appSha = commit(fx, gitBin, fx.app, "cyclic-app")
    let libSha = commit(fx, gitBin, fx.lib, "cyclic-lib")
    let coreSha = commit(fx, gitBin, fx.core, "cyclic-core")
    for member in [fx.app, fx.lib, fx.core]:
      storeCertificateForHead(gitBin, fx, member)
    let otherBefore = remoteHead(gitBin, fx.otherBare)
    discard commit(fx, gitBin, fx.other, "unrelated-cycle-work")
    installHooks(fx)
    # Raw pushes have no component authorization and retain the ordinary gate.
    for member in [(fx.app, "lib"), (fx.lib, "core"), (fx.core, "app")]:
      let refused = fx.withHookCli(q(gitBin) & " -C " & q(member[0]) &
        " push origin HEAD:main")
      check refused.code != 0
      check ("repro check: " & member[1] & ": unpublished") in refused.output
    let pushed = invokePush(fx)
    if pushed.code != 0: checkpoint(pushed.output)
    check pushed.code == 0
    check remoteHead(gitBin, fx.appBare) == appSha
    check remoteHead(gitBin, fx.libBare) == libSha
    check remoteHead(gitBin, fx.coreBare) == coreSha
    check remoteHead(gitBin, fx.otherBare) == otherBefore
    for member in [("app", appSha), ("lib", libSha), ("core", coreSha)]:
      check remoteHasLock(gitBin, fx, member[0], member[1])
    check report(fx)["order"] == %*["app", "lib", "core"]
    # Each member's own hook carried its certificate, under an authorization
    # that is the component's and not the ordinary gate's.
    for bare in [fx.appBare, fx.libBare, fx.coreBare]:
      let note = remoteNoteOnHeadTree(gitBin, bare)
      check note.code == 0
      check "# --- test-certificate ---" in note.output
    check report(fx)["lockPublished"].getBool()
    check fileExists(fx.manifestPrePushLog)
    if fileExists(fx.manifestPrePushLog):
      check readFile(fx.manifestPrePushLog).splitLines().allIt(
        it.len == 0 or it == "cap= legacy= context=")
    let capDir = capabilityDir(gitBin, fx)
    if dirExists(capDir): check toSeq(walkDir(capDir)).len == 0
    checkSourceCapabilitiesEmpty(fx, gitBin)

  test "two unpublished members of a cycle retain its published intermediate":
    let gitBin = findExe("git")
    check gitBin.len > 0
    let fx = setup(gitBin, "cycle-published-intermediate")
    defer: removeDir(fx.scratch)
    configureCycle(fx, gitBin)
    let coreBefore = remoteHead(gitBin, fx.coreBare)
    let locked = fx.withHookCli(q(fx.reproBin) & " workspace lock app" &
      " --trigger-repo=core --workspace-root=" & q(fx.workspace))
    if locked.code != 0: checkpoint(locked.output)
    check locked.code == 0
    # The issue's pushed repository carries an older, published sibling pin.
    # Its source push must retain the existing mutual-pin deferral while the
    # peer's new HEAD is still unpublished; a future HEAD is never pinned here.
    proc row(name, path, sha, depends, url: string): string =
      "{ name = \"" & name & "\", path = \"" & path &
        "\", coord_kind = \"vcs\", url = \"" & url &
        "\", ref = \"main\", revision = \"" & sha &
        "\", integrity = \"git-sha1:" & sha &
        "\", version = \"\", visibility = \"public\", participation = \"\", " &
        "depends = \"" & depends & "\", groups = \"\" }"
    let appBefore = remoteHead(gitBin, fx.appBare)
    let libBefore = remoteHead(gitBin, fx.libBare)
    writeFile(fx.app / "repro.lock",
      "schema = \"reprobuild.solved-graph-lock.v2\"\n[lock]\n" &
      "platform = \"x86_64-linux\"\noptimal = true\n" &
      "inputs_digest = \"published-cycle-pin\"\nvariants = []\npackages = []\n" &
      "deps = [" & row("app", ".", appBefore, "lib", fileUrl(fx.appBare)) &
      ", " & row("lib", "../lib", libBefore, "core", fileUrl(fx.libBare)) &
      ", " & row("core", "../core", coreBefore, "app", fileUrl(fx.coreBare)) & "]\n")
    discard require(q(gitBin) & " -C " & q(fx.app) & " add repro.lock")
    let appSha = commit(fx, gitBin, fx.app, "pair-app")
    let libSha = commit(fx, gitBin, fx.lib, "pair-lib")
    installHooks(fx)
    let raw = fx.withHookCli(q(gitBin) & " -C " & q(fx.app) &
      " push origin HEAD:main")
    check raw.code != 0
    check "repro.lock pin DEFERRED" in raw.output
    let pushed = invokePush(fx)
    if pushed.code != 0: checkpoint(pushed.output)
    check pushed.code == 0
    check remoteHead(gitBin, fx.appBare) == appSha
    check remoteHead(gitBin, fx.libBare) == libSha
    check remoteHead(gitBin, fx.coreBare) == coreBefore
    let r = report(fx)
    check r["repos"][2]["outcome"].getStr() == "already-published"
    check r["lockPublished"].getBool()

  test "a component receive failure reports its prefix and retry completes":
    let gitBin = findExe("git")
    check gitBin.len > 0
    let fx = setup(gitBin, "cycle-retry")
    defer: removeDir(fx.scratch)
    configureCycle(fx, gitBin)
    let libBefore = remoteHead(gitBin, fx.libBare)
    let coreBefore = remoteHead(gitBin, fx.coreBare)
    let appSha = commit(fx, gitBin, fx.app, "retry-cycle-app")
    let libSha = commit(fx, gitBin, fx.lib, "retry-cycle-lib")
    let coreSha = commit(fx, gitBin, fx.core, "retry-cycle-core")
    storeCertificateForHead(gitBin, fx, fx.app)
    executable(fx.libBare / "hooks" / "pre-receive", "#!/bin/sh\nexit 73\n")
    installHooks(fx)
    let stopped = invokePush(fx)
    check stopped.code != 0
    check report(fx)["stoppedStage"].getStr() == "source-push"
    check remoteHead(gitBin, fx.appBare) == appSha
    check remoteHead(gitBin, fx.libBare) == libBefore
    check remoteHead(gitBin, fx.coreBare) == coreBefore
    # The published prefix's certificate went with it, so the stop strands
    # nothing and the retry, which does not push app again, needs to do nothing.
    let prefixNote = remoteNoteOnHeadTree(gitBin, fx.appBare)
    check prefixNote.code == 0
    check "# --- test-certificate ---" in prefixNote.output
    checkSourceCapabilitiesEmpty(fx, gitBin)
    removeFile(fx.libBare / "hooks" / "pre-receive")
    let retried = invokePush(fx)
    if retried.code != 0: checkpoint(retried.output)
    check retried.code == 0
    check remoteHead(gitBin, fx.appBare) == appSha
    check remoteHead(gitBin, fx.libBare) == libSha
    check remoteHead(gitBin, fx.coreBare) == coreSha
    check report(fx)["repos"][0]["outcome"].getStr() == "already-published"
    check remoteNoteOnHeadTree(gitBin, fx.appBare).output == prefixNote.output
    check report(fx)["lockPublished"].getBool()
    checkSourceCapabilitiesEmpty(fx, gitBin)

  test "a dirty component peer refuses before the first source publication":
    let gitBin = findExe("git")
    check gitBin.len > 0
    let fx = setup(gitBin, "cycle-dirty")
    defer: removeDir(fx.scratch)
    configureCycle(fx, gitBin)
    let before = [remoteHead(gitBin, fx.appBare),
      remoteHead(gitBin, fx.libBare), remoteHead(gitBin, fx.coreBare)]
    discard commit(fx, gitBin, fx.app, "dirty-cycle-app")
    discard commit(fx, gitBin, fx.lib, "dirty-cycle-lib")
    discard commit(fx, gitBin, fx.core, "dirty-cycle-core")
    writeFile(fx.core / "dirty.txt", "uncommitted\n")
    installHooks(fx)
    check invokePush(fx).code != 0
    check [remoteHead(gitBin, fx.appBare), remoteHead(gitBin, fx.libBare),
      remoteHead(gitBin, fx.coreBare)] == before

  test "component authority never proves an unpublished exact committed pin":
    let gitBin = findExe("git")
    check gitBin.len > 0
    for kind in ["repro", "flake"]:
      let fx = setup(gitBin, "cycle-pin-" & kind)
      defer: removeDir(fx.scratch)
      configureCycle(fx, gitBin)
      let before = [remoteHead(gitBin, fx.appBare),
        remoteHead(gitBin, fx.libBare), remoteHead(gitBin, fx.coreBare)]
      let libSha = commit(fx, gitBin, fx.lib, "pin-cycle-lib")
      if kind == "repro":
        writeFile(fx.app / "repro.lock",
          "schema = \"reprobuild.solved-graph-lock.v2\"\n[lock]\n" &
          "platform = \"x86_64-linux\"\noptimal = true\n" &
          "inputs_digest = \"fixture\"\nvariants = []\npackages = []\n" &
          "deps = [{name = \"lib\", path = \"../lib\", coord_kind = \"vcs\", " &
          "url = \"" & fileUrl(fx.libBare) & "\", ref = \"main\", revision = \"" &
          libSha & "\", integrity = \"git-sha1:" & libSha &
          "\", version = \"\", visibility = \"public\", participation = \"\", " &
          "depends = \"\", groups = \"\"}]\n")
      else:
        writeFile(fx.app / "flake.lock", $(%*{
          "version": 7, "root": "root", "nodes": {
            "root": {"inputs": {"lib": "lib"}},
            "lib": {"locked": {"type": "git", "url": fileUrl(fx.libBare),
              "rev": libSha}, "original": {"type": "git", "url": fileUrl(fx.libBare)}}}}))
      discard require(q(gitBin) & " -C " & q(fx.app) & " add " & kind & ".lock")
      discard commit(fx, gitBin, fx.app, "pin-cycle-app")
      discard commit(fx, gitBin, fx.core, "pin-cycle-core")
      installHooks(fx)
      let stopped = invokePush(fx)
      check stopped.code != 0
      check [remoteHead(gitBin, fx.appBare), remoteHead(gitBin, fx.libBare),
        remoteHead(gitBin, fx.coreBare)] == before
      let gate = parseFile(fx.workspace / ".repro" / "build" / "reports" /
        "check-report.json")
      check gate["failures"].anyIt(
        it["property"].getStr() == "source-component-unpublished-pin")

  test "a cyclic member publishes every configured push destination":
    let gitBin = findExe("git")
    check gitBin.len > 0
    let fx = setup(gitBin, "cycle-plural-destinations")
    defer: removeDir(fx.scratch)
    configureCycle(fx, gitBin)
    let secondBare = fx.scratch / "app-second.git"
    discard require(q(gitBin) & " clone --bare " & q(fileUrl(fx.appBare)) &
      " " & q(secondBare))
    discard require(q(gitBin) & " -C " & q(fx.app) &
      " remote set-url --add --push origin " & q(fileUrl(fx.appBare)))
    discard require(q(gitBin) & " -C " & q(fx.app) &
      " remote set-url --add --push origin " & q(fileUrl(secondBare)))
    let secondBefore = remoteHead(gitBin, secondBare)
    let libBefore = remoteHead(gitBin, fx.libBare)
    let coreBefore = remoteHead(gitBin, fx.coreBare)
    let appSha = commit(fx, gitBin, fx.app, "plural-cycle-app")
    let libSha = commit(fx, gitBin, fx.lib, "plural-cycle-lib")
    let coreSha = commit(fx, gitBin, fx.core, "plural-cycle-core")
    executable(secondBare / "hooks" / "pre-receive", "#!/bin/sh\nexit 73\n")
    installHooks(fx)
    let stopped = invokePush(fx)
    check stopped.code != 0
    check report(fx)["stoppedStage"].getStr() == "source-push"
    check remoteHead(gitBin, fx.appBare) == appSha
    check remoteHead(gitBin, secondBare) == secondBefore
    check remoteHead(gitBin, fx.libBare) == libBefore
    check remoteHead(gitBin, fx.coreBare) == coreBefore
    checkSourceCapabilitiesEmpty(fx, gitBin)
    removeFile(secondBare / "hooks" / "pre-receive")
    # URL1 is now a Git no-op; its unused token still must be removed while
    # URL2 and the remaining component members finish on retry.
    let pushed = invokePush(fx)
    if pushed.code != 0: checkpoint(pushed.output)
    check pushed.code == 0
    check remoteHead(gitBin, fx.appBare) == appSha
    check remoteHead(gitBin, secondBare) == appSha
    check remoteHead(gitBin, fx.libBare) == libSha
    check remoteHead(gitBin, fx.coreBare) == coreSha
    check report(fx)["lockPublished"].getBool()
    checkSourceCapabilitiesEmpty(fx, gitBin)

  test "a preserved hook cannot change a component peer after preflight":
    let gitBin = findExe("git")
    check gitBin.len > 0
    for drift in ["head", "dirty", "remote"]:
      let fx = setup(gitBin, "cycle-drift-" & drift)
      defer: removeDir(fx.scratch)
      configureCycle(fx, gitBin)
      let before = [remoteHead(gitBin, fx.appBare),
        remoteHead(gitBin, fx.libBare), remoteHead(gitBin, fx.coreBare)]
      discard commit(fx, gitBin, fx.app, "drift-cycle-app")
      discard commit(fx, gitBin, fx.lib, "drift-cycle-lib")
      discard commit(fx, gitBin, fx.core, "drift-cycle-core")
      let mutation = case drift
        of "head": q(gitBin) & " -C " & q(fx.core) & " update-ref HEAD " & before[2]
        of "dirty": "printf dirty > " & q(fx.core / "dirty.txt")
        else: q(gitBin) & " -C " & q(fx.core) &
          " remote set-url --push origin " & q(fileUrl(fx.otherBare))
      executable(fx.app / ".git" / "hooks" / "pre-push",
        "#!/bin/sh\nset -eu\n" & mutation & "\ncat >/dev/null\n")
      installHooks(fx)
      check invokePush(fx).code != 0
      check [remoteHead(gitBin, fx.appBare), remoteHead(gitBin, fx.libBare),
        remoteHead(gitBin, fx.coreBare)] == before
      let gate = parseFile(fx.workspace / ".repro" / "build" / "reports" /
        "check-report.json")
      check gate["failures"].anyIt(
        it["property"].getStr() == "source-component-publication")

  test "external dependencies publish before a cyclic component":
    let gitBin = findExe("git")
    check gitBin.len > 0
    let fx = setup(gitBin, "cycle-external-dependency")
    defer: removeDir(fx.scratch)
    writeFile(fx.manifests / "repos" / "core.toml",
      repoToml("core", "core-origin", @["app", "other"]))
    discard require(q(gitBin) & " -C " & q(fx.manifests) & " add repos")
    discard require(q(gitBin) & " -C " & q(fx.manifests) & " commit -m cycle")
    discard require(q(gitBin) & " -C " & q(fx.manifests) & " push origin main")
    let appSha = commit(fx, gitBin, fx.app, "external-cycle-app")
    let libSha = commit(fx, gitBin, fx.lib, "external-cycle-lib")
    let coreSha = commit(fx, gitBin, fx.core, "external-cycle-core")
    let otherSha = commit(fx, gitBin, fx.other, "external-cycle-other")
    installHooks(fx)
    let pushed = invokePush(fx)
    if pushed.code != 0: checkpoint(pushed.output)
    check pushed.code == 0
    check report(fx)["order"] == %*["other", "app", "lib", "core"]
    for member in [("app", fx.appBare, appSha), ("lib", fx.libBare, libSha),
        ("core", fx.coreBare, coreSha), ("other", fx.otherBare, otherSha)]:
      check remoteHead(gitBin, member[1]) == member[2]
      check remoteHasLock(gitBin, fx, member[0], member[2])
    check report(fx)["lockPublished"].getBool()
    checkSourceCapabilitiesEmpty(fx, gitBin)

  test "an obsolete hook interpreter refuses cyclic publication before any source":
    let gitBin = findExe("git")
    check gitBin.len > 0
    let fx = setup(gitBin, "cycle-interpreter-skew")
    defer: removeDir(fx.scratch)
    configureCycle(fx, gitBin)
    let handshake = runShell(shellCommand(@[fx.reproBin, "hooks", "protocol",
      "--require=2", "--require-source-component"]))
    check handshake.code == 0
    check handshake.output.strip() == "2"
    let before = [remoteHead(gitBin, fx.appBare),
      remoteHead(gitBin, fx.libBare), remoteHead(gitBin, fx.coreBare)]
    discard commit(fx, gitBin, fx.app, "skew-cycle-app")
    discard commit(fx, gitBin, fx.lib, "skew-cycle-lib")
    discard commit(fx, gitBin, fx.core, "skew-cycle-core")
    installHooks(fx)
    let oldCli = getAppFilename()
    let stopped = runShell(shellCommand(@[fx.reproBin, "push", "app",
      "--no-certify", "--write-report", "--workspace-root=" & fx.workspace,
      "--current-repo=" & fx.app, "--json"],
      @[(name: "REPROBUILD_REPRO", value: oldCli),
        (name: ObsoleteComponentProtocolEnv, value: "1")]))
    check stopped.code != 0
    check report(fx)["stoppedStage"].getStr() == "source-component-hook-preflight"
    check "REPROBUILD_REPRO=" in report(fx)["retryCommand"].getStr()
    check [remoteHead(gitBin, fx.appBare), remoteHead(gitBin, fx.libBare),
      remoteHead(gitBin, fx.coreBare)] == before
    checkSourceCapabilitiesEmpty(fx, gitBin)

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

  test "ordinary backend ahead commit names offender rather than upstream record":
    let gitBin = findExe("git")
    doAssert gitBin.len > 0, "Git is required for backend refusal regression"
    for shape in ["upstream-record", "no-records", "valid-prefix", "followed-by-lock",
        "modified-metadata", "deleted-metadata"]:
      let fx = setup(gitBin, "ordinary-ahead-" & shape)
      defer: removeDir(fx.scratch)
      let appSha = remoteHead(gitBin, fx.appBare)
      let innocent = "locks/app/app/" & appSha & ".toml"
      if shape == "upstream-record":
        # The reported record in the field was already upstream and untouched.
        writeLockRecord(fx.manifests, "app", "app", appSha)
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " add locks")
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " commit -m upstream-record")
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " push origin main")
      if shape in ["modified-metadata", "deleted-metadata"]:
        writeFile(fx.manifests / ".gitignore", "scratch\n")
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " add .gitignore")
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " commit -m upstream-metadata")
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " push origin main")
      let coreSha = commit(fx, gitBin, fx.core, "core-ordinary-ahead")
      if shape == "valid-prefix":
        writeLockRecord(fx.manifests, "core", "core", coreSha)
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " add locks")
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " commit -m valid-prefix")
      let backendBefore = remoteHead(gitBin, fx.manifestBare)
      let sourceBefore = remoteHead(gitBin, fx.coreBare)
      if shape == "deleted-metadata": removeFile(fx.manifests / ".gitignore")
      else: writeFile(fx.manifests / ".gitignore", ".repro/\n")
      discard require(q(gitBin) & " -C " & q(fx.manifests) & " add .gitignore")
      discard require(q(gitBin) & " -C " & q(fx.manifests) & " commit -m ordinary-ignore")
      let offender = require(q(gitBin) & " -C " & q(fx.manifests) & " rev-parse HEAD").strip()
      if shape == "followed-by-lock":
        writeLockRecord(fx.manifests, "core", "core", coreSha)
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " add locks")
        discard require(q(gitBin) & " -C " & q(fx.manifests) & " commit -m later-lock-addition")
      let localBefore = require(q(gitBin) & " -C " & q(fx.manifests) & " rev-parse HEAD").strip()
      if shape == "upstream-record":
        check require(q(gitBin) & " -C " & q(fx.manifests) & " log --oneline origin/main..HEAD -- " & q(innocent)).strip().len == 0
        check run(q(gitBin) & " -C " & q(fx.manifests) & " cat-file -e " & q("origin/main:" & innocent)).code == 0
      installHooks(fx)
      let beforeStatus = require(q(gitBin) & " -C " & q(fx.manifests) & " status --porcelain")
      let stopped = invokePush(fx)
      check stopped.code != 0
      let stoppedReport = report(fx)
      check stoppedReport["stoppedStage"].getStr() == "lock-backend-preflight"
      let diagnostic = stoppedReport["lockDiagnostic"].getStr()
      checkpoint(shape & ": " & diagnostic)
      check offender in diagnostic
      check ".gitignore" in diagnostic
      check "solely of additions of canonical lock records under locks/" in diagnostic
      check innocent notin diagnostic
      check offender in stopped.output
      check remoteHead(gitBin, fx.manifestBare) == backendBefore
      check remoteHead(gitBin, fx.coreBare) == sourceBefore
      check require(q(gitBin) & " -C " & q(fx.manifests) & " rev-parse HEAD").strip() == localBefore
      check require(q(gitBin) & " -C " & q(fx.manifests) & " status --porcelain") == beforeStatus

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
        let beforeLib = remoteHead(gitBin, fx.libBare)
        let beforeApp = remoteHead(gitBin, fx.appBare)
        let beforeManifest = remoteHead(gitBin, fx.manifestBare)
        # An unpublished core commit makes core execute a real pre-push hook
        # after preflight. The preserved hook mutates the later published
        # member; source revalidation must catch it before either that member
        # or the backend is transported.
        let coreSha = commit(fx, gitBin, fx.core, "revalidation-" & drift)
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
            "\ncat >/dev/null\n")
        installHooks(fx)
        let stopped = invokePush(fx)
        if stopped.code == 0: checkpoint(stopped.output)
        check stopped.code != 0
        let stoppedReport = report(fx)
        check stoppedReport["repos"][0]["name"].getStr() == "core"
        check stoppedReport["repos"][0]["outcome"].getStr() == "pushed"
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

        # Core's push succeeded, so `repro push` continues to the later member
        # and must revalidate it; no other source ref may advance, and the
        # backend gains core's own record and nothing else.
        check remoteHead(gitBin, fx.coreBare) == coreSha
        check remoteHead(gitBin, fx.libBare) == beforeLib
        check remoteHead(gitBin, fx.appBare) == beforeApp
        check pathsAddedSince(gitBin, fx.manifestBare, beforeManifest) ==
          "A\tlocks/app/core/" & coreSha & ".toml"
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

      let coreSha = commit(fx, gitBin, fx.core, "delete-later-advertised-branch")
      executable(fx.core / ".git" / "hooks" / "pre-push",
        "#!/usr/bin/env sh\nset -eu\n" &
        q(gitBin) & " --git-dir=" & q(fx.libBare) &
          " update-ref -d refs/heads/main\n" &
        "cat >/dev/null\n")
      installHooks(fx)

      let localHeads = @[
        require(q(gitBin) & " -C " & q(fx.core) & " rev-parse HEAD").strip(),
        require(q(gitBin) & " -C " & q(fx.lib) & " rev-parse HEAD").strip(),
        require(q(gitBin) & " -C " & q(fx.app) & " rev-parse HEAD").strip()]
      let sourceState = @[
        sourceStorageSnapshot(gitBin, fx.core),
        sourceStorageSnapshot(gitBin, fx.lib),
        sourceStorageSnapshot(gitBin, fx.app)]
      let deletedLibRemote = remoteHead(gitBin, fx.libBare)
      let mirrorRemote = remoteHead(gitBin, libMirror)
      let appRemote = remoteHead(gitBin, fx.appBare)
      let backendLocal = require(q(gitBin) & " -C " & q(fx.manifests) &
        " rev-parse HEAD").strip()
      let backendRemote = remoteHead(gitBin, fx.manifestBare)
      let backendStatus = require(q(gitBin) & " -C " & q(fx.manifests) &
        " status --porcelain")

      let stopped = invokePush(fx)
      if stopped.code == 0: checkpoint(stopped.output)
      check stopped.code != 0
      let stoppedReport = report(fx)
      check stoppedReport["repos"][0]["name"].getStr() == "core"
      check stoppedReport["repos"][0]["outcome"].getStr() == "pushed"
      check stoppedReport["repos"][1]["name"].getStr() == "lib"
      check stoppedReport["repos"][1]["outcome"].getStr() == "failed"
      check stoppedReport["stoppedRepo"].getStr() == "lib"
      check stoppedReport["stoppedStage"].getStr() == "source-revalidation"
      check "exact destination advertisement changed after preflight" in
        stoppedReport["repos"][1]["diagnostic"].getStr()

      check not branchExists(gitBin, fx.libBare)
      check deletedLibRemote == localHeads[1]
      check remoteHead(gitBin, libMirror) == mirrorRemote
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHead(gitBin, fx.appBare) == appRemote
      # The backend gains core's own record, which core's real push published,
      # on both sides, and nothing for the refused members.
      let coreRecord = "A\tlocks/app/core/" & coreSha & ".toml"
      check pathsAddedSince(gitBin, fx.manifestBare, backendRemote) == coreRecord
      check pathsAddedSince(gitBin, fx.manifests, backendLocal) == coreRecord
      check require(q(gitBin) & " -C " & q(fx.manifests) &
        " status --porcelain") == backendStatus
      for index, source in [fx.core, fx.lib, fx.app]:
        check require(q(gitBin) & " -C " & q(source) &
          " rev-parse HEAD").strip() == localHeads[index]
      # Core really pushed, so its remote-tracking ref moved; the others' storage
      # is untouched.
      for index, source in [fx.lib, fx.app]:
        check sourceStorageSnapshot(gitBin, source) == sourceState[index + 1]
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

  test "shared backend preflight tolerates only untracked disposable build output":
    ## The backend preflight refuses uncommitted state before any source ref
    ## is transmitted, with one carve-out: an UNTRACKED file under the
    ## backend's ``.repro/build/`` is disposable derived output (a hook report
    ## or log) that publication, which stages explicit record paths only, can
    ## never sweep into its commit. Counting it as dirt let a hook's own trace
    ## block every push routed to that backend. Falsifiable: without the
    ## carve-out this push stops at ``lock-backend-preflight`` naming the
    ## report. The refusing side of the line — an untracked file anywhere else,
    ## including the retired ``.repro/workspace/`` spelling — is pinned by the
    ## ``dirty`` and ``retired-report`` variants of the next case.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real repos, real hooks " &
        "and real bare remotes")
    else:
      var fx = setup(gitBin, "backend-disposable-output")
      defer: removeDir(fx.scratch)
      let routingEnvironment = isolateRoutingConfig(fx)
      defer: restoreRoutingConfig(routingEnvironment)
      enableRoutedBackends(gitBin, fx)
      # Both routes shared, so a preflight refusal would stop the push rather
      # than degrade to a personal-tier warning.
      let routing = fx.routedConfig()
      writeFile(routing, readFile(routing).replace(
        "visibility = \"personal\"", "visibility = \"team\""))
      let reports = fx.personalLocks / ".repro" / "build" / "reports"
      createDir(reports)
      writeFile(reports / "post-commit-report.json",
        "{\"outcome\": \"skipped-no-workspace\"}\n")
      writeFile(reports / "post-commit-lock.log", "trace\n")
      installHooks(fx)
      let coreSha = commit(fx, gitBin, fx.core, "core-disposable")
      let libSha = commit(fx, gitBin, fx.lib, "lib-disposable")
      let appSha = commit(fx, gitBin, fx.app, "app-disposable")
      let pushed = invokePush(fx)
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      check report(fx)["stoppedStage"].getStr() == ""
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHead(gitBin, fx.libBare) == libSha
      check remoteHead(gitBin, fx.appBare) == appSha
      check bareHasLock(gitBin, fx.personalLocksBare, "lib", libSha)
      # The derived output was neither published nor touched.
      let published = require(q(gitBin) & " -C " & q(fx.personalLocksBare) &
        " ls-tree -r --name-only refs/heads/main")
      check ".repro/" notin published
      let status = require(q(gitBin) & " -C " & q(fx.personalLocks) &
        " status --porcelain --untracked-files=all")
      check "?? .repro/build/reports/post-commit-report.json" in status
      check "?? .repro/build/reports/post-commit-lock.log" in status

  test "every later shared backend failure is discovered before source mutation":
    let gitBin = findExe("git")
    if gitBin.len == 0: skip()
    else:
      for failure in ["dirty", "retired-report", "auth", "divergent",
                      "unverified-ahead"]:
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
        of "retired-report":
          # The retired report location is not disposable output: nothing
          # current writes there, so a file under it still refuses.
          createDir(fx.personalLocks / ".repro" / "workspace")
          writeFile(fx.personalLocks / ".repro" / "workspace" /
            "post-commit-report.json", "{}\n")
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

  test "pinned dependency already on an upstream branch is not pushed":
    # A pinned dependency is parked on a local `reprobuild/pinned/<short-sha>`
    # branch at a revision its upstream already carries on `main`. No branch of
    # that name exists remotely, but the commit is published, so `repro push`
    # must treat the member as already published: no transport to the
    # upstream, no junk `reprobuild/pinned/*` branch created there, and no
    # stop at `source-push` when the upstream is a read-only third party.
    # Both shapes are exercised: a read-only upstream (every receive refused)
    # and a writable one (where a wrongly attempted push would succeed and
    # leave the parking branch behind on the upstream).
    let gitBin = findExe("git")
    if gitBin.len == 0: skip("git is not on PATH")
    else:
      for upstream in ["read-only", "writable"]:
        let fx = setup(gitBin, "pinned-published-" & upstream)
        defer: removeDir(fx.scratch)
        let coreSha = remoteHead(gitBin, fx.coreBare)
        check require(q(gitBin) & " -C " & q(fx.core) &
          " rev-parse HEAD").strip() == coreSha
        let pinnedBranch = "reprobuild/pinned/" & coreSha[0 ..< 12]
        discard require(q(gitBin) & " -C " & q(fx.core) &
          " switch -c " & q(pinnedBranch))
        if upstream == "read-only":
          executable(fx.coreBare / "hooks" / "pre-receive",
            "#!/usr/bin/env sh\ncat >/dev/null\nexit 73\n")
        let libSha = commit(fx, gitBin, fx.lib, "lib-over-pinned-" & upstream)
        let appSha = commit(fx, gitBin, fx.app, "app-over-pinned-" & upstream)
        installHooks(fx)
        let coreRefsBefore = require(q(gitBin) & " -C " & q(fx.coreBare) &
          " for-each-ref --format='%(refname) %(objectname)'")

        let pushed = invokePush(fx)
        if pushed.code != 0: checkpoint(pushed.output)
        let r = report(fx)
        check r["stoppedStage"].getStr() != "source-push"
        check r["repos"][0]["name"].getStr() == "core"
        check r["repos"][0]["branch"].getStr() == pinnedBranch
        check r["repos"][0]["headSha"].getStr() == coreSha
        check r["repos"][0]["outcome"].getStr() == "already-published"
        check require(q(gitBin) & " -C " & q(fx.coreBare) &
          " for-each-ref --format='%(refname) %(objectname)'") ==
          coreRefsBefore
        check run(q(gitBin) & " -C " & q(fx.coreBare) &
          " rev-parse --verify " & q("refs/heads/" & pinnedBranch)).code != 0

        # The dependents carry new commits and are published normally on top
        # of the pinned dependency, each through its own real gate.
        check r["repos"].len == 3
        if r["repos"].len == 3:
          check r["repos"][1]["name"].getStr() == "lib"
          check r["repos"][1]["outcome"].getStr() == "pushed"
          check r["repos"][2]["name"].getStr() == "app"
          check r["repos"][2]["outcome"].getStr() == "pushed"
        check remoteHead(gitBin, fx.libBare) == libSha
        check remoteHead(gitBin, fx.appBare) == appSha
        check remoteHasLock(gitBin, fx, "lib", libSha)
        check remoteHasLock(gitBin, fx, "app", appSha)

        # Final completion still expects an exact record for EVERY closure
        # member at its HEAD, and only a member's own gate creates one. The
        # pinned member is never transmitted, so its record was never created
        # and completion stops honestly instead of manufacturing it -- the
        # same contract as "already-published closure without records fails
        # honestly on retry". It names the member and a runnable remedy.
        check pushed.code == 2
        check r["stoppedStage"].getStr() == "final-lock-verification"
        check r["retryCommand"].getStr() ==
          "repro workspace lock app --trigger-repo=core && " &
          "repro push --sync --rebase"
        check not remoteHasLock(gitBin, fx, "core", coreSha)

        # Following that remedy completes the closure without ever touching
        # the pinned dependency's upstream.
        let locked = runShell(shellCommand(@[fx.reproBin, "workspace", "lock",
          "app", "--trigger-repo=core", "--workspace-root=" & fx.workspace],
          @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
        if locked.code != 0: checkpoint(locked.output)
        check locked.code == 0
        let retried = invokePush(fx)
        if retried.code != 0: checkpoint(retried.output)
        check retried.code == 0
        let completed = report(fx)
        check completed["stoppedStage"].getStr() == ""
        check completed["lockPublished"].getBool()
        check completed["repos"].len == 3
        for member in completed["repos"]:
          check member["outcome"].getStr() == "already-published"
        check remoteHasLock(gitBin, fx, "core", coreSha)
        check require(q(gitBin) & " -C " & q(fx.coreBare) &
          " for-each-ref --format='%(refname) %(objectname)'") ==
          coreRefsBefore

  test "pinned member published by another branch is revalidated after deletion":
    # The no-op decision for a member parked on a local-only pinned branch
    # rests on a DIFFERENT advertised branch (`main`) containing its HEAD. That
    # branch must be part of what revalidation re-proves: if it disappears
    # between global preflight and this member's turn, the stale "already
    # published" plan must be refused, not acted on and not reinterpreted as a
    # push of the parking branch.
    let gitBin = findExe("git")
    if gitBin.len == 0: skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "pinned-containing-deletion")
      defer: removeDir(fx.scratch)
      let libSha = remoteHead(gitBin, fx.libBare)
      let pinnedBranch = "reprobuild/pinned/" & libSha[0 ..< 12]
      discard require(q(gitBin) & " -C " & q(fx.lib) &
        " switch -c " & q(pinnedBranch))
      # An unpublished core commit makes core run a real pre-push hook, which
      # deletes lib's only containing branch after preflight has classified lib
      # as published.
      let coreSha = commit(fx, gitBin, fx.core, "delete-pinned-containing-branch")
      executable(fx.core / ".git" / "hooks" / "pre-push",
        "#!/usr/bin/env sh\nset -eu\n" &
        q(gitBin) & " --git-dir=" & q(fx.libBare) &
          " update-ref -d refs/heads/main\n" &
        "cat >/dev/null\n")
      installHooks(fx)
      let appRemote = remoteHead(gitBin, fx.appBare)
      let backendRemote = remoteHead(gitBin, fx.manifestBare)

      let stopped = invokePush(fx)
      if stopped.code == 0: checkpoint(stopped.output)
      check stopped.code != 0
      let r = report(fx)
      check r["repos"].len == 2
      if r["repos"].len == 2:
        check r["repos"][0]["name"].getStr() == "core"
        check r["repos"][0]["outcome"].getStr() == "pushed"
        check r["repos"][1]["name"].getStr() == "lib"
        check r["repos"][1]["branch"].getStr() == pinnedBranch
        check r["repos"][1]["outcome"].getStr() == "failed"
        check "exact destination advertisement changed after preflight" in
          r["repos"][1]["diagnostic"].getStr()
      check r["stoppedRepo"].getStr() == "lib"
      check r["stoppedStage"].getStr() == "source-revalidation"

      # Nothing was transmitted: the deleted branch is not recreated and no
      # parking branch appears on lib's remote.
      check require(q(gitBin) & " -C " & q(fx.libBare) &
        " for-each-ref --format='%(refname)' refs/heads/").strip() == ""
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHead(gitBin, fx.appBare) == appRemote
      check pathsAddedSince(gitBin, fx.manifestBare, backendRemote) ==
        "A\tlocks/app/core/" & coreSha & ".toml"

  test "existing destination behind HEAD is advanced though another branch has it":
    # Containment by ANOTHER branch only stands in for a destination branch
    # that does not exist. When the checkout's own branch exists remotely and
    # is behind HEAD, it is still fast-forwarded: reporting the member
    # "already published" because some other branch happens to carry HEAD
    # would leave the branch the user is publishing stale.
    let gitBin = findExe("git")
    if gitBin.len == 0: skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "exact-behind-contained-elsewhere")
      defer: removeDir(fx.scratch)
      let coreBefore = remoteHead(gitBin, fx.coreBare)
      let coreSha = commit(fx, gitBin, fx.core, "core-also-elsewhere")
      # Raw push before the managed hooks exist: `elsewhere` carries HEAD and
      # the source gains a matching `origin/elsewhere` remote-tracking ref.
      discard require(q(gitBin) & " -C " & q(fx.core) &
        " push origin HEAD:refs/heads/elsewhere")
      check require(q(gitBin) & " -C " & q(fx.core) &
        " rev-parse refs/remotes/origin/elsewhere").strip() == coreSha
      check remoteHead(gitBin, fx.coreBare) == coreBefore
      let libSha = commit(fx, gitBin, fx.lib, "lib-over-elsewhere")
      let appSha = commit(fx, gitBin, fx.app, "app-over-elsewhere")
      installHooks(fx)

      let pushed = invokePush(fx)
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      let r = report(fx)
      check r["stoppedStage"].getStr() == ""
      check r["repos"].len == 3
      if r["repos"].len == 3:
        check r["repos"][0]["name"].getStr() == "core"
        check r["repos"][0]["outcome"].getStr() == "pushed"
      check remoteHead(gitBin, fx.coreBare) == coreSha
      check remoteHead(gitBin, fx.libBare) == libSha
      check remoteHead(gitBin, fx.appBare) == appSha
      check remoteHasLock(gitBin, fx, "core", coreSha)
      check r["lockPublished"].getBool()
