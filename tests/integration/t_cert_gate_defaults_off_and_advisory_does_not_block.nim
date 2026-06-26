## RA-32 — certificate gating is OPT-IN: default ``off`` is a strict no-op,
## and ``advisory`` records coverage WITHOUT ever blocking the push.
##
## Certificate ENFORCEMENT is opt-in (Test-Certificates.md §"Per-project
## configuration"): issuance is always on, but pushes are gated only when a
## project sets ``gate_mode = "required"``. The DEFAULT is ``off`` and
## ``advisory`` records-without-blocking, so a team can run advisory while
## people learn the workflow and tighten to required later. This prevents the
## "first push hits a hard certificate wall" onboarding failure.
##
##   (a) DEFAULT (no `[certificates]` policy at all) → the pre-push gate
##       behaves EXACTLY as it did before certificates existed: it PASSES
##       (exit 0) on an otherwise-clean + published + locked state even with
##       ZERO certificates attached, and records NO certificate notice.
##   (b) ``advisory`` with NO covering cert → the gate still PASSES (exit 0)
##       but RECORDS the missing coverage as a non-blocking notice.
##   (c) ``advisory`` with a covering cert → passes and records "coverage OK".
##
## Falsifiability:
##   - make ``off`` (or a missing policy) run the cert check and block → (a)
##     fails (it would exit non-zero, or emit a coverage notice).
##   - make ``advisory`` block on a miss → (b) fails (exit 2 instead of 0).
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

# TC-5: issuance signs the cert; the advisory "coverage OK" case (c) needs the
# issued cert to be signed by a registered key. These helpers provide it.
include tc5_cert_signing_helpers

const ra32KeyId = "ra32-daemon-key"

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

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA32 Tester\"")
  writeFile(workPath / "README.md", "RA-32 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA32 Tester\"")

proc projectToml(libAUrl, certificatesTable: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  certificatesTable &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libAPath: string
    libASha: string
    daemonKey: string

proc writeProjectManifest(fx: Fixture; certificatesTable: string) =
  let manifestsRoot = fx.workspaceRoot / ".repo" / "manifests"
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(fx.libAOrigin), certificatesTable))

proc setupFixture(gitBin, slug, certificatesTable: string): Fixture =
  result.scratch = createTempDir("repro-ra32-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.workspaceRoot = workspaceRoot
  result.libAPath = workspaceRoot / "lib-a"
  writeProjectManifest(result, certificatesTable)
  cloneInto(gitBin, result.libAOrigin, result.libAPath)
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")
  # TC-5: provide + register a daemon signing key so issued certs are signed
  # and trusted (the advisory "coverage OK" case needs a trusted cert).
  if findExe("ssh-keygen").len > 0:
    let key = genEd25519Key(result.scratch / "daemon-keys", "ra32-key",
      ra32KeyId)
    result.daemonKey = key.priv
    writeRegistry(workspaceRoot,
      @[RegisteredKey(keyId: ra32KeyId, publicKey: key.pub,
        status: rksActive)])

proc seedLock(fx: Fixture) =
  let res = runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot]))
  if res.code != 0:
    checkpoint("workspace lock failed: " & res.output)
  check res.code == 0

proc writeTestFixtureJson(path, selector, scriptCmd: string) =
  var obj = newJObject()
  obj["fallbackBuildCostNs"] = %1
  obj["fallbackTestCostNs"] = %1
  var edges = newJArray()
  var e = newJObject()
  e["id"] = %1
  e["selector"] = %selector
  e["historyKey"] = %selector
  e["buildDeps"] = newJArray()
  var cmd = newJArray()
  cmd.add(%"sh")
  cmd.add(%"-c")
  cmd.add(%scriptCmd)
  e["runCmd"] = cmd
  e["testName"] = %selector
  edges.add(e)
  obj["testEdges"] = edges
  obj["buildActions"] = newJArray()
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  writeFile(path, obj.pretty() & "\n")

proc issueRealCert(fx: Fixture; fixtureJson: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1",
    "--certify",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath],
    daemonKeyEnv(fx.daemonKey, ra32KeyId)), fx.workspaceRoot)

