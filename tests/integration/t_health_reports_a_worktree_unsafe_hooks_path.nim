## ``repro health``'s ``vcs-hooks`` row reports a ``core.hooksPath`` that
## cannot resolve from a linked worktree — the ``path-unsafe`` stop-state.
##
## THE DEFECT (reprobuild-pm issue 2026-09-27, "core.hooksPath is relative so
## no managed hook runs in a linked worktree"). ``git-hooks.nix``'s installer
## stores ``core.hooksPath = .git/hooks``. Git resolves a relative value against
## the top level of whichever worktree runs the hook, and in a linked worktree
## ``<top>/.git`` is a FILE — so Git finds no hooks directory there and runs no
## hook at all, saying nothing. The issue's own words: "``repro health`` should
## report a ``hooksPath`` that cannot resolve from a worktree, since the failure
## mode is silence."
##
## Measured before this suite existed, with ``build/bin/repro`` at ``ffb4dfe5``:
## a workspace repo carrying ``.git/hooks`` and all five managed hooks gave
##
##     vcs-hooks  ok  5 managed hook(s) wired across 1 participating repo(s) …
##
## — the row's census read the five bodies through the MAIN worktree, where the
## relative value happens to resolve, and never asked whether any other
## worktree could find them.
##
## WHAT IS ASSERTED
##
##   (A) CONTROLS. The value ``hooks ensure`` leaves (unset), and an explicit
##       ABSOLUTE value, are both ``ok``. Without these every assertion below is
##       satisfied by a row hardwired to ``fail``.
##   (B) A relative value makes the row NON-``ok``, names the repo and the value,
##       says what it costs, is ``--fix``-able, and leads its remedy with
##       ``hooks ensure --vcs <workspace>``. The bodies are still counted as
##       wired (they ARE serviceable from the main worktree). **Mutation guard:
##       the shipped check reports ``ok`` here.**
##   (C) The remedy is the repair: ``repro health --fix`` and ``repro hooks
##       ensure --vcs`` each leave the row ``ok`` and ``core.hooksPath``
##       absolute.
##   (D) ORDERING against ``stale``. ``stale`` must stay FIRST — its arm is the
##       one that does NOT hand out an ``--fix``-able ``hooks ensure``, because
##       re-authoring a body under a live contract mismatch deletes the evidence.
##       A repo that is both stale and path-unsafe takes the stale arm, and the
##       path-unsafe finding is NAMED in the same detail so it is not dropped.
##   (E) ORDERING against ``missing``. path-unsafe precedes it, and names the
##       missing hook in the same detail.
##   (F) A SINGLE-REPO target (no workspace population to sweep) is checked for
##       path-unsafe too: it used to be ``ok`` "not applicable" unconditionally.
##
## TEST DOUBLES: none. Real ``git``, local bares over ``file://``, the
## engine-built ``build/bin/repro`` installing real hooks and running the real
## ``health``. The only "fixture mutation" is writing the exact config value the
## dev shell writes, and (for D) the contract-token rewrite
## ``t_health_reports_a_refusing_hook_as_not_ok.nim`` explains and justifies.
##
## Hermetic: one ``createTempDir`` per case, no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
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

const DevShellRelativeHooksPath = ".git/hooks"
  ## Verbatim what `git-hooks.nix`'s installer leaves behind.

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "lib-a"

[[remote]]
name = "lib-a-origin"
fetch = "LIB_A_URL"

includes = [
  "repos/lib-a.toml",
]
"""

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
"""

type
  Fixture = object
    gitBin: string
    scratch: string
    workspaceRoot: string
    repoPath: string
    seedPath: string   ## a plain clone-source repo outside any workspace.
    reproBin: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.gitBin = gitBin
  result.scratch = createTempDir("repro-hookspath-health-" & slug & "-", "")
  result.reproBin = reproBinary()
  let origin = result.scratch / "origin-lib-a.git"
  result.seedPath = result.scratch / "seed-lib-a"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
  discard requireGit(q(gitBin) & " init -b main " & q(result.seedPath))
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " config user.name \"Hookspath Tester\"")
  writeFile(result.seedPath / "README.md", "hooksPath fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " remote add origin " & q(origin))
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " push origin main")
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  createDir(result.workspaceRoot / ".repro")
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectToml.replace("LIB_A_URL", fileUrl(origin)))
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.repoPath = result.workspaceRoot / "lib-a"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
    q(result.repoPath))
  let ensured = runShell(shellCommand(@[
    result.reproBin, "hooks", "ensure", "--vcs", result.workspaceRoot],
    @[(name: "REPROBUILD_REPRO", value: result.reproBin)]))
  doAssert ensured.code == 0, "fixture could not install managed hooks:\n" &
    ensured.output
  doAssert fileExists(result.repoPath / ".git" / "hooks" /
    "post-commit.repro-managed"), "fixture installed no managed post-commit"

proc hooksPathValue(fx: Fixture; repo: string): string =
  let res = runCmd(q(fx.gitBin) & " -C " & q(repo) &
    " config --get core.hooksPath")
  if res.code != 0: "" else: res.output.strip()

