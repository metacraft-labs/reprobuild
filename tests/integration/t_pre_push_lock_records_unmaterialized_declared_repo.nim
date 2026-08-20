## A DECLARED but never-materialized repo must not block a push, and the
## lock must SAY that it did not pin it.
##
## Workspace-Manifests.md §"Declared repos with no on-disk checkout" and
## Workspace-And-Develop-Mode.md §"Membership and Materialization".
##
## The defect this pins: ``executeWorkspaceLock`` gated three different
## properties — "the checkout exists", "it answers rev-parse", "it is
## clean" — on one ``dirtyScopeNames`` flag. An EMPTY scope means "no
## scope information, consider every repo" (``prePushScope``'s documented
## fallback for a ``--current-repo`` that resolves to neither a declared
## repo nor a manifest layer — e.g. a workspace-framework repo living at
## the workspace root beside ``.repro/manifests``). Under that fallback the
## lock stage demanded that EVERY declared repo be on disk, so the pushed
## commit was refused with
##
##   repro check: lock update FAILED: repo '<name>' has no on-disk checkout
##   at '<path>'; run `repro workspace init` or `repro workspace sync` first
##
## once per absent repo. In a multi-project workspace the declared set is
## the union of every active project, so publishing a one-line manifest
## commit required materializing repos from projects this workspace never
## builds — while the gate's OWN cleanliness/publication stage had already
## passed the very same absent checkout as vacuously satisfied.
##
## Three cases, because a narrower gate could otherwise be vacuously
## "fixed" by being disabled:
##
##   1. the push SUCCEEDS end to end — a real ``git push`` through the
##      really-installed managed pre-push hook — with a declared repo that
##      was never cloned;
##   2. the lock it wrote pins the two materialized repos AT THEIR OWN,
##      MUTUALLY DISTINCT HEAD SHAs and NAMES the unmaterialized one under
##      ``[extensions] unmaterialized_repos``. Distinctness is load-bearing:
##      a fixture whose repos share a SHA makes "pinned the right revision"
##      unfalsifiable;
##   3. a DIRTY materialized sibling still refuses, naming it — the lock
##      stage stopped requiring existence, not cleanliness.
##
## No mocks: real git repos on the real filesystem, real ``build/bin/repro``,
## and in case 1 a real ``git push`` driven by git itself.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc configureIdentity(gitBin, path: string) =
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"Unmaterialized Repo Tester\"")

proc seedOrigin(gitBin, originPath, seedPath, marker: string) =
  ## A bare origin plus one published commit. ``marker`` is written into
  ## the seed commit so each repo's HEAD SHA is DIFFERENT from every
  ## other's — see the header: identical SHAs would make case 2 vacuous.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
  configureIdentity(gitBin, seedPath)
  writeFile(seedPath / "README.md", marker & "\n")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " commit -m " & q("seed " & marker))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")

