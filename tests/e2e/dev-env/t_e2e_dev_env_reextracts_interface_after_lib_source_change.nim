## A dev-env activation re-extracts the project interface when a source the
## recipe is compiled against changes, even though the project file did not.
##
## reprobuild-specs issue
## 2026-09-24-dev-env-reuses-interface-after-stdlib-package-change: after an
## edit to ``repro_dsl_stdlib/packages/gh.nim`` added ``tarball`` arms,
## ``repro exec`` kept serving a ``project-interface.rbsz`` that described
## ``gh`` as it was BEFORE the edit, until the dev-env directory was removed by
## hand. ``Development-Environments-And-Control-API.md`` says a changed
## provider input must lead to a recompute; a package module compiled into
## the recipe is such an input.
##
## The cause was the interface-reuse decision in ``computeDevEnvEdge``. It
## replayed the cached interface whenever ``dev-env.rbde.cache-key`` matched
## ``computeDevEnvEdgeCacheKey``, and that key covers the project file, the
## lock, the develop overrides and a few environment variables -- not the
## modules the project file imports. So the extraction's own warm check,
## which does cover them, was never reached. Two cases, one per place such a
## module can live:
##
##   * a reprobuild LIBRARY source (the issue's case). The edge's work dir is
##     a scratch tree with its own ``libs/`` (the out-of-tree layout
##     ``reproLibPathFlags`` and ``reproLibSources`` both support), so the
##     test can edit a library source without touching the checkout running
##     it. ``$REPROBUILD_LIBS_DIR`` points the reprobuild libs at this
##     checkout, as an out-of-tree consumer's activation does.
##   * a module in the recipe's OWN project directory, imported by the
##     project file. A fix that folded only the library digest into that key
##     passes the first case and fails this one.
##
## In both, the imported module declares a package with a ``tarball`` arm, the
## recipe ``uses:`` it, and the edit changes the arm. The assertion is on the
## interface the SECOND activation hands downstream, which is the artifact the
## issue found stale. A third activation then checks that the fix did not turn
## every activation into a miss.
##
## No mocks: the engine-built ``build/bin/repro``, the real Nim compiler, the
## real io-mon shim and the real filesystem.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_dev_env_engine
import repro_interface_artifacts
import repro_test_support

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const
  FixturePkgModule = "fixture_dev_env_pkgs"
  FixtureToolName = "fixturedevenvtool"

type PackageModuleHome = enum
  pmhLibrary      ## ``<workDir>/libs/<lib>/src/``, a library the recipe
                  ## compiles against, like the stdlib's ``packages/gh.nim``
  pmhProjectDir   ## beside the project file, imported by it

proc packageModuleText(version: string): string =
  ## A stdlib-shaped package module: one ``package`` with one ``tarball``
  ## realization, like ``repro_dsl_stdlib/packages/gh.nim``. ``version`` is
  ## carried into the URL, the package id and the lock identity, so the
  ## interface extracted from it names exactly one of the two versions.
  let sha = repeat('a', 64)
  "import repro_project_dsl\n\n" &
    "package " & FixtureToolName & ":\n" &
    "  provisioning:\n" &
    "    tarball url = \"https://example.invalid/" & FixtureToolName & "-" &
      version & ".tar.gz\",\n" &
    "      sha256 = \"" & sha & "\",\n" &
    "      archiveType = \"tar.gz\",\n" &
    "      executablePath = \"bin/" & FixtureToolName & "\",\n" &
    "      packageId = \"" & FixtureToolName & "@" & version & "\",\n" &
    "      cpu = \"x86_64\",\n" &
    "      os = \"linux\",\n" &
    "      lockIdentity = \"tarball:" & FixtureToolName & "@" & version &
      ":sha256:" & sha & "\",\n" &
    "      version = \"" & version & "\"\n"

proc recipeText(): string =
  "import repro_project_dsl\n" &
    "import " & FixturePkgModule & "\n\n" &
    "package fixture:\n" &
    "  defaultToolProvisioning \"path\"\n" &
    "  uses:\n" &
    "    \"" & FixtureToolName & "\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    setEnv \"FIXTURE_MODE\", \"dev\"\n"

proc fixtureToolUrls(interfacePath: string): seq[string] =
  ## Every ``tarball`` URL the extracted interface records for the fixture
  ## tool. Read from the file on disk, because that file is what the issue
  ## found stale and what every downstream consumer of the edge reads.
  let artifact = readInterfaceArtifact(interfacePath)
  for use in artifact.projectInterface.toolUses:
    if use.packageSelector == FixtureToolName or
        use.rawConstraint.startsWith(FixtureToolName):
      for arm in use.tarballProvisioning:
        result.add(arm.url)