proc setHooksPath(fx: Fixture; repo, value: string) =
  discard requireGit(q(fx.gitBin) & " -C " & q(repo) &
    " config --local core.hooksPath " & q(value))
  doAssert fx.hooksPathValue(repo) == value

proc unsetHooksPath(fx: Fixture; repo: string) =
  discard runCmd(q(fx.gitBin) & " -C " & q(repo) &
    " config --local --unset core.hooksPath")
  doAssert fx.hooksPathValue(repo) == ""

proc repro(fx: Fixture; args: seq[string]): CmdResult =
  ## ``REPROBUILD_REPRO`` is pinned to the binary under test so the
  ## neighbouring ``hook-interpreter`` row, and any hook a git command fires,
  ## measure this build and not whatever the dev shell pins.
  runShell(shellCommand(@[fx.reproBin] & args,
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  nil

proc vcsHooksRowAt(fx: Fixture; workspaceRoot: string;
    project = ""): JsonNode =
  var args = @["health"]
  if project.len > 0:
    args.add(project)
  args.add(@["--json", "--workspace-root=" & workspaceRoot])
  let res = fx.repro(args)
  checkpoint("health --json output:\n" & res.output)
  let row = findCheck(parseJson(res.output), "vcs-hooks")
  doAssert not row.isNil, "health emitted no vcs-hooks row"
  row

proc vcsHooksRow(fx: Fixture): JsonNode =
  fx.vcsHooksRowAt(fx.workspaceRoot, "lib-a")

# The token rewrite (D) uses — see t_health_reports_a_refusing_hook_as_not_ok
# for why mutating the demanded token IS the stale state, by the only property
# the comparison reads.
const contractFlag = "--hook-contract="

proc makeStale(fx: Fixture; hookName: string) =
  let path = fx.repoPath / ".git" / "hooks" / (hookName & ".repro-managed")
  let body = readFile(path)
  let at = body.find(contractFlag)
  doAssert at >= 0, "fixture body carries no contract flag"
  var j = at + contractFlag.len
  while j < body.len and (body[j] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'} or
      body[j] in {'.', '-', '_'}):
    inc j
  let token = body[at + contractFlag.len ..< j]
  writeFile(path, body.replace(token,
    token[0 .. token.rfind('.')] & "0123456789abcdef"))

suite "health reports a worktree-unsafe core.hooksPath (path-unsafe)":

  test "t_health_reports_a_relative_hooks_path_as_path_unsafe":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository whose real " &
        "git config carries the relative core.hooksPath")
    else:
      let fx = setupFixture(gitBin, "relative")
      defer: removeDir(fx.scratch)

      # (A) CONTROLS FIRST. `hooks ensure` leaves the value unset (Git's own
      # default, `$GIT_COMMON_DIR/hooks`, is already worktree-safe) ...
      check fx.hooksPathValue(fx.repoPath) == ""
      let unsetRow = fx.vcsHooksRow()
      check unsetRow["status"].getStr() == "ok"
      check "5 managed hook(s) wired" in unsetRow["detail"].getStr()
      # ... and an ABSOLUTE value naming the same directory is equally fine.
      fx.setHooksPath(fx.repoPath, fx.repoPath / ".git" / "hooks")
      let absoluteRow = fx.vcsHooksRow()
      check absoluteRow["status"].getStr() == "ok"
      check "PATH-UNSAFE" notin absoluteRow["detail"].getStr()

      # (B) THE FIELD CONDITION.
      fx.setHooksPath(fx.repoPath, DevShellRelativeHooksPath)
      let row = fx.vcsHooksRow()
      let status = row["status"].getStr()
      let detail = row["detail"].getStr()
      let remedy = row["remedy"].getStr()
      checkpoint("vcs-hooks: status=" & status & "\ndetail=" & detail &
        "\nremedy=" & remedy)
      # THE MUTATION GUARD: the shipped check reports `ok` here.
      check status == "fail"
      check "PATH-UNSAFE" in detail
      check "lib-a" in detail
      check ("'" & DevShellRelativeHooksPath & "'") in detail
      check "linked worktree" in detail
      # The bodies are present and serviceable from the main worktree; the
      # finding is about every other worktree, not a reason to uncount them.
      check "5 managed hook(s) wired across 1 participating repo(s)" in detail
      # Not dressed up as either neighbouring state.
      check "STALE" notin detail
      check "missing" notin detail
      check remedy.contains("hooks ensure --vcs " & fx.workspaceRoot)
      check row["fixable"].getBool() == true
      # A failing row is a failing command.
      check fx.repro(@["health", "lib-a", "--json",
        "--workspace-root=" & fx.workspaceRoot]).code != 0

  test "t_health_fix_and_hooks_ensure_make_the_hooks_path_absolute":
    ## (C) The advertised remedy is the repair, by both routes.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository whose real " &
        "git config carries the relative core.hooksPath")
    else:
      let fx = setupFixture(gitBin, "fix")
      defer: removeDir(fx.scratch)
      let intended = fx.repoPath / ".git" / "hooks"

      fx.setHooksPath(fx.repoPath, DevShellRelativeHooksPath)
      check fx.vcsHooksRow()["status"].getStr() == "fail"
      let fixed = fx.repro(@["health", "lib-a", "--fix",
        "--workspace-root=" & fx.workspaceRoot])
      checkpoint("health --fix output:\n" & fixed.output)
      check fx.hooksPathValue(fx.repoPath) == intended
      let afterFix = fx.vcsHooksRow()
      check afterFix["status"].getStr() == "ok"
      check "5 managed hook(s) wired" in afterFix["detail"].getStr()

      fx.setHooksPath(fx.repoPath, DevShellRelativeHooksPath)
      check fx.vcsHooksRow()["status"].getStr() == "fail"
      let ensured = fx.repro(@["hooks", "ensure", "--vcs", fx.workspaceRoot])
      checkpoint("hooks ensure output:\n" & ensured.output)
      check ensured.code == 0
      check fx.hooksPathValue(fx.repoPath) == intended
      check fx.vcsHooksRow()["status"].getStr() == "ok"

  test "t_health_takes_the_stale_arm_ahead_of_path_unsafe_and_names_it":
    ## (D) Both conditions hold at once; the row must choose `stale`, whose
    ## remedy is NOT an `--fix`-able `hooks ensure`, and still say the path is
    ## unsafe.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository in which a " &
        "managed hook can be made stale and the hook path made relative")
    else:
      let fx = setupFixture(gitBin, "stale-and-unsafe")
      defer: removeDir(fx.scratch)

      check fx.vcsHooksRow()["status"].getStr() == "ok"   # control
      fx.makeStale("post-commit")
      fx.setHooksPath(fx.repoPath, DevShellRelativeHooksPath)

      let row = fx.vcsHooksRow()
      let detail = row["detail"].getStr()
      checkpoint("vcs-hooks: " & $row)
      check row["status"].getStr() == "fail"
      check "STALE" in detail
      check "lib-a/post-commit" in detail
      check row["remedy"].getStr().startsWith("direnv reload")
      check row["fixable"].getBool() == false
      # Nothing dropped by taking the safer arm.
      check "PATH-UNSAFE" in detail
      check ("'" & DevShellRelativeHooksPath & "'") in detail
      check detail.find("STALE") < detail.find("PATH-UNSAFE")

  test "t_health_takes_path_unsafe_ahead_of_missing_and_names_it":
    ## (E) path-unsafe precedes `missing`, and names the missing hook.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository in which a " &
        "managed hook can be removed and the hook path made relative")
    else:
      let fx = setupFixture(gitBin, "unsafe-and-missing")
      defer: removeDir(fx.scratch)

      check fx.vcsHooksRow()["status"].getStr() == "ok"   # control
      removeFile(fx.repoPath / ".git" / "hooks" / "post-merge")
      removeFile(fx.repoPath / ".git" / "hooks" / "post-merge.repro-managed")
      fx.setHooksPath(fx.repoPath, DevShellRelativeHooksPath)

      let row = fx.vcsHooksRow()
      let detail = row["detail"].getStr()
      checkpoint("vcs-hooks: " & $row)
      check row["status"].getStr() == "fail"
      check detail.startsWith("1 repo(s) PATH-UNSAFE")
      check "1 missing" in detail
      check "lib-a/post-merge" in detail
      check "4 managed hook(s) wired" in detail
      check row["fixable"].getBool() == true

  test "t_health_single_repo_target_reports_a_path_unsafe_hooks_path":
    ## (F) A target that is one repo and no workspace has no hook population to
    ## sweep, which is why the row used to answer `ok` "not applicable" — and
    ## that also answered `ok` for the one thing it CAN check.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository whose real " &
        "git config carries the relative core.hooksPath")
    else:
      let fx = setupFixture(gitBin, "single-repo")
      defer: removeDir(fx.scratch)

      let control = fx.vcsHooksRowAt(fx.seedPath)
      checkpoint("single-repo control: " & $control)
      check control["status"].getStr() == "ok"

      fx.setHooksPath(fx.seedPath, DevShellRelativeHooksPath)
      let row = fx.vcsHooksRowAt(fx.seedPath)
      let detail = row["detail"].getStr()
      checkpoint("single-repo vcs-hooks: " & $row)
      check row["status"].getStr() == "fail"
      check "PATH-UNSAFE" in detail
      check fx.seedPath in detail
      check ("'" & DevShellRelativeHooksPath & "'") in detail
      check row["remedy"].getStr().contains("hooks ensure --vcs " & fx.seedPath)
      check row["fixable"].getBool() == true

      let fixed = fx.repro(@["health", "--fix",
        "--workspace-root=" & fx.seedPath])
      checkpoint("single-repo health --fix output:\n" & fixed.output)
      check fx.hooksPathValue(fx.seedPath) == fx.seedPath / ".git" / "hooks"
      check fx.vcsHooksRowAt(fx.seedPath)["status"].getStr() == "ok"
