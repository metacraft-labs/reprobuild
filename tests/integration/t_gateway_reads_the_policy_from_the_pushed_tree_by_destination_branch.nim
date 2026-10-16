## TC-9c — the gateway's ``pre-receive`` reads the requirement from the
## ``[certificate_policy]`` snapshot in the PUSHED commit's ``repro.lock``
## (inside the receive quarantine), under the rule for each update's
## DESTINATION branch, and ratchets ``gate_mode`` against the anchor
## (Test-Certificates.md §"Branch matching", Push-Gateway-Wiring-And-Policy
## §4.2).
##
## A real gateway bare (its installed hooks driving the built ``repro``) in
## front of a real upstream bare. Every push uses ``--no-verify``, so only the
## receiving side decides. The gateway config is wired with a BAKED policy
## (``required``, ``t-unit`` on this platform) that the snapshot must
## override. The snapshot: rule "agents" requires ``pre-commit`` on any
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
## Falsifiability: judge by the baked config → 1 is refused; judge every ref
## by the first ref's branch, or ignore the destination → 1 and 2 agree;
## read the anchor from the pushed commit instead of the upstream → 3's
## relaxing push is accepted.
##
## Hermetic: local bare repos, the built ``repro``; no network. Requires git
## and ssh-keygen.

import std/[os, osproc, strutils, unittest]

include policy_gate_fixture

proc wirePolicyGateway(fx: StoreFixture) =
  ## The gateway, wired with a baked policy the snapshot must override, the
  ## committed-lock source (no record store), and the fixture's keys.
  let cfg = GatewayConfig(
    gateMode: cgmRequired,
    requiredTargets: @["t-unit"],
    requiredPlatforms: @[currentPlatformTag()],
    lockRecordsDir: "",
    registeredKeysPath: registeredKeyStorePath(fx.workspaceRoot))
  let wired = wirePushGateway("git", fx.libAPath, fx.gatewayBare,
    fileUrl(fx.upstreamBare), cfg)
  doAssert wired.ok, wired.diagnostic

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
