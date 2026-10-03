## PG-14 / spec §7.6.5 — the gateway migration sweep REFUSES, workspace-wide,
## when the ``repro`` that would write a gateway's hooks is not the ``repro``
## that will run them.
##
## Why a workspace-level refusal in a design that is otherwise per-repo
## independent (§7.6.4: no abort on first failure, no rollback, the answer is a
## count with its residue): **binary skew is a property of the machine**, not of
## any repo, and it is identically fatal for all of them. Measured on the host
## this was written for (§1.6b): 770 managed hook bodies across 154 repos demand
## one of five contract tokens, uniformly, and whether the resolved ``repro``
## services that demand depends on **which shell the hook fires in** — three
## 0.1.3 builds disagree about the flag, so the version string partitions
## nothing and the discriminator is the store path.
##
## Wiring under that condition does not convert "no gate" into "a gate". It
## converts "no gate" into "a gate that appears to work and does not": the
## wired repo now *looks* governed, serving either fails closed on every push
## or fails open on every push, and §1.6c measures ``repro health`` scoring
## exactly that state ``ok``.
##
## What each assertion pins, and how it is falsifiable:
##
##   (A) REFUSAL, not advice. Exit status is non-zero. An advisory check — a
##       warning followed by the sweep — fails here.
##   (B) ZERO ``pushurl`` writes ANYWHERE. Every git repo under the fixture is
##       interrogated for ``remote.origin.pushurl`` afterwards. A skew check
##       evaluated per repo *after* the first wiring leaves repo 1 wired and
##       fails this, which is the specific ordering mistake §7.6.5 names ("once
##       before any", not "once per repo").
##   (C) BOTH BUILDS NAMED, by path, with how each was resolved — the writer
##       (this build) and the runner (the stub). A diagnostic naming only one of
##       them leaves the operator unable to tell which install produced the
##       demand.
##   (D) The remedy does NOT propose ``hooks ensure``. That is the command the
##       generated hook body's own text warns against ("that rewrites this file
##       with its own older body, the contract line disappears, and you silence
##       this message instead of fixing it") and the command the generated
##       ``.envrc`` runs ambiently on every directory entry with its output
##       discarded.
##   (E) BOTH SKEW ARMS refuse, and the predicate is "does not speak the
##       handshake", never "is older": a stub that *speaks* the handshake and
##       answers a DIFFERENT contract (probe exit 3) is just as much a
##       writer/runner mismatch as one that rejects the flag outright (exit 1).
##   (F) CONTROL — with writer and runner the SAME binary, the sweep proceeds
##       and DOES write a ``pushurl``. Without this arm (B) would be satisfied
##       by a sweep that can never write anything, and the test would prove
##       nothing.
##
## The fixture uses a STUB ``repro`` as the runner. Justified, and justified
## narrowly: the defect is specifically about a binary this workspace did NOT
## build — seventeen reprobuild store paths exist on the host this was measured
## on — and no second real build can be produced hermetically inside a test.
## The stub is behavioural rather than a mock of an interface: it answers the
## handshake exactly as an older CLI does (rejecting a flag it predates) or as a
## sibling build does (confirming the flag, naming a different token). Every
## other participant is real: the real ``repro``, real git repos, real remotes,
## the real sweep.
##
## Hermetic: one ``createTempDir``; local bares only; ``REPRO_WORKSPACE_CLONES``
## points the cache (and therefore the gateway tree) inside the fixture, so
## nothing touches the operator's ``~/.cache``. No network.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core/cli_images
import repro_test_support

proc q(value: string): string = quoteShell(value)
# For text that goes INTO an ``sh`` script. ``quoteShell`` quotes for the
# HOST's command line (cmd.exe rules on Windows, which leave ``C:\...`` bare),
# and ``sh`` then eats every backslash.
proc qsh(value: string): string = quoteShellPosix(value)

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

[[remote]]
name = "lib-b-origin"
fetch = "LIB_B_URL"

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
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

