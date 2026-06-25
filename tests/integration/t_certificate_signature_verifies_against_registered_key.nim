## TC-5 — a certificate signed by a REGISTERED, UNREVOKED key VERIFIES; after
## ROTATION it still verifies; after REVOCATION the same cert is REJECTED.
##
## The daemon signs the canonical certificate payload (ed25519, via the real
## ``ssh-keygen -Y sign`` the issuance path uses) as a side effect of an
## observed ``repro test`` run. CI/the server holds a registered-keys store
## (allowed signers) with rotation + revocation. A certificate is accepted only
## when its ``key_id`` resolves to a registered, unrevoked key AND the signature
## over the canonical payload checks against that key.
##
## Assertions:
##   1. Issue a cert via the REAL ``repro test`` issuance path, signed by key A
##      whose public half is REGISTERED + ACTIVE → ``verifyCertificateSignature``
##      returns ``svValid`` and the pre-push ``required`` gate ACCEPTS (exit 0).
##   2. ROTATION: register a SECOND key B (active) alongside A, issue+sign a cert
##      with B → that cert is also ``svValid`` and accepted. The pre-rotation
##      cert (A) is still ``svValid`` (rotation does not invalidate old certs).
##   3. REVOCATION: revoke key A → the cert signed by A is now ``svRevokedKey``
##      and the SAME cert is REJECTED by the gate (exit 2).
##
## Falsifiability (recorded in the report, then reverted):
##   - make the verifier skip the signature check (count every attached cert as
##     covering) → an unsigned/wrong-key cert is wrongly accepted → the sibling
##     test ``t_unsigned_or_wrong_key_certificate_is_rejected`` fails.
##   - make the verifier ignore revocation (treat revoked as active) → the
##     revoke case here wrongly stays accepted → assertion 3 fails.
##
## Hermetic: local ``git init`` / ``git init --bare`` only; ed25519 keys are
## generated in-test with ssh-keygen. Skip rule: ``git`` or ``ssh-keygen``
## missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

include tc5_cert_signing_helpers

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
    " config user.name \"TC5 Tester\"")
  writeFile(workPath / "README.md", "TC-5 fixture\n")
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
    " config user.name \"TC5 Tester\"")

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

proc writeProjectManifest(fx: Fixture; certificatesTable: string) =
  let manifestsRoot = fx.workspaceRoot / ".repo" / "manifests"
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(fx.libAOrigin), certificatesTable))

proc requiredPolicy(): string =
  "[certificates]\n" &
  "gate_mode = \"required\"\n" &
  "required_targets = [\"t-unit\"]\n" &
  "required_platforms = [\"" & currentPlatformTag() & "\"]\n\n"

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-tc5-verify-", "")
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
  writeProjectManifest(result, requiredPolicy())
  cloneInto(gitBin, result.libAOrigin, result.libAPath)
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

proc seedLock(fx: Fixture) =
  let res = runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot]))
  if res.code != 0: checkpoint("workspace lock failed: " & res.output)
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
  cmd.add(%"sh"); cmd.add(%"-c"); cmd.add(%scriptCmd)
  e["runCmd"] = cmd
  e["testName"] = %selector
  edges.add(e)
  obj["testEdges"] = edges
  obj["buildActions"] = newJArray()
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  writeFile(path, obj.pretty() & "\n")

proc issueRealCert(fx: Fixture; daemonKey, keyId: string): TestCertificate =
  ## Drive the TC-1/TC-5 issuance path: a REAL passing run in a clean state,
  ## signed by the daemon key. Returns the issued (signed) cert read from disk.
  ## A per-key ``--certificate-out`` keeps each issuance distinct so the TC-1
  ## incremental no-op (which consults the existing cert at the out path) does
  ## not short-circuit a re-issue under a DIFFERENT key.
  let fixtureJson = fx.scratch / "fixture-pass.json"
  writeTestFixtureJson(fixtureJson, "t-unit", "exit 0")
  let certFile = fx.scratch / ("issued-" & keyId & ".toml")
  let issued = runShell(shellCommand(@[
    fx.reproBin, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1", "--certify",
    "--certificate-out=" & certFile,
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath],
    daemonKeyEnv(daemonKey, keyId)), fx.workspaceRoot)
  if issued.code != 0: checkpoint("repro test output: " & issued.output)
  check issued.code == 0
  check fileExists(certFile)
  result = readCertificateFile(certFile)

