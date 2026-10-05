## ``e2e_federated_catalog_discovery_from_published_repositories`` --
## ReproOS-Campaign-Completion M6 verification entry, deliverables 1 and 2:
##
##   A consumer resolves interfaces and contributions from independent
##   pinned repositories without local develop overrides.
##
## Normative design: ``reprobuild-specs/Federated-Catalog-Imports.md``
## (declaration, pinning, discovery, provider identity) and
## ``Provisioning-Contributions.md`` (Resolution, Locks And Snapshots).
##
## ## The chain exercised, with no mocks
##
## Three independent catalog repositories are REAL git repositories with real
## commits: ``fed-packages`` publishes the canonical interface of
## ``federatedTool``; ``fed-catalog-a`` and ``fed-catalog-b`` each publish a
## tarball contribution for it. Each commits its provider source
## (``repro.nim``) and the interface artifacts THAT PROVIDER GENERATES
## (``published-interfaces/*.rbsz``, written by the production publisher,
## ``repro_cli_support/catalog_publication``, which compiles and runs the
## committed provider -- M6 deliverable 5; see ``federated_catalog_fixture``
## for what "published" means in a hermetic test). Each has a shared bare
## clone under ``REPRO_WORKSPACE_CLONES`` -- the store ``repro ws sync``
## maintains -- whose origin is the catalog's logical remote. The process
## runs in the fixture's hermetic environment (isolated ``HOME`` and global
## git configuration, no ``GIT_*`` variable, its own clone and realization
## stores). The consumer declares the three by ``repro-catalogs.toml`` (two by
## the moving ref ``main``) with a curator policy, and then, through the
## functions the ``repro`` binary calls, with the DEFAULT (production)
## ``ProvisioningCatalogSource``:
##
##   ``repro lock refresh --provisioning`` (``runReproLockCommand``) -> the
##   committed lock pins every catalog at an exact revision and the
##   interface-artifact identity read there, and locks the policy selection
##   -> ``buildProvisioningPins`` verifies the lock against the catalogs read
##   at the pinned revisions -> ``warmResolveAndWriteIdentity`` REALIZES the
##   locked contributor's archive -> a branch tip moves and the build stays
##   pinned -> explicit re-selection moves the pins and records -> ``repro
##   lock diff`` (``lockDiffReport``) explains the change field by field,
##   from evidence read out of the published catalogs at each record's own
##   revision.
##
## No develop override exists anywhere in the fixture, and no catalog
## provider is compiled or run by a consumer: catalog A's committed provider
## writes marker files when compiled or run -- which PUBLISHING does (the
## markers appear then and are removed) -- and its working tree, left dirty
## after publishing, declares a DIFFERENT contribution; while consuming, the
## markers never reappear and the selected record is the published
## artifact's.
##
## ## Adversarial inputs (each refuses, or provably changes nothing)
##
## (The adversarial ARTIFACTS below -- garbage bytes, a forged fingerprint,
## imported / developInterface records, a replacement object -- are crafted
## on purpose with the production codec: no publisher writes them, which is
## the point. Every valid publication in this file is generated.)
##
## A dirty checkout and a checkout at another commit named exactly like the
## catalog, next to the consumer; a branch name or an abbreviated id where a
## commit is required, in the declaration and hand-edited into the lock; a
## pin for a revision the store lacks; a hand-edited interface-artifact pin;
## a wrong declared identity; a garbage artifact, an artifact whose stored
## fingerprint was forged, a substituted object in the store, a commit with
## no publication, an imported / developInterface record, a SHA-256 store;
## a symbolic link, subdirectory, stray file, submodule or empty directory in
## the publication, and a publication that is itself a link; two imports of
## one repo, one remote spelled twice, a store that belongs to another
## remote (including a URL-slug collision and a junction to a foreign store),
## a junction to the right store (accepted), and a second catalog claiming
## the first one's contributor id; every ``GIT_*`` repository variable
## pointed at another store; a replace ref; a moved ``HEAD``; a branch and a
## tag of one name; declaration-order permutations. And crafted objects that
## hash correctly: two root entries named ``published-interfaces``, two
## artifacts of one name, an artifact named ``a/b.rbsz`` or ``.rbsz``, a tree
## that does not parse, a commit naming no tree or a non-hex tree; a store
## with no origin; a blobless partial clone whose promisor could serve the
## artifact (discovery never fetches); a ref that matches only as a prefix
## (``release`` vs ``release/x``) and a ref naming a blob; an origin URL
## whose host depends on who parses it (``https://evil?@host/...``), a
## multi-valued origin, a store-local ``url.*.insteadOf`` redirect, a
## symbolic ref, and a tree one byte short of an object id (added by the
## verification round); a lock pin for
## another ref or
## remote than declared, pins under a key spelling the reader skips, and an
## incumbent whose pins cannot be read.
##
## ## What this does NOT cover
##
##   * The ``repro`` binary itself (the library functions it calls are
##     driven; see the M7 e2e for why the binary is not run).
##   * Linux. Built and run on Windows only.
##   * Fetching: the shared clones are populated by the fixture, as ``repro
##     ws sync`` would; discovery never fetches.

import std/[algorithm, options, os, osproc, sequtils, strutils, tempfiles,
            unittest]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/catalog_declaration
import repro_interface_artifacts/contribution_fingerprint
import repro_cli_support
import repro_lock
import repro_project_dsl
import repro_tool_profiles

import ./federated_catalog_fixture

package federatedTool:
  executable federatedTool:
    name "federated-tool"
    cli:
      subcmd "run":
        flag verbose, bool

package federatedConsumer:
  defaultToolProvisioning "tarball"
  uses:
    "federatedTool"

const
  ToolPackage = "federatedTool"
  ContributorA = "github:example/fed-catalog-a"
  ContributorB = "github:example/fed-catalog-b"
  RepoPackages = "fed-packages"
  RepoA = "fed-catalog-a"
  RepoB = "fed-catalog-b"

let Host = currentPlatformId()

var fixtureRoot = ""
var clonesRoot = ""
var toolFingerprint = ""
  ## The canonical interface fingerprint the interface catalog PUBLISHED.
var publisherRanProviderA = false
  ## Publishing catalog A compiled and ran its provider (its markers
  ## appeared): the artifacts are the provider's output.

# ---------------------------------------------------------------------------
# Archives, contributions, artifacts
# ---------------------------------------------------------------------------

proc executableRelPath(): string =
  when defined(windows): "bin/federated-tool.cmd" else: "bin/federated-tool"

type Archive = FixtureArchive

proc buildArchive(name, marker: string): Archive =
  buildFixtureArchive(fixtureRoot, name, marker, "federated-tool-1.0.0",
    "federated-tool")

var archiveA1, archiveA2, archiveB1: Archive

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc contributionDef(contributor: string; archive: Archive):
    ProvisioningContributionDef =
  let packages = registeredPackages()
  ProvisioningContributionDef(
    targetPackage: ToolPackage,
    targetInterfaceFingerprint:
      canonicalPackageInterfaceFingerprint(findPackage(ToolPackage), packages),
    contributor: contributor,
    tarballProvisioning: @[TarballProvisioningDef(url: archive.url,
      sha256: archive.sha256, archiveType: "tar.gz",
      executablePath: executableRelPath(), stripComponents: 1,
      packageId: "federated-tool@1.0.0",
      lockIdentity: "sha256:" & archive.sha256)],
    sourceFile: "catalogs/" & contributor.split('/')[^1] & "/repro.nim",
    sourceLine: 3)

