## TC-2 — certificates TRAVEL with the pushed commit.
##
## A certificate issued by the TC-1 path (``repro test`` in a clean state) is
## attached to its commit C as a git note under
## ``refs/notes/reprobuild/certificates`` and carried to the upstream bare by
## ``repro push`` so reviewers / the gate / CI can read exactly what was
## attested. The transport must:
##
##   1. Carry the attached certificate to the upstream: after ``repro push``,
##      the cert is READABLE from the upstream bare (fetch the notes ref) and
##      its content round-trips + attests C.
##   2. Carry MULTIPLE certificates (e.g. two platforms) on the same commit —
##      BOTH travel and are BOTH readable on the upstream (accumulate, no
##      overwrite).
##   3. The reader ``readAttachedCertificates(…, C)`` IGNORES a record whose
##      internal ``commit`` field != C (defense against a stale/misfiled note).
##
## Falsifiability (see the milestone note):
##   - no attach → the upstream has no cert note → assert 1 fails.
##   - overwrite-instead-of-accumulate → only one platform survives → the
##     multi-cert assert (2) fails.
##   - no mismatch filter → the wrong-commit cert is returned → assert 3 fails.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network.
## Skip rule: ``git`` or ``ssh-keygen`` missing on PATH.
##
## TC-5: issuance now signs the certificate, so the TC-1 issuance helper here
## provides a daemon signing key. The transport assertions are unchanged — a
## signed cert travels exactly like an unsigned one did.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

include tc5_cert_signing_helpers

const tc2KeyId = "tc2-daemon-key"

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
    " config user.name \"TC2 Tester\"")
  writeFile(workPath / "README.md", "TC-2 fixture\n")
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
    " config user.name \"TC2 Tester\"")

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
    libAPath: string
    libASha: string
    daemonKey: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-tc2-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.workspaceRoot = workspaceRoot
  result.libAPath = workspaceRoot / "lib-a"
  cloneInto(gitBin, result.libAOrigin, result.libAPath)
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")
  # TC-5: issuance signs the cert — provide + register a daemon key.
  if findExe("ssh-keygen").len > 0:
    let key = genEd25519Key(result.scratch / "daemon-keys", "tc2-key", tc2KeyId)
    result.daemonKey = key.priv
    writeRegistry(workspaceRoot,
      @[RegisteredKey(keyId: tc2KeyId, publicKey: key.pub, status: rksActive)])

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
    daemonKeyEnv(fx.daemonKey, tc2KeyId)), fx.workspaceRoot)

proc invokePush(fx: Fixture): CmdResult =
  ## ``--no-certify`` so the push's own certify slot stays a no-op; the
  ## certificate transport (carry the attached notes) runs regardless.
  runShell(shellCommand(@[
    fx.reproBin, "push",
    "--no-certify",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath,
    "--json"]))

proc clonedUpstreamCerts(gitBin, originPath, commit, scratch, slug: string):
    seq[TestCertificate] =
  ## Read the certificates that reached the UPSTREAM bare: clone it fresh,
  ## fetch the certificate notes ref from origin into the clone, then read the
  ## certs attached to ``commit``. This proves the certs travelled to the
  ## upstream (not merely that they exist in the local checkout).
  let verifyClone = scratch / ("verify-" & slug)
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(verifyClone))
  discard requireGit(q(gitBin) & " -C " & q(verifyClone) &
    " fetch origin refs/notes/reprobuild/certificates:" &
    "refs/notes/reprobuild/certificates")
  readAttachedCertificates(gitBin, verifyClone, commit)

suite "TC-2 — certificates travel with the pushed commit":

  test "t_certificates_travel_with_pushed_commit":
    let gitBin = findExe("git")
    if gitBin.len == 0 or findExe("ssh-keygen").len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "travel")
      defer: removeDir(fx.scratch)
      seedLock(fx)

      # --- issue a REAL certificate via the TC-1 path ---------------------
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
      check cert.commit == fx.libASha
      check "t-unit" in cert.targets

      # --- attach it to commit C (the TC-2 carrier) -----------------------
      let att = attachCertificate(gitBin, fx.libAPath, fx.libASha, cert)
      check att.ok

      # A SECOND platform's certificate for the SAME commit. We can only run
      # on one real platform, so this one is a synthetic-platform clone of the
      # genuine cert (same commit/lock, a different ``platform`` + target).
      # Accumulation (append, no overwrite) is what we are exercising.
      var cert2 = cert
      cert2.platform =
        if cert.platform == "linux/other": "linux/second"
        else: "linux/other"
      cert2.targets = @["t-integration"]
      let att2 = attachCertificate(gitBin, fx.libAPath, fx.libASha, cert2)
      check att2.ok

      # Locally, BOTH certs are now attached to C (accumulated, not clobbered).
      let localCerts = readAttachedCertificates(gitBin, fx.libAPath, fx.libASha)
      check localCerts.len == 2
      var localPlatforms: seq[string]
      for c in localCerts: localPlatforms.add(c.platform)
      check cert.platform in localPlatforms
      check cert2.platform in localPlatforms

      # --- push: the attached certs must travel to the upstream bare ------
      let pushed = invokePush(fx)
      checkpoint("push output: " & pushed.output)
      check pushed.code == 0
      let report = parseFile(
        fx.workspaceRoot / ".repro" / "workspace" / "push-report.json")
      check report["exitCode"].getInt() == 0
      # The push report records that the cert notes were carried for lib-a.
      var carried: seq[string]
      for n in report["certNotesPushed"]: carried.add(n.getStr())
      check "lib-a" in carried

      # ASSERT 1 + 2: read the certs back FROM THE UPSTREAM (a fresh clone +
      # fetch of the notes ref). BOTH platforms' certs travelled and attest C.
      # Falsifiable: no attach → no note on the upstream → upstreamCerts empty.
      # Falsifiable: overwrite-instead-of-accumulate → only ONE platform here.
      let upstreamCerts = clonedUpstreamCerts(
        gitBin, fx.libAOrigin, fx.libASha, fx.scratch, "after-push")
      check upstreamCerts.len == 2
      var upstreamPlatforms: seq[string]
      for c in upstreamCerts:
        upstreamPlatforms.add(c.platform)
        # Each travelled cert genuinely attests C (round-trips the binding).
        check c.commit == fx.libASha
        check c.schema == testCertificateSchemaV1
      check cert.platform in upstreamPlatforms
      check cert2.platform in upstreamPlatforms
      # Content round-trip: the genuine platform's covered target survived.
      for c in upstreamCerts:
        if c.platform == cert.platform:
          check "t-unit" in c.targets

      # ASSERT 3: a cert whose INTERNAL commit != C is IGNORED by the reader.
      # Attach a misfiled cert (its body claims a DIFFERENT commit) under C's
      # note, then confirm the reader for C does NOT return it. Falsifiable:
      # drop the mismatch filter and this cert is returned (count climbs to 3,
      # and the wrong-commit platform appears).
      var mismatch = cert
      mismatch.commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      mismatch.platform = "linux/mismatch"
      let attM = attachCertificate(gitBin, fx.libAPath, fx.libASha, mismatch)
      check attM.ok
      let afterMismatch =
        readAttachedCertificates(gitBin, fx.libAPath, fx.libASha)
      # Still exactly the two genuine certs for C; the misfiled one is dropped.
      check afterMismatch.len == 2
      for c in afterMismatch:
        check c.commit == fx.libASha
        check c.platform != "linux/mismatch"
