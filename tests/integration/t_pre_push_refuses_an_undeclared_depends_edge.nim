## A `depends` edge that names no declared repo must REFUSE the push, not
## quietly shrink the set the gate walks.
##
## RA-21 scopes the gate to the pushed repo's transitive develop-set closure.
## `developSetClosure` skipped a dependency name it could not resolve, so a
## single typo in a `depends` list removed a real dependency from the
## cleanliness, publication and lock stages — and the gate then reported
## success over a smaller set than the manifests declare, with nothing said
## about the difference. A check that passes having verified less than it
## claims is the failure mode this gate exists to prevent; the fact that the
## shortfall is one edge rather than the whole workspace does not change what
## it is.
##
## The resolver already refuses a fragment referencing an undeclared REMOTE
## for the same reason ("turning a typo into a silent success is a worse
## failure mode than the transitional convenience is worth"). This is that
## rule applied to the other cross-reference a fragment can make.
##
## Discrimination against an unfixed binary: assertions 4-8 fail (exit 0, no
## failures, and the dropped edge is named nowhere in the report).
##
## Skip rule: `git` missing on PATH.

import std/[json, os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc git(gitBin: string; args: openArray[string]; cwd: string): CmdResult =
  var argv = @[gitBin]
  for a in args: argv.add(a)
  runShell(shellCommand(argv), cwd = cwd)

proc requireGit(gitBin: string; args: openArray[string]; cwd: string): string =
  let res = git(gitBin, args, cwd)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " failed in " & cwd &
      "\nexit=" & $res.code & "\n" & res.output)
    quit 1
  res.output

const projectTomlTemplate = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "lib-a"
default_revision = "main"
trunk = "main"

[[remote]]
name = "lib-a-origin"
fetch = "$1"

[[remote]]
name = "lib-b-origin"
fetch = "$2"

includes = [
  "repos/lib-a.toml",
  "repos/lib-b.toml",
]
"""

const libAFragmentTemplate = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
depends = [$1]
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

const workspaceLocalToml = """
schema = "reprobuild.workspace.local.v1"

[workspace]
project = "lib-a"
branch = "main"
"""

type Fixture = object
  scratch: string
  workspaceRoot: string
  reproBin: string
  gitBin: string
  headSha: string

proc seedRepo(gitBin, scratch, name: string): string =
  ## Bare origin + a pushed `main`; returns the bare path.
  let origin = scratch / ("origin-" & name & ".git")
  let seed = scratch / ("seed-" & name)
  createDir(seed)
  discard requireGit(gitBin, ["init", "-q", "-b", "main", "."], seed)
  discard requireGit(gitBin,
    ["config", "user.email", "tester@example.invalid"], seed)
  discard requireGit(gitBin, ["config", "user.name", "Gate Tester"], seed)
  writeFile(seed / "README.md", name & "\n")
  discard requireGit(gitBin, ["add", "README.md"], seed)
  discard requireGit(gitBin, ["commit", "-q", "-m", "seed"], seed)
  discard requireGit(gitBin, ["clone", "-q", "--bare", seed, origin], scratch)
  origin

proc buildFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-depends-", "")
  result.gitBin = gitBin
  result.reproBin = reproBinary()

  let originA = seedRepo(gitBin, result.scratch, "lib-a")
  let originB = seedRepo(gitBin, result.scratch, "lib-b")

  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  createDir(result.workspaceRoot / ".repro")
  writeFile(result.workspaceRoot / ".repro" / "workspace.toml",
    workspaceLocalToml)
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectTomlTemplate % [fileUrl(originA), fileUrl(originB)])
  writeFile(result.workspaceRoot / "repos" / "lib-b.toml", libBFragmentToml)

  for name, origin in {"lib-a": originA, "lib-b": originB}.items:
    let target = result.workspaceRoot / name
    discard requireGit(gitBin,
      ["clone", "-q", fileUrl(origin), target], result.scratch)
    discard requireGit(gitBin,
      ["config", "user.email", "tester@example.invalid"], target)
    discard requireGit(gitBin, ["config", "user.name", "Gate Tester"], target)

  result.headSha = requireGit(gitBin, ["rev-parse", "HEAD"],
    result.workspaceRoot / "lib-a").strip()

proc setDepends(fx: Fixture; entries: string) =
  writeFile(fx.workspaceRoot / "repos" / "lib-a.toml",
    libAFragmentTemplate % [entries])

proc runGate(fx: Fixture): tuple[code: int; report: JsonNode] =
  let refsFile = fx.scratch / "pushed-refs.txt"
  writeFile(refsFile, "refs/heads/main " & fx.headSha &
    " refs/heads/main 0000000000000000000000000000000000000000\n")
  let res = runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.workspaceRoot / "lib-a",
    "--pushed-refs=" & refsFile,
    "--json",
  ]))
  let start = res.output.find('{')
  check start >= 0
  (res.code, parseJson(res.output[start .. ^1]))

suite "pre-push refuses a `depends` edge naming no declared repo":

  test "t_pre_push_refuses_an_undeclared_depends_edge":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = buildFixture(gitBin)
      defer: removeDir(fx.scratch)

      # --- baseline: every edge resolves, the gate passes ----------------
      fx.setDepends("\"lib-b\"")
      let clean = runGate(fx)
      # 1-3: the fixture itself is green, so the refusal below is caused by
      #      the dangling edge and by nothing else about this workspace.
      check clean.code == 0
      check clean.report["exitCode"].getInt() == 0
      check clean.report["failures"].len == 0

      # --- one typo'd edge ------------------------------------------------
      fx.setDepends("\"lib-b\", \"lib-bee\"")
      let dangling = runGate(fx)
      # 4-5: refused, not passed.
      check dangling.code == 2
      check dangling.report["exitCode"].getInt() == 2
      # Bail cleanly rather than IndexDefect-ing when the gate passed: an
      # unfixed binary reports zero failures here, and the remaining
      # assertions should read as failures, not as a crash.
      require dangling.report["failures"].len == 1
      let failure = dangling.report["failures"][0]
      # 6-8: the refusal is attributable — it names the property, the edge,
      #      and what to do about it.
      check failure["property"].getStr() == "dependency-not-declared"
      check failure["evidence"].getStr().contains("lib-a -> lib-bee")
      check failure["remediation"].getStr().contains("does not declare")

      # 9: a resolvable edge is still not reported as dangling.
      check not failure["evidence"].getStr().contains("lib-a -> lib-b,")
