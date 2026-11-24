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
##   - ``deletion_of_the_certificate_notes_is_leased_too`` and
##     ``deletion_of_a_tag_is_leased_too`` -- a deletion of a ref outside
##     ``refs/heads/*`` is leased as a branch's is. A teammate published a
##     newer note (moved the tag) upstream after this gateway last forwarded
##     the ref; the deletion is refused and the upstream keeps it. A plain
##     ``:<ref>`` deleted it. The remedy the refusal names (push the
##     upstream's value through the gateway, then delete) publishes the
##     deletion.
##   - ``deleting_a_ref_the_gateway_never_forwarded_names_the_remedy`` --
##     stock git sends an all-zeroes ``<old>`` and ``<new>`` for
##     ``git push origin :<ref>`` when the gateway has no such ref. There is
##     no value to lease, so it is refused; the refusal names the same
##     remedy, and following it publishes the deletion.
##   - ``workspace_root_roles_that_do_not_resolve_refuse_a_forced_update`` --
##     a settings file that declares a role for the root repository but no
##     mainline resolves no role at all. The gateway refuses a forced update
##     (fail closed) instead of reading "no role resolved" as "no role is
##     declared", whether the role is given in ``[workspace]`` or in the
##     default profile; a settings file that declares nothing still
##     publishes. A ``REPRO_WORKSPACE_CONFIG`` inherited from the pushing
##     shell that names a missing file does not read as "no settings file":
##     the root's mainline is still refused.
##   - ``workspace_root_roles_ignore_an_inherited_settings_variable`` and
##     ``member_roles_ignore_an_inherited_settings_variable`` -- the gateway
##     reads the roles of the workspace its config records, not of the file
##     a ``REPRO_WORKSPACE_CONFIG`` inherited from the pushing shell names.
##     A variable naming another settings file that declares no mainline
##     (for the root) or a profile without the member's role (for a member)
##     must not switch the refusal off; a relative value (which the hook
##     would read against the gateway's bare repository) and one naming a
##     directory must not refuse an ordinary forced push. Recorded as
##     reprobuild-pm
##     ``issues/2026-11-20-the-gateway-reads-the-root-s-roles-from-whatever-file-an-inherited-repro-workspace-config-names.md``.
##   - ``upstream_without_atomic_push_is_forwarded_non_atomically`` -- an
##     upstream that does not advertise ``atomic`` still receives the push,
##     and the gateway says the forward was not atomic.
##   - ``non_atomic_fallback_does_not_depend_on_gits_language`` -- the
##     forward recognises such an upstream by git's message, which git
##     translates. Under a German git the push still publishes.
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
## The groups from the non-branch deletions on were recorded as reprobuild-pm
## ``issues/2026-11-19-the-gateway-forwards-tag-and-notes-deletions-unleased-and-its-stale-lease-report-reads-git-s-english.md``.
##
## Test doubles: none. The German git is the real ``git`` reading a message
## catalogue this test writes (one message, the one the forward matches) under
## a ``de_DE.UTF-8`` locale it compiles with ``localedef``; both are handed to
## git through ``GIT_TEXTDOMAINDIR`` and ``LOCPATH``.
##
## Skip rule: ``git`` missing on PATH. The language case is skipped as well
## when this host cannot produce a translated git (no ``localedef``, or a git
## built without gettext); it first proves that its git does print German.

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

proc pushThroughGatewayWith(fx: Fixture;
    extraEnv: seq[tuple[name, value: string]]; args: varargs[string]):
    tuple[code: int; output: string] =
  var argv = @[fx.gitBin, "-C", fx.clone, "push", "--no-verify", "origin"]
  for r in args:
    argv.add(r)
  runShell(shellCommand(argv,
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)] & extraEnv))

const NotesRef = "refs/notes/test-certificates/certificates"

