## TC-9b — a policy imported from a shared package is snapshotted into the
## consumer's ``repro.lock`` (Test-Certificates.md §"The policy declaration",
## §"Importing and pinning", §"The policy snapshot in `repro.lock`").
##
## Fixture (``certificate_policy_fixture.nim``): a ``certpolicy`` package
## whose ``policy/team_policy.nim`` builds the policy, and a ``consumer``
## repository that names the package in ``uses:`` and enacts the policy. The
## consumer has no copy of the policy source.
##
## Asserted, against the built ``repro``:
##   1. ``repro lock refresh`` writes ``[certificate_policy]`` exactly as the
##      declaration says (the canonical text, byte for byte), names the
##      package, and pins that package's revision as an ordinary ``deps``
##      entry. After the rules it records what each required name means
##      (§"What a required name means: its command set"): one
##      ``[[certificate_policy.certificate]]`` table per required name, in
##      first-requirement order, listing the one edge each name's aggregate
##      holds;
##   2. a second refresh writes nothing (bytes and modification time), and a
##      copy of the whole workspace elsewhere, whose compiled provider is
##      reused from the cache, records the same snapshot naming the COPY's
##      package — command-set digests included, which therefore name no path
##      of the checkout;
##   3. the consumer checkout carries no copy of the policy source;
##   4. a new revision of the policy package that changes a rule is picked up
##      by the next refresh: the snapshot says the new rule and the pin moves
##      with it — the snapshot travels with the pin;
##   5. removing ``enactCertificatePolicy`` removes the snapshot.
##
## NO MOCKS: real repositories, the real provider compile, the real lock
## writer. Skip rule: ``git`` missing.

import std/[os, strutils, tempfiles, times, unittest]
import repro_test_support/reasoned_skip

import repro_lock/certificate_policy
import ./certificate_policy_fixture

const teamPolicy = """
const teamPolicy* = certificatePolicy "team-default":
  ciTrust advisory
  rule "agents", "agents-to-dev-*":
    gateMode required
    commitGate advisory
    requires "pre-commit", platforms = anyPlatform
  rule "dev", "stable":
    gateMode required
    requires "pre-commit", platforms = anyPlatform
    requires "unit-suite", platforms = ["linux/amd64", "macos/arm64"]
  rule detachedHead:
    gateMode off
  rule "**":
    gateMode advisory
    requires "unit-suite"
"""

const expectedSnapshot = """[certificate_policy]
schema = "reprobuild.certificate-policy.v1"
name = "team-default"
package = "certpolicy"
ci_trust = "advisory"
untracked_inputs = "read-set"

[[certificate_policy.rule]]
branches = ["agents", "agents-to-dev-*"]
gate_mode = "required"
commit_gate = "advisory"
requires = [{ certificate = "pre-commit", platforms = ["*"] }]

[[certificate_policy.rule]]
branches = ["dev", "stable"]
gate_mode = "required"
requires = [{ certificate = "pre-commit", platforms = ["*"] }, { certificate = "unit-suite", platforms = ["linux/amd64", "macos/arm64"] }]

[[certificate_policy.rule]]
branches = ["(detached)"]
gate_mode = "off"

[[certificate_policy.rule]]
branches = ["**"]
gate_mode = "advisory"
requires = [{ certificate = "unit-suite", platforms = ["*"] }]
"""

proc rulesAndSets(lock: string): tuple[rules: string;
                                       sets: seq[CertificateCommandSet]] =
  ## The snapshot ``lock`` ends with, split into the text of everything but
  ## its command sets (rendered by the production renderer) and the command
  ## sets. Fails the case when the lock does not END with that snapshot,
  ## byte for byte, as the renderer writes it.
  let section = splitCertificatePolicySection(lock).policySection
  check section.len > 0
  check lock.endsWith("\n\n" & section)
  let policy = parseCertificatePolicySnapshot(section)
  check renderCertificatePolicySnapshot(policy) == section
  var withoutSets = policy
  withoutSets.commandSets = @[]
  (renderCertificatePolicySnapshot(withoutSets), policy.commandSets)

proc checkMeaning(sets: seq[CertificateCommandSet]) =
  ## One command set per required name, sorted by name, each
  ## naming the one edge the consumer's aggregate for it holds.
  check sets.len == 2
  if sets.len == 2:
    for (set, name) in [(sets[0], "pre-commit"), (sets[1], "unit-suite")]:
      check set.name == name
      check set.commands.len == 1
      if set.commands.len == 1:
        let parts = commandEntryParts(set.commands[0])
        check parts.ok
        check parts.actionId == name & "-check"

