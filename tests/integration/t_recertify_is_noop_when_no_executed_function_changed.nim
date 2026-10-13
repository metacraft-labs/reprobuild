## TC-1 — re-certification is incremental: a re-certify with NO relevant
## change is a NO-OP (the existing valid certificate stands, the tests are
## NOT re-run); after a relevant change, the re-certify DOES re-run and
## re-issues.
##
## How the test PROVES "tests not re-run": the fixture's trivial test target
## appends a line to a run-counter file every time it actually executes. The
## test asserts the counter does not grow across a no-op re-certify, and DOES
## grow when a relevant change forces a re-run.
##
## How the no-op decision is driven (HONEST):
##   TC-8b: the certificate names the tested CONTENT (the content id of the
##   tracked files, the committed lock included), which is a precise
##   fingerprint of the tested state. When it is unchanged AND a covering
##   certificate already exists, nothing relevant changed → no-op. A change
##   to tracked files changes the content → re-run, before it is committed
##   (TC-8d); committing that tested content, and then amending only the
##   commit message, re-runs nothing. (When a
##   ct-incremental trace dir is supplied, the canonical adapter's
##   per-function change signal is also consulted; this hermetic test drives
##   the decision from the content signal, which the milestone note records
##   as the sandbox-runnable path.)
##
## Falsifiability: if the re-certify ALWAYS re-ran (no-op disabled), the
## "counter unchanged" check fails. See the milestone note.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

# TC-5 daemon-signing helpers (``genEd25519Key`` / ``daemonKeyEnv``).
# Issuance signs the certificate with the daemon key supplied via
# ``REPRO_DAEMON_SIGNING_KEY`` / ``REPRO_DAEMON_KEY_ID``; without it
# ``certify`` issues NOTHING (the attestation is withheld because the
# daemon signing key is absent) and the certificate file is never
# written. The earlier revision of this test omitted the key, so the
# first certify silently produced no cert and the subsequent
# ``readFile(certOut)`` raised IOError. Provision a real ed25519 key
# the same way the TC-1/TC-5 issuance tests do so the cert is actually
# signed + written.
include tc5_cert_signing_helpers

const tc1nKeyId = "tc1n-daemon-key"

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
    daemonKey: string   ## ed25519 private key issuance signs the cert with
    certStore: string   ## the scratch local certificate store (user root)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-tc1n-" & slug & "-", "")
  result.certStore = isolateCertificateStore(result.scratch)
  result.reproBin = reproBinary()
  # TC-5: issuance signs the certificate with the daemon key; provide a
  # real ed25519 key (and register it via the env overlay below) so the
  # cert is signed + written rather than withheld.
  let key = genEd25519Key(result.scratch / "daemon-keys", "tc1n-key", tc1nKeyId)
  result.daemonKey = key.priv
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASeed = result.scratch / "seed-lib-a"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin, result.libASeed)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.workspaceRoot = workspaceRoot
  seedManifestLockStore(gitBin, workspaceRoot)
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

proc seedLock(fx: Fixture) =
  let res = runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot]))
  if res.code != 0:
    checkpoint("workspace lock failed: " & res.output)
  check res.code == 0

proc writeCountingFixture(path, selector, counterFile: string) =
  ## The test target appends one line to ``counterFile`` every time it runs,
  ## so a no-op re-certify (which does NOT re-run the target) leaves the line
  ## count unchanged.
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
  cmd.add(%"sh"); cmd.add(%"-c")
  cmd.add(%("echo ran >> " & q(counterFile) & "; exit 0"))
  e["runCmd"] = cmd
  e["testName"] = %selector
  edges.add(e)
  obj["testEdges"] = edges
  obj["buildActions"] = newJArray()
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  writeFile(path, obj.pretty() & "\n")

proc runCount(counterFile: string): int =
  if not fileExists(counterFile): return 0
  for line in readFile(counterFile).splitLines():
    if line.strip().len > 0: inc result

proc runCertify(fx: Fixture; fixtureJson: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "certify",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib-a")],
    daemonKeyEnv(fx.daemonKey, tc1nKeyId)),
    fx.workspaceRoot)

suite "TC-1 — re-certify is a no-op when no executed function changed":

  test "t_recertify_is_noop_when_no_executed_function_changed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "noop")
      defer: removeDir(fx.scratch)
      seedLock(fx)

      let counterFile = fx.scratch / "run-counter.txt"
      let fixtureJson = fx.scratch / "fixture.json"
      writeCountingFixture(fixtureJson, "t-unit", counterFile)

      # TC-8c: the certificate lives in the local store, under the content.
      let libA = fx.workspaceRoot / "lib-a"
      let content1 = treeContentId(gitBin, libA, fx.libASha)

      # --- 1. initial certify: runs the target, issues the cert -----------
      let r1 = runCertify(fx, fixtureJson)
      if r1.code != 0:
        checkpoint("certify #1 output: " & r1.output)
      check r1.code == 0
      let files1 = storedCertificateFiles(fx.certStore, content1)
      check files1.len == 1
      check runCount(counterFile) == 1
      let certOut = files1[0]
      let certBytes1 = readFile(certOut)

      # --- 2. re-certify with NO relevant change: NO-OP -------------------
      let r2 = runCertify(fx, fixtureJson)
      check r2.code == 0
      # The decisive assertion: the target did NOT run again.
      check runCount(counterFile) == 1
      check r2.output.contains("no-op")
      # The existing certificate still stands, byte-identical.
      check readFile(certOut) == certBytes1
      check storedCertificateFiles(fx.certStore, content1) == files1

      # --- 3. a RELEVANT change → re-run + re-issue ------------------------
      # TC-8d: the change is certified BEFORE it is committed. It changes the
      # tracked CONTENT, so the existing certificate does not cover it and the
      # target runs again.
      let libA2 = fx.workspaceRoot / "lib-a"
      writeFile(libA2 / "feature.nim", "proc f() = discard\n")
      discard requireGit(q(gitBin) & " -C " & q(libA2) & " add feature.nim")
      let content2 = workingTreeContentIdOf(gitBin, libA2,
        fx.scratch / "expected-index")
      check content2 != content1
      let r3 = runCertify(fx, fixtureJson)
      if r3.code != 0:
        checkpoint("certify #3 output: " & r3.output)
      check r3.code == 0
      check runCount(counterFile) == 2
      let newFiles = storedCertificateFiles(fx.certStore, content2)
      check newFiles.len == 1
      if newFiles.len == 1:
        let newCert = readCertificateFile(newFiles[0])
        check newCert.vcs.content == content2
        check newCert.vcs.base == fx.libASha
        check "t-unit" in newCert.targets

      # --- 4. committing the tested content re-runs nothing ----------------
      discard requireGit(q(gitBin) & " -C " & q(libA2) & " commit -m feature")
      let newSha = requireGit(q(gitBin) & " -C " & q(libA2) &
        " rev-parse HEAD").strip()
      check treeContentId(gitBin, libA2, newSha) == content2
      let r4 = runCertify(fx, fixtureJson)
      checkpoint("certify #4 output: " & r4.output)
      check r4.code == 0
      check r4.output.contains("no-op")
      check runCount(counterFile) == 2

      # --- 5. a message-only amend re-runs nothing either ------------------
      discard requireGit(q(gitBin) & " -C " & q(libA2) &
        " commit --amend -m reworded")
      let r5 = runCertify(fx, fixtureJson)
      checkpoint("certify #5 output: " & r5.output)
      check r5.code == 0
      check r5.output.contains("no-op")
      check runCount(counterFile) == 2
      check storedCertificateFiles(fx.certStore, content2) == newFiles
