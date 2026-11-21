## Clone-object policy integration boundary: real local Git repositories,
## the built CLI, filesystem sentinels, and persisted reports; no mocks.
##
## The matrix exercises init, sync, mainline sync, pull and enable with
## private, none and dissociate policies. It checks resolved commit identity,
## alternates, per-clone reports and an untouched host-pool sentinel. A local
## source borrowing its objects independently falsifies accidental inheritance
## of alternates: source and pools are removed before fsck on the result.
## Bootstrap/cold-init and branch cover independent clone orchestration paths.
## A manifest layer pinned by `revision` in `repro-workspace.toml`
## (Workspace-Settings-Files.md §3 — the per-layer pin that replaced the
## retired bootstrap `[manifest] revision`) must refuse init when its checkout
## cannot be put at, or is not at, the pin, on every attempt, and must land
## exactly on the pin when it can. Invalid flags must refuse before creating
## workspace state. Git and the CLI are required, so missing prerequisites
## fail rather than weaken coverage.

import std/[algorithm, json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests
import git_actions
import git_tool
import repro_build_engine

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
  "\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib.toml\",\n]\n"

const libFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
mainline = "main"
"""

proc seedWorkspace(scratch, slug, libUrl: string): string =
  let workspaceRoot = scratch / ("ws-" & slug)
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "ra5proj.toml", projectToml(libUrl))
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragmentToml)
  workspaceRoot

suite "workspace clone object policy":
  test "private and standalone policies isolate objects without changing revisions":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let scratch = createTempDir("repro-clone-policy-", "")
    defer: removeDir(scratch)
    let reproBin = reproBinary()
    let origin = scratch / "origin.git"
    let tip = seedGitOrigin(gitBin, origin, scratch / "seed")
    let hostPool = scratch / "host-pool"
    createDir(hostPool)
    writeFile(hostPool / "sentinel", "unchanged")
    let privatePool = scratch / "private-pool"
    for verb in ["init", "sync", "mainline", "pull", "enable"]:
      for policy in ["none", "dissociate", "private=" & privatePool]:
        let ws = seedWorkspace(scratch, verb & "-" & $policy.len & "-" & policy[
            0..1], fileUrl(origin))
        let report = scratch / (verb & "-" & $policy.len & ".json")
        var argv = @[reproBin, "workspace"]
        if verb == "mainline": argv.add(@["sync", "--mainline"])
        else: argv.add(verb)
        argv.add(@["ra5proj", "--workspace-root=" & ws,
          "--clone-objects=" & policy, "--write-report=" & report])
        if verb in ["sync", "mainline", "enable"]: argv.add("--jobs=1")
        let res = runShell(shellCommand(argv, @[("REPRO_WORKSPACE_CLONES", hostPool)]))
        checkpoint(verb & " " & policy & "\n" & res.output)
        require res.code == 0
        let leaf = ws / "lib"
        check requireGit(q(gitBin) & " -C " & q(leaf) &
            " rev-parse HEAD").strip() == tip
        let alternates = leaf / ".git/objects/info/alternates"
        let expected = if policy == "dissociate": "none" else: policy
        let data = parseJson(readFile(report))
        let entry = if verb == "init": data["cloned"][0] else: data["repos"][0]
        check entry["cloneObjects"].getStr() == expected
        if expected == "none":
          check not fileExists(alternates)
          check entry["clonePoolRoot"].getStr() == ""
        else:
          check fileExists(alternates)
          check privatePool in readFile(alternates)
          check entry["clonePoolRoot"].getStr() == privatePool
        check readFile(hostPool / "sentinel") == "unchanged"
        var hostEntries: seq[string]
        for kind, path in walkDir(hostPool): hostEntries.add(path)
        check hostEntries == @[hostPool / "sentinel"]
    # A standalone clone of a local source that itself borrows objects must
    # copy those objects, rather than inheriting the source's alternates.
    let borrower = scratch / "borrower.git"
    discard requireGit(q(gitBin) & " clone --shared " & q(origin) & " " & q(borrower))
    let ws = seedWorkspace(scratch, "local-borrower", borrower)
    let res = runShell(shellCommand(@[reproBin, "workspace", "init", "ra5proj",
      "--workspace-root=" & ws, "--clone-objects=none"],
      @[("REPRO_WORKSPACE_CLONES", hostPool)]))
    checkpoint(res.output)
    require res.code == 0
    let privateWs = seedWorkspace(scratch, "private-local-borrower", borrower)
    let privateClone = runShell(shellCommand(@[reproBin, "workspace", "init", "ra5proj",
      "--workspace-root=" & privateWs, "--clone-objects=private=" & privatePool],
      @[("REPRO_WORKSPACE_CLONES", hostPool)]))
    checkpoint(privateClone.output)
    require privateClone.code == 0
    removeDir(origin)
    removeDir(borrower)
    # The private pool and leaf must not inherit the local source's old pool.
    check runCmd(q(gitBin) & " -C " & q(privateWs / "lib") & " fsck --full").code == 0
    check privatePool in readFile(privateWs / "lib/.git/objects/info/alternates")
    removeDir(privatePool)
    check not fileExists(ws / "lib/.git/objects/info/alternates")
    check runCmd(q(gitBin) & " -C " & q(ws / "lib") & " fsck --full").code == 0

  test "invalid clone object policies refuse before writing":
    let reproBin = reproBinary()
    let scratch = createTempDir("repro-clone-policy-invalid-", "")
    defer: removeDir(scratch)
    for policy in ["", "private=", "unexpected"]:
      let res = runShell(shellCommand(@[reproBin, "workspace", "init",
        "ra5proj",
        "--workspace-root=" & scratch, "--clone-objects=" & policy]))
      check res.code != 0
      check "clone-objects" in res.output
    check not dirExists(scratch / ".repro")

  test "bootstrap and cold init keep standalone manifests inside destination":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let scratch = createTempDir("repro-policy-bootstrap-", "")
    defer: removeDir(scratch)
    let reproBin = reproBinary()
    let origin = scratch / "origin.git"
    discard seedGitOrigin(gitBin, origin, scratch / "seed")
    let manifest = seedWorkspace(scratch, "manifest", fileUrl(origin))
    discard requireGit(q(gitBin) & " init -b main " & q(manifest))
    discard requireGit(q(gitBin) & " -C " & q(manifest) & " -c user.name=Tester -c user.email=test@example.invalid add -A")
    discard requireGit(q(gitBin) & " -C " & q(manifest) & " -c user.name=Tester -c user.email=test@example.invalid commit -m fixture")
    let root = scratch / "root"
    createDir(root)
    writeFile(root / "repro-workspace.toml", "schema = \"reprobuild.workspace.settings.v1\"\n[records]\nurl = \"" & fileUrl(
        manifest) &
      "\"\nbranch = \"main\"\n[projects]\ndefault = [\"ra5proj\"]\n")
    discard requireGit(q(gitBin) & " init -b main " & q(root))
    discard requireGit(q(gitBin) & " -C " & q(root) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(root) & " -c user.name=Tester -c user.email=test@example.invalid commit -m fixture")
    let dest = scratch / "cold-destination"
    let forbidden = scratch / "host-manifests"
    let report = scratch / "cold.json"
    let res = runShell(shellCommand(@[reproBin, "workspace", "init", fileUrl(
        root), dest,
      "--clone-objects", "none", "--write-report=" & report],
      @[("REPRO_MANIFEST_CACHE", forbidden), ("REPRO_WORKSPACE_CLONES",
          scratch / "host-pool")]))
    checkpoint(res.output)
    require res.code == 0
    check not dirExists(forbidden)
    check not dirExists(scratch / "host-pool")
    let data = parseJson(readFile(report))
    check data["manifestClones"][0]["cloneObjects"].getStr() == "none"
    check data["rootClone"]["cloneObjects"].getStr() == "none"
    check not symlinkExists(dest / ".repro/manifests")
    let privateDest = scratch / "private-destination"
    let privateReport = scratch / "private.json"
    createDir(privateDest)
    let privateInit = runShell(shellCommand(@[reproBin, "workspace", "init",
      "ra5proj",
      "--workspace-root=" & privateDest, "--manifest-url=" & fileUrl(manifest),
      "--manifest-branch=main", "--clone-objects=private=relative-pool",
      "--write-report=" & privateReport], @[("REPRO_MANIFEST_CACHE", forbidden),
      ("REPRO_WORKSPACE_CLONES", scratch / "host-pool")]), cwd = scratch)
    checkpoint(privateInit.output)
    require privateInit.code == 0
    check not dirExists(forbidden)
    check not dirExists(scratch / "host-pool")
    let privateData = parseJson(readFile(privateReport))
    check privateData["manifestClones"][0]["cloneObjects"].getStr() ==
      "private=" & expandFilename(scratch) / "relative-pool"
    check privateData["cloned"][0]["clonePoolRoot"].getStr() == expandFilename(scratch) / "relative-pool"
    # A manifest layer pinned by `revision` (the settings mechanism that
    # replaced the bootstrap `[manifest] revision`). The record store gives
    # init its manifests; the layer is a second, pinned view of them.
    let refused = scratch / "untrusted-destination"
    createDir(refused)
    proc writePinnedLayer(pin: string) =
      writeFile(refused / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n[records]\nurl = \"" &
        fileUrl(manifest) & "\"\nbranch = \"main\"\n\n[[manifest]]\nurl = \"" &
        fileUrl(manifest) & "\"\nvisibility = \"public\"\nrevision = \"" & pin &
        "\"\n")
    proc layerCheckouts(): seq[string] =
      for kind, path in walkDir(refused / ".repro"):
        if kind == pcDir and path.lastPathPart.startsWith("manifests-"):
          result.add(path)
    proc initPinned(): CmdResult =
      runShell(shellCommand(@[reproBin, "workspace", "init", "ra5proj",
        "--workspace-root=" & refused, "--clone-objects=none"]))
    # 1. A pin the source cannot resolve refuses, and a failed attempt must
    #    not leave a layer checkout a retry accepts.
    writePinnedLayer(repeat("0", 40))
    for attempt in 0 .. 1:
      let bad = initPinned()
      checkpoint(bad.output)
      check bad.code != 0
      check fileUrl(manifest) in bad.output
      check layerCheckouts().len == 0
    # 2. A pin the source resolves is where the layer lands.
    let firstPin = requireGit(q(gitBin) & " -C " & q(manifest) &
      " rev-parse HEAD").strip()
    writePinnedLayer(firstPin)
    let good = initPinned()
    checkpoint(good.output)
    check good.code == 0
    let pinnedCheckouts = layerCheckouts()
    check pinnedCheckouts.len == 1
    if pinnedCheckouts.len == 1:
      check requireGit(q(gitBin) & " -C " & q(pinnedCheckouts[0]) &
        " rev-parse HEAD").strip() == firstPin
    # 3. Moving the pin past the existing checkout refuses on every attempt:
    #    the checkout is verified against the pin each time, never accepted
    #    because it exists.
    writeFile(manifest / "PIN-MOVED", "second manifest commit\n")
    discard requireGit(q(gitBin) & " -C " & q(manifest) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(manifest) &
      " -c user.name=Tester -c user.email=test@example.invalid commit -m moved")
    let secondPin = requireGit(q(gitBin) & " -C " & q(manifest) &
      " rev-parse HEAD").strip()
    writePinnedLayer(secondPin)
    for attempt in 0 .. 1:
      let moved = initPinned()
      checkpoint(moved.output)
      check moved.code != 0
      check "is not at its pinned revision" in moved.output
      check secondPin in moved.output
    removeDir(root)
    removeDir(manifest)
    removeDir(origin)
    check fileExists(dest / ".repro/manifests/projects/ra5proj.toml")
    for path in [dest, dest / ".repro/manifests", dest / "lib"]:
      check not fileExists(path / ".git/objects/info/alternates")
      check runCmd(q(gitBin) & " -C " & q(path) & " fsck --full").code == 0

  test "branch forwards standalone and private policy and reports it":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let scratch = createTempDir("repro-policy-branch-", "")
    defer: removeDir(scratch)
    let reproBin = reproBinary()
    let origin = scratch / "origin.git"
    discard seedGitOrigin(gitBin, origin, scratch / "seed")
    let source = seedWorkspace(scratch, "source", fileUrl(origin))
    writeFile(source / ".gitignore", ".repro/\nlib/\n")
    discard requireGit(q(gitBin) & " init -b main " & q(source))
    discard requireGit(q(gitBin) & " -C " & q(source) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(source) & " -c user.name=Tester -c user.email=test@example.invalid commit -m fixture")
    let moduleSource = scratch / "module-borrower"
    discard requireGit(q(gitBin) & " clone --shared " & q(origin) & " " & q(moduleSource))
    discard requireGit(q(gitBin) & " -C " & q(source) &
      " -c protocol.file.allow=always submodule add " & q(moduleSource) & " framework")
    discard requireGit(q(gitBin) & " -C " & q(source) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(source) &
      " -c user.name=Tester -c user.email=test@example.invalid commit -m submodule")
    let globalConfig = scratch / "file-transport.gitconfig"
    writeFile(globalConfig, "[protocol \"file\"]\nallow = always\n")
    var destinations: seq[string]
    let rootBare = scratch / "root.git"
    discard requireGit(q(gitBin) & " clone --bare " & q(source) & " " & q(rootBare))
    discard requireGit(q(gitBin) & " -C " & q(source) & " remote add origin " &
        q(fileUrl(rootBare)))
    let initialized = runShell(shellCommand(@[reproBin, "workspace", "init",
      "ra5proj",
      "--workspace-root=" & source, "--clone-objects=none"]))
    checkpoint(initialized.output)
    require initialized.code == 0
    writeWorkspaceBranch(source, project = "ra5proj", branch = "main")
    let hostPool = scratch / "forbidden-host"
    let privatePool = scratch / "private-pool"
    for policy in ["none", "private=" & privatePool]:
      let dest = scratch / ("fork-" & $policy.len)
      destinations.add(dest)
      let report = scratch / ("branch-" & $policy.len & ".json")
      let res = runShell(shellCommand(@[reproBin, "branch", dest,
        "--workspace-root=" & source, "--clone-objects=" & policy,
        "--write-report=" & report], @[("REPRO_WORKSPACE_CLONES", hostPool), ("GIT_CONFIG_GLOBAL", globalConfig),
        ("GIT_CONFIG_NOSYSTEM", "1")]))
      checkpoint(res.output)
      require res.code == 0
      check not dirExists(hostPool)
      let data = parseJson(readFile(report))
      var found = false
      var rootFound = false
      for entry in data["repos"]:
        if entry["path"].getStr() == ".":
          rootFound = true
          check entry["cloneObjects"].getStr() == policy
        if entry["path"].getStr() == "lib":
          found = true
          check entry["cloneObjects"].getStr() == policy
      check found
      check rootFound
      if policy == "none":
        check not fileExists(dest / "lib/.git/objects/info/alternates")
      else:
        check privatePool in readFile(dest / "lib/.git/objects/info/alternates")
    removeDir(origin)
    removeDir(moduleSource)
    for dest in destinations:
      let module = dest / "framework"
      let alternates = requireGit(q(gitBin) & " -C " & q(module) &
        " rev-parse --git-path objects/info/alternates").strip()
      check not fileExists(alternates)
      check runShell(shellCommand(@[gitBin, "-C", module, "fsck", "--full"],
        @[("GIT_NO_LAZY_FETCH", "1")])).code == 0

  test "default and explicit shared preserve environment-selected pool":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let scratch = createTempDir("repro-policy-shared-", "")
    defer: removeDir(scratch)
    let origin = scratch / "origin.git"
    discard seedGitOrigin(gitBin, origin, scratch / "seed")
    let pool = scratch / "shared-pool"
    for explicit in [false, true]:
      let ws = seedWorkspace(scratch, $explicit, fileUrl(origin))
      let report = scratch / ($explicit & ".json")
      var argv = @[reproBinary(), "workspace", "init", "ra5proj",
        "--workspace-root=" & ws, "--write-report=" & report]
      if explicit: argv.add("--clone-objects=shared")
      let res = runShell(shellCommand(argv, @[("REPRO_WORKSPACE_CLONES", pool)]))
      checkpoint(res.output)
      require res.code == 0
      check pool in readFile(ws / "lib/.git/objects/info/alternates")
      let data = parseJson(readFile(report))
      check data["cloned"][0]["cloneObjects"].getStr() == "shared"
      check data["cloned"][0]["clonePoolRoot"].getStr() == pool

  test "failed reference clone falls back without inheriting alternates":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let scratch = createTempDir("repro-policy-fallback-", "")
    defer: removeDir(scratch)
    let origin = scratch / "origin.git"
    discard seedGitOrigin(gitBin, origin, scratch / "seed")
    let borrower = scratch / "borrower.git"
    discard requireGit(q(gitBin) & " clone --shared " & q(origin) & " " & q(borrower))
    let invalidRef = scratch / "invalid-reference"
    discard requireGit(q(gitBin) & " clone --depth=1 " & q(fileUrl(origin)) &
      " " & q(invalidRef))
    # Git refuses shallow repositories as references. This real repository
    # passes the payload's presence check but forces Git's reference failure;
    # the control proves the retry executes instead of a successful reference.
    let control = runCmd(q(gitBin) & " clone --reference " & q(invalidRef) & " " &
      q(borrower) & " " & q(scratch / "negative-control"))
    check control.code != 0
    check "reference" in control.output
    let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
    installGitVcsExecutor()
    var action = gitCloneAction("fallback", identity, remoteUrl = borrower,
      repoPath = "leaf", receiptPath = "clone.receipt", revision = "main",
      referencePath = invalidRef, cacheable = false)
    action.cwd = scratch
    var config = defaultBuildEngineConfig(scratch / "engine-cache")
    config.suppressTrace = true
    let outcome = runBuild(graph([action]), config)
    require outcome.results.len == 1
    checkpoint(outcome.results[0].stderr)
    require outcome.results[0].status == asSucceeded
    removeDir(origin)
    removeDir(borrower)
    check not fileExists(scratch / "leaf/.git/objects/info/alternates")
    check runCmd(q(gitBin) & " -C " & q(scratch / "leaf") &
        " fsck --full").code == 0
