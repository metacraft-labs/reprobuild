## M26 — ``repro check --mode=pre-push`` blocks publishing a public
## manifest lock that references repos declared only in a private
## manifest layer.
##
## The sixth pre-push stage activates when:
##   - ``--current-repo`` is one of the manifest-layer repos declared
##     in ``.repo/workspace.toml``,
##   - that layer's ``visibility = "public"``,
##   - the pushed refs introduce or modify at least one
##     ``locks/<project>/<file>.toml`` path in the layer repo.
##
## The stage parses each touched lock with M5's strict ``readLock``,
## re-resolves each manifest layer's project file to build a per-path
## visibility map (``public`` / ``org`` / ``team`` / ``private``), and
## emits a ``lock_references_private_repo`` failure when a path in the
## lock is declared exclusively in non-public layers.
##
## Fixture: two ``local_path`` manifest layers (a public one and a
## private one) backed by local git repositories in the test scratch
## directory. The public layer's project file declares two repos
## (``lib-public-a`` / ``lib-public-b``); the private layer declares
## one additional repo (``lib-private``). Sibling repos are clean
## clones with published HEADs so stages 1-3 always pass; there are no
## develop overrides so stage 4 is a no-op. Lock files are created in
## the public layer's local checkout, committed, and the pre-push hook
## is then driven with a refs file that names the lock-touching commit.
##
## Cases:
##
##   1. test_m26_pre_push_passes_when_lock_only_references_public_repos
##      — lock references only ``lib-public-a`` / ``lib-public-b`` →
##      stage 6 passes, exit 0.
##
##   2. test_m26_pre_push_blocks_when_public_lock_references_private_only_repo
##      — lock references ``lib-private`` (declared only in the
##      private layer) → stage 6 refuses with the
##      ``lock_references_private_repo`` property, exit 2.
##
##   3. test_m26_pre_push_passes_when_lock_unchanged_in_push
##      — the lock file is committed in a base commit but the pushed
##      commit doesn't touch it (a README-only change) → stage 6 is a
##      no-op, exit 0.
##
##   4. test_m26_pre_push_blocks_when_new_lock_added_with_private_refs
##      — a brand-new branch is being pushed (zero remote-sha) carrying
##      a lock file that references a private-only repo → stage 6
##      refuses with the same structured property.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

# ---- shell helpers --------------------------------------------------------

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

proc compileRepro(tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  let root = repoRoot()
  let args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & root / "build" / "nimcache" / "m26-prepush-lockvis-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

# ---- bare-repo seed fixture ----------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  ## Single-commit bare origin used as a stand-in for a sibling repo.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M26 Tester\"")
  writeFile(workPath / "README.md", "M26 fixture\n")
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
    " config user.name \"M26 Tester\"")

# ---- manifest TOML --------------------------------------------------------
#
# The composed project ``myproject`` has THREE repos after composition:
# two from the public layer (``lib-public-a`` / ``lib-public-b``) and
# one from the private layer (``lib-private``).

