## ``repro health --fix`` says what it is about to do BEFORE it does it.
##
## The property (CLI/health.md §"Modes"; Interactive-UX-And-Progress
## Principle 1, "Announce before acting"): ``--fix`` is not scoped to one row.
## It runs every safe fix the diagnosis found, and one of them clones every
## missing sibling repository. So before its first action it prints the plan
## (which rows it will act on, and how many repositories it will clone, by
## name), and it prints each action's line before that action runs, not after
## all of them have finished.
##
## Why this is a test: the lines used to be collected and written only once
## every fix had completed. An operator who ran ``repro health --fix`` to move
## the workspace state file watched a silent terminal while it cloned every
## missing sibling, and the "announcement" arrived with the result
## (reprobuild-pm
## ``issues/2026-11-16-health-fix-clones-every-missing-sibling-when-run-to-migrate-the-state-file.md``).
##
## How it observes ordering: the production ``repro`` binary runs with its
## stdout redirected to a file, and a ``git`` earlier on ``PATH`` copies that
## file aside each time it is asked to ``clone``, then execs the real git.
## Each copy is therefore exactly what the operator had been shown at the
## moment a clone started.
##
## The one stand-in: that ``git`` wrapper. It is a probe, not a mock. It
## changes no argument and no result (it ``exec``s the real git with the same
## argv), and exists because "what had been printed when the clone began"
## cannot be read from outside the process any other way.
##
## Not run on Windows: the wrapper is a ``/bin/sh`` script. The behaviour it
## protects is platform-independent code.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string; cwd = ""): string =
  let res = execCmdEx(command, workingDir = cwd)
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

proc seedGitOrigin(gitBin, originPath, workPath: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Health Plan Tester\"")
  writeFile(workPath / "README.md", "fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")

const repoNames = ["lib-a", "lib-b", "lib-c"]

proc projectToml(scratch: string): string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"lib-a\"\n\n"
  for name in repoNames:
    result.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fileUrl(scratch / ("origin-" & name & ".git")) & "\"\n\n")
  result.add("includes = [\n")
  for name in repoNames:
    result.add("  \"repos/" & name & ".toml\",\n")
  result.add("]\n")

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"" & name &
    "-origin\"\nmainline = \"main\"\n"

const gitProbe = """#!/bin/sh
# Copy aside what `repro health` has printed so far, each time a clone starts,
# then run the real git unchanged.
for arg in "$@"; do
  if [ "$arg" = clone ]; then
    n=$(ls "$HEALTH_PLAN_SNAPSHOTS" | wc -l | tr -d ' ')
    cp "$HEALTH_PLAN_STDOUT" "$HEALTH_PLAN_SNAPSHOTS/at-clone-$n.txt"
    break
  fi
done
exec "$HEALTH_PLAN_REAL_GIT" "$@"
"""

