## The DSL packaging layer — reprobuild's CPack analog, entirely in user
## space.
##
## Importing this module gives a recipe the ``Distribution`` type, the
## §5 runtime contract, and the reference producers, with the built-in
## producers registered.
##
## ```nim
## import repro_dsl_stdlib/packaging
##
## package sampletool:
##   uses:
##     "nim >=2.2 <3.0"
##     # The producers declare their own tools (see
##     # ``runtime_contract.declareProducerTool``); these entries are
##     # what makes them resolvable on this host.
##     "tar"
##     "dpkg-deb"
##     "patchelf"
##     "install-file"
##
##   build:
##     let hello = nim.c(source = "src/hello.nim", binary = "build/bin/hello")
##     var dist = newDistribution("sampletool", "0.2.0", toLinux)
##     dist.components = @[executableComponent("build/bin/hello", @[hello])]
##     discard debPackage(dist, packagingSite("sampletool"))
##     discard tarballPackage(dist, packagingSite("sampletool"))
## ```
##
## Everything above is ordinary Nim over ordinary build edges. The
## engine gains nothing: there is no packaging opcode, no format enum,
## no capability switch. Distribution-And-Packaging.md §6.1 — "the
## engine does not know what a ``.deb`` is, and must not" — is a
## property of this arrangement rather than a rule anyone has to
## remember.
##
## ## Adding a format
##
## A new format is a new module that nobody in this repository has to
## know about:
##
## ```nim
## import repro_dsl_stdlib/packaging
## import mypkgs/packages/ipkg_build        # your own tool package
##
## proc ipkPackage*(dist: Distribution; site = noSite()): PackagedArtifact =
##   let tree = stageInstallTree(dist, "ipk", site)      # §5 applied for you
##   let edge = ipkgBuild(tree = tree.root, output = ...,
##                        after = tree.terminal,
##                        extraInputs = tree.stagedPaths())
##   declareProducerTool(site, edge.id, "ipkg-build")     # §6 rule 2
##   PackagedArtifact(format: "ipk", path: ..., edge: edge, tree: tree)
##
## proc ipkProducer(dist: Distribution;
##                  site: ToolDependencySite): PackagedArtifact {.nimcall.} =
##   ipkPackage(dist, site)
##
## registerProducer("ipk", "OpenWrt package", ipkProducer)
## ```
##
## Zero engine changes, zero DSL-macro changes, zero changes to this
## file. That is §6 rule 3, and
## ``libs/repro_dsl_stdlib/tests/t_packaging_third_party_producer.nim``
## does exactly the above inside a test to prove it is not aspirational.

import ./packaging/types
import ./packaging/runtime_contract
import ./packaging/services
import ./packaging/producer
import ./packaging/producers/tarball
import ./packaging/producers/deb
import ./packaging/producers/msi

export types, runtime_contract, services, producer, tarball, deb, msi

proc packagingSite*(packageName: string;
                    sourceFile = ""; sourceLine = 0): ToolDependencySite =
  ## Name the package a producer is being called on behalf of, so the
  ## producer can register its tool as a dependency OF that package
  ## (§6 rule 2 — "a project that depends on a producer transitively
  ## depends on the underlying tool").
  ##
  ## ``sourceFile``/``sourceLine`` identify WHICH declaration when one
  ## recipe module is instantiated more than once — the per-consumer
  ## sibling shims give each consumer its own module instance, and
  ## ``registerPackageNativeTool`` matches on the triple. Leaving them
  ## empty is correct for the ordinary single-instantiation case;
  ## ``registerPackageNativeTool`` then raises rather than silently
  ## registering against the wrong declaration, which is why the
  ## producers tolerate a site whose ``packageName`` is empty and skip
  ## the package-level half rather than guessing.
  ToolDependencySite(
    packageName: packageName,
    sourceFile: sourceFile,
    sourceLine: sourceLine)
