## `repro workspace project repo add` writes manifest entries that match the
## hand-written ones: it REUSES a declared `[[remote]]` that already serves the
## requested URL, mints at most ONE reusable org-named remote when none does,
## and never guesses a `revision`.
##
## Regression origin: adding `nim-shm-lease` to the `reprobuild` project (whose
## manifest already declares `metacraft-labs` → `https://github.com/metacraft-labs`
## and whose `default_revision` is `dev`) produced
##
##     remote = "nim-shm-lease-origin"   # a single-use remote + a new [[remote]]
##     revision = "main"                 # a branch the repo does not have
##
## where its hand-written siblings (`repos/nim-shm-queue.toml`,
## `repos/nim-shm-gset.toml`) carry `remote = "metacraft-labs"` and no
## `revision` at all. Both defects are asserted below.
##
## MOCKS: none. The test drives the real `repro` binary against a real git
## manifest repo on a real filesystem, and reads the results back through the
## real manifest resolver (`resolveProject`) rather than re-implementing its
## semantics. The two URL families used for the remote-reuse cases are
## unreachable network URLs on purpose — `project repo add` is a manifest
## AUTHORING verb and never contacts them. The one case that does contact a
## remote (explicit `--revision=` validation) uses a real local bare repo, so
## the test stays hermetic and offline.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

# The project manifest is shaped exactly like the pilot's
# `projects/reprobuild.toml`: an org remote, a bare-host remote, and a second
# alias (`origin`) pointing at the SAME org base — so the reuse rule has to
# pick deterministically between two equally valid matches.
const projectToml = """schema = "reprobuild.workspace.project.v1"

[project]
name = "reprobuild"
default_revision = "dev"

[[remote]]
name = "github"
fetch = "https://github.com"

[[remote]]
name = "metacraft-labs"
fetch = "https://github.com/metacraft-labs"

[[remote]]
name = "origin"
fetch = "https://github.com/metacraft-labs"

includes = [
  "repos/nim-shm-queue.toml",
]
"""

# A hand-written sibling fragment — the shape every generated fragment must
# match.
const siblingFragment = """schema = "reprobuild.workspace.repo.v1"

[repo]
name = "nim-shm-queue"
path = "nim-shm-queue"
remote = "metacraft-labs"
"""

type Fixture = object
  scratch: string
  reproBin: string
  workspaceRoot: string
  projectFile: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-projrepoadd-" & slug & "-", "")
  result.reproBin = reproBinary()
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  result.workspaceRoot = workspaceRoot
  result.projectFile = workspaceRoot / "projects" / "reprobuild.toml"
  writeFile(result.projectFile, projectToml)
  writeFile(workspaceRoot / "repos" / "nim-shm-queue.toml", siblingFragment)
  discard requireGit(q(gitBin) & " init -b dev " & q(workspaceRoot))
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.name \"Manifest Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m fixture")

proc addRepo(fx: Fixture; extra: seq[string]): tuple[code: int; output: string] =
  var argv = @[fx.reproBin, "workspace", "project", "repo", "add"]
  for e in extra: argv.add(e)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

proc countRemotes(projectFile: string): int =
  for line in readFile(projectFile).splitLines():
    if line.strip() == "[[remote]]": inc result

proc revisionOf(projectFile, repoName: string): string =
  ## The EFFECTIVE revision the resolver hands the sync planner — the whole
  ## point of omitting `revision` from a fragment is that this still answers.
  for repo in resolveProject(projectFile).repos:
    if repo.name == repoName: return repo.revision
  ""

proc fetchUrlOf(projectFile, repoName: string): string =
  for repo in resolveProject(projectFile).repos:
    if repo.name == repoName: return repo.fetchUrl
  ""