suite "repro health --fix announces its plan before acting":

  test "the plan and each clone's line are on screen before that clone runs":
    let gitBin = findExe("git")
    when defined(windows):
      skip("the git probe is a /bin/sh script; the announced-before-acting " &
        "ordering is platform-independent code")
    else:
      if gitBin.len == 0:
        skip("git not on PATH; this case clones real repositories")
      else:
        let scratch = createTempDir("repro-health-plan-", "")
        defer: removeDir(scratch)
        let reproBin = reproBinary()
        for name in repoNames:
          seedGitOrigin(gitBin, scratch / ("origin-" & name & ".git"),
            scratch / ("seed-" & name))

        let workspaceRoot = scratch / "workspace"
        createDir(workspaceRoot / "projects")
        createDir(workspaceRoot / "repos")
        writeFile(workspaceRoot / "projects" / "lib-a.toml",
          projectToml(scratch))
        for name in repoNames:
          writeFile(workspaceRoot / "repos" / (name & ".toml"),
            fragmentToml(name))
        # lib-a is checked out; lib-b and lib-c are the missing siblings.
        discard requireGit(q(gitBin) & " clone " &
          q(fileUrl(scratch / "origin-lib-a.git")) & " " &
          q(workspaceRoot / "lib-a"))

        let probeDir = scratch / "probe-bin"
        let snapshots = scratch / "snapshots"
        let healthStdout = scratch / "health-stdout.txt"
        createDir(probeDir)
        createDir(snapshots)
        writeFile(probeDir / "git", gitProbe)
        setFilePermissions(probeDir / "git",
          {fpUserRead, fpUserWrite, fpUserExec})

        let res = runShell(shellCommand(
          ["/bin/sh", "-c",
           q(reproBin) & " health lib-a --fix --workspace-root=" &
             q(workspaceRoot) & " > " & q(healthStdout)],
          [("PATH", probeDir & $PathSep & getEnv("PATH")),
           ("HEALTH_PLAN_REAL_GIT", gitBin),
           ("HEALTH_PLAN_SNAPSHOTS", snapshots),
           ("HEALTH_PLAN_STDOUT", healthStdout)]))
        checkpoint("health --fix stderr/exit: " & $res.code & "\n" &
          res.output)
        let finalOut = readFile(healthStdout)
        checkpoint("health --fix stdout:\n" & finalOut)

        # The fix really ran, through the probe: two clones, both landed.
        check dirExists(workspaceRoot / "lib-b" / ".git")
        check dirExists(workspaceRoot / "lib-c" / ".git")
        check fileExists(snapshots / "at-clone-0.txt")
        check fileExists(snapshots / "at-clone-1.txt")

        # What the operator had been shown when the FIRST clone started.
        let atFirst = readFile(snapshots / "at-clone-0.txt")
        checkpoint("stdout when the first clone started:\n" & atFirst)
        check "fix: plan: " in atFirst
        check "siblings: clone 2 missing repositories" in atFirst
        check "lib-b, lib-c" in atFirst
        check "fix: cloning missing sibling lib-b" in atFirst
        check "(1/2)" in atFirst
        # ... and it is a mid-run view, not the finished report.
        check "fix: cloned lib-b" notin atFirst
        check "cloning missing sibling lib-c" notin atFirst

        # When the SECOND clone started: the first one's outcome, and the
        # second one's announcement.
        let atSecond = readFile(snapshots / "at-clone-1.txt")
        checkpoint("stdout when the second clone started:\n" & atSecond)
        check "fix: cloned lib-b" in atSecond
        check "fix: cloning missing sibling lib-c" in atSecond
        check "(2/2)" in atSecond

        # The finished report: the plan comes first, a summary closes the
        # multi-repository fix.
        let planAt = finalOut.find("fix: plan: ")
        let firstCloneAt = finalOut.find("fix: cloning missing sibling")
        check planAt >= 0
        check firstCloneAt > planAt
        # No fix line of any row comes before the plan: a plan printed just
        # ahead of the clones, after other rows' fixes ran, is not a plan.
        # (This workspace has no state file, so the one fix that precedes
        # the diagnosis prints nothing.)
        check finalOut.find("fix: ") == planAt
        check "fix: siblings: cloned 2, failed 0" in finalOut

  test "with no missing sibling the plan promises no clone":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case clones real repositories")
    else:
      let scratch = createTempDir("repro-health-noplan-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      for name in repoNames:
        seedGitOrigin(gitBin, scratch / ("origin-" & name & ".git"),
          scratch / ("seed-" & name))
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      writeFile(workspaceRoot / "projects" / "lib-a.toml",
        projectToml(scratch))
      for name in repoNames:
        writeFile(workspaceRoot / "repos" / (name & ".toml"),
          fragmentToml(name))
        discard requireGit(q(gitBin) & " clone " &
          q(fileUrl(scratch / ("origin-" & name & ".git"))) & " " &
          q(workspaceRoot / name))

      let res = runShell(shellCommand([reproBin, "health", "lib-a", "--fix",
        "--workspace-root=" & workspaceRoot]))
      checkpoint(res.output)
      # The command ran and diagnosed (a binary that could not start would
      # satisfy the two absences below).
      check "siblings" in res.output
      # No missing sibling: the plan must not promise a clone.
      check "siblings: clone" notin res.output
      check "cloning missing sibling" notin res.output
      check "fix: siblings: cloned" notin res.output
