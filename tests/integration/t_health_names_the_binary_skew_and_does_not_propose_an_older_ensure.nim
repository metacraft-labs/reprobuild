## PG-14 — ``repro health`` names the binary skew, and its remedy is NOT
## ``hooks ensure``.
##
## The state being diagnosed, measured 2026-10-01 (spec §1.6b): 770 managed hook
## bodies across 154 repos of one workspace demand one of five contract tokens,
## uniformly — and whether the resolved ``repro`` services that demand depends on
## **which shell the hook fires in**. ``5rf6zm4a…`` (0.1.3, bare ``PATH``)
## refuses; ``r9dxqdl0…`` (0.1.3, workspace-root ``.direnv``), ``2ra9q1gh…``
## (0.1.3, ``codetracer/.direnv``) and ``0lc7zyrm…`` (0.2.2, nix profile) all
## answer. **The discriminator is the store path, not the version**, so a
## diagnosis that prints "repro 0.1.3" is not merely unhelpful — it is actively
## misleading, and §1.6c measures that ``health`` today scores *both* outcomes
## ``ok``.
##
## Two obligations, and this suite is the mutation guard for each.
##
##   (A) The check must report a non-``ok`` status that NAMES BOTH BUILDS — the
##       one that wrote the installed bodies (the body advertises it) and the one
##       a hook would resolve to run them — with their paths.
##   (B) THE REMEDY MUST NOT BE A BARE ``hooks ensure --vcs``. **Mutation-
##       verified: this arm fails against today's remedy, which is exactly
##       that** — the ``vcs-hooks`` row's remedy is ``<self> hooks ensure --vcs
##       <workspaceRoot>``, and reusing it here would hand the operator the one
##       command the hook body's own text warns against: *"Do NOT run `repro
##       hooks ensure` with it: that rewrites this file with its own older body,
##       the contract line disappears, and you silence this message instead of
##       fixing it."* The same command runs ambiently from the generated
##       ``.envrc`` on every directory entry with its output discarded, so a
##       remedy pointing at it is a remedy that races the ambient command to
##       delete its own evidence. The remedy must reconcile what SUPPLIES
##       ``repro``: ``direnv reload``, then the pin.
##
##   (C) The check must say WHICH SHELL'S RESOLUTION it used, and must not
##       present a per-shell answer as a machine-wide one.
##
##   (D) CONTROL — with the writer and the runner the same binary, the row is
##       ``ok``. Without this arm a check hardcoded to ``fail`` would pass (A).
##
## The fixture uses a STUB ``repro`` as the resolved runner, for the reason the
## sibling suites give: the defect is about a binary this workspace did not build
## (seventeen reprobuild store paths exist on the measured host) and no second
## real build can be produced hermetically. The stub is behavioural — it answers
## the handshake exactly as a build predating the flag does. The hooks, the real
## binary, git and ``health`` itself are all real.
##
## Hermetic: one ``createTempDir``, local bares only, no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

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

type
  Fixture = object
    scratch: string
    workspaceRoot: string
    repoPath: string
    reproBin: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-pg14-health-" & slug & "-", "")
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
  # Install the REAL managed hooks with the REAL binary, so there is a
  # contract-bearing body on disk for the check to be about. Without an
  # installed demand the question "does the resolved repro service these
  # hooks?" has no subject.
  let ensured = runShell(shellCommand(@[
    result.reproBin, "hooks", "ensure", "--vcs", result.workspaceRoot]))
  checkpoint("hooks ensure: " & ensured.output)
  doAssert ensured.code == 0, "fixture could not install managed hooks"
  let managed = result.repoPath / ".git" / "hooks" / "post-commit.repro-managed"
  doAssert fileExists(managed), "fixture installed no managed post-commit"
  doAssert "--hook-contract=" in readFile(managed),
    "fixture's managed body carries no contract token; (A)-(D) prove nothing"

proc writeStaleStub(path: string) =
  ## A ``repro`` that predates the handshake: answers the bare ``--require=2``
  ## probe and rejects the flag it has never heard of. Its ``--version`` is
  ## deliberately the SAME string two servicing builds report on the measured
  ## host, so a check that leant on the version could not tell them apart.
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

suite "PG-14 — health names the binary skew and proposes no older ensure":

  test "t_health_names_the_binary_skew_and_does_not_propose_an_older_ensure":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real repositories carrying " &
        "installed managed hooks for `health` to have a subject")
    else:
      let fx = setupFixture(gitBin, "skew")
      defer: removeDir(fx.scratch)

      let staleStub = fx.scratch / "stale-repro"
      writeStaleStub(staleStub)

      let res = invokeHealth(fx, staleStub)
      checkpoint("health --json output:\n" & res.output)
      let report = parseJson(res.output)
      let row = findCheck(report, "hook-interpreter")
      check not row.isNil
      let status = row["status"].getStr()
      let detail = row["detail"].getStr()
      let remedy = row["remedy"].getStr()
      checkpoint("hook-interpreter: status=" & status & "\ndetail=" & detail &
        "\nremedy=" & remedy)

      # (A) non-ok, and BOTH builds named: the runner that cannot service the
      # contract, and the build that wrote the installed bodies.
      check status != "ok"
      check staleStub in detail
      check engineBinary() in detail
      # How the runner was resolved is part of the finding, because that is
      # what differs between two shells on one machine.
      check "REPROBUILD_REPRO" in detail

      # (B) THE MUTATION GUARD. Today's remedy for the neighbouring row is
      # ``<self> hooks ensure --vcs <workspaceRoot>``; reusing it here is the
      # specific regression this arm exists to catch.
      check remedy.len > 0
      check "hooks ensure" notin remedy
      check (fx.reproBin & " hooks ensure --vcs " & fx.workspaceRoot) != remedy
      check "ensure" notin remedy
      # The remedy reconciles what SUPPLIES repro.
      check "direnv reload" in remedy

      # (C) it says which shell's resolution it used, and does not pass that
      # off as a statement about the machine.
      check "THIS shell" in detail

      # Principle 2 — a non-ok row carries a remedy, and the overall exit
      # status reflects the failure rather than hiding it.
      if status == "fail":
        check res.code != 0

      # (D) CONTROL: writer and runner are one build → the row is ok. This is
      # what stops (A) being satisfied by a check wired to fail.
      let control = invokeHealth(fx, fx.reproBin)
      checkpoint("control health output:\n" & control.output)
      let controlRow = findCheck(parseJson(control.output), "hook-interpreter")
      check not controlRow.isNil
      check controlRow["status"].getStr() == "ok"
      check controlRow["remedy"].getStr().len == 0
      # Even when green it refuses to overstate: the answer is about the
      # resolutions it probed, not about every shell on the machine.
      check "not about every shell" in controlRow["detail"].getStr()
