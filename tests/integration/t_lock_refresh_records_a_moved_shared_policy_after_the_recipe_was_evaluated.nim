## A policy imported from a shared package, moved to a new revision, is
## recorded by ``repro lock refresh`` even after ``repro certificates list``
## has evaluated the consumer's recipe through the build engine
## (Test-Certificates.md §"Importing and pinning", §"The policy snapshot in
## repro.lock": the snapshot travels with the pin).
##
## The defect this holds closed: the listing leaves a provider binary in the
## consumer's output directory. After the package moved, the refresh moved
## the pin but its policy probe ran that binary, compiled against the old
## revision, so the lock pinned the new revision beside the old revision's
## policy. The same mechanism as an edited local policy module
## (``t_lock_refresh_records_the_edited_policy_after_the_recipe_was_evaluated``).
##
## Asserted, against the built ``repro``:
##   1. the refresh records ``commitGate advisory`` and pins the package;
##   2. ``repro certificates list`` runs in the consumer;
##   3. the package moves to a revision whose rule drops ``commitGate
##      advisory``;
##   4. the refresh pins the new revision AND records the new rule.
##
## Falsifiability: make the durable provider reuse in
## ``tryLoadDurableSolverProviderArtifacts`` accept a validated
## recipe-relative hit without binding it to the durable binary → (4) keeps
## ``commit_gate = "advisory"`` beside the new pin.
##
## NO MOCKS: real repositories, the real provider compile and engine, the
## real lock writer (``certificate_policy_fixture.nim``). Skip rule: ``git``
## missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip

import ./certificate_policy_fixture

const teamPolicy = """
const teamPolicy* = certificatePolicy "team":
  rule "**":
    gateMode required
    commitGate advisory
    requires "unit-suite"
"""

suite "the snapshot travels with a moved pin after the recipe was evaluated":

  test "t_lock_refresh_records_a_moved_shared_policy_after_the_recipe_was_evaluated":
    if findExe("git").len == 0:
      skip("git is not on PATH; this test drives real repositories")
    else:
      let ws = newPolicyWorkspace("refresh-moved-policy", teamPolicy,
        consumerRecipe("teamPolicy", ["unit-suite"]))
      defer: removeDir(ws.root)

      # (1)
      let first = ws.refresh()
      checkpoint("first refresh:\n" & first.output)
      check first.code == 0
      let lock1 = lockOf(ws.consumer)
      check "commit_gate = \"advisory\"" in lock1
      let pin1 = ws.headOf(ws.policyPkg)
      check ("revision = \"" & pin1 & "\"") in depLine(lock1, "certpolicy")

      # (2)
      let listed = ws.reproIn(ws.consumer, "certificates", "list")
      checkpoint("certificates list:\n" & listed.output)
      check listed.code == 0
      check "unit-suite" in listed.output

      # (3)
      ws.writePolicyModule(teamPolicy.replace("    commitGate advisory\n", ""),
        "commit gate required")
      let pin2 = ws.headOf(ws.policyPkg)
      check pin2 != pin1

      # (4)
      let second = ws.refresh()
      checkpoint("refresh after the policy moved:\n" & second.output)
      check second.code == 0
      let lock2 = lockOf(ws.consumer)
      check ("revision = \"" & pin2 & "\"") in depLine(lock2, "certpolicy")
      check "[certificate_policy]" in lock2
      check "package = \"certpolicy\"" in lock2
      check "commit_gate = \"advisory\"" notin lock2
      check "gate_mode = \"required\"" in lock2