proc seedOrigin(gitBin, originPath, seedPath, branch: string) =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(seedPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.name \"PG14 Tester\"")
  writeFile(seedPath / "README.md", "PG-14 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin " &
    branch)

type
  Fixture = object
    scratch: string
    workspaceRoot: string
    reproBin: string
    repoPaths: seq[string]

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-pg14-migrate-", "")
  result.reproBin = reproBinary()
  let originA = result.scratch / "origin-lib-a.git"
  let originB = result.scratch / "origin-lib-b.git"
  seedOrigin(gitBin, originA, result.scratch / "seed-lib-a", "main")
  seedOrigin(gitBin, originB, result.scratch / "seed-lib-b", "main")

  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  # The ``.repro/`` shell is what makes this an initialized workspace rather
  # than a directory that merely holds manifest-shaped data.
  createDir(result.workspaceRoot / ".repro")
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectToml
      .replace("LIB_A_URL", fileUrl(originA))
      .replace("LIB_B_URL", fileUrl(originB)))
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(result.workspaceRoot / "repos" / "lib-b.toml", libBFragmentToml)

  # Both repos materialized, each with a real ``remote.origin.url`` — the thing
  # migration reads to decide what the gateway forwards to.
  for name, origin in {"lib-a": originA, "lib-b": originB}.items:
    let target = result.workspaceRoot / name
    discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
      q(target))
    result.repoPaths.add(target)

proc writeStaleStub(path, marker: string) =
  ## A ``repro`` that PREDATES the handshake: it answers the bare
  ## ``--require=2`` probe (as every v2-era build does) and rejects the flag it
  ## has never heard of. Records any other invocation so the test can prove the
  ## sweep never asked it to do work.
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
    "echo \"stale-stub:$*\" >> " & qsh(marker) & "\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc writeDifferentContractStub(path, marker: string) =
  ## A ``repro`` that SPEAKS the handshake and answers a DIFFERENT contract:
  ## exit 3, the status reserved for "I understand this handshake and simply
  ## generate another body". This is the arm a version comparison gets wrong —
  ## the stub is not old, it is not the writer.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  for arg in \"$@\"; do\n" &
    "    case \"$arg\" in\n" &
    "      --hook-contract=*)\n" &
    "        echo \"repro hooks: this build generates \" \\\n" &
    "          \"'reprobuild.managed-hook.v1.post-commit.deadbeefdeadbeef'\" >&2\n" &
    "        exit 3\n" &
    "        ;;\n" &
    "    esac\n" &
    "  done\n" &
    "  echo 2\n" &
    "  exit 0\n" &
    "fi\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'repro 0.2.9'; exit 0; fi\n" &
    "echo \"different-contract-stub:$*\" >> " & qsh(marker) & "\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc pushurlOf(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " config --get remote.origin.pushurl")
  if res.code != 0: "" else: res.output.strip()

proc anyPushurlUnder(gitBin, root: string): seq[string] =
  ## Every ``remote.origin.pushurl`` set in any git work tree under ``root``.
  ## "Zero writes ANYWHERE" is asserted by sweeping, not by checking the two
  ## repos the test happens to know about.
  for path in walkDirRec(root, yieldFilter = {pcDir},
      skipSpecial = true):
    if lastPathPart(path) != ".git":
      continue
    let work = parentDir(path)
    let value = pushurlOf(gitBin, work)
    if value.len > 0:
      result.add(work & " -> " & value)

proc runMigrate(fx: Fixture; runner: string): CmdResult =
  runShell(shellCommand(
    @[fx.reproBin, "gateway", "migrate",
      "--workspace-root=" & fx.workspaceRoot],
    @[(name: "REPROBUILD_REPRO", value: runner),
      # Keep the gateway tree inside the fixture: `defaultCacheRoot` honours
      # this override verbatim and the gateways root is its sibling.
      (name: "REPRO_WORKSPACE_CLONES", value: fx.scratch / "clones")]))

