## TC-9c shared fixture: the TC-8g pre-commit fixture (itself the TC-8c store
## workspace) with a ``[certificate_policy]`` snapshot committed in the
## developer clone's ``repro.lock``, so every gate reads its requirement out
## of the content it judges.
##
## ``include``d (not imported, not a registered test) by the TC-9c gate
## tests. The snapshot text is rendered by the production renderer
## (``renderCertificatePolicySnapshot``) and spliced in by the production
## splicer (``replaceCertificatePolicySection``): the bytes ``repro lock
## refresh`` writes for the same policy. The end-to-end route — a shared
## policy package imported by ``uses:``, enacted and refreshed into the lock
## — is driven by ``t_hooks_ensure_generates_the_gate_from_the_imported_policy``
## through the TC-9b package fixture; the gate tests here vary the policy
## from case to case, which the package route would make a provider compile
## per case.
##
## The committed lock pins nothing (an empty ``deps``): a lock that pins a
## commit the receiving side cannot see fails the public-tier lock gate, and
## the gate under test here is the certificate one.

import repro_lock/certificate_policy

include pre_commit_gate_fixture

proc req(name: string; platforms: varargs[string]): PolicyRequirement =
  PolicyRequirement(certificate: name, platforms: @platforms)

proc policyRule(branches: openArray[string]; gateMode: PolicyMode;
                requires: openArray[PolicyRequirement];
                commitGate = pmOff; commitGateSet = false): PolicyRule =
  PolicyRule(branches: @branches, gateMode: gateMode,
    commitGate: (if commitGateSet: commitGate else: gateMode),
    requires: @requires)

proc snapshotOf(rules: openArray[PolicyRule];
                ciTrust = pctAdvisory): string =
  renderCertificatePolicySnapshot(BranchCertificatePolicy(
    name: "team-default", package: "certpolicy", ciTrust: ciTrust,
    untrackedInputs: puiReadSet, rules: @rules))

proc commitPolicy(fx: StoreFixture; snapshot: string;
                  message = "certificate policy"): string =
  ## Write ``snapshot`` into lib-a's ``repro.lock`` and commit it with
  ## ``--no-verify``: the policy commit itself is not what a case judges.
  writeFile(fx.libAPath / "repro.lock", policyLock(snapshot))
  discard fx.mustGit("add", "repro.lock")
  discard fx.mustGit("commit", "--no-verify", "-q", "-m", message)
  fx.head

proc certifyTargets(fx: StoreFixture; content: string; targets: seq[string];
                    platform = currentPlatformTag()) =
  ## A registered-signed certificate for ``content`` naming ``targets``, in
  ## the user root of the local store.
  let published = publishCertificateToLocalStore(
    signedCertFor(fx, content, fx.head, targets = targets,
      platform = platform), fx.libAPath)
  doAssert published.written, published.error

proc dispatcherOf(repo: string): string =
  let path = repo / ".git" / "hooks" / "pre-commit"
  if fileExists(path): readFile(path) else: ""

proc hasCertificatePhase(repo: string): bool =
  PreCommitGatePhaseArg in dispatcherOf(repo)
