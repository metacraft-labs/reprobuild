## §6 rule 2: a project that depends on a producer transitively depends
## on the producer's TOOL — hermetically, with no host assumptions and
## no engine provisioning.
##
## Distribution-And-Packaging.md §6:
##
##   "A format producer (``dist.deb``, ``dist.rpm``, …) declares a
##   genuine build-graph dependency on the tool package it needs.
##   Therefore **a project that depends on a producer transitively
##   depends on the underlying tool** … Dependency-on-a-recipe ⇒
##   dependency-on-its-tools is the whole point."
##
## This is the milestone's central hermeticity claim, and it is the one
## most easily satisfied in appearance only: a producer that simply
## spelled ``dpkg-deb`` into an argv and hoped the host had one would
## look identical in the source and would work on the maintainer's
## machine.
##
## What makes it real in reprobuild is a specific pair of registrations,
## and each case below reads one of them back:
##
## * The EDGE names the tool (``BuildActionDef.toolIdentityRefs``),
##   which is what the engine's fork-time resolver walks to put the
##   tool's own bin directory on that action's PATH. Without it the
##   action inherits whatever PATH the build had.
## * The PACKAGE gains the tool as a native build dependency
##   (``registerPackageNativeTool``), which is what
##   ``PackageDef.allToolUses()`` folds into
##   ``ProjectInterface.toolUses`` and therefore what gets PROVISIONED.
##
## ``repro.nim``'s own ``uses:`` block states the same rule in prose:
## "A ``uses:`` entry is necessary but not sufficient: the edge also has
## to name them."

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc toolRefsFor(edgeId: string): seq[string] =
  ## Read the refs back off the REGISTRY entry, not off the local value
  ## the producer returned. ``buildActionRegistry.add`` stores a copy by
  ## value, so a producer that mutated only its local copy would leave
  ## the engine seeing nothing — the exact failure
  ## ``appendRegisteredActionToolIdentityRefs`` exists to prevent, and a
  ## test that read the local copy could not tell the two apart.
  for act in registeredBuildActions():
    if act.id == edgeId: return act.toolIdentityRefs
  @[]

suite "packaging: producers declare a real dependency on their tool":

  test "the deb producer's artifact edge names dpkg-deb":
    resetBuildActionRegistry()
    let artifact = debPackage(sampleDistribution(toLinux))
    check artifact.format == "deb"
    check "dpkg-deb" in toolRefsFor(artifact.edge.id)

  test "the tarball producer's artifact edge names tar":
    resetBuildActionRegistry()
    let artifact = tarballPackage(sampleDistribution(toLinux))
    check "tar" in toolRefsFor(artifact.edge.id)

  test "the tarball producer's artifact edge also names gzip":
    # The tool a producer TYPES is not the whole dependency. ``tar -z``
    # forks a separate program called ``gzip``, and an action's PATH
    # holds only the tools its own edge named -- so an edge that names
    # tar alone gets gnutar's bin directory and nothing else, and the
    # action dies with ``gzip: command not found`` / ``Child returned
    # status 127``. That is how the first real Linux build of the
    # fixture failed, after every unit case here passed.
    #
    # It must be on the TAR edge. gzip is exec'd by tar, so a separate
    # edge naming it would put it on the PATH of an action that never
    # runs it.
    resetBuildActionRegistry()
    let artifact = tarballPackage(sampleDistribution(toLinux))
    check GzipSelector in toolRefsFor(artifact.edge.id)
    check GzipSelector in artifact.toolSelectors

  test "no other producer drags gzip in":
    # Over-declaring costs a project a fetch of a tool it never runs.
    # dpkg-deb compresses the payload itself (``-Z gzip`` is dpkg's own
    # flag, not a fork of /usr/bin/gzip), and the MSI path is Windows.
    resetBuildActionRegistry()
    let deb = debPackage(sampleDistribution(toLinux))
    check GzipSelector notin deb.toolSelectors
    resetBuildActionRegistry()
    let msi = msiPackage(sampleDistribution(toWindows))
    check GzipSelector notin msi.toolSelectors

  test "the MSI producer names both WiX tools, on their own edges":
    # candle and light are separate programs from one distribution, and
    # each runs in its own action. Naming both on the light edge would
    # put candle on the wrong action's PATH and leave the compile step
    # with none.
    resetBuildActionRegistry()
    let artifact = msiPackage(sampleDistribution(toWindows))
    check "wix-light" in toolRefsFor(artifact.edge.id)
    var candleRefs: seq[string] = @[]
    for act in edgesInvoking("wix-candle"):
      candleRefs.add(toolRefsFor(act.id))
    check "wix-candle" in candleRefs
    check "wix-light" notin candleRefs

  test "the §5 staging edges name their own tools too":
    # The patchelf and install edges are emitted by the SHARED staging
    # step, not by any producer, so the tool declaration has to happen
    # there — otherwise every producer would have to remember to declare
    # tools it never mentions, which is precisely the per-producer
    # hand-writing §5 forbids.
    resetBuildActionRegistry()
    discard debPackage(sampleDistribution(toLinux))
    for act in edgesInvoking("patchelf"):
      check "patchelf" in toolRefsFor(act.id)
    for act in edgesInvoking("install-file"):
      check "install-file" in toolRefsFor(act.id)

  test "a producer reports the tools it made the project depend on":
    # The returned list is the claim in a form a caller can read back,
    # rather than a side effect the recipe has to take on trust.
    resetBuildActionRegistry()
    let deb = debPackage(sampleDistribution(toLinux))
    check "dpkg-deb" in deb.toolSelectors
    check "patchelf" in deb.toolSelectors
    resetBuildActionRegistry()
    let msi = msiPackage(sampleDistribution(toWindows))
    check "wix-candle" in msi.toolSelectors
    check "wix-light" in msi.toolSelectors
    # The Windows staging path has no POSIX-mode tool, so it must not
    # claim one — a producer that over-declares makes a project fetch a
    # tool it never runs.
    check "patchelf" notin msi.toolSelectors
    check "install-file" notin msi.toolSelectors

  test "the fixture's uses: block matches the producers' own selectors":
    # The package-level half of the dependency has to be a literal in
    # the recipe (reprobuild collects a package's tool dependencies at
    # macro-expansion time, before any ``build:`` body runs). That
    # leaves one way for the two halves to drift: the recipe author
    # writing a name the producer does not actually use. Pinning the
    # fixture's literals against the producers' exported selector
    # constants closes it.
    let fixture = repoRootFromTest() &
      "/tests/fixtures/packaging/two-binary-dist/repro.nim"
    let text = readFile(fixture)
    for selector in [DpkgDebSelector, TarSelector, GzipSelector,
                     CandleSelector, LightSelector, PatchelfSelector,
                     InstallSelector, ShSelector]:
      check text.contains("\"" & selector & "\"")

  test "no producer edge is marked uncacheable":
    # §6: "each producer is an ordinary reprobuild build edge
    # (content-addressed, cache-able, reproducible)". An edge opted out
    # of caching would still produce a correct package and would quietly
    # cost a full re-run of the packaging pipeline on every build.
    resetBuildActionRegistry()
    let deb = debPackage(sampleDistribution(toLinux))
    check deb.edge.cacheable
    for act in registeredBuildActions():
      check act.cacheable
