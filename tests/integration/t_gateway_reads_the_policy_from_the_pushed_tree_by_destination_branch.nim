## TC-9c — the gateway's ``pre-receive`` reads the requirement from the
## ``[certificate_policy]`` snapshot in the PUSHED commit's ``repro.lock``
## (inside the receive quarantine), under the rule for each update's
## DESTINATION branch, and ratchets ``gate_mode`` against the anchor
## (Test-Certificates.md §"Branch matching", Push-Gateway-Wiring-And-Policy
## §4.2).
##
## A real gateway bare (its installed hooks driving the built ``repro``) in
## front of a real upstream bare. Every push uses ``--no-verify``, so only the
## receiving side decides. The gateway config is then rewritten in the
## pre-TC-9d format, still BAKING a policy (``required``, ``t-unit`` on this
## platform): since TC-9d such keys are never applied, only reported. The snapshot: rule "agents" requires ``pre-commit`` on any
## platform under ``required``; nothing else matches.
##
##   1. One commit C, carrying no certificate, pushed to ``feature/x``: no
##      rule matches, so it is ACCEPTED and forwarded although the baked
##      ``required`` would have refused it; the gateway says the baked policy
##      is ignored.
##   2. The same C pushed to ``agents``: REFUSED (uncovered), naming
##      ``pre-commit``. With a ``pre-commit`` certificate noted on its tree,
##      ACCEPTED and forwarded: ``agents`` is now anchored at ``required``.
##   3. The ratchet: a commit whose own snapshot relaxes ``agents`` to
##      ``off`` (keeping its ``requires``) is still judged at the anchor's
##      ``required`` and REFUSED, and the gateway says the pushed ``off``
##      cannot relax it. Certified, it is accepted; the NEXT uncovered push is
##      judged at ``off`` and accepted.
##
## Falsifiability: apply the baked keys of an old config → 1 is refused; judge every ref
## by the first ref's branch, or ignore the destination → 1 and 2 agree;
## read the anchor from the pushed commit instead of the upstream → 3's
## relaxing push is accepted.
##
## Hermetic: local bare repos, the built ``repro``; no network. Requires git
## and ssh-keygen.

import std/[os, osproc, strutils, unittest]

include policy_gate_fixture

proc wirePolicyGateway(fx: StoreFixture) =
  ## The gateway, wired with the committed-lock source (no record store) and
  ## the fixture's keys; then its config is rewritten as a pre-TC-9d writer
  ## wrote it, baking a `required` policy the gateway must ignore.
  let cfg = GatewayConfig(
    lockRecordsDir: "",
    registeredKeysPath: registeredKeyStorePath(fx.workspaceRoot))
  let wired = wirePushGateway("git", fx.libAPath, fx.gatewayBare,
    fileUrl(fx.upstreamBare), cfg)
  doAssert wired.ok, wired.diagnostic
  let path = gatewayConfigPath(fx.gatewayBare)
  writeFile(path, readFile(path).replace("[gateway]\n",
    "[gateway]\ngate_mode = \"required\"\n" &
    "required_targets = [\"t-unit\"]\n" &
    "required_platforms = [\"" & currentPlatformTag() & "\"]\n"))
  doAssert parseGatewayConfig(readFile(path)).ignoredPolicyKeys ==
    @["gate_mode", "required_targets", "required_platforms"]

proc upstreamRef(fx: StoreFixture; branch: string): string =
  let res = execCmdEx(quoteShellCommand(@["git", "-C", fx.upstreamBare,
    "rev-parse", "--verify", "--quiet", "refs/heads/" & branch]))
  if res.exitCode != 0: "" else: res.output.strip()

proc noteCertificate(fx: StoreFixture; commit: string; targets: seq[string]) =
  let content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
    commit & "^{tree}")
  check attachCertificate("git", fx.libAPath,
    signedCertFor(fx, content, commit, targets = targets)).ok

