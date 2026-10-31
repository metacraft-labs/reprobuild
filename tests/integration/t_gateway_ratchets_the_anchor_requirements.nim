## Operator decision D19 (2026-10-18) — the gateway ratchets the anchor's
## REQUIREMENTS, not only its ``gate_mode``.
##
## The gateway judges each branch push by the UNION of the requirement the
## pushed commit's ``[certificate_policy]`` snapshot sets for the destination
## branch and the one the anchor's sets (the upstream's ``refs/heads/<b>``):
## every name either side requires, each on the union of both sides'
## platforms, under the stricter ``gate_mode``. A push that weakens the policy
## must therefore still satisfy the anchor's; once it lands it is the anchor,
## and the pushes after it are judged by the weakened policy. A new branch has
## no anchor and is judged by the pushed commit's own policy
## (Push-Gateway-Wiring-And-Policy §4.2, CLI/gateway.md).
##
## A real gateway bare (its installed hooks driving the built ``repro``) in
## front of a real upstream bare. Every push uses ``--no-verify``, so only the
## receiving side decides. Each case first ANCHORS ``agents`` by pushing a
## certified commit whose snapshot requires something there, then pushes the
## commit under test on top of it:
##
##   a. the commit deletes ``[certificate_policy]``: REFUSED, naming the
##      anchor's ``pre-commit``; certified for it, accepted; the next
##      uncovered push (the anchor now has no snapshot) is accepted.
##   b. the commit's ``agents`` rule requires nothing: REFUSED.
##   c. the commit narrows ``pre-commit`` from two platforms to this one:
##      certified on this platform only it is REFUSED, naming the other;
##      certified on both it is accepted.
##   d. the commit drops ``unit-suite`` and satisfies the anchor's both
##      names: ACCEPTED; the next commit, certified for ``pre-commit`` alone,
##      is judged by the weakened policy and accepted; an uncovered one after
##      it is refused.
##   e. the commit ADDS ``extra``: certified for the anchor's ``pre-commit``
##      only it is REFUSED, naming ``extra``.
##   f. a new branch has no anchor: a commit with no snapshot pushed to one
##      is accepted although ``agents`` is anchored at ``required``, and a
##      commit whose own snapshot requires ``own-only`` on it is refused,
##      naming ``own-only`` and not the agents anchor's ``pre-commit``.
##
## Plus the pure union (``unionPlatforms`` / ``unionRequirements``), which
## the gateway applies and which the platform cases above exercise.
##
## Falsifiability: leave the anchor's names out of the union → a, b and c's
## first push are accepted; let ``anyPlatform`` win over a concrete set, or
## keep only the pushed platforms → c's first push is accepted; skip the
## anchor when the pushed tree has no snapshot (as before D19) → a's first
## push is accepted; take the anchor's names alone → e is accepted.
##
## Hermetic: local bare repos, the built ``repro``; no network. Requires git
## and ssh-keygen.

import std/[os, osproc, strutils, unittest]

include policy_gate_fixture
import ./certificate_note_seed

const otherPlatform = "tc-other-os/tc-other-arch"
  ## A platform no host reports: a certificate for it is fabricated by the
  ## fixture's registered key, which the gateway trusts like any other.

proc wireRatchetGateway(fx: StoreFixture) =
  ## The gateway, with the committed-lock source and the fixture's keys.
  let cfg = GatewayConfig(
    lockRecordsDir: "",
    registeredKeysPath: registeredKeyStorePath(fx.workspaceRoot))
  let wired = wirePushGateway("git", fx.libAPath, fx.gatewayBare,
    fileUrl(fx.upstreamBare), cfg)
  doAssert wired.ok, wired.diagnostic

proc upstreamRef(fx: StoreFixture; branch: string): string =
  let res = execCmdEx(quoteShellCommand(@["git", "-C", fx.upstreamBare,
    "rev-parse", "--verify", "--quiet", "refs/heads/" & branch]))
  if res.exitCode != 0: "" else: res.output.strip()

proc noteCertificate(fx: StoreFixture; commit: string; targets: seq[string];
                     platform = currentPlatformTag()) =
  ## A registered-signed certificate for ``commit``'s tree, noted on it.
  let content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
    commit & "^{tree}")
  check seedCertificateNote("git", fx.libAPath,
    signedCertFor(fx, content, commit, targets = targets,
      platform = platform)).ok

const notesRefspec = certificateNotesRef & ":" & certificateNotesRef

