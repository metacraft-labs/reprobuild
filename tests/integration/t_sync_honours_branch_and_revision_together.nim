## A repo fragment may declare BOTH `branch` and `revision`, and the two are
## not in competition: `branch` is what the repo TRACKS, `revision` is where it
## SITS.
##
## For most repos only the first belongs in the manifest, because the second is
## recorded — more completely — by the lock that covers the repo. The case that
## needs both is a read-only third-party source tree vendored for reference: it
## appears in no dependency graph, so no lock covers it, and a fragment naming
## only a branch leaves the checkout floating on whatever the upstream tip
## happens to be that day. Naming both says "track `main`, and sit at this
## commit until someone deliberately moves it".
##
## The defect this pins down: `branch` did not take precedence over `revision`,
## it OVERWROTE it — a fragment carrying both resolved to `revision = "main"`
## and the SHA never reached `ResolvedRepo`, the sync planner, or the lock
## writer. The manifest would then RECORD a pin without BINDING it, which is
## worse than not writing one, because the fragment reads as protected while
## the checkout floats.
##
## Asserted:
##   1. A fragment declaring both resolves `branch` to the branch name and
##      `revision` to the SHA — neither field clobbers the other.
##   2. Sync lands the checkout on exactly that commit, NOT on the branch tip.
##      This is the half that matters: a resolution-only assertion would still
##      pass if the planner ignored the value, and the planner is what actually
##      decides where the working tree ends up. Falsifiable — against the
##      pre-fix build the checkout lands on the tip and the HEAD comparison
##      fails.
##   3. A fragment declaring only `branch` still resolves `revision` to the
##      branch name, so a branch-only fragment keeps producing a legal
##      `git clone --branch` argument. This is the regression guard for the
##      behaviour the fix had to preserve.
##
## No mocks: real `git init --bare` upstreams, the real resolver, and the
## engine-built `build/bin/repro` driving a real clone.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string): string =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  ## Two commits on `main`; returns the FIRST commit's sha. Pinning the first
  ## commit is what makes "landed on the pin" distinguishable from "landed on
  ## the branch tip" — pinning the tip would pass either way.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Pin Tester\"")
  writeFile(workPath / "first.txt", "first\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add first.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m first")
  let pinned = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()
  writeFile(workPath / "second.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add second.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m second")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  pinned

proc writeFragment(workspaceRoot, name, remote, branch, revision: string) =
  writeFile(workspaceRoot / "repos" / (name & ".toml"),
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\n" &
    (if branch.len > 0: "branch = \"" & branch & "\"\n" else: "") &
    (if revision.len > 0: "revision = \"" & revision & "\"\n" else: ""))

proc writeProject(workspaceRoot, remoteName, fetchUrl: string;
                  includes: openArray[string]) =
  var body = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"vendored\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"" & remoteName & "\"\nfetch = \"" & fetchUrl &
    "\"\n\n" &
    "includes = [\n"
  for inc in includes:
    body.add("  \"" & inc & "\",\n")
  body.add("]\n")
  writeFile(workspaceRoot / "projects" / "vendored.toml", body)

proc findRepo(resolved: ResolvedProject; path: string): ResolvedRepo =
  for repo in resolved.repos:
    if repo.path == path:
      return repo
  checkpoint("no resolved repo at path '" & path & "'")
  fail()

suite "a fragment may track a branch AND sit at a pinned commit":

  test "t_branch_and_revision_resolve_to_different_fields":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pinboth-resolve-", "")
      defer: removeDir(scratch)
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")

      let origin = scratch / "origin-vendored-lib.git"
      let pinned = seedOrigin(gitBin, origin, scratch / "seed-vendored-lib")

      # The vendored-reference shape: tracks `main`, sits at an explicit commit.
      writeFragment(workspaceRoot, "vendored-lib", "vendored-origin",
        branch = "main", revision = pinned)
      # ...and a branch-only sibling, so the regression guard travels with the
      # case it guards rather than in a separate fixture that could drift.
      writeFragment(workspaceRoot, "tracking-lib", "vendored-origin",
        branch = "main", revision = "")
      writeProject(workspaceRoot, "vendored-origin", fileUrl(origin),
        ["repos/vendored-lib.toml", "repos/tracking-lib.toml"])

      let resolved = resolveProject(
        workspaceRoot / "projects" / "vendored.toml")

      let vendored = findRepo(resolved, "vendored-lib")
      check vendored.branch == "main"
      # The SHA survives. Before the fix this was "main" and the pin was gone
      # by the time anything downstream could act on it.
      check vendored.revision == pinned
      check vendored.revision != "main"

      # Branch-only is unchanged: `branch` still supplies `revision` when the
      # fragment pinned nothing, so it stays a legal `--branch` argument.
      let tracking = findRepo(resolved, "tracking-lib")
      check tracking.branch == "main"
      check tracking.revision == "main"

  test "t_sync_lands_on_the_pinned_commit_not_the_branch_tip":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pinboth-sync-", "")
      defer: removeDir(scratch)
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")

      let origin = scratch / "origin-vendored-lib.git"
      let pinned = seedOrigin(gitBin, origin, scratch / "seed-vendored-lib")
      let tip = requireGit(q(gitBin) & " -C " &
        q(scratch / "seed-vendored-lib") & " rev-parse HEAD").strip()
      check tip != pinned

      writeFragment(workspaceRoot, "vendored-lib", "vendored-origin",
        branch = "main", revision = pinned)
      writeProject(workspaceRoot, "vendored-origin", fileUrl(origin),
        ["repos/vendored-lib.toml"])

      let res = runShell(shellCommand(@[reproBinary(), "workspace", "enable",
        "vendored", "--workspace-root=" & workspaceRoot]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      check dirExists(workspaceRoot / "vendored-lib" / ".git")
      let head = requireGit(q(gitBin) & " -C " &
        q(workspaceRoot / "vendored-lib") & " rev-parse HEAD").strip()
      # The property the manifest was trying to express. Against the pre-fix
      # build this is `tip`: the pin resolved to the branch name, so the clone
      # landed wherever the branch pointed.
      check head == pinned
      check head != tip
      check fileExists(workspaceRoot / "vendored-lib" / "first.txt")
      check not fileExists(workspaceRoot / "vendored-lib" / "second.txt")
