## A per-repo push-gateway opt-out made with plain git holds: wiring does not
## undo it, and ``repro health`` reports it as an opt-out.
##
## THE PROPERTY (Push-Gateway-Wiring-And-Policy.md §6.4, §7.3, §7.4). The spec
## documents ``git config --unset remote.origin.pushurl`` as a per-repo opt-out
## that the next wiring run reports as ``opted-out`` instead of re-wiring. Plain
## git cannot write an opt-out marker, so the verdict has to come from state
## reprobuild wrote itself: wiring records the §7.6.3 provenance record
## (``reprobuild.pushGateway.*`` in the repo's own ``.git/config``) beside the
## ``pushurl``, and ``git config --unset remote.origin.pushurl`` leaves that
## record in place. §7.3 classifies "provenance record present, ``pushurl``
## absent" as ``opted-out``. A repo with no record and no ``pushurl`` (one
## that was never wired, or one whose foreign ``pushurl`` was removed) is still
## ``unwired`` and is wired by the next run (§7.6.4).
##
## THE DEFECT THIS GUARDS AGAINST (reprobuild-pm
## ``issues/2026-11-12-automatic-migration-silently-undoes-the-documented-plain-git-opt-out.md``).
## Wiring wrote no provenance record and read an absent ``pushurl`` as
## ``unwired``, so the next ``repro gateway migrate`` silently re-wired a repo
## whose owner had opted it out the documented way, and ``health`` reported it
## ``not-wired``. Once migration runs from ``repro sync`` (PG-9), that would
## happen on every sync without anyone asking for it.
##
## The arms, all against the REAL ``repro`` binary in one fixture:
##
##   1. ``repro gateway migrate`` wires the repo and writes the provenance
##      record naming the value it wrote and this workspace.
##   2. ``git config --unset remote.origin.pushurl``, then ``migrate`` again
##      (also with ``--dry-run`` first): the ``pushurl`` stays unset, the run
##      reports the repo ``opted-out`` and exits 0. ``health`` counts it
##      ``opted-out``, not ``not-wired``.
##   3. CONTROL, and what makes arm 2 about the record rather than about any
##      unset ``pushurl``: ``git config --remove-section reprobuild.pushGateway``
##      (the documented way back in) and ``migrate`` wires the repo again;
##      ``health`` counts it ``wired`` and no longer ``opted-out``.
##
## Test doubles: none. The origin is a local bare reached over ``file://``, so
## there is no network. ``REPRO_WORKSPACE_CLONES`` points the cache root inside
## the fixture's temp dir, so nothing reaches the operator's real cache, and
## ``REPROBUILD_REPRO`` pins the binary-skew probe to the binary under test.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output.strip())

proc must(command: string): string =
  let res = runCmd(command)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code & "\n" &
      res.output)
  doAssert res.code == 0, "fixture command failed: " & command
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "lib-a"

[[remote]]
name = "lib-a-origin"
fetch = "LIB_A_URL"

includes = [
  "repos/lib-a.toml",
]
"""

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
"""

type Fixture = object
  gitBin, scratch, workspaceRoot, repoPath, cacheRoot, reproBin: string

proc setupFixture(gitBin: string): Fixture =
  ## One workspace, one participating repo cloned from a local bare origin,
  ## and a cache root inside the fixture.
  result.gitBin = gitBin
  result.reproBin = reproBinary()
  result.scratch = createTempDir("repro-gateway-plain-git-opt-out-", "")
  let origin = result.scratch / "origin-lib-a.git"
  let seed = result.scratch / "seed-lib-a"
  discard must(q(gitBin) & " init -q --bare -b main " & q(origin))
  discard must(q(gitBin) & " init -q -b main " & q(seed))
  discard must(q(gitBin) & " -C " & q(seed) &
    " -c user.email=t@example.invalid -c user.name=T commit -q " &
    "--allow-empty -m seed")
  discard must(q(gitBin) & " -C " & q(seed) & " push -q " & q(origin) &
    " main")
  result.workspaceRoot = result.scratch / "workspace"
  result.cacheRoot = result.scratch / "cache" / "clones"
  for dir in [result.workspaceRoot / ".repro", result.workspaceRoot / "projects",
              result.workspaceRoot / "repos", result.cacheRoot]:
    createDir(dir)
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectToml.replace("LIB_A_URL", fileUrl(origin)))
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.repoPath = result.workspaceRoot / "lib-a"
  discard must(q(gitBin) & " clone -q " & q(fileUrl(origin)) & " " &
    q(result.repoPath))

