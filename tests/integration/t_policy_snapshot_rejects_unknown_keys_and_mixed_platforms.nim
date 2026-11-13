## TC-9b — the snapshot's format is checked loudly (Test-Certificates.md
## §"The policy snapshot in `repro.lock`": "An unknown key inside
## `[certificate_policy]`, an unknown mode, or `"*"` mixed with concrete
## platforms is a structural error that refuses. It never silently becomes
## `off`.").
##
## A real ``repro lock refresh`` records a policy whose ``agents`` rule is
## ``required``. Each case then hand-edits the committed snapshot, as a pushed
## commit could, and reads it the way every gate does:
##
##   * the strict reader (``readCertificatePolicySnapshot``) raises
##     ``CertificatePolicySnapshotError`` naming the offence;
##   * ``repro certificates policy --branch agents`` exits non-zero with that
##     message and never reports the branch as ungated;
##   * ``certificatePolicyStaleness`` -- what ``repro health`` and the
##     pre-push gate report -- flags the lock.
##
## The cases: an unknown key (``owner``), an unknown table, an unknown mode
## (``gate_mode = "mandatory"``), and ``platforms = ["*", "linux/amd64"]``.
## The control: the unedited snapshot reads, and the edited ones are carried
## through the lock model verbatim, so the commit-time re-pin (which never
## writes the snapshot) leaves a hand edit for the gates to judge.
##
## NO MOCKS: a real recorded lock, the built ``repro``, the production
## reader. Skip rule: ``git`` missing.

import std/[json, os, strutils, unittest]
import repro_test_support/reasoned_skip

import repro_lock
import repro_lock/certificate_policy
import repro_cli_support
import ./certificate_policy_fixture

const requiredPolicy = """
const requiredPolicy* = certificatePolicy "required-agents":
  rule "agents":
    gateMode required
    requires "pre-commit", platforms = ["linux/amd64"]
"""

suite "TC-9b — the snapshot rejects unknown keys and mixed platforms":

  test "t_policy_snapshot_rejects_unknown_keys_and_mixed_platforms":
    if findExe("git").len == 0:
      skip("git is not on PATH; this test drives real repositories")
    else:
      let ws = newPolicyWorkspace("tc9b-strict", requiredPolicy,
        consumerRecipe("requiredPolicy", ["pre-commit"]))
      defer: removeDir(ws.root)
      let refreshed = ws.refresh()
      checkpoint(refreshed.output)
      check refreshed.code == 0
      let pristine = lockOf(ws.consumer)
      check readCertificatePolicySnapshot(pristine).present
      let control = ws.policyReport(ws.consumer, "agents")
      check control.code == 0
      check control.report["match"]["gateMode"].getStr() == "required"

      let cases = [
        ("an unknown key",
          pristine.replace("name = \"required-agents\"\n",
            "name = \"required-agents\"\nowner = \"someone\"\n"),
          "unknown key 'owner'"),
        ("an unknown table",
          pristine & "\n[certificate_policy.exceptions]\nbranches = []\n",
          "unknown table [certificate_policy.exceptions]"),
        ("an unknown mode",
          pristine.replace("gate_mode = \"required\"",
            "gate_mode = \"mandatory\""),
          "unknown gate_mode 'mandatory'"),
        ("\"*\" mixed with platforms",
          pristine.replace("platforms = [\"linux/amd64\"]",
            "platforms = [\"*\", \"linux/amd64\"]"),
          "cannot be mixed with concrete platforms")]
      for (label, edited, offence) in cases:
        checkpoint("case: " & label)
        check edited != pristine
        # The strict reader refuses, naming the offence.
        var raised = ""
        try:
          discard readCertificatePolicySnapshot(edited)
        except CertificatePolicySnapshotError as err:
          raised = err.msg
        check offence in raised
        # The lock model carries the edit through byte for byte: the hook's
        # re-pin never rewrites the snapshot, malformed or not.
        let model = parseLockedDependencies(edited)
        check serializeLockedDependencies(model) == edited
        writeFile(ws.consumer / "repro.lock", edited)
        # The CLI reader refuses; it does not report the branch as ungated.
        let report = ws.policyReport(ws.consumer, "agents")
        checkpoint(report.output)
        check report.code != 0
        check offence in report.output
        check "no branch is gated" notin report.output
        check "matches no rule" notin report.output
        check report.report.isNil
        # And the staleness check flags it.
        let staleness = certificatePolicyStaleness(ws.consumer)
        check staleness.stale
        check offence in staleness.detail
      writeFile(ws.consumer / "repro.lock", pristine)
      check ws.policyReport(ws.consumer, "agents").code == 0
