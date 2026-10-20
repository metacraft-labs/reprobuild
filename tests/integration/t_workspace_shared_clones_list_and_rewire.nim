## Foreign-pool regression design: real local bare origins and clone --shared
## leaves, with no mocked filesystem or Git adapter. A foreign-only safety ref
## and tag survive consolidation; a two-layer graph has a base available only
## from the old pool, asserted before migration. Renaming that pool afterwards
## proves all refs, detached worktree HEADs and the local graph remain usable.
## Reflog-only commits, annotated tags, dirty tracked/untracked files and index
## bytes must survive. A blobless partial pool exercises rewire before
## consolidation and proves promised foreign-only safety blobs remain readable
## with lazy fetching disabled after both foreign pool and old upstream vanish. A dangling
## symbolic ref (omitted by for-each-ref) refuses migration without rewiring.
##
## RA-5 — `repro workspace shared-clones [root|list|rewire]`.
##
## Covers the operator-facing inspection / repair surface:
##
##   * ``root``   — prints the resolved cache root (honoring the
##                  ``REPRO_WORKSPACE_CLONES`` override).
##   * ``list``   — read-only per-repo wiring view (bare present? wired?).
##   * ``rewire`` — idempotently retrofits an existing workspace: it
##                  populates the shared bare and writes the alternates
##                  entry into an already-checked-out repo that lacks it.
##                  A second ``rewire`` is a no-op (``rewired=false``).
##
## Falsifiability: ``rewire`` flips ``wired`` from false→true and writes
## a real ``objects/info/alternates`` file (asserted on disk); a re-run
## reports ``rewired=false`` (idempotence). Hermetic local upstream; skip
## only when ``git`` is missing.

import std/[algorithm, json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import shared_clones
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc treeBytes(path: string): seq[(string, string)] =
  ## Tiny fixture trees can be compared byte-for-byte: observation and a failed
  ## migration must not install retention metadata or rewrite a foreign pool.
  if dirExists(path):
    for file in walkDirRec(path):
      result.add((relativePath(file, path), readFile(file)))
    result.sort()

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    stderr.writeLine("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA5 Tester\"")
  writeFile(workPath / "README.md", "ra5 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m base")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " &
    branch)
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

proc seedWorkspace(scratch, libUrl: string): string =
  let workspaceRoot = scratch / "ws"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "ra5proj.toml", projectToml(libUrl))
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragmentToml)
  workspaceRoot