suite "TC-9c — the gateway reads the policy from the pushed tree":

  test "t_gateway_reads_the_policy_from_the_pushed_tree_by_destination_branch":
    let fx = setupStoreFixture("", "tc9c-gateway", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    let notes = certificateNotesRef & ":" & certificateNotesRef
    let requiredAgents = snapshotOf([
      policyRule(["agents"], pmRequired, [req("pre-commit", "*")])])
    let c = fx.commitPolicy(requiredAgents, "the policy")
    wirePolicyGateway(fx)

    # ---- 1. feature/x: no rule; the baked required is ignored ------------
    let toFeature = pushToGateway(fx, @[c & ":refs/heads/feature/x"])
    checkpoint("push C to feature/x:\n" & toFeature.output)
    check toFeature.code == 0
    check fx.upstreamRef("feature/x") == c
    check "IGNORED" in toFeature.output
    check "branch 'feature/x' matches no rule" in toFeature.output

    # ---- 2. agents: the agents rule ---------------------------------------
    let toAgents = pushToGateway(fx, @[c & ":refs/heads/agents"])
    checkpoint("push C to agents:\n" & toAgents.output)
    check toAgents.code != 0
    check fx.upstreamRef("agents") == ""
    check "rule \"agents\"" in toAgents.output
    check "'pre-commit' on any platform" in toAgents.output
    check "no anchor" in toAgents.output   # a new branch upstream
    fx.noteCertificate(c, @["pre-commit"])
    let covered = pushToGateway(fx, @[c & ":refs/heads/agents", notes])
    checkpoint("push certified C to agents:\n" & covered.output)
    check covered.code == 0
    check fx.upstreamRef("agents") == c
    check "COVERED by 1 trusted certificate" in covered.output

    # ---- 3. the ratchet: a commit cannot relax the rule judging it --------
    discard fx.mustGit("checkout", "-q", "-b", "agents")
    let relaxed = fx.commitPolicy(snapshotOf([
      policyRule(["agents"], pmOff, [req("pre-commit", "*")])]),
      "relax agents to off")
    let relax = pushToGateway(fx, @["agents:refs/heads/agents"])
    checkpoint("push relaxing commit:\n" & relax.output)
    check relax.code != 0
    check fx.upstreamRef("agents") == c
    check "applied gate_mode required" in relax.output
    check "cannot relax it" in relax.output
    check "read from the" in relax.output   # the anchor's source is named
    fx.noteCertificate(relaxed, @["pre-commit"])
    let relaxCovered = pushToGateway(fx,
      @["agents:refs/heads/agents", notes])
    checkpoint("push certified relaxing commit:\n" & relaxCovered.output)
    check relaxCovered.code == 0
    check fx.upstreamRef("agents") == relaxed
    # Now the anchor itself says off: the next uncovered push is accepted.
    let next = fx.newCommit("next.txt", "next\n")
    let nextPush = pushToGateway(fx, @["agents:refs/heads/agents"])
    checkpoint("push the next commit:\n" & nextPush.output)
    check nextPush.code == 0
    check fx.upstreamRef("agents") == next
    check "applied gate_mode off" in nextPush.output


  test "migration supplies the record-store lock source and repairs existing gateways":
    let fx = setupStoreFixture(requiredPolicy(@["pre-commit"], @["*"]),
      "gateway-record-route")
    defer: removeDir(fx.scratch)
    # Routing belongs to this fixture, never the reviewer's host configuration.
    var savedRoutingEnv: seq[tuple[name, value: string; present: bool]]
    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG", "REPRO_WORKSPACE_CONFIG"]:
      savedRoutingEnv.add((name, getEnv(name), existsEnv(name)))
      if name == "REPRO_WORKSPACE_CONFIG": delEnv(name)
      else: putEnv(name, fx.scratch / (name & ".toml"))
    defer:
      for saved in savedRoutingEnv:
        if saved.present: putEnv(saved.name, saved.value)
        else: delEnv(saved.name)
    let cache = fx.scratch / "cache" / "clones"
    let records = fx.workspaceRoot / ".repro" / "manifests"
    let lockDir = lockRecordsDirFor(records, "lib-a", "lib-a")
    let wired = ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    checkpoint(wired.diagnostic)
    check wired.outcome == gwoWired
    let cfg = readGatewayConfig(wired.gatewayDir)
    check cfg.lockRecordsDir == lockDir
    check cfg.registeredKeysPath == registeredKeyStorePath(fx.workspaceRoot)
    var trusted = cfg

    # The upstream's required snapshot ratchets this push even though its
    # tree has no repro.lock: the case originally rejected by the gateway.
    discard fx.mustGit("rm", "repro.lock")
    discard fx.mustGit("commit", "--no-verify", "-qm", "record-store content")
    let c = fx.head
    createDir(lockDir)
    let record = lockDir / (c & ".toml")
    writeFile(record, "[[repo]]\nname = \"lib-a\"\npath = \"lib-a\"\nrevision = \"" & c & "\"\n")
    fx.noteCertificate(c, @["pre-commit"])
    let args = @["main:refs/heads/main",
      certificateNotesRef & ":" & certificateNotesRef]
    let covered = runArgv(@["git", "-C", fx.libAPath, "push", "--no-verify",
      "origin"] & args, env = fx.hookEnv)
    checkpoint("covered record-store push:\n" & covered.output)
    check covered.code == 0
    check "COVERED by 1 trusted certificate" in covered.output
    check fx.upstreamRef("main") == c

    # A valid policy snapshot is not a substitute for the record-store lock.
    let next = fx.commitPolicy(requiredPolicy(@["pre-commit"], @["*"]))
    fx.noteCertificate(next, @["pre-commit"])
    let missing = runArgv(@["git", "-C", fx.libAPath, "push", "--no-verify",
      "origin"] & args, env = fx.hookEnv)
    checkpoint("missing record push:\n" & missing.output)
    check missing.code != 0
    check "no committed lock record" in missing.output
    check fx.upstreamRef("main") == c
    writeFile(lockDir / (next & ".toml"), "not a lock record\n")
    let malformed = runArgv(@["git", "-C", fx.libAPath, "push", "--no-verify",
      "origin"] & args, env = fx.hookEnv)
    checkpoint("malformed record push:\n" & malformed.output)
    check malformed.code != 0
    check "pins no revisions" in malformed.output
    check fx.upstreamRef("main") == c
    writeFile(lockDir / (next & ".toml"), readFile(record).replace(c, next))
    let restored = runArgv(@["git", "-C", fx.libAPath, "push", "--no-verify",
      "origin"] & args, env = fx.hookEnv)
    checkpoint("valid record with policy-only repro.lock:\n" & restored.output)
    check restored.code == 0
    check "COVERED by 1 trusted certificate" in restored.output
    check fx.upstreamRef("main") == next

    # A migration must repair already-wired configs, and dry-run must leave
    # even stale configs byte-for-byte unchanged.
    trusted.lockRecordsDir = ""
    let stale = serializeGatewayConfig(trusted)
    writeFile(gatewayConfigPath(wired.gatewayDir), stale)
    discard ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache, dryRun = true)
    check readFile(gatewayConfigPath(wired.gatewayDir)) == stale
    let repaired = ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    check repaired.outcome == gwoAlreadyWired
    check readGatewayConfig(wired.gatewayDir).lockRecordsDir == lockDir
    # An explicit route for another repo must not turn this public repo
    # into a record-store project merely because a store exists nearby.
    let customStore = fx.workspaceRoot / "custom-records"
    discard gitOut(fx.workspaceRoot, "init", "-q", customStore)
    let routingPath = fx.workspaceRoot / ".repro-workspace.toml"
    let otherRoute = "schema = \"reprobuild.workspace.bootstrap.v1\"\n" &
      "[manifest]\nurl = \"https://example.invalid/manifests.git\"\n" &
      "[locking]\nroute = [{visibility = \"team\", backend = \"git-checkout\", " &
      "path = \"custom-records\", repos = [\"other\"]}]\n"
    writeFile(routingPath, otherRoute)
    discard ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    check readGatewayConfig(wired.gatewayDir).lockRecordsDir == ""
    writeFile(routingPath, otherRoute.replace("other", "lib-a"))
    discard ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    check readGatewayConfig(wired.gatewayDir).lockRecordsDir ==
      lockRecordsDirFor(customStore, "lib-a", "lib-a")
    # Read-only record consumers also support a readable plain directory.
    removeDir(customStore / ".git")
    let readable = ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    checkpoint(readable.diagnostic)
    check readable.outcome == gwoAlreadyWired
    check readGatewayConfig(wired.gatewayDir).lockRecordsDir ==
      lockRecordsDirFor(customStore, "lib-a", "lib-a")
    let beforeMissingStore = readFile(gatewayConfigPath(wired.gatewayDir))
    removeDir(customStore)
    let missingStore = ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    check missingStore.outcome == gwoFailed
    check readFile(gatewayConfigPath(wired.gatewayDir)) == beforeMissingStore
    removeFile(routingPath)
    removeDir(records)
    discard ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    check readGatewayConfig(wired.gatewayDir).lockRecordsDir == ""

    let beforeFailure = readFile(gatewayConfigPath(wired.gatewayDir))
    writeFile(fx.workspaceRoot / ".repro-workspace.toml",
      "schema = \"reprobuild.workspace.bootstrap.v1\"\n" &
      "[manifest]\nurl = \"https://example.invalid/manifests.git\"\n" &
      "[locking]\nroute = [{visibility = \"team\", backend = \"git-notes\", " &
      "repos = [\"lib-a\"]}]\n")
    let failed = ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    checkpoint(failed.diagnostic)
    check failed.outcome == gwoFailed
    check "cannot read locking backend 'git-notes'" in failed.diagnostic
    check readFile(gatewayConfigPath(wired.gatewayDir)) == beforeFailure
    # A first wiring must also refuse before creating a gateway or push URL.
    discard fx.mustGit("config", "--unset", "remote.origin.pushurl")
    let firstCache = fx.scratch / "first-cache" / "clones"
    let firstFailed = ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = firstCache)
    checkpoint(firstFailed.diagnostic)
    check firstFailed.outcome == gwoFailed
    check not dirExists(firstFailed.gatewayDir)
    check runArgv(@["git", "-C", fx.libAPath, "config", "--get",
      "remote.origin.pushurl"]).code != 0
    discard fx.mustGit("remote", "set-url", "--push", "origin", fx.upstreamBare)
    let foreign = ensureGatewayForRepo("git", fx.workspaceRoot, "lib-a",
      fx.libAPath, cacheRoot = cache)
    check foreign.outcome == gwoForeignPushurl
    check gitOut(fx.libAPath, "config", "--get", "remote.origin.pushurl") ==
      fx.upstreamBare

    # No active project is needed for the committed default. It must still
    # refuse to guess a project coordinate for any declared record source.
    discard fx.mustGit("config", "--unset", "remote.origin.pushurl")
    removeFile(workspaceTomlPath(fx.workspaceRoot))
    let routeWithoutProject = ensureGatewayForRepo("git", fx.workspaceRoot,
      "lib-a", fx.libAPath, cacheRoot = firstCache)
    check routeWithoutProject.outcome == gwoFailed
    check not dirExists(routeWithoutProject.gatewayDir)
    removeFile(routingPath)
    discard gitOut(fx.workspaceRoot, "init", "-q", records)
    let storeWithoutProject = ensureGatewayForRepo("git", fx.workspaceRoot,
      "lib-a", fx.libAPath, cacheRoot = firstCache)
    check storeWithoutProject.outcome == gwoFailed
    check not dirExists(storeWithoutProject.gatewayDir)
    removeDir(records)
    let defaultWithoutProject = ensureGatewayForRepo("git", fx.workspaceRoot,
      "lib-a", fx.libAPath, cacheRoot = firstCache)
    checkpoint(defaultWithoutProject.diagnostic)
    check defaultWithoutProject.outcome == gwoWired
    let defaultConfig = readGatewayConfig(defaultWithoutProject.gatewayDir)
    check defaultConfig.lockRecordsDir == ""
    check defaultConfig.registeredKeysPath == registeredKeyStorePath(fx.workspaceRoot)