suite "PG-14 — migration refuses when the hook writer is not the hook runner":

  test "t_migration_refuses_when_the_hook_writer_is_not_the_hook_runner":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real repositories with real " &
        "remotes for the sweep to have push urls to write or withhold")
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      # ---- (E1) the runner PREDATES the handshake ----------------------
      let staleStub = fx.scratch / "stale-repro"
      let staleMarker = fx.scratch / "stale-invocations.log"
      writeStaleStub(staleStub, staleMarker)
      let stale = runMigrate(fx, staleStub)
      checkpoint("(E1) stale-runner migrate output:\n" & stale.output)

      # (A) a refusal, not advice.
      check stale.code != 0
      # (B) zero pushurl writes anywhere under the fixture.
      let afterStale = anyPushurlUnder(gitBin, fx.scratch)
      checkpoint("(B) pushurls after the stale-runner sweep: " &
        afterStale.join(", "))
      check afterStale.len == 0
      # (C) both builds named, with how each was resolved.
      check engineBinary() in stale.output
      check staleStub in stale.output
      check "REPROBUILD_REPRO" in stale.output
      # ... and the refusal says plainly that nothing was wired, so the
      # operator does not have to infer it from the absence of output.
      check "NOTHING was wired" in stale.output
      # (D) the remedy is to reconcile what SUPPLIES repro, and never to run
      # the command that deletes the diagnostic.
      check "hooks ensure" notin stale.output
      check "direnv reload" in stale.output
      # The version is offered, never as the discriminator.
      check "store path" in stale.output.toLowerAscii()
      # The sweep asked the stub for the handshake and for nothing else: it
      # never got as far as handing it work.
      check not fileExists(staleMarker)

      # ---- (E2) the runner SPEAKS the handshake, different body ---------
      # The predicate is "does not speak the contract", not "is older". This
      # stub reports a NEWER version and still must refuse.
      let otherStub = fx.scratch / "other-contract-repro"
      let otherMarker = fx.scratch / "other-invocations.log"
      writeDifferentContractStub(otherStub, otherMarker)
      let other = runMigrate(fx, otherStub)
      checkpoint("(E2) different-contract migrate output:\n" & other.output)
      check other.code != 0
      check anyPushurlUnder(gitBin, fx.scratch).len == 0
      check otherStub in other.output
      check engineBinary() in other.output
      check "hooks ensure" notin other.output
      check not fileExists(otherMarker)

      # ---- (F) CONTROL: writer and runner are one build ------------------
      # This is what makes (B) mean something. With no skew the sweep runs and
      # a pushurl appears; so a sweep that wrote nothing under skew wrote
      # nothing BECAUSE it refused.
      let control = runMigrate(fx, fx.reproBin)
      checkpoint("(F) control migrate output:\n" & control.output)
      check control.code == 0
      let wired = anyPushurlUnder(gitBin, fx.scratch)
      checkpoint("(F) pushurls after the control sweep: " & wired.join(", "))
      check wired.len == fx.repoPaths.len
      for repoPath in fx.repoPaths:
        let value = pushurlOf(gitBin, repoPath)
        check value.len > 0
        # Spec §2's layout: the gateway is a per-(workspace, upstream) bare
        # beside the clones pool, not a second copy of the repo.
        check value.startsWith(fx.scratch / "gateways")

      # ---- and a skewed sweep AFTER a successful one still refuses -------
      # Idempotence is not an excuse: the refusal is about the machine, so a
      # workspace that is already wired must not be re-swept under skew
      # either, and the already-wired state must survive untouched.
      let afterControl = runMigrate(fx, staleStub)
      check afterControl.code != 0
      check "NOTHING was wired" in afterControl.output
      for repoPath in fx.repoPaths:
        check pushurlOf(gitBin, repoPath).startsWith(fx.scratch / "gateways")
