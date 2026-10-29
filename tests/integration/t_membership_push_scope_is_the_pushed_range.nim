## Workspace-And-Develop-Mode.md §"Gate scope when the pushed repo is the
## membership repo" (DECIDED): a push of the membership repo is scoped to the
## repos named by the added/modified `repos/<name>.toml` and
## `projects/<project>.toml` files in the diff of the PUSHED RANGE.
##
## WHY. The gate used to take that scope from HEAD's own first-parent diff,
## whatever Git was actually pushing. Three measured consequences, each a case
## below, each driven through a real `git push` and the installed pre-push hook:
##
##   1. OVER-CHECK — pushing an OLDER commit while HEAD is a newer commit that
##      touches a dirty sibling's fragment was refused over that sibling, which
##      only the later, unpushed commit mentions. It must pass, and the remote
##      must land on the older commit.
##   2. DELETION — deleting a remote branch publishes no commit, yet it was
##      gated on HEAD's diff and refused over a dirty sibling. It must pass.
##   3. UNDER-CHECK (soundness) — a range whose NEWEST commit is empty but
##      whose earlier commit re-declares a dirty sibling's fragment passed
##      unchecked. It must be refused, naming that sibling, and the remote
##      must not move.
##   4. UNION — one push of two new branches, each touching a different dirty
##      sibling's fragment, is refused naming BOTH: the scope is the union of
##      every pushed ref's range, not the first record's and not HEAD's.
##   5. UNREADABLE — a refs record naming an object the checkout lacks is
##      refused (`membership-push-scope`), not read as "publishes nothing".
##
## Each case is falsifiable against the old behaviour: in 1 and 2 HEAD's diff
## names the dirty sibling (the old gate refused); in 3 HEAD's diff is empty
## (the old gate passed); in 4 HEAD is the published root commit, for which
## the old scope came back empty. A third sibling, `lib-c`, is dirty throughout
## and no pushed commit touches its fragment: it must never be named, which
## keeps "refused" from passing against a gate that checks every repo.
##
## Mutation-checked:
##   * the old gate (scope from HEAD's first-parent diff): cases 1 and 2
##     fail on `check res.code == 0` (refused over lib-b), cases 3 and 4 on
##     `check res.code != 0` (passed unchecked);
##   * range reduced to the newest pushed commit (`-1` on the log): case 3
##     fails on `check res.code != 0`;
##   * only the first pre-push record read: case 4 fails on the `lib-b` needle
##     (`check name in res.output`);
##   * an unreadable pushed object treated as "publishes nothing": case 5
##     fails on `check res.code != 0`.
##
## No mocks. Real `git init` / `git init --bare` repositories, the real
## `repro hooks ensure` installation, real `git push` through the installed
## pre-push hook, the real `build/bin/repro` binary. No network. Case 5 alone
## hands the gate a written refs stream instead of a `git push`, because Git
## never sends a record for an object the checkout lacks; the gate itself is
## the real binary.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  let candidate =
    if configured.len > 0: configured
    else: currentSourcePath().parentDir.parentDir.parentDir / "build" /
      "bin" / addFileExt("repro", ExeExt)
  requireBinary(candidate, "reprobuild.apps.repro")

type
  EnvSnapshot = object
    existed: bool
    value: string

  Fixture = object
    scratch, workspace, gitBin, reproBin: string

proc overrideEnv(name, value: string): EnvSnapshot =
  result = EnvSnapshot(existed: existsEnv(name), value: getEnv(name))
  putEnv(name, value)

proc restoreEnv(name: string; snapshot: EnvSnapshot) =
  if snapshot.existed: putEnv(name, snapshot.value)
  else: delEnv(name)

proc gitIn(fx: Fixture; repo: string; args: openArray[string];
    required = true): tuple[code: int; output: string] =
  var argv = @[fx.gitBin, "-C", repo]
  argv.add(args)
  let res = runShell(shellCommand(argv))
  result = (res.code, res.output)
  if required and result.code != 0:
    checkpoint("git failed: " & argv.join(" ") & "\n" & res.output)
    quit 1