proc writeGermanCatalogue(dir: string) =
  ## A gettext ``.mo`` for domain ``git`` holding one message: the refusal
  ## ``git push --atomic`` dies with when the receiving side does not
  ## advertise ``atomic`` (git's ``send-pack.c``). The translation is git's
  ## own (``po/de.po``).
  const msgid = "the receiving end does not support --atomic push"
  const msgstr = "die Gegenseite unterst\xC3\xBCtzt keinen atomaren " &
    "Versand (\"--atomic push\")"
  proc u32(v: int): string =
    for shift in [0, 8, 16, 24]:
      result.add(char((v shr shift) and 0xff))
  let keysAt = 28 + 16
  let valuesAt = keysAt + msgid.len + 1
  var mo = u32(0x950412de'i64.int) & u32(0) & u32(1) & u32(28) & u32(36) &
    u32(0) & u32(0)
  mo.add(u32(msgid.len) & u32(keysAt))
  mo.add(u32(msgstr.len) & u32(valuesAt))
  mo.add(msgid & "\0" & msgstr & "\0")
  createDir(dir / "de" / "LC_MESSAGES")
  writeFile(dir / "de" / "LC_MESSAGES" / "git.mo", mo)

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

suite "push gateway deletions outside refs/heads":

  test "deletion_of_the_certificate_notes_is_leased_too":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c8")
      defer: removeDir(fx.scratch)
      # This workspace publishes a note through its gateway.
      discard gitC(fx, fx.clone, "notes --ref " & NotesRef & " add -m ours HEAD")
      let p1 = pushThroughGateway(fx, NotesRef)
      checkpoint("notes push: " & p1.output)
      check p1.code == 0
      let ours = tip(fx, fx.upstream, NotesRef)
      check ours.len > 0
      check tip(fx, fx.gateway, NotesRef) == ours
      # A teammate publishes a newer note straight to the upstream.
      discard gitC(fx, fx.other, "fetch -q origin " & NotesRef & ":" & NotesRef)
      discard gitC(fx, fx.other, "notes --ref " & NotesRef &
        " append -m teammate HEAD")
      discard gitC(fx, fx.other, "push -q origin " & NotesRef)
      let theirs = tip(fx, fx.upstream, NotesRef)
      check theirs != ours
      # Deleting the notes through the gateway must not delete theirs.
      let d = pushThroughGateway(fx, ":" & NotesRef)
      checkpoint("notes deletion: " & d.output)
      check d.code != 0
      check tip(fx, fx.upstream, NotesRef) == theirs
      check tip(fx, fx.gateway, NotesRef) == ours
      check "stale lease:" in d.output
      check theirs in d.output
      # ``rewire --reset-refs`` resets branches only; it is no remedy here.
      check "rewire --reset-refs" notin d.output
      # The remedy the refusal names: bring the gateway to the upstream's
      # value by pushing it through, then delete.
      check ("'git fetch origin " & NotesRef & "'") in d.output
      check ("git push origin " & theirs & ":" & NotesRef) in d.output
      discard gitC(fx, fx.clone, "fetch -q origin " & NotesRef)
      let catchUp = pushThroughGateway(fx, theirs & ":" & NotesRef)
      checkpoint("catch-up push: " & catchUp.output)
      check catchUp.code == 0
      check tip(fx, fx.gateway, NotesRef) == theirs
      let ok = pushThroughGateway(fx, ":" & NotesRef)
      checkpoint("notes deletion with a current lease: " & ok.output)
      check ok.code == 0
      check tip(fx, fx.upstream, NotesRef) == ""

  test "deletion_of_a_tag_is_leased_too":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c9")
      defer: removeDir(fx.scratch)
      discard gitC(fx, fx.clone, "tag v1 HEAD")
      let p1 = pushThroughGateway(fx, "refs/tags/v1")
      checkpoint("tag push: " & p1.output)
      check p1.code == 0
      let ours = tip(fx, fx.upstream, "refs/tags/v1")
      check ours.len > 0
      # A teammate moves the tag on the upstream to a commit of theirs.
      let theirs = commit(fx, fx.other, "teammate")
      discard gitC(fx, fx.other, "tag v1 HEAD")
      discard gitC(fx, fx.other, "push -q --force origin refs/tags/v1")
      check tip(fx, fx.upstream, "refs/tags/v1") == theirs
      let d = pushThroughGateway(fx, ":refs/tags/v1")
      checkpoint("tag deletion: " & d.output)
      check d.code != 0
      check tip(fx, fx.upstream, "refs/tags/v1") == theirs
      check tip(fx, fx.gateway, "refs/tags/v1") == ours
      check "stale lease:" in d.output
      check (theirs[0 ..< 7] & " teammate") in d.output
      check "rewire --reset-refs" notin d.output
      # The remedy: push the upstream's value through the gateway (the tag
      # moved, so git asks for --force), then delete.
      check "'git fetch origin refs/tags/v1'" in d.output
      check ("git push --force origin " & theirs & ":refs/tags/v1") in d.output
      discard gitC(fx, fx.clone, "fetch -q origin refs/tags/v1")
      let catchUp = pushThroughGateway(fx, "--force", theirs & ":refs/tags/v1")
      checkpoint("catch-up push: " & catchUp.output)
      check catchUp.code == 0
      check tip(fx, fx.gateway, "refs/tags/v1") == theirs
      let ok = pushThroughGateway(fx, ":refs/tags/v1")
      checkpoint("tag deletion with a current lease: " & ok.output)
      check ok.code == 0
      check tip(fx, fx.upstream, "refs/tags/v1") == ""

  test "deleting_a_ref_the_gateway_never_forwarded_names_the_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c9z")
      defer: removeDir(fx.scratch)
      # A teammate's tag, on the upstream only: this gateway has no such ref.
      let theirs = commit(fx, fx.other, "teammate")
      discard gitC(fx, fx.other, "tag rel HEAD")
      discard gitC(fx, fx.other, "push -q origin refs/tags/rel")
      doAssert tip(fx, fx.gateway, "refs/tags/rel").len == 0
      let d = pushThroughGateway(fx, ":refs/tags/rel")
      checkpoint("deletion of a ref the gateway lacks: " & d.output)
      check d.code != 0
      check tip(fx, fx.upstream, "refs/tags/rel") == theirs
      check "this gateway holds no such ref" in d.output
      check "'git fetch origin refs/tags/rel'" in d.output
      check "'git push origin FETCH_HEAD:refs/tags/rel'" in d.output
      # The remedy as named.
      discard gitC(fx, fx.clone, "fetch -q origin refs/tags/rel")
      let catchUp = pushThroughGateway(fx, "FETCH_HEAD:refs/tags/rel")
      checkpoint("catch-up push: " & catchUp.output)
      check catchUp.code == 0
      check tip(fx, fx.gateway, "refs/tags/rel") == theirs
      let ok = pushThroughGateway(fx, ":refs/tags/rel")
      checkpoint("deletion with a value to lease: " & ok.output)
      check ok.code == 0
      check tip(fx, fx.upstream, "refs/tags/rel") == ""

