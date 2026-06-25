## TC-6 — THE KEY TEST: the local push gateway's ``pre-receive`` is the
## AUTHORITATIVE certificate check, so an uncovered push is REJECTED even when
## the client tries ``git push --no-verify`` (which skips ALL client hooks and
## cannot be disabled by git config).
##
## Model (Test-Certificates.md §"Enforcement", "Hosts you don't control"):
## a daemon-managed BARE gateway repo is set as the repo's PUSH remote at clone
## time (``remote.origin.pushurl`` → gateway bare; fetch stays on the real
## upstream). The gateway bare's ``pre-receive`` runs the SAME registered-
## signature (TC-5) + coverage (TC-1) check the client gate runs, but on the
## receiving side where ``--no-verify`` has no effect. On success a
## ``post-receive`` FORWARDS the push to a SECOND bare standing in for the real
## upstream (GitHub); on failure the push is rejected and never reaches it.
##
##   (a) A push with NO covering cert — even ``git push --no-verify`` — is
##       REJECTED by the gateway ``pre-receive`` (git reports a non-zero push;
##       the UPSTREAM bare does NOT receive the commit).
##   (b) A push WITH a valid registered-signed COVERING cert is ACCEPTED by
##       ``pre-receive`` AND FORWARDED (``post-receive``) to the upstream bare
##       (the upstream DOES receive the commit).
##
## Falsifiability:
##   - make ``pre-receive`` always exit 0 (e.g. ``gatewayVerifyPush`` always
##     accepts) → the (a) reject test fails: the uncovered ``--no-verify`` push
##     reaches the upstream.
##   - break the forward (``gatewayForwardToUpstream`` a no-op) → the (b)
##     accept test fails: the upstream never gets the covered commit.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos + the REAL
## installed ``pre-receive`` / ``post-receive`` hooks; no network.
## Skip rule: ``git`` or ``ssh-keygen`` missing on PATH.

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
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(result.upstreamBare), certificatesTable))
  result.workspaceRoot = workspaceRoot
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
  check result.commit == headSha
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

suite "TC-6 — local gateway pre-receive rejects uncovered push even " &
    "with --no-verify":

  test "t_local_gateway_pre_receive_rejects_uncovered_push_even_with_no_verify":
    let gitBin = findExe("git")
    let sshKeygen = findExe("ssh-keygen")
    if gitBin.len == 0 or sshKeygen.len == 0:
      skip()
    else:
      let policy =
        "[certificates]\n" &
        "gate_mode = \"required\"\n" &
        "required_targets = [\"t-unit\"]\n" &
        "required_platforms = [\"" & currentPlatformTag() & "\"]\n\n"
      let fx = setupFixture(gitBin, policy)
      defer: removeDir(fx.scratch)

      # ---- wire the gateway as the developer clone's PUSH remote ----------
      # We resolve the lock digest the cert will bind to by issuing the cert
      # below; for the gateway config we read it back from the (b) cert. The
      # (a) reject path needs no digest match (there is no cert at all), so we
      # wire with a placeholder lock and REWIRE before (b) with the cert's
      # exact digest — modelling the daemon configuring the gateway from the
      # project's resolved policy + lock.
      let registeredKeysPath = registeredKeyStorePath(fx.workspaceRoot)

      # ---- (a) NO covering cert, even `git push --no-verify` → REJECTED ----
      let newSha = makeNewCommit(gitBin, fx, "uncovered change\n")

      # Wire the gateway now (push-remote → gateway bare; fetch stays upstream).
      var cfgA = GatewayConfig(
        gateMode: cgmRequired,
        requiredTargets: @["t-unit"],
        requiredPlatforms: @[currentPlatformTag()],
        lockDigest: "blake3:placeholder-no-cert-present",
        registeredKeysPath: registeredKeysPath)
      let wiredA = wirePushGateway(gitBin, fx.libAPath, fx.gatewayBare,
        fileUrl(fx.upstreamBare), cfgA)
      check wiredA.ok

      # The push must go through the gateway (pushurl). REPROBUILD_REPRO points
      # the thin hooks at the test's freshly-built binary so the gateway's
      # ``repro gateway pre-receive`` runs even outside a PATH-installed repro.
      let noVerifyPush = runShell(shellCommand(@[
        gitBin, "-C", fx.libAPath, "push", "--no-verify", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("(a) --no-verify push output: " & noVerifyPush.output)
      # Falsifiable: if pre-receive always accepted, the push would SUCCEED and
      # the upstream would receive ``newSha``.
      check noVerifyPush.code != 0
      check ("REJECTED" in noVerifyPush.output or
             "rejected" in noVerifyPush.output)
      # The upstream bare must NOT have the uncovered commit.
      check not upstreamHasCommit(gitBin, fx.upstreamBare, newSha)

      # ---- (b) valid registered-signed COVERING cert → ACCEPTED+FORWARDED --
      # Mint the cert: publish HEAD to upstream so issuance's published check
      # passes, then rewind upstream to seed so the gateway forward genuinely
      # advances it (see ``publishDirectly`` / ``rewindUpstreamToSeed``).
      publishDirectly(gitBin, fx)
      # Seed the workspace lock now that HEAD is the new commit, so the lock-
      # currency precondition of issuance holds (the lock binds the closure at
      # the commit being certified).
      seedLock(fx)
      let cert = issueAndAttachCert(gitBin, fx, newSha)
      rewindUpstreamToSeed(gitBin, fx)
      # Confirm the rewind: the upstream tip is back at seed before the gateway
      # push, so the forward assertion below proves the gateway advanced it.
      check not upstreamHasCommit(gitBin, fx.upstreamBare, newSha)
      # Rewire the gateway config with the cert's EXACT lock digest so coverage
      # binds correctly (the daemon would resolve the same digest from the
      # workspace lock the cert was issued against).
      var cfgB = cfgA
      cfgB.lockDigest = cert.lock
      writeFile(gatewayConfigPath(fx.gatewayBare),
        serializeGatewayConfig(GatewayConfig(
          gateMode: cgmRequired,
          requiredTargets: @["t-unit"],
          requiredPlatforms: @[currentPlatformTag()],
          lockDigest: cert.lock,
          registeredKeysPath: registeredKeysPath,
          upstreamUrl: fileUrl(fx.upstreamBare))))

      # Push the branch AND the certificate notes ref through the gateway. The
      # notes ref carries the attestation the pre-receive verifies.
      let coveredPush = runShell(shellCommand(@[
        gitBin, "-C", fx.libAPath, "push", "origin", "main",
        certificateNotesRef & ":" & certificateNotesRef],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("(b) covered push output: " & coveredPush.output)
      # Falsifiable: if coverage were not actually checked, the cert would not
      # flip this; if the forward broke, the upstream would never get the
      # commit even though pre-receive accepted.
      check coveredPush.code == 0
      # The REAL upstream bare must now have the covered commit (post-receive
      # forwarded it).
      check upstreamHasCommit(gitBin, fx.upstreamBare, newSha)
