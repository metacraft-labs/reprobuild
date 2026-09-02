## `repro workspace repos add --project=` must record the repo as a NAME under
## the project's `member_repos` — the same membership rule the repo-set branch
## already uses — not as a fragment path inserted before whichever array
## happens to close first.
##
## Regression origin: adding `verno` to the `codetracer` project wrote the
## fragment path into `member_sets`:
##
##     member_sets = [
##       "shared-infrastructure",
##       "metacraft-org-baseline",
##       "repos/verno.toml",      # <-- wrong array
##     ]
##
## because the `mkProject` branch called `appendFragmentInclude`, which inserts
## before the first line that is a bare `]` — in a project manifest that is the
## closing bracket of `member_sets`, declared before `member_repos`. The
## `mkRepoSet` branch alongside it already routed through `membershipKeyFor` +
## `editSetMember`, which locate the array BY ITS KEY; only the project branch
## kept the positional rule. The project then stopped resolving entirely:
##
##     cannot resolve repo-set 'codetracer': member set 'repos/verno.toml'
##     does not exist (looked for 'repo-sets/repos/verno.toml.toml')
##
## The failure is total rather than partial — every repo in the project becomes
## unlistable, not just the added one — so it is asserted here against a
## manifest shaped like the one that produced it: an array declared BEFORE the
## includes edges would go.
##
## MOCKS: none. The test drives the real `repro` binary against a real git
## manifest repo on a real filesystem. The remote URL is never contacted:
## `repos add` is a manifest AUTHORING verb, and no revision is pinned, so no
## remote probe runs.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

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

suite "repos add records project membership by key":

  test "a preceding array is not mistaken for the membership array":
    if findExe("git").len == 0:
      skip()
      return

    let root = createTempDir("repro-repos-add-includes-", "")
    defer: removeDir(root)

    let manifestRoot = root / "manifests"
    createDir(manifestRoot / "projects")
    createDir(manifestRoot / "repo-sets")

    # A project manifest whose FIRST multi-line array is not `includes`. This
    # is the shape that produced the regression.
    writeFile(manifestRoot / "projects" / "demo.toml", """schema = "reprobuild.workspace.project.v1"

member_sets = [
  "baseline",
]

member_repos = [
  "existing",
]

[project]
name = "demo"
default_remote = "metacraft-labs"

[[remote]]
name = "metacraft-labs"
fetch = "https://github.com/metacraft-labs"
""")
    writeFile(manifestRoot / "repo-sets" / "baseline.toml",
      "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
      "member_repos = [\n]\n")

    discard requireGit("git init -q .", manifestRoot)
    discard requireGit("git config user.email t@example.com", manifestRoot)
    discard requireGit("git config user.name Test", manifestRoot)
    discard requireGit("git add -A", manifestRoot)
    discard requireGit("git -c core.hooksPath=/dev/null commit -q -m init",
      manifestRoot)

    let repro = reproBinary()
    let res = runCmd(q(repro) & " workspace repos add added" &
      " --remote=https://github.com/metacraft-labs/added" &
      " --branch=main --project=demo -m " & q("a repo"),
      manifestRoot)
    checkpoint(res.output)

    let project = readFile(manifestRoot / "projects" / "demo.toml")

    # The whole point: the fragment path must NOT have landed in the array
    # that merely happens to close first.
    let memberSetsBlock = project.split("member_sets = [")[1].split("]")[0]
    check "repos/added.toml" notin memberSetsBlock
    check "added" notin memberSetsBlock
    check "baseline" in memberSetsBlock

    # It belongs under `member_repos`, as a bare name.
    let memberReposBlock = project.split("member_repos = [")[1].split("]")[0]
    check "\"added\"" in memberReposBlock
    check "existing" in memberReposBlock

    # The fragment itself is written either way; this asserts the edge, which
    # is what the resolver follows.
    check fileExists(manifestRoot / "repos" / "added.toml")