proc recordOf(def: ProvisioningContributionDef):
    InterfaceProvisioningContribution =
  toProjectInterface(findPackage("federatedConsumer"), registeredPackages(),
    @[def]).provisioningContributions[0]

proc catalogArtifact(name: string;
                     records: seq[InterfaceProvisioningContribution]):
    ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(projectName: name, packageName: name,
    provisioningContributions: records))

proc consumerArtifact(defs: seq[ProvisioningContributionDef];
                      consumerRoot: string): ProjectInterfaceArtifact =
  ## The consumer's artifact as extraction produces it: the contributions it
  ## imports (declared under ``catalogs/``) are marked imported.
  var pi = toProjectInterface(findPackage("federatedConsumer"),
    registeredPackages(), defs)
  markImportedContributions(pi, consumerRoot / "repro.nim")
  artifactFor(pi)

# ---------------------------------------------------------------------------
# The world: three real catalog repositories and their shared clones
# ---------------------------------------------------------------------------

proc markerPath(name: string): string =
  fixtureRoot / ("provider-" & name & ".marker")

proc markerPrelude(): string =
  ## Statements that write one marker if the provider is COMPILED and
  ## another if it is RUN.
  providerMarkerPrelude(markerPath("compiled"), markerPath("ran"))

proc providerSourceA(archive: Archive): string =
  ## Catalog A's COMMITTED provider: it publishes ``archive`` for
  ## ``ContributorA`` and leaves the markers when compiled or run -- which
  ## publishing does.
  fedCatalogSource("fedCatalogA", [fedContribution(ContributorA, archive,
    toolFingerprint)], markerPrelude())

proc providerSourceB(contributor: string; archive: Archive): string =
  fedCatalogSource("fedCatalogB", [fedContribution(contributor, archive,
    toolFingerprint)])

proc otherwiseSourceA(): string =
  ## What catalog A's WORKING TREE says after publishing: the markers, and a
  ## different contribution than its published artifact. Never committed.
  "import repro_project_dsl\n" & markerPrelude() &
  "provisioningFor \"" & ToolPackage & "\":\n" &
  "  interfaceFingerprint \"" & repeat('0', 64) & "\"\n" &
  "  contributor \"" & ContributorA & "\"\n" &
  "  tarball url = \"https://example.invalid/provider-says-otherwise.tar.gz\"\n"

proc forgetMarkers() =
  for name in ["compiled", "ran"]:
    if fileExists(markerPath(name)):
      removeFile(markerPath(name))

type World = object
  tag: string
  packages, a, b: CatalogRepo
  revPackages, revA1, revB1: string
  defA1, defB1: ProvisioningContributionDef
  publishedPackages, publishedA1: seq[PublishedArtifactFile]

proc remoteOf(tag, repo: string): string =
  "https://example.invalid/" & tag & "/" & repo

proc newWorld(tag: string): World =
  ## Three fresh catalog repositories (own remotes, so a test that moves a
  ## branch or damages a store affects no other test), each with one
  ## publication, synced into the shared clones.
  ## Every publication is GENERATED: each catalog commits its provider and
  ## what the production publisher extracted from it (memoized per source
  ## text within this process; the D5 fixture test measures that the
  ## publisher is deterministic).
  result.tag = tag
  let root = fixtureRoot / tag
  result.packages = initCatalogRepo(root, RepoPackages,
    remoteOf(tag, RepoPackages))
  result.a = initCatalogRepo(root, RepoA, remoteOf(tag, RepoA))
  result.b = initCatalogRepo(root, RepoB, remoteOf(tag, RepoB))
  let p = result.packages.publishRevision(
    canonicalToolSource(ToolPackage, "federated-tool"), "publish interfaces")
  result.revPackages = p.revision
  result.publishedPackages = p.files
  if toolFingerprint.len == 0:
    toolFingerprint = fingerprintHexOf(p.files[0].artifact)
  doAssert toolFingerprint == fingerprintHexOf(p.files[0].artifact)
  result.defA1 = contributionDef(ContributorA, archiveA1)
  result.defB1 = contributionDef(ContributorB, archiveB1)
  let a = result.a.publishRevision(providerSourceA(archiveA1), "publish A1")
  result.revA1 = a.revision
  result.publishedA1 = a.files
  if fileExists(markerPath("compiled")) and fileExists(markerPath("ran")):
    publisherRanProviderA = true
  forgetMarkers()
  # The working tree now says something else; it is never committed.
  writeFile(result.a.upstream / "repro.nim", otherwiseSourceA())
  result.revB1 = result.b.publishRevision(
    providerSourceB(ContributorB, archiveB1), "publish B1").revision
  for repo in [result.packages, result.a, result.b]:
    discard repo.syncSharedClone(clonesRoot)

proc specs(w: World): seq[ImportSpec] =
  @[ImportSpec(repo: RepoPackages, remote: w.packages.remote, gitRef: "main"),
    ImportSpec(repo: RepoA, remote: w.a.remote, gitRef: "main"),
    ImportSpec(repo: RepoB, remote: w.b.remote, commit: w.revB1)]

var projectCounter = 0

proc baseLockText(): string =
  serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, platform: Host, optimal: true,
    inputsDigest: inputsDigestOf("federated"),
    packages: @[LockedPackage(name: "nim", version: "2.2.8", source: "nim",
      selection: ssSelected)]))

proc newProject(w: World; imports: seq[ImportSpec] = @[];
                policy = @[(ToolPackage, ContributorA)];
                parent = ""): string =
  ## A consumer project: a ``repro.solver`` sidecar, a base committed lock and
  ## ``repro-catalogs.toml``.
  inc projectCounter
  result = (if parent.len > 0: parent else: fixtureRoot / "projects") /
    ("consumer-" & $projectCounter)
  createDir(result)
  writeFile(result / "repro.solver", "package app\nversions: 1.0.0\n")
  writeFile(result / "repro.lock", baseLockText())
  writeDeclaration(result, if imports.len > 0: imports else: w.specs(), policy)

proc refresh(dir: string): int =
  runReproLockCommand(@["refresh", dir, "--inputs", dir / "repro.solver",
    "--provisioning"])

proc reselectRefusal(dir: string): string =
  let text = readFile(dir / "repro.lock")
  let outcome = reselectCommittedProvisioning(dir, dir / "repro.lock", true,
    text, text, Host, Host)
  outcome.refusals.join(" | ")

proc lockOf(dir: string): LockedDependencies =
  parseLockedDependencies(readFile(dir / "repro.lock"))

proc pinsOf(dir: string): seq[LockedCatalogImport] =
  lockOf(dir).lockedCatalogImportPins()

proc recordsOf(dir: string): seq[LockedRealization] =
  lockOf(dir).lockedProvisioningClaims()

proc buildPins(dir: string; defs: seq[ProvisioningContributionDef]):
    seq[ProvisioningPin] =
  buildProvisioningPins(consumerArtifact(defs, dir), dir)

proc buildRefusal(dir: string; defs: seq[ProvisioningContributionDef]): string =
  try:
    discard buildPins(dir, defs)
    ""
  except ProvisioningSelectionRefused as err:
    err.msg