proc headOf(fx: Fixture; repo: string): string =
  fx.gitIn(repo, ["rev-parse", "HEAD"]).output.strip()

proc remoteTip(fx: Fixture; branch: string): string =
  ## "" when the remote has no such branch.
  let listed = fx.gitIn(fx.workspace,
    ["ls-remote", "origin", "refs/heads/" & branch]).output.strip()
  if listed.len == 0: "" else: listed.split('\t')[0]

const siblings = ["lib-a", "lib-b", "lib-c"]

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\nname = \"" & name & "\"\npath = \"" & name & "\"\n" &
  "remote = \"" & name & "-origin\"\nrevision = \"main\"\n"

proc setupFixture(gitBin, slug: string): Fixture =
  ## A FLAT native-layout workspace whose root is the membership repo (it
  ## carries `projects/` and `repos/`) with an `origin` of its own, and three
  ## clean, published sibling clones. The managed hooks are installed by the
  ## real `repro hooks ensure`.
  result.scratch = createTempDir("repro-membership-range-" & slug & "-", "")
  result.workspace = result.scratch / "workspace"
  result.gitBin = gitBin
  result.reproBin = reproBinary()
  let ws = result.workspace
  createDir(ws)
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"ws\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  var includes: seq[string]
  for name in siblings:
    let origin = result.scratch / ("origin-" & name & ".git")
    let seed = result.scratch / ("seed-" & name)
    discard require(q(gitBin) & " init -q --bare -b main " & q(origin))
    discard require(q(gitBin) & " init -q -b main " & q(seed))
    discard result.gitIn(seed, ["config", "user.email",
      "tester@example.invalid"])
    discard result.gitIn(seed, ["config", "user.name", "Range Tester"])
    writeFile(seed / "README.md", name & "\n")
    discard result.gitIn(seed, ["add", "README.md"])
    discard result.gitIn(seed, ["commit", "-q", "-m", "seed"])
    discard result.gitIn(seed, ["push", "-q", origin, "main"])
    project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fileUrl(origin) & "\"\n\n")
    includes.add("\"repos/" & name & ".toml\"")
  project.add("includes = [" & includes.join(", ") & "]\n")

  discard require(q(gitBin) & " init -q -b main " & q(ws))
  discard result.gitIn(ws, ["config", "user.email", "tester@example.invalid"])
  discard result.gitIn(ws, ["config", "user.name", "Range Tester"])
  createDir(ws / "projects")
  createDir(ws / "repos")
  writeFile(ws / "projects" / "ws.toml", project)
  for name in siblings:
    writeFile(ws / "repos" / (name & ".toml"), fragmentToml(name))
  # The sibling checkouts are nested working trees, not membership content.
  writeFile(ws / ".gitignore", "/lib-a/\n/lib-b/\n/lib-c/\n/.repro/\n")
  discard result.gitIn(ws, ["add", "-A"])
  discard result.gitIn(ws, ["commit", "-q", "-m", "seed membership"])
  let wsOrigin = result.scratch / "origin-workspace.git"
  discard require(q(gitBin) & " init -q --bare -b main " & q(wsOrigin))
  discard result.gitIn(ws, ["remote", "add", "origin", wsOrigin])
  discard result.gitIn(ws, ["push", "-q", "--no-verify", "-u", "origin",
    "main"])
  for name in siblings:
    discard require(q(gitBin) & " clone -q " &
      q(fileUrl(result.scratch / ("origin-" & name & ".git"))) & " " &
      q(ws / name))
  writeWorkspaceBranch(ws, project = "ws", branch = "main")

  let ensured = runShell(shellCommand(@[result.reproBin, "hooks", "ensure",
    "--vcs", "--workspace-root=" & ws, ws]))
  if ensured.code != 0:
    checkpoint("hook ensure failed:\n" & ensured.output)
    quit 1
  doAssert fileExists(ws / ".git" / "hooks" / "pre-push"),
    "the managed pre-push hook was not installed in the membership repo"
  # Post-commit / post-merge / post-checkout refreshes are orthogonal here and
  # would add lock commits between the steps this suite measures.
  for repo in @[ws] & @[ws / "lib-a", ws / "lib-b", ws / "lib-c"]:
    for name in ["post-commit", "post-merge", "post-checkout"]:
      for suffix in ["", ".repro-managed", ".repro-local"]:
        let path = repo / ".git" / "hooks" / (name & suffix)
        if fileExists(path): removeFile(path)

