## `realization_selection` — the one selection a recipe's `uses:` and a home
## profile's `package` reference share (GM4b; Provisioning-Contributions.md
## §"Profile Package References" → Selection, rules 1–5).
##
## Each case states the rule it pins and is falsifiable by the mutation named
## beside it. Inputs are `InterfaceToolUse` records built in the test: the
## selection is a pure function of records, a target, a policy and the host
## inventory the caller passes, so no definition needs to be compiled and
## nothing is downloaded. The PATH / Scoop inventories are closures over
## fixture data rather than the machine's PATH — not a mock of a dependency,
## but the documented injection point (`HostInventory`) through which every
## caller supplies its inventory, used so the cases are identical on every
## host.

import std/[options, strutils, unittest]

import repro_interface_artifacts
import repro_tool_profiles/realization_selection

proc tarball(url: string; cpu = ""; os = ""; version = "";
             contributor = ""; lockIdentity = ""; sha256 = "";
             cpuLevel = ""; cpuFeatures = ""): InterfaceTarballProvisioning =
  result = InterfaceTarballProvisioning(packageName: "demo",
    contributor: contributor, url: url, archiveType: "tar.gz",
    executablePath: "bin/demo", cpu: cpu, os: os,
    lockIdentity: lockIdentity,
    sha256: if sha256.len > 0: sha256 else: repeat('a', 64))
  result.detail.version = version
  result.detail.cpuLevel = cpuLevel
  result.detail.cpuFeatures = cpuFeatures

proc nixRecord(selector: string; contributor = ""): InterfaceNixProvisioning =
  InterfaceNixProvisioning(packageName: "demo", contributor: contributor,
    selector: selector, executablePath: "bin/demo")

proc scoopRecord(app: string; version = "1.0"; contributor = ""):
    InterfaceScoopProvisioning =
  InterfaceScoopProvisioning(packageName: "demo", contributor: contributor,
    bucket: "main", app: app, version: version,
    executablePath: app & ".exe")

proc request(target: RealizationTarget; policy: SelectionPolicy;
             version = ""; contributor = none(string);
             availability = PackageAvailability();
             inventory = HostInventory()): SelectionRequest =
  SelectionRequest(packageName: "demo", target: target, policy: policy,
    version: version, contributor: contributor, availability: availability,
    probeNames: @["demo"], definitionKnown: true, inventory: inventory)

let linux = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)
let macArm = realizationTargetFor(pcAArch64, poMacos)
let windows = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)

proc pathInventory(found: string): HostInventory =
  result.probePath = proc(names: seq[string]): string = found

suite "realization_selection: lock-identity pin":
  # Provisioning-Contributions.md §"The home-profile lock": a recorded
  # selection pins its lock identity, so exactly that realization is
  # eligible.

  test "a pinned identity selects the locked record over a newer default":
    # Mutation: ignoring ``request.lockIdentity`` selects "new" (declaration
    # order), which is what an unpinned request does.
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("new", os = "linux", version = "2.0", sha256 = repeat('b', 64)),
      tarball("old", os = "linux", version = "1.0", sha256 = repeat('c', 64))])
    check selectRealization(use, request(linux, @[rkTarball])).tarball.url ==
      "new"
    var req = request(linux, @[rkTarball], contributor = some(""))
    req.lockIdentity = "sha256:" & repeat('c', 64)
    let sel = selectRealization(use, req)
    check sel.tarball.url == "old"
    check sel.version == "1.0"
    check sel.lockIdentity == req.lockIdentity

  test "a pinned contributor identity matches the contributor form":
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("canonical", os = "linux"),
      tarball("contrib", os = "linux", contributor = "github:x/y")])
    var req = request(linux, @[rkTarball])
    req.lockIdentity = "contributor:github:x/y\nsha256:" & repeat('a', 64)
    # Same digest, two contributors: the identity alone disambiguates.
    check selectRealization(use, req).tarball.url == "contrib"

  test "a withdrawn identity is a miss naming it and what is offered, " &
      "never a re-selection":
    let use = InterfaceToolUse(packageSelector: "demo",
      tarballProvisioning: @[
        tarball("new", os = "linux", version = "2.0", sha256 = repeat('b', 64))],
      nixProvisioning: @[nixRecord("nixpkgs#demo")])
    var req = request(linux, @[rkTarball, rkNix, rkPath],
      contributor = some(""), inventory = pathInventory("/usr/bin/demo"))
    req.lockIdentity = "sha256:" & repeat('c', 64)
    req.target.isHost = true
    try:
      discard selectRealization(use, req)
      check false
    except EMissingRealization as err:
      check err.steps.len == 3
      check err.steps[0].reason.contains("sha256:" & repeat('c', 64))
      check err.steps[0].reason.contains("no longer offered")
      check err.steps[0].reason.contains("sha256:" & repeat('b', 64))
      # Neither another nix record nor PATH substitutes for the locked one.
      check not err.steps[1].selected
      check not err.steps[2].selected

  test "nix and scoop records are pinned by their lock identity too":
    let nixUse = InterfaceToolUse(packageSelector: "demo", nixProvisioning: @[
      nixRecord("nixpkgs#demo-next"), nixRecord("nixpkgs#demo")])
    var nixReq = request(linux, @[rkNix])
    nixReq.lockIdentity = "nixpkgs#demo"
    check selectRealization(nixUse, nixReq).nix.selector == "nixpkgs#demo"
    let scoopUse = InterfaceToolUse(packageSelector: "demo",
      scoopProvisioning: @[scoopRecord("demo-next", "2.0"),
        scoopRecord("demo", "1.0")])
    var scoopReq = request(windows, @[rkScoop])
    scoopReq.lockIdentity = "scoop:main/demo"
    let scoopSel = selectRealization(scoopUse, scoopReq)
    check scoopSel.scoop.app == "demo"
    check scoopSel.version == "1.0"

