## Unified-Locking-And-Hooks.md §8.4 — "Public-only workspace, no declared
## manifest route".
##
## §10 ("No implicit team route", DECIDED) is explicit: "The route is EXPLICIT,
## not inferred from the manifest's presence. A workspace that never declares a
## team route is public-only and writes only `repro.lock`." Before this test the
## gate resolved its lock store to ``<workspaceRoot>/.repro/manifests``
## UNCONDITIONALLY, so a workspace that had never declared any route still:
##
##   * materialized ``.repro/manifests/locks/<project>/<repo>/<sha>.toml`` — a
##     lock record inside a gitignored, non-git directory nobody can publish; and
##   * reported "lock publish skipped: … is not a git checkout; cannot publish
##     lock" for a publish that should never have been attempted at all.
##
## The unconditional fallback also made every ``manifestLayerRoot.len > 0``
## guard permanently true, including the HL-3 guard documented as firing "ONLY
## when a `.repro/manifests` git-checkout is present".
##
## This test pins the corrected contract for the default all-public workspace:
## the gate passes, writes NO manifest lock anywhere, and stays silent about
## publishing. Publication for a public repo is the repo's own git push carrying
## its in-tree ``repro.lock`` (§8.2 public row).
##
## No mocks: a real hermetic workspace on the real filesystem, driven through the
## real ``build/bin/repro`` binary and real ``git``.
##
## Skip rule: ``git`` missing on PATH.

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

proc projectToml(libAUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

suite "pre-push — public-only workspace writes no manifest lock":
  let gitBin = findExe("git")

  test "no declared route: gate passes, no locks/ tree, no publish diagnostic":
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-public-only-lock-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # A published, clean lib-a whose origin is a real bare repo.
      let origin = scratch / "origin-lib-a.git"
      let seed = scratch / "seed-lib-a"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(seed))
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.name \"Public Only Tester\"")
      writeFile(seed / "README.md", "public-only fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m fixture")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " remote add origin " &
        q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

      # The workspace declares NO [[manifest]] layer and its `.repro/manifests`
      # is not a git checkout — the default public-only shape.
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let manifestsRoot = workspaceRoot / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "lib-a.toml",
        projectToml(fileUrl(origin)))
      writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
        q(workspaceRoot / "lib-a"))
      writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

      let res = runCmd(q(reproBin) & " check --mode=pre-push" &
        " --workspace-root=" & q(workspaceRoot) &
        " --current-repo=" & q(workspaceRoot / "lib-a"))

      check res.code == 0

      # The load-bearing assertion: no lock record was synthesized under a
      # store the workspace never declared.
      check not dirExists(manifestsRoot / "locks")

      # ...and the gate does not talk about publishing a lock it should never
      # have tried to publish.
      check "cannot publish lock" notin res.output
      check "lock publish skipped" notin res.output
