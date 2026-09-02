## The gate's `unpublished` evidence must describe the search that ACTUALLY
## ran, not the remote name the gate happened to ask about.
##
## `isPublishedQuery` scopes to `<remote>/*` only when that remote is
## configured in the checkout; when it is not — the normal case for a
## workspace whose remotes are named after the org rather than `origin` — the
## query degrades to the ANY-remote question and answers that instead. The
## refusal, however, went on quoting the requested name:
##
##     HEAD c952fae… not on a 'origin/*' remote-tracking branch
##
## against a checkout with no `origin` at all. That statement is true only of
## a remote that does not exist; it sends the operator looking for a
## publication on a remote that could never hold one, and says nothing about
## the fact that every remote the checkout DOES have was already searched.
## The predicate was right and the message was wrong, which is the harder of
## the two to notice.
##
## Both wordings are asserted here, because the fix must not flatten the
## distinction: a remote that IS configured and does NOT contain HEAD still
## produces the scoped sentence.
##
## Discrimination against an unfixed binary: assertions 3 and 4 fail (the
## evidence still reads `'origin/*'` and carries no mention of the remotes
## actually searched).
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

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
depends = ["lib-b"]
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
  pushedRepo: string
  sibling: string
  reproBin: string
  gitBin: string

proc seedOrigin(gitBin, scratch, name: string): string =
  ## Bare origin carrying one commit on `main`; returns the bare path.
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

proc buildFixture(gitBin, slug, siblingRemoteName: string): Fixture =
  ## `lib-a` is the pushed repo (clean, published). `lib-b` is a declared
  ## dependency carrying an UNPUBLISHED local commit, with its git remote
  ## named `siblingRemoteName`.
  ##
  ## The unpublished repo has to be the SIBLING, not the pushed one: RA-32
  ## gives the pushed repo's own HEAD a different, self-referential evidence
  ## sentence ("this push is the publication being gated"), which is not the
  ## wording under test here.
  result.scratch = createTempDir("repro-unpub-" & slug & "-", "")
  result.gitBin = gitBin
  result.reproBin = reproBinary()

  let originA = seedOrigin(gitBin, result.scratch, "lib-a")
  let originB = seedOrigin(gitBin, result.scratch, "lib-b")

  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  createDir(result.workspaceRoot / ".repro")
  writeFile(result.workspaceRoot / ".repro" / "workspace.toml",
    workspaceLocalToml)
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectTomlTemplate % [fileUrl(originA), fileUrl(originB)])
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(result.workspaceRoot / "repos" / "lib-b.toml", libBFragmentToml)

  result.pushedRepo = result.workspaceRoot / "lib-a"
  discard requireGit(gitBin,
    ["clone", "-q", fileUrl(originA), result.pushedRepo], result.scratch)

  result.sibling = result.workspaceRoot / "lib-b"
  discard requireGit(gitBin,
    ["clone", "-q", "--origin", siblingRemoteName, fileUrl(originB),
     result.sibling], result.scratch)
  discard requireGit(gitBin,
    ["config", "user.email", "tester@example.invalid"], result.sibling)
  discard requireGit(gitBin, ["config", "user.name", "Gate Tester"],
    result.sibling)
  writeFile(result.sibling / "local.txt", "local\n")
  discard requireGit(gitBin, ["add", "local.txt"], result.sibling)
  discard requireGit(gitBin, ["commit", "-q", "-m", "local"], result.sibling)

proc unpublishedEvidence(fx: Fixture): string =
  ## Run the gate and return the sibling's `unpublished` evidence string.
  let head = requireGit(fx.gitBin, ["rev-parse", "HEAD"], fx.pushedRepo).strip()
  let refsFile = fx.scratch / "pushed-refs.txt"
  writeFile(refsFile, "refs/heads/main " & head &
    " refs/heads/main 0000000000000000000000000000000000000000\n")
  let res = runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.pushedRepo,
    "--pushed-refs=" & refsFile,
    "--json",
  ]))
  check res.code == 2
  let start = res.output.find('{')
  check start >= 0
  let report = parseJson(res.output[start .. ^1])
  check report["exitCode"].getInt() == 2
  check report["failures"].len == 1
  let failure = report["failures"][0]
  check failure["property"].getStr() == "unpublished"
  check failure["repo"].getStr() == "lib-b"
  failure["evidence"].getStr()

suite "pre-push `unpublished` evidence describes the search performed":

  test "t_unpublished_evidence_names_the_search_that_ran":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # --- the checkout has NO remote named `origin` -------------------
      let orgNamed = buildFixture(gitBin, "org-named", "metacraft-labs")
      defer: removeDir(orgNamed.scratch)
      # 1: precondition — the gate really is asking about a remote that is
      #    not configured here.
      check git(gitBin, ["remote"], orgNamed.sibling).output.strip() ==
        "metacraft-labs"

      let orgEvidence = unpublishedEvidence(orgNamed)
      # 2: the refusal still names the commit it is refusing.
      check orgEvidence.contains("not on any remote-tracking branch")
      # 3: it does NOT claim a search of a remote this checkout does not have.
      check not orgEvidence.contains("'origin/*'")
      # 4: it says which name was unusable and that everything else was tried.
      check orgEvidence.contains("no remote named 'origin'")
      check orgEvidence.contains("every configured remote was accepted")

      # --- the checkout DOES have `origin`, and it lacks HEAD ------------
      let originNamed = buildFixture(gitBin, "origin-named", "origin")
      defer: removeDir(originNamed.scratch)
      let scopedEvidence = unpublishedEvidence(originNamed)
      # 5: the scoped sentence survives — the fix reports the real scope, it
      #    does not blanket-reword every refusal into the any-remote form.
      check scopedEvidence.contains("not on a 'origin/*' remote-tracking branch")
      check not scopedEvidence.contains("no remote named")
