## `repro workspace repos add` writes manifest entries that match the
## hand-written ones: it REUSES the MOST SPECIFIC declared `[[remote]]` base
## that prefixes the requested URL (putting whatever path remains in
## `[repo].name`), mints at most ONE reusable org-named remote when no declared
## base does, and never guesses a `revision`.
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
## The same reuse rule has to reproduce the THIRD-PARTY shape as well —
## `repos/llvm-project.toml` carries `remote = "github"` (the generic
## `https://github.com` base) with the full server-side path
## `llvm/llvm-project` as its `name` — so that case is asserted alongside,
## against the same project manifest that declares both bases.
##
## MOCKS: none. The test drives the real `repro` binary against a real git
## manifest repo on a real filesystem, and reads the results back through the
## real manifest resolver (`resolveProject`) rather than re-implementing its
## semantics. The two URL families used for the remote-reuse cases are
## unreachable network URLs on purpose — `repos add` is a manifest
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

# The hand-written THIRD-PARTY shape (`repos/llvm-project.toml`,
# `repos/0install.toml`, `repos/BuildXL.toml` in this repo's own manifest set):
# the project declares no `llvm` org base, so the repo goes through the generic
# `github` base and the org segment travels in `[repo].name` — the server-side
# path — while `path` stays the local checkout dir. Identical to the real file
# except for its nested `path` (which `repos add` derives from the
# `<repo>` argument) and its pinned `revision` (this project has a
# `default_revision` to inherit).
const thirdPartyFragment = """schema = "reprobuild.workspace.repo.v1"

[repo]
name = "llvm/llvm-project"
path = "llvm-project"
remote = "github"
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
  ## WV-4 — the project moved from a positional to a repeatable `--project`
  ## flag (a fragment is declared once and included by any number of projects).
  ## The call sites still read `<project> <repo> …`, so translate the first
  ## element here rather than at every one of them.
  var argv = @[fx.reproBin, "workspace", "repos", "add"]
  for i, e in extra:
    if i == 0: argv.add("--project=" & e)
    else: argv.add(e)
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

proc checkoutPathOf(projectFile, repoName: string): string =
  for repo in resolveProject(projectFile).repos:
    if repo.name == repoName: return repo.path
  ""

proc remoteOf(projectFile, repoName: string): string =
  for repo in resolveProject(projectFile).repos:
    if repo.name == repoName: return repo.projectRemote
  ""

suite "repro workspace repos add — remote reuse and revision inheritance":

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

      # The generic `github` base ALSO serves this URL (it prefixes it), but
      # it is less specific: picking it would have written
      # `name = "metacraft-labs/nim-shm-lease"`, which is not how the
      # first-party siblings are written. The most specific base wins.
      check generated.contains("name = \"nim-shm-lease\"")
      check not generated.contains("metacraft-labs/nim-shm-lease")

      # DEFECT 2: with no `revision` key the repo inherits `default_revision`,
      # and the composed clone URL is the one that was requested.
      check revisionOf(fx.projectFile, "nim-shm-lease") == "dev"
      check fetchUrlOf(fx.projectFile, "nim-shm-lease") ==
        "https://github.com/metacraft-labs/nim-shm-lease"

      # No description file was requested, so the command says so rather than
      # silently leaving the generated project docs without an entry.
      check res.output.contains("repos/nim-shm-lease.md")
      check not fileExists(fx.workspaceRoot / "repos" / "nim-shm-lease.md")

  test "test_repo_add_reuses_the_generic_host_base_and_keeps_the_org_in_name":
    # The third-party family: no `llvm` org base is declared, but `github` →
    # `https://github.com` is, and it prefixes the URL. The convention (and
    # the hand-written `repos/llvm-project.toml`) is to use that base and put
    # the remaining server-side path — `llvm/llvm-project` — in `[repo].name`,
    # NOT to mint a new `llvm` remote next to the two github ones the project
    # already declares.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "hostbase")
      defer: removeDir(fx.scratch)

      let remotesBefore = countRemotes(fx.projectFile)
      let res = addRepo(fx, @["reprobuild", "llvm-project",
        "--remote=https://github.com/llvm/llvm-project.git"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      check readFile(fx.workspaceRoot / "repos" / "llvm-project.toml") ==
        thirdPartyFragment

      # Nothing was appended to the shared remote table: no `llvm` org remote,
      # no single-use `llvm-project-origin`.
      let projectText = readFile(fx.projectFile)
      check countRemotes(fx.projectFile) == remotesBefore
      check not projectText.contains("name = \"llvm\"")
      check not projectText.contains("llvm-project-origin")
      check projectText.contains("\"repos/llvm-project.toml\"")
      check res.output.contains("(reused)")

      # Round-trip through the real resolver: the composed clone URL is the
      # one that was requested, the checkout dir is still the `<repo>`
      # argument, and the revision is inherited rather than pinned.
      check remoteOf(fx.projectFile, "llvm/llvm-project") == "github"
      check fetchUrlOf(fx.projectFile, "llvm/llvm-project") ==
        "https://github.com/llvm/llvm-project"
      check checkoutPathOf(fx.projectFile, "llvm/llvm-project") ==
        "llvm-project"
      check revisionOf(fx.projectFile, "llvm/llvm-project") == "dev"

  test "test_repo_add_mints_one_org_named_remote_that_the_next_repo_reuses":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "mint")
      defer: removeDir(fx.scratch)

      # A host the project declares NO base for — neither `https://github.com`
      # nor the org base prefixes this URL — so reuse cannot apply and exactly
      # one new remote is minted.
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
    # `projects add` + `repos add` must leave a manifest the RESOLVER
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
        "projects", "add", "fresh-proj", "-m", "A brand new project.",
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
