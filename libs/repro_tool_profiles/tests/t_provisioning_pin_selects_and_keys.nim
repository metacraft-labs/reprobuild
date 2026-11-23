## M7 deliverables 3/4 in the acquisition planners: a resolver pin selects
## the contributor in every realization family, is never relaxed to another
## contributor, provisions exactly the realization a committed-lock pin
## names, and binds the contribution fingerprint into the plan's lock
## identity (which keys the realized prefix, the tool profile and the
## typed-tool action). Unpinned, two contributors refuse whatever order they
## were declared in, and the removed ``REPRO_PROVISIONING_CONTRIBUTOR``
## refuses whenever it is set.
##
## The pins here are stamped by hand, as a caller bypassing
## ``applyProvisioningPins`` would; the planners re-check them. The chain
## from a committed lock is ``tests/integration/
## t_e2e_locked_provisioning_contributor_selection``.

import std/[algorithm, os, sequtils, strutils, unittest]

import repro_interface_artifacts
import repro_tool_profiles

const
  Fp = repeat('7', 64)
  Digest = repeat('8', 64)
  ShaA = repeat('a', 64)
  ShaB = repeat('b', 64)
  ShaC = repeat('c', 64)

proc pin(contributor: string; packageName = "tool"): ProvisioningPin =
  ProvisioningPin(packageName: packageName, contributor: contributor,
    contributionFingerprint: Fp, contributionRecordDigest: Digest)

proc nixEntry(contributor, selector: string): InterfaceNixProvisioning =
  InterfaceNixProvisioning(packageName: "tool", contributor: contributor,
    selector: selector, executablePath: "bin/tool")

proc tarEntry(contributor, sha: string; os = ""): InterfaceTarballProvisioning =
  InterfaceTarballProvisioning(packageName: "tool", contributor: contributor,
    url: "https://example.invalid/" & contributor & ".tar.gz", sha256: sha,
    archiveType: "tar.gz", executablePath: "bin/tool", os: os)

proc scoopEntry(contributor, app: string): InterfaceScoopProvisioning =
  InterfaceScoopProvisioning(packageName: "tool", contributor: contributor,
    bucket: "main", app: app, version: "1.0", executablePath: "tool.exe")

proc use(): InterfaceToolUse =
  InterfaceToolUse(rawConstraint: "tool", packageSelector: "tool",
    executableName: "tool",
    nixProvisioning: @[nixEntry("one", "nixpkgs#one"),
                       nixEntry("two", "nixpkgs#two")],
    tarballProvisioning: @[tarEntry("one", ShaA), tarEntry("two", ShaB)],
    scoopProvisioning: @[scoopEntry("one", "one"), scoopEntry("two", "two")])

proc refusal(body: proc ()): string =
  try:
    body()
    ""
  except ValueError as err:
    err.msg

proc otherOs(): string =
  when defined(windows): "linux" else: "windows"

let
  # Nix realizes on Linux and macOS and Scoop on Windows
  # (``realization_selection``, the selection a home profile shares), so the
  # nix and scoop planners are asked for a target their kind serves, on any
  # host. Tarball selection is asked for the host, as before.
  NixTarget = realizationTargetFor(pcX86_64, poLinux)
  ScoopTarget = realizationTargetFor(pcX86_64, poWindows)