proc dirty(fx: Fixture; name: string) =
  writeFile(fx.workspace / name / "uncommitted.txt", "work in progress\n")
  # Positive find: the sibling really is dirty, so a pass is about scope.
  doAssert fx.gitIn(fx.workspace / name,
    ["status", "--porcelain"]).output.strip().len > 0

proc touchFragment(fx: Fixture; name, marker: string): string =
  ## Commit an edit to one sibling's fragment; return the commit.
  let path = fx.workspace / "repos" / (name & ".toml")
  writeFile(path, readFile(path) & "# " & marker & "\n")
  discard fx.gitIn(fx.workspace, ["add", "-A"])
  discard fx.gitIn(fx.workspace, ["commit", "-q", "-m", marker])
  fx.headOf(fx.workspace)

template passes(res: tuple[code: int; output: string]) =
  if res.code != 0:
    checkpoint("push unexpectedly refused:\n" & res.output)
  check res.code == 0

template refusedNaming(res: tuple[code: int; output: string];
    names: openArray[string]) =
  ## Refused FOR THE STATED REASON: each named sibling is reported dirty.
  if res.code == 0:
    checkpoint("push unexpectedly passed:\n" & res.output)
  check res.code != 0
  check "dirty" in res.output
  for name in names:
    if name notin res.output:
      checkpoint("missing '" & name & "' in:\n" & res.output)
    check name in res.output

template withFixture(gitBin, slug: string; body: untyped) =
  var fx {.inject.} = setupFixture(gitBin, slug)
  defer: removeDir(fx.scratch)
  let priorRepro = overrideEnv("REPROBUILD_REPRO", fx.reproBin)
  let priorSystem = overrideEnv("REPROBUILD_SYSTEM_CONFIG",
    fx.scratch / "no-system.toml")
  let priorUser = overrideEnv("REPROBUILD_USER_CONFIG",
    fx.scratch / "no-user.toml")
  let priorVcsPrivate = overrideEnv("REPROBUILD_VCS_PRIVATE_CONFIG",
    fx.scratch / "no-vcs-private.toml")
  let priorConfig = overrideEnv("REPRO_WORKSPACE_CONFIG", "")
  delEnv("REPRO_WORKSPACE_CONFIG")
  defer:
    restoreEnv("REPRO_WORKSPACE_CONFIG", priorConfig)
    restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", priorVcsPrivate)
    restoreEnv("REPROBUILD_USER_CONFIG", priorUser)
    restoreEnv("REPROBUILD_SYSTEM_CONFIG", priorSystem)
    restoreEnv("REPROBUILD_REPRO", priorRepro)
  # `lib-c` is dirty throughout and no commit ever touches its fragment.
  fx.dirty("lib-c")
  body

