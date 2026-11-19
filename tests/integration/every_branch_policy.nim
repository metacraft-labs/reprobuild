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

import std/strutils

import repro_lock/certificate_policy

export certificate_policy

proc fixtureCommandSet*(name: string): CertificateCommandSet =
  ## A well-formed command set for ``name``, standing in for the one
  ## ``repro lock refresh`` records from an evaluated graph
  ## (Test-Certificates.md §"What a required name means: its command set").
  ## The hand-built fixtures that use it have no graph: the gate under test
  ## reads only the snapshot, and needs the base and the candidate to say
  ## the same thing about what ``name`` means.
  CertificateCommandSet(name: name,
    commands: @[name & "-command" & CommandEntryDigestMarker & repeat('0', 64)])

proc withFixtureCommandSets*(policy: BranchCertificatePolicy):
    BranchCertificatePolicy =
  ## ``policy`` with ``fixtureCommandSet`` for every name it requires.
  result = policy
  result.commandSets = @[]
  for name in requiredCertificateNames(policy):
    result.commandSets.add(fixtureCommandSet(name))

proc everyBranchPolicy*(mode: PolicyMode; targets, platforms: openArray[string];
                        ciTrust = pctAdvisory; untrackedInputs = puiReadSet;
                        name = "team-default";
                        package = "certpolicy";
                        commandSets = false): BranchCertificatePolicy =
  ## ``rule "**", detachedHead`` under ``mode``, requiring every one of
  ## ``targets`` on ``platforms`` (``@["*"]`` for any one platform).
  ## ``platforms`` must not be empty when ``targets`` is not. With
  ## ``commandSets``, every required name gets ``fixtureCommandSet``; without
  ## it the snapshot is one written before command sets existed.
  var rule = PolicyRule(branches: @["**", DetachedHeadPattern],
    gateMode: mode, commitGate: mode)
  for t in targets:
    rule.requires.add(PolicyRequirement(certificate: t,
      platforms: @platforms))
  result = BranchCertificatePolicy(name: name, package: package,
    ciTrust: ciTrust, untrackedInputs: untrackedInputs, rules: @[rule])
  if commandSets:
    result = withFixtureCommandSets(result)
  validatePolicy(result)
  validateCommandSets(result)

proc everyBranchSnapshot*(mode: PolicyMode;
                          targets, platforms: openArray[string];
                          ciTrust = pctAdvisory; untrackedInputs = puiReadSet;
                          name = "team-default";
                          package = "certpolicy";
                          commandSets = false): string =
  ## ``everyBranchPolicy`` as the ``[certificate_policy]`` snapshot text.
  renderCertificatePolicySnapshot(everyBranchPolicy(mode, targets, platforms,
    ciTrust, untrackedInputs, name, package, commandSets))
