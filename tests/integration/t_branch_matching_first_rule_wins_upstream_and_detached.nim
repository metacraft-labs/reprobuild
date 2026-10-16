## TC-9b — branch matching: first rule wins, the commit-time branch is the
## upstream's, a detached HEAD has its own rule, tags never match
## (Test-Certificates.md §"Branch matching").
##
## The policy (``certificate_policy_fixture``), recorded by a real
## ``repro lock refresh`` and read back by ``repro certificates policy``,
## which uses the library every gate shares:
##
##   1. ``rule "agents"``                  push required
##   2. ``rule "agents-to-dev-*"``         push required, commit advisory
##   3. ``rule detachedHead``              push advisory
##   4. ``rule "**"``                      push advisory
##   5. ``rule "after-catch-all"``         push required -- never selected
##
## Asserted:
##   * ``agents-to-dev-2026-10-09`` selects rule 2, ``feature/x`` rule 4
##     (``**`` crosses ``/``), ``after-catch-all`` rule 4, not rule 5: the
##     first match wins and a rule after ``**`` is never consulted;
##   * a local branch ``wip`` whose upstream is ``origin/agents`` is judged as
##     ``agents`` (rule 1), while a local ``wip`` with no upstream is judged
##     as itself (rule 4);
##   * a detached HEAD selects rule 3 -- not ``**`` -- and, under a policy
##     with no ``detachedHead`` rule, has no requirement;
##   * a tag (``refs/tags/agents``) never matches, though its short name does.
##
## NO MOCKS: real repositories, a real upstream configuration, a real
## detached HEAD, the built ``repro``. Skip rule: ``git`` missing.

import std/[json, os, strutils, unittest]
import repro_test_support/reasoned_skip

import ./certificate_policy_fixture

const matchingPolicies = """
const matchingPolicy* = certificatePolicy "matching":
  rule "agents":
    gateMode required
    requires "pre-commit"
  rule "agents-to-dev-*":
    gateMode required
    commitGate advisory
    requires "unit-suite"
  rule detachedHead:
    gateMode advisory
  rule "**":
    gateMode advisory
    requires "unit-suite", platforms = ["linux/amd64"]
  rule "after-catch-all":
    gateMode required
    requires "pre-commit"

const noDetachedPolicy* = certificatePolicy "no-detached":
  rule "agents":
    gateMode required
    requires "pre-commit"
  rule "**":
    gateMode advisory
"""

proc ruleFor(ws: PolicyWorkspace; branch = ""): JsonNode =
  let res = ws.policyReport(ws.consumer, branch)
  checkpoint("certificates policy " & branch & ":\n" & res.output)
  doAssert res.code == 0 and not res.report.isNil,
    "repro certificates policy failed: " & res.output
  res.report

suite "TC-9b — branch matching":

  test "t_branch_matching_first_rule_wins_upstream_and_detached":
    if findExe("git").len == 0:
      skip("git is not on PATH; this test drives real repositories")
    else:
      let ws = newPolicyWorkspace("tc9b-matching", matchingPolicies,
        consumerRecipe("matchingPolicy", ["pre-commit", "unit-suite"]))
      defer: removeDir(ws.root)
      let refreshed = ws.refresh()
      checkpoint(refreshed.output)
      check refreshed.code == 0

      # First match wins; `**` crosses `/`; a rule after `**` is dead.
      let toDev = ws.ruleFor("agents-to-dev-2026-10-09")
      check toDev["match"]["matched"].getBool()
      check toDev["match"]["rule"].getInt() == 2
      check toDev["match"]["pattern"].getStr() == "agents-to-dev-*"
      check toDev["match"]["gateMode"].getStr() == "required"
      check toDev["match"]["commitGate"].getStr() == "advisory"
      let feature = ws.ruleFor("feature/x")
      check feature["match"]["rule"].getInt() == 4
      check feature["match"]["pattern"].getStr() == "**"
      let dead = ws.ruleFor("after-catch-all")
      check dead["match"]["rule"].getInt() == 4
      check dead["match"]["gateMode"].getStr() == "advisory"
      # A full branch ref is the same branch.
      check ws.ruleFor("refs/heads/agents")["match"]["rule"].getInt() == 1

      # Commit time: the upstream's name, else the branch's own.
      discard ws.git(ws.consumer, "checkout", "-q", "-b", "wip")
      let alone = ws.ruleFor()
      check alone["branch"]["name"].getStr() == "wip"
      check alone["match"]["rule"].getInt() == 4
      discard ws.git(ws.consumer, "remote", "add", "origin", ws.root /
        "nowhere.git")
      discard ws.git(ws.consumer, "config", "branch.wip.remote", "origin")
      discard ws.git(ws.consumer, "config", "branch.wip.merge",
        "refs/heads/agents")
      let tracking = ws.ruleFor()
      check tracking["branch"]["kind"].getStr() == "brkBranch"
      check tracking["branch"]["name"].getStr() == "agents"
      check tracking["match"]["rule"].getInt() == 1
      check tracking["match"]["gateMode"].getStr() == "required"

      # A detached HEAD: its own rule, never `**`.
      discard ws.git(ws.consumer, "checkout", "-q", "--detach")
      let detached = ws.ruleFor()
      check detached["branch"]["kind"].getStr() == "brkDetached"
      check detached["match"]["matched"].getBool()
      check detached["match"]["rule"].getInt() == 3
      check detached["match"]["pattern"].getStr() == "(detached)"

      # A tag is not a branch, whatever its short name.
      let tag = ws.ruleFor("refs/tags/agents")
      check tag["branch"]["kind"].getStr() == "brkOther"
      check not tag["match"]["matched"].getBool()
      check "not a branch" in tag["match"]["reason"].getStr()

      # A policy with no detachedHead rule: a detached HEAD has no
      # requirement, although `**` would match any branch.
      discard ws.git(ws.consumer, "checkout", "-q", "main")
      ws.writeConsumer(consumerRecipe("noDetachedPolicy",
        ["pre-commit", "unit-suite"]), "no detached rule")
      let again = ws.refresh()
      checkpoint(again.output)
      check again.code == 0
      discard ws.git(ws.consumer, "checkout", "-q", "--detach")
      let noRule = ws.ruleFor()
      check noRule["branch"]["kind"].getStr() == "brkDetached"
      check not noRule["match"]["matched"].getBool()
      check noRule["match"]["reason"].getStr() ==
        "detached HEAD: no branch rule applies"
      check ws.ruleFor("feature/y")["match"]["pattern"].getStr() == "**"