proc urlFor(version: string): string =
  "https://example.invalid/" & FixtureToolName & "-" & version & ".tar.gz"

type EditObservation = object
  ## What three activations around one edit of the imported module handed
  ## downstream. The cases assert on it in their own bodies.
  firstUrls: seq[string]     ## before the edit
  secondUrls: seq[string]    ## after the edit -- the artifact the issue found stale
  thirdRewroteInterface: bool  ## an unchanged activation changed the bytes or the mtime
  thirdLaunchedProvider: bool  ## an unchanged activation recompiled the provider

proc observeEditReachingInterface(home: PackageModuleHome): EditObservation =
  let repoRoot = getCurrentDir()
  let tempRoot = createTempDir("repro-dev-env-import-edit-", "")
  defer: removeDir(tempRoot)
  let projectRoot = tempRoot / "project"
  let libsTree = tempRoot / "libs-tree"
  let outDir = tempRoot / "out"
  let modulePath =
    case home
    of pmhLibrary:
      libsTree / "libs" / FixturePkgModule / "src" / (FixturePkgModule & ".nim")
    of pmhProjectDir:
      projectRoot / (FixturePkgModule & ".nim")
  createDir(projectRoot)
  createDir(libsTree / "libs")
  createDir(parentDir(modulePath))
  createDir(outDir)
  writeFile(modulePath, packageModuleText("1.0.0"))
  writeFile(projectRoot / "repro.nim", recipeText())

  let savedLibsDir = getEnv("REPROBUILD_LIBS_DIR")
  defer:
    if savedLibsDir.len > 0: putEnv("REPROBUILD_LIBS_DIR", savedLibsDir)
    else: delEnv("REPROBUILD_LIBS_DIR")
  putEnv("REPROBUILD_LIBS_DIR", repoRoot / "libs")

  let reproBin = reproBinary(repoRoot)
  let monitor = prepareMonitorTools(repoRoot, tempRoot / "monitor",
    "dev-env-import-edit")
  let cfg = DevEnvEdgeConfig(
    modulePath: projectRoot / "repro.nim",
    projectRoot: projectRoot,
    outDir: outDir,
    workDir: libsTree,
    publicCliPath: reproBin,
    monitorCliPath: monitor.monitorCliPath,
    monitorCliArgs: monitor.monitorCliArgs,
    monitorShimLibPath: monitor.shim,
    activity: "default",
    renderShell: false)

  let first = computeDevEnvEdge(cfg)
  result.firstUrls = fixtureToolUrls(first.interfacePath)

  # Nothing a `computeDevEnvEdgeCacheKey` input can see changes from here on:
  # the project file, the lock, the overrides and the environment are the
  # same. Only the imported module does, as in the issue. The new content has
  # a different length, so its stamp moves however coarse the filesystem's
  # mtime is.
  writeFile(modulePath, packageModuleText("2.0.0-changed"))

  let second = computeDevEnvEdge(cfg)
  result.secondUrls = fixtureToolUrls(second.interfacePath)
  if result.secondUrls != @[urlFor("2.0.0-changed")]:
    echo "interface after the ", home, " edit records: ",
      result.secondUrls.join(", ")

  # The fix must not turn every activation into a miss: with nothing moved, a
  # third activation hands back the same interface without rewriting it and
  # does not recompile the provider.
  let interfaceBytes = readFile(second.interfacePath)
  let interfaceStamp = getLastModificationTime(second.interfacePath)
  let third = computeDevEnvEdge(cfg)
  result.thirdRewroteInterface =
    readFile(third.interfacePath) != interfaceBytes or
    getLastModificationTime(third.interfacePath) != interfaceStamp
  result.thirdLaunchedProvider = third.stats.providerBuildLaunched

suite "e2e_dev_env_reextracts_interface_after_lib_source_change":
  when isIoMonitorSupported:
    test "a changed library package is not served from the cached interface":
      let seen = observeEditReachingInterface(pmhLibrary)
      check seen.firstUrls == @[urlFor("1.0.0")]
      check seen.secondUrls == @[urlFor("2.0.0-changed")]
      check not seen.secondUrls.anyIt(it == urlFor("1.0.0"))
      check not seen.thirdRewroteInterface
      check not seen.thirdLaunchedProvider

    test "a changed recipe-local module is not served from the cached interface":
      let seen = observeEditReachingInterface(pmhProjectDir)
      check seen.firstUrls == @[urlFor("1.0.0")]
      check seen.secondUrls == @[urlFor("2.0.0-changed")]
      check not seen.secondUrls.anyIt(it == urlFor("1.0.0"))
      check not seen.thirdRewroteInterface
      check not seen.thirdLaunchedProvider