suite "realization_selection: tarball":

  test "the most specific (cpu, os) coordinate wins over a catch-all":
    # Mutation: dropping the arm tier (taking the first applicable record)
    # selects the catch-all declared first.
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("any"), tarball("exact", cpu = "aarch64", os = "macos")])
    let choice = selectTarballRecord(use.tarballProvisioning, macArm)
    check choice.status == kcSelected
    check use.tarballProvisioning[choice.index].url == "exact"

  test "equal coordinates fall to declaration order":
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("first", os = "linux", version = "2.0"),
      tarball("second", os = "linux", version = "1.0")])
    let sel = selectRealization(use, request(linux, @[rkTarball]))
    check sel.tarball.url == "first"
    check sel.version == "2.0"

  test "a version pin selects that version and names what is offered " &
      "when it is absent":
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("new", os = "linux", version = "2.0"),
      tarball("old", os = "linux", version = "1.0")])
    check selectRealization(use,
      request(linux, @[rkTarball], version = "1.0")).tarball.url == "old"
    let choice = selectTarballRecord(use.tarballProvisioning, linux, "3.0")
    check choice.status == kcVersionNotOffered
    check "2.0" in choice.detail and "1.0" in choice.detail

  test "no record for the target names the coverage and the target":
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("win", cpu = "x86_64", os = "windows")])
    let choice = selectTarballRecord(use.tarballProvisioning, macArm)
    check choice.status == kcNoneForTarget
    check "aarch64-macos" in choice.detail
    check "x86_64-windows" in choice.detail

  test "two eligible contributors are ambiguous; a pin selects":
    # Mutation: picking the first eligible record regardless of contributor
    # (import order as a selection rule) makes the first check fail.
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("canonical", os = "linux"),
      tarball("contrib", os = "linux", contributor = "github:x/y")])
    expect EAmbiguousRealization:
      discard selectRealization(use, request(linux, @[rkTarball, rkNix]))
    let pinned = selectRealization(use,
      request(linux, @[rkTarball], contributor = some("github:x/y")))
    check pinned.tarball.url == "contrib"
    check pinned.contributor == "github:x/y"
    check pinned.lockIdentity == "contributor:github:x/y\nsha256:" &
      repeat('a', 64)
    let canonical = selectRealization(use,
      request(linux, @[rkTarball], contributor = some("")))
    check canonical.tarball.url == "canonical"
    check canonical.lockIdentity == "sha256:" & repeat('a', 64)

  test "ambiguity does not fall through to the next kind":
    let use = InterfaceToolUse(packageSelector: "demo",
      tarballProvisioning: @[tarball("a", os = "linux"),
        tarball("b", os = "linux", contributor = "c")],
      nixProvisioning: @[nixRecord("nixpkgs#demo")])
    try:
      discard selectRealization(use, request(linux, @[rkTarball, rkNix]))
      check false
    except EAmbiguousRealization as err:
      check err.kind == rkTarball
      check err.steps.len == 1  # nix was never consulted

  test "a floor the target cannot meet is a capability shortfall":
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("v3", cpu = "x86_64", os = "linux", cpuLevel = "x86-64-v3")])
    let v2 = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v2)
    let choice = selectTarballRecord(use.tarballProvisioning, v2)
    check choice.status == kcCapabilityShortfall
    check "x86-64-v3" in choice.detail
    let v3 = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v3)
    check selectTarballRecord(use.tarballProvisioning, v3).status ==
      kcSelected

  test "the highest satisfied floor wins among one coordinate":
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("v1", cpu = "x86_64", os = "linux"),
      tarball("v3", cpu = "x86_64", os = "linux", cpuLevel = "x86-64-v3"),
      tarball("v4", cpu = "x86_64", os = "linux", cpuLevel = "x86-64-v4")])
    let v3 = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v3)
    let choice = selectTarballRecord(use.tarballProvisioning, v3)
    check use.tarballProvisioning[choice.index].url == "v3"

  test "an unreadable floor is refused, never read as floorless or skipped":
    # Mutation: `continue` on an unparseable record (skip it) turns this into
    # a quiet "no record for the target" and lets nix select.
    let use = InterfaceToolUse(packageSelector: "demo",
      tarballProvisioning: @[tarball("typo", os = "linux",
        cpuLevel = "x86-64-v9")],
      nixProvisioning: @[nixRecord("nixpkgs#demo")])
    let choice = selectTarballRecord(use.tarballProvisioning, linux)
    check choice.status == kcInvalidRecord
    check "x86-64-v9" in choice.detail
    expect EInvalidRealization:
      discard selectRealization(use, request(linux, @[rkTarball, rkNix]))