proc invokeCheckPrePush(fx: Fixture; refsFile: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath,
    "--pushed-refs=" & refsFile,
    "--json"]))

proc writeRefsFile(path, localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, "refs/heads/main " & localSha & " refs/heads/main " &
    zeroSha & "\n")

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "check-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc noticeMentioning(report: JsonNode; needle: string): bool =
  for n in report["notices"]:
    if needle in n.getStr():
      return true
  false

proc issueAndAttachCert(fx: Fixture; gitBin: string) =
  let fixtureJson = fx.scratch / "fixture-pass.json"
  writeTestFixtureJson(fixtureJson, "t-unit", "exit 0")
  let issued = issueRealCert(fx, fixtureJson)
  if issued.code != 0:
    checkpoint("repro test output: " & issued.output)
  check issued.code == 0
  let certFile = defaultCertificatePath(
    fx.workspaceRoot, fx.libASha, currentPlatformTag())
  check fileExists(certFile)
  let cert = readCertificateFile(certFile)
  let att = attachCertificate(gitBin, fx.libAPath, fx.libASha, cert)
  check att.ok

suite "RA-32 — certificate gate defaults off; advisory never blocks":

  test "t_cert_gate_defaults_off_and_advisory_does_not_block":
    let gitBin = findExe("git")
    if gitBin.len == 0 or findExe("ssh-keygen").len == 0:
      skip()
    else:
      # ---- (a) DEFAULT: NO `[certificates]` policy at all → no cert check -
      # An otherwise-clean + published + locked single-repo workspace with
      # ZERO certificates attached must PASS, and the report must carry NO
      # certificate notice (the cert stage is a strict no-op when off).
      let fxOff = setupFixture(gitBin, "default-off", "")
      defer: removeDir(fxOff.scratch)
      seedLock(fxOff)
      let refsOff = fxOff.scratch / "pushed-refs.txt"
      writeRefsFile(refsOff, fxOff.libASha)

      let offRun = invokeCheckPrePush(fxOff, refsOff)
      checkpoint("(a) output: " & offRun.output)
      # Falsifiable: if a missing policy ran the cert check, this would be
      # exit 2 (no cert attached) — the regression-critical default-off case.
      check offRun.code == 0
      let offReport = readReport(fxOff)
      check offReport["exitCode"].getInt() == 0
      check offReport["failures"].len == 0
      # No certificate notice recorded when off.
      check not noticeMentioning(offReport, "certificate")

      # ---- (b) ADVISORY + NO covering cert → PASS but RECORD the miss ----
      let advisoryPolicy =
        "[certificates]\n" &
        "gate_mode = \"advisory\"\n" &
        "required_targets = [\"t-unit\"]\n" &
        "required_platforms = [\"" & currentPlatformTag() & "\"]\n\n"
      let fxAdv = setupFixture(gitBin, "advisory", advisoryPolicy)
      defer: removeDir(fxAdv.scratch)
      seedLock(fxAdv)
      let refsAdv = fxAdv.scratch / "pushed-refs.txt"
      writeRefsFile(refsAdv, fxAdv.libASha)

      let advMiss = invokeCheckPrePush(fxAdv, refsAdv)
      checkpoint("(b) output: " & advMiss.output)
      # Falsifiable: if advisory blocked, this would be exit 2.
      check advMiss.code == 0
      let advMissReport = readReport(fxAdv)
      check advMissReport["exitCode"].getInt() == 0
      check advMissReport["failures"].len == 0
      # The missing coverage IS recorded as a non-blocking advisory notice.
      check noticeMentioning(advMissReport, "advisory")
      check noticeMentioning(advMissReport, "INCOMPLETE")

      # ---- (c) ADVISORY + a covering cert → PASS, records "coverage OK" --
      issueAndAttachCert(fxAdv, gitBin)
      let advCovered = invokeCheckPrePush(fxAdv, refsAdv)
      checkpoint("(c) output: " & advCovered.output)
      check advCovered.code == 0
      let advCoveredReport = readReport(fxAdv)
      check advCoveredReport["exitCode"].getInt() == 0
      check advCoveredReport["failures"].len == 0
      check noticeMentioning(advCoveredReport, "coverage OK")