suite "pre-push — the membership repo's scope is the pushed range":
  let gitBin = findExe("git")

  test "membership_push_scope_is_the_pushed_range: older commit, HEAD newer":
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "older"):
        # A touches the CLEAN lib-a; B (HEAD) touches the DIRTY lib-b.
        let older = fx.touchFragment("lib-a", "re-declare lib-a")
        discard fx.touchFragment("lib-b", "re-declare lib-b")
        fx.dirty("lib-b")
        let res = fx.gitIn(fx.workspace,
          ["push", "origin", older & ":refs/heads/main"], required = false)
        passes(res)
        check "lib-b" notin res.output
        check "lib-c" notin res.output
        check fx.remoteTip("main") == older
        # Converse: pushing HEAD itself is in scope of lib-b and refused, so
        # the pass above is about the range and not a disabled gate.
        let head = fx.gitIn(fx.workspace, ["push", "origin", "main"],
          required = false)
        refusedNaming(head, ["lib-b"])
        check "lib-c" notin head.output
        check fx.remoteTip("main") == older

  test "membership_push_scope_is_the_pushed_range: deletion publishes nothing":
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "delete"):
        # HEAD touches lib-b's fragment and is PUBLISHED (lib-b clean then),
        # along with a `topic` branch to delete.
        discard fx.touchFragment("lib-b", "re-declare lib-b")
        passes(fx.gitIn(fx.workspace, ["push", "origin", "main"],
          required = false))
        passes(fx.gitIn(fx.workspace, ["push", "origin", "main:topic"],
          required = false))
        check fx.remoteTip("topic").len > 0
        fx.dirty("lib-b")
        let res = fx.gitIn(fx.workspace,
          ["push", "origin", "--delete", "topic"], required = false)
        passes(res)
        check "lib-b" notin res.output
        check fx.remoteTip("topic") == ""

  test "membership_push_scope_is_the_pushed_range: an empty newest commit " &
      "does not hide an earlier one":
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "under"):
        let published = fx.headOf(fx.workspace)
        discard fx.touchFragment("lib-b", "re-declare lib-b")
        discard fx.gitIn(fx.workspace, ["commit", "-q", "--allow-empty",
          "-m", "an empty commit on top"])
        fx.dirty("lib-b")
        let res = fx.gitIn(fx.workspace, ["push", "origin", "main"],
          required = false)
        refusedNaming(res, ["lib-b"])
        check "lib-c" notin res.output
        check fx.remoteTip("main") == published

  test "membership_push_scope_is_the_pushed_range: several refs take the union":
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "union"):
        # Two NEW branches (zero remote oid), each touching one sibling; HEAD
        # stays on the published `main`, whose own diff touches neither.
        discard fx.gitIn(fx.workspace, ["checkout", "-q", "-b", "x"])
        discard fx.touchFragment("lib-a", "re-declare lib-a")
        discard fx.gitIn(fx.workspace, ["checkout", "-q", "-b", "y", "main"])
        discard fx.touchFragment("lib-b", "re-declare lib-b")
        discard fx.gitIn(fx.workspace, ["checkout", "-q", "main"])
        fx.dirty("lib-a")
        fx.dirty("lib-b")
        let res = fx.gitIn(fx.workspace, ["push", "origin", "x", "y"],
          required = false)
        refusedNaming(res, ["lib-a", "lib-b"])
        check "lib-c" notin res.output
        check fx.remoteTip("x") == ""
        check fx.remoteTip("y") == ""

  test "membership_push_scope_is_the_pushed_range: an unreadable pushed " &
      "object refuses":
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "unreadable"):
        # A refs stream naming an object this checkout does not have. Git
        # never sends one, so this is driven through `repro check` with a
        # hand-written stream: the range cannot be read, and "publishes
        # nothing" (an empty scope, a pass) would be a guess.
        let published = fx.headOf(fx.workspace)
        let missing = "1".repeat(published.len)
        doAssert fx.gitIn(fx.workspace, ["cat-file", "-e", missing],
          required = false).code != 0
        let refs = fx.scratch / "pushed-refs"
        writeFile(refs, "refs/heads/main " & missing & " refs/heads/main " &
          published & "\n")
        let res = runShell(shellCommand(@[fx.reproBin, "check",
          "--mode=pre-push", "--workspace-root=" & fx.workspace,
          "--current-repo=" & fx.workspace, "--pushed-refs=" & refs]))
        if res.code == 0:
          checkpoint("gate unexpectedly passed:\n" & res.output)
        check res.code != 0
        check "membership-push-scope" in res.output
        check "lib-c" notin res.output