proc fragmentToml(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\nname = \"" & name & "\"\npath = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\nrevision = \"main\"\n"

proc projectToml(alphaUrl, betaUrl, gammaUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"ws\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
  "[[remote]]\nname = \"alpha-origin\"\nfetch = \"" & alphaUrl & "\"\n\n" &
  "[[remote]]\nname = \"beta-origin\"\nfetch = \"" & betaUrl & "\"\n\n" &
  "[[remote]]\nname = \"gamma-origin\"\nfetch = \"" & gammaUrl & "\"\n\n" &
  "includes = [\n  \"repos/alpha.toml\",\n  \"repos/beta.toml\",\n" &
  "  \"repos/gamma.toml\",\n]\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc buildFixture(gitBin, slug: string): Fixture =
  ## The production topology this defect was reported from: membership
  ## lives in ``.repro/manifests`` (its own git checkout), and the
  ## WORKSPACE ROOT is a SEPARATE git repo — a workspace-framework repo
  ## that is neither a declared project repo, nor the membership repo, nor
  ## a ``[[manifest]]`` layer. Pushing it is exactly the "no scope
  ## information" case whose whole-workspace fallback triggered the bug.
  ##
  ## alpha and beta are cloned. gamma is DECLARED and never cloned.
  result.scratch = createTempDir("repro-unmaterialized-" & slug & "-", "")
  result.reproBin = reproBinary()

  let alphaOrigin = result.scratch / "origin-alpha.git"
  let betaOrigin = result.scratch / "origin-beta.git"
  let gammaOrigin = result.scratch / "origin-gamma.git"
  seedOrigin(gitBin, alphaOrigin, result.scratch / "seed-alpha", "alpha")
  seedOrigin(gitBin, betaOrigin, result.scratch / "seed-beta", "beta")
  seedOrigin(gitBin, gammaOrigin, result.scratch / "seed-gamma", "gamma")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)

  # ---- membership repo at .repro/manifests -------------------------------
  let manifests = workspaceRoot / ".repro" / "manifests"
  createDir(manifests / "projects")
  createDir(manifests / "repos")
  writeFile(manifests / "projects" / "ws.toml",
    projectToml(fileUrl(alphaOrigin), fileUrl(betaOrigin),
      fileUrl(gammaOrigin)))
  writeFile(manifests / "repos" / "alpha.toml",
    fragmentToml("alpha", "alpha-origin"))
  writeFile(manifests / "repos" / "beta.toml",
    fragmentToml("beta", "beta-origin"))
  writeFile(manifests / "repos" / "gamma.toml",
    fragmentToml("gamma", "gamma-origin"))
  let manifestsOrigin = result.scratch / "origin-manifests.git"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(manifestsOrigin))
  discard requireGit(q(gitBin) & " init -b main " & q(manifests))
  configureIdentity(gitBin, manifests)
  discard requireGit(q(gitBin) & " -C " & q(manifests) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(manifests) &
    " commit -m \"seed membership\"")
  discard requireGit(q(gitBin) & " -C " & q(manifests) & " remote add origin " &
    q(manifestsOrigin))
  discard requireGit(q(gitBin) & " -C " & q(manifests) & " push origin main")

  writeFile(workspaceRoot / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"ws\"\nprojects = [\"ws\"]\nbranch = \"main\"\n")

  # ---- the workspace-root repo -------------------------------------------
  let workspaceOrigin = result.scratch / "origin-workspace.git"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(workspaceOrigin))
  discard requireGit(q(gitBin) & " init -b main " & q(workspaceRoot))
  configureIdentity(gitBin, workspaceRoot)
  writeFile(workspaceRoot / ".gitignore",
    "/alpha/\n/beta/\n/gamma/\n/.repro/\n")
  writeFile(workspaceRoot / "README.md", "workspace framework repo\n")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m \"seed workspace\"")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " remote add origin " & q(workspaceOrigin))
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " push -u origin main")

  # ---- materialize alpha and beta only -----------------------------------
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(alphaOrigin)) & " " &
    q(workspaceRoot / "alpha"))
  configureIdentity(gitBin, workspaceRoot / "alpha")
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(betaOrigin)) & " " &
    q(workspaceRoot / "beta"))
  configureIdentity(gitBin, workspaceRoot / "beta")
  # gamma: DECLARED, deliberately NOT cloned.
  doAssert not dirExists(workspaceRoot / "gamma")

  result.workspaceRoot = workspaceRoot

proc commitWorkspaceEdit(gitBin, workspaceRoot: string) =
  writeFile(workspaceRoot / "README.md",
    readFile(workspaceRoot / "README.md") & "one more line\n")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m \"workspace edit\"")

proc headSha(gitBin, path: string): string =
  requireGit(q(gitBin) & " -C " & q(path) & " rev-parse HEAD").strip()

proc gateResult(fx: Fixture): tuple[code: int; output: string] =
  ## ``--write-report`` rather than parsing stdout: the gate also writes
  ## progress/publish lines to stderr, and ``execCmdEx`` folds stderr into
  ## stdout, so a stdout parse is not reliably JSON.
  runCmd(q(fx.reproBin) & " check --mode=pre-push --write-report" &
    " --workspace-root=" & q(fx.workspaceRoot) &
    " --current-repo=" & q(fx.workspaceRoot))

proc gateReport(fx: Fixture): JsonNode =
  parseJson(readFile(fx.workspaceRoot / ".repro" / "build" / "reports" /
    "check-report.json"))

