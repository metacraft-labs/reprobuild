## PG-14 — when two of this host's ``repro`` resolutions disagree about the
## managed-hook contract, ``repro health`` reports THE DISAGREEMENT, not
## whichever one it happened to resolve.
##
## This is the arm that cannot be satisfied by the implementation an author
## writes first. Measured 2026-10-01 (spec §1.6b): the same ``git commit`` in the
## same repo dispatches inside a loaded dev shell and refuses in a bare-``PATH``
## shell, because the generated body's ``find_repro_cmd`` takes the first
## ``repro`` on ``PATH`` and direnv changes what that is. So the question *"does
## this machine's ``repro`` service these hooks?"* **has no machine-wide answer**
## — it has one answer per shell, and ``repro health`` run in either shell
## reports its own answer as the truth without noting that the other exists.
##
## **Must FAIL against an implementation that probes only its own ``PATH`` —
## which is what ships today.** Such an implementation sees the servicing
## resolution this fixture installs as ``REPROBUILD_REPRO``, reports ``ok``, and
## fails every assertion below. §7.7's exit condition 3 is precisely this:
## ``health`` "reports a *disagreement* between resolutions when one exists",
## and the condition is what makes the enumerated shell list in condition 1 a
## finite list rather than a dodge — enumerating shells is unbounded (an editor
## subprocess, a CI step, a cron job and an agent harness each have their own
## environment), so one tool that NOTICES a disagreement beats enumerating them
## forever.
##
## How the second resolution is produced, and why this way. Reprobuild's own
## enumeration reads the store paths out of direnv's profile ``.rc`` files —
## that is how §1.6b's measurement was taken (``grep -o
## '/nix/store/[a-z0-9]*-reprobuild-[0-9.]*'`` over the ``.rc``), and it needs
## neither a shell entry nor a flake evaluation. The fixture therefore builds a
## store-shaped tree of its own and an ``.rc`` that exports it. A test cannot
## write into the host's real ``/nix/store``, which is exactly why the store-path
## scanner recovers the store ROOT rather than assuming ``/nix/store``: a
## scanner that hard-coded the prefix could only be exercised on the machine it
## ran on.
##
## Assertions:
##
##   (A) status is non-``ok`` and the detail says the resolutions DISAGREE —
##       not "ok" (the servicing one won) and not a flat "skew" (both refuse).
##   (B) BOTH resolutions are named, each with how it was resolved, and the
##       store-path-bearing one is named BY ITS STORE PATH — the version is not
##       the discriminator, and printing it alone is what §1.6b calls actively
##       misleading.
##   (C) The row still says which resolution THIS shell would use, so a reader
##       can tell what their own next ``git commit`` will do — without that
##       being presented as the machine's answer.
##   (D) The remedy reconciles what SUPPLIES ``repro`` and never proposes
##       ``hooks ensure``.
##   (E) CONTROL — remove the disagreeing ``.rc`` and the row goes back to
##       ``ok``. So (A) is caused by the second resolution and not by the
##       fixture being broken in some other way.
##
## Hermetic: one ``createTempDir``; a fixture-local store tree; no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_core/cli_images
import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
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

proc engineBinary(): string =
  ## The FULL CLI image. ``repro`` on PATH is the thin daemon client and it
  ## ``execv``s this one, so ``getAppFilename()`` inside every diagnostic below
  ## is THIS path — asserting on the thin client's path would be asserting on a
  ## process that no longer exists by the time the message is written.
  requireBinary(repoRoot() / "build" / "bin" / reprobuildEngineExeName(),
    "reprobuild.apps.repro")

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "lib-a"
default_revision = "main"
trunk = "main"

[[remote]]
name = "lib-a-origin"
fetch = "LIB_A_URL"

