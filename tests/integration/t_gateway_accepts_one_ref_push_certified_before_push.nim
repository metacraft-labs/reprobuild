## Agents-Push-Gate.md §4.1–§4.2 (Sovereign-CI-Fleet P6.b/P6.c) — the
## `agents` gate end to end on a real local gateway, with no publish-first
## workaround; and §4.3's one-ref push, as TC-8c (operator decision D12)
## leaves it:
##
##   1. CERTIFY BEFORE PUSH (§4.1). A clean, committed, NOT-yet-published HEAD
##      is issued a `pre-commit` certificate, delivered to the standard local
##      certificate store (TC-8c).
##   2. NO STORE READ AT THE GATEWAY (D12). A plain one-ref
##      `git push --no-verify origin main` carries no certificate note, and
##      the gateway reads no certificate store any more, so under `required`
##      it is REFUSED — although the certificate sits in the local store.
##      A push that runs the managed hook gets there, because the hook propagates
##      notes from the store first; `--no-verify` skips it.
##   3. ANY ONE PLATFORM (§4.2), BRANCH + NOTES. The certificate is noted on
##      the pushed tree and the branch is pushed together with the notes ref;
##      the pushed tree's policy (TC-9d: a requirement on
##      `anyPlatform`) is met by the host's
##      own platform and the push is forwarded.
##
## Negative control in the same fixture: a second commit with no certificate,
## pushed the same way (with the notes ref), is REJECTED and never reaches the
## upstream.
##
## Falsifiability: dropping the issuance exemption leaves no certificate
## (step 1 fails); reintroducing a gateway store read accepts the one-ref push
## (step 2 fails); treating "*" as a literal platform rejects the covered push,
## because no certificate names the platform "*" (step 3 fails); a gateway
## that accepts everything lets the negative control through.
##
## Hermetic: local `git init --bare` repos and the REAL installed gateway hooks
## driving the built `repro`; no network, no mocks.
## Skip rule: `git` or `ssh-keygen` missing on PATH.

import repro_test_support/reasoned_skip
import std/[json, options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests
import repro_lock
import repro_lock/certificate_policy
import ./every_branch_policy

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
                     policyLock = ""; branch = "main"): string =
  ## Seed the REAL upstream bare with an initial commit, then return its SHA.
  ## ``policyLock``, when given, is committed as the seed's ``repro.lock``:
  ## since TC-9d the certificate policy lives there, in the content a gate
  ## judges, and every later commit carries it to the gateway.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(upstreamPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"TC6 Seeder\"")
  writeFile(workPath / "README.md", "TC-6 fixture\n")
  if policyLock.len > 0:
    writeFile(workPath / "repro.lock", policyLock)
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
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

proc projectToml(libAUrl: string): string =
  ## No certificate policy here: the retired `[certificates]` table would
  ## make the manifest refuse to load (TC-9d).
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
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
    certStore: string      ## the scratch local certificate store (user root)