proc realizedMarker(dir: string; defs: seq[ProvisioningContributionDef];
                    outDir: string): string =
  let artifact = consumerArtifact(defs, dir)
  let identity = warmResolveAndWriteIdentity(artifact, outDir, tpmTarball,
    pins = buildProvisioningPins(artifact, dir)).identity
  for line in readFile(identity.profiles[0].resolvedExecutablePath).splitLines():
    if line.startsWith("echo "):
      return line["echo ".len .. ^1].strip()

proc identityOfPublished(artifacts: seq[ProjectInterfaceArtifact]): string =
  catalogArtifactIdentity(artifacts)

proc identityOfPublished(files: seq[PublishedArtifactFile]): string =
  catalogArtifactIdentity(files.mapIt(it.artifact))

proc lockLine(text, key: string): string =
  for line in text.splitLines():
    if line.startsWith(key & " = "):
      return line

proc selection(text: string): string =
  ## What a lock SELECTS: its catalog import pins and provisioning records.
  ## (The rest of a refreshed lock names the project directory itself in its
  ## ``deps`` and so differs between two project directories.)
  lockLine(text, CatalogImportsLockKey) & "\n" &
    lockLine(text, ProvisioningLockKey)

proc withBareMoved(remote: string; body: proc ()) =
  ## Run ``body`` with the shared clone of ``remote`` moved away, then put it
  ## back.
  let bare = sharedCloneOf(clonesRoot, remote)
  let aside = bare & ".aside"
  moveDir(bare, aside)
  try:
    body()
  finally:
    if dirExists(bare): removeDir(bare)
    moveDir(aside, bare)

# ---------------------------------------------------------------------------

