## TC-9b — a policy that requires a certificate the enacting package does not
## declare fails the provider compile (Test-Certificates.md §"The policy
## declaration": "Every name the policy requires must be declared").
##
## A requirement nobody can satisfy would wedge every push to its branch, so
## the compile refuses it, naming the rule, the branch pattern and the
## missing name. Declaring the certificate makes the same policy compile.
##
## Three cases through the built ``repro`` (``certificate_policy_fixture``):
##   1. the policy's ``agents`` rule requires ``unit-suite``; the consumer
##      declares only ``pre-commit``: ``repro lock refresh`` fails, its
##      message names ``certificate policy 'strict'``, ``rule "agents"``, the
##      pattern and ``unit-suite``, and no lock is written;
##   2. the consumer adds ``certificate "unit-suite", ...``: the refresh
##      succeeds and records the policy;
##   3. a policy that requires ``test`` -- possibly the implicit marking of
##      whatever a plain ``repro test`` builds (D15), so it cannot be decided
##      from the source alone -- is checked when the provider evaluates the
##      package: ``repro certificates list`` (which evaluates it) fails naming
##      ``test`` for a consumer with no ``test`` target, and passes once the
##      consumer has one.
##
## NO MOCKS: real repositories, the real provider compile and evaluation.
## Skip rule: ``git`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip

import ./certificate_policy_fixture

const strictPolicy = """
const strictPolicy* = certificatePolicy "strict":
  rule "agents":
    gateMode required
    requires "pre-commit"
    requires "unit-suite", platforms = ["linux/amd64"]

const testPolicy* = certificatePolicy "needs-test":
  rule "**":
    gateMode advisory
    requires "test"
"""

suite "TC-9b — a policy requiring an undeclared name fails the compile":

  test "t_policy_requiring_an_undeclared_name_fails_the_compile":
    if findExe("git").len == 0:
      skip("git is not on PATH; this test drives real repositories")
    else:
      let ws = newPolicyWorkspace("tc9b-undeclared", strictPolicy,
        consumerRecipe("strictPolicy", ["pre-commit"]))
      defer: removeDir(ws.root)

      # (1) Refused, naming the rule, its pattern and the missing name.
      let refused = ws.refresh()
      checkpoint("refresh, unit-suite undeclared:\n" & refused.output)
      check refused.code != 0
      check "certificate policy 'strict', rule \"agents\" (branch pattern " &
        "\"agents\"): requires certificate 'unit-suite', which this " &
        "package does not declare" in refused.output
      check "repro.nim" in refused.output
      check not fileExists(ws.consumer / "repro.lock")

      # (2) Declared: the same policy compiles and is recorded.
      ws.writeConsumer(consumerRecipe("strictPolicy",
        ["pre-commit", "unit-suite"]), "declare unit-suite")
      let accepted = ws.refresh()
      checkpoint("refresh, unit-suite declared:\n" & accepted.output)
      check accepted.code == 0
      check "name = \"strict\"" in lockOf(ws.consumer)
      check "requires = [{ certificate = \"pre-commit\", platforms = " &
        "[\"*\"] }, { certificate = \"unit-suite\", platforms = " &
        "[\"linux/amd64\"] }]" in lockOf(ws.consumer)

      # (3) `test` is decided when the package is evaluated.
      ws.writeConsumer(consumerRecipe("testPolicy", ["pre-commit"]),
        "require test, declare none")
      let noTest = ws.reproIn(ws.consumer, "certificates", "list",
        "--tool-provisioning=path")
      checkpoint("certificates list, no test target:\n" & noTest.output)
      check noTest.code != 0
      check "requires certificate 'test', which this package does not " &
        "declare" in noTest.output
      ws.writeConsumer(consumerRecipe("testPolicy", ["pre-commit"]).replace(
        "  build:\n", "  build:\n    discard aggregate(\"test\", " &
        "actions = @[])\n"), "a test target")
      let withTest = ws.reproIn(ws.consumer, "certificates", "list",
        "--tool-provisioning=path")
      checkpoint("certificates list, test target:\n" & withTest.output)
      check withTest.code == 0
      check "test  implicit" in withTest.output
