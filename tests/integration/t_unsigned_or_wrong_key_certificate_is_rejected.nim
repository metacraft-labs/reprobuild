## TC-5 — unsigned / wrong-key / unregistered / tampered certificates are
## REJECTED, and the ``required`` pre-push gate (TC-3) REFUSES a push covered
## only by such a cert.
##
## A certificate is accepted only when (a) it is signed, (b) its ``key_id``
## resolves to a REGISTERED, UNREVOKED key, and (c) the ed25519 signature over
## the canonical payload checks against that key. This test exercises every way
## that can fail:
##   (a) an UNSIGNED cert (TC-1-shape, empty signature) → ``svUnsigned``.
##   (b) a cert signed by a key NOT in the registry (unregistered key_id) →
##       ``svUnregisteredKey``.
##   (c) a cert whose signature was TAMPERED, and one signed over DIFFERENT
##       content than it carries → ``svBadSignature``.
##   (d) a cert claiming a REGISTERED key_id but signed by a DIFFERENT key →
##       ``svBadSignature`` (the allowed-signers line for that id is the wrong
##       key, so the signature does not verify).
## The ``required`` gate, given an attached cert of each kind, must REFUSE
## (exit 2) — no trusted cert covers the requirement.
##
## Falsifiability (recorded, then reverted):
##   - make the verifier skip the signature check (accept any attached cert) →
##     cases (a)/(b)/(c)/(d) wrongly verify → every assertion here fails AND the
##     gate wrongly accepts.
##
## Every signature here is produced by the REAL ssh-keygen ed25519 path; we
## never fabricate one. Hermetic; skip when git/ssh-keygen are absent.

import std/[base64, json, os, osproc, strutils, tempfiles, unittest]

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
  writeFile(workPath / "README.md", "TC-5 reject fixture\n")
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
  result.scratch = createTempDir("repro-tc5-reject-", "")
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

proc lockDigestOf(fx: Fixture): string =
  ## The lock digest the gate binds certs to (so a hand-built cert matches the
  ## coverage requirement on every field EXCEPT its signature).
  let locksRoot = fx.workspaceRoot / ".repo" / "manifests" / "locks" /
    "lib-a" / "lib-a"
  var lockFile = ""
  for f in walkFiles(locksRoot / "*.toml"): lockFile = f
  check lockFile.len > 0
  certificateLockDigest(lockFile)

proc baseCert(fx: Fixture; keyId: string): TestCertificate =
  ## A passed cert bound to the pushed commit + lock + host platform + t-unit,
  ## i.e. one that WOULD cover the requirement — so only the signature decides
  ## acceptance. ``keyId`` is set so the cert can claim a (possibly wrong) id.
  TestCertificate(
    schema: testCertificateSchemaV1,
    project: "lib-a", repo: "lib-a",
    commit: fx.libASha, lock: lockDigestOf(fx),
    platform: currentPlatformTag(),
    targets: @["t-unit"], result: tcrPassed,
    issuedAt: "2026-06-25T00:00:00Z",
    issuer: "tc5-test", keyId: keyId)

proc gateRefuses(fx: Fixture; cert: TestCertificate; gitBin: string): bool =
  ## Attach ``cert`` to the pushed commit and assert the `required` gate
  ## REFUSES (exit 2 with a certificate-coverage failure). Clears any prior
  ## note so each case is judged on its own attached cert.
  discard execCmdEx(quoteShellCommand(@[gitBin, "-C", fx.libAPath,
    "notes", "--ref", certificateNotesRef, "remove", fx.libASha]))
  let att = attachCertificate(gitBin, fx.libAPath, fx.libASha, cert)
  check att.ok
  let refsFile = fx.scratch / "pushed-refs.txt"
  writeRefsFile(refsFile, fx.libASha)
  let res = invokeCheckPrePush(fx, refsFile)
  checkpoint("gate output: " & res.output)
  let rep = readReport(fx)
  var sawCertFailure = false
  for f in rep["failures"]:
    if f["property"].getStr() == "certificate-coverage": sawCertFailure = true
  res.code == 2 and rep["exitCode"].getInt() == 2 and sawCertFailure

suite "TC-5 — unsigned or wrong-key certificate is rejected":

  test "t_unsigned_or_wrong_key_certificate_is_rejected":
    let gitBin = findExe("git")
    let sshKeygen = findExe("ssh-keygen")
    if gitBin.len == 0 or sshKeygen.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      seedLock(fx)

      # Registry holds ONE registered key, "good".
      const goodId = "tc5-good"
      let good = genEd25519Key(fx.scratch / "keys", "good", goodId)
      writeRegistry(fx.workspaceRoot,
        @[RegisteredKey(keyId: goodId, publicKey: good.pub,
          status: rksActive)])
      let store = readRegisteredKeyStore(
        registeredKeyStorePath(fx.workspaceRoot))

      # ---- (a) UNSIGNED cert → svUnsigned + gate refuses -----------------
      var unsigned = baseCert(fx, "")    # no key_id, empty signature
      check not unsigned.isSigned
      check verifyCertificateSignature(unsigned, store) == svUnsigned
      check gateRefuses(fx, unsigned, gitBin)

      # ---- (b) signed by an UNREGISTERED key (key_id not in registry) ----
      const strangerId = "tc5-stranger"
      let stranger = genEd25519Key(fx.scratch / "keys", "stranger", strangerId)
      var byStranger = baseCert(fx, strangerId)
      signCertificateOnIssuance(byStranger, strangerId, stranger.priv)
      check byStranger.isSigned
      # Cryptographically valid signature, but the key_id is not registered.
      check verifyCertificateSignature(byStranger, store) == svUnregisteredKey
      check gateRefuses(fx, byStranger, gitBin)

      # ---- (c) TAMPERED: a genuinely-signed-by-good cert whose payload is
      # then altered (targets changed) → the signature no longer matches ----
      var signedGood = baseCert(fx, goodId)
      signCertificateOnIssuance(signedGood, goodId, good.priv)
      check verifyCertificateSignature(signedGood, store) == svValid
      var tampered = signedGood
      tampered.targets = @["t-unit", "t-smuggled"]   # alter signed content
      # Falsifiable: skip the sig check and this "covers" more targets.
      check verifyCertificateSignature(tampered, store) == svBadSignature
      check gateRefuses(fx, tampered, gitBin)
      # Also: keep the good key_id but replace the signature bytes (garbage).
      var garbled = signedGood
      garbled.signature.value = encode("not a real ssh signature blob")
      check verifyCertificateSignature(garbled, store) == svBadSignature

      # ---- (d) claims a REGISTERED key_id but signed by a DIFFERENT key ---
      let impostor = genEd25519Key(fx.scratch / "keys", "impostor", goodId)
      var spoofed = baseCert(fx, goodId)         # claims the registered id...
      signCertificateOnIssuance(spoofed, goodId, impostor.priv)  # ...wrong key
      # The allowed-signers line for goodId is the GOOD public key, so a
      # signature made by the impostor key does not verify for that id.
      check verifyCertificateSignature(spoofed, store) == svBadSignature
      check gateRefuses(fx, spoofed, gitBin)