proc setupFixture(gitBin, policyLock: string): Fixture =
  result.scratch = createTempDir("repro-tc6-", "")
  result.certStore = isolateCertificateStore(result.scratch)
  result.reproBin = reproBinary()
  result.upstreamBare = result.scratch / "upstream-lib-a.git"
  result.gatewayBare = result.scratch / "gateway-lib-a.git"
  result.seedSha = seedGitUpstream(gitBin, result.upstreamBare,
    result.scratch / "seed-lib-a", policyLock)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(result.upstreamBare)))
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
  let content = treeContentId(gitBin, fx.libAPath, headSha)
  result = issuedCertificate(fx.certStore, content, currentPlatformTag()).cert
  check result.vcs.base == headSha
  check result.vcs.content == content
  check "t-unit" in result.targets
  let att = attachCertificate(gitBin, fx.libAPath, result)
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
      # The policy the pushed tree records (TC-9d): one every-branch
      # `required` rule, `pre-commit` on any platform, committed in
      # lib-a's repro.lock by the seed. The gateway config carries none.
      let policy = replaceCertificatePolicySection(
        serializeLockedDependencies(LockedDependencies(
          schema: "reprobuild.solved-graph-lock.v2", deps: @[])),
        everyBranchSnapshot(pmRequired, ["pre-commit"],
    ["*"], name = "lib-a"))
      let fx = setupFixture(gitBin, policy)
      defer: removeDir(fx.scratch)
      let lockDir = lockRecordsDirFor(
        fx.workspaceRoot / ".repro" / "manifests", "lib-a", "lib-a")
      let wired = wirePushGateway(gitBin, fx.libAPath, fx.gatewayBare,
        fileUrl(fx.upstreamBare), GatewayConfig(
          lockRecordsDir: lockDir,
          registeredKeysPath: registeredKeyStorePath(fx.workspaceRoot)))
      check wired.ok

      # ---- 1. certify the clean, UNPUBLISHED head -------------------------
      let covered = makeNewCommit(gitBin, fx, "certified change\n")
      seedLock(fx)
      check not upstreamHasCommit(gitBin, fx.upstreamBare, covered)
      let issued = certifyPreCommit(fx)
      checkpoint("certify output: " & issued.output)
      check issued.code == 0
      let content = treeContentId(gitBin, fx.libAPath, covered)
      let stored = issuedCertificate(fx.certStore, content,
        currentPlatformTag())
      check "pre-commit" in stored.cert.targets
      # Nothing under the workspace's retired certificate directory.
      check not dirExists(fx.workspaceRoot / ".repro" / "workspace" /
        "certificates") or storedCertificateFiles(fx.workspaceRoot / ".repro" /
        "workspace" / "certificates", content).len == 0
      # Certifying published nothing.
      check not upstreamHasCommit(gitBin, fx.upstreamBare, covered)

      # ---- 2. a plain one-ref push is REFUSED: no note, no store read -----
      let oneRef = runShell(shellCommand(@[
        gitBin, "-C", fx.libAPath, "push", "--no-verify", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("one-ref push: " & oneRef.output)
      check oneRef.code != 0
      check "no certificate note on the pushed tree" in oneRef.output
      check not upstreamHasCommit(gitBin, fx.upstreamBare, covered)

      # ---- 3. noted on the tree, pushed with the notes ref: FORWARDED -----
      check attachCertificate(gitBin, fx.libAPath, stored.cert).ok
      let push = runShell(shellCommand(@[
        gitBin, "-C", fx.libAPath, "push", "--no-verify", "origin", "main",
        certificateNotesRef & ":" & certificateNotesRef],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("covered push: " & push.output)
      check push.code == 0
      check "COVERED by 1 trusted certificate" in push.output
      check upstreamHasCommit(gitBin, fx.upstreamBare, covered)

      # ---- negative control: an uncertified commit is REJECTED ------------
      let uncovered = makeNewCommit(gitBin, fx, "uncertified change\n")
      seedLock(fx)
      let rejected = runShell(shellCommand(@[
        gitBin, "-C", fx.libAPath, "push", "--no-verify", "origin", "main",
        certificateNotesRef & ":" & certificateNotesRef],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("uncovered push: " & rejected.output)
      check rejected.code != 0
      check "any platform" in rejected.output
      check not upstreamHasCommit(gitBin, fx.upstreamBare, uncovered)
      check upstreamHasCommit(gitBin, fx.upstreamBare, covered)

  test "\"*\" cannot be combined with concrete platforms":
    ## The policy refuses the mix rather than guess at it: both when it is
    ## built (the DSL validates at compile time) and when a snapshot carrying
    ## it is read (every gate reads through the strict reader).
    expect CertificatePolicySnapshotError:
      discard everyBranchPolicy(pmRequired, ["pre-commit"],
        ["*", "linux/amd64"])
    let mixed = everyBranchSnapshot(pmRequired, ["pre-commit"], ["*"])
      .replace("[\"*\"]", "[\"*\", \"linux/amd64\"]")
    expect CertificatePolicySnapshotError:
      discard parseCertificatePolicySnapshot(mixed)
    let ok = everyBranchPolicy(pmRequired, ["pre-commit"], ["*"])
    check ok.rules[0].requires[0].platforms == @["*"]

  test "\"*\" is per-platform coverage, never a cross-platform union":
    const content = "git-tree-sha1:c0ffee0000000000000000000000000000c0ffee"
    proc mk(platform: string; targets: seq[string]): TestCertificate =
      TestCertificate(schema: testCertificateSchemaV1,
        framework: reprobuildFrameworkId, platform: platform,
        targets: targets, result: tcrPassed,
        vcs: TestCertificateVcs(repo: "r", content: content))
    let state = stateWithKnownContent(
      [KnownContentId(algorithm: "git-tree-sha1", id: content)])
    let split = @[mk("linux/amd64", @["a"]), mk("macos/arm64", @["b"])]
    check uncoveredPlatforms(split, @["*"], @["a", "b"], state).len == 1
    check uncoveredPlatforms(@[mk("macos/arm64", @["a", "b"])], @["*"],
      @["a", "b"], state).len == 0
    check uncoveredPlatforms(@[], @["*"], @["a"], state) ==
      @["any platform (missing: <no certificate>)"]

  test "a policy's any-platform requirement beside a concrete one (TC-9c)":
    ## TC-9c reconciliation of P6.c. The policy declares ``platforms`` per
    ## ``requires``, so one rule can hold an any-platform name and a concrete
    ## one at once — which the retired ``[certificates]`` table (one platform
    ## list for every target) could not say. The gate's evaluator judges each
    ## platform set on its own, through the production verifier (registered
    ## signatures by the real ``ssh-keygen``):
    ##
    ##   requires pre-commit (any platform), unit-suite (linux/amd64)
    ##
    ##   * pre-commit on macos/arm64 + unit-suite on linux/amd64 → covered:
    ##     the any-platform name is met by ONE platform alone, and the
    ##     concrete name by its own platform;
    ##   * pre-commit and unit-suite both on macos/arm64: pre-commit is met
    ##     (any platform), but unit-suite on macos/arm64 does not stand in for
    ##     linux/amd64 → not covered, naming unit-suite on linux/amd64.
    if findExe("ssh-keygen").len == 0:
      skip("ssh-keygen not on PATH; this case signs certificates")
    else:
      const content = "git-tree-sha1:c0ffee0000000000000000000000000000c0ffee"
      let scratch = createTempDir("repro-tc9c-anyplatform-", "")
      defer: removeDir(scratch)
      let key = genEd25519Key(scratch / "keys", "tc9c-key", "tc9c-any-key")
      writeRegistry(scratch, @[RegisteredKey(keyId: "tc9c-any-key",
        publicKey: key.pub, status: rksActive)])
      let keys = readRegisteredKeyStoreChecked(registeredKeyStorePath(scratch))
      proc signed(platform: string; targets: seq[string]): FoundCertificate =
        var cert = TestCertificate(schema: testCertificateSchemaV1,
          framework: reprobuildFrameworkId, project: "lib-a",
          platform: platform, targets: targets, result: tcrPassed,
          issuedAt: "2026-10-15T00:00:00Z", issuer: "tc9c-fixture",
          vcs: TestCertificateVcs(repo: "lib-a", content: content),
          commands: @[TestCertificateCommand(argv: @["sh", "-c", "exit 0"])])
        signCertificateOnIssuance(cert, "tc9c-any-key", key.priv)
        FoundCertificate(name: platform & ":" & targets.join(","),
          read: CertificateReadResult(status: crsOk, cert: cert))
      let state = stateWithKnownContent(
        [KnownContentId(algorithm: "git-tree-sha1", id: content)])
      let requires = @[
        PolicyRequirement(certificate: "pre-commit", platforms: @["*"]),
        PolicyRequirement(certificate: "unit-suite",
          platforms: @["linux/amd64"])]
      # D8: a state that is not a commit is not looked up in a record store.
      let lockSource = recordStoreLockSource("")
      let covered = evaluateRequirementCoverage(
        @[signed("macos/arm64", @["pre-commit"]),
          signed("linux/amd64", @["unit-suite"])],
        state, requires, keys, lockSource)
      checkpoint(describeCoverageVerdict(covered))
      check covered.outcome == voCovered
      let short = evaluateRequirementCoverage(
        @[signed("macos/arm64", @["pre-commit", "unit-suite"])],
        state, requires, keys, lockSource)
      checkpoint(describeCoverageVerdict(short))
      check short.outcome == voNotCovered
      check short.unmet == @[(name: "unit-suite", platform: "linux/amd64")]
