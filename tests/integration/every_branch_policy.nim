## Shared test helper: a certificate policy with ONE rule for every branch.
##
## Deliberately not a ``t_*.nim`` file, so the suite generator never compiles
## it as a test of its own.
##
## Many gate tests need "this repository requires these names on these
## platforms, whatever the branch". This builds that policy as its author
## would write it with ``repro_certificates``:
##
## .. code-block:: nim
##
##   const teamDefault* = certificatePolicy "team-default":
##     ciTrust advisory
##     untrackedInputs readSet
##     rule "**", detachedHead:
##       gateMode required
##       requires "t-unit", platforms = ["linux/amd64"]
##
## ``detachedHead`` is spelled out because ``"**"`` never matches a detached
## ``HEAD`` (Test-Certificates.md §"Branch matching"); the tests that commit
## on a detached ``HEAD`` rely on the rule applying there too. The snapshot
## text comes from the production renderer, i.e. the bytes ``repro lock
## refresh`` records for the same declaration.

import repro_lock/certificate_policy

export certificate_policy

proc everyBranchPolicy*(mode: PolicyMode; targets, platforms: openArray[string];
                        ciTrust = pctAdvisory; untrackedInputs = puiReadSet;
                        name = "team-default";
                        package = "certpolicy"): BranchCertificatePolicy =
  ## ``rule "**", detachedHead`` under ``mode``, requiring every one of
  ## ``targets`` on ``platforms`` (``@["*"]`` for any one platform).
  ## ``platforms`` must not be empty when ``targets`` is not.
  var rule = PolicyRule(branches: @["**", DetachedHeadPattern],
    gateMode: mode, commitGate: mode)
  for t in targets:
    rule.requires.add(PolicyRequirement(certificate: t,
      platforms: @platforms))
  result = BranchCertificatePolicy(name: name, package: package,
    ciTrust: ciTrust, untrackedInputs: untrackedInputs, rules: @[rule])
  validatePolicy(result)

proc everyBranchSnapshot*(mode: PolicyMode;
                          targets, platforms: openArray[string];
                          ciTrust = pctAdvisory; untrackedInputs = puiReadSet;
                          name = "team-default";
                          package = "certpolicy"): string =
  ## ``everyBranchPolicy`` as the ``[certificate_policy]`` snapshot text.
  renderCertificatePolicySnapshot(everyBranchPolicy(mode, targets, platforms,
    ciTrust, untrackedInputs, name, package))
