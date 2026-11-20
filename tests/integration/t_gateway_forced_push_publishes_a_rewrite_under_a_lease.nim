## A rewrite the client protocol permits is published through the push gateway,
## and only under a lease that bounds what the upstream may discard.
##
## reprobuild-pm ``spec/Push-Gateway-Wiring-And-Policy.md`` §5.3 "Forced
## updates: the forward carries a lease", and ``spec/CLI/gateway.md`` §"The
## forward". Recorded as reprobuild-pm
## ``issues/2026-11-12-forced-updates-the-forward-is-unspecified-and-the-shipped-forward-cannot-publish-a-rewrite.md``:
## the gateway accepted a ``git push --force`` of a rebased feature branch and
## then forwarded it as a plain ``<new>:<ref>``, which the upstream refused as
## non-fast-forward, so the rewrite could never be published.
##
## Cases (each against real bares, the real installed hooks and the real
## ``repro`` binary; no network):
##
##   - ``forced_push_of_a_feature_branch_reaches_the_upstream`` -- push a
##     feature branch through the gateway, rewrite it, ``git push --force``.
##     The push exits 0 and the upstream holds the rewritten tip.
##   - ``stale_lease_refuses_and_the_teammates_commit_survives`` -- a teammate
##     advances the branch upstream between the two pushes. The forced push is
##     refused, the upstream still holds the teammate's commit, the gateway's
##     ref does not move, and the diagnostic names the remedy. This is the
##     case that catches a fix which merely adds ``+`` to the refspec: git 2.43
##     lets a ``+`` refspec override a stale ``--force-with-lease``.
##   - ``forced_deletion_is_leased_too`` -- deleting the branch through the
##     gateway after a teammate advanced it upstream is refused, and the
##     teammate's commit survives (a plain ``:<ref>`` would delete it).
##   - ``old_that_is_not_the_gateways_ref_is_refused`` -- a crafted push whose
##     ``<old>`` names the upstream's tip rather than the gateway's ref is
##     refused before anything is forwarded.
##   - ``forced_update_of_a_declared_role_branch_is_refused`` -- the gateway's
##     config names a workspace whose manifest declares ``main`` as the
##     mainline; ``git push --no-verify --force`` of a rewritten ``main`` is
##     refused at the gateway and the upstream is untouched, while a forced
##     push of a feature branch in the same gateway still publishes.
##   - ``unresolvable_role_refuses_a_forced_update`` -- a gateway whose config
##     names no workspace refuses a forced update (fail closed), and says why.
##   - ``workspace_root_repository_takes_its_roles_from_the_settings`` -- the
##     workspace root repository is no project member; its feature branch is
##     rewritten and deleted through its gateway, and its mainline, declared
##     in the settings file, is refused.
##   - ``reset_refs_refuses_a_pool_without_a_fetch_refspec`` and
##     ``stale_lease_remedy_integrate_reset_push_publishes`` -- the remedy a
##     stale lease names, at the procedure: a pre-PG-0 pool is refused, and
##     integrate, reset, push publishes.
##   - ``rewire_reset_refs_from_the_command_line_completes_the_remedy`` -- the
##     same remedy through ``repro workspace shared-clones rewire
##     --reset-refs``.
##
## The scratch directories are named by neutral slugs, because git prints
## their paths in every push report: a check for a bare word such as "stale"
## would otherwise hold whatever the gateway said.
##
## Test doubles: none.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_cli_support
import shared_clones

proc q(value: string): string = quoteShell(value)

proc sh(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output.strip())

proc must(command: string): string =
  let res = sh(command)
  if res.code != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
  doAssert res.code == 0, "fixture command failed: " & command
  res.output

