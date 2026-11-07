## Test support (not a test): a HERMETIC multi-repository federated-catalog
## fixture whose catalogs are reached only as PUBLISHED COMMITS carrying
## GENERATED interface artifacts -- ReproOS-Campaign-Completion M6
## deliverable 5 (``reprobuild-specs/Federated-Catalog-Imports.md``).
##
## ## What "published" means here
##
## Hermetic means no network, so a catalog cannot be fetched from a real
## remote. What the fixture guarantees instead is everything a consumer can
## observe about a published catalog:
##
##   * **Committed objects only.** Each catalog is a real git repository
##     (``CatalogRepo.upstream``) whose revisions are ordinary commits. The
##     consumer reaches them ONLY through the workspace's shared bare clone
##     of the catalog's logical remote (``shared_clones.sharedBarePath``
##     under ``REPRO_WORKSPACE_CLONES``, the store ``repro ws sync``
##     maintains), whose ``remote.origin.url`` is that remote -- the same
##     store and remote identity production discovery reads. A shared clone
##     is filled by ``git fetch`` of the upstream's refs, which transfers
##     commits and nothing of a working tree; discovery reads it by object id
##     and re-hashes every object. The upstream's working tree is never read
##     by a consumer (the D5 test makes it differ from the commit and shows
##     nothing changes).
##   * **Generated artifacts.** ``published-interfaces/*.rbsz`` is written by
##     the production publisher (``repro_cli_support/catalog_publication``):
##     the catalog's OWN provider source, committed in the same revision as
##     ``repro.nim``, is compiled and run by the production interface
##     extraction, its source locations made repository-relative, and the
##     result checked as a consumer will check it. No artifact byte of a
##     published revision is written by hand. (Adversarial tests may still
##     craft objects on purpose -- a forged or garbage artifact is not a
##     publication -- and say so where they do.)
##   * **Reproducible.** Commits use a fixed identity and date, archives are
##     built with fixed metadata, and the publisher's output does not depend
##     on where the checkout sits: two constructions of one world in two
##     different roots give byte-identical artifacts, commits and
##     identities (measured by the D5 test, with the memo below bypassed).
##   * **Self-contained.** ``enterHermeticEnvironment`` gives the process an
##     isolated ``HOME`` / ``XDG_CONFIG_HOME`` (empty global git
##     configuration -- read by the fixture's git AND by discovery's git,
##     which inherits ``HOME``), its own ``REPRO_WORKSPACE_CLONES`` and
##     ``REPRO_STORE_ROOT``, and removes every ``GIT_*`` variable; the
##     fixture's own git also runs with ``GIT_CONFIG_NOSYSTEM=1``. No real
##     workspace repository, shared clone store, realization store or
##     ambient git configuration is read. Residual, stated: discovery's git
##     still reads git's SYSTEM configuration (discovery scrubs ``GIT_*``,
##     so ``GIT_CONFIG_NOSYSTEM`` cannot reach it) -- a test-isolation gap,
##     not a false accept: measured at the same non-repository level
##     (global configuration), ambient configuration can only make
##     discovery refuse, never read other objects or accept another store
##     (objects are re-hashed by id; refs and origin are store-local) --
##     and the publisher
##     compiles providers against this reprobuild checkout's libraries with
##     the compiler path its build configuration names.
##
## ## The publisher memo
##
## A real extraction compiles the provider (minutes each on Windows). The
## publisher is deterministic in the provider source text -- the D5 test
## measures exactly that -- so within one process ``publishProvider``
## reuses the files a previous run of the publisher produced for the SAME
## source text, unless ``memo = false``. ``extractionCount`` counts the real
## extractions.

import std/[os, osproc, strutils, tables, times]

import repro_interface_artifacts
import repro_cli_support
import repro_tool_profiles

import ./published_catalog_fixtures

export published_catalog_fixtures

const
  FixtureReproRoot* = currentSourcePath().parentDir.parentDir.parentDir
    ## The reprobuild checkout whose libraries the publisher compiles
    ## providers against.

# ---------------------------------------------------------------------------
# The hermetic environment
# ---------------------------------------------------------------------------

type HermeticEnvironment* = object
  root*: string
  home*: string
  clonesRoot*: string
  storeRoot*: string
  saved: seq[tuple[key, value: string; existed: bool]]

proc setSaved(env: var HermeticEnvironment; key, value: string) =
  env.saved.add((key, getEnv(key), existsEnv(key)))
  putEnv(key, value)

