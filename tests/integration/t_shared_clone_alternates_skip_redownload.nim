## RA-5 — shared bare-clone cache + alternates: skip re-download.
##
## Two hermetic workspaces (W1, W2) clone the SAME local bare upstream
## through ``repro workspace init``. The shared object-cache (per-upstream
## bare + per-repo ``objects/info/alternates``) means W2's clone reads
## objects from the shared pool instead of re-downloading them.
##
## What this test asserts (both must hold, and each is falsifiable):
##
##   1. **Alternates are wired.** W2's cloned repo has an
##      ``objects/info/alternates`` entry pointing at the shared bare's
##      ``objects/`` dir. (Falsifiable: absent if init didn't wire the
##      shared cache.)
##   2. **~0 objects re-downloaded.** W2's clone keeps essentially no
##      objects of its own — every object reachable through the reference
##      is served from the shared pool, NOT copied into W2. We assert
##      W2's own object count is far smaller than the full object count a
##      standalone (no-cache) clone of the same upstream carries.
##      (Falsifiable: a plain clone would carry the full object set
##      locally.)
##   3. **Transparency.** W2's resolved tree (HEAD SHA + working-tree
##      file content) is byte-identical to a cold-cache standalone clone
##      of the same pinned revision. (Falsifiable: a different tree would
##      mean the accelerator changed what was built.)
##
## Hermetic: a local ``git init --bare`` upstream under a single
## ``createTempDir`` root; no network. Skip only when ``git`` is missing.
##
## ``REPRO_WORKSPACE_CLONES`` is pointed at a per-test temp dir so the
## shared cache is isolated from the real user cache and from other tests.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   nCommits = 5; branch = "main"): string =
  ## Bare upstream with several commits so there is a non-trivial object
  ## set to (not) re-download. Returns the tip SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA5 Tester\"")
  for i in 0 ..< nCommits:
    writeFile(workPath / ("file-" & $i & ".txt"),
      "content " & $i & "\n" & repeat("payload ", 64) & "\n")
    discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(workPath) &
      " commit -m commit-" & $i)
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc projectToml(libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"ra5proj\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib.toml\",\n]\n"

const libFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
"""

proc seedWorkspace(scratch, slug, libUrl: string): string =
  let workspaceRoot = scratch / ("ws-" & slug)
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "ra5proj.toml", projectToml(libUrl))
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragmentToml)
  workspaceRoot

proc countObjects(gitBin, repoPath: string): int =
  ## Count objects physically present in ``repoPath``'s OWN object store
  ## (loose + packed), i.e. NOT counting objects reachable only through
  ## alternates. ``git count-objects -v`` reports ``count`` (loose) and
  ## ``in-pack`` for this repo only — alternates are excluded.
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) & " count-objects -v")
  if res.code != 0:
    checkpoint("count-objects failed: " & res.output)
    quit 1
  var loose = 0
  var inPack = 0
  for line in res.output.splitLines:
    let parts = line.split(':')
    if parts.len == 2:
      let key = parts[0].strip()
      let val = parts[1].strip()
      if key == "count": loose = parseInt(val)
      elif key == "in-pack": inPack = parseInt(val)
  loose + inPack

proc treeFiles(repoPath: string): seq[(string, string)] =
  ## Sorted (relpath, content) of every tracked file under the working
  ## tree (skipping ``.git``). Used for the byte-identical comparison.
  var entries: seq[(string, string)]
  for path in walkDirRec(repoPath, relative = true):
    if path.startsWith(".git" & DirSep) or path == ".git":
      continue
    let abs = repoPath / path
    if fileExists(abs):
      entries.add((path.replace(DirSep, '/'), readFile(abs)))
  entries.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
  entries

suite "RA-5 — shared clone alternates skip re-download":

  test "test_ra5_alternates_skip_redownload_and_transparent":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra5-skip-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let origin = scratch / "origin-lib.git"
      let tipSha = seedGitOrigin(gitBin, origin, scratch / "seed-lib")
      let libUrl = fileUrl(origin)

      # Isolate the shared cache for this test.
      let cacheDir = scratch / "clones-cache"
      var env = @[("REPRO_WORKSPACE_CLONES", cacheDir)]

      # --- W1: cold cache. Init populates the shared bare. -------------
      let w1 = seedWorkspace(scratch, "w1", libUrl)
      let r1 = runShell(shellCommand(@[
        reproBin, "workspace", "init", "ra5proj",
        "--workspace-root=" & w1,
      ], env))
      if r1.code != 0:
        checkpoint("W1 init output: " & r1.output)
      check r1.code == 0
      check dirExists(w1 / "lib" / ".git")

      # The shared bare now exists under the cache root. The slug is
      # ``<host>/<path-segments>.git``; rather than reconstruct it by
      # hand, assert the cache holds exactly one populated bare and use
      # it.
      var bares: seq[string]
      for path in walkDirRec(cacheDir, relative = false,
          yieldFilter = {pcDir}):
        if path.endsWith(".git") and dirExists(path / "objects"):
          bares.add(path)
      check bares.len == 1
      let bare = bares[0]

      # --- W2: warm cache. Init clones the SAME upstream via alternates.
      let w2 = seedWorkspace(scratch, "w2", libUrl)
      let r2 = runShell(shellCommand(@[
        reproBin, "workspace", "init", "ra5proj",
        "--workspace-root=" & w2,
      ], env))
      if r2.code != 0:
        checkpoint("W2 init output: " & r2.output)
      check r2.code == 0
      check dirExists(w2 / "lib" / ".git")

      # (1) Alternates wired in W2 → the shared bare's objects dir.
      let altPath = w2 / "lib" / ".git" / "objects" / "info" / "alternates"
      check fileExists(altPath)
      let altContent = readFile(altPath)
      check (bare / "objects") in altContent

      # (3a) Transparency: W2's HEAD matches the upstream tip exactly.
      let w2Head = requireGit(q(gitBin) & " -C " & q(w2 / "lib") &
        " rev-parse HEAD").strip()
      check w2Head == tipSha

      # Reference: a plain standalone clone (no cache) of the same pin.
      let plain = scratch / "plain-clone"
      discard requireGit(q(gitBin) & " clone --branch main " & q(libUrl) &
        " " & q(plain))
      let plainHead = requireGit(q(gitBin) & " -C " & q(plain) &
        " rev-parse HEAD").strip()
      check plainHead == tipSha

      # (3b) Transparency: byte-identical working tree.
      check treeFiles(w2 / "lib") == treeFiles(plain)

      # (2) ~0 objects re-downloaded: W2's OWN object store is far smaller
      # than the full object set the standalone clone carries.
      let w2Objects = countObjects(gitBin, w2 / "lib")
      let plainObjects = countObjects(gitBin, plain)
      checkpoint("w2 own objects=" & $w2Objects &
        " standalone objects=" & $plainObjects)
      # The standalone clone packs the whole history (>= 10 objects for 5
      # commits worth of trees/blobs/commits); W2 must hold a small
      # fraction of that locally (the rest served from the shared bare).
      check plainObjects >= 10
      check w2Objects * 2 < plainObjects
