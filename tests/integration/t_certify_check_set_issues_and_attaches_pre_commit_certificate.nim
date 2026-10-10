## Agents-Push-Gate.md §3.2 / §4.4 (Sovereign-CI-Fleet P6.e) —
## `repro certify --check-set` runs a repository's pre-commit check set as the
## certifiable target `pre-commit`, through the ordinary issuance path, and
## attaches the result as a git note.
##
##   1. A FAILING check set issues nothing and exits 2.
##   2. A PASSING check set on a clean, committed, UNPUBLISHED head issues a
##      signed certificate covering `pre-commit`, attaches it to
##      `refs/notes/reprobuild/certificates`, and leaves the repository CLEAN
##      (the run's files go to a scratch directory, never the repo).
##   3. Re-running is idempotent: no second note record is appended.
##
## Falsifiability: a certify that ignored the run's result would issue in (1);
## a certify that wrote its fixture or logs into the repo would fail the
## cleanliness check in (2); a certify that attached unconditionally would
## leave two records in (3).
##
## The check-set command is passed with `--check-set-command`, so the test
## does not depend on prek being installed; the default (`prek run
## --all-files` over the committed `.pre-commit-config.yaml`) differs only in
## the argv the certificate records.
## Hermetic: local repos, the built `repro`; no network, no mocks.
## Skip rule: `git` or `ssh-keygen` missing on PATH.

import repro_test_support/reasoned_skip
import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

include tc5_cert_signing_helpers

const tc6KeyId = "tc6-daemon-key"

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

proc seedGitUpstream(gitBin, upstreamPath, workPath: string;
                     branch = "main"): string =
  ## Seed the REAL upstream bare with an initial commit, then return its SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(upstreamPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"TC6 Seeder\"")
  writeFile(workPath / "README.md", "TC-6 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(upstreamPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, upstreamPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(upstreamPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"TC6 Tester\"")

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
    upstreamBare: string   ## the REAL upstream (stands in for GitHub)
    gatewayBare: string    ## the daemon-managed gateway bare
    libAPath: string       ## the developer's clone
    seedSha: string
    daemonKey: string

proc setupFixture(gitBin, certificatesTable: string): Fixture =
  result.scratch = createTempDir("repro-tc6-", "")
  result.reproBin = reproBinary()
  result.upstreamBare = result.scratch / "upstream-lib-a.git"
  result.gatewayBare = result.scratch / "gateway-lib-a.git"
  result.seedSha = seedGitUpstream(gitBin, result.upstreamBare,
    result.scratch / "seed-lib-a")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(result.upstreamBare), certificatesTable))
  result.workspaceRoot = workspaceRoot
  seedManifestLockStore(gitBin, workspaceRoot)
  result.libAPath = workspaceRoot / "lib-a"
  cloneInto(gitBin, result.upstreamBare, result.libAPath)
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

  let key = genEd25519Key(result.scratch / "daemon-keys", "tc6-key", tc6KeyId)
  result.daemonKey = key.priv
  writeRegistry(workspaceRoot,
    @[RegisteredKey(keyId: tc6KeyId, publicKey: key.pub, status: rksActive)])

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
  cmd.add(%"sh"); cmd.add(%"-c"); cmd.add(%scriptCmd)
  e["runCmd"] = cmd
  e["testName"] = %selector
  edges.add(e)
  obj["testEdges"] = edges
  obj["buildActions"] = newJArray()
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  writeFile(path, obj.pretty() & "\n")

proc makeNewCommit(gitBin: string; fx: Fixture; content: string): string =
  ## Make a NEW commit in the developer clone (so HEAD differs from the seed
  ## already on the upstream). This is the commit the developer tries to push.
  writeFile(fx.libAPath / "feature.txt", content)
  discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) & " add feature.txt")
  discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
    " commit -m feature")
  result = requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
    " rev-parse HEAD").strip()

proc publishDirectly(gitBin: string; fx: Fixture) =
  ## Publish the clone's current HEAD directly to the upstream bare (bypassing
  ## the gateway). TC-1 issuance refuses to certify an UNPUBLISHED commit (it
  ## reuses the pre-push gate's published check against ``origin`` = the
  ## fetch/upstream URL), so the cert can only be minted once HEAD is on
  ## upstream. We publish here, mint the cert, then REWIND the upstream back to
  ## the seed (``rewindUpstreamToSeed``) so the gateway forward in (b)
  ## genuinely ADVANCES the upstream from seed → the covered commit — a faithful
  ## "covered push lands on the upstream" assertion rather than a no-op.
  let res = runCmd(q(gitBin) & " -C " & q(fx.libAPath) &
    " push " & q(fileUrl(fx.upstreamBare)) & " main")
  if res.code != 0:
    checkpoint("direct publish failed: " & res.output)
  check res.code == 0
  # Update the ``origin/main`` remote-tracking ref so issuance's published
  # check (``git branch -r --contains HEAD`` → ``origin/...``) sees HEAD as
  # published. ``origin``'s FETCH url is the upstream, so a fetch advances the
  # tracking ref to the just-published commit.
  let fetched = runCmd(q(gitBin) & " -C " & q(fx.libAPath) & " fetch origin")
  if fetched.code != 0:
    checkpoint("fetch origin failed: " & fetched.output)
  check fetched.code == 0