suite "realization_selection: nix, scoop, path":

  test "nix serves linux and macos targets, never windows":
    let use = InterfaceToolUse(packageSelector: "demo",
      nixProvisioning: @[nixRecord("nixpkgs#demo")])
    check selectRealization(use, request(macArm, @[rkNix])).kind == rkNix
    expect EMissingRealization:
      discard selectRealization(use, request(windows, @[rkNix]))

  test "a version pin makes nix ineligible (a nixPackage names no version)":
    let use = InterfaceToolUse(packageSelector: "demo",
      nixProvisioning: @[nixRecord("nixpkgs#demo")])
    let choice = selectNixRecord(use.nixProvisioning, linux, "1.0")
    check choice.status == kcVersionNotOffered

  test "scoop serves windows only and honours an exact version":
    let use = InterfaceToolUse(packageSelector: "demo",
      scoopProvisioning: @[scoopRecord("demo", "1.0")])
    check selectRealization(use, request(windows, @[rkScoop])).scoop.app ==
      "demo"
    expect EMissingRealization:
      discard selectRealization(use, request(linux, @[rkScoop]))
    check selectScoopRecord(use.scoopProvisioning, windows, "2.0").status ==
      kcVersionNotOffered

  test "path is consulted only for the host, and is ambient":
    let use = InterfaceToolUse(packageSelector: "demo")
    var hostTarget = linux
    hostTarget.isHost = true
    let sel = selectRealization(use,
      request(hostTarget, @[rkPath], inventory = pathInventory("/usr/bin/demo")))
    check sel.kind == rkPath
    check sel.ambient
    check sel.pathExecutable == "/usr/bin/demo"
    check sel.lockIdentity == "path:/usr/bin/demo"
    # The same inventory is never asked about a target that is not the host.
    expect EMissingRealization:
      discard selectRealization(use,
        request(linux, @[rkPath], inventory = pathInventory("/usr/bin/demo")))

  test "a host's Scoop inventory realizes an undeclared app, ambiently":
    let use = InterfaceToolUse(packageSelector: "demo")
    var hostWin = windows
    hostWin.isHost = true
    var inventory: HostInventory
    inventory.probeScoop = proc(app: string): ScoopInventoryHit =
      ScoopInventoryHit(found: true, installed: true, bucket: "extras",
        app: app, version: "3.1", executableName: app & ".exe")
    let sel = selectRealization(use,
      request(hostWin, @[rkScoop], inventory = inventory))
    check sel.kind == rkScoop
    check sel.ambient
    check sel.scoopInventory.bucket == "extras"
    check sel.lockIdentity == "scoop:extras/demo"