suite "RA-5 — repro workspace shared-clones":

  test "test_ra5_shared_clones_root_list_rewire":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra5-sc-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let origin = scratch / "origin-lib.git"
      discard seedGitOrigin(gitBin, origin, scratch / "seed-lib")
      let libUrl = fileUrl(origin)

      let cacheDir = scratch / "clones-cache"
      let env = @[("REPRO_WORKSPACE_CLONES", cacheDir)]
      let ws = seedWorkspace(scratch, libUrl)

      # --- root: prints the override path verbatim. -------------------
      let rootRes = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "root",
        "--workspace-root=" & ws,
      ], env))
      check rootRes.code == 0
      check rootRes.output.strip() == cacheDir

      # Pre-clone the repo into the workspace WITHOUT alternates so the
      # repo is "checked out but unwired" — exactly what rewire repairs.
      discard requireGit(q(gitBin) & " clone --branch main " & q(libUrl) &
        " " & q(ws / "lib"))
      let altPath = ws / "lib" / ".git" / "objects" / "info" / "alternates"
      check not fileExists(altPath)

      # --- list: read-only; reports unwired + no bare yet. ------------
      let listRes = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "list", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      check listRes.code == 0
      let listReport = parseJson(listRes.output)
      check listReport["repos"].len == 1
      check listReport["repos"][0]["wired"].getBool() == false
      # list does no network work → bare not yet populated.
      check not fileExists(altPath)

      # --- rewire: populates the bare + writes the alternates. --------
      let rewireRes = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "rewire", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      if rewireRes.code != 0:
        checkpoint("rewire output: " & rewireRes.output)
      check rewireRes.code == 0
      let rewireReport = parseJson(rewireRes.output)
      check rewireReport["repos"][0]["wired"].getBool() == true
      check rewireReport["repos"][0]["rewired"].getBool() == true

      # On-disk proof: the alternates file now points at the shared bare.
      check fileExists(altPath)
      let bare = rewireReport["repos"][0]["sharedBarePath"].getStr()
      check (bare / "objects") in readFile(altPath)

      # --- rewire again: idempotent (already wired → rewired=false). ---
      let rewire2 = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "rewire", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      check rewire2.code == 0
      let report2 = parseJson(rewire2.output)
      check report2["repos"][0]["wired"].getBool() == true
      check report2["repos"][0]["rewired"].getBool() == false

  test "test_ra5_shared_clones_verdict_refspec_without_safety":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case drives the real git binary")
    else:
      let scratch = createTempDir("repro-ra5-sc-verdict-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let origin = scratch / "origin-lib.git"
      discard seedGitOrigin(gitBin, origin, scratch / "seed-lib")
      let libUrl = fileUrl(origin)

      let cacheDir = scratch / "clones-cache"
      let env = @[("REPRO_WORKSPACE_CLONES", cacheDir)]
      let ws = seedWorkspace(scratch, libUrl)

      # 1. Bare not present -> verdict is "no-bare"
      let listBefore = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "list", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      check listBefore.code == 0
      let reportBefore = parseJson(listBefore.output)
      check reportBefore["repos"].len == 1
      check reportBefore["repos"][0].hasKey("verdict")
      check reportBefore["repos"][0]["verdict"].getStr() == "no-bare"

      let listBeforeText = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "list", "ra5proj",
        "--workspace-root=" & ws,
      ], env))
      check listBeforeText.code == 0
      check "verdict=no-bare" in listBeforeText.output

      # 2. Hand-configure bare into refspec-without-safety
      let barePath = reportBefore["repos"][0]["sharedBarePath"].getStr()
      createDir(barePath)
      discard requireGit(q(gitBin) & " init --bare -q " & q(barePath))
      discard requireGit(q(gitBin) & " -C " & q(barePath) &
        " config --replace-all remote.origin.fetch \"+refs/heads/*:refs/heads/*\"")

      let listRefspecOnly = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "list", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      check listRefspecOnly.code == 0
      let reportRefspecOnly = parseJson(listRefspecOnly.output)
      check reportRefspecOnly["repos"][0].hasKey("verdict")
      check reportRefspecOnly["repos"][0]["verdict"].getStr() == "refspec-without-safety"

      let listRefspecOnlyText = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "list", "ra5proj",
        "--workspace-root=" & ws,
      ], env))
      check listRefspecOnlyText.code == 0
      check "verdict=refspec-without-safety" in listRefspecOnlyText.output

      # 3. Configure safety keys -> verdict is "ok"
      discard requireGit(q(gitBin) & " -C " & q(barePath) & " config --replace-all gc.auto 0")
      discard requireGit(q(gitBin) & " -C " & q(barePath) & " config --replace-all maintenance.auto false")
      discard requireGit(q(gitBin) & " -C " & q(barePath) & " config --replace-all maintenance.strategy none")
      discard requireGit(q(gitBin) & " -C " & q(barePath) & " config --replace-all gc.writeCommitGraph false")
      discard requireGit(q(gitBin) & " -C " & q(barePath) & " config --replace-all fetch.writeCommitGraph false")
      discard requireGit(q(gitBin) & " -C " & q(barePath) & " config --replace-all gc.pruneExpire never")

      let listOk = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "list", "ra5proj",
        "--workspace-root=" & ws, "--json",
      ], env))
      check listOk.code == 0
      let reportOk = parseJson(listOk.output)
      check reportOk["repos"][0].hasKey("verdict")
      check reportOk["repos"][0]["verdict"].getStr() == "ok"

      let listOkText = runShell(shellCommand(@[
        reproBin, "workspace", "shared-clones", "list", "ra5proj",
        "--workspace-root=" & ws,
      ], env))
      check listOkText.code == 0
      check "verdict=ok" in listOkText.output


  test "foreign pool consolidation preserves safety refs tags and graph":
    let git = findExe("git")
    require git.len > 0
    let scratch = createTempDir("repro-consolidate-", "")
    defer: removeDir(scratch)
    let origin = scratch / "origin.git"
    discard seedGitOrigin(git, origin, scratch / "seed")
    let ws = seedWorkspace(scratch, fileUrl(origin))
    let env = @[("REPRO_WORKSPACE_CLONES", scratch / "canonical")]
    let initialized = runShell(shellCommand(@[reproBinary(), "workspace", "init",
      "ra5proj", "--workspace-root=" & ws], env))
    checkpoint initialized.output
    require initialized.code == 0
    removeDir(ws / "lib")
    let foreign = scratch / "foreign.git"
    discard requireGit(q(git) & " clone --bare " & q(origin) & " " & q(foreign))
    # Only the foreign pool owns these commits. Neither the canonical pool nor
    # the upstream knows the tag and safety ref; checking only HEAD is unsound.
    discard requireGit(q(git) & " -C " & q(scratch / "seed") &
      " commit --allow-empty -m foreign-only")
    let safety = requireGit(q(git) & " -C " & q(scratch / "seed") & " rev-parse HEAD").strip()
    discard requireGit(q(git) & " -C " & q(scratch / "seed") & " push " & q(foreign) &
      " HEAD:refs/heads/old")
    discard requireGit(q(git) & " -C " & q(foreign) &
      " -c user.name=Tester -c user.email=tester@example.invalid tag -a archive " & safety & " -m archive")
    let annotated = requireGit(q(git) & " -C " & q(foreign) & " rev-parse refs/tags/archive").strip()
    discard requireGit(q(git) & " -C " & q(scratch / "seed") & " commit --allow-empty -m reflog-only")
    let reflogOnly = requireGit(q(git) & " -C " & q(scratch / "seed") & " rev-parse HEAD").strip()
    discard requireGit(q(git) & " -C " & q(scratch / "seed") & " push " & q(foreign) & " HEAD:refs/heads/reflog")
    discard requireGit(q(git) & " -C " & q(foreign) & " commit-graph write --reachable --split")
    let leaf = ws / "lib"
    discard requireGit(q(git) & " clone --shared " & q(foreign) & " " & q(leaf))
    discard requireGit(q(git) & " -C " & q(leaf) & " remote set-url origin " & q(origin))
    discard requireGit(q(git) & " -C " & q(leaf) & " update-ref refs/pre-sync/old " & safety)
    discard requireGit(q(git) & " -C " & q(leaf) & " update-ref refs/tags/old " & safety)
    discard requireGit(q(git) & " -C " & q(leaf) & " update-ref -d refs/remotes/origin/old")
    discard requireGit(q(git) & " -C " & q(leaf) & " checkout --detach " & reflogOnly)
    discard requireGit(q(git) & " -C " & q(leaf) & " checkout main")
    discard requireGit(q(git) & " -C " & q(leaf) & " update-ref -d refs/remotes/origin/reflog")
    let reflogBefore = readFile(leaf / ".git/logs/HEAD")
    discard requireGit(q(git) & " -C " & q(leaf) & " config user.name Tester")
    discard requireGit(q(git) & " -C " & q(leaf) & " config user.email tester@example.invalid")
    discard requireGit(q(git) & " -C " & q(leaf) & " commit --allow-empty -m leaf-only")
    discard requireGit(q(git) & " -C " & q(leaf) & " commit-graph write --reachable --split=no-merge")
    let graphDir = leaf / ".git/objects/info/commit-graphs"
    let layers = readFile(graphDir / "commit-graph-chain").strip().splitLines()
    require layers.len == 2
    check not fileExists(graphDir / ("graph-" & layers[0] & ".graph"))
    check fileExists(foreign / "objects/info/commit-graphs" / ("graph-" & layers[0] & ".graph"))
    let linked = scratch / "linked"
    discard requireGit(q(git) & " -C " & q(leaf) & " worktree add --detach " & q(linked) & " " & safety)
    check expandFilename(checkoutLockPath(leaf).parentDir) ==
      expandFilename(checkoutLockPath(linked).parentDir)
    check checkoutLockPath(leaf).lastPathPart == checkoutLockPath(linked).lastPathPart
    writeFile(leaf / "README.md", "dirty tracked content\n")
    writeFile(leaf / "untracked", "keep me\n")
    let indexBefore = readFile(leaf / ".git/index")
    let bin = reproBinary()
    let health = runShell(shellCommand(@[bin, "health", "--workspace-root=" & ws], env))
    checkpoint health.output
    check foreign in health.output
    check "examined 1 of 1" in health.output
    let rewired = runShell(shellCommand(@[bin, "ws", "shared-clones", "rewire",
      "ra5proj", "--workspace-root=" & ws, "--json"], env))
    require rewired.code == 0
    let report = parseJson(rewired.output)
    check "migration incomplete" in report["repos"][0]["diagnostic"].getStr()
    let canonical = report["repos"][0]["sharedBarePath"].getStr()
    # Git can return success without writing a graph under this setting. The
    # migration must still produce the independent graph it promises.
    discard requireGit(q(git) & " -C " & q(leaf) & " config core.commitGraph false")
    let migrated = runShell(shellCommand(@[bin, "ws", "shared-clones", "consolidate",
      "ra5proj", "--workspace-root=" & ws], env))
    checkpoint migrated.output
    require migrated.code == 0
    check readAlternates(leaf) == @[canonical / "objects"]
    moveDir(foreign, scratch / "unavailable")
    let fsck = runCmd(q(git) & " -C " & q(leaf) & " fsck --full")
    checkpoint fsck.output
    check fsck.code == 0
    check "unable to find" notin fsck.output
    check readFile(leaf / "README.md") == "dirty tracked content\n"
    check readFile(leaf / "untracked") == "keep me\n"
    check readFile(leaf / ".git/index") == indexBefore
    check readFile(leaf / ".git/logs/HEAD").startsWith(reflogBefore)
    discard requireGit(q(git) & " -C " & q(leaf) & " cat-file -e " & reflogOnly)
    check requireGit(q(git) & " -C " & q(leaf) & " rev-parse refs/tags/archive").strip() == annotated
    discard requireGit(q(git) & " -C " & q(leaf) & " cat-file -e " & annotated)
    check requireGit(q(git) & " -C " & q(linked) & " rev-parse HEAD").strip() == safety
    discard requireGit(q(git) & " -C " & q(linked) & " cat-file -e HEAD")
    check fileExists(leaf / ".git/objects/info/commit-graph")
    check not fileExists(graphDir / "commit-graph-chain")
    for refName in ["refs/pre-sync/old", "refs/tags/old"]:
      check requireGit(q(git) & " -C " & q(leaf) & " rev-parse " & refName).strip() == safety
      discard requireGit(q(git) & " -C " & q(leaf) & " cat-file -e " & refName)
    check requireGit(q(git) & " -C " & q(leaf) & " config remote.repro-pool.url").strip() == poolFileUrl(canonical)

  test "consolidation refuses dangling symbolic ref and restores alternates":
    let git = findExe("git")
    require git.len > 0
    let scratch = createTempDir("repro-consolidate-refuse-", "")
    defer: removeDir(scratch)
    let origin = scratch / "origin.git"
    discard seedGitOrigin(git, origin, scratch / "seed")
    let ws = seedWorkspace(scratch, fileUrl(origin))
    let env = @[("REPRO_WORKSPACE_CLONES", scratch / "canonical")]
    let initialized = runShell(shellCommand(@[reproBinary(), "workspace", "init",
      "ra5proj", "--workspace-root=" & ws], env))
    checkpoint initialized.output
    require initialized.code == 0
    removeDir(ws / "lib")
    let foreign = scratch / "foreign.git"
    discard requireGit(q(git) & " clone --bare " & q(origin) & " " & q(foreign))
    let leaf = ws / "lib"
    discard requireGit(q(git) & " clone --shared " & q(foreign) & " " & q(leaf))
    discard requireGit(q(git) & " -C " & q(leaf) & " symbolic-ref refs/remotes/old/HEAD refs/remotes/old/missing")
    let path = alternatesFilePath(leaf)
    let before = readFile(path)
    let migrated = runShell(shellCommand(@[reproBinary(), "ws", "shared-clones",
      "consolidate", "ra5proj", "--workspace-root=" & ws],
      @[("REPRO_WORKSPACE_CLONES", scratch / "canonical")]))
    checkpoint migrated.output
    check migrated.code != 0
    check readFile(path) == before
    check requireGit(q(git) & " -C " & q(leaf) & " symbolic-ref refs/remotes/old/HEAD").strip() == "refs/remotes/old/missing"

  test "consolidation hydrates promised safety blobs after additive rewire":
    let git = findExe("git")
    require git.len > 0
    let scratch = createTempDir("repro-consolidate-promisor-", "")
    defer: removeDir(scratch)
    let origin = scratch / "origin.git"
    let seed = scratch / "seed"
    discard seedGitOrigin(git, origin, seed)
    let ws = seedWorkspace(scratch, fileUrl(origin))
    let env = @[("REPRO_WORKSPACE_CLONES", scratch / "canonical")]
    let bin = reproBinary()
    let initialized = runShell(shellCommand(@[bin, "workspace", "init",
      "ra5proj", "--workspace-root=" & ws], env))
    require initialized.code == 0
    removeDir(ws / "lib")
    let retired = scratch / "retired-origin.git"
    discard requireGit(q(git) & " clone --bare " & q(origin) & " " & q(retired))
    discard requireGit(q(git) & " -C " & q(retired) & " config uploadpack.allowFilter true")
    discard requireGit(q(git) & " -C " & q(retired) & " config uploadpack.allowAnySHA1InWant true")
    writeFile(seed / "secret", "foreign-only promised safety blob\n")
    discard requireGit(q(git) & " -C " & q(seed) & " add secret")
    discard requireGit(q(git) & " -C " & q(seed) & " commit -m safety")
    let safety = requireGit(q(git) & " -C " & q(seed) & " rev-parse HEAD").strip()
    let blob = requireGit(q(git) & " -C " & q(seed) & " rev-parse HEAD:secret").strip()
    discard requireGit(q(git) & " -C " & q(seed) & " push " & q(retired) & " HEAD:refs/heads/old")
    let foreign = scratch / "foreign.git"
    discard requireGit(q(git) & " clone --bare --filter=blob:none " & q(fileUrl(retired)) & " " & q(foreign))
    # Checkout needs main's blob; hydrate only that one so the safety commit's
    # new blob remains absent (asserted below with lazy fetching disabled).
    discard requireGit(q(git) & " -C " & q(foreign) & " cat-file -p main:README.md")
    let leaf = ws / "lib"
    discard requireGit(q(git) & " clone --shared " & q(foreign) & " " & q(leaf))
    discard requireGit(q(git) & " -C " & q(leaf) & " remote set-url origin " & q(origin))
    discard requireGit(q(git) & " -C " & q(leaf) & " update-ref refs/pre-sync/safety " & safety)
    discard requireGit(q(git) & " -C " & q(leaf) & " update-ref -d refs/remotes/origin/old")
    require ensureLeafPoolConfig(git, leaf, foreign).len == 0
    let absent = runShell(shellCommand(@[git, "-C", leaf, "cat-file", "-e", blob],
      @[("GIT_NO_LAZY_FETCH", "1")]))
    require absent.code != 0
    let rewired = runShell(shellCommand(@[bin, "ws", "shared-clones", "rewire",
      "ra5proj", "--workspace-root=" & ws], env))
    require rewired.code == 0
    let migrated = runShell(shellCommand(@[bin, "ws", "shared-clones", "consolidate",
      "ra5proj", "--workspace-root=" & ws], env))
    checkpoint migrated.output
    require migrated.code == 0
    moveDir(foreign, scratch / "foreign-unavailable")
    moveDir(retired, scratch / "upstream-unavailable")
    let readable = runShell(shellCommand(@[git, "-C", leaf, "cat-file", "-p", blob],
      @[("GIT_NO_LAZY_FETCH", "1")]))
    checkpoint readable.output
    check readable.code == 0
    check readable.output.strip() == "foreign-only promised safety blob"
    check runCmd(q(git) & " -C " & q(leaf) & " fsck --full").code == 0

  test "late configuration failure restores alternates config and graph bytes":
    let git = findExe("git")
    require git.len > 0
    let scratch = createTempDir("repro-consolidate-rollback-", "")
    defer: removeDir(scratch)
    let origin = scratch / "origin.git"
    discard seedGitOrigin(git, origin, scratch / "seed")
    let ws = seedWorkspace(scratch, fileUrl(origin))
    let env = @[("REPRO_WORKSPACE_CLONES", scratch / "canonical")]
    let bin = reproBinary()
    require runShell(shellCommand(@[bin, "ws", "init", "ra5proj",
      "--workspace-root=" & ws], env)).code == 0
    removeDir(ws / "lib")
    let foreign = scratch / "foreign.git"
    discard requireGit(q(git) & " clone --bare " & q(origin) & " " & q(foreign))
    discard requireGit(q(git) & " -C " & q(foreign) &
      " commit-graph write --reachable --split")
    let leaf = ws / "lib"
    discard requireGit(q(git) & " clone --shared " & q(foreign) & " " & q(leaf))
    discard requireGit(q(git) & " -C " & q(leaf) &
      " -c user.name=Tester -c user.email=tester@example.invalid commit --allow-empty -m leaf")
    discard requireGit(q(git) & " -C " & q(leaf) &
      " commit-graph write --reachable --split=no-merge")
    let graphDir = leaf / ".git/objects/info/commit-graphs"
    require fileExists(graphDir / "commit-graph-chain")
    let graphBefore = treeBytes(graphDir)
    let alt = alternatesFilePath(leaf)
    # Whitespace is valid outside an entry too. Rollback must preserve the
    # original file, rather than reconstructing an equivalent normalized list.
    writeFile(alt, "\n" & readFile(alt) & "\n")
    let alternatesBefore = readFile(alt)
    let configBefore = readFile(leaf / ".git/config")
    let foreignBefore = treeBytes(foreign)
    writeFile(leaf / ".git/config.lock", "held by independent review fixture\n")
    let migrated = runShell(shellCommand(@[bin, "ws", "shared-clones",
      "consolidate", "ra5proj", "--workspace-root=" & ws], env))
    checkpoint migrated.output
    check migrated.code != 0
    # This is a late failure: metadata replacement has already happened by
    # the time the canonical refetch configuration is installed.
    check "could not write remote.repro-pool" in migrated.output
    check readFile(alt) == alternatesBefore
    check readFile(leaf / ".git/config") == configBefore
    check treeBytes(graphDir) == graphBefore
    check treeBytes(foreign) == foreignBefore
    check not dirExists(graphDir & ".repro-consolidate-backup")
    discard requireGit(q(git) & " -C " & q(leaf) & " fsck --full")

  test "health examines linked borrowers of a missing former key in this root":
    let git = findExe("git")
    require git.len > 0
    let scratch = createTempDir("repro-foreign-health-", "")
    defer: removeDir(scratch)
    let origin = scratch / "origin.git"
    discard seedGitOrigin(git, origin, scratch / "seed")
    let ws = seedWorkspace(scratch, fileUrl(origin))
    let cache = scratch / "canonical"
    let env = @[("REPRO_WORKSPACE_CLONES", cache)]
    let bin = reproBinary()
    require runShell(shellCommand(@[bin, "ws", "init", "ra5proj",
      "--workspace-root=" & ws], env)).code == 0
    removeDir(ws / "lib")
    let foreign = cache / "old-organisation/renamed.git"
    createDir(foreign.parentDir)
    discard requireGit(q(git) & " clone --bare " & q(origin) & " " & q(foreign))
    let host = scratch / "host"
    discard requireGit(q(git) & " clone --shared " & q(foreign) & " " & q(host))
    discard requireGit(q(git) & " -C " & q(host) & " remote set-url origin " & q(origin))
    let leaf = ws / "lib"
    discard requireGit(q(git) & " -C " & q(host) &
      " worktree add --detach " & q(leaf) & " HEAD")
    require fileExists(leaf / ".git")
    # Git resolves relative alternate paths against the common object store.
    writeFile(alternatesFilePath(leaf),
      relativePath(foreign / "objects", host / ".git/objects") & "\n")
    let foreignBefore = treeBytes(foreign)
    let observed = runShell(shellCommand(@[bin, "health",
      "--workspace-root=" & ws], env))
    checkpoint observed.output
    check "examined 1 of 1" in observed.output
    check foreign in observed.output
    check treeBytes(foreign) == foreignBefore
    let listed = runShell(shellCommand(@[bin, "ws", "shared-clones", "list",
      "ra5proj", "--workspace-root=" & ws], env))
    check listed.code == 0
    check "migration incomplete" in listed.output
    check foreign in listed.output
    # Retain the leaf's objects so a missing alternate is the only defect.
    discard requireGit(q(git) & " -C " & q(leaf) & " repack -a -d")
    moveDir(foreign, scratch / "unavailable")
    let missing = runShell(shellCommand(@[bin, "health",
      "--workspace-root=" & ws], env))
    checkpoint missing.output
    var row = ""
    for line in missing.output.splitLines():
      if line.startsWith("shared-clone-leaves"):
        row = line
    check "examined 1 of 1" in row
    check "warn" in row
    check foreign in row
    check "error:" in row or "warning:" in row

  test "relative and symlink canonical alternates keep canonical health handling":
    let git = findExe("git")
    require git.len > 0
    let scratch = createTempDir("repro-canonical-alternates-", "")
    defer: removeDir(scratch)
    let origin = scratch / "origin.git"
    discard seedGitOrigin(git, origin, scratch / "seed")
    let ws = seedWorkspace(scratch, fileUrl(origin))
    let cache = scratch / "canonical"
    let env = @[("REPRO_WORKSPACE_CLONES", cache)]
    let bin = reproBinary()
    require runShell(shellCommand(@[bin, "ws", "init", "ra5proj",
      "--workspace-root=" & ws], env)).code == 0
    let listing = runShell(shellCommand(@[bin, "ws", "shared-clones", "list",
      "ra5proj", "--workspace-root=" & ws, "--json"], env))
    require listing.code == 0
    let canonical = parseJson(listing.output)["repos"][0]["sharedBarePath"].getStr()
    let leaf = ws / "lib"
    writeFile(alternatesFilePath(leaf),
      relativePath(canonical / "objects", leaf / ".git/objects") & "\n")
    # Ref tips are present, so fsck alone misses the broken promisor chain.
    # Report mode must retain the existing canonical detector's on-touch repair.
    discard requireGit(q(git) & " -C " & q(canonical) &
      " config extensions.partialClone origin")
    discard requireGit(q(git) & " -C " & q(leaf) &
      " config --remove-section remote.repro-pool")
    let health = runShell(shellCommand(@[bin, "health",
      "--workspace-root=" & ws], env))
    checkpoint health.output
    check "lacked a working refetch chain" in health.output
    check "foreign pool(s)" notin health.output
    check requireGit(q(git) & " -C " & q(leaf) &
      " config remote.repro-pool.url").strip() == poolFileUrl(canonical)
    check borrowsFromPool(leaf, canonical)

    # A canonical store can be reached through a root symlink, just as Darwin
    # exposes /var through /private/var. Identity, rather than spelling, decides
    # whether an actual foreign pool remains to migrate.
    let realCache = scratch / "real-cache"
    moveDir(cache, realCache)
    createSymlink(realCache, cache)
    writeFile(alternatesFilePath(leaf), expandFilename(canonical / "objects") & "\n")
    check borrowsFromPool(leaf, canonical)
    check foreignAlternates(leaf, canonical).len == 0
    let aliased = runShell(shellCommand(@[bin, "ws", "shared-clones", "list",
      "ra5proj", "--workspace-root=" & ws, "--json"], env))
    require aliased.code == 0
    let report = parseJson(aliased.output)
    check report["repos"][0]["wired"].getBool()
    check "migration incomplete" notin report["repos"][0]["diagnostic"].getStr()
    let after = runShell(shellCommand(@[bin, "health",
      "--workspace-root=" & ws], env))
    checkpoint after.output
    var row = ""
    for line in after.output.splitLines():
      if line.startsWith("shared-clone-leaves"):
        row = line
    check " ok " in row
    check "examined 1 of 1" in row