proc reproBinary(): string =
  let root = currentSourcePath().parentDir.parentDir.parentDir
  requireBinary(root / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Fixture = object
  gitBin, scratch, reproBin, upstream, gateway, clone, other, workspace: string

proc gitC(fx: Fixture; repo: string; args: string): string =
  must(q(fx.gitBin) & " -C " & q(repo) & " " & args)

proc tip(fx: Fixture; repo, refName: string): string =
  sh(q(fx.gitBin) & " -C " & q(repo) & " rev-parse --verify -q " &
    refName).output

proc newClone(fx: Fixture; dest: string) =
  discard must(q(fx.gitBin) & " clone -q " & q(fileUrl(fx.upstream)) & " " &
    q(dest))
  discard gitC(fx, dest, "config user.email t@example.invalid")
  discard gitC(fx, dest, "config user.name T")

proc commit(fx: Fixture; repo, body: string): string =
  writeFile(repo / "f.txt", body)
  discard gitC(fx, repo, "add f.txt")
  discard gitC(fx, repo, "commit -q -m " & q(body))
  gitC(fx, repo, "rev-parse HEAD")

proc writeRoleWorkspace(fx: Fixture) =
  ## A workspace whose manifest declares ``main`` as the mainline of repo
  ## ``app`` in project ``proj`` (Workspace-Branch-Roles.md §5).
  ## The layout is `t_force_push_of_any_declared_role_is_refused`'s.
  createDir(fx.workspace / ".repro")
  createDir(fx.workspace / "projects")
  createDir(fx.workspace / "repos")
  writeFile(fx.workspace / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n" &
    "[workspace]\nproject = \"proj\"\nbranch = \"main\"\n")
  writeFile(fx.workspace / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[workspace]\nmainline = \"main\"\n")
  writeFile(fx.workspace / "projects" / "proj.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"proj\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" &
      fx.upstream.replace('\\', '/') & "\"\n\n" &
    "includes = [\"repos/app.toml\"]\n")
  writeFile(fx.workspace / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\nremote = \"app-origin\"\n" &
    "mainline = \"main\"\n")

proc setup(gitBin, slug: string; roles = true; rootRepo = false;
           cache = ""): Fixture =
  ## ``slug`` names the scratch directory. git prints that path in every
  ## push report, so no assertion below looks for a bare word a slug could
  ## supply. With ``cache``, the checkout is the workspace's ``app`` and the
  ## gateway sits where ``ensureGatewayForRepo`` puts this workspace's
  ## gateway for the upstream, so ``shared-clones rewire`` finds both.
  result.gitBin = gitBin
  result.scratch = createTempDir("repro-pg-lease-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.upstream = result.scratch / "upstream.git"
  result.workspace = result.scratch / "ws"
  if cache.len > 0:
    result.clone = result.workspace / "app"
    result.gateway = gatewayBarePathFor(cache, "ws",
      fileUrl(result.upstream))
  else:
    result.clone = result.scratch / "clone"
    result.gateway = result.scratch / "gateway.git"
  result.other = result.scratch / "other"
  discard must(q(gitBin) & " init -q --bare -b main " & q(result.upstream))
  let seed = result.scratch / "seed"
  discard must(q(gitBin) & " init -q -b main " & q(seed))
  discard must(q(gitBin) & " -C " & q(seed) &
    " config user.email t@example.invalid")
  discard must(q(gitBin) & " -C " & q(seed) & " config user.name T")
  writeFile(seed / "f.txt", "seed\n")
  discard must(q(gitBin) & " -C " & q(seed) & " add f.txt")
  discard must(q(gitBin) & " -C " & q(seed) & " commit -q -m seed")
  discard must(q(gitBin) & " -C " & q(seed) & " push -q " &
    q(result.upstream) & " main")
  if cache.len > 0: createDir(result.workspace)
  newClone(result, result.clone)
  newClone(result, result.other)
  var cfg = GatewayConfig()
  if roles:
    writeRoleWorkspace(result)
    cfg.workspaceRoot = result.workspace
    cfg.project = "proj"
    if rootRepo:
      # The workspace root repository: no member, roles from the settings.
      cfg.repo = "ws"
      cfg.repoIsWorkspaceRoot = true
    else:
      cfg.repo = "app"
  let wired = wirePushGateway(gitBin, result.clone, result.gateway,
    fileUrl(result.upstream), cfg)
  doAssert wired.ok, wired.diagnostic

proc pushThroughGateway(fx: Fixture; args: varargs[string]):
    tuple[code: int; output: string] =
  var argv = @[fx.gitBin, "-C", fx.clone, "push", "--no-verify", "origin"]
  for r in args:
    argv.add(r)
  runShell(shellCommand(argv,
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

proc publishFeature(fx: Fixture): string =
  ## Push a two-commit ``feature`` branch through the gateway; return its tip.
  discard gitC(fx, fx.clone, "checkout -q -b feature")
  discard commit(fx, fx.clone, "feature-1")
  result = commit(fx, fx.clone, "feature-2")
  let p = pushThroughGateway(fx, "feature")
  checkpoint("first push: " & p.output)
  doAssert p.code == 0, "the first push of feature failed: " & p.output
  doAssert tip(fx, fx.upstream, "refs/heads/feature") == result

proc rewriteFeature(fx: Fixture): string =
  ## Squash the feature branch's two commits into one: a rewrite whose old
  ## tip is not an ancestor of the new one.
  discard gitC(fx, fx.clone, "reset -q --soft HEAD~2")
  discard gitC(fx, fx.clone, "commit -q -m squashed")
  gitC(fx, fx.clone, "rev-parse HEAD")

proc teammateAdvancesFeature(fx: Fixture): string =
  discard gitC(fx, fx.other, "fetch -q origin")
  discard gitC(fx, fx.other, "checkout -q -b feature origin/feature")
  result = commit(fx, fx.other, "teammate")
  discard gitC(fx, fx.other, "push -q origin feature")

suite "push gateway forced updates":

  test "forced_push_of_a_feature_branch_reaches_the_upstream":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c1")
      defer: removeDir(fx.scratch)
      let before = publishFeature(fx)
      let rewritten = rewriteFeature(fx)
      check rewritten != before
      let p = pushThroughGateway(fx, "--force", "feature")
      checkpoint("forced push: " & p.output)
      check p.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") == rewritten
      check tip(fx, fx.gateway, "refs/heads/feature") == rewritten

  test "stale_lease_refuses_and_the_teammates_commit_survives":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c2")
      defer: removeDir(fx.scratch)
      let before = publishFeature(fx)
      let theirs = teammateAdvancesFeature(fx)
      discard rewriteFeature(fx)
      let p = pushThroughGateway(fx, "--force", "feature")
      checkpoint("forced push: " & p.output)
      check p.code != 0
      check tip(fx, fx.upstream, "refs/heads/feature") == theirs
      check tip(fx, fx.gateway, "refs/heads/feature") == before
      # The diagnostic lists what the forced push would discard and names
      # the remedy in order: integrate, reset the gateway's refs, push.
      check "stale lease:" in p.output
      # The listed commits, not only the header's full object name.
      check (theirs[0 ..< 7] & " teammate") in p.output
      check "rewire --reset-refs" in p.output

  test "forced_deletion_is_leased_too":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c3")
      defer: removeDir(fx.scratch)
      discard publishFeature(fx)
      let theirs = teammateAdvancesFeature(fx)
      let p = pushThroughGateway(fx, ":feature")
      checkpoint("deletion: " & p.output)
      check p.code != 0
      check "stale lease:" in p.output
      check (theirs[0 ..< 7] & " teammate") in p.output
      check tip(fx, fx.upstream, "refs/heads/feature") == theirs
      # With the lease current the deletion is published.
      discard gitC(fx, fx.other, "push -q origin " & q(tip(fx, fx.gateway,
        "refs/heads/feature")) & ":refs/heads/feature --force")
      let ok = pushThroughGateway(fx, ":feature")
      checkpoint("deletion with a current lease: " & ok.output)
      check ok.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") == ""

  test "old_that_is_not_the_gateways_ref_is_refused":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c4")
      defer: removeDir(fx.scratch)
      let before = publishFeature(fx)
      let theirs = teammateAdvancesFeature(fx)
      let rewritten = rewriteFeature(fx)
      # Drive the gateway's pre-receive directly with a crafted line whose
      # <old> is the upstream's tip, as a non-stock client could send it.
      let line = theirs & " " & rewritten & " refs/heads/feature\n"
      let input = fx.scratch / "crafted.txt"
      writeFile(input, line)
      # The rewritten commit must be readable to the gateway, as it would be
      # from the receive quarantine.
      discard gitC(fx, fx.gateway, "fetch -q " & q(fx.clone) &
        " feature:refs/crafted/probe")
      let res = sh(q(fx.reproBin) & " gateway pre-receive --gateway-dir " &
        q(fx.gateway) & " < " & q(input))
      checkpoint("crafted pre-receive: " & res.output)
      check res.code != 0
      check "does not match" in res.output
      check tip(fx, fx.upstream, "refs/heads/feature") == theirs
      check tip(fx, fx.gateway, "refs/heads/feature") == before

  test "zero_to_zero_update_cannot_delete_an_upstream_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c4z")
      defer: removeDir(fx.scratch)
      # A branch created on the upstream after the gateway was wired: the
      # gateway has no such ref, so an all-zeroes <old> matches "absent".
      discard gitC(fx, fx.other, "checkout -q -b feature")
      let theirs = commit(fx, fx.other, "teammate")
      discard gitC(fx, fx.other, "push -q origin feature")
      doAssert tip(fx, fx.gateway, "refs/heads/feature").len == 0
      # A crafted line with both values all-zeroes is no deletion, but a
      # plain forward of it would be ``:refs/heads/feature``.
      let zero = "0000000000000000000000000000000000000000"
      let input = fx.scratch / "crafted.txt"
      writeFile(input, zero & " " & zero & " refs/heads/feature\n")
      let res = sh(q(fx.reproBin) & " gateway pre-receive --gateway-dir " &
        q(fx.gateway) & " < " & q(input))
      checkpoint("crafted pre-receive: " & res.output)
      check res.code != 0
      check "neither an old nor a new value" in res.output
      check tip(fx, fx.upstream, "refs/heads/feature") == theirs

  test "forced_update_of_a_declared_role_branch_is_refused":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c5")
      defer: removeDir(fx.scratch)
      # The upstream's HEAD must not be ``main``: a bare repository refuses
      # to delete its current branch by itself, which would let the deletion
      # case below pass without the gateway's refusal.
      discard gitC(fx, fx.upstream, "symbolic-ref HEAD refs/heads/elsewhere")
      let first = commit(fx, fx.clone, "main-1")
      discard commit(fx, fx.clone, "main-2")
      let p1 = pushThroughGateway(fx, "main")
      checkpoint("main push: " & p1.output)
      check p1.code == 0
      let mainTip = tip(fx, fx.upstream, "refs/heads/main")
      discard gitC(fx, fx.clone, "reset -q --hard " & first)
      discard commit(fx, fx.clone, "main-rewritten")
      let p = pushThroughGateway(fx, "--force", "main")
      checkpoint("forced push of main: " & p.output)
      check p.code != 0
      check "mainline-history-rewrite: a forced update of the shared " &
        "mainline 'main'" in p.output
      check tip(fx, fx.upstream, "refs/heads/main") == mainTip
      check tip(fx, fx.gateway, "refs/heads/main") == mainTip
      # A deletion of the mainline is refused as well.
      let d = pushThroughGateway(fx, ":main")
      checkpoint("deletion of main: " & d.output)
      check d.code != 0
      check "mainline-history-rewrite: a deletion of the shared mainline " &
        "'main'" in d.output
      check tip(fx, fx.upstream, "refs/heads/main") == mainTip
      # A forced push of a branch no role names still publishes.
      let before = publishFeature(fx)
      let rewritten = rewriteFeature(fx)
      check rewritten != before
      let f = pushThroughGateway(fx, "--force", "feature")
      checkpoint("forced push of feature: " & f.output)
      check f.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") == rewritten

  test "unresolvable_role_refuses_a_forced_update":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c6", roles = false)
      defer: removeDir(fx.scratch)
      let before = publishFeature(fx)
      discard rewriteFeature(fx)
      let p = pushThroughGateway(fx, "--force", "feature")
      checkpoint("forced push: " & p.output)
      check p.code != 0
      check "cannot tell whether a declared role names this branch" in
        p.output
      check tip(fx, fx.upstream, "refs/heads/feature") == before

suite "push gateway forced updates of the workspace root repository":

  test "workspace_root_repository_takes_its_roles_from_the_settings":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c7", rootRepo = true)
      defer: removeDir(fx.scratch)
      # A feature branch of the root repository: rewritten and deleted.
      let before = publishFeature(fx)
      let rewritten = rewriteFeature(fx)
      check rewritten != before
      let f = pushThroughGateway(fx, "--force", "feature")
      checkpoint("forced push of the root's feature: " & f.output)
      check f.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") == rewritten
      let d = pushThroughGateway(fx, ":feature")
      checkpoint("deletion of the root's feature: " & d.output)
      check d.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") == ""
      # Its mainline, declared in the settings file, is refused.
      discard gitC(fx, fx.upstream, "symbolic-ref HEAD refs/heads/elsewhere")
      discard gitC(fx, fx.clone, "checkout -q main")
      let first = commit(fx, fx.clone, "root-main-1")
      discard commit(fx, fx.clone, "root-main-2")
      check pushThroughGateway(fx, "main").code == 0
      let mainTip = tip(fx, fx.upstream, "refs/heads/main")
      discard gitC(fx, fx.clone, "reset -q --hard " & first)
      discard commit(fx, fx.clone, "root-main-rewritten")
      let p = pushThroughGateway(fx, "--force", "main")
      checkpoint("forced push of the root's main: " & p.output)
      check p.code != 0
      check "mainline-history-rewrite: a forced update of the shared " &
        "mainline 'main'" in p.output
      check tip(fx, fx.upstream, "refs/heads/main") == mainTip

proc poolOf(fx: Fixture; tracking: bool): string =
  ## A pool for the upstream: a ``clone --bare`` (which installs no fetch
  ## refspec, the pre-PG-0 shape), plus PG-0's refspec when ``tracking``.
  result = fx.scratch / (if tracking: "pool.git" else: "frozen-pool.git")
  discard must(q(fx.gitBin) & " clone -q --bare " & q(fileUrl(fx.upstream)) &
    " " & q(result))
  if tracking:
    discard gitC(fx, result, "config remote.origin.fetch " &
      q(SharedBareFetchRefspec))
    discard gitC(fx, result, "fetch -q --prune origin")

suite "rewire --reset-refs":

  test "reset_refs_refuses_a_pool_without_a_fetch_refspec":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "r1")
      defer: removeDir(fx.scratch)
      let pool = poolOf(fx, tracking = false)
      let before = publishFeature(fx)
      discard teammateAdvancesFeature(fx)
      let res = resetGatewayRefsToPool(gitBin, fx.gateway, pool)
      checkpoint(res.diagnostic)
      check not res.ok
      check "refused" in res.diagnostic
      check tip(fx, fx.gateway, "refs/heads/feature") == before

  test "stale_lease_remedy_integrate_reset_push_publishes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "r2")
      defer: removeDir(fx.scratch)
      discard publishFeature(fx)
      let theirs = teammateAdvancesFeature(fx)
      discard gitC(fx, fx.gateway, "update-ref refs/heads/gone " &
        tip(fx, fx.gateway, "refs/heads/feature"))
      discard rewriteFeature(fx)
      check pushThroughGateway(fx, "--force", "feature").code != 0
      # 1. integrate the teammate's commit (redo the squashed change on top
      #    of it).
      discard gitC(fx, fx.clone, "fetch -q origin")
      discard gitC(fx, fx.clone, "reset -q --hard origin/feature")
      let integrated = commit(fx, fx.clone, "squashed-on-top")
      # 2. reset the gateway's refs to a refreshed (PG-0) pool.
      let pool = poolOf(fx, tracking = true)
      let reset = resetGatewayRefsToPool(gitBin, fx.gateway, pool)
      checkpoint(reset.diagnostic)
      check reset.ok
      check tip(fx, fx.gateway, "refs/heads/feature") == theirs
      check tip(fx, fx.gateway, "refs/heads/gone") == ""
      # 3. push again: an ordinary fast-forward.
      let p = pushThroughGateway(fx, "feature")
      checkpoint("push after the remedy: " & p.output)
      check p.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") == integrated

  test "rewire_reset_refs_from_the_command_line_completes_the_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let scratchCache = createTempDir("repro-pg-lease-cache-", "")
      defer: removeDir(scratchCache)
      let cache = scratchCache / "clones"
      let fx = setup(gitBin, "r3", cache = cache)
      defer: removeDir(fx.scratch)
      let before = publishFeature(fx)
      let theirs = teammateAdvancesFeature(fx)
      discard rewriteFeature(fx)
      check pushThroughGateway(fx, "--force", "feature").code != 0
      discard gitC(fx, fx.clone, "fetch -q origin")
      discard gitC(fx, fx.clone, "reset -q --hard origin/feature")
      let integrated = commit(fx, fx.clone, "squashed-on-top")
      check tip(fx, fx.gateway, "refs/heads/feature") == before
      let rewire = runShell(shellCommand(@[fx.reproBin, "workspace",
        "shared-clones", "rewire", "proj", "--workspace-root=" & fx.workspace,
        "--reset-refs"], @[(name: "REPRO_WORKSPACE_CLONES", value: cache)]))
      checkpoint("rewire --reset-refs: " & rewire.output)
      check rewire.code == 0
      check "gateway refs reset to the pool's" in rewire.output
      check tip(fx, fx.gateway, "refs/heads/feature") == theirs
      let p = pushThroughGateway(fx, "feature")
      checkpoint("push after the remedy: " & p.output)
      check p.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") == integrated