suite "e2e_federated_catalog_discovery_from_published_repositories":
  when defined(windows):
    putEnv("PATH", getEnv("SystemRoot", r"C:\Windows") / "System32" & ";" &
      getEnv("PATH"))
  putEnv("REPRO_CACHE_DISABLE", "1")
  fixtureRoot = createTempDir("repro-federated-", "")
  let hermetic = enterHermeticEnvironment(fixtureRoot)
  clonesRoot = hermetic.clonesRoot
  check getEnv("REPRO_WORKSPACE_CLONES") == fixtureRoot / "clones"
  archiveA1 = buildArchive("a1", "federated-tool-from-catalog-a-1")
  archiveA2 = buildArchive("a2", "federated-tool-from-catalog-a-2")
  archiveB1 = buildArchive("b1", "federated-tool-from-catalog-b-1")
  # The production source is installed by default.
  check provisioningCatalogSourceInstalled()
  let main = newWorld("main")

  test "explicit re-selection pins every declared catalog at an exact revision read from its published artifacts":
    let dir = main.newProject()
    check refresh(dir) == 0
    let pins = pinsOf(dir)
    check pins.mapIt(it.repo) == @[RepoA, RepoB, RepoPackages]
    let byRepo = proc (r: string): LockedCatalogImport =
      pins.filterIt(it.repo == r)[0]
    check byRepo(RepoPackages).revision == main.revPackages
    check byRepo(RepoPackages).gitRef == "main"
    check byRepo(RepoA).revision == main.revA1
    check byRepo(RepoA).gitRef == "main"
    check byRepo(RepoB).revision == main.revB1
    check byRepo(RepoB).gitRef == ""
    check byRepo(RepoA).remote == main.a.remote
    # The pinned identity is recomputed from the published artifacts -- the
    # same value catalogArtifactIdentity gives the artifacts the publisher
    # wrote.
    check byRepo(RepoPackages).interfaceArtifact ==
      identityOfPublished(main.publishedPackages)
    check byRepo(RepoA).interfaceArtifact == identityOfPublished(
      main.publishedA1)
    # The publisher GENERATED them from the committed providers: catalog A's
    # provider was compiled and run to publish, the canonical interface it
    # published is the one this process computes for the same package, and
    # the record it published is the one the consumer imports.
    check publisherRanProviderA
    check toolFingerprint == canonicalPackageInterfaceFingerprint(
      findPackage(ToolPackage), registeredPackages())
    check interfaceContributionRecordDigest(recordOfPublished(
      main.publishedA1)) == interfaceContributionRecordDigest(
        recordOf(main.defA1))
    # The policy selection is locked, with the catalog coordinate it was read
    # at.
    let records = recordsOf(dir)
    check records.len == 1
    let r = records[0]
    check r.contributor == ContributorA
    check r.selectedBy == lsrCuratorPolicy
    check r.catalogWorkspace == RepoA
    check r.catalogRemote == main.a.remote
    check r.catalogRevision == main.revA1
    check r.catalogInterfaceArtifact == byRepo(RepoA).interfaceArtifact
    check r.realizationLockIdentity == "sha256:" & archiveA1.sha256
    # Where the provider identity comes from: the root tree of the pinned
    # commit, read out of the shared clone -- recomputed here from git
    # independently of discovery.
    let bareA = sharedCloneOf(clonesRoot, main.a.remote)
    let provider = catalogProviderIdentity("sha1",
      rootTreeOf(bareA, main.revA1))
    let fp = contributionFingerprint(ContributionIdentity(
      contribution: recordOf(main.defA1), providerIdentity: provider),
      noContributionResolver)
    check fp.dependenciesFullyResolved
    check r.contributionFingerprint == fp.hex
    # A lock written this way reads back canonically.
    check serializeLockedDependencies(lockOf(dir)) == readFile(dir / "repro.lock")
    # A catalog that offers nothing to select is pinned all the same.
    let only = main.newProject(@[main.specs()[0]], policy = @[])
    check refresh(only) == 0
    check pinsOf(only).mapIt(it.repo) == @[RepoPackages]
    check recordsOf(only).len == 0

  test "a build verifies the committed lock against the published catalogs and realizes the locked contributor":
    let dir = main.newProject()
    check refresh(dir) == 0
    let defs = @[main.defA1, main.defB1]
    let pins = buildPins(dir, defs)
    check pins.len == 1
    check pins[0].contributor == ContributorA
    check pins[0].contributionFingerprint ==
      recordsOf(dir)[0].contributionFingerprint
    check pins[0].realizationLockIdentity == "sha256:" & archiveA1.sha256
    check buildPins(dir, defs) == pins
    check realizedMarker(dir, defs, fixtureRoot / "out-build") ==
      archiveA1.marker
    # A consumer artifact built from metadata the published catalog does not
    # carry is refused by the engine, not realized.
    var stale = main.defA1
    stale.tarballProvisioning[0].url = "https://example.invalid/stale.tar.gz"
    let artifact = consumerArtifact(@[stale, main.defB1], dir)
    var engine = ""
    try:
      discard warmResolveAndWriteIdentity(artifact, fixtureRoot / "out-stale",
        tpmTarball, pins = buildProvisioningPins(artifact, dir))
    except CatchableError as err:
      engine = err.msg
    check "the artifact was not built from the contribution the selection " &
      "verified" in engine

  test "branch tips move and the build stays pinned; re-selection moves the pins and the diff explains why":
    let w = newWorld("tips")
    let dir = w.newProject()
    check refresh(dir) == 0
    let oldLock = fixtureRoot / "tips-old.lock"
    copyFile(dir / "repro.lock", oldLock)
    let defs1 = @[w.defA1, w.defB1]
    let pinsBefore = buildPins(dir, defs1)
    check realizedMarker(dir, defs1, fixtureRoot / "out-tips") ==
      archiveA1.marker
    # A publishes A2 on main; the shared clone is synced.
    let defA2 = contributionDef(ContributorA, archiveA2)
    let revA2 = w.a.publishRevision(providerSourceA(archiveA2),
      "publish A2").revision
    forgetMarkers()
    discard w.a.syncSharedClone(clonesRoot)
    check revA2 != w.revA1
    # The build reads the PINNED revision: identical pins, A1 realized.
    check buildPins(dir, defs1) == pinsBefore
    check realizedMarker(dir, defs1, fixtureRoot / "out-tips") ==
      archiveA1.marker
    # Explicit re-selection re-pins A at main's new tip and re-locks it.
    let text = readFile(dir / "repro.lock")
    let outcome = reselectCommittedProvisioning(dir, dir / "repro.lock", true,
      text, text, Host, Host)
    check outcome.reselected
    check ("catalog import \"" & RepoA & "\": revision " & w.revA1 & " -> " &
      revA2) in outcome.report
    check "contribution changed (realization-only" in outcome.report
    check refresh(dir) == 0
    check pinsOf(dir).filterIt(it.repo == RepoA)[0].revision == revA2
    let r = recordsOf(dir)[0]
    check r.catalogRevision == revA2
    check r.realizationLockIdentity == "sha256:" & archiveA2.sha256
    let defs2 = @[defA2, w.defB1]
    check realizedMarker(dir, defs2, fixtureRoot / "out-tips") ==
      archiveA2.marker
    # repro lock diff: the evidence is read out of the published catalogs at
    # each record's OWN revision, so the cause is named field by field.
    let diff = lockDiffReport(oldLock, dir / "repro.lock")
    check diff.rc == 1
    check "contribution changed (realization-only" in diff.text
    check "cause (from the two contribution identities" in diff.text
    check "provider identity: " in diff.text
    check "field sha256: \"" & archiveA1.sha256 & "\" -> \"" &
      archiveA2.sha256 & "\"" in diff.text
    check "catalog revision changed: \"" & w.revA1 & "\" -> \"" & revA2 &
      "\"" in diff.text
    check "not determinable" notin diff.text
    # With the A2 commit gone from the store, the same diff cannot be
    # explained -- and says so rather than guessing.
    withBareMoved(w.a.remote, proc () =
      let blind = lockDiffReport(oldLock, dir / "repro.lock")
      check blind.rc == 1
      check "not determinable from the records" in blind.text)

  test "the declaration's order is not an input":
    let w = newWorld("order")
    let base = w.specs()
    var texts: seq[string] = @[]
    var perm = @[0, 1, 2]
    while true:
      for policyFirst in [false, true]:
        let dir = w.newProject(perm.mapIt(base[it]))
        if policyFirst:
          # Move the [[policy]] table above the imports.
          let text = readFile(dir / "repro-catalogs.toml")
          let at = text.find("\n[[policy]]")
          writeFile(dir / "repro-catalogs.toml",
            "schema = \"reprobuild.catalog-imports.v1\"\n" & text[at .. ^1] &
            text["schema = \"reprobuild.catalog-imports.v1\"\n".len ..< at])
        check refresh(dir) == 0
        texts.add(selection(readFile(dir / "repro.lock")))
      if not perm.nextPermutation(): break
    check texts.len == 12
    check texts.deduplicate().len == 1
    check texts[0].len > 200

  test "projects without catalog imports behave exactly as before":
    let workspaceRoot = currentSourcePath().parentDir.parentDir.parentDir.
      parentDir
    var locks: seq[string] = @[]
    if fileExists(workspaceRoot / "repro.lock"):
      locks.add(workspaceRoot / "repro.lock")
    for kind, path in walkDir(workspaceRoot):
      if kind in {pcDir, pcLinkToDir} and fileExists(path / "repro.lock"):
        locks.add(path / "repro.lock")
    locks.sort(cmp)
    check locks.anyIt(it.endsWith("reprobuild" / "repro.lock"))
    echo "  workspace locks examined: ", locks.len
    check provisioningCatalogSourceInstalled()
    for path in locks:
      let text = readFile(path)
      check CatalogImportsLockKey notin text
      check not lockDeclaresCatalogImports(text)
      check not fileExists(path.parentDir / CatalogImportsFileName)
      # The build path consults nothing and pins nothing.
      check buildProvisioningPins(ProjectInterfaceArtifact(), path.parentDir,
        path).len == 0
      # A refresh carries nothing, and a diff sees nothing.
      check withProvisioningCarriedForward(parseLockedDependencies(text),
        text).catalogImportPinCount == 0
      check lockDiffReport(path, path).rc == 0
      # Explicit re-selection refuses (no declaration), writing nothing --
      # the outcome it had with no catalog source at all.
      let outcome = reselectCommittedProvisioning(path.parentDir, path, true,
        text, text, Host, Host)
      check not outcome.reselected
      check outcome.document == ""
      check "declares no catalog imports" in outcome.refusals.join(" ")
      check readFile(path) == text

  test "working trees and sibling directories are never read":
    let w = newWorld("trees")
    let ws = fixtureRoot / "trees-ws"
    createDir(ws)
    let baseline = w.newProject(parent = ws)
    check refresh(baseline) == 0
    let baselineLock = readFile(baseline / "repro.lock")
    let defs = @[w.defA1, w.defB1]
    let baselinePins = buildPins(baseline, defs)
    # A checkout named exactly like each catalog, next to the consumer, at
    # ANOTHER commit and DIRTY: its working tree offers B's record under A's
    # name, and its provider source is edited.
    for repo in [w.a, w.packages]:
      let sibling = ws / repo.name
      discard git(["clone", "-q", repo.upstream, sibling])
      writeFile(sibling / "published-interfaces" / "catalog.rbsz",
        "not an artifact")
      writeFile(sibling / "repro.nim", "{.error: \"never compiled\".}\n")
      discard git(["checkout", "-q", "-b", "other"], sibling)
      writeFile(sibling / "published-interfaces" / "extra.rbsz", "dirty")
    let dir = w.newProject(parent = ws)
    check refresh(dir) == 0
    check selection(readFile(dir / "repro.lock")) == selection(baselineLock)
    check buildPins(dir, defs) == baselinePins
    let dirLock = readFile(dir / "repro.lock")
    # Without the shared clone, discovery refuses -- the sibling checkout is
    # never used instead.
    withBareMoved(w.a.remote, proc () =
      let built = buildRefusal(dir, defs)
      check "there is no shared clone of catalog remote " & w.a.remote in built
      check "never a working checkout, a sibling directory" in built
      let reselect = reselectRefusal(dir)
      check "there is no shared clone of catalog remote " & w.a.remote in
        reselect
      check refresh(dir) == 1
      check readFile(dir / "repro.lock") == dirLock)

  test "pins and declarations that do not name one exact commit refuse":
    let w = newWorld("exact")
    let dir = w.newProject()
    check refresh(dir) == 0
    let defs = @[w.defA1, w.defB1]
    let good = readFile(dir / "repro.lock")
    let goodDecl = readFile(dir / "repro-catalogs.toml")
    # A branch name, an abbreviated id, where the declaration needs a commit.
    for bad in ["main", w.revB1[0 ..< 12]]:
      writeFile(dir / "repro-catalogs.toml",
        goodDecl.replace("commit = \"" & w.revB1 & "\"", "commit = \"" & bad & "\""))
      check "is not a full-width commit id" in buildRefusal(dir, defs)
      check "is not a full-width commit id" in reselectRefusal(dir)
      check refresh(dir) == 1
      check readFile(dir / "repro.lock") == good
    writeFile(dir / "repro-catalogs.toml", goodDecl)
    check buildRefusal(dir, defs) == ""
    # A branch name hand-edited into the lock where a revision is required.
    let pinLine = lockLine(good, CatalogImportsLockKey)
    writeFile(dir / "repro.lock", good.replace(pinLine,
      pinLine.replace("revision = \"" & w.revB1 & "\"", "revision = \"main\"")))
    check "cannot be read" in buildRefusal(dir, defs)
    # A full-width revision the shared clone does not have: refused with the
    # fetch remedy; never another revision.
    let absent = repeat('7', 40)
    writeFile(dir / "repro.lock", good.replace(pinLine,
      pinLine.replace(w.revA1, absent)))
    let missing = buildRefusal(dir, defs)
    check "the pinned commit is not available in the shared clone" in missing
    check "cannot be read from" in missing
    check "fetch origin " & absent in missing
    # A hand-edited interface-artifact pin.
    writeFile(dir / "repro.lock", good)
    let artifactA = pinsOf(dir).filterIt(it.repo == RepoA)[0].interfaceArtifact
    writeFile(dir / "repro.lock", good.replace(artifactA, repeat('9', 64)))
    let forgedPin = buildRefusal(dir, defs)
    check "publishes interface artifact " & artifactA & ", but the " &
      "committed lock pins " & repeat('9', 64) in forgedPin
    # A declared identity is an assertion the re-selection checks.
    writeFile(dir / "repro.lock", good)
    var specs = w.specs()
    specs[1].interfaceArtifact = repeat('9', 64)
    writeDeclaration(dir, specs, @[(ToolPackage, ContributorA)])
    check "repro-catalogs.toml asserts " & repeat('9', 64) in reselectRefusal(dir)
    check "asserts interface artifact " & repeat('9', 64) in buildRefusal(dir, defs)
    specs[1].interfaceArtifact = artifactA
    writeDeclaration(dir, specs, @[(ToolPackage, ContributorA)])
    check reselectRefusal(dir) == ""
    check buildRefusal(dir, defs) == ""
    # The declaration and the lock must agree: a ref turned into a commit, an
    # undeclared pin, a declared import without a pin.
    specs = w.specs()
    specs[1].gitRef = ""
    specs[1].commit = w.revA1
    writeDeclaration(dir, specs, @[(ToolPackage, ContributorA)])
    check "disagrees with repro-catalogs.toml" in buildRefusal(dir, defs)
    writeDeclaration(dir, w.specs()[0 .. 1], @[(ToolPackage, ContributorA)])
    check "which repro-catalogs.toml does not declare" in buildRefusal(dir, defs)
    # A pin for another ref, or for another remote, than the declaration
    # names.
    writeDeclaration(dir, w.specs(), @[(ToolPackage, ContributorA)])
    writeFile(dir / "repro.lock", good.replace(pinLine,
      pinLine.replace("ref = \"main\"", "ref = \"release\"")))
    check "the lock pinned ref \"release\"" in buildRefusal(dir, defs)
    let elsewhere = remoteOf("exact", "elsewhere")
    writeFile(dir / "repro.lock", good.replace(pinLine,
      pinLine.replace("\"" & w.a.remote & "\"", "\"" & elsewhere & "\"")))
    check "remote \"" & elsewhere & "\" is declared as \"" & w.a.remote & "\"" in
      buildRefusal(dir, defs)
    # Pins under a key spelling the reader skips are refused, not read as
    # "no pins" -- by a build and by re-selection.
    let pinsRhs = pinLine[pinLine.find('=') + 1 .. ^1].strip()
    writeFile(dir / "repro.lock", good & "CATALOG_IMPORTS = " & pinsRhs & "\n")
    check "names `catalog_imports` in a form the lock reader does not read" in
      buildRefusal(dir, defs)
    check "names `catalog_imports` in a form the lock reader does not read" in
      reselectRefusal(dir)
    writeFile(dir / "repro.lock", good)
    writeDeclaration(dir, w.specs(), @[(ToolPackage, ContributorA)])
    writeFile(dir / "repro.lock", good.replace(pinLine & "\n", ""))
    check "is declared but the committed lock pins no revision for it" in
      buildRefusal(dir, defs)
    # An incumbent whose pins cannot be read is refused by re-selection, not
    # replaced.
    let pinsOnly = w.newProject(@[w.specs()[0]], policy = @[])
    check refresh(pinsOnly) == 0
    let pinsOnlyText = readFile(pinsOnly / "repro.lock")
    let onlyLine = lockLine(pinsOnlyText, CatalogImportsLockKey)
    writeFile(pinsOnly / "repro.lock", pinsOnlyText.replace(onlyLine,
      onlyLine.replace("revision = \"" & w.revPackages & "\"",
        "revision = \"main\"")))
    check "pins that cannot be read" in reselectRefusal(pinsOnly)
    # No declaration at all, while the lock has provisioning records.
    writeFile(dir / "repro.lock", good)
    removeFile(dir / "repro-catalogs.toml")
    check "declares no catalog imports" in buildRefusal(dir, defs)
    writeFile(dir / "repro-catalogs.toml", goodDecl)
    check buildRefusal(dir, defs) == ""

  test "forged and missing artifacts refuse":
    let w = newWorld("forged")
    proc pinnedAt(commit: string): string =
      ## A project importing catalog A at ``commit`` exactly.
      var specs = w.specs()
      specs[1].gitRef = ""
      specs[1].commit = commit
      result = w.newProject(specs)
    # Garbage bytes as an artifact.
    let garbage = w.a.publishCommit(@[], "garbage",
      branch = "garbage", extraFiles = @[("published-interfaces/catalog.rbsz",
        "RBSZ but not an artifact")])
    discard w.a.syncSharedClone(clonesRoot)
    check "is not a readable interface artifact" in reselectRefusal(
      pinnedAt(garbage))
    # An artifact whose stored fingerprint was forged after the fact: the
    # contribution edited, the fingerprint left alone.
    var forged = catalogArtifact(RepoA, @[recordOf(w.defA1)])
    forged.projectInterface.provisioningContributions[0].
      tarballProvisioning[0].url = "https://example.invalid/forged.tar.gz"
    let forgedRev = w.a.publishCommit(@[("catalog.rbsz", forged)], "forged",
      branch = "forged")
    discard w.a.syncSharedClone(clonesRoot)
    check "interface fingerprint mismatch" in reselectRefusal(
      pinnedAt(forgedRev))
    # A commit that publishes nothing.
    let nothing = w.a.publishCommit(@[], "nothing", branch = "nothing")
    discard w.a.syncSharedClone(clonesRoot)
    check "publishes no interface artifacts" in reselectRefusal(
      pinnedAt(nothing))
    # Imported and developInterface records are not a publication.
    var imported = recordOf(w.defA1)
    imported.imported = true
    var develop = recordOf(w.defA1)
    develop.developInterface = true
    for (record, expected) in [(imported, "IMPORTED"),
                               (develop, "developInterface")]:
      let rev = w.a.publishCommit(@[("catalog.rbsz",
        catalogArtifact(RepoA, @[record]))], expected, branch = expected)
      discard w.a.syncSharedClone(clonesRoot)
      check expected in reselectRefusal(pinnedAt(rev))
    # A substituted object in the shared clone: git returns the forged bytes
    # (measured below as the control), discovery re-hashes and refuses.
    let looseRoot = fixtureRoot / "clones-loose"
    let looseBare = w.a.syncSharedClone(looseRoot, loose = true)
    let blob = blobIdAt(looseBare, w.revA1,
      "published-interfaces/fedCatalogA.rbsz")
    let other = writeBlob(looseBare, "a different artifact")
    let blobFile = looseBare / "objects" / blob[0 .. 1] / blob[2 .. ^1]
    check fileExists(blobFile)
    setFilePermissions(blobFile, {fpUserRead, fpUserWrite})
    copyFile(looseBare / "objects" / other[0 .. 1] / other[2 .. ^1], blobFile)
    check git(["--git-dir=" & looseBare, "cat-file", "blob", blob]).strip() ==
      "a different artifact"
    let dir = w.newProject()
    putEnv("REPRO_WORKSPACE_CLONES", looseRoot)
    try:
      for repo in [w.packages, w.b]:
        discard repo.syncSharedClone(looseRoot)
      let substituted = reselectRefusal(dir)
      check "hashes to " & gitObjectId("blob", "a different artifact") in
        substituted
      check "the object store is corrupt or was tampered with" in substituted
    finally:
      putEnv("REPRO_WORKSPACE_CLONES", clonesRoot)
    # A SHA-256 shared clone is refused, not read.
    let shaRoot = fixtureRoot / "clones-sha256"
    let shaBare = sharedCloneOf(shaRoot, w.a.remote)
    createDir(shaBare)
    discard git(["init", "-q", "--bare", "--object-format=sha256", shaBare])
    discard git(["--git-dir=" & shaBare, "config", "remote.origin.url",
      w.a.remote])
    putEnv("REPRO_WORKSPACE_CLONES", shaRoot)
    try:
      for repo in [w.packages, w.b]:
        discard repo.syncSharedClone(shaRoot)
      check "uses the sha256 object format" in reselectRefusal(w.newProject())
    finally:
      putEnv("REPRO_WORKSPACE_CLONES", clonesRoot)

  test "a publication holds regular artifact files and nothing else":
    let w = newWorld("shapes")
    let bareA = sharedCloneOf(clonesRoot, w.a.remote)
    let artifactBlob = blobIdAt(bareA, w.revA1,
      "published-interfaces/fedCatalogA.rbsz")
    let rootEntries = proc (pub: TreeEntrySpec): string =
      writeTree(bareA, [pub])
    proc commitWith(pubEntries: seq[TreeEntrySpec]; asLink = false): string =
      if asLink:
        let link = writeBlob(bareA, "elsewhere")
        return commitTree(bareA, rootEntries(TreeEntrySpec(mode: "120000",
          kind: "blob", oid: link, name: "published-interfaces")), "link")
      let pubTree = writeTree(bareA, pubEntries)
      commitTree(bareA, rootEntries(TreeEntrySpec(mode: "040000", kind: "tree",
        oid: pubTree, name: "published-interfaces")), "shape")
    let ok = TreeEntrySpec(mode: "100644", kind: "blob", oid: artifactBlob,
      name: "catalog.rbsz")
    let linkBlob = writeBlob(bareA, "catalog.rbsz")
    let subTree = writeTree(bareA, [ok])
    let shapes = @[
      (commitWith(@[ok, TreeEntrySpec(mode: "120000", kind: "blob",
        oid: linkBlob, name: "link.rbsz")]), "link.rbsz` (mode 120000)"),
      (commitWith(@[ok, TreeEntrySpec(mode: "040000", kind: "tree",
        oid: subTree, name: "nested")]), "nested` (mode 40000)"),
      (commitWith(@[ok, TreeEntrySpec(mode: "100644", kind: "blob",
        oid: artifactBlob, name: "notes.txt")]), "notes.txt` (mode 100644)"),
      (commitWith(@[ok, TreeEntrySpec(mode: "160000", kind: "commit",
        oid: w.revB1, name: "sub.rbsz")]), "sub.rbsz` (mode 160000)"),
      (commitWith(@[]), "is empty"),
      (commitWith(@[], asLink = true), "is not a directory")]
    # Two entries of one name -- which git never writes, but a crafted tree
    # can -- are not resolved by picking one.
    let pubOk = writeTree(bareA, [ok])
    let pubEntry = TreeEntrySpec(mode: "040000", kind: "tree", oid: pubOk,
      name: "published-interfaces")
    let dupRoot = commitTree(bareA, writeRawTree(bareA, [pubEntry, pubEntry]),
      "dup root")
    var dupPubEntry = pubEntry
    dupPubEntry.oid = writeRawTree(bareA, [ok, ok])
    let dupPub = commitTree(bareA, writeTree(bareA, [dupPubEntry]), "dup pub")
    let duplicates = @[(dupRoot, "names `published-interfaces` 2 times"),
      (dupPub, "`published-interfaces/catalog.rbsz` appears more than once")]
    # Names git would not write, a tree that does not parse, and a commit
    # that names no tree -- each hashes correctly, so only the reader's own
    # checks stand between them and the composition.
    proc pubCommit(pubTree, message: string): string =
      var e = pubEntry
      e.oid = pubTree
      commitTree(bareA, writeTree(bareA, [e]), message)
    var slashed = ok
    slashed.name = "a/b.rbsz"
    var suffixOnly = ok
    suffixOnly.name = ".rbsz"
    let crafted = @[
      (pubCommit(writeRawTree(bareA, [slashed]), "slash"),
        "`published-interfaces/a/b.rbsz` (mode 100644)"),
      (pubCommit(writeRawTree(bareA, [suffixOnly]), "suffix"),
        "`published-interfaces/.rbsz` (mode 100644)"),
      (pubCommit(writeRawObject(bareA, "tree",
        "100644 catalog.rbsz\0\x01\x02\x03"), "malformed"), "is malformed"),
      # One byte short of an object id: the bound that once let the
      # reader index past the end of the tree (an IndexDefect, which no
      # caller's ``except CatchableError`` turns into a refusal).
      (pubCommit(writeRawObject(bareA, "tree",
        "100644 catalog.rbsz\0" & repeat('\x01', 19)), "short id"),
        "is malformed"),
      (writeRawObject(bareA, "commit", "parent " & w.revA1 &
        "\n\nno tree here\n"), "does not start with its tree"),
      (writeRawObject(bareA, "commit", "tree " & repeat('z', 40) &
        "\n\nbad tree\n"), "the commit names a malformed tree")]
    # The control: the same plumbing with only the artifact reads.
    let control = commitWith(@[ok])
    for (rev, expected) in shapes & duplicates & crafted & @[(control, "")]:
      var specs = w.specs()
      specs[1].gitRef = ""
      specs[1].commit = rev
      let dir = w.newProject(specs)
      let refusal = reselectRefusal(dir)
      if expected.len == 0:
        check refusal == ""
      else:
        check expected in refusal
        if expected notin refusal:
          echo "    expected ", expected.escape(), " in ", refusal.escape()

  test "two catalogs claiming one coordinate refuse":
    let w = newWorld("claims")
    let defs = @[w.defA1, w.defB1]
    # One repo imported twice; one remote in two spellings.
    var specs = w.specs()
    specs.add(ImportSpec(repo: RepoA, remote: remoteOf("claims", "other"),
      gitRef: "main"))
    check "imported twice" in reselectRefusal(w.newProject(specs))
    for spelling in [w.a.remote & ".git", w.a.remote & "/",
                     "git@example.invalid:claims/" & RepoA]:
      specs = w.specs()
      specs.add(ImportSpec(repo: "fed-catalog-a-again", remote: spelling,
        gitRef: "main"))
      check "name one remote" in reselectRefusal(w.newProject(specs))
    # A shared clone that belongs to another remote: refused, never read.
    let bareA = sharedCloneOf(clonesRoot, w.a.remote)
    discard git(["--git-dir=" & bareA, "config", "remote.origin.url",
      w.b.remote])
    check ("is a clone of " & w.b.remote & ", not of catalog remote " &
      w.a.remote) in reselectRefusal(w.newProject())
    discard git(["--git-dir=" & bareA, "config", "remote.origin.url",
      w.a.remote])
    # Two remotes whose URL slugs collide share one directory; the second
    # is refused against the first one's store.
    let colliding = remoteOf("claims", "fed:catalog-a")
    let collidingTwin = remoteOf("claims", "fed_catalog-a")
    check sharedCloneOf(clonesRoot, colliding) ==
      sharedCloneOf(clonesRoot, collidingTwin)
    let collide = initCatalogRepo(fixtureRoot / "claims-collide", "x",
      colliding)
    discard collide.publishRevision(providerSourceA(archiveA1), "x")
    forgetMarkers()
    discard collide.syncSharedClone(clonesRoot)
    specs = w.specs()
    specs[1].remote = collidingTwin
    check ("is a clone of " & colliding) in reselectRefusal(w.newProject(specs))
    # A junction at A's slot: to A's real store (moved elsewhere) it is
    # read exactly as before; to B's store it is refused.
    let baseline = w.newProject()
    check refresh(baseline) == 0
    let baselineLock = readFile(baseline / "repro.lock")
    let moved = fixtureRoot / "claims-moved-bare.git"
    moveDir(bareA, moved)
    makeJunction(bareA, moved)
    try:
      let dir = w.newProject()
      check refresh(dir) == 0
      check selection(readFile(dir / "repro.lock")) == selection(baselineLock)
      check buildPins(dir, defs) == buildPins(baseline, defs)
    finally:
      removeLink(bareA)
    makeJunction(bareA, sharedCloneOf(clonesRoot, w.b.remote))
    try:
      check ("is a clone of " & w.b.remote) in reselectRefusal(w.newProject())
    finally:
      removeLink(bareA)
      moveDir(moved, bareA)
    # A second catalog claiming the first one's contributor id is not a
    # silent substitute: both are offered, and the policy cannot choose.
    let impostor = w.b.publishRevision(providerSourceB(ContributorA,
      archiveB1), "impostor", branch = "impostor").revision
    discard w.b.syncSharedClone(clonesRoot)
    specs = w.specs()
    specs[2].commit = impostor
    let ambiguous = reselectRefusal(w.newProject(specs))
    check "unresolved-contribution-ambiguity" in ambiguous
    check ContributorA in ambiguous

  test "the environment, replace refs, HEAD and ref ambiguity cannot redirect a read":
    let w = newWorld("redirect")
    let baseline = w.newProject()
    check refresh(baseline) == 0
    let baselineLock = readFile(baseline / "repro.lock")
    let bareA = sharedCloneOf(clonesRoot, w.a.remote)
    let bareB = sharedCloneOf(clonesRoot, w.b.remote)
    # Every repository-local git variable pointed at B's store.
    for (name, value) in [("GIT_DIR", bareB),
                          ("GIT_OBJECT_DIRECTORY", bareB / "objects"),
                          ("GIT_ALTERNATE_OBJECT_DIRECTORIES", bareB / "objects"),
                          ("GIT_NAMESPACE", "elsewhere"),
                          ("GIT_REPLACE_REF_BASE", "refs/heads/")]:
      putEnv(name, value)
    try:
      let dir = w.newProject()
      check refresh(dir) == 0
      check selection(readFile(dir / "repro.lock")) == selection(baselineLock)
    finally:
      for name in ["GIT_DIR", "GIT_OBJECT_DIRECTORY",
                   "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
                   "GIT_REPLACE_REF_BASE"]:
        delEnv(name)
    # A replace ref substituting A1 with a commit publishing B's record.
    let bRecord = catalogArtifact(RepoA, @[recordOf(contributionDef(
      ContributorA, archiveB1))])
    var bytes = ""
    for b in encodeProjectInterfaceArtifact(bRecord): bytes.add(char(b))
    let fakeBlob = writeBlob(bareA, bytes)
    let fakePub = writeTree(bareA, [TreeEntrySpec(mode: "100644",
      kind: "blob", oid: fakeBlob, name: "catalog.rbsz")])
    let fakeRoot = writeTree(bareA, [TreeEntrySpec(mode: "040000",
      kind: "tree", oid: fakePub, name: "published-interfaces")])
    let fake = commitTree(bareA, fakeRoot, "replacement")
    discard git(["--git-dir=" & bareA, "replace", w.revA1, fake])
    # The control: an ordinary read now sees the replacement.
    check ("tree " & fakeRoot) in git(["--git-dir=" & bareA, "cat-file",
      "commit", w.revA1])
    let pinned = w.newProject()
    writeFile(pinned / "repro.lock", baselineLock)
    check buildPins(pinned, @[w.defA1, w.defB1]).len == 1
    let afterReplace = w.newProject()
    check refresh(afterReplace) == 0
    check selection(readFile(afterReplace / "repro.lock")) ==
      selection(baselineLock)
    discard git(["--git-dir=" & bareA, "replace", "-d", w.revA1])
    # HEAD moved to another branch: a ref is resolved by name, never HEAD.
    let side = w.a.publishRevision(providerSourceA(archiveA2), "side",
      branch = "side").revision
    forgetMarkers()
    discard w.a.syncSharedClone(clonesRoot)
    discard git(["--git-dir=" & bareA, "symbolic-ref", "HEAD",
      "refs/heads/side"])
    let headMoved = w.newProject()
    check refresh(headMoved) == 0
    check selection(readFile(headMoved / "repro.lock")) ==
      selection(baselineLock)
    # A branch and a tag of one name, naming different commits: refused.
    discard git(["--git-dir=" & bareA, "tag", "main", side])
    check "both a branch" in reselectRefusal(w.newProject())
    # A tag alone (annotated) resolves to its commit.
    var specs = w.specs()
    specs[1].gitRef = "release"
    discard git(["--git-dir=" & bareA, "tag", "-a", "-m", "release", "release",
      w.revA1])
    let tagged = w.newProject(specs)
    check refresh(tagged) == 0
    check pinsOf(tagged).filterIt(it.repo == RepoA)[0].revision == w.revA1
    check pinsOf(tagged).filterIt(it.repo == RepoA)[0].gitRef == "release"
    # A ref that does not exist.
    specs[1].gitRef = "no-such-branch"
    check "there is no branch or tag \"no-such-branch\"" in
      reselectRefusal(w.newProject(specs))

  test "the store and its refs are checked, not trusted":
    let w = newWorld("store")
    let bareA = sharedCloneOf(clonesRoot, w.a.remote)
    # A store with no origin: nothing shows it is a clone of the remote.
    discard git(["--git-dir=" & bareA, "config", "--unset",
      "remote.origin.url"])
    check "has no remote.origin.url" in reselectRefusal(w.newProject())
    discard git(["--git-dir=" & bareA, "config", "remote.origin.url",
      w.a.remote])
    check reselectRefusal(w.newProject()) == ""
    # Verification round (2026-10-03): what the store SAYS it is a clone of
    # must be one URL, of one host whoever parses it, and the URL a fetch
    # would really use. Each of these was accepted before: an origin whose
    # identity reads as the remote's while curl ends its authority at '?' /
    # '#' (so fetches from the host before it); a multi-valued origin
    # (``config --get`` answers with the LAST value, a fetch uses the
    # first); and a store-local ``url.<base>.insteadOf`` redirect.
    let host = w.a.remote["https://".len ..< w.a.remote.find('/', "https://".len)]
    for (origins, expected) in [
        (@["https://evil.invalid?@" & w.a.remote["https://".len .. ^1]],
          "depend on who parses it"),
        (@["https://evil.invalid#@" & w.a.remote["https://".len .. ^1]],
          "depend on who parses it"),
        (@["https://evil.invalid/x", w.a.remote], "names 2 origin URL(s)")]:
      discard git(["--git-dir=" & bareA, "config", "--unset-all",
        "remote.origin.url"])
      for o in origins:
        discard git(["--git-dir=" & bareA, "config", "--add",
          "remote.origin.url", o])
      check expected in reselectRefusal(w.newProject())
    discard git(["--git-dir=" & bareA, "config", "--unset-all",
      "remote.origin.url"])
    discard git(["--git-dir=" & bareA, "config", "remote.origin.url",
      w.a.remote])
    discard git(["--git-dir=" & bareA, "config",
      "url.https://evil.invalid/.insteadOf", "https://" & host & "/"])
    check "fetches (after url.*.insteadOf) from https://evil.invalid/" in
      reselectRefusal(w.newProject())
    discard git(["--git-dir=" & bareA, "config", "--remove-section",
      "url.https://evil.invalid/"])
    check reselectRefusal(w.newProject()) == ""
    # A symbolic ref answers with its target's commit (HEAD's, for one that
    # points at HEAD): refused, so a ref is never resolved through HEAD.
    discard git(["--git-dir=" & bareA, "symbolic-ref", "refs/heads/follow",
      "refs/heads/main"])
    block:
      var symSpecs = w.specs()
      symSpecs[1].gitRef = "follow"
      check "is a symbolic ref" in reselectRefusal(w.newProject(symSpecs))
    # A ref is matched by its whole name: branch ``release/x`` is not ref
    # ``release`` (a ``for-each-ref`` pattern also matches below it).
    discard git(["--git-dir=" & bareA, "branch", "release/x", w.revA1])
    var specs = w.specs()
    specs[1].gitRef = "release"
    check "there is no branch or tag \"release\"" in
      reselectRefusal(w.newProject(specs))
    # A ref naming something other than a commit refuses.
    let blob = writeBlob(bareA, "not a commit")
    discard git(["--git-dir=" & bareA, "tag", "blobtag", blob])
    specs[1].gitRef = "blobtag"
    check "does not name a commit" in reselectRefusal(w.newProject(specs))
    # A partial (blobless) shared clone whose promisor COULD serve the
    # missing artifact blob: discovery never fetches, so it refuses; the
    # control afterwards shows an ordinary read would have fetched it.
    let partialRoot = fixtureRoot / "clones-partial"
    for repo in [w.packages, w.a]:
      discard repo.syncSharedClone(partialRoot)
    let partialBare = sharedCloneOf(partialRoot, w.b.remote)
    discard git(["-C", w.b.upstream, "config", "uploadpack.allowFilter", "true"])
    let publisherUrl = "file:///" & w.b.upstream.replace('\\', '/')
    discard git(["clone", "-q", "--bare", "--filter=blob:none", "--no-local",
      publisherUrl, partialBare])
    for (key, value) in [("remote.publisher.url", publisherUrl),
                         ("remote.publisher.promisor", "true"),
                         ("remote.publisher.partialclonefilter", "blob:none"),
                         ("extensions.partialclone", "publisher"),
                         ("remote.origin.url", w.b.remote)]:
      discard git(["--git-dir=" & partialBare, "config", key, value])
    for key in ["remote.origin.promisor", "remote.origin.partialclonefilter"]:
      discard git(["--git-dir=" & partialBare, "config", "--unset", key])
    let missingBlob = blobIdAt(partialBare, w.revB1,
      "published-interfaces/fedCatalogB.rbsz")
    putEnv("REPRO_WORKSPACE_CLONES", partialRoot)
    try:
      let partial = reselectRefusal(w.newProject())
      check ("object " & missingBlob & " (blob) cannot be read") in partial
    finally:
      putEnv("REPRO_WORKSPACE_CLONES", clonesRoot)
    check git(["--git-dir=" & partialBare, "cat-file", "-t",
      missingBlob]).strip() == "blob"
    # Called directly, discovery refuses what is not one exact SHA-1 commit,
    # and ref resolution what is not a ref -- whatever its caller checked.
    for (rev, expected) in [
        ("main", "which is not a full-width lower-case commit id"),
        (w.revA1[0 ..< 12], "which is not a full-width lower-case commit id"),
        (repeat('a', 64), "SHA-256 repositories are not supported")]:
      var raised = ""
      try:
        discard discoverCatalogAt(RepoA, w.a.remote, "", rev, fixtureRoot)
      except CatalogDiscoveryError as err:
        raised = err.msg
      check expected in raised
    var refRaised = ""
    try:
      discard resolveCatalogRef(RepoA, w.a.remote, "main..x", fixtureRoot)
    except CatalogDiscoveryError as err:
      refRaised = err.msg
    check "contains '..'" in refRaised

  test "a catalog's provider is never compiled or run":
    # Every case above discovered catalog A, whose provider would have
    # written these markers had it been compiled or run.
    check not fileExists(markerPath("compiled"))
    check not fileExists(markerPath("ran"))
    # And what was selected is the ARTIFACT's record, not what the provider
    # source declares.
    let dir = main.newProject()
    check refresh(dir) == 0
    let pins = buildPins(dir, @[main.defA1, main.defB1])
    check pins[0].contributionRecordDigest ==
      interfaceContributionRecordDigest(recordOf(main.defA1))
    check "provider-says-otherwise" in readFile(main.a.upstream / "repro.nim")
    check not fileExists(markerPath("compiled"))
    check not fileExists(markerPath("ran"))

  hermetic.leave()
removeDir(fixtureRoot)