suite "push gateway root roles that do not resolve":

  test "workspace_root_roles_that_do_not_resolve_refuse_a_forced_update":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c10", rootRepo = true)
      defer: removeDir(fx.scratch)
      # The root declares a role and no mainline: every fallback chain ends
      # at ``mainline``, so no role resolves (Workspace-Branch-Roles §3.3).
      writeFile(fx.workspace / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[workspace]\nunstable = \"feature\"\n")
      let before = publishFeature(fx)
      discard rewriteFeature(fx)
      let p = pushThroughGateway(fx, "--force", "feature")
      checkpoint("forced push of a declared, unresolvable role: " & p.output)
      check p.code != 0
      check "cannot tell whether a declared role names this branch" in
        p.output
      check "repro-workspace.toml" in p.output
      check tip(fx, fx.upstream, "refs/heads/feature") == before
      check tip(fx, fx.gateway, "refs/heads/feature") == before
      # The same through the default profile, which declares for the root
      # when ``[workspace]`` names no profile (Workspace-Branch-Roles §3.4).
      writeFile(fx.workspace / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[workspace]\ndefault_profile = \"tiers\"\n\n" &
        "[profiles.tiers]\nunstable = \"feature\"\n")
      let viaProfile = pushThroughGateway(fx, "--force", "feature")
      checkpoint("forced push, role from the default profile: " &
        viaProfile.output)
      check viaProfile.code != 0
      check "cannot tell whether a declared role names this branch" in
        viaProfile.output
      check tip(fx, fx.upstream, "refs/heads/feature") == before
      # A settings file that declares nothing for the root names no role
      # branch, and that is no error: the same forced push publishes.
      writeFile(fx.workspace / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n")
      let f = pushThroughGateway(fx, "--force", "feature")
      checkpoint("forced push with nothing declared: " & f.output)
      check f.code == 0
      let published = tip(fx, fx.clone, "refs/heads/feature")
      check tip(fx, fx.upstream, "refs/heads/feature") == published
      # ``feature`` becomes the root's mainline. A variable inherited from
      # the pushing shell that names a missing settings file must not read
      # as "no settings file".
      writeFile(fx.workspace / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[workspace]\nmainline = \"feature\"\n")
      discard gitC(fx, fx.clone, "commit -q --amend -m squashed-again")
      let e = pushThroughGatewayWith(fx, @[(name: "REPRO_WORKSPACE_CONFIG",
        value: fx.scratch / "absent.toml")], "--force", "feature")
      checkpoint("forced push of the mainline, settings named away: " &
        e.output)
      check e.code != 0
      check "mainline-history-rewrite: a forced update of the shared " &
        "mainline 'feature'" in e.output
      check tip(fx, fx.upstream, "refs/heads/feature") == published

suite "push gateway roles ignore an inherited REPRO_WORKSPACE_CONFIG":

  test "workspace_root_roles_ignore_an_inherited_settings_variable":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      # The root's settings declare ``mainline = "main"`` (``setup``).
      let fx = setup(gitBin, "c13", rootRepo = true)
      defer: removeDir(fx.scratch)
      # Another workspace's settings file, one that declares nothing.
      let decoyDir = fx.scratch / "decoy"
      createDir(decoyDir)
      let decoy = decoyDir / "repro-workspace.toml"
      writeFile(decoy, "schema = \"reprobuild.workspace.settings.v1\"\n")
      discard gitC(fx, fx.upstream, "symbolic-ref HEAD refs/heads/elsewhere")
      let first = commit(fx, fx.clone, "root-main-1")
      discard commit(fx, fx.clone, "root-main-2")
      check pushThroughGateway(fx, "main").code == 0
      let mainTip = tip(fx, fx.upstream, "refs/heads/main")
      discard gitC(fx, fx.clone, "reset -q --hard " & first)
      discard commit(fx, fx.clone, "root-main-rewritten")
      let p = pushThroughGatewayWith(fx, @[(name: "REPRO_WORKSPACE_CONFIG",
        value: decoy)], "--force", "main")
      checkpoint("forced push of the root's main, settings named away: " &
        p.output)
      check p.code != 0
      check "mainline-history-rewrite: a forced update of the shared " &
        "mainline 'main'" in p.output
      check tip(fx, fx.upstream, "refs/heads/main") == mainTip
      check tip(fx, fx.gateway, "refs/heads/main") == mainTip
      let d = pushThroughGatewayWith(fx, @[(name: "REPRO_WORKSPACE_CONFIG",
        value: decoy)], ":main")
      checkpoint("deletion of the root's main, settings named away: " &
        d.output)
      check d.code != 0
      check "mainline-history-rewrite: a deletion of the shared mainline " &
        "'main'" in d.output
      check tip(fx, fx.upstream, "refs/heads/main") == mainTip
      # A relative value means a file beside the developer's shell; the hook
      # runs in the gateway's bare repository. And a value naming a
      # directory. Neither may refuse a forced push of a branch no role of
      # the recorded root names.
      let before = publishFeature(fx)
      discard rewriteFeature(fx)
      let rel = pushThroughGatewayWith(fx, @[(name: "REPRO_WORKSPACE_CONFIG",
        value: "repro-workspace.toml")], "--force", "feature")
      checkpoint("forced push of feature, relative variable: " & rel.output)
      check rel.code == 0
      let rewritten = tip(fx, fx.clone, "refs/heads/feature")
      check rewritten != before
      check tip(fx, fx.upstream, "refs/heads/feature") == rewritten
      discard gitC(fx, fx.clone, "commit -q --amend -m squashed-again")
      let dir = pushThroughGatewayWith(fx, @[(name: "REPRO_WORKSPACE_CONFIG",
        value: decoyDir)], "--force", "feature")
      checkpoint("forced push of feature, variable names a directory: " &
        dir.output)
      check dir.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") ==
        tip(fx, fx.clone, "refs/heads/feature")

  test "member_roles_ignore_an_inherited_settings_variable":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c14")
      defer: removeDir(fx.scratch)
      # ``app`` takes role ``stable`` = ``release`` from the profile the
      # workspace's settings file declares (Workspace-Branch-Roles §3).
      writeFile(fx.workspace / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[workspace]\nmainline = \"main\"\n\n" &
        "[profiles.product]\nmainline = \"main\"\nstable = \"release\"\n")
      writeFile(fx.workspace / "repos" / "app.toml",
        "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
        "[repo]\nname = \"app\"\npath = \"app\"\nremote = \"app-origin\"\n" &
        "profile = \"product\"\nmainline = \"main\"\n")
      # Another workspace's settings: the same profile, without ``stable``.
      let decoy = fx.scratch / "decoy.toml"
      writeFile(decoy,
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[workspace]\nmainline = \"main\"\n\n" &
        "[profiles.product]\nmainline = \"main\"\n")
      discard gitC(fx, fx.clone, "checkout -q -b release")
      let first = commit(fx, fx.clone, "release-1")
      discard commit(fx, fx.clone, "release-2")
      check pushThroughGateway(fx, "release").code == 0
      let releaseTip = tip(fx, fx.upstream, "refs/heads/release")
      discard gitC(fx, fx.clone, "reset -q --hard " & first)
      discard commit(fx, fx.clone, "release-rewritten")
      let p = pushThroughGatewayWith(fx, @[(name: "REPRO_WORKSPACE_CONFIG",
        value: decoy)], "--force", "release")
      checkpoint("forced push of app's release, settings named away: " &
        p.output)
      check p.code != 0
      check "mainline-history-rewrite: a forced update of the shared " &
        "branch 'release' (role `stable`)" in p.output
      check tip(fx, fx.upstream, "refs/heads/release") == releaseTip
      check tip(fx, fx.gateway, "refs/heads/release") == releaseTip

suite "push gateway forward to an upstream without atomic push":

  test "upstream_without_atomic_push_is_forwarded_non_atomically":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "c11e")
      defer: removeDir(fx.scratch)
      discard gitC(fx, fx.upstream, "config receive.advertiseAtomic false")
      discard gitC(fx, fx.clone, "checkout -q -b feature")
      let pushed = commit(fx, fx.clone, "feature-1")
      # The language git reports in is pinned by the forward itself; the
      # caller's is pinned here so that this case holds on any host.
      let p = pushThroughGatewayWith(fx, @[(name: "LC_ALL", value: "C")],
        "feature")
      checkpoint("push to an upstream without atomic: " & p.output)
      check p.code == 0
      check tip(fx, fx.upstream, "refs/heads/feature") == pushed
      check tip(fx, fx.gateway, "refs/heads/feature") == pushed
      check "forwarded non-atomically" in p.output

  test "non_atomic_fallback_does_not_depend_on_gits_language":
    let gitBin = findExe("git")
    let localedef = findExe("localedef")
    if gitBin.len == 0:
      skip("git is not on PATH")
    elif localedef.len == 0:
      skip("localedef is not on PATH, so no German locale can be compiled")
    else:
      let fx = setup(gitBin, "c11")
      defer: removeDir(fx.scratch)
      let locales = fx.scratch / "locales"
      let catalogues = fx.scratch / "catalogues"
      createDir(locales)
      writeGermanCatalogue(catalogues)
      let compiled = sh(q(localedef) & " -i de_DE -f UTF-8 " &
        q(locales / "de_DE.UTF-8"))
      let german = @[(name: "LOCPATH", value: locales),
        (name: "LC_ALL", value: "de_DE.UTF-8"),
        (name: "LANGUAGE", value: "de"),
        (name: "GIT_TEXTDOMAINDIR", value: catalogues)]
      # An upstream that does not advertise ``atomic``.
      discard gitC(fx, fx.upstream, "config receive.advertiseAtomic false")
      # Does this host's git speak German with that catalogue? Ask it
      # directly, outside the gateway.
      discard gitC(fx, fx.other, "checkout -q -b probe")
      let probe = runShell(shellCommand(@[gitBin, "-C", fx.other, "push",
        "--atomic", "origin", "probe"], german))
      checkpoint("probe: " & probe.output)
      if compiled.code != 0 or "keinen atomaren Versand" notin probe.output:
        skip("this host's git does not print the German catalogue " &
          "(localedef exited " & $compiled.code & ")")
      else:
        check "does not support --atomic push" notin probe.output
        discard gitC(fx, fx.clone, "checkout -q -b feature")
        let pushed = commit(fx, fx.clone, "feature-1")
        let p = pushThroughGatewayWith(fx, german, "feature")
        checkpoint("push under a German git: " & p.output)
        check p.code == 0
        check tip(fx, fx.upstream, "refs/heads/feature") == pushed
        check tip(fx, fx.gateway, "refs/heads/feature") == pushed
        check "forwarded non-atomically" in p.output

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