proc enterHermeticEnvironment*(root: string): HermeticEnvironment =
  ## Isolate this process for a federated-catalog world rooted at ``root``
  ## (see the module docstring). ``leave`` restores everything.
  result.root = root
  result.home = root / "home"
  result.clonesRoot = root / "clones"
  result.storeRoot = root / "store"
  createDir(result.home / ".config" / "git")
  writeFile(result.home / ".gitconfig", "")
  createDir(result.clonesRoot)
  var gitVars: seq[string] = @[]
  for key, _ in envPairs():
    if key.toUpperAscii().startsWith("GIT_"):
      gitVars.add(key)
  for key in gitVars:
    result.saved.add((key, getEnv(key), true))
    delEnv(key)
  result.setSaved("HOME", result.home)
  result.setSaved("XDG_CONFIG_HOME", result.home / ".config")
  result.setSaved("REPRO_WORKSPACE_CLONES", result.clonesRoot)
  result.setSaved("REPRO_STORE_ROOT", result.storeRoot)

proc leave*(env: HermeticEnvironment) =
  for i in countdown(env.saved.high, 0):
    let s = env.saved[i]
    if s.existed: putEnv(s.key, s.value)
    else: delEnv(s.key)

# ---------------------------------------------------------------------------
# Deterministic archives
# ---------------------------------------------------------------------------

type FixtureArchive* = object
  url*: string
  sha256*: string
  marker*: string
  path*: string

proc fixtureExecutableRelPath*(stem: string): string =
  when defined(windows): "bin/" & stem & ".cmd" else: "bin/" & stem

