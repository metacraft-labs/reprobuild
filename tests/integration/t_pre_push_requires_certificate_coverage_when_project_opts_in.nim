## TC-3 — the pre-push gate REQUIRES certificate coverage when the project
## opts in (gate mode ``required``).
##
## When a project's `[certificates]` policy sets ``gate_mode = "required"``
## with ``required_targets`` / ``required_platforms``, the RA-21 pre-push gate
## refuses the push unless the certificates ATTACHED to the pushed commit
## (the TC-2 git-notes carrier) COVER (the TC-1 ``verifyCoverage`` verifier)
## the pushed commit, against the current clean lock, for every required
## target on EACH required platform. Coverage UNIONS multiple certificates:
## a {linux, macos} × {t-unit} requirement is satisfied by a linux cert + a
## macos cert TOGETHER.
##
##   (a) NO covering cert attached → the gate REFUSES (exit 2) with a
##       ``certificate-coverage`` failure naming the missing coverage and the
##       ``repro certify`` remedy.
##   (b) A covering cert (issued via the TC-1 path, attached via TC-2) →
##       the gate PASSES (exit 0).
##   (c) A multi-platform requirement satisfied by the UNION of two certs
##       (one per platform) → passes; dropping one platform's cert → refuses
##       and names exactly that platform.
##
## Falsifiability:
##   - make ``required`` not enforce (treat it like ``off``) → (a) wrongly
##     passes → the test fails on the exit-2 assertion.
##   - break the multi-cert union (per-platform set not unioned) → the
##     two-cert case in (c) fails to cover → the pass assertion fails.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

# TC-5 reconciliation: the gate now requires a VALID REGISTERED SIGNATURE, not
# just coverage. The covering cert must be daemon-signed (ed25519) by a key
# whose public half is REGISTERED in the workspace allowed-signers store. These
# helpers generate that key, point issuance at it, and register it.
include tc5_cert_signing_helpers

const tc3KeyId = "tc3-daemon-key"

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
    " config user.name \"TC3 Tester\"")
  writeFile(workPath / "README.md", "TC-3 fixture\n")
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
    " config user.name \"TC3 Tester\"")

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
    daemonKey: string   ## ed25519 private key the daemon signs issuance with

proc writeProjectManifest(fx: Fixture; certificatesTable: string) =
  let manifestsRoot = fx.workspaceRoot / ".repo" / "manifests"
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(fx.libAOrigin), certificatesTable))

proc setupFixture(gitBin, slug, certificatesTable: string): Fixture =
  result.scratch = createTempDir("repro-tc3-" & slug & "-", "")
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
  # TC-5: generate the daemon signing key and register its public half so the
  # cert the TC-1 path issues is daemon-signed AND trusted by the gate.
  let key = genEd25519Key(result.scratch / "daemon-keys", "tc3-key", tc3KeyId)
  result.daemonKey = key.priv
  writeRegistry(workspaceRoot,
    @[RegisteredKey(keyId: tc3KeyId, publicKey: key.pub, status: rksActive)])

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
  ## Drive the TC-1 issuance path (a REAL passing run in a clean state) so a
  ## genuine certificate file is produced (never a hardcoded cert).
  runShell(shellCommand(@[
    fx.reproBin, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1",
    "--certify",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath],
    daemonKeyEnv(fx.daemonKey, tc3KeyId)), fx.workspaceRoot)

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

proc issueAndReadCert(fx: Fixture): TestCertificate =
  ## Issue a genuine certificate for the pushed commit via the TC-1 path and
  ## read it back from disk.
  let fixtureJson = fx.scratch / "fixture-pass.json"
  writeTestFixtureJson(fixtureJson, "t-unit", "exit 0")
  let issued = issueRealCert(fx, fixtureJson)
  if issued.code != 0:
    checkpoint("repro test output: " & issued.output)
  check issued.code == 0
  let certFile = defaultCertificatePath(
    fx.workspaceRoot, fx.libASha, currentPlatformTag())
  check fileExists(certFile)
  result = readCertificateFile(certFile)
  check result.commit == fx.libASha
  check "t-unit" in result.targets

const otherPlatform = "linux/tc3-second"