suite "realization_selection: policy, availability, diagnostics":

  test "policy order decides; the first kind that selects wins":
    let use = InterfaceToolUse(packageSelector: "demo",
      tarballProvisioning: @[tarball("t", os = "macos")],
      nixProvisioning: @[nixRecord("nixpkgs#demo")])
    check selectRealization(use, request(macArm, @[rkTarball, rkNix])).kind ==
      rkTarball
    check selectRealization(use, request(macArm, @[rkNix, rkTarball])).kind ==
      rkNix

  test "a declared platform constraint refuses before any kind, PATH included":
    # Mutation: moving the availability gate after the policy loop lets the
    # planted PATH executable resolve the package.
    let use = InterfaceToolUse(packageSelector: "demo")
    var hostTarget = linux
    hostTarget.isHost = true
    let windowsOnly = PackageAvailability(declared: true,
      platforms: @[PackagePlatform(cpu: pcAny, os: poWindows)],
      message: "a Windows tool")
    try:
      discard selectRealization(use, request(hostTarget, @[rkPath],
        availability = windowsOnly, inventory = pathInventory("/bin/demo")))
      check false
    except EPlatformUnavailable as err:
      check "windows only" in err.msg
      check "a Windows tool" in err.msg
      check err.steps.len == 0
    # Control: without the declaration the planted executable resolves.
    check selectRealization(use, request(hostTarget, @[rkPath],
      inventory = pathInventory("/bin/demo"))).kind == rkPath

  test "a capability refusal does not fall through to PATH (PMC-4)":
    # Mutation: deleting the capabilityRefusal guard on the path step
    # resolves the same-named PATH executable.
    let use = InterfaceToolUse(packageSelector: "demo", tarballProvisioning: @[
      tarball("v3", cpu = "x86_64", os = "linux", cpuLevel = "x86-64-v3")])
    var v2host = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v2)
    v2host.isHost = true
    try:
      discard selectRealization(use, request(v2host, @[rkTarball, rkPath],
        inventory = pathInventory("/bin/demo")))
      check false
    except EMissingRealization as err:
      check err.steps.len == 2
      check err.steps[0].capabilityShortfall
      check err.steps[1].capabilityShortfall
      check "refused" in err.steps[1].reason

  test "a defined package with nothing for the target is a missing " &
      "realization naming the target":
    let use = InterfaceToolUse(packageSelector: "demo",
      tarballProvisioning: @[tarball("w", cpu = "x86_64", os = "windows")])
    try:
      discard selectRealization(use, request(macArm, DefaultSelectionPolicy))
      check false
    except EMissingRealization as err:
      check err.definitionKnown
      check "no realization of package 'demo' for aarch64-macos" in err.msg
      check "unknown package" notin err.msg

  test "an undefined name with no inventory hit is an unknown package, " &
      "and the target is still named":
    let use = InterfaceToolUse(packageSelector: "ghost")
    var req = request(macArm, DefaultSelectionPolicy)
    req.packageName = "ghost"
    req.definitionKnown = false
    try:
      discard selectRealization(use, req)
      check false
    except EMissingRealization as err:
      check not err.definitionKnown
      check "unknown package 'ghost'" in err.msg
      check "aarch64-macos" in err.msg

  test "the default policy is the same on every platform":
    check DefaultSelectionPolicy == @[rkTarball, rkNix, rkScoop, rkPath]

  test "builtin is accepted as the former spelling of tarball":
    check parseRealizationKind("builtin") == (true, rkTarball)
    check parseRealizationKind("tarball") == (true, rkTarball)
    check not parseRealizationKind("homebrew").ok

suite "realization_selection: realizer routing":

  test "installer-class work belongs to the home archive realizer":
    var rec = tarball("x", os = "windows")
    check archiveInstallerFeatures(rec).len == 0
    rec.detail.installMethod = "installer-msi"
    check archiveInstallerFeatures(rec) == @["installMethod installer-msi"]
    var sfx = tarball("y", os = "windows")
    sfx.archiveType = "7z-sfx"
    check "archiveType 7z-sfx" in archiveInstallerFeatures(sfx)
    var sha512Only = tarball("z")
    sha512Only.sha256 = ""
    sha512Only.detail.sha512 = repeat('b', 128)
    check "a digest other than sha256" in archiveInstallerFeatures(sha512Only)
    check tarballRealizationLockIdentity(sha512Only) ==
      "sha512:" & repeat('b', 128)

  test "strip, alias, prune, launcher and closure belong to the uses: edge":
    var rec = tarball("x")
    check extractRealizerFeatures(rec).len == 0
    rec.stripComponents = 1
    rec.executableAlias = "demo2"
    check extractRealizerFeatures(rec) == @["stripComponents",
      "executableAlias"]