proc pushAgents(fx: StoreFixture; withNotes = true):
    tuple[code: int; output: string] =
  var refspecs = @["agents:refs/heads/agents"]
  if withNotes: refspecs.add(notesRefspec)
  result = pushToGateway(fx, refspecs)
  checkpoint("push agents:\n" & result.output)

proc anchorAgents(fx: StoreFixture; snapshot: string;
                  certs: openArray[(seq[string], string)]): string =
  ## On a fresh local ``agents``, commit ``snapshot``, note ``certs`` (each a
  ## target list and a platform) on it, and push it: the anchor for the case.
  discard fx.mustGit("checkout", "-q", "-b", "agents")
  result = fx.commitPolicy(snapshot, "anchor policy")
  for (targets, platform) in certs:
    fx.noteCertificate(result, targets, platform)
  let pushed = fx.pushAgents()
  doAssert pushed.code == 0, "the anchor push was refused:\n" & pushed.output
  doAssert fx.upstreamRef("agents") == result

proc agentsRule(requires: openArray[PolicyRequirement];
                mode = pmRequired): string =
  snapshotOf([policyRule(["agents"], mode, requires)])

suite "D19 — the gateway ratchets the anchor's requirements":

  test "the union of two requirement sets":
    let here = "linux/amd64"
    # anyPlatform joined with a concrete set is that set; with itself, itself.
    check unionPlatforms(["*"], ["*"]) == @["*"]
    check unionPlatforms(["*"], [here]) == @[here]
    check unionPlatforms([here], ["*"]) == @[here]
    check unionPlatforms([here], [here, "macos/arm64"]) ==
      @[here, "macos/arm64"]
    check unionPlatforms(["macos/arm64"], [here]) == @["macos/arm64", here]
    # Names: the first side's first, then the names only the second has.
    let joined = unionRequirements(
      [req("pre-commit", "*"), req("unit", here)],
      [req("unit", "macos/arm64"), req("lint", "*")])
    check joined.len == 3
    check joined[0] == req("pre-commit", "*")
    check joined[1] == req("unit", here, "macos/arm64")
    check joined[2] == req("lint", "*")
    check unionRequirements([], [req("lint", "*")]) == @[req("lint", "*")]
    check unionRequirements([req("lint", "*")], []) == @[req("lint", "*")]

  test "a: deleting the snapshot is judged by the anchor's policy":
    let fx = setupStoreFixture("", "d19-delete", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    wireRatchetGateway(fx)
    let anchor = fx.anchorAgents(agentsRule([req("pre-commit", "*")]),
      [(@["pre-commit"], currentPlatformTag())])

    let dropped = fx.commitPolicy("", "drop the certificate policy")
    let refused = fx.pushAgents(withNotes = false)
    check refused.code != 0
    check fx.upstreamRef("agents") == anchor
    check "'pre-commit' on any platform" in refused.output
    check "the anchor's pre-commit (any platform) still applies" in
      refused.output
    check "no certificate policy: no requirement" in refused.output

    # Satisfying the anchor's requirement, the weakening push lands ...
    fx.noteCertificate(dropped, @["pre-commit"])
    let covered = fx.pushAgents()
    check covered.code == 0
    check fx.upstreamRef("agents") == dropped
    # ... and is the anchor from now on: no snapshot there, no requirement.
    let next = fx.newCommit("next.txt", "next\n")
    let nextPush = fx.pushAgents(withNotes = false)
    check nextPush.code == 0
    check fx.upstreamRef("agents") == next

  test "b: a rule that requires nothing is judged by the anchor's names":
    let fx = setupStoreFixture("", "d19-empty", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    wireRatchetGateway(fx)
    let anchor = fx.anchorAgents(agentsRule([req("pre-commit", "*")]),
      [(@["pre-commit"], currentPlatformTag())])

    discard fx.commitPolicy(agentsRule([]), "require nothing on agents")
    let refused = fx.pushAgents(withNotes = false)
    check refused.code != 0
    check fx.upstreamRef("agents") == anchor
    check "required, requires nothing required" in refused.output
    check "the anchor's pre-commit (any platform) still applies" in
      refused.output
    check "'pre-commit' on any platform" in refused.output

  test "c: narrowing the platforms keeps the anchor's platforms required":
    let here = currentPlatformTag()
    let fx = setupStoreFixture("", "d19-narrow", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    wireRatchetGateway(fx)
    let anchor = fx.anchorAgents(
      agentsRule([req("pre-commit", here, otherPlatform)]),
      [(@["pre-commit"], here), (@["pre-commit"], otherPlatform)])

    let narrowed = fx.commitPolicy(agentsRule([req("pre-commit", here)]),
      "require pre-commit on this platform only")
    fx.noteCertificate(narrowed, @["pre-commit"], here)
    let refused = fx.pushAgents()
    check refused.code != 0
    check fx.upstreamRef("agents") == anchor
    check "'pre-commit' on " & otherPlatform in refused.output
    check "requires pre-commit (" & here & ", " & otherPlatform & ")" in
      refused.output

    fx.noteCertificate(narrowed, @["pre-commit"], otherPlatform)
    let covered = fx.pushAgents()
    check covered.code == 0
    check fx.upstreamRef("agents") == narrowed

  test "d: a weakening push that satisfies the anchor lands and then rules":
    let fx = setupStoreFixture("", "d19-weaken", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    wireRatchetGateway(fx)
    discard fx.anchorAgents(
      agentsRule([req("pre-commit", "*"), req("unit-suite", "*")]),
      [(@["pre-commit", "unit-suite"], currentPlatformTag())])

    let weakened = fx.commitPolicy(agentsRule([req("pre-commit", "*")]),
      "drop unit-suite from agents")
    fx.noteCertificate(weakened, @["pre-commit", "unit-suite"])
    let accepted = fx.pushAgents()
    check accepted.code == 0
    check fx.upstreamRef("agents") == weakened
    check "requires pre-commit (any platform), unit-suite (any platform)" in
      accepted.output

    # Judged by the weakened policy: pre-commit alone covers it.
    let next = fx.newCommit("next.txt", "next\n")
    fx.noteCertificate(next, @["pre-commit"])
    let nextPush = fx.pushAgents()
    check nextPush.code == 0
    check fx.upstreamRef("agents") == next
    check "unit-suite" notin nextPush.output

    # And it is still a requirement: an uncovered commit is refused.
    discard fx.newCommit("later.txt", "later\n")
    let uncovered = fx.pushAgents(withNotes = false)
    check uncovered.code != 0
    check fx.upstreamRef("agents") == next

  test "e: a stricter pushed requirement is enforced alongside the anchor's":
    let fx = setupStoreFixture("", "d19-stricter", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    wireRatchetGateway(fx)
    let anchor = fx.anchorAgents(agentsRule([req("pre-commit", "*")]),
      [(@["pre-commit"], currentPlatformTag())])

    let stricter = fx.commitPolicy(
      agentsRule([req("extra", "*")]), "require extra instead")
    fx.noteCertificate(stricter, @["pre-commit"])
    let refused = fx.pushAgents()
    check refused.code != 0
    check fx.upstreamRef("agents") == anchor
    check "'extra' on any platform" in refused.output
    check "requires extra (any platform), pre-commit (any platform)" in
      refused.output

    fx.noteCertificate(stricter, @["extra"])
    let covered = fx.pushAgents()
    check covered.code == 0
    check fx.upstreamRef("agents") == stricter

  test "f: a new branch has no anchor and is judged by its own policy":
    let fx = setupStoreFixture("", "d19-new-branch", recordStore = false,
      committedLock = true)
    defer: removeDir(fx.scratch)
    wireRatchetGateway(fx)
    let rules = snapshotOf([
      policyRule(["agents", "agents-*"], pmRequired, [req("pre-commit", "*")])])
    let anchor = fx.anchorAgents(rules,
      [(@["pre-commit"], currentPlatformTag())])

    # No snapshot, pushed to a branch the upstream does not have: the
    # agents anchor does not reach it.
    let dropped = fx.commitPolicy("", "drop the certificate policy")
    let toNew = pushToGateway(fx, @[dropped & ":refs/heads/agents-new"])
    checkpoint("push to agents-new:\n" & toNew.output)
    check toNew.code == 0
    check fx.upstreamRef("agents-new") == dropped
    check fx.upstreamRef("agents") == anchor

    # Its own policy, on a new branch, is what judges it: one that requires
    # a name the agents anchor never did (and a tree no certificate names).
    let own = fx.commitPolicy(snapshotOf([policyRule(["agents", "agents-*"],
      pmRequired, [req("own-only", "*")])]), "a policy of its own")
    let ownPush = pushToGateway(fx, @[own & ":refs/heads/agents-other"])
    checkpoint("push to agents-other:\n" & ownPush.output)
    check ownPush.code != 0
    check fx.upstreamRef("agents-other") == ""
    check "a new branch" in ownPush.output
    check "'own-only' on any platform" in ownPush.output
    check "pre-commit" notin ownPush.output