suite "TC-9b — the shared policy is snapshotted into the lock":

  test "t_policy_imported_from_a_shared_package_is_snapshotted_into_the_lock":
    if findExe("git").len == 0:
      skip("git is not on PATH; this test drives real repositories")
    else:
      let ws = newPolicyWorkspace("tc9b-snapshot", teamPolicy,
        consumerRecipe("teamPolicy", ["pre-commit", "unit-suite"]))
      defer: removeDir(ws.root)

      # (1) The first refresh records the policy and pins its package.
      let first = ws.refresh()
      checkpoint("first refresh:\n" & first.output)
      check first.code == 0
      let lock1 = lockOf(ws.consumer)
      let snap1 = rulesAndSets(lock1)
      check snap1.rules == expectedSnapshot
      checkMeaning(snap1.sets)
      let pin1 = ws.headOf(ws.policyPkg)
      let entry1 = depLine(lock1, "certpolicy")
      checkpoint("certpolicy entry: " & entry1)
      check entry1.len > 0
      check "path =" notin entry1
      check ("revision = \"" & pin1 & "\"") in entry1
      # The lock is still an ordinary lock: its readers take the lock keys,
      # not the snapshot's `schema` / `name`.
      check lock1.startsWith("schema = \"reprobuild.solved-graph-lock.v3\"")

      # (2) A second refresh writes nothing.
      let stamp = getLastModificationTime(ws.consumer / "repro.lock")
      sleep(1100)
      let second = ws.refresh()
      checkpoint("second refresh:\n" & second.output)
      check second.code == 0
      check lockOf(ws.consumer) == lock1
      check getLastModificationTime(ws.consumer / "repro.lock") == stamp

      # (2b) A copy of the whole workspace elsewhere. Its recipes are byte-
      # identical, so the compiled provider is reused from the cache; the
      # policy's declaring file must still resolve to the COPY's package, not
      # to the checkout that was compiled first.
      let moved = createTempDir("repro-tc9b-snapshot-moved-", "")
      defer: removeDir(moved)
      copyDir(ws.root, moved / "ws")
      var copy = ws
      copy.root = moved / "ws"
      copy.policyPkg = copy.root / "certpolicy"
      copy.consumer = copy.root / "consumer"
      removeFile(copy.consumer / "repro.lock")
      let relocated = copy.refresh()
      checkpoint("refresh of the relocated copy:\n" & relocated.output)
      check relocated.code == 0
      let copied = rulesAndSets(lockOf(copy.consumer))
      check copied.rules == expectedSnapshot
      check copied.sets == snap1.sets
      check ws.root notin lockOf(copy.consumer)

      # (3) The consumer carries no copy of the policy source: no file in its
      # checkout holds the declaration, and its tracked files are the recipe
      # and the ignore file (the lock is not committed by this test).
      var copies: seq[string]
      for path in walkDirRec(ws.consumer):
        if "/.git/" in path or path.endsWith("repro.lock"):
          continue
        let text = readFile(path)
        if "certificatePolicy \"" in text or "team-default" in text or
            "agents-to-dev-*" in text:
          copies.add(path)
      check copies.len == 0
      check ws.git(ws.consumer, "ls-files").strip().splitLines() ==
        @[".gitignore", "repro.nim"]
      check "enactCertificatePolicy teamPolicy" in
        readFile(ws.consumer / "repro.nim")

      # (4) The package moves to a revision whose `agents` rule is stricter.
      ws.writePolicyModule(teamPolicy.replace(
        "    commitGate advisory\n", ""), "commit gate required")
      let pin2 = ws.headOf(ws.policyPkg)
      check pin2 != pin1
      let third = ws.refresh()
      checkpoint("refresh after the policy moved:\n" & third.output)
      check third.code == 0
      let lock2 = lockOf(ws.consumer)
      check ("revision = \"" & pin2 & "\"") in depLine(lock2, "certpolicy")
      let snap2 = rulesAndSets(lock2)
      check snap2.rules == expectedSnapshot.replace(
        "commit_gate = \"advisory\"\n", "")
      check snap2.sets == snap1.sets

      # (5) Enacting nothing removes the snapshot.
      ws.writeConsumer(consumerRecipe("", ["pre-commit", "unit-suite"]),
        "no policy")
      let fourth = ws.refresh()
      checkpoint("refresh with no policy:\n" & fourth.output)
      check fourth.code == 0
      let lock3 = lockOf(ws.consumer)
      check "[certificate_policy]" notin lock3
      check lock3.endsWith("]\n")