proc buildFixtureArchive*(dir, name, marker, topDir, stem: string):
    FixtureArchive =
  ## ``<dir>/<name>.tar.gz`` holding ``<topDir>/bin/<stem>`` that echoes
  ## ``marker``, with fixed timestamps and ownership so the bytes -- and so
  ## the sha256 a provider declares -- are the same on every run.
  let payload = dir / ("payload-" & name)
  let top = payload / topDir
  createDir(top / "bin")
  let tool = top / fixtureExecutableRelPath(stem)
  when defined(windows):
    writeFile(tool, "@echo off\r\necho " & marker & "\r\n")
  else:
    writeFile(tool, "#!/bin/sh\necho " & marker & "\n")
    setFilePermissions(tool, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  let fixed = fromUnix(1790000000)
  for path in [tool, top / "bin", top]:
    setLastModificationTime(path, fixed)
  let archive = dir / (name & ".tar.gz")
  var cmd = ""
  when defined(windows):
    let systemTar = getEnv("SystemRoot", r"C:\Windows") / "System32" /
      "tar.exe"
    let tarExe = if fileExists(systemTar): systemTar else: findExe("tar")
    # bsdtar: ustar, no gzip timestamp, numeric root ownership.
    cmd = quoteShell(tarExe) & " --format ustar --options gzip:!timestamp " &
      "--uid 0 --gid 0 --uname \"\" --gname \"\" -czf " & quoteShell(archive) &
      " -C " & quoteShell(payload) & " " & quoteShell(topDir)
  else:
    # GNU tar (untested in this round: Windows only).
    cmd = "tar --format=ustar --owner=0 --group=0 --numeric-owner " &
      "--mtime=@1790000000 -cf - -C " & quoteShell(payload) & " " &
      quoteShell(topDir) & " | gzip -n > " & quoteShell(archive)
  let res = execCmdEx(cmd)
  doAssert res.exitCode == 0, "tar failed: " & res.output
  FixtureArchive(url: "file://" & archive.replace('\\', '/'),
    sha256: fileSha256Hex(archive).toLowerAscii(), marker: marker,
    path: archive)

# ---------------------------------------------------------------------------
# Provider sources
# ---------------------------------------------------------------------------

proc canonicalToolSource*(packageIdent, executableName: string): string =
  ## A catalog provider that owns the canonical interface of one tool.
  "import repro_project_dsl\n\n" &
  "package " & packageIdent & ":\n" &
  "  executable " & packageIdent & ":\n" &
  "    name " & executableName.escape() & "\n" &
  "    cli:\n" &
  "      subcmd \"run\":\n" &
  "        flag verbose, bool\n"

type TarballContribution* = object
  targetPackage*: string
  targetInterfaceFingerprint*: string
  contributor*: string
  archive*: FixtureArchive
  executablePath*: string
  packageId*: string

proc contributionStatement*(c: TarballContribution): string =
  "provisioningFor " & c.targetPackage.escape() & ":\n" &
  "  interfaceFingerprint " & c.targetInterfaceFingerprint.escape() & "\n" &
  "  contributor " & c.contributor.escape() & "\n" &
  "  tarball url = " & c.archive.url.escape() & ",\n" &
  "    sha256 = " & c.archive.sha256.escape() & ",\n" &
  "    archiveType = \"tar.gz\",\n" &
  "    executablePath = " & c.executablePath.escape() & ",\n" &
  "    stripComponents = 1,\n" &
  "    packageId = " & c.packageId.escape() & ",\n" &
  "    lockIdentity = " & ("sha256:" & c.archive.sha256).escape() & "\n"

proc contributionCatalogSource*(catalogIdent: string;
                                contributions: openArray[TarballContribution];
                                prelude = ""): string =
  ## A catalog provider that publishes tarball contributions. ``prelude``
  ## is spliced after the imports (a test may make the provider leave
  ## evidence that it was compiled and run).
  result = "import repro_project_dsl\n\n" & prelude &
    "package " & catalogIdent & ":\n  discard\n"
  for c in contributions:
    result.add("\n" & contributionStatement(c))

proc providerMarkerPrelude*(compiledMarker, ranMarker: string): string =
  ## Provider statements that write ``compiledMarker`` when the provider is
  ## COMPILED and ``ranMarker`` when it is RUN -- which publishing does and
  ## consuming must never do.
  "static: writeFile(" & compiledMarker.replace('\\', '/').escape() &
    ", \"compiled\")\n" &
  "writeFile(" & ranMarker.replace('\\', '/').escape() & ", \"ran\")\n\n"

# ---------------------------------------------------------------------------
# Publishing
# ---------------------------------------------------------------------------

var publishedMemo = initTable[string, seq[PublishedArtifactFile]]()
var extractionCount* = 0
  ## Real extractions (provider compiled and run) in this process.

proc publishProvider*(upstream, source: string; memo = true):
    seq[PublishedArtifactFile] =
  ## Write ``source`` as the catalog's provider (``repro.nim``) and generate
  ## its ``published-interfaces/`` with the production publisher -- or, when
  ## ``memo`` and this process already published the same source, write the
  ## files that run produced (see the module docstring).
  writeFile(upstream / "repro.nim", source)
  if memo and source in publishedMemo:
    result = publishedMemo[source]
    writePublishedInterfaces(upstream, result)
    return
  var saved: seq[(string, string, bool)] = @[]
  for (key, value) in [("REPRO_PROVIDER_NIMCACHE_MODE", "per-binary"),
                       ("REPRO_PROVIDER_PARALLEL_BUILD", "4")]:
    saved.add((key, getEnv(key), existsEnv(key)))
    putEnv(key, value)
  try:
    result = publishCatalogInterfaces(upstream, ["repro.nim"],
      FixtureReproRoot)
  finally:
    for (key, value, existed) in saved:
      if existed: putEnv(key, value) else: delEnv(key)
  inc extractionCount
  publishedMemo[source] = result

proc checkoutBranch(repo: CatalogRepo; branch: string) =
  let hasMain = execCmdEx("git -C " & quoteShell(repo.upstream) &
    " rev-parse --verify -q refs/heads/main").exitCode == 0
  let hasBranch = execCmdEx("git -C " & quoteShell(repo.upstream) &
    " rev-parse --verify -q refs/heads/" & branch).exitCode == 0
  if not hasMain:
    doAssert branch == "main", "the first publication goes on main"
  elif hasBranch:
    discard git(["checkout", "-q", "-f", branch], repo.upstream)
  else:
    discard git(["checkout", "-q", "-f", "-b", branch, "main"], repo.upstream)

proc publishRevision*(repo: CatalogRepo; source, message: string;
                      branch = "main"; memo = true):
    tuple[revision: string; files: seq[PublishedArtifactFile]] =
  ## Publish ``source`` as the catalog's provider on ``branch`` (created from
  ## ``main`` when new): generate ``published-interfaces/`` with the
  ## production publisher, commit the provider source and the generated
  ## artifacts together, and return the commit id and the files.
  repo.checkoutBranch(branch)
  result.files = publishProvider(repo.upstream, source, memo)
  discard git(["add", "-A"], repo.upstream)
  discard git(["commit", "-q", "--allow-empty", "-m", message], repo.upstream)
  result.revision = git(["rev-parse", "HEAD"], repo.upstream).strip()

proc fingerprintHexOf*(artifact: ProjectInterfaceArtifact): string =
  var hex = ""
  for b in artifact.interfaceFingerprint.bytes:
    hex.add(toHex(int(b), 2).toLowerAscii())
  hex

# ---------------------------------------------------------------------------
# The standard world: one interface catalog and two contribution catalogs
# ---------------------------------------------------------------------------

const
  FedToolPackage* = "federatedTool"
  FedToolExecutable* = "federated-tool"
  FedToolTopDir* = "federated-tool-1.0.0"
  FedToolPackageId* = "federated-tool@1.0.0"
  FedRepoPackages* = "fed-packages"
  FedRepoA* = "fed-catalog-a"
  FedRepoB* = "fed-catalog-b"
  FedContributorA* = "github:example/fed-catalog-a"
  FedContributorB* = "github:example/fed-catalog-b"

type StandardWorld* = object
  tag*: string
  packages*, a*, b*: CatalogRepo
  revPackages*, revA1*, revB1*: string
  toolFingerprint*: string
    ## The canonical interface fingerprint the interface catalog PUBLISHED
    ## (the value a contribution's provider pins).
  publishedPackages*, publishedA1*, publishedB1*: seq[PublishedArtifactFile]

proc fedRemote*(tag, repo: string): string =
  "https://example.invalid/" & tag & "/" & repo

proc fedContribution*(contributor: string; archive: FixtureArchive;
                      toolFingerprint: string): TarballContribution =
  TarballContribution(targetPackage: FedToolPackage,
    targetInterfaceFingerprint: toolFingerprint, contributor: contributor,
    archive: archive, executablePath: fixtureExecutableRelPath(
      FedToolExecutable), packageId: FedToolPackageId)

proc fedCatalogSource*(catalogIdent: string;
                       contributions: openArray[TarballContribution];
                       prelude = ""): string =
  contributionCatalogSource(catalogIdent, contributions, prelude)

proc newStandardWorld*(root, tag: string; archiveA, archiveB: FixtureArchive;
                       clonesRoot: string; memo = true;
                       preludeA = ""): StandardWorld =
  ## Three independent catalog repositories under ``<root>/<tag>``, each with
  ## one GENERATED publication, synced into the shared clones under
  ## ``clonesRoot``: ``fed-packages`` owns the canonical interface of
  ## ``federatedTool``; ``fed-catalog-a`` / ``fed-catalog-b`` each contribute
  ## a tarball realization of it, pinned to the fingerprint the interface
  ## catalog published.
  result.tag = tag
  let at = root / tag
  result.packages = initCatalogRepo(at, FedRepoPackages,
    fedRemote(tag, FedRepoPackages))
  result.a = initCatalogRepo(at, FedRepoA, fedRemote(tag, FedRepoA))
  result.b = initCatalogRepo(at, FedRepoB, fedRemote(tag, FedRepoB))
  let p = result.packages.publishRevision(
    canonicalToolSource(FedToolPackage, FedToolExecutable),
    "publish interfaces", memo = memo)
  result.revPackages = p.revision
  result.publishedPackages = p.files
  doAssert p.files.len == 1
  result.toolFingerprint = fingerprintHexOf(p.files[0].artifact)
  let a = result.a.publishRevision(fedCatalogSource("fedCatalogA",
    [fedContribution(FedContributorA, archiveA, result.toolFingerprint)],
    preludeA), "publish A1", memo = memo)
  result.revA1 = a.revision
  result.publishedA1 = a.files
  let b = result.b.publishRevision(fedCatalogSource("fedCatalogB",
    [fedContribution(FedContributorB, archiveB, result.toolFingerprint)]),
    "publish B1", memo = memo)
  result.revB1 = b.revision
  result.publishedB1 = b.files
  for repo in [result.packages, result.a, result.b]:
    discard repo.syncSharedClone(clonesRoot)

proc standardImports*(w: StandardWorld): seq[ImportSpec] =
  ## The interface catalog and A by the moving ref ``main``, B by its exact
  ## commit.
  @[ImportSpec(repo: FedRepoPackages, remote: w.packages.remote,
      gitRef: "main"),
    ImportSpec(repo: FedRepoA, remote: w.a.remote, gitRef: "main"),
    ImportSpec(repo: FedRepoB, remote: w.b.remote, commit: w.revB1)]

proc recordOfPublished*(files: seq[PublishedArtifactFile]):
    InterfaceProvisioningContribution =
  ## The one contribution record a contribution catalog published.
  for f in files:
    for c in f.artifact.projectInterface.provisioningContributions:
      return c
  raise newException(ValueError, "the publication carries no contribution")