suite "TC-3 — pre-push requires certificate coverage when project opts in":

  test "t_pre_push_requires_certificate_coverage_when_project_opts_in":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ---- (a) required + NO covering cert → REFUSE ----------------------
      let policySingle =
        "[certificates]\n" &
        "gate_mode = \"required\"\n" &
        "required_targets = [\"t-unit\"]\n" &
        "required_platforms = [\"" & currentPlatformTag() & "\"]\n\n"
      let fx = setupFixture(gitBin, "required", policySingle)
      defer: removeDir(fx.scratch)
      seedLock(fx)

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, fx.libASha)

      let refused = invokeCheckPrePush(fx, refsFile)
      checkpoint("(a) output: " & refused.output)
      # Falsifiable: if `required` did not enforce, this would be exit 0.
      check refused.code == 2
      let refusedReport = readReport(fx)
      check refusedReport["exitCode"].getInt() == 2
      var sawCertFailure = false
      var remedyNamesCertify = false
      for f in refusedReport["failures"]:
        if f["property"].getStr() == "certificate-coverage":
          sawCertFailure = true
          if "repro certify" in f["remediation"].getStr():
            remedyNamesCertify = true
      check sawCertFailure
      check remedyNamesCertify

      # ---- (b) required + a covering cert attached → PASS ----------------
      # Issue a genuine cert (TC-1) and attach it to the pushed commit (TC-2).
      let cert = issueAndReadCert(fx)
      let att = attachCertificate(gitBin, fx.libAPath, fx.libASha, cert)
      check att.ok

      let passed = invokeCheckPrePush(fx, refsFile)
      checkpoint("(b) output: " & passed.output)
      # Falsifiable: if coverage were not actually checked, an irrelevant
      # cert would not flip this. The cert covers (commit, lock, platform,
      # t-unit) exactly, so the gate must now PASS.
      check passed.code == 0
      let passedReport = readReport(fx)
      check passedReport["exitCode"].getInt() == 0
      for f in passedReport["failures"]:
        check f["property"].getStr() != "certificate-coverage"

      # ---- (c) MULTI-PLATFORM required, satisfied by the UNION of two ----
      # certs (one per platform); dropping one platform's cert → refuse and
      # name that platform.
      let policyMulti =
        "[certificates]\n" &
        "gate_mode = \"required\"\n" &
        "required_targets = [\"t-unit\"]\n" &
        "required_platforms = [\"" & currentPlatformTag() & "\", \"" &
          otherPlatform & "\"]\n\n"
      writeProjectManifest(fx, policyMulti)

      # Only the host-platform cert is attached so far → the SECOND platform
      # is uncovered. The gate must refuse and NAME the missing platform.
      let missingOne = invokeCheckPrePush(fx, refsFile)
      checkpoint("(c) missing-platform output: " & missingOne.output)
      check missingOne.code == 2
      let missingReport = readReport(fx)
      var namedMissingPlatform = false
      for f in missingReport["failures"]:
        if f["property"].getStr() == "certificate-coverage":
          if otherPlatform in f["evidence"].getStr():
            namedMissingPlatform = true
      check namedMissingPlatform

      # Attach a SECOND cert for the other platform (same commit + lock, a
      # different platform + the required target). Now the UNION of the two
      # certs covers BOTH required platforms.
      #
      # TC-5: the second cert must be GENUINELY daemon-signed for its OWN
      # canonical payload (a different platform changes the signed bytes), so we
      # re-sign with the same daemon key — modelling "run `repro certify` on a
      # worker for the other platform". A naive copy of cert 1's signature would
      # NOT verify (different payload) and the gate would correctly drop it.
      var cert2 = cert
      cert2.platform = otherPlatform
      cert2.targets = @["t-unit"]
      cert2.signature = TestCertificateSignature()  # clear cert 1's signature
      signCertificateOnIssuance(cert2, tc3KeyId, fx.daemonKey)
      let att2 = attachCertificate(gitBin, fx.libAPath, fx.libASha, cert2)
      check att2.ok

      let unionPass = invokeCheckPrePush(fx, refsFile)
      checkpoint("(c) union output: " & unionPass.output)
      # Falsifiable: break the per-platform UNION and the second platform
      # stays uncovered → this stays exit 2.
      check unionPass.code == 0
      let unionReport = readReport(fx)
      check unionReport["exitCode"].getInt() == 0
      for f in unionReport["failures"]:
        check f["property"].getStr() != "certificate-coverage"
