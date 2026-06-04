## M19a — post-merge / post-checkout manifest auto-refresh skip rules.
##
## When the manifest checkout has uncommitted edits, the M10
## ``refreshManifestLayers`` helper records the per-layer outcome as
## ``mrsSkippedDirty`` and the M19a hook wrapper translates that into a
## single ``skipped_dirty`` log line in
## ``$HOME/.cache/repro/manifest-refresh.log``. The hook STILL exits 0;
## the participating-repo ``git pull`` must never be blocked by the
## operator having half-edited a manifest layer in the background.
##
## This test verifies the dirty-skip arm end-to-end:
##
##   1. Bare manifest-host seeded; one TOML commit on ``main``.
##   2. Layer cloned into the canonical ``.repo/manifests-0-<...>/``
##      directory by a probe ``refreshManifestLayers`` call.
##   3. Bare advanced by a second commit (would normally trigger a
##      fast-forward).
##   4. An untracked file placed in the layer checkout so the working
##      tree is dirty.
##   5. ``post-merge`` dispatched; verify exit 0, manifest HEAD did
##      NOT advance, ONE ``skipped_dirty`` line in the cache log.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

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
    "--nimcache:" & root / "build" / "nimcache" /
      "m19a-manifest-refresh-skips-when-locally-dirty-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M19a Tester\"")
  for entry in files:
    let absPath = workPath / entry[0]
    createDir(absPath.splitPath.head)
    writeFile(absPath, entry[1])
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M19a Tester\"")
  writeFile(workPath / "README.md", "M19a participating-repo fixture\n")
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
    " config user.name \"M19a Tester\"")

const projectTomlBody = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "myproject"
default_revision = "main"
default_remote = "origin"
trunk = "main"

[[remote]]
name = "origin"
fetch = "https://example.invalid/dummy"

includes = [
  "repos/lib-a.toml",
]
"""

const libATomlBody = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
revision = "main"
"""

proc writeWorkspaceTomlWithLayer(workspaceRoot, layerUrl: string) =
  let dotRepo = workspaceRoot / ".repo"
  createDir(dotRepo)
  let body =
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"myproject\"\nbranch = \"main\"\n\n" &
    "[[manifest]]\n" &
    "url = \"" & layerUrl & "\"\n" &
    "visibility = \"public\"\nbranch = \"main\"\n"
  writeFile(dotRepo / "workspace.toml", body)

proc invokePostMerge(reproBin, currentRepo, cacheHome: string;
                     squashFlag: string): CmdResult =
  runShell(shellCommand(@[
    reproBin, "hooks", "dispatch", "post-merge",
    "--repo-root", currentRepo, "--", squashFlag,
  ], env = @[(name: "XDG_CACHE_HOME", value: cacheHome)]))

proc readCacheLog(cacheHome: string): string =
  let path = cacheHome / "repro" / "manifest-refresh.log"
  if not fileExists(path):
    return ""
  readFile(path)

suite "M19a — post-merge manifest auto-refresh (skips dirty layer)":

  test "test_m19a_post_merge_skips_when_manifest_layer_dirty":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m19a-dirty-", "")
      defer: removeDir(scratch)
      let reproBin = compileRepro(scratch)
      let cacheHome = scratch / "cache"
      createDir(cacheHome)

      let manifestBare = scratch / "bare-manifest.git"
      seedBareWithFiles(gitBin, scratch, manifestBare, [
        ("projects/myproject.toml", projectTomlBody),
        ("repos/lib-a.toml", libATomlBody),
      ])
      let layerUrl = fileUrl(manifestBare)

      let libOrigin = scratch / "origin-lib-a.git"
      let libSeed = scratch / "seed-lib-a"
      discard seedGitOrigin(gitBin, libOrigin, libSeed)
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      cloneInto(gitBin, libOrigin, workspaceRoot / "lib-a")

      writeWorkspaceTomlWithLayer(workspaceRoot, layerUrl)
      let probe = refreshManifestLayers(workspaceRoot)
      check probe.layers.len == 1
      let layerCheckoutPath = probe.layers[0].layerPath
      discard requireGit(q(gitBin) & " clone " &
        q(fileUrl(manifestBare)) & " " & q(layerCheckoutPath))
      let preRefreshSha = requireGit(q(gitBin) & " -C " &
        q(layerCheckoutPath) & " rev-parse HEAD").strip()

      # Advance the bare so the wrapper has somewhere to fast-forward
      # TO. The dirty-skip arm exists precisely to refuse advancing in
      # the face of operator-local edits.
      let manifestSeedWork = scratch / "seed-bare-manifest.git"
      removeDir(manifestSeedWork)
      discard requireGit(q(gitBin) & " clone " &
        q(fileUrl(manifestBare)) & " " & q(manifestSeedWork))
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " config user.name \"M19a Tester\"")
      writeFile(manifestSeedWork / "repos" / "lib-b.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-b\"\npath = \"lib-b\"\n" &
        "revision = \"main\"\n")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " commit -m \"upstream advance\"")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " push origin main")

      # Make the layer checkout dirty: an uncommitted modification to
      # an existing tracked file is the precise condition M10's
      # ``isClean`` flags. (Untracked files also count, but a modified
      # tracked file is the more common operator-mid-edit scenario.)
      writeFile(layerCheckoutPath / "repos" / "lib-a.toml",
        libATomlBody & "\n# WIP: operator was mid-edit when the\n" &
        "# participating repo's git pull fired the hook.\n")

      # Dispatch the post-merge hook from the participating repo.
      let res = invokePostMerge(reproBin, workspaceRoot / "lib-a",
        cacheHome, "0")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # The manifest layer must NOT have advanced — the dirty-skip arm
      # refused the fast-forward.
      let postRefreshSha = requireGit(q(gitBin) & " -C " &
        q(layerCheckoutPath) & " rev-parse HEAD").strip()
      check postRefreshSha == preRefreshSha

      # Exactly one ``skipped_dirty`` line in the cache log.
      let logBody = readCacheLog(cacheHome)
      let lines = logBody.splitLines().filterIt(it.len > 0)
      check lines.len == 1
      check lines[0].contains("skipped_dirty")
      check lines[0].contains("post-merge")
      check lines[0].contains(layerUrl)
