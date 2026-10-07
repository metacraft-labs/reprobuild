## Agents-Push-Gate.md §4.1–§4.3 (Sovereign-CI-Fleet P6.b/P6.c/P6.d) — the
## `agents` gate end to end on a real local gateway, with no publish-first
## workaround:
##
##   1. CERTIFY BEFORE PUSH (§4.1). A clean, committed, NOT-yet-published HEAD
##      is issued a `pre-commit` certificate. Before this, issuance refused it
##      as unpublished while the gateway refused the push without it, and the
##      TC-6 test had to publish directly to the upstream and rewind it to mint
##      a certificate at all.
##   2. ANY ONE PLATFORM (§4.2). The policy says `required_platforms = ["*"]`;
##      one certificate from the host's own platform satisfies it.
##   3. ONE-REF PUSH (§4.3). The developer runs a plain
##      `git push --no-verify origin main` — no notes ref. The gateway finds
##      the certificate in the workspace certificate store and forwards.
##
## Negative control in the same fixture: a second commit with no certificate,
## pushed the same way, is REJECTED and never reaches the upstream.
##
## Falsifiability: dropping the issuance exemption leaves no certificate file
## (step 1 fails); dropping the store carrier rejects the covered one-ref push
## (step 3 fails); treating "*" as a literal platform rejects it too, because
## no certificate names the platform "*" (step 2 fails); a gateway that
## accepts everything lets the negative control through.
##
## Hermetic: local `git init --bare` repos and the REAL installed gateway hooks
## driving the built `repro`; no network, no mocks.
## Skip rule: `git` or `ssh-keygen` missing on PATH.

import repro_test_support/reasoned_skip
import std/[json, options, os, osproc, strutils, tempfiles, unittest]

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


proc certifyPreCommit(fx: Fixture): CmdResult =
  let fixtureJson = fx.scratch / "fixture-pre-commit.json"
  writeTestFixtureJson(fixtureJson, "pre-commit", "exit 0")
  runShell(shellCommand(@[
    fx.reproBin, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1",
    "--certify",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath],
    daemonKeyEnv(fx.daemonKey, tc6KeyId)), fx.workspaceRoot)

suite "Agents push gate — certify before push, any platform, one-ref push":

  test "t_gateway_accepts_one_ref_push_certified_before_push":
    let gitBin = findExe("git")
    if gitBin.len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this case signs a certificate in a repository")
    else:
      let policy =
        "[certificates]\n" &
        "gate_mode = \"required\"\n" &
        "required_targets = [\"pre-commit\"]\n" &
        "required_platforms = [\"*\"]\n\n"
      let fx = setupFixture(gitBin, policy)
      defer: removeDir(fx.scratch)
      let lockDir = lockRecordsDirFor(
        fx.workspaceRoot / ".repro" / "manifests", "lib-a", "lib-a")
      let wired = wirePushGateway(gitBin, fx.libAPath, fx.gatewayBare,
        fileUrl(fx.upstreamBare), GatewayConfig(
          gateMode: cgmRequired,
          requiredTargets: @["pre-commit"],
          requiredPlatforms: @["*"],
          lockRecordsDir: lockDir,
          registeredKeysPath: registeredKeyStorePath(fx.workspaceRoot),
          certificateStoreDir: fx.workspaceRoot / ".repro" / "workspace" /
            "certificates"))
      check wired.ok

      # ---- 1. certify the clean, UNPUBLISHED head -------------------------
      let covered = makeNewCommit(gitBin, fx, "certified change\n")
      seedLock(fx)
      check not upstreamHasCommit(gitBin, fx.upstreamBare, covered)
      let issued = certifyPreCommit(fx)
      checkpoint("certify output: " & issued.output)
      check issued.code == 0
      let certFile = defaultCertificatePath(fx.workspaceRoot, covered,
        currentPlatformTag())
      check fileExists(certFile)
      # Certifying published nothing.
      check not upstreamHasCommit(gitBin, fx.upstreamBare, covered)

      # ---- 2+3. a plain one-ref --no-verify push is ACCEPTED + FORWARDED --
      let push = runShell(shellCommand(@[
        gitBin, "-C", fx.libAPath, "push", "--no-verify", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("covered one-ref push: " & push.output)
      check push.code == 0
      check upstreamHasCommit(gitBin, fx.upstreamBare, covered)

      # ---- negative control: an uncertified commit is REJECTED ------------
      let uncovered = makeNewCommit(gitBin, fx, "uncertified change\n")
      seedLock(fx)
      let rejected = runShell(shellCommand(@[
        gitBin, "-C", fx.libAPath, "push", "--no-verify", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("uncovered one-ref push: " & rejected.output)
      check rejected.code != 0
      check "any platform" in rejected.output
      check not upstreamHasCommit(gitBin, fx.upstreamBare, uncovered)
      check upstreamHasCommit(gitBin, fx.upstreamBare, covered)

  test "\"*\" cannot be combined with concrete platforms":
    let body = CertificatesBody(
      gate_mode: some("required"),
      required_targets: @["pre-commit"],
      required_platforms: @["*", "linux/amd64"])
    expect CatchableError:
      discard resolveCertificatePolicy(body, "projects/x.toml")
    let ok = resolveCertificatePolicy(CertificatesBody(
      gate_mode: some("required"), required_targets: @["pre-commit"],
      required_platforms: @["*"]), "projects/x.toml")
    check ok.requiredPlatforms == @["*"]

  test "\"*\" is per-platform coverage, never a cross-platform union":
    proc mk(platform: string; targets: seq[string]): TestCertificate =
      TestCertificate(schema: testCertificateSchemaV1,
        framework: reprobuildFrameworkId, platform: platform,
        targets: targets, result: tcrPassed,
        vcs: TestCertificateVcs(repo: "r", commit: "c0ffee", clean: true))
    let split = @[mk("linux/amd64", @["a"]), mk("macos/arm64", @["b"])]
    check uncoveredPlatforms(split, @["*"], @["a", "b"], "c0ffee").len == 1
    check uncoveredPlatforms(@[mk("macos/arm64", @["a", "b"])], @["*"],
      @["a", "b"], "c0ffee").len == 0
    check uncoveredPlatforms(@[], @["*"], @["a"], "c0ffee") ==
      @["any platform (missing: <no certificate>)"]