suite "repro workspace project repo add — remote reuse and revision inheritance":

  test "test_repo_add_reuses_matching_org_remote_and_omits_revision":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "reuse")
      defer: removeDir(fx.scratch)

      let remotesBefore = countRemotes(fx.projectFile)
      let res = addRepo(fx, @["reprobuild", "nim-shm-lease",
        "--remote=https://github.com/metacraft-labs/nim-shm-lease.git"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # DEFECT 1 + 2 regression: the generated fragment must be byte-identical
      # in shape to its hand-written sibling — same keys, same order, same
      # spacing, no `revision`, and the SHARED org remote rather than a
      # single-use `nim-shm-lease-origin`.
      let generated = readFile(fx.workspaceRoot / "repos" /
        "nim-shm-lease.toml")
      let expected = siblingFragment.replace("nim-shm-queue", "nim-shm-lease")
      check generated == expected

      # No new `[[remote]]` was appended, and the single-use name never
      # appears anywhere in the project manifest.
      let projectText = readFile(fx.projectFile)
      check countRemotes(fx.projectFile) == remotesBefore
      check not projectText.contains("nim-shm-lease-origin")
      check projectText.contains("\"repos/nim-shm-lease.toml\"")

      # Between `metacraft-labs` and its `origin` alias (identical `fetch`),
      # the org-named remote wins deterministically.
      check generated.contains("remote = \"metacraft-labs\"")

      # DEFECT 2: with no `revision` key the repo inherits `default_revision`,
      # and the composed clone URL is the one that was requested.
      check revisionOf(fx.projectFile, "nim-shm-lease") == "dev"
      check fetchUrlOf(fx.projectFile, "nim-shm-lease") ==
        "https://github.com/metacraft-labs/nim-shm-lease"

      # No description file was requested, so the command says so rather than
      # silently leaving the generated project docs without an entry.
      check res.output.contains("repos/nim-shm-lease.md")
      check not fileExists(fx.workspaceRoot / "repos" / "nim-shm-lease.md")

  test "test_repo_add_mints_one_org_named_remote_that_the_next_repo_reuses":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "mint")
      defer: removeDir(fx.scratch)

      let remotesBefore = countRemotes(fx.projectFile)
      let first = addRepo(fx, @["reprobuild", "first-lib",
        "--remote=https://git.example.invalid/acme/first-lib.git",
        "-m", "First library from a host the project has never seen."])
      if first.code != 0:
        checkpoint("output: " & first.output)
      check first.code == 0

      # Exactly ONE remote was added, named for the ORG (not the repo), with
      # the org base as `fetch` so it can serve other repos.
      check countRemotes(fx.projectFile) == remotesBefore + 1
      let projectText = readFile(fx.projectFile)
      check projectText.contains(
        "[[remote]]\nname = \"acme\"\nfetch = \"https://git.example.invalid/acme\"")
      check not projectText.contains("first-lib-origin")
      check readFile(fx.workspaceRoot / "repos" / "first-lib.toml") ==
        siblingFragment.replace("nim-shm-queue", "first-lib")
          .replace("metacraft-labs", "acme")
      check fetchUrlOf(fx.projectFile, "first-lib") ==
        "https://git.example.invalid/acme/first-lib"

      # `-m` records the description where the generated project docs read it.
      check readFile(fx.workspaceRoot / "repos" / "first-lib.md") ==
        "First library from a host the project has never seen.\n"

      # A SECOND repo from the same org reuses that remote and adds nothing.
      let second = addRepo(fx, @["reprobuild", "second-lib",
        "--remote=https://git.example.invalid/acme/second-lib.git"])
      if second.code != 0:
        checkpoint("output: " & second.output)
      check second.code == 0
      check countRemotes(fx.projectFile) == remotesBefore + 1
      check readFile(fx.workspaceRoot / "repos" / "second-lib.toml") ==
        siblingFragment.replace("nim-shm-queue", "second-lib")
          .replace("metacraft-labs", "acme")
      check revisionOf(fx.projectFile, "second-lib") == "dev"

  test "test_repo_add_to_a_freshly_created_project_stays_readable":
    # `project new` + `project repo add` must leave a manifest the RESOLVER
    # can read. A `includes = [ … ]` array written directly under `[project]`
    # is parsed as a key of that table and the whole manifest stops loading,
    # so the fresh-project path is asserted end-to-end here rather than only
    # by eyeballing the generated text.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "fresh")
      defer: removeDir(fx.scratch)

      let created = runShell(shellCommand(@[fx.reproBin, "workspace",
        "project", "new", "fresh-proj", "-m", "A brand new project.",
        "--workspace-root=" & fx.workspaceRoot]))
      if created.code != 0:
        checkpoint("output: " & created.output)
      check created.code == 0

      let freshProject = fx.workspaceRoot / "projects" / "fresh-proj.toml"
      let added = addRepo(fx, @["fresh-proj", "brand-new-lib",
        "--remote=https://git.example.invalid/acme/brand-new-lib.git"])
      if added.code != 0:
        checkpoint("output: " & added.output)
      check added.code == 0
      let resolved = resolveProject(freshProject)
      check resolved.repos.len == 1
      check resolved.repos[0].name == "brand-new-lib"
      check resolved.repos[0].projectRemote == "acme"
      check resolved.repos[0].fetchUrl ==
        "https://git.example.invalid/acme/brand-new-lib"
      # `project new` seeds `default_revision`, which the fragment inherits.
      check resolved.repos[0].revision == "main"

  test "test_repo_add_validates_an_explicit_revision_against_the_remote":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "revision")
      defer: removeDir(fx.scratch)

      # A real remote whose only branch is `dev` — the exact shape of the
      # reported failure, where `main` does not exist.
      let origins = fx.scratch / "origins"
      createDir(origins)
      let bare = origins / "pinned-lib"
      discard requireGit(q(gitBin) & " init --bare -b dev " & q(bare))
      let seed = fx.scratch / "seed"
      discard requireGit(q(gitBin) & " init -b dev " & q(seed))
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.name \"Manifest Tester\"")
      writeFile(seed / "README.md", "seed\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m seed")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push " & q(bare) &
        " dev")
      let url = "file://" & bare

      # A revision the remote does not have is REFUSED, not written.
      let bad = addRepo(fx, @["reprobuild", "pinned-lib",
        "--remote=" & url, "--revision=main"])
      check bad.code != 0
      check bad.output.contains("main")
      check not fileExists(fx.workspaceRoot / "repos" / "pinned-lib.toml")
      check not readFile(fx.projectFile).contains("pinned-lib")

      # A revision the remote does have is accepted and pinned.
      let good = addRepo(fx, @["reprobuild", "pinned-lib",
        "--remote=" & url, "--revision=dev"])
      if good.code != 0:
        checkpoint("output: " & good.output)
      check good.code == 0
      let fragment = readFile(fx.workspaceRoot / "repos" / "pinned-lib.toml")
      check fragment.contains("revision = \"dev\"")
      check revisionOf(fx.projectFile, "pinned-lib") == "dev"
      check fetchUrlOf(fx.projectFile, "pinned-lib") == url
