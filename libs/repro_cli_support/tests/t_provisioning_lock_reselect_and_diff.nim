## M7 deliverable 5 on the CLI: ``repro lock refresh --provisioning``,
## ``repro lock diff``, and the build-time explanation of a refused lock
## (``ReproOS-Campaign-Completion.milestones.org`` § M7; normative design
## ``reprobuild-specs/Provisioning-Contributions.md`` § Locks And
## Snapshots).
##
## Drives the functions the ``repro`` binary calls -- the real
## ``runReproLockCommand`` dispatcher with real argument vectors over real
## lock FILES on disk, ``buildProvisioningPins`` (what ``repro build``
## calls before any tool identity is resolved), and the exported builders
## whose text the CLI prints (``reselectCommittedProvisioning``,
## ``lockDiffReport``) -- and asserts:
##
##   * a plain ``repro lock refresh`` never re-selects: the records are
##     carried byte for byte even when the catalogs moved, and the catalogs
##     are not even consulted;
##   * ``repro lock refresh --provisioning`` re-selects, rewrites the
##     records and prints the diff, after which a build accepts the lock;
##     and it refuses -- leaving the committed lock BYTE-IDENTICAL -- on no
##     catalog source (the production state today), ambiguity, unbound
##     dependencies, a contradictory policy and an unreadable incumbent;
##   * ``--provisioning`` is accepted by ``refresh`` only;
##   * a build refused with ``contribution-changed`` says which field moved
##     (given verified evidence) or that it cannot tell, and names the
##     exact command that re-selects;
##   * ``repro lock diff`` reports, refuses unreadable locks (never "no
##     change"), and treats a lock written before the ``provisioning`` key
##     existed as having no records;
##   * every committed ``repro.lock`` in the workspace (none of which has
##     provisioning records) behaves exactly as before under refresh and
##     diff.
##
## The catalog source is supplied BY THE TEST: M6 deliverables 1 and 2
## have no production implementation (see
## ``t_e2e_locked_provisioning_contributor_selection``). The ``repro``
## binary itself is not run. The test does not capture stdout; the printed
## text is the exported builders' output, asserted directly.

import std/[algorithm, options, os, sequtils, strutils, tempfiles, unittest]

import repro_cli_support
import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/contribution_fingerprint
import repro_interface_artifacts/contribution_lock
import repro_interface_artifacts/provisioning_lock_diff
import repro_lock

const
  Pkg = "reselect-target"
  A = "github:example/reselect-catalog-a"
  B = "github:example/reselect-catalog-b"
  Ws = "github:example/reselect-workspace"
  PackagesRemote = "github:example/reselect-packages"
  Iface = repeat('1', 64)
  DepIface = repeat('3', 64)
  PackagesRev = repeat('9', 40)
  RevA1 = repeat('a', 40)
  RevB1 = repeat('c', 40)
  Art0 = repeat('4', 64)
  ArtA = repeat('5', 64)
  ArtB = repeat('7', 64)
  NixpkgsRev = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
  NarA = "sha256-" & repeat('A', 43) & "="
  NarB = "sha256-" & repeat('B', 43) & "="
  ProvA = repeat('a', 64)
  ProvA2 = repeat('d', 64)
  ProvB = repeat('b', 64)

let Host = currentPlatformId()

proc nixLockId(selector, nar: string): string =
  "github:NixOS/nixpkgs/" & NixpkgsRev & "?narHash=" & nar & "#" & selector

proc contributionOf(contributor, selector, nar: string):
    InterfaceProvisioningContribution =
  InterfaceProvisioningContribution(targetPackage: Pkg,
    targetInterfaceFingerprint: Iface, contributor: contributor,
    nixProvisioning: @[InterfaceNixProvisioning(packageName: Pkg,
      contributor: contributor, selector: "nixpkgs#" & selector,
      executablePath: "bin/tool", nixpkgsRef: "github:NixOS/nixpkgs",
      nixpkgsRev: NixpkgsRev, nixpkgsNarHash: nar, packageId: "tool@1",
      lockIdentity: nixLockId(selector, nar))])

