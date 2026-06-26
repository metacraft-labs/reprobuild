## RA-31 — ``repro workspace init <url>`` clones the org ROOT workspace repo
## into a NEW NAMED directory and syncs the member repos.
##
## Hermetic, black-box (no network): local bare repos stand in for the org
## root repo (``<org>/repro-workspace``), the manifest repo, and one member
## repo. The org root repo carries a ``.repro-workspace.toml`` host bootstrap
## config pointing at the manifest repo, which declares the member repo.
##
## We drive the ``github:<org>`` shorthand with the github alias base
## overridden (``REPRO_VCS_HOST_BASE_GITHUB``) to a local ``file://`` hosts
## directory laid out as ``<base>/<org>/repro-workspace`` — so the shorthand
## resolves to the local bare root repo. ``init`` then:
##   - clones the root repo into a directory named after the ORG (NOT cwd);
##   - reads the cloned ``.repro-workspace.toml``;
##   - bootstraps ``.repo/manifests`` from the manifest URL (RA-11 cache);
##   - syncs / clones the declared member repo.
##
## Assertions:
##   - the named ``<org>/`` directory is created (NOT cwd / parent);
##   - the cwd and its parent are untouched (no ``.repo`` leaks out);
##   - ``.repo/manifests`` materialised with the project TOML;
##   - the member repo is checked out under the named dir;
##   - the output ends pointing the user at ``repro health``.
##
## Falsifiability:
##   - If ``local-path`` defaulted to cwd, the named-dir assertion fails and
##     the cwd-untouched assertion fails.
##   - If the root repo's bootstrap config were ignored, ``.repo/manifests``
##     would not materialise and the member would not be cloned.
##   - If the closing ``repro health`` pointer were dropped, its check fails.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string; cwd = ""): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA31 Tester\"")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  ## A member-repo origin with one commit on ``main``.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "RA31 member fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m first")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  for entry in files:
    let absPath = workPath / entry[0]
    createDir(absPath.splitPath.head)
    writeFile(absPath, entry[1])
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

proc projectTomlBody(libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libATomlBody = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-origin"
revision = "main"
"""

proc bootstrapTomlBody(manifestUrl: string): string =
  ## The host bootstrap config committed in the org root repo.
  "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
  "[manifest]\n" &
  "url = \"" & manifestUrl & "\"\n" &
  "branch = \"main\"\n\n" &
  "[projects]\n" &
  "default = [\"myproject\"]\n"

suite "RA-31 — clone org root repo + sync into named path":

  test "t_workspace_init_clones_org_root_repo_and_syncs_into_named_path":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra31-clone-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let org = "acme-org"

      # Member repo origin.
      let libOrigin = scratch / "origin-lib-a.git"
      let libSeed = scratch / "seed-lib-a"
      discard seedOrigin(gitBin, libOrigin, libSeed)

      # Manifest bare repo declaring the member.
      let manifestBare = scratch / "bare-manifest.git"
      seedBareWithFiles(gitBin, scratch, manifestBare, [
        ("projects/myproject.toml", projectTomlBody(fileUrl(libOrigin))),
        ("repos/lib-a.toml", libATomlBody),
      ])

      # Org ROOT workspace repo, laid out at ``<hostBase>/<org>/repro-workspace``
      # so the ``github:<org>`` shorthand resolves to it. It carries the host
      # bootstrap config pointing at the manifest repo.
      let hostBase = scratch / "hosts" / "github"
      let rootBare = hostBase / org / "repro-workspace"
      createDir(hostBase / org)
      seedBareWithFiles(gitBin, scratch, rootBare, [
        (".repro-workspace.toml", bootstrapTomlBody(fileUrl(manifestBare))),
      ])

      # A clean working directory to run ``init`` from. The named dir must be
      # created HERE as a child, and this dir + its parent must stay untouched.
      let runDir = scratch / "run-here"
      createDir(runDir)
      let parentOfRun = scratch  # the parent of runDir

      let manifestCacheRoot = scratch / "manifest-cache"

      let init = runShell(shellCommand(@[
        reproBin, "workspace", "init", "github:" & org,
      ], env = @[
        (name: "REPRO_VCS_HOST_BASE_GITHUB", value: fileUrl(hostBase)),
        (name: "REPRO_MANIFEST_CACHE", value: manifestCacheRoot),
      ]), cwd = runDir)
      if init.code != 0:
        checkpoint("init output: " & init.output)
      check init.code == 0

      # The named directory (after the ORG) was created as a child of runDir.
      let named = runDir / org
      check dirExists(named)

      # cwd (runDir) and its parent are UNTOUCHED — init never materialised a
      # workspace into them.
      check not dirExists(runDir / ".repo")
      check not dirExists(parentOfRun / ".repo")
      # The only child created under runDir is the named org dir.
      var childCount = 0
      for kind, path in walkDir(runDir):
        inc childCount
      check childCount == 1

      # The org root repo was cloned (carrying the bootstrap config).
      check fileExists(named / ".repro-workspace.toml")

      # ``.repo/manifests`` materialised from the manifest URL, with the
      # project TOML — proving the cloned bootstrap config drove the sync.
      check fileExists(named / ".repo" / "manifests" / "projects" /
        "myproject.toml")

      # The declared member repo was checked out under the named dir.
      check dirExists(named / "lib-a" / ".git")

      # The command ends by pointing the user at ``repro health``.
      check init.output.contains("repro health")