proc publicProjectToml(originPubA, originPubB: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"pub-a-origin\"\nfetch = \"" &
      originPubA & "\"\n\n" &
    "[[remote]]\nname = \"pub-b-origin\"\nfetch = \"" &
      originPubB & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-public-a.toml\",\n" &
    "  \"repos/lib-public-b.toml\",\n" &
    "]\n"

proc privateProjectToml(originPrivate: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"priv-origin\"\nfetch = \"" &
      originPrivate & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-private.toml\",\n" &
    "]\n"

const libPublicAFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-public-a"
path = "lib-public-a"
remote = "pub-a-origin"
revision = "main"
"""

const libPublicBFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-public-b"
path = "lib-public-b"
remote = "pub-b-origin"
revision = "main"
"""

const libPrivateFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-private"
path = "lib-private"
remote = "priv-origin"
revision = "main"
"""

# ---- fixture --------------------------------------------------------------

type
  RepoSeed = object
    name: string
    origin: string
    seedPath: string
    sha: string

  M26Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    publicLayerPath: string   ## On-disk path of the public manifest layer
                              ## (a git repo) — this is the
                              ## ``--current-repo`` argument the tests pass.
    privateLayerPath: string
    libPublicA: RepoSeed
    libPublicB: RepoSeed
    libPrivate: RepoSeed

proc seedManifestLayerRepo(gitBin, layerPath: string;
                            files: openArray[(string, string)]) =
  ## Build a git repository at ``layerPath`` holding the manifest TOML
  ## files. The repo has a single commit on ``main`` so the test can
  ## later add more commits (lock files) and inspect the diff. Mirrors
  ## the ``seedManifestBare`` helper in the M25 test but operates on a
  ## non-bare working tree (since M26 needs to commit lock files into
  ## the layer's tree).
  discard requireGit(q(gitBin) & " init -b main " & q(layerPath))
  discard requireGit(q(gitBin) & " -C " & q(layerPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(layerPath) &
    " config user.name \"M26 Tester\"")
  # Stub an origin so the "is-published" probes M18 / M23 use for
  # sibling-repo checks have a remote to consult if needed. The
  # manifest-layer repo itself isn't probed by stages 1-3, but having
  # an origin keeps the git environment consistent with a real
  # workspace.
  let bareOrigin = layerPath & ".origin.git"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(bareOrigin))
  for entry in files:
    let relPath = entry[0]
    let body = entry[1]
    let absPath = layerPath / relPath
    createDir(absPath.splitPath.head)
    writeFile(absPath, body)
  discard requireGit(q(gitBin) & " -C " & q(layerPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(layerPath) &
    " commit -m \"M26 fixture seed\"")
  discard requireGit(q(gitBin) & " -C " & q(layerPath) &
    " remote add origin " & q(bareOrigin))
  discard requireGit(q(gitBin) & " -C " & q(layerPath) &
    " push origin main")

proc writeWorkspaceToml(workspaceRoot, publicLayerPath,
                        privateLayerPath: string): string =
  let dotRepo = workspaceRoot / ".repo"
  createDir(dotRepo)
  result = dotRepo / "workspace.toml"
  # Use ``local_path`` layers so the M26 stage's per-layer on-disk
  # lookup picks the literal directories the test seeded — no need to
  # mirror the composer's URL-sanitization machinery.
  # Forward-slash the paths so the TOML basic strings don't trip the
  # ``\U`` / ``\u`` escape rules on Windows (``C:\Users\...`` would
  # otherwise be rejected by the strict reader). Nim's ``isAbsolute`` /
  # ``dirExists`` on Windows accept forward-slash forms, so the
  # composer reads them just fine.
  let publicLocalPath = publicLayerPath.replace('\\', '/')
  let privateLocalPath = privateLayerPath.replace('\\', '/')
  let body =
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"myproject\"\nbranch = \"main\"\n\n" &
    "[[manifest]]\n" &
    "local_path = \"" & publicLocalPath & "\"\n" &
    "visibility = \"public\"\n\n" &
    "[[manifest]]\n" &
    "local_path = \"" & privateLocalPath & "\"\n" &
    "visibility = \"private\"\n"
  writeFile(result, body)

proc setupFixture(gitBin, slug: string): M26Fixture =
  result.scratch = createTempDir("repro-m26-" & slug & "-", "")
  result.reproBin = compileRepro(result.scratch)

  # Three sibling-repo bare origins. Only the two ``lib-public-*``
  # repos materialise as workspace clones; ``lib-private`` is declared
  # by the private layer and is intentionally NOT cloned (the lock
  # writer doesn't run in these tests — we write the lock file by
  # hand so we can craft the public / private references precisely).
  result.libPublicA.name = "lib-public-a"
  result.libPublicA.origin = result.scratch / "origin-lib-public-a.git"
  result.libPublicA.seedPath = result.scratch / "seed-lib-public-a"
  result.libPublicA.sha = seedGitOrigin(gitBin, result.libPublicA.origin,
    result.libPublicA.seedPath)
  result.libPublicB.name = "lib-public-b"
  result.libPublicB.origin = result.scratch / "origin-lib-public-b.git"
  result.libPublicB.seedPath = result.scratch / "seed-lib-public-b"
  result.libPublicB.sha = seedGitOrigin(gitBin, result.libPublicB.origin,
    result.libPublicB.seedPath)
  result.libPrivate.name = "lib-private"
  result.libPrivate.origin = result.scratch / "origin-lib-private.git"
  result.libPrivate.seedPath = result.scratch / "seed-lib-private"
  result.libPrivate.sha = seedGitOrigin(gitBin, result.libPrivate.origin,
    result.libPrivate.seedPath)

  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)

  # Public manifest layer is a git repo under the scratch dir.
  result.publicLayerPath = result.scratch / "manifest-public"
  result.privateLayerPath = result.scratch / "manifest-private"

  seedManifestLayerRepo(gitBin, result.publicLayerPath, [
    ("projects/myproject.toml", publicProjectToml(
      fileUrl(result.libPublicA.origin),
      fileUrl(result.libPublicB.origin))),
    ("repos/lib-public-a.toml", libPublicAFragment),
    ("repos/lib-public-b.toml", libPublicBFragment),
  ])
  seedManifestLayerRepo(gitBin, result.privateLayerPath, [
    ("projects/myproject.toml", privateProjectToml(
      fileUrl(result.libPrivate.origin))),
    ("repos/lib-private.toml", libPrivateFragment),
  ])

  discard writeWorkspaceToml(result.workspaceRoot,
    result.publicLayerPath, result.privateLayerPath)

  # Clone the two public sibling repos so stages 1-3 (clean +
  # published) have something to inspect. ``lib-private`` is not
  # cloned — it isn't part of the public-only universe.
  cloneInto(gitBin, result.libPublicA.origin,
    result.workspaceRoot / "lib-public-a")
  cloneInto(gitBin, result.libPublicB.origin,
    result.workspaceRoot / "lib-public-b")
  # The composed project actually has THREE repos — the M18 sibling
  # loop walks every declared repo. If ``lib-private`` is missing
  # from disk, stage 2/3 simply skip it (``hasGit=false``). We don't
  # add it so the fixture mirrors a public-only operator's workspace.

  writeWorkspaceBranch(result.workspaceRoot,
    project = "myproject", branch = "main")

# ---- lock-file helpers ----------------------------------------------------

proc publicOnlyLockToml(publicASha, publicBSha: string): string =
  ## Hand-rolled lock TOML matching the M11 lock writer's emit shape
  ## (M5 strict reader is happy with this body). References only the
  ## two public-layer repo paths.
  result =
    "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
    "[lock]\n" &
    "project = \"myproject\"\n" &
    "created_at = \"2026-06-04T00:00:00Z\"\n" &
    "created_by = \"M26 test fixture\"\n" &
    "workspace_branch = \"main\"\n\n" &
    "[[repo]]\n" &
    "name = \"lib-public-a\"\n" &
    "path = \"lib-public-a\"\n" &
    "remote = \"pub-a-origin\"\n" &
    "revision = \"" & publicASha & "\"\n\n" &
    "[[repo]]\n" &
    "name = \"lib-public-b\"\n" &
    "path = \"lib-public-b\"\n" &
    "remote = \"pub-b-origin\"\n" &
    "revision = \"" & publicBSha & "\"\n"

proc privateMixedLockToml(publicASha, publicBSha,
                          privateSha: string): string =
  result =
    "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
    "[lock]\n" &
    "project = \"myproject\"\n" &
    "created_at = \"2026-06-04T00:00:00Z\"\n" &
    "created_by = \"M26 test fixture\"\n" &
    "workspace_branch = \"main\"\n\n" &
    "[[repo]]\n" &
    "name = \"lib-public-a\"\n" &
    "path = \"lib-public-a\"\n" &
    "remote = \"pub-a-origin\"\n" &
    "revision = \"" & publicASha & "\"\n\n" &
    "[[repo]]\n" &
    "name = \"lib-public-b\"\n" &
    "path = \"lib-public-b\"\n" &
    "remote = \"pub-b-origin\"\n" &
    "revision = \"" & publicBSha & "\"\n\n" &
    "[[repo]]\n" &
    "name = \"lib-private\"\n" &
    "path = \"lib-private\"\n" &
    "remote = \"priv-origin\"\n" &
    "revision = \"" & privateSha & "\"\n"

proc lockIndexToml(triggerRepo, triggerSha, lockFile: string): string =
  ## Minimal lock-index entry. The M18 stage 5 inspects this to decide
  ## whether the lock is "already current". For the M26 tests we set
  ## the triggerSha to one of the public repo HEADs so the gate finds
  ## the lock current and proceeds to stage 6.
  result =
    "schema = \"reprobuild.workspace.lock-index.v1\"\n\n" &
    "[[entry]]\n" &
    "trigger_repo = \"" & triggerRepo & "\"\n" &
    "trigger_sha = \"" & triggerSha & "\"\n" &
    "lock_file = \"" & lockFile & "\"\n" &
    "created_at = \"2026-06-04T00:00:00Z\"\n"

proc writeRefsFile(path: string; localRef, localSha, remoteSha: string) =
  ## Build a git pre-push refs stream. ``remoteSha`` of all-zero means
  ## "branch creation" which exercises the M26 new-branch arm of
  ## ``lockPathsTouchedInPush``.
  writeFile(path, localRef & " " & localSha & " " &
    "refs/heads/main " & remoteSha & "\n")

proc commitInLayer(gitBin, layerPath, message: string): string =
  discard requireGit(q(gitBin) & " -C " & q(layerPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(layerPath) &
    " commit -m " & q(message))
  result = requireGit(q(gitBin) & " -C " & q(layerPath) &
    " rev-parse HEAD").strip()

proc currentLayerHead(gitBin, layerPath: string): string =
  result = requireGit(q(gitBin) & " -C " & q(layerPath) &
    " rev-parse HEAD").strip()

# ---- invocation -----------------------------------------------------------

proc invokeCheckPrePush(fx: M26Fixture; currentRepo, refsFile: string):
    CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & currentRepo,
    "--pushed-refs=" & refsFile,
    "--json",
  ]))

proc readReport(fx: M26Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "check-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite ------------------------------------------------------------

suite "M26 — pre-push lock visibility check":

  test "test_m26_pre_push_passes_when_lock_only_references_public_repos":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "public-only-lock")
      defer: removeDir(fx.scratch)

      # Write a lock referencing only ``lib-public-a`` / ``lib-public-b``
      # into the public layer's checkout, commit it, and point the
      # refs file at the new HEAD.
      let lockRel = "locks/myproject/myproject-aaaaaaaa.toml"
      let indexRel = "locks/myproject/index.toml"
      let lockBody = publicOnlyLockToml(fx.libPublicA.sha,
                                        fx.libPublicB.sha)
      let lockAbs = fx.publicLayerPath / lockRel.replace('/', DirSep)
      createDir(parentDir(lockAbs))
      writeFile(lockAbs, lockBody)
      writeFile(fx.publicLayerPath / indexRel.replace('/', DirSep),
        lockIndexToml("myproject", fx.libPublicA.sha, lockRel))
      let newHead = commitInLayer(gitBin, fx.publicLayerPath,
        "add public-only lock")

      let remoteHead = requireGit(q(gitBin) & " -C " &
        q(fx.publicLayerPath) & " rev-parse origin/main").strip()

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", newHead, remoteHead)

      let res = invokeCheckPrePush(fx,
        currentRepo = fx.publicLayerPath,
        refsFile = refsFile)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["failures"].len == 0
      # The lock is already current (we wrote both the lock and the
      # index so stage 5 found a covering index entry).
      check report["lockUpdate"]["kind"].getStr() == "already-current"

  test "test_m26_pre_push_blocks_when_public_lock_references_private_only_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "private-ref-block")
      defer: removeDir(fx.scratch)

      let lockRel = "locks/myproject/myproject-bbbbbbbb.toml"
      let indexRel = "locks/myproject/index.toml"
      let lockBody = privateMixedLockToml(fx.libPublicA.sha,
                                          fx.libPublicB.sha,
                                          fx.libPrivate.sha)
      let lockAbs = fx.publicLayerPath / lockRel.replace('/', DirSep)
      createDir(parentDir(lockAbs))
      writeFile(lockAbs, lockBody)
      writeFile(fx.publicLayerPath / indexRel.replace('/', DirSep),
        lockIndexToml("myproject", fx.libPublicA.sha, lockRel))
      let newHead = commitInLayer(gitBin, fx.publicLayerPath,
        "add lock with private ref")

      let remoteHead = requireGit(q(gitBin) & " -C " &
        q(fx.publicLayerPath) & " rev-parse origin/main").strip()

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", newHead, remoteHead)

      let res = invokeCheckPrePush(fx,
        currentRepo = fx.publicLayerPath,
        refsFile = refsFile)
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["failures"].len == 1
      let failure = report["failures"][0]
      check failure["property"].getStr() == "lock_references_private_repo"
      check failure["repo"].getStr() == "lib-private"
      check failure["source"].getStr() == lockRel
      check failure["remediation"].getStr().contains("lib-private")
      # The remediation embeds the layer's ``provenance`` string, which
      # is the ``local_path`` value from workspace.toml verbatim. On
      # Windows the test seeds that value in forward-slash form (to
      # avoid TOML basic-string ``\U`` escapes), so the substring may
      # not match ``fx.publicLayerPath`` (native backslash form) byte
      # for byte. Match either separator shape.
      let remediationStr = failure["remediation"].getStr()
      check remediationStr.contains(fx.publicLayerPath) or
        remediationStr.contains(fx.publicLayerPath.replace('\\', '/'))
      check failure["evidence"].getStr().contains("private")
      check failure["evidence"].getStr().contains(lockRel)

  test "test_m26_pre_push_passes_when_lock_unchanged_in_push":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "lock-unchanged")
      defer: removeDir(fx.scratch)

      # Commit a lock referencing a private-only repo into the layer
      # AND push it to origin so it's part of the base history.
      let lockRel = "locks/myproject/myproject-cccccccc.toml"
      let indexRel = "locks/myproject/index.toml"
      let lockBody = privateMixedLockToml(fx.libPublicA.sha,
                                          fx.libPublicB.sha,
                                          fx.libPrivate.sha)
      let lockAbs = fx.publicLayerPath / lockRel.replace('/', DirSep)
      createDir(parentDir(lockAbs))
      writeFile(lockAbs, lockBody)
      writeFile(fx.publicLayerPath / indexRel.replace('/', DirSep),
        lockIndexToml("myproject", fx.libPublicA.sha, lockRel))
      discard commitInLayer(gitBin, fx.publicLayerPath,
        "seed pre-existing lock")
      discard requireGit(q(gitBin) & " -C " &
        q(fx.publicLayerPath) & " push origin main")

      # Now make a non-lock commit (README change) and push only that.
      # The pre-push gate must see that no lock files are touched in
      # the diff between origin/main and the new HEAD, so stage 6 is a
      # no-op even though the lock on disk references a private repo.
      writeFile(fx.publicLayerPath / "README.md",
        "M26 fixture\n\nSecond commit, no lock touch.\n")
      let newHead = commitInLayer(gitBin, fx.publicLayerPath,
        "non-lock commit")
      let remoteHead = requireGit(q(gitBin) & " -C " &
        q(fx.publicLayerPath) & " rev-parse origin/main").strip()

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", newHead, remoteHead)

      let res = invokeCheckPrePush(fx,
        currentRepo = fx.publicLayerPath,
        refsFile = refsFile)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["failures"].len == 0

  test "test_m26_pre_push_blocks_when_new_lock_added_with_private_refs":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "new-branch-private-ref")
      defer: removeDir(fx.scratch)

      # Create a feature branch in the public layer, add a lock with a
      # private reference, and stage a pre-push where remote-sha is
      # zero (the branch doesn't exist on origin yet). This exercises
      # the M26 "branch creation" arm of ``lockPathsTouchedInPush``,
      # which ls-trees the local-sha to enumerate every lock file.
      discard requireGit(q(gitBin) & " -C " &
        q(fx.publicLayerPath) & " checkout -b feature-m26")

      let lockRel = "locks/myproject/myproject-dddddddd.toml"
      let indexRel = "locks/myproject/index.toml"
      let lockBody = privateMixedLockToml(fx.libPublicA.sha,
                                          fx.libPublicB.sha,
                                          fx.libPrivate.sha)
      let lockAbs = fx.publicLayerPath / lockRel.replace('/', DirSep)
      createDir(parentDir(lockAbs))
      writeFile(lockAbs, lockBody)
      writeFile(fx.publicLayerPath / indexRel.replace('/', DirSep),
        lockIndexToml("myproject", fx.libPublicA.sha, lockRel))
      let newHead = commitInLayer(gitBin, fx.publicLayerPath,
        "add private-ref lock on feature branch")

      # ``feature-m26`` doesn't exist on origin → remote-sha is zero.
      let zeroSha = "0000000000000000000000000000000000000000"
      let refsFile = fx.scratch / "pushed-refs.txt"
      # We claim to push ``refs/heads/main`` so the pushed-branch
      # matches the workspace's active branch (avoiding stage 1's
      # branch-mismatch refusal). The branch-creation arm is exercised
      # by the zero remote-sha.
      writeRefsFile(refsFile, "refs/heads/main", newHead, zeroSha)

      let res = invokeCheckPrePush(fx,
        currentRepo = fx.publicLayerPath,
        refsFile = refsFile)
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["failures"].len == 1
      let failure = report["failures"][0]
      check failure["property"].getStr() == "lock_references_private_repo"
      check failure["repo"].getStr() == "lib-private"
      check failure["source"].getStr() == lockRel
      check failure["evidence"].getStr().contains("private")
