## M23 — ``repro check --mode=pre-push`` enforces develop-override
## cleanliness.
##
## The pre-push gate gains a fifth stage between the sibling-repo
## ``unpublished`` stage (M18 stage 3) and the lock-currency stage
## (M18 stage 4 / M23 stage 5). For every entry in
## ``<workspaceRoot>/.repro/develop-overrides.toml`` the gate checks
## the override's source path:
##
##   - missing on disk           → ``develop_override_missing``
##   - working tree is dirty     → ``develop_override_dirty``
##   - HEAD is not on any remote → ``develop_override_unpublished``
##
## The blocking condition reproduces
## ``reprobuild-specs/Workspace-And-Develop-Mode.md`` §"Reproducibility
## And `repro check`" exactly: a develop-mode dependency with
## uncommitted modifications, or one pointing at commits not pushed to
## an agreed remote, must not silently be encoded into a workspace
## lock. Exit codes match the M18 contract:
##   - 0 — every check passed.
##   - 1 — IO / VCS-tool failure unrelated to the gate.
##   - 2 — any gate stage refused.
##
## Failure records add a ``source`` field that names the override's
## filesystem path so the operator can locate the offending checkout.
## The ``repo`` field is set to the override's package name (NOT the
## workspace-relative sibling-repo path the M18 stages emit), so the
## JSON consumer can disambiguate sibling-repo failures from override
## failures by inspecting ``property`` and ``source`` together.
##
## Fixture pattern mirrors the other M18 pre-push tests: one bare
## origin per repo, a workspace clone, a metadata-only
## ``.repo/workspace.toml`` selecting the active branch. The develop
## override always points at ``<workspace>/develop/lib-a`` so the
## fifth stage has something to check; the sibling-repo set
## (``lib-a``, ``lib-b``, ``lib-c``) is kept clean and published so
## the earlier four stages always pass and the test isolates M23's
## behaviour.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

# ---- shell helpers (same shape as the existing M18 tests) -----------------

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

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

# ---- bare-repo seed fixture ----------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M23 Tester\"")
  writeFile(workPath / "README.md", "M23 fixture\n")
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
    " config user.name \"M23 Tester\"")

# ---- manifest TOML --------------------------------------------------------

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

# ---- fixture --------------------------------------------------------------

type
  RepoSeed = object
    name: string
    origin: string
    seedPath: string
    sha: string

  M23Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): M23Fixture =
  result.scratch = createTempDir("repro-m23-" & slug & "-", "")
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
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
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
  result.workspaceRoot = workspaceRoot

proc cloneAllSiblings(gitBin: string; fx: M23Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc seedMetadataBranch(fx: M23Fixture; branch: string) =
  writeWorkspaceBranch(fx.workspaceRoot,
    project = "lib-a", branch = branch)

proc writeRefsFile(path: string; localRef, localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, localRef & " " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

proc invokeCheckPrePush(fx: M23Fixture; currentRepo, refsFile: string):
    CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & currentRepo,
    "--pushed-refs=" & refsFile,
    "--json",
  ]))

