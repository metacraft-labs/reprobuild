## M19a — post-merge / post-checkout manifest auto-refresh skip rules.
##
## When the manifest checkout has a local commit on the SAME branch
## that has ALSO advanced upstream, the M10 ``refreshManifestLayers``
## helper records the per-layer outcome as ``mrsSkippedDivergent`` —
## ``merge-base --is-ancestor`` returns 1, ``--ff-only`` would refuse
## — and the M19a hook wrapper translates that into a single
## ``skipped_divergent`` log line. The hook STILL exits 0; an operator
## who deliberately rebased a manifest layer must resolve it by hand,
## NOT by having the next ``git pull`` quietly clobber their work.
##
## This test verifies the divergent-skip arm end-to-end:
##
##   1. Bare manifest-host seeded; one TOML commit on ``main``.
##   2. Layer cloned into ``.repo/manifests-0-<...>/`` via the M10
##      probe.
##   3. Upstream advances by one commit (push from a side seed clone).
##   4. The layer checkout ALSO advances by one commit on top of
##      ``main``, so the local branch carries an extra commit upstream
##      does NOT have. Combined with step 3 the two histories share an
##      ancestor (the original seed commit) but neither tip is an
##      ancestor of the other — the canonical divergent case.
##   5. ``post-merge`` dispatched; verify exit 0, manifest HEAD stayed
##      on the local commit (no merge attempted), ONE
##      ``skipped_divergent`` line in the cache log.
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
      "m19a-manifest-refresh-skips-when-divergent-repro",
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
  runShell(shellCommand(@[
    reproBin, "hooks", "dispatch", "post-merge",
    "--repo-root", currentRepo, "--", squashFlag,
  ], env = @[(name: "XDG_CACHE_HOME", value: cacheHome)]))

proc readCacheLog(cacheHome: string): string =
  let path = cacheHome / "repro" / "manifest-refresh.log"
  if not fileExists(path):
    return ""
  readFile(path)

suite "M19a — post-merge manifest auto-refresh (skips divergent layer)":

  test "test_m19a_post_merge_skips_when_manifest_layer_divergent":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-m19a-divergent-", "")
      defer: removeDir(scratch)
      let reproBin = compileRepro(scratch)
      let cacheHome = scratch / "cache"
      createDir(cacheHome)

      let manifestBare = scratch / "bare-manifest.git"
      seedBareWithFiles(gitBin, scratch, manifestBare, [
        ("projects/myproject.toml", projectTomlBody),
        ("repos/lib-a.toml", libATomlBody),
      ])
      let layerUrl = "file://" & manifestBare

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
        q("file://" & manifestBare) & " " & q(layerCheckoutPath))
      let seedSha = requireGit(q(gitBin) & " -C " &
        q(layerCheckoutPath) & " rev-parse HEAD").strip()

      # Configure the layer checkout so a local commit can be created
      # without raising on missing user identity.
      discard requireGit(q(gitBin) & " -C " & q(layerCheckoutPath) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(layerCheckoutPath) &
        " config user.name 'M19a Tester'")

      # Advance upstream by one commit on ``main`` (push from a side
      # clone so the layer checkout is strictly behind).
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
        " commit -m 'upstream advance'")
      discard requireGit(q(gitBin) & " -C " & q(manifestSeedWork) &
        " push origin main")
      let upstreamTip = requireGit(q(gitBin) & " -C " &
        q(manifestSeedWork) & " rev-parse HEAD").strip()
      check upstreamTip != seedSha

      # Advance the LAYER CHECKOUT by a different commit on ``main``,
      # without ever fetching upstream's advance. ``merge-base
      # --is-ancestor local upstream`` now returns 1: neither tip is
      # an ancestor of the other. M10 reports ``mrsSkippedDivergent``.
      writeFile(layerCheckoutPath / "repos" / "lib-local.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-local\"\npath = \"lib-local\"\n" &
        "revision = \"main\"\n")
      discard requireGit(q(gitBin) & " -C " & q(layerCheckoutPath) &
        " add -A")
      discard requireGit(q(gitBin) & " -C " & q(layerCheckoutPath) &
        " commit -m 'local manifest divergence'")
      let preRefreshSha = requireGit(q(gitBin) & " -C " &
        q(layerCheckoutPath) & " rev-parse HEAD").strip()
      check preRefreshSha != upstreamTip
      check preRefreshSha != seedSha

      # Dispatch the post-merge hook from the participating repo. M10
      # will run ``git fetch`` against the bare (which updates the
      # local clone's ``origin/main`` remote-tracking ref to
      # ``upstreamTip``), then refuse to ``--ff-only`` merge because
      # the two histories diverge — and the wrapper records ONE
      # ``skipped_divergent`` line.
      let res = invokePostMerge(reproBin, workspaceRoot / "lib-a",
        cacheHome, "0")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # The manifest checkout MUST still point at the local commit;
      # divergent-skip refuses to advance ANYTHING.
      let postRefreshSha = requireGit(q(gitBin) & " -C " &
        q(layerCheckoutPath) & " rev-parse HEAD").strip()
      check postRefreshSha == preRefreshSha

      # Exactly one ``skipped_divergent`` line in the cache log.
      let logBody = readCacheLog(cacheHome)
      let lines = logBody.splitLines().filterIt(it.len > 0)
      check lines.len == 1
      check lines[0].contains("skipped_divergent")
      check lines[0].contains("post-merge")
      check lines[0].contains(layerUrl)
