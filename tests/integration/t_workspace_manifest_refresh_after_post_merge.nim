## M19a — post-merge / post-checkout manifest auto-refresh (happy path).
##
## The M17-installed post-merge hook dispatches into
## ``repro hooks dispatch post-merge --repo-root <repo> --
## <hook-args>`` which routes to the M19a manifest-refresh wrapper. The
## wrapper invokes M10's ``refreshManifestLayers`` in best-effort mode:
## the in-tree manifest checkout is fast-forwarded when upstream has
## advanced, the originating git operation NEVER sees a non-zero hook
## status, and one line per layer is appended to
## ``$HOME/.cache/repro/manifest-refresh.log``.
##
## This test exercises the happy path:
##
##   1. Bare manifest-host git repo (the ``[[manifest]]`` ``url``)
##      seeded with one TOML-bearing commit.
##   2. The bare repo cloned into the workspace's
##      ``.repo/manifests-0-<sanitized>/`` directory by a probe call
##      to ``refreshManifestLayers`` (the M10 helper reports the
##      ``layerPath`` even on its initial ``mrsSkippedAbsent`` pass).
##   3. Bare advanced by a second commit (the SHA the auto-refresh must
##      land on).
##   4. Workspace's participating ``lib-a`` repo also advanced and the
##      ``post-merge`` hook dispatched with a non-zero squash-flag (the
##      single positional arg git passes).
##   5. Verify: exit code 0; manifest checkout HEAD now points at the
##      upstream tip; one ``refreshed`` line in the cache log.
##
## Skip rule: ``git`` missing on PATH (same convention as the rest of
## the workspace integration suite).

import std/[os, osproc, strutils, tempfiles, unittest]

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
      "m19a-manifest-refresh-after-post-merge-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  ## Mirrors the M12 / M8 composer-test fixture builder.
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name 'M19a Tester'")
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
  ## A non-bare participating-repo origin for the workspace's ``lib-a``.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name 'M19a Tester'")
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
    q("file://" & originPath) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name 'M19a Tester'")

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
  ## Exact argv the M17 hook dispatcher uses for post-merge. Per the
  ## canonical hook-body template the participating repo's post-merge
  ## script forwards ``"$@"`` (the squash-flag) after the ``--``
  ## separator.
  runShell(shellCommand(@[
    reproBin, "hooks", "dispatch", "post-merge",
    "--repo-root", currentRepo, "--", squashFlag,
  ], env = @[(name: "XDG_CACHE_HOME", value: cacheHome)]))

proc readCacheLog(cacheHome: string): string =
  let path = cacheHome / "repro" / "manifest-refresh.log"
  if not fileExists(path):
    return ""
  readFile(path)

suite "M19a — post-merge manifest auto-refresh (happy path)":

  test "test_m19a_post_merge_fast_forwards_manifest_layer":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m19a-post-merge-", "")
      defer: removeDir(scratch)
      let reproBin = compileRepro(scratch)
      # Per-test XDG_CACHE_HOME so the manifest-refresh log lives in a
      # hermetic location and does not leak into the developer's real
      # ``$HOME/.cache/repro``.
      let cacheHome = scratch / "cache"
      createDir(cacheHome)

      # 1. Seed the manifest-host bare repo with one TOML-bearing
      #    commit.
      let manifestBare = scratch / "bare-manifest.git"
      seedBareWithFiles(gitBin, scratch, manifestBare, [
        ("projects/myproject.toml", projectTomlBody),
        ("repos/lib-a.toml", libATomlBody),
      ])
      let layerUrl = "file://" & manifestBare

      # 2. Seed the participating repo (``lib-a``) origin + clone into
      #    the workspace.
      let libOrigin = scratch / "origin-lib-a.git"
      let libSeed = scratch / "seed-lib-a"
      discard seedGitOrigin(gitBin, libOrigin, libSeed)
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      cloneInto(gitBin, libOrigin, workspaceRoot / "lib-a")

      # 3. Write the workspace.toml declaring the manifest layer and
      #    pre-clone the layer into the same ``manifests-0-<sanitized>``
      #    path the M8 composer / M10 refresh expects. A probe call to
      #    ``refreshManifestLayers`` surfaces that path via
      #    ``layerPath`` (``mrsSkippedAbsent`` on the very first pass).
      writeWorkspaceTomlWithLayer(workspaceRoot, layerUrl)
      let probe = refreshManifestLayers(workspaceRoot)
      check probe.layers.len == 1
      check probe.layers[0].status == mrsSkippedAbsent
      let layerCheckoutPath = probe.layers[0].layerPath
      check layerCheckoutPath.len > 0

      # Clone the bare into the canonical layer directory. The compose
      # path normally does this; we shortcut it here so the test stays
      # focused on M19a's hook surface.
      discard requireGit(q(gitBin) & " clone " &
        q("file://" & manifestBare) & " " & q(layerCheckoutPath))
      let preRefreshSha = requireGit(q(gitBin) & " -C " &
        q(layerCheckoutPath) & " rev-parse HEAD").strip()

      # 4. Advance the bare manifest-host by a second commit so the
      #    in-tree layer is one commit behind ``origin/main``.
      let manifestSeedWork = scratch / "seed-bare-manifest.git"
      removeDir(manifestSeedWork)
      discard requireGit(q(gitBin) & " clone " &
        q("file://" & manifestBare) & " " & q(manifestSeedWork))
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " config user.name 'M19a Tester'")
      writeFile(manifestSeedWork / "repos" / "lib-b.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-b\"\npath = \"lib-b\"\n" &
        "revision = \"main\"\n")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " commit -m 'second manifest commit'")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " push origin main")
      let upstreamTipSha = requireGit(q(gitBin) & " -C " &
        q(manifestSeedWork) & " rev-parse HEAD").strip()
      check upstreamTipSha != preRefreshSha

      # 5. Dispatch the post-merge hook from the participating repo.
      #    Git always passes one positional arg (the squash-flag, "0"
      #    or "1") to post-merge; pass "0" here.
      let res = invokePostMerge(reproBin, workspaceRoot / "lib-a",
        cacheHome, "0")
      if res.code != 0:
        checkpoint("output: " & res.output)
      # Best-effort contract: ALWAYS exit 0.
      check res.code == 0

      # 6. Verify the layer checkout was fast-forwarded to the upstream
      #    tip.
      let postRefreshSha = requireGit(q(gitBin) & " -C " &
        q(layerCheckoutPath) & " rev-parse HEAD").strip()
      check postRefreshSha == upstreamTipSha

      # 7. Verify exactly one ``refreshed`` log line was written.
      let logBody = readCacheLog(cacheHome)
      check logBody.contains(" refreshed ")
      check logBody.contains(preRefreshSha)
      check logBody.contains(upstreamTipSha)
      check logBody.contains("post-merge")