proc readReport(fx: M23Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "check-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- develop-override helpers ---------------------------------------------

proc registerOverride(fx: M23Fixture; package, localPath: string) =
  ## Write a minimal ``.repro/develop-overrides.toml`` carrying a
  ## single entry for ``package`` at ``localPath``. The serializer is
  ## byte-deterministic so this is equivalent to running
  ## ``repro develop`` and trimming the fixture to one entry.
  var file = newDevelopOverrides()
  let entry = DevelopOverrideEntry(
    package: package,
    local_path: absolutePath(localPath),
    state: "editable",
    created_at: "2026-06-04T00:00:00Z",
    provenance: some("test fixture"))
  file = addOverride(file, entry)
  writeDevelopOverridesFile(fx.workspaceRoot, file)

proc seedOverrideClone(gitBin: string; fx: M23Fixture;
                       package, originPath: string): string =
  ## Mirror what ``repro develop <pkg>`` does: clone ``originPath``
  ## into ``<workspace>/develop/<pkg>``, register the override, and
  ## return the absolute clone path.
  result = fx.workspaceRoot / "develop" / package
  createDir(parentDir(result))
  cloneInto(gitBin, originPath, result)
  registerOverride(fx, package, result)

# ---- the suite -------------------------------------------------------------

suite "M23 — repro check --mode=pre-push (develop-override cleanliness)":

  test "test_m23_pre_push_blocks_when_develop_override_dirty":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "override-dirty")
      defer: removeDir(fx.scratch)
      cloneAllSiblings(gitBin, fx)
      seedMetadataBranch(fx, "main")

      let clone = seedOverrideClone(gitBin, fx, "lib-a", fx.libA.origin)
      writeFile(clone / "scratch.txt", "uncommitted override edit\n")

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", fx.libA.sha)
      let res = invokeCheckPrePush(fx,
        currentRepo = fx.workspaceRoot / "lib-a",
        refsFile = refsFile)
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["failures"].len == 1
      let failure = report["failures"][0]
      check failure["property"].getStr() == "develop_override_dirty"
      check failure["repo"].getStr() == "lib-a"
      check failure["source"].getStr() == clone
      check failure["remediation"].getStr().contains("commit or stash")
      check failure["remediation"].getStr().contains(clone)
      # The fifth stage runs after stages 1–3 pass and before the
      # lock-currency stage; the lock stage therefore never runs.
      check report["lockUpdate"]["kind"].getStr() == "none"

  test "test_m23_pre_push_blocks_when_develop_override_unpublished":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "override-unpublished")
      defer: removeDir(fx.scratch)
      cloneAllSiblings(gitBin, fx)
      seedMetadataBranch(fx, "main")

      let clone = seedOverrideClone(gitBin, fx, "lib-a", fx.libA.origin)
      # Add a local commit that has not been pushed to origin.
      writeFile(clone / "local-only.txt", "local-only override commit\n")
      discard requireGit(q(gitBin) & " -C " & q(clone) &
        " add local-only.txt")
      discard requireGit(q(gitBin) & " -C " & q(clone) &
        " commit -m local-only")

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", fx.libA.sha)
      let res = invokeCheckPrePush(fx,
        currentRepo = fx.workspaceRoot / "lib-a",
        refsFile = refsFile)
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["failures"].len == 1
      let failure = report["failures"][0]
      check failure["property"].getStr() == "develop_override_unpublished"
      check failure["repo"].getStr() == "lib-a"
      check failure["source"].getStr() == clone
      check failure["remediation"].getStr().contains("git push")
      check failure["remediation"].getStr().contains(clone)
      check report["lockUpdate"]["kind"].getStr() == "none"

  test "test_m23_pre_push_blocks_when_develop_override_missing":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "override-missing")
      defer: removeDir(fx.scratch)
      cloneAllSiblings(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # Point the override at a path that does not exist on disk.
      let missing = fx.scratch / "vanished-checkout"
      registerOverride(fx, "lib-a", missing)
      check not dirExists(missing)

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", fx.libA.sha)
      let res = invokeCheckPrePush(fx,
        currentRepo = fx.workspaceRoot / "lib-a",
        refsFile = refsFile)
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["failures"].len == 1
      let failure = report["failures"][0]
      check failure["property"].getStr() == "develop_override_missing"
      check failure["repo"].getStr() == "lib-a"
      check failure["source"].getStr() == absolutePath(missing)
      check failure["remediation"].getStr().contains("repro develop")
      check failure["remediation"].getStr().contains("lib-a")
      check report["lockUpdate"]["kind"].getStr() == "none"

  test "test_m23_pre_push_passes_with_clean_published_override":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "override-happy")
      defer: removeDir(fx.scratch)
      cloneAllSiblings(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # The override is a clean clone of an origin whose HEAD is
      # already published. The fifth stage must pass.
      discard seedOverrideClone(gitBin, fx, "lib-a", fx.libA.origin)

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", fx.libA.sha)
      let res = invokeCheckPrePush(fx,
        currentRepo = fx.workspaceRoot / "lib-a",
        refsFile = refsFile)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["failures"].len == 0
      # The lock stage proceeded normally because all five gates
      # passed; without a prior lock the gate creates one.
      check report["lockUpdate"]["kind"].getStr() == "created"

  test "test_m23_pre_push_passes_when_no_overrides_recorded":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-overrides")
      defer: removeDir(fx.scratch)
      cloneAllSiblings(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # No develop-overrides.toml at all — the fifth stage must be a
      # silent no-op so the gate behaves identically to M18.
      check not fileExists(
        developOverridesPath(fx.workspaceRoot))

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", fx.libA.sha)
      let res = invokeCheckPrePush(fx,
        currentRepo = fx.workspaceRoot / "lib-a",
        refsFile = refsFile)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["failures"].len == 0
      check report["lockUpdate"]["kind"].getStr() == "created"