let contribA = contributionOf(A, "tool-a", NarA)
let contribB = contributionOf(B, "tool-b", NarB)

proc ident(c: InterfaceProvisioningContribution; provider: string;
           deps: seq[ContributionDependencyRef] = @[]): ContributionIdentity =
  ContributionIdentity(contribution: c, providerIdentity: provider,
    dependencies: deps)

type World = object
  imports: seq[CatalogImport]
  offered: seq[ContributionIdentity]
  policy: CatalogSelectionPolicy
  previous: seq[ContributionIdentity]

proc catalog(remote, revision, artifact: string;
             contributions: seq[InterfaceProvisioningContribution]):
    CatalogImport =
  CatalogImport(coordinate: CatalogCoordinate(workspace: Ws, remote: remote,
      revision: revision, interfaceArtifact: artifact),
    discoveredAt: "/w/" & remote.split('/')[^1],
    content: some(CatalogContent(contributions: contributions)))

proc interfaces(): CatalogImport =
  CatalogImport(coordinate: CatalogCoordinate(workspace: Ws,
      remote: PackagesRemote, revision: PackagesRev, interfaceArtifact: Art0),
    discoveredAt: "/w/packages", content: some(CatalogContent(
      canonicalInterfaces: @[catalogInterface(Pkg, Iface)])))

proc policyFor(contributor: string): CatalogSelectionPolicy =
  CatalogSelectionPolicy(selections: @[CatalogSelectionRule(
    targetPackage: Pkg, contributor: contributor)])

proc worldAB(providerA = ProvA; policy = CatalogSelectionPolicy()): World =
  World(imports: @[interfaces(), catalog(A, RevA1, ArtA, @[contribA]),
      catalog(B, RevB1, ArtB, @[contribB])],
    offered: @[ident(contribA, providerA), ident(contribB, ProvB)],
    policy: policy)

var currentWorld: World
var sourceCalls = 0
var lastPurpose = pcpBuild

proc useWorld(w: World) =
  currentWorld = w
  setProvisioningCatalogSource(
    proc (request: ProvisioningCatalogRequest): ProvisioningCatalogInputs =
      inc sourceCalls
      lastPurpose = request.purpose
      ProvisioningCatalogInputs(imports: currentWorld.imports,
        offered: currentWorld.offered, policy: currentWorld.policy,
        previous: currentWorld.previous))

proc lockedA(): LockedRealization =
  ## The record the lock writer makes for contributor A, selected by policy.
  let w = worldAB(policy = policyFor(A))
  let r = reselectProvisioning(ProvisioningReselectionRequest(
    imports: w.imports, policy: w.policy, offered: w.offered,
    hostPlatform: Host, targetPlatform: Host), noContributionResolver)
  doAssert r.reselected, r.refusals.join(" | ")
  r.records[0]

var fixtureRoot = ""
var projectCounter = 0

proc baseLockText(): string =
  serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, platform: Host, optimal: true,
    inputsDigest: inputsDigestOf("reselect"),
    packages: @[LockedPackage(name: "nim", version: "2.2.8", source: "nim",
      selection: ssSelected)]))

proc project(records: seq[LockedRealization]; rawLock = ""): string =
  ## A project directory with a ``repro.solver`` sidecar and a committed
  ## ``repro.lock`` carrying ``records`` (or ``rawLock`` verbatim).
  inc projectCounter
  result = fixtureRoot / ("project-" & $projectCounter)
  createDir(result)
  writeFile(result / "repro.solver", "package app\nversions: 1.0.0\n")
  writeFile(result / "repro.lock",
    if rawLock.len > 0: rawLock
    else: serializeLockedDependencies(parseLockedDependencies(
      baseLockText()).withProvisioningRealizations(records)))

proc refreshArgs(dir: string; extra: varargs[string]): seq[string] =
  result = @["refresh", dir, "--inputs", dir / "repro.solver"]
  for e in extra: result.add(e)

proc provisioningLine(text: string): string =
  for line in text.splitLines():
    if line.startsWith(ProvisioningLockKey & " = "):
      return line

