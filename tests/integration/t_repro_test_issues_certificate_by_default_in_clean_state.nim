## TC-1 — ``repro test`` issues a test certificate by default in a clean state.
##
## A clean single-repo workspace at the locked revision with a passing test
## target → ``repro test --certify`` emits a ``reprobuild.test-certificate.v1``
## record covering that target for the current platform, bound to HEAD; the
## verifier confirms it covers (commit, lock, platform, target).
##
## Sub-cases (all hermetic, real local bare repos, no network):
##   1. clean + passing target → a certificate is written, covers the target,
##      binds to HEAD, and (TC-5) is daemon-SIGNED (ed25519) by the registered
##      key.
##   2. ``--no-certify`` → no certificate file is written (tests still run).
##   3. a FAILING target → no certificate (result is not 'passed').
##
## TC-5 reconciliation: issuance now signs the certificate, so the clean-issue
## case provides a daemon signing key (via ``REPRO_DAEMON_SIGNING_KEY``) and the
## former "unsigned" assertion becomes a "signed + verifies against the
## registered key" assertion. The issuance still happens — only the signature is
## now populated.
##
## Falsifiability: forcing issuance for a failing run, or breaking the verifier
## coverage union, makes a check below fail. See the milestone note.
##
## Skip rule: ``git`` or ``ssh-keygen`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

include tc5_cert_signing_helpers

const tc1KeyId = "tc1-daemon-key"

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
    " config user.name \"TC1 Tester\"")
  writeFile(workPath / "README.md", "TC-1 fixture\n")
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
    " config user.name \"TC1 Tester\"")

proc projectToml(libAUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
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
    libASeed: string
    libASha: string
    daemonKey: string   ## ed25519 private key the daemon signs issuance with

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-tc1-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASeed = result.scratch / "seed-lib-a"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin, result.libASeed)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.workspaceRoot = workspaceRoot
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")
  # TC-5: the daemon signs issuance — provide a key and register its public
  # half so the issued cert is signed AND verifies against the registry.
  if findExe("ssh-keygen").len > 0:
    let key = genEd25519Key(result.scratch / "daemon-keys", "tc1-key", tc1KeyId)
    result.daemonKey = key.priv
    writeRegistry(workspaceRoot,
      @[RegisteredKey(keyId: tc1KeyId, publicKey: key.pub, status: rksActive)])

proc seedLock(fx: Fixture) =
  let res = runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot]))
  if res.code != 0:
    checkpoint("workspace lock failed: " & res.output)
  check res.code == 0

proc writeTestFixtureJson(path, selector, scriptCmd: string) =
  ## A single-edge fixture whose runCmd is a trivial shell command, so the
  ## REAL run result drives certificate issuance.
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

proc runReproTest(fx: Fixture; fixtureJson: string;
                  extra: seq[string] = @[]): CmdResult =
  var args = @[
    fx.reproBin, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib-a")]
  for a in extra: args.add(a)
  # Run from the workspace root (not an in-scope git repo) so the shard
  # runner's ``test-logs/`` artifacts never dirty ``lib-a`` and skew the gate.
  runShell(shellCommand(args, daemonKeyEnv(fx.daemonKey, tc1KeyId)),
    fx.workspaceRoot)

proc certPath(fx: Fixture): string =
  defaultCertificatePath(fx.workspaceRoot, fx.libASha, currentPlatformTag())

suite "TC-1 — repro test issues a certificate by default in a clean state":

  test "t_repro_test_issues_certificate_by_default_in_clean_state":
    let gitBin = findExe("git")
    if gitBin.len == 0 or findExe("ssh-keygen").len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clean")
      defer: removeDir(fx.scratch)
      seedLock(fx)

      let fixtureJson = fx.scratch / "fixture-pass.json"
      writeTestFixtureJson(fixtureJson, "t-unit", "exit 0")

      # --- sub-case 1: clean + passing target → certificate issued ---------
      let res = runReproTest(fx, fixtureJson, @["--certify"])
      if res.code != 0:
        checkpoint("repro test output: " & res.output)
      check res.code == 0

      let cp = certPath(fx)
      check fileExists(cp)
      let cert = readCertificateFile(cp)
      check cert.schema == testCertificateSchemaV1
      check cert.commit == fx.libASha            # bound to HEAD (clean tree)
      check cert.platform == currentPlatformTag()
      check cert.result == tcrPassed
      check "t-unit" in cert.targets
      check cert.lock.len > 0 and cert.lock.startsWith("blake3:")
      # TC-5: the certificate is now daemon-SIGNED (ed25519) by the registered
      # key, and the signature verifies against the workspace registry.
      check cert.isSigned
      check cert.signature.algorithm == certificateSignatureAlgorithm
      check cert.signature.value.len > 0
      check cert.keyId == tc1KeyId
      let regStore = readRegisteredKeyStore(
        registeredKeyStorePath(fx.workspaceRoot))
      check verifyCertificateSignature(cert, regStore) == svValid

      # Verifier: the cert covers (commit, lock, platform, [t-unit]).
      let req = CoverageRequirement(
        commit: fx.libASha, lock: cert.lock,
        platform: currentPlatformTag(), requiredTargets: @["t-unit"])
      let cov = verifyCoverage(@[cert], req)
      check cov.covered
      check cov.matchingCerts == 1
      check "t-unit" in cov.coveredTargets
      check cov.missingTargets.len == 0

      # A requirement for a target NOT covered must NOT verify.
      let reqMiss = CoverageRequirement(
        commit: fx.libASha, lock: cert.lock,
        platform: currentPlatformTag(),
        requiredTargets: @["t-unit", "t-integration"])
      let covMiss = verifyCoverage(@[cert], reqMiss)
      check (not covMiss.covered)
      check "t-integration" in covMiss.missingTargets

      # A cert for a DIFFERENT commit must be ignored by the verifier.
      var otherCert = cert
      otherCert.commit = "deadbeef" & cert.commit[8 .. ^1]
      let covIgnore = verifyCoverage(@[otherCert], req)
      check (not covIgnore.covered)
      check covIgnore.matchingCerts == 0

      # --- sub-case 2: --no-certify suppresses issuance --------------------
      removeFile(cp)
      let resNo = runReproTest(fx, fixtureJson, @["--no-certify"])
      check resNo.code == 0
      check (not fileExists(cp))   # no certificate written

      # --- sub-case 3: a FAILING target → no certificate -------------------
      let fixtureFail = fx.scratch / "fixture-fail.json"
      writeTestFixtureJson(fixtureFail, "t-unit", "exit 1")
      check (not fileExists(cp))
      let resFail = runReproTest(fx, fixtureFail, @["--certify"])
      # The run itself fails (a failing target), and NO certificate is issued.
      check resFail.code != 0
      check (not fileExists(cp))
      check resFail.output.contains("no certificate")
