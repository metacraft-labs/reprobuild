## TC-9b — two repositories on two pins of one policy package resolve
## different rules (Test-Certificates.md §"Importing and pinning": "A policy
## change reaches a repository when that repository bumps its pin", "The
## snapshot travels with the pin").
##
## One policy package, two revisions of it, and two consumers, each in its own
## workspace directory beside its own checkout of the package:
##
##   ws-a/certpolicy  at revision 1: ``rule "agents": gateMode advisory``
##   ws-a/consumer-a  enacts ``teamPolicy``
##   ws-b/certpolicy  a clone of ws-a's, advanced to revision 2:
##                    ``rule "agents": gateMode required``
##   ws-b/consumer-b  enacts ``teamPolicy``, the same name
##
## Each consumer's ``repro lock refresh`` pins its own checkout's revision,
## its snapshot records that revision's rule, and ``repro certificates policy
## --branch agents`` reports that rule and that pin. The two revisions'
## ``agents`` rules are different by construction (checked before anything
## else), so the test cannot pass with both consumers reading one rule.
##
## NO MOCKS: real repositories and clones, the real provider compile, the
## real lock writer and reader. Skip rule: ``git`` missing.

import std/[json, os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import ./certificate_policy_fixture

const revisionOne = """
const teamPolicy* = certificatePolicy "team":
  rule "agents":
    gateMode advisory
    requires "pre-commit"
"""

suite "TC-9b — two pins, two rules":

  test "t_two_repos_on_different_policy_pins_resolve_different_rules":
    if findExe("git").len == 0:
      skip("git is not on PATH; this test drives real repositories")
    else:
      let root = createTempDir("repro-tc9b-pins-", "")
      defer: removeDir(root)
      createDir(root / "ws-a")
      var a = newPolicyWorkspace("tc9b-pins-a", revisionOne,
        consumerRecipe("teamPolicy", ["pre-commit"]), root = root / "ws-a")
      # ws-b: a clone of the same package, moved to revision 2.
      var b = a
      b.root = root / "ws-b"
      b.policyPkg = b.root / "certpolicy"
      b.consumer = b.root / "consumer"
      createDir(b.root)
      discard a.git(b.root, "clone", "-q", a.policyPkg, b.policyPkg)
      discard b.git(b.policyPkg, "config", "user.email",
        "tester@example.invalid")
      discard b.git(b.policyPkg, "config", "user.name", "Policy Tester")
      let revisionTwo = revisionOne.replace("gateMode advisory",
        "gateMode required")
      check revisionTwo != revisionOne
      b.writePolicyModule(revisionTwo, "agents required")
      createDir(b.consumer)
      discard b.git(b.consumer, "init", "-q", "-b", "main")
      discard b.git(b.consumer, "config", "user.email",
        "tester@example.invalid")
      discard b.git(b.consumer, "config", "user.name", "Policy Tester")
      writeFile(b.consumer / ".gitignore", ".repro/\nbuild/\n")
      b.writeConsumer(consumerRecipe("teamPolicy", ["pre-commit"]), "seed")
      let pinA = a.headOf(a.policyPkg)
      let pinB = b.headOf(b.policyPkg)
      check pinA != pinB
      # The two revisions really disagree about `agents`.
      check "gateMode advisory" in a.git(a.policyPkg, "show",
        pinA & ":policy/team_policy.nim")
      check "gateMode required" in b.git(b.policyPkg, "show",
        pinB & ":policy/team_policy.nim")

      for (ws, pin, mode, other) in [(a, pinA, "advisory", pinB),
                                     (b, pinB, "required", pinA)]:
        let refreshed = ws.refresh()
        checkpoint(ws.consumer & " refresh:\n" & refreshed.output)
        check refreshed.code == 0
        let lock = lockOf(ws.consumer)
        let entry = depLine(lock, "certpolicy")
        checkpoint("pin entry: " & entry)
        check ("revision = \"" & pin & "\"") in entry
        check other notin lock
        check ("branches = [\"agents\"]\ngate_mode = \"" & mode & "\"\n") in
          lock
        let report = ws.policyReport(ws.consumer, "agents")
        checkpoint(report.output)
        check report.code == 0
        if not report.report.isNil:
          check report.report["package"].getStr() == "certpolicy"
          check report.report["revision"].getStr() == pin
          check report.report["match"]["gateMode"].getStr() == mode