proc claims(dir: string): seq[LockedRealization] =
  parseLockedDependencies(readFile(dir / "repro.lock")).
    lockedProvisioningClaims()

proc buildRefusal(dir: string; lockPath = ""): string =
  try:
    discard buildProvisioningPins(ProjectInterfaceArtifact(), dir, lockPath)
    ""
  except ProvisioningSelectionRefused as err:
    err.msg

fixtureRoot = createTempDir("repro-m7d5-", "")

suite "explicit provisioning re-selection and lock diff on the CLI":

  test "a build refused by contribution-changed explains the change and names the re-select command":
    let dir = project(@[lockedA()])
    # A republished A: same record, new provider identity.
    var w = worldAB(providerA = ProvA2, policy = policyFor(A))
    useWorld(w)
    let bare = buildRefusal(dir)
    check "contribution-changed" in bare
    check "what changed since the lock was written (the locked record -> " &
      "what the composed catalogs offer now):\n  provisioning \"" & Pkg &
      "\" on " & Host & " -> " & Host & ": changed (contribution-changed)" in
      bare
    check "    cause: not determinable from the records" in bare
    check bare.endsWith("\nto re-select explicitly (rewrites the lock's " &
      "provisioning records and prints this diff; nothing re-selects " &
      "silently):\n  repro lock refresh --provisioning " & quoteShell(dir))
    # With the locked contribution supplied as evidence, the field is named.
    w.previous = @[ident(contribA, ProvA)]
    useWorld(w)
    let given = buildRefusal(dir)
    check "      - provider identity: " & ProvA & " -> " & ProvA2 in given
    check "not determinable" notin given
    # A lock named for the build is named in the command.
    let elsewhere = fixtureRoot / "elsewhere.lock"
    copyFile(dir / "repro.lock", elsewhere)
    let named = buildRefusal(dir, elsewhere)
    check named.endsWith("repro lock refresh --provisioning " &
      quoteShell(dir) & " --lock " & quoteShell(elsewhere))
    check provisioningReselectCommand("", elsewhere) ==
      "repro lock refresh --provisioning --lock " & quoteShell(elsewhere)
    check provisioningReselectCommand(dir, dir / "repro.lock") ==
      "repro lock refresh --provisioning " & quoteShell(dir)
    # A lock that still matches builds; nothing is explained.
    useWorld(worldAB(policy = policyFor(A)))
    check buildRefusal(dir) == ""

  test "a plain refresh never re-selects, even when the catalogs moved":
    let dir = project(@[lockedA()])
    let before = provisioningLine(readFile(dir / "repro.lock"))
    check before.len > 0
    useWorld(worldAB(providerA = ProvA2, policy = policyFor(B)))
    sourceCalls = 0
    check runReproLockCommand(refreshArgs(dir)) == 0
    check provisioningLine(readFile(dir / "repro.lock")) == before
    check sourceCalls == 0

  test "refresh --provisioning re-selects, rewrites the records and prints the diff":
    let dir = project(@[lockedA()])
    useWorld(worldAB(policy = policyFor(B)))
    check buildRefusal(dir).len > 0       # the curator now contradicts the lock
    check runReproLockCommand(refreshArgs(dir, "--provisioning")) == 0
    check lastPurpose == pcpLockReselect
    let now = claims(dir)
    check now.len == 1
    check now[0].contributor == B
    check now[0].selectedBy == lsrCuratorPolicy
    check buildRefusal(dir) == ""          # the build accepts the new lock
    check lastPurpose == pcpBuild
    # The printed report, from the builder the CLI prints.
    let dir2 = project(@[lockedA()])
    let incumbent = readFile(dir2 / "repro.lock")
    let outcome = reselectCommittedProvisioning(dir2, dir2 / "repro.lock",
      true, incumbent, baseLockText(), Host, Host)
    check outcome.reselected
    let lines = outcome.report.splitLines()
    check lines[0] == "repro lock refresh --provisioning: re-selected " &
      "provisioning on " & Host & " -> " & Host & " (1 selection(s) locked; " &
      "0 record(s) for other platform pairs carried forward unchanged)"
    check lines[1] == "provisioning \"" & Pkg & "\" on " & Host & " -> " &
      Host & ": changed (contributor-changed, catalog-changed, " &
      "realization-changed)"
    check lines[2] == "  contributor changed: \"" & A & "\" -> \"" & B & "\""
    # Re-selecting again changes nothing, and says so.
    let again = reselectCommittedProvisioning(dir, dir / "repro.lock", true,
      readFile(dir / "repro.lock"), baseLockText(), Host, Host)
    check again.reselected
    check again.report.splitLines()[1] == "no provisioning selection changed"

  test "refresh --provisioning refuses and leaves the committed lock byte-identical":
    let record = lockedA()
    template refusesUnchanged(w: Option[World]; rawLock = "") =
      block:
        let dir = project(@[record], rawLock)
        let before = readFile(dir / "repro.lock")
        if w.isSome: useWorld(w.get)
        else: setProvisioningCatalogSource(nil)
        check runReproLockCommand(refreshArgs(dir, "--provisioning")) == 1
        check readFile(dir / "repro.lock") == before
    # No catalog source: the production state today.
    refusesUnchanged(none(World))
    check reselectCommittedProvisioning("p", "p/repro.lock", false, "",
      baseLockText(), Host, Host).refusals[0].startsWith(
        "re-selection needs the composed catalogs")
    # Ambiguity: two eligible contributors and no policy.
    refusesUnchanged(some(worldAB()))
    # A contradictory policy.
    refusesUnchanged(some(worldAB(policy = CatalogSelectionPolicy(selections:
      @[CatalogSelectionRule(targetPackage: Pkg, contributor: A),
        CatalogSelectionRule(targetPackage: Pkg, contributor: B)]))))
    # A dependency the catalog source does not bind.
    var unbound = worldAB(policy = policyFor(A))
    unbound.offered[0] = ident(contribA, ProvA, @[ContributionDependencyRef(
      targetPackage: "dep", contributor: B,
      targetInterfaceFingerprint: DepIface)])
    refusesUnchanged(some(unbound))
    check reselectCommittedProvisioning("p", "p/repro.lock", false, "",
      baseLockText(), Host, Host).refusals.anyIt(
        it.startsWith("dependencies-not-fully-resolved"))
    # An incumbent whose provisioning records cannot be read.
    let broken = baseLockText() & ProvisioningLockKey & " = [{ record = \"x\" }]\n"
    refusesUnchanged(some(worldAB(policy = policyFor(A))), broken)
    let spelled = baseLockText() & "\"" & ProvisioningLockKey & "\" = []\n"
    refusesUnchanged(some(worldAB(policy = policyFor(A))), spelled)
    # An incumbent that is not a lock at all and names no provisioning key
    # contributes no record -- as for a plain refresh, which overwrites it.
    useWorld(worldAB(policy = policyFor(A)))
    let garbage = reselectCommittedProvisioning("p", "p/repro.lock", true,
      "not a lock\n", baseLockText(), Host, Host)
    check garbage.reselected
    check garbage.diff.changes.mapIt(it.kind) == @[pckAdded]
    # A catalog source that fails.
    block:
      let dir = project(@[record])
      let before = readFile(dir / "repro.lock")
      setProvisioningCatalogSource(
        proc (request: ProvisioningCatalogRequest): ProvisioningCatalogInputs =
          raise newException(IOError, "catalog fetch failed"))
      check runReproLockCommand(refreshArgs(dir, "--provisioning")) == 1
      check readFile(dir / "repro.lock") == before
      check reselectCommittedProvisioning(dir, dir / "repro.lock", true,
        before, baseLockText(), Host, Host).refusals == @["the catalogs to " &
        "re-select from could not be obtained: catalog fetch failed"]

  test "--provisioning is accepted only by refresh":
    let dir = project(@[lockedA()])
    let before = readFile(dir / "repro.lock")
    check runReproLockCommand(@["solve", dir, "--inputs",
      dir / "repro.solver", "--write", "--provisioning"]) == 2
    check runReproLockCommand(@["validate", dir, "--provisioning"]) == 2
    check readFile(dir / "repro.lock") == before

  test "repro lock diff reports, refuses unreadable locks, and reads a pre-provisioning lock as empty":
    let a = fixtureRoot / "diff-a.lock"
    let b = fixtureRoot / "diff-b.lock"
    let empty = fixtureRoot / "diff-empty.lock"
    writeFile(a, readFile(project(@[lockedA()]) / "repro.lock"))
    writeFile(empty, baseLockText())
    check lockDiffReport(a, a) ==
      (0, "repro lock diff: no provisioning selection changed")
    check runReproLockCommand(@["diff", a, a]) == 0
    # The same records re-serialised in another order are the same lock.
    writeFile(b, serializeLockedDependencies(parseLockedDependencies(
      readFile(a))))
    check lockDiffReport(a, b).rc == 0
    # A lock from before the key existed has no records: all added.
    let added = lockDiffReport(empty, a)
    check added.rc == 1
    check added.text.startsWith("provisioning \"" & Pkg & "\" on " & Host &
      " -> " & Host & ": added (added)")
    check lockDiffReport(a, empty).text.contains(": removed (removed)")
    check runReproLockCommand(@["diff", empty, a]) == 1
    # A contributor change.
    useWorld(worldAB(policy = policyFor(B)))
    let reselected = reselectCommittedProvisioning("p", a, true, readFile(a),
      baseLockText(), Host, Host)
    writeFile(b, reselected.document)
    let changed = lockDiffReport(a, b)
    check changed.rc == 1
    check changed.text == renderProvisioningDiff(reselected.diff)
    # Unreadable locks refuse with rc 2 -- never "no change".
    for bad in [baseLockText() & ProvisioningLockKey & " = [{ x = \"y\" }]\n",
        baseLockText() & "\"" & ProvisioningLockKey & "\" = []\n",
        baseLockText() & "Provisioning = []\n",
        baseLockText() & "[" & ProvisioningLockKey & "]\n",
        "not a lock at all\n"]:
      let bf = fixtureRoot / "diff-bad.lock"
      writeFile(bf, bad)
      for (x, y) in [(bf, a), (a, bf), (bf, bf)]:
        let r = lockDiffReport(x, y)
        check r.rc == 2
        check "provisioning diff refused" in r.text
        check runReproLockCommand(@["diff", x, y]) == 2
    let missing = lockDiffReport(a, fixtureRoot / "missing.lock")
    check missing.rc == 2
    check missing.text.endsWith("missing.lock: no such file")
    check runReproLockCommand(@["diff", a]) == 2

  test "the workspace's committed locks behave exactly as before under refresh and diff":
    let workspaceRoot = currentSourcePath().parentDir.parentDir.parentDir.
      parentDir.parentDir
    var locks: seq[string] = @[]
    if fileExists(workspaceRoot / "repro.lock"):
      locks.add(workspaceRoot / "repro.lock")
    for kind, path in walkDir(workspaceRoot):
      if kind in {pcDir, pcLinkToDir} and fileExists(path / "repro.lock"):
        locks.add(path / "repro.lock")
    locks.sort(cmp)
    check locks.anyIt(it.endsWith("reprobuild" / "repro.lock"))
    echo "  workspace locks examined: ", locks.len
    useWorld(World())      # catalogs that offer nothing
    for path in locks:
      let text = readFile(path)
      var records: seq[LockedRealization]
      check provisioningRecordsOf(text, path, records) == ""
      check records.len == 0
      # diff against itself: nothing; and the refresh carry-forward adds
      # nothing.
      check diffProvisioningLockDocuments(text, text).unchanged
      check lockDiffReport(path, path).rc == 0
      let carried = withProvisioningCarriedForward(
        parseLockedDependencies(text), text)
      check carried.provisioningRealizationCount == 0
      # Explicit re-selection with nothing offered writes the fresh
      # document byte for byte, as a plain refresh does.
      let outcome = reselectCommittedProvisioning(path.parentDir, path, true,
        text, text, Host, Host)
      check outcome.reselected
      check outcome.document == text
      check outcome.diff.unchanged

removeDir(fixtureRoot)
setProvisioningCatalogSource(nil)
