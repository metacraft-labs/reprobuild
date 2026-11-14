## ``repro push`` with EXPLICIT ``[locking]`` routes and the default
## ``[records] publish_locks = false``.
##
## Central publication of the record-store checkout (``.repro/manifests``) is
## opt-in. With it off the pre-push gate writes a record into that checkout but
## neither commits nor pushes it, so ``repro push`` must not plan that checkout
## as a backend it has to prove remotely (``pushLockBackendPlans``). A routed
## per-tier backend is a different thing: the gate publishes it whatever
## ``publish_locks`` says, so ``repro push`` keeps planning, verifying and
## publishing it, and refuses honestly when it cannot be reached.
##
## A SINGLE-repo workspace (``app``, with a committed lock) so that only one lock
## record is ever written. The two-repo shape (a second repo routed to the record
## store, pushed before ``app``) trips a different, separately recorded defect in
## the gate's per-repo participation fan-out and is deliberately not exercised
## here.
##
## Cases:
##   A. the explicit route's ROOT IS THE RECORD STORE (``.repro/manifests``):
##      that checkout must drop out of the plan, the push succeeds, and nothing
##      reaches the record store's upstream or its HEAD (it may hold the
##      uncommitted record). Against the pre-fix ``pushLockBackendPlans`` the
##      route's root is planned, final-lock-verification demands remote proof of
##      a record the gate deliberately did not publish, and the push is refused.
##   B. the route points at a DISTINCT team backend with its own bare upstream,
##      and that upstream is removed after its tracking branch is configured: the
##      push is REFUSED and no source ref moves. This proves a routed backend
##      that is not the record store is still planned and verified.
##
## Fixture choices, none of them a mock: real ``git`` repos, real bare remotes
## on the local filesystem, the real managed hooks installed by ``repro hooks
## ensure --vcs`` and the built ``repro`` running every process. The record
## store is a real checkout with a real bare upstream so "nothing was published
## there" is observable on the bare. Layered user/system/VCS-private config is
## pointed at absent files so the host's own routing cannot leak in.
## Skip: ``git`` missing; the built ``repro`` is required (``requireBinary``).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_test_support/recipe_dependencies
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string): string =
  ## ``doAssert`` so a fixture that could not be built never reads as a result.
  let res = run(command)
  doAssert res.code == 0, "command failed: " & command & "\n" & res.output
  res.output

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir /
    "build" / "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc gitIn(gitBin, repo, args: string): string =
  require(q(gitBin) & " -C " & q(repo) & " " & args)

proc identify(gitBin, repo: string) =
  discard gitIn(gitBin, repo, "config user.email tester@example.invalid")
  discard gitIn(gitBin, repo, "config user.name 'Explicit Routes Tester'")

proc seed(gitBin, bare, seedPath, label: string) =
  discard require(q(gitBin) & " init --bare -b main " & q(bare))
  discard require(q(gitBin) & " init -b main " & q(seedPath))
  identify(gitBin, seedPath)
  writeFile(seedPath / "README.md", label & "\n")
  discard gitIn(gitBin, seedPath, "add README.md")
  discard gitIn(gitBin, seedPath, "commit -m seed")
  discard gitIn(gitBin, seedPath, "remote add origin " & q(bare))
  discard gitIn(gitBin, seedPath, "push origin main")

proc clone(gitBin, bare, path: string) =
  discard require(q(gitBin) & " clone " & q(fileUrl(bare)) & " " & q(path))
  identify(gitBin, path)

type Fixture = object
  scratch, workspace, manifests, manifestBare, reproBin: string
  app, appBare, teamLocks, teamLocksBare: string

