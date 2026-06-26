## RA-30 — ``repro health --fix`` performs ONLY safe remediations.
##
## ``--fix`` is the communicate-before-execute remediation path: it
## performs the SAFE, non-destructive fixes the spec authorizes (clone a
## missing develop-mode sibling, ``direnv allow``, start the user
## daemon), announcing each action; UNSAFE / ambiguous failures are
## reported, never auto-performed.
##
## This test exercises the hermetically controllable safe fix — cloning a
## missing develop-mode sibling reachable from a LOCAL bare repo created
## in the test — and asserts:
##
##   * Before ``--fix``: the ``siblings`` check FAILS (lib-b absent) and
##     the missing checkout does not exist on disk.
##   * ``repro health --fix`` announces the clone action and actually
##     clones the missing sibling (the working tree appears, ``.git``
##     present). Falsifiable: a no-op ``--fix`` leaves lib-b absent and
##     breaks this.
##   * After ``--fix``: re-running ``repro health --json`` shows the
##     ``siblings`` check now ``ok``.
##   * A NON-SAFE failure (the missing workspace marker, fixKind=none) is
##     NOT auto-fixed — it remains ``fail`` after ``--fix`` and is only
##     reported. Falsifiable: an over-eager fixer that "fixes everything"
##     breaks this.
##   * ``--json`` shape + non-zero exit while a check still fails.
##
## Skip rule: only when ``git`` is missing from PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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
  result = currentSourcePath().parentDir.parentDir.parentDir

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
    " config user.name \"RA30 Tester\"")
  writeFile(workPath / "README.md", "RA30 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " &
    branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))

proc projectTomlWith2Remotes(libAUrl, libBUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libBOrigin: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra30-fix-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libBOrigin = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")
  discard seedGitOrigin(gitBin, result.libBOrigin,
    result.scratch / "seed-lib-b")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith2Remotes(
      fileUrl(result.libAOrigin), fileUrl(result.libBOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  result.workspaceRoot = workspaceRoot

proc invokeHealth(fx: Fixture; extra: openArray[string] = []): CmdResult =
  var argv = @[
    fx.reproBin, "health", "lib-a",
    "--workspace-root=" & fx.workspaceRoot,
  ]
  for x in extra: argv.add(x)
  runShell(shellCommand(argv))

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  return nil

suite "RA-30 — repro health --fix remediates safe issues only":

  test "test_ra30_fix_clones_missing_sibling_reachable_from_local_bare":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clone")
      defer: removeDir(fx.scratch)
      # Clone only lib-a; lib-b is the missing develop-mode sibling.
      cloneInto(gitBin, fx.libAOrigin, fx.workspaceRoot / "lib-a")
      let libBPath = fx.workspaceRoot / "lib-b"
      check not dirExists(libBPath / ".git")

      # Before --fix: siblings fails and names the missing lib-b.
      block before:
        let res = invokeHealth(fx, ["--json"])
        let report = parseJson(res.output)
        let sib = findCheck(report, "siblings")
        check not sib.isNil
        check sib["status"].getStr() == "fail"

      # --fix announces + performs the safe clone.
      let fixRes = invokeHealth(fx, ["--fix"])
      check "cloning missing sibling lib-b" in fixRes.output

      # The missing sibling is now actually cloned on disk (clone is the
      # falsifiable observable; a no-op fixer leaves .git absent).
      check dirExists(libBPath / ".git")

      # After --fix: re-running health shows siblings OK.
      block after:
        let res = invokeHealth(fx, ["--json"])
        let report = parseJson(res.output)
        let sib = findCheck(report, "siblings")
        check not sib.isNil
        check sib["status"].getStr() == "ok"

  test "test_ra30_fix_does_not_touch_unsafe_failures":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # A workspace WITHOUT the manifest checkout: the workspace marker is
      # absent (fixKind=none, NOT auto-fixable) AND the manifest is
      # unresolved. ``--fix`` must NOT fabricate a workspace marker.
      let fx = setupFixture(gitBin, "unsafe")
      defer: removeDir(fx.scratch)
      # Strip the manifest so the workspace marker is genuinely absent.
      removeDir(fx.workspaceRoot / ".repo")
      check not dirExists(fx.workspaceRoot / ".repo")

      # Before --fix: workspace check fails (no marker).
      block before:
        let res = invokeHealth(fx, ["--json"])
        let report = parseJson(res.output)
        let ws = findCheck(report, "workspace")
        check not ws.isNil
        check ws["status"].getStr() == "fail"
        check ws["fixable"].getBool() == false

      # --fix runs but must REPORT (skip) the unsafe workspace failure,
      # not perform it.
      let fixRes = invokeHealth(fx, ["--fix"])
      check "skip workspace" in fixRes.output
      # No workspace marker was fabricated.
      check not dirExists(fx.workspaceRoot / ".repo")

      # After --fix: the unsafe failure persists and exit stays non-zero.
      block after:
        let res = invokeHealth(fx, ["--json"])
        let report = parseJson(res.output)
        let ws = findCheck(report, "workspace")
        check not ws.isNil
        check ws["status"].getStr() == "fail"
        check report["ok"].getBool() == false
        check report["exitCode"].getInt() == 1
        check res.code == 1