proc rewindUpstreamToSeed(gitBin: string; fx: Fixture) =
  discard requireGit(q(gitBin) & " -C " & q(fx.upstreamBare) &
    " update-ref refs/heads/main " & q(fx.seedSha))

proc issueAndAttachCert(gitBin: string; fx: Fixture; headSha: string):
    TestCertificate =
  ## Drive the TC-1 issuance path (a REAL passing run, clean state) to mint a
  ## genuine daemon-signed cert for ``headSha``, then attach it (TC-2) to the
  ## pushed commit in the developer clone.
  let fixtureJson = fx.scratch / "fixture-pass.json"
  writeTestFixtureJson(fixtureJson, "t-unit", "exit 0")
  let issued = runShell(shellCommand(@[
    fx.reproBin, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1",
    "--certify",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath],
    daemonKeyEnv(fx.daemonKey, tc6KeyId)), fx.workspaceRoot)
  if issued.code != 0:
    checkpoint("repro test output: " & issued.output)
  check issued.code == 0
  let certFile = defaultCertificatePath(
    fx.workspaceRoot, headSha, currentPlatformTag())
  check fileExists(certFile)
  result = readCertificateFile(certFile)
  check result.vcs.commit == headSha
  check "t-unit" in result.targets
  let att = attachCertificate(gitBin, fx.libAPath, headSha, result)
  check att.ok

proc upstreamHasCommit(gitBin, upstreamBare, sha: string): bool =
  ## True iff the REAL upstream bare contains ``sha`` as a reachable object on
  ## its branch (``git cat-file -e`` + the branch actually points there).
  let exists = runCmd(q(gitBin) & " -C " & q(upstreamBare) &
    " cat-file -e " & q(sha & "^{commit}"))
  if exists.code != 0:
    return false
  let tip = runCmd(q(gitBin) & " -C " & q(upstreamBare) &
    " rev-parse refs/heads/main")
  tip.code == 0 and tip.output.strip() == sha


proc certifyCheckSet(fx: Fixture; command: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "certify", "--check-set",
    "--check-set-command=" & command,
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath],
    daemonKeyEnv(fx.daemonKey, tc6KeyId)), fx.libAPath)

proc noteRecordCount(gitBin: string; fx: Fixture; sha: string): int =
  let note = runCmd(q(gitBin) & " -C " & q(fx.libAPath) & " notes --ref " &
    q(certificateNotesRef) & " show " & sha)
  if note.code != 0: return 0
  note.output.count("# --- reprobuild-certificate ---")

suite "P6.e — repro certify --check-set":

  test "t_certify_check_set_issues_and_attaches_pre_commit_certificate":
    let gitBin = findExe("git")
    if gitBin.len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this case signs a certificate in a repository")
    else:
      let fx = setupFixture(gitBin, "")
      defer: removeDir(fx.scratch)
      let head = makeNewCommit(gitBin, fx, "change under check\n")
      seedLock(fx)
      let certFile = defaultCertificatePath(fx.workspaceRoot, head,
        currentPlatformTag())

      # ---- 1. a failing check set issues nothing --------------------------
      let failing = certifyCheckSet(fx, "echo 'lint: bad file' >&2; exit 3")
      checkpoint("failing: " & failing.output)
      check failing.code == 2
      check not fileExists(certFile)
      check noteRecordCount(gitBin, fx, head) == 0

      # ---- 2. a passing check set issues, signs, attaches -----------------
      let passing = certifyCheckSet(fx, "true")
      checkpoint("passing: " & passing.output)
      check passing.code == 0
      check fileExists(certFile)
      if fileExists(certFile):
        let cert = readCertificateFile(certFile)
        check cert.vcs.commit == head
        check cert.targets == @["pre-commit"]
        check cert.isSigned
        check cert.commands.len == 1
      check noteRecordCount(gitBin, fx, head) == 1
      let status = runCmd(q(gitBin) & " -C " & q(fx.libAPath) &
        " status --porcelain --untracked-files=all")
      check status.code == 0
      check status.output.strip() == ""
      # Certifying published nothing.
      check not upstreamHasCommit(gitBin, fx.upstreamBare, head)

      # ---- 3. idempotent ----------------------------------------------------
      let again = certifyCheckSet(fx, "true")
      check again.code == 0
      check noteRecordCount(gitBin, fx, head) == 1