proc repoToml(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\nmainline = \"main\"\n"

proc setup(gitBin, slug: string; routeToRecordStore: bool): Fixture =
  result.scratch = createTempDir("repro-push-explicit-routes-" & slug & "-", "")
  result.workspace = result.scratch / "workspace"
  result.manifests = result.workspace / ".repro" / "manifests"
  result.manifestBare = result.scratch / "manifest.git"
  result.appBare = result.scratch / "app.git"
  result.teamLocks = result.scratch / "team-locks"
  result.teamLocksBare = result.scratch / "team-locks.git"
  result.reproBin = reproBinary()
  seed(gitBin, result.appBare, result.scratch / "seed-app", "app")
  createDir(result.manifests / "projects")
  createDir(result.manifests / "repos")
  writeFile(result.manifests / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" & fileUrl(result.appBare) &
      "\"\n\n" &
    "includes = [\"repos/app.toml\"]\n")
  writeFile(result.manifests / "repos" / "app.toml",
    repoToml("app", "app-origin"))
  discard require(q(gitBin) & " init --bare -b main " & q(result.manifestBare))
  discard require(q(gitBin) & " init -b main " & q(result.manifests))
  identify(gitBin, result.manifests)
  discard gitIn(gitBin, result.manifests, "add projects repos")
  discard gitIn(gitBin, result.manifests, "commit -m 'seed manifest'")
  discard gitIn(gitBin, result.manifests,
    "remote add origin " & q(result.manifestBare))
  discard gitIn(gitBin, result.manifests, "push -u origin main")
  clone(gitBin, result.appBare, result.workspace / "app")
  result.app = result.workspace / "app"
  discard declareDependenciesInRecipes(gitBin, result.reproBin,
    result.workspace, [("app", newSeq[string]())])
  writeWorkspaceBranch(result.workspace, project = "app", branch = "main")
  # The distinct team backend: tracks its own bare so a publish really pushes.
  discard require(q(gitBin) & " init --bare -b main " & q(result.teamLocksBare))
  discard require(q(gitBin) & " init -b main " & q(result.teamLocks))
  identify(gitBin, result.teamLocks)
  writeFile(result.teamLocks / "README.md", "team locks\n")
  discard gitIn(gitBin, result.teamLocks, "add README.md")
  discard gitIn(gitBin, result.teamLocks, "commit -m seed")
  discard gitIn(gitBin, result.teamLocks,
    "remote add origin " & q(result.teamLocksBare))
  discard gitIn(gitBin, result.teamLocks, "push -u origin main")
  # ``publish_locks`` is deliberately ABSENT (default off). The one explicit
  # route sends ``app`` to the record store's own root or to the distinct team
  # backend, per the case.
  let routedRoot = if routeToRecordStore: result.manifests else: result.teamLocks
  writeFile(result.workspace / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[records]\nurl = \"" & fileUrl(result.manifestBare) & "\"\n\n" &
    "[locking]\nroute = [\n" &
    "  { visibility = \"team\", backend = \"git-checkout\", path = \"" &
      routedRoot.replace('\\', '/') & "\", repos = [\"app\"] },\n]\n")

proc installHooks(fx: Fixture) =
  for path in [fx.workspace, fx.manifests, fx.teamLocks]:
    let ensured = runShell(shellCommand(@[fx.reproBin, "hooks", "ensure",
      "--vcs", "--workspace-root=" & path]))
    doAssert ensured.code == 0, "hooks ensure failed for " & path & ":\n" &
      ensured.output

proc commitChange(fx: Fixture; gitBin, path, label: string): string =
  ## A commit that re-pins the repo's committed lock first, as the managed
  ## pre-commit hook would, so the state is one a developer can reach.
  writeFile(path / (label & ".txt"), label & "\n")
  discard gitIn(gitBin, path, "add " & q(label & ".txt"))
  if fileExists(path / "repro.lock"):
    let refreshed = refreshCommittedLock(fx.reproBin, path)
    doAssert refreshed.code == 0, refreshed.output
    discard gitIn(gitBin, path, "add repro.lock")
  discard gitIn(gitBin, path, "-c commit.gpgsign=false commit -m " & q(label))
  gitIn(gitBin, path, "rev-parse HEAD").strip()

proc invokePush(fx: Fixture): tuple[code: int; output: string] =
  runShell(shellCommand(@[fx.reproBin, "push", "--write-report", "app",
    "--no-certify", "--workspace-root=" & fx.workspace,
    "--current-repo=" & fx.app, "--json"],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

proc remoteHead(gitBin, bare: string): string =
  gitIn(gitBin, bare, "rev-parse refs/heads/main").strip()

proc bareHasLock(gitBin, bare, repo, sha: string): bool =
  run(q(gitBin) & " -C " & q(bare) & " cat-file -e " &
    q("refs/heads/main:locks/app/" & repo & "/" & sha & ".toml")).code == 0

suite "repro push: explicit routes with publish_locks off":
  setup:
    # Keep every layered config read inside the fixture (restored in teardown).
    let priorEnv = [getEnv("REPROBUILD_SYSTEM_CONFIG"),
      getEnv("REPROBUILD_USER_CONFIG"), getEnv("REPROBUILD_VCS_PRIVATE_CONFIG")]
    let hadEnv = [existsEnv("REPROBUILD_SYSTEM_CONFIG"),
      existsEnv("REPROBUILD_USER_CONFIG"),
      existsEnv("REPROBUILD_VCS_PRIVATE_CONFIG")]
  teardown:
    for (index, name) in [(0, "REPROBUILD_SYSTEM_CONFIG"),
        (1, "REPROBUILD_USER_CONFIG"), (2, "REPROBUILD_VCS_PRIVATE_CONFIG")]:
      if hadEnv[index]: putEnv(name, priorEnv[index]) else: delEnv(name)

  test "A: a route onto the record store itself is not planned, the push succeeds":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real repos, hooks and bare remotes")
    else:
      let fx = setup(gitBin, "record-store", routeToRecordStore = true)
      defer: removeDir(fx.scratch)
      putEnv("REPROBUILD_SYSTEM_CONFIG", fx.scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", fx.scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", fx.scratch / "no-vcs.toml")
      installHooks(fx)
      let appSha = commitChange(fx, gitBin, fx.app, "app-change")
      let manifestBefore = remoteHead(gitBin, fx.manifestBare)
      let manifestLocalBefore = gitIn(gitBin, fx.manifests, "rev-parse HEAD")
      let pushed = invokePush(fx)
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      check "not remotely proven" notin pushed.output
      let r = parseFile(fx.workspace / ".repro" / "build" / "reports" /
        "push-report.json")
      check r["stoppedStage"].getStr() == ""
      check remoteHead(gitBin, fx.appBare) == appSha
      # Nothing was published to, or committed in, the record store.
      check remoteHead(gitBin, fx.manifestBare) == manifestBefore
      check gitIn(gitBin, fx.manifests, "rev-parse HEAD") == manifestLocalBefore
      check not bareHasLock(gitBin, fx.manifestBare, "app", appSha)

  test "B: an unreachable distinct team route still refuses the push":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs real repos, hooks and bare remotes")
    else:
      let fx = setup(gitBin, "unreachable", routeToRecordStore = false)
      defer: removeDir(fx.scratch)
      putEnv("REPROBUILD_SYSTEM_CONFIG", fx.scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", fx.scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", fx.scratch / "no-vcs.toml")
      installHooks(fx)
      discard commitChange(fx, gitBin, fx.app, "app-change")
      let appBefore = remoteHead(gitBin, fx.appBare)
      let manifestBefore = remoteHead(gitBin, fx.manifestBare)
      # Its tracking branch stays configured locally; the upstream is gone.
      removeDir(fx.teamLocksBare)
      let refused = invokePush(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check remoteHead(gitBin, fx.appBare) == appBefore
      check remoteHead(gitBin, fx.manifestBare) == manifestBefore
      let r = parseFile(fx.workspace / ".repro" / "build" / "reports" /
        "push-report.json")
      check r["stoppedStage"].getStr().len > 0