proc fixtureEnv(fx: Fixture): seq[tuple[name, value: string]] =
  @[(name: "REPRO_WORKSPACE_CLONES", value: fx.cacheRoot),
    (name: "REPROBUILD_REPRO", value: fx.reproBin)]

proc migrate(fx: Fixture; dryRun = false): CmdResult =
  var args = @[fx.reproBin, "gateway", "migrate",
    "--workspace-root=" & fx.workspaceRoot]
  if dryRun: args.add("--dry-run")
  result = runShell(shellCommand(args, fixtureEnv(fx)))
  checkpoint("gateway migrate" & (if dryRun: " --dry-run" else: "") &
    ": exit=" & $result.code & "\n" & result.output)

proc gitConfig(fx: Fixture; key: string): string =
  ## "" when the key is unset.
  let res = runCmd(q(fx.gitBin) & " -C " & q(fx.repoPath) &
    " config --get " & key)
  if res.code == 0: res.output else: ""

proc pushurl(fx: Fixture): string = gitConfig(fx, "remote.origin.pushurl")

proc gatewayDetail(fx: Fixture; label: string): string =
  let res = runShell(shellCommand(@[fx.reproBin, "health", "lib-a", "--json",
    "--workspace-root=" & fx.workspaceRoot], fixtureEnv(fx)))
  let report =
    try: parseJson(res.output)
    except CatchableError:
      checkpoint(label & ": health emitted unparseable output:\n" & res.output)
      raise
  for entry in report["checks"]:
    if entry["name"].getStr() == "push-gateway":
      result = entry["detail"].getStr()
  checkpoint(label & ": push-gateway detail: " & result)
  doAssert result.len > 0, label & ": health emitted no push-gateway row"

suite "a plain-git pushurl unset is a per-repo push-gateway opt-out":

  test "t_gateway_plain_git_unset_is_a_per_repo_opt_out":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository whose " &
        "pushurl and provenance record live in its own git config")
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      checkpoint("binary under test: " & fx.reproBin)

      # ARM 1 — wiring writes the pushurl AND the record that says so.
      let first = migrate(fx)
      check first.code == 0
      let gateway = pushurl(fx)
      check gateway.len > 0
      check gitConfig(fx, "reprobuild.pushGateway.setBy") == "reprobuild"
      check gitConfig(fx, "reprobuild.pushGateway.value") == gateway
      check gitConfig(fx, "reprobuild.pushGateway.workspace") ==
        absolutePath(fx.workspaceRoot)
      check gitConfig(fx, "reprobuild.pushGateway.at").len > 0
      check "1 wired" in gatewayDetail(fx, "after wiring")

      # ARM 2 — the documented plain-git opt-out (§7.4), then wiring again.
      discard must(q(gitBin) & " -C " & q(fx.repoPath) &
        " config --unset remote.origin.pushurl")
      check pushurl(fx) == ""
      let dry = migrate(fx, dryRun = true)
      check dry.code == 0
      check "lib-a: opted-out" in dry.output
      check "would wire" notin dry.output
      let again = migrate(fx)
      check again.code == 0
      check "lib-a: opted-out" in again.output
      # The verdict comes from the record, not from the explicit marker.
      check "provenance record remains" in again.output
      check "wired ->" notin again.output
      check pushurl(fx) == ""       # the opt-out held
      let optedOut = gatewayDetail(fx, "after plain-git opt-out")
      check "1 opted-out" in optedOut
      check "0 not-wired" in optedOut

      # ARM 3 — CONTROL. Without the record the same unset pushurl is
      # `unwired`, and wiring takes it: the record is what decided arm 2.
      discard must(q(gitBin) & " -C " & q(fx.repoPath) &
        " config --remove-section reprobuild.pushGateway")
      let back = migrate(fx)
      check back.code == 0
      check "lib-a: wired ->" in back.output
      check pushurl(fx) == gateway
      let rewired = gatewayDetail(fx, "after opting back in")
      check "1 wired" in rewired
      check "0 opted-out" in rewired