suite "pre-push lock — declared repo with no on-disk checkout":
  let gitBin = findExe("git")

  test "a real git push succeeds with a declared, never-cloned repo":
    if gitBin.len == 0:
      skip()
    else:
      let fx = buildFixture(gitBin, "push")
      defer: removeDirEventually(fx.scratch)
      commitWorkspaceEdit(gitBin, fx.workspaceRoot)

      # Install the REAL managed hooks on the workspace-root repo, so the
      # assertion below is git's own verdict on a real push, not ours.
      let ensured = runCmd(q(fx.reproBin) & " hooks ensure --vcs" &
        " --workspace-root " & q(fx.workspaceRoot) & " " &
        q(fx.workspaceRoot))
      if ensured.code != 0:
        checkpoint("hooks ensure output: " & ensured.output)
      check ensured.code == 0
      check fileExists(fx.workspaceRoot / ".git" / "hooks" / "pre-push")

      # The managed hook resolves ``${REPROBUILD_REPRO:-repro}``. Bind it
      # to the binary UNDER TEST — a bare ``repro`` on PATH is whatever
      # the host happens to have installed, and this test would then be
      # reporting on someone else's build.
      let pushed = runCmd("env REPROBUILD_REPRO=" & q(fx.reproBin) & " " &
        q(gitBin) & " -C " & q(fx.workspaceRoot) & " push origin main 2>&1")
      if pushed.code != 0:
        checkpoint("push output: " & pushed.output)
      check pushed.code == 0
      # The exact refusal this test exists to remove must be gone.
      check "has no on-disk checkout" notin pushed.output
      # And the push really landed.
      let remoteSha = requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot) &
        " rev-parse origin/main").strip()
      check remoteSha == headSha(gitBin, fx.workspaceRoot)

  test "the lock pins the materialized repos and names the unmaterialized one":
    if gitBin.len == 0:
      skip()
    else:
      let fx = buildFixture(gitBin, "lock")
      defer: removeDirEventually(fx.scratch)
      commitWorkspaceEdit(gitBin, fx.workspaceRoot)

      let alphaSha = headSha(gitBin, fx.workspaceRoot / "alpha")
      let betaSha = headSha(gitBin, fx.workspaceRoot / "beta")
      # The fixture must not be able to pass by accident: two repos with
      # the same SHA make "pinned the sibling" unfalsifiable.
      check alphaSha != betaSha
      check alphaSha.len == 40
      check betaSha.len == 40

      let res = gateResult(fx)
      if res.code != 0:
        checkpoint("gate output: " & res.output)
      check res.code == 0

      let report = gateReport(fx)
      let lockPath = report["lockUpdate"]["lockFilePath"].getStr()
      check lockPath.len > 0
      check fileExists(lockPath)
      let body = readFile(lockPath)

      # Read it back through the STRICT reader — the same one every
      # consumer uses. This also proves the new `[extensions]` table did
      # not make the document unparseable for readers that ignore it.
      let parsed = readLock(lockPath)
      var pinned: seq[string]
      var revisionOf = initTable[string, string]()
      for r in parsed.repo:
        pinned.add(r.name)
        revisionOf[r.name] = r.revision

      # Exactly the two materialized repos are pinned, each at its OWN
      # revision. gamma contributes none — there is none to observe.
      check pinned == @["alpha", "beta"]
      check revisionOf.getOrDefault("alpha") == alphaSha
      check revisionOf.getOrDefault("beta") == betaSha
      check "gamma" notin pinned

      # … but gamma is NOT silently absent: the lock states the omission.
      check isPresent(parsed.extensions)
      check "unmaterialized_repos" in body
      check "name = \"gamma\"" in body
      check "no on-disk checkout" in body
      # The committed document must stay host-independent: no absolute
      # path from whoever happened to run the gate.
      check fx.scratch notin body

      # And the operator is told, on the gate's own output.
      var sawNotice = false
      for notice in report["notices"]:
        if "unmaterialized_repos" in notice.getStr() and
            "gamma" in notice.getStr():
          sawNotice = true
      check sawNotice

  test "a dirty materialized sibling still refuses, naming it":
    if gitBin.len == 0:
      skip()
    else:
      let fx = buildFixture(gitBin, "dirty")
      defer: removeDirEventually(fx.scratch)
      # gamma is still absent; beta is dirty. Dropping the EXISTENCE
      # requirement must not have dropped the CLEANLINESS one.
      writeFile(fx.workspaceRoot / "beta" / "uncommitted.txt", "wip\n")
      commitWorkspaceEdit(gitBin, fx.workspaceRoot)

      let res = gateResult(fx)
      check res.code == 2
      check "beta" in res.output