includes = [
  "repos/lib-a.toml",
]
"""

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

# A store-shaped base name: ``<hash>-<name>``. The name carries the
# ``reprobuild-`` prefix the enumeration filters on, and the hash is the right
# shape without pretending to be a real one.
const fakeStoreBase = "0000000000000000000000000000000a-reprobuild-0.0.1"

proc seedOrigin(gitBin, originPath, seedPath: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.name \"PG14 Tester\"")
  writeFile(seedPath / "README.md", "PG-14 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")

proc writeRefusingStub(path: string) =
  ## A ``repro`` that predates the handshake. Reports a version string that
  ## SERVICING builds also report on the measured host, so a check that leant
  ## on the version could not separate it from the one that answers.
  createDir(parentDir(path))
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  if [ \"$#\" -eq 3 ] && [ \"${3:-}\" = \"--require=2\" ]; then\n" &
    "    echo 2\n" &
    "    exit 0\n" &
    "  fi\n" &
    "  echo \"repro hooks protocol requires exactly --require=2\" >&2\n" &
    "  exit 1\n" &
    "fi\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'repro 0.1.3'; exit 0; fi\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

type
  Fixture = object
    scratch: string
    workspaceRoot: string
    repoPath: string
    reproBin: string
    fakeStorePath: string
    rcPath: string

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-pg14-disagree-", "")
  result.reproBin = reproBinary()
  let origin = result.scratch / "origin-lib-a.git"
  seedOrigin(gitBin, origin, result.scratch / "seed-lib-a")

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

  # Real managed hooks from the real binary: the installed bodies are the
  # demand both resolutions are judged against.
  let ensured = runShell(shellCommand(@[
    result.reproBin, "hooks", "ensure", "--vcs", result.workspaceRoot]))
  checkpoint("hooks ensure: " & ensured.output)
  doAssert ensured.code == 0, "fixture could not install managed hooks"
  doAssert "--hook-contract=" in readFile(
    result.repoPath / ".git" / "hooks" / "post-commit.repro-managed"),
    "fixture's managed body carries no contract token"

  # The SECOND resolution: a store-shaped tree holding a refusing build, and a
  # direnv profile ``.rc`` that exports it — the artefact direnv itself writes
  # and the one §1.6b's enumeration reads.
  result.fakeStorePath = result.scratch / "fake-root" / "nix" / "store" /
    fakeStoreBase
  writeRefusingStub(result.fakeStorePath / "bin" /
    addFileExt("repro", ExeExt))
  createDir(result.repoPath / ".direnv")
  result.rcPath = result.repoPath / ".direnv" / "flake-profile-pg14.rc"
  writeFile(result.rcPath,
    "# direnv profile fixture\n" &
    "export PATH=\"" & result.fakeStorePath / "bin" & ":$PATH\"\n")

proc invokeHealth(fx: Fixture; runner: string): CmdResult =
  runShell(shellCommand(
    @[fx.reproBin, "health", "lib-a", "--json",
      "--workspace-root=" & fx.workspaceRoot],
    @[(name: "REPROBUILD_REPRO", value: runner)]))

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  nil

suite "PG-14 — health reports a disagreement between two repro resolutions":

  test "t_health_reports_a_disagreement_between_two_repro_resolutions":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real repositories carrying " &
        "installed managed hooks for two resolutions to disagree about")
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      # THIS shell resolves a build that SERVICES the installed contract. An
      # implementation that probed only its own resolution would stop here and
      # report ok.
      let res = invokeHealth(fx, fx.reproBin)
      checkpoint("health --json output:\n" & res.output)
      let row = findCheck(parseJson(res.output), "hook-interpreter")
      check not row.isNil
      let status = row["status"].getStr()
      let detail = row["detail"].getStr()
      let remedy = row["remedy"].getStr()
      checkpoint("hook-interpreter: status=" & status & "\ndetail=" & detail &
        "\nremedy=" & remedy)

      # (A) the disagreement is the finding.
      check status != "ok"
      check "DISAGREE" in detail

      # (B) both resolutions named; the store-bearing one by its STORE PATH.
      check engineBinary() in detail
      check fakeStoreBase in detail
      check "[store " in detail
      check ("direnv dev shell at " & fx.repoPath) in detail
      # The version is reported, and explicitly NOT as the discriminator —
      # both of this fixture's builds could report the same one.
      check "STORE PATH, not the version" in detail

      # (C) which resolution THIS shell would use is still stated, as one row
      # among several rather than as the machine's answer.
      check "THIS shell" in detail
      check "per-shell" in detail

      # (D) the remedy reconciles the supply, and never proposes the command
      # that deletes the diagnostic.
      check remedy.len > 0
      check "hooks ensure" notin remedy
      check "direnv reload" in remedy

      # (E) CONTROL: with the second resolution gone the row is ok again, so
      # the disagreement above was caused by it.
      removeFile(fx.rcPath)
      let control = invokeHealth(fx, fx.reproBin)
      checkpoint("control health output:\n" & control.output)
      let controlRow = findCheck(parseJson(control.output), "hook-interpreter")
      check not controlRow.isNil
      check controlRow["status"].getStr() == "ok"