proc invokeCheckPrePush(fx: Fixture; refsFile: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath,
    "--pushed-refs=" & refsFile, "--json"]))

proc writeRefsFile(path, localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, "refs/heads/main " & localSha & " refs/heads/main " &
    zeroSha & "\n")

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "check-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

suite "TC-5 — certificate signature verifies against a registered key":

  test "t_certificate_signature_verifies_against_registered_key":
    let gitBin = findExe("git")
    let sshKeygen = findExe("ssh-keygen")
    if gitBin.len == 0 or sshKeygen.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      seedLock(fx)

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, fx.libASha)

      # ---- 1. signed by a REGISTERED + ACTIVE key A → VALID + ACCEPTED ----
      const keyIdA = "tc5-key-a"
      let keyA = genEd25519Key(fx.scratch / "keys", "key-a", keyIdA)
      writeRegistry(fx.workspaceRoot,
        @[RegisteredKey(keyId: keyIdA, publicKey: keyA.pub,
          status: rksActive)])

      let certA = issueRealCert(fx, keyA.priv, keyIdA)
      check certA.isSigned
      check certA.keyId == keyIdA
      check certA.signature.algorithm == certificateSignatureAlgorithm
      var storeA = readRegisteredKeyStore(
        registeredKeyStorePath(fx.workspaceRoot))
      # Signature is VALID against the registered, unrevoked key.
      check verifyCertificateSignature(certA, storeA) == svValid

      # Attach + gate ACCEPTS (the `required` gate now requires a valid sig).
      let attA = attachCertificate(gitBin, fx.libAPath, fx.libASha, certA)
      check attA.ok
      let acceptA = invokeCheckPrePush(fx, refsFile)
      checkpoint("accept-A output: " & acceptA.output)
      check acceptA.code == 0
      check readReport(fx)["exitCode"].getInt() == 0

      # ---- 2. ROTATION: register key B alongside A; cert signed by B is ----
      # also valid; the pre-rotation cert A is STILL valid.
      const keyIdB = "tc5-key-b"
      let keyB = genEd25519Key(fx.scratch / "keys", "key-b", keyIdB)
      var rotated = storeA
      registerKey(rotated, keyIdB, keyB.pub)        # rotation = add a new key
      writeRegisteredKeyStore(rotated,
        registeredKeyStorePath(fx.workspaceRoot))
      # Both keys resolve as active signers.
      check resolveSigner(rotated, keyIdA).found
      check not resolveSigner(rotated, keyIdA).revoked
      check resolveSigner(rotated, keyIdB).found

      let certB = issueRealCert(fx, keyB.priv, keyIdB)
      check certB.keyId == keyIdB
      let storeRot = readRegisteredKeyStore(
        registeredKeyStorePath(fx.workspaceRoot))
      # Cert signed with the rotated-in key B verifies.
      check verifyCertificateSignature(certB, storeRot) == svValid
      # The pre-rotation cert A still verifies (old certs survive rotation).
      check verifyCertificateSignature(certA, storeRot) == svValid

      # ---- 3. REVOCATION: revoke key A → cert A is REJECTED ---------------
      var revoked = storeRot
      check revokeKey(revoked, keyIdA)              # revocation
      writeRegisteredKeyStore(revoked,
        registeredKeyStorePath(fx.workspaceRoot))
      let storeRev = readRegisteredKeyStore(
        registeredKeyStorePath(fx.workspaceRoot))
      check resolveSigner(storeRev, keyIdA).revoked
      # Falsifiable: if the verifier ignored revocation, this would stay svValid.
      check verifyCertificateSignature(certA, storeRev) == svRevokedKey

      # The gate now REJECTS the SAME push (cert A is the only attached cert
      # and its key is revoked → no trusted cert covers the requirement).
      let rejected = invokeCheckPrePush(fx, refsFile)
      checkpoint("revoked output: " & rejected.output)
      check rejected.code == 2
      let rejReport = readReport(fx)
      check rejReport["exitCode"].getInt() == 2
      var sawCertFailure = false
      for f in rejReport["failures"]:
        if f["property"].getStr() == "certificate-coverage":
          sawCertFailure = true
      check sawCertFailure