suite "provisioning pins in the acquisition planners":
  delEnv(RemovedContributorSelectorEnv)

  test "unpinned, two contributors refuse in every family, independent of declaration order":
    var u = use()
    var r = use()
    r.nixProvisioning = r.nixProvisioning.reversed()
    r.tarballProvisioning = r.tarballProvisioning.reversed()
    r.scoopProvisioning = r.scoopProvisioning.reversed()
    let nixMsg = refusal(proc () = discard nixAcquisitionPlan(u, NixTarget))
    let tarMsg = refusal(proc () = discard tarballAcquisitionPlan(u))
    let scoopMsg = refusal(proc () = discard scoopAcquisitionPlan(u, ScoopTarget))
    check "ambiguous nix provisioning" in nixMsg
    check "ambiguous tarball provisioning" in tarMsg
    check "ambiguous scoop provisioning" in scoopMsg
    for m in [nixMsg, tarMsg, scoopMsg]:
      check "one, two" in m
    check refusal(proc () = discard nixAcquisitionPlan(r, NixTarget)) == nixMsg
    check refusal(proc () = discard tarballAcquisitionPlan(r)) == tarMsg
    check refusal(proc () = discard scoopAcquisitionPlan(r, ScoopTarget)) == scoopMsg

  test "a pin selects its contributor in every family and binds the contribution into the lock identity":
    for chosen in ["one", "two"]:
      var u = use()
      u.provisioningPin = pin(chosen)
      let prefix = "contributor:" & chosen & "\ncontribution:" & Fp & "\n"
      let nixPlan = nixAcquisitionPlan(u, NixTarget)
      check nixPlan.nixSelector == "nixpkgs#" & chosen
      check nixPlan.lockIdentity == prefix & "nixpkgs#" & chosen
      let tarPlan = tarballAcquisitionPlan(u)
      check tarPlan.sha256 == (if chosen == "one": ShaA else: ShaB)
      check tarPlan.lockIdentity == prefix & "sha256:" & tarPlan.sha256
      let scoopPlan = scoopAcquisitionPlan(u, ScoopTarget)
      check scoopPlan.app == chosen
      check scoopPlan.lockIdentity == prefix & "scoop:main/" & chosen

  test "the contribution fingerprint alone moves every family's lock identity":
    var u1 = use()
    u1.provisioningPin = pin("one")
    var u2 = u1
    u2.provisioningPin.contributionFingerprint = repeat('9', 64)
    check nixAcquisitionPlan(u1, NixTarget).lockIdentity !=
      nixAcquisitionPlan(u2, NixTarget).lockIdentity
    check tarballAcquisitionPlan(u1).lockIdentity !=
      tarballAcquisitionPlan(u2).lockIdentity
    check scoopAcquisitionPlan(u1, ScoopTarget).lockIdentity !=
      scoopAcquisitionPlan(u2, ScoopTarget).lockIdentity
    # And the pin is what moved it: unpinned unique selection spells no
    # contribution at all.
    var unique = use()
    unique.nixProvisioning = unique.nixProvisioning[0 .. 0]
    check nixAcquisitionPlan(unique, NixTarget).lockIdentity ==
      "contributor:one\nnixpkgs#one"

  test "a pin is never relaxed to another contributor":
    var u = use()
    u.nixProvisioning = @[nixEntry("two", "nixpkgs#two")]
    u.provisioningPin = pin("one")
    let m = refusal(proc () = discard nixAcquisitionPlan(u, NixTarget))
    check "pins contributor \"one\"" in m
    check "no nix realization from it is eligible" in m
    check "eligible contributors: two" in m

  test "a lock-pinned realization is provisioned in every family, never another of the contributor's":
    # Contributor "one" declares a SECOND realization in every family. A pin
    # that selects the contributor only (curator policy / unique) takes its
    # first entry in declaration order; a committed-lock pin names the
    # realization, and exactly that one is provisioned -- or the planner
    # refuses. Without this the lock could pin one realization while the
    # engine realized another of the same contributor's.
    var u = use()
    u.nixProvisioning.add(nixEntry("one", "nixpkgs#one-b"))
    u.nixProvisioning[^1].lockIdentity = "nix:one-b"
    u.tarballProvisioning.add(tarEntry("one", ShaC))
    u.tarballProvisioning[^1].lockIdentity = "tar:one-c"
    u.scoopProvisioning.add(scoopEntry("one", "one-b"))
    u.scoopProvisioning[^1].lockIdentity = "scoop:one-b"
    u.tarballProvisioning[1].lockIdentity = "tar:two"
    u.provisioningPin = pin("one")
    check nixAcquisitionPlan(u, NixTarget).nixSelector == "nixpkgs#one"
    check tarballAcquisitionPlan(u).sha256 == ShaA
    check scoopAcquisitionPlan(u, ScoopTarget).app == "one"
    let prefix = "contributor:one\ncontribution:" & Fp & "\n"
    u.provisioningPin.realizationLockIdentity = "nix:one-b"
    let nixPlan = nixAcquisitionPlan(u, NixTarget)
    check nixPlan.nixSelector == "nixpkgs#one-b"
    check nixPlan.lockIdentity == prefix & "nix:one-b"
    check "declares no tarball realization with that lock identity" in
      refusal(proc () = discard tarballAcquisitionPlan(u))
    check "declares no scoop realization with that lock identity" in
      refusal(proc () = discard scoopAcquisitionPlan(u, ScoopTarget))
    u.provisioningPin.realizationLockIdentity = "tar:one-c"
    let tarPlan = tarballAcquisitionPlan(u)
    check tarPlan.sha256 == ShaC
    check tarPlan.lockIdentity == prefix & "tar:one-c"
    check "declares no nix realization with that lock identity" in
      refusal(proc () = discard nixAcquisitionPlan(u, NixTarget))
    u.provisioningPin.realizationLockIdentity = "scoop:one-b"
    let scoopPlan = scoopAcquisitionPlan(u, ScoopTarget)
    check scoopPlan.app == "one-b"
    check scoopPlan.lockIdentity == prefix & "scoop:one-b"
    # Another contributor's realization is never taken for the pinned one.
    u.provisioningPin.realizationLockIdentity = "tar:two"
    check "declares no tarball realization with that lock identity" in
      refusal(proc () = discard tarballAcquisitionPlan(u))
    # The locked realization declared for another host is refused, not
    # replaced by the contributor's entry for this host.
    var h = u
    h.tarballProvisioning[^1].os = otherOs()
    h.provisioningPin.realizationLockIdentity = "tar:one-c"
    let hostMsg = refusal(proc () = discard tarballAcquisitionPlan(h))
    check "declares no tarball realization with that lock identity" in hostMsg
    check "eligible for host" in hostMsg

  test "tarball entries for another host are filtered before the contributor is chosen":
    var u = use()
    u.tarballProvisioning = @[tarEntry("one", ShaA, os = otherOs()),
                              tarEntry("two", ShaB)]
    # Unpinned: only "two" matches this host, so it is the unique choice.
    check tarballAcquisitionPlan(u).sha256 == ShaB
    # Pinned to "one": its only entry is for another host -- refused, not
    # relaxed to "two".
    u.provisioningPin = pin("one")
    let m = refusal(proc () = discard tarballAcquisitionPlan(u))
    check "no tarball realization from it is eligible for host" in m

  test "a malformed or misdirected hand-stamped pin refuses":
    var u = use()
    u.provisioningPin = pin("one")
    u.provisioningPin.contributionFingerprint = "abc"
    check "malformed provisioning pin" in
      refusal(proc () = discard nixAcquisitionPlan(u, NixTarget))
    u.provisioningPin = ProvisioningPin(contributionRecordDigest: Digest)
    check "malformed provisioning pin" in
      refusal(proc () = discard scoopAcquisitionPlan(u, ScoopTarget))
    u.provisioningPin = pin("one", packageName = "other-tool")
    check "was made for package \"other-tool\"" in
      refusal(proc () = discard tarballAcquisitionPlan(u))

  test "the removed environment selector refuses whenever it is set":
    for value in ["two", " ", "one"]:
      putEnv(RemovedContributorSelectorEnv, value)
      var pinned = use()
      pinned.provisioningPin = pin("one")
      var single = use()
      single.nixProvisioning = single.nixProvisioning[0 .. 0]
      for u in [pinned, single, use()]:
        check "is set" in refusal(proc () = discard nixAcquisitionPlan(u, NixTarget))
        check "is set" in refusal(proc () = discard tarballAcquisitionPlan(u))
        check "is set" in refusal(proc () = discard scoopAcquisitionPlan(u, ScoopTarget))
    delEnv(RemovedContributorSelectorEnv)
    var single = use()
    single.nixProvisioning = single.nixProvisioning[0 .. 0]
    check nixAcquisitionPlan(single, NixTarget).nixSelector == "nixpkgs#one"
