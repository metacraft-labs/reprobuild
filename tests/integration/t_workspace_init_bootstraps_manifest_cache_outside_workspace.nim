## RA-11 — bootstrap manifest cache: ``repro workspace init`` works
## OUTSIDE an existing workspace (no sibling manifest checkout yet) by
## cloning the manifest repo into a tool-managed cache and materialising
## ``.repo/manifests`` from it.
##
## Two halves:
##
##   A. Pure resolution-order unit checks on ``resolveManifestCacheRoot``
##      (hermetic, injected ``env``): ``REPRO_MANIFEST_CACHE`` override →
##      ``XDG_CACHE_HOME`` → ``%LOCALAPPDATA%`` (Windows) → ``~/.cache``,
##      all under ``reprobuild/manifests``; the private companion uses the
##      PARALLEL ``…/manifests-private`` tree.
##
##   B. End-to-end ``init --manifest-url=<bare> --private-manifest-url=…``
##      in a workspace dir that has NO ``.repo/manifests``. Assert init
##      populated the bootstrap cache (under the injected
##      ``REPRO_MANIFEST_CACHE``), materialised ``.repo/manifests`` with
##      the project TOML, and resolved/cloned the participating repo.
##
## Falsifiability:
##   - If init required a pre-existing ``.repo/manifests`` it would fail
##     to resolve the project (init exits non-zero / no cloned repo).
##   - If the private companion shared the public cache slug namespace,
##     the two caches would collide; we assert distinct cache roots.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import shared_clones

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

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA11 Tester\"")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "RA11 fixture\n")
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

suite "RA-11 — bootstrap manifest cache":

  test "resolveManifestCacheRoot honors the documented order":
    proc envWith(pairs: openArray[(string, string)]): proc(k: string): string =
      let captured = @pairs
      return proc(k: string): string =
        for (name, value) in captured:
          if name == k: return value
        ""

    # 1. REPRO_MANIFEST_CACHE override wins; private appends ``-private``.
    let ov = envWith({"REPRO_MANIFEST_CACHE": "/custom/cache"})
    check resolveManifestCacheRoot(ov, private = false) == "/custom/cache"
    check resolveManifestCacheRoot(ov, private = true) == "/custom/cache-private"

    # 2. XDG_CACHE_HOME → reprobuild/manifests (and the parallel private).
    let xdg = envWith({"XDG_CACHE_HOME": "/x/cache"})
    check resolveManifestCacheRoot(xdg, private = false) ==
      "/x/cache" / "reprobuild" / "manifests"
    check resolveManifestCacheRoot(xdg, private = true) ==
      "/x/cache" / "reprobuild" / "manifests-private"

    # 3. LOCALAPPDATA fallback on Windows (no XDG).
    let lad = envWith({"LOCALAPPDATA": "C:\\Users\\me\\AppData\\Local"})
    check resolveManifestCacheRoot(lad, private = false, isWindows = true) ==
      "C:\\Users\\me\\AppData\\Local" / "reprobuild" / "manifests"

    # 4. ~/.cache fallback.
    let hom = envWith({"HOME": "/home/me"})
    check resolveManifestCacheRoot(hom, private = false) ==
      "/home/me" / ".cache" / "reprobuild" / "manifests"

    # Public and private caches are DISTINCT roots (no slug collision).
    check resolveManifestCacheRoot(xdg, private = false) !=
      resolveManifestCacheRoot(xdg, private = true)

  test "t_workspace_init_bootstraps_manifest_cache_outside_workspace":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra11-bootstrap-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # Participating repo origin.
      let libOrigin = scratch / "origin-lib-a.git"
      let libSeed = scratch / "seed-lib-a"
      discard seedOrigin(gitBin, libOrigin, libSeed)

      # Public manifest bare repo.
      let manifestBare = scratch / "bare-manifest.git"
      seedBareWithFiles(gitBin, scratch, manifestBare, [
        ("projects/myproject.toml", projectTomlBody(fileUrl(libOrigin))),
        ("repos/lib-a.toml", libATomlBody),
      ])

      # A private companion manifest bare (content irrelevant; we only
      # assert it lands in the parallel private cache).
      let privateBare = scratch / "bare-manifest-private.git"
      seedBareWithFiles(gitBin, scratch, privateBare, [
        ("projects/_private_placeholder.toml",
          "schema = \"reprobuild.workspace.project.v1\"\n\n" &
          "[project]\nname = \"private\"\ndefault_revision = \"main\"\n" &
          "trunk = \"main\"\n\nincludes = []\n"),
      ])

      # Hermetic cache root: an injected REPRO_MANIFEST_CACHE under scratch.
      let manifestCacheRoot = scratch / "manifest-cache"

      # The workspace dir starts EMPTY — no .repo/manifests sibling.
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      check not dirExists(workspaceRoot / ".repo" / "manifests")

      let init = runShell(shellCommand(@[
        reproBin, "workspace", "init", "myproject",
        "--workspace-root=" & workspaceRoot,
        "--manifest-url=" & fileUrl(manifestBare),
        "--manifest-branch=main",
        "--private-manifest-url=" & fileUrl(privateBare),
      ], env = @[(name: "REPRO_MANIFEST_CACHE", value: manifestCacheRoot)]))
      if init.code != 0:
        checkpoint("init output: " & init.output)
      check init.code == 0

      # Bootstrap cache was populated (public + parallel private root).
      let publicCachePath = manifestCachePath(manifestCacheRoot,
        fileUrl(manifestBare))
      check dirExists(publicCachePath)
      let privateCachePath = manifestCachePath(
        manifestCacheRoot & "-private", fileUrl(privateBare))
      check dirExists(privateCachePath)

      # ``.repo/manifests`` materialised from the cache and carries the
      # project TOML — proving init resolved the project WITHOUT a
      # pre-existing sibling manifest checkout.
      check fileExists(workspaceRoot / ".repo" / "manifests" / "projects" /
        "myproject.toml")
      check dirExists(workspaceRoot / ".repo" / "manifests-private")

      # The participating repo was cloned by init.
      check dirExists(workspaceRoot / "lib-a" / ".git")

      let reportPath = workspaceRoot / ".repro" / "workspace" /
        "init-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      var clonedLibA = false
      for entry in report["cloned"]:
        if entry["path"].getStr() == "lib-a":
          clonedLibA = true
      check clonedLibA
