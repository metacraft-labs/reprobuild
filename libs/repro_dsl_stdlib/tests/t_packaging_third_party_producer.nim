## §6 rule 3: adding a new format producer and its tool package requires
## ZERO engine changes — demonstrated by doing it.
##
## Distribution-And-Packaging.md §6:
##
##   "The producer set is open and pluggable. The built-in producers …
##   are a **reference set**, not a closed enum baked into the engine.
##   The producer 'interface' is just a recipe signature — ``(typed
##   Distribution) -> artifact edge``. Anyone can define a new producer
##   for a new format, bring its own tool package, and plug it in
##   **purely in user space**."
##
## M0's gate names this as the architectural claim of the whole
## milestone and asks for it to be demonstrated "with a trivial custom
## producer defined outside the stdlib".
##
## **This file is that producer.** Everything below — the tool package,
## the artifact-name convention, the producer proc, the registration —
## lives in a test file under ``libs/repro_dsl_stdlib/tests/``, which is
## not the stdlib, is not the DSL macro layer, and is emphatically not
## the engine. Nothing outside this file was edited to make it work.
##
## The companion assertion — that the engine contains no
## packaging-specific code at all — is
## ``t_packaging_engine_has_no_format_knowledge.nim``. Together they are
## the two halves of the claim: nothing central knows about formats, and
## a new format can be added without telling anything central.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/types/executable
import repro_dsl_stdlib/packaging
import ./packaging_test_support

{.experimental: "callOperator".}

# ---------------------------------------------------------------------------
# Step 1 — the tool package (§6 rule 1: "packaging tools are reprobuild
# packages"). This is an ordinary ``package`` block. A real third party
# would put it in their own repository; putting it in a test file is
# strictly HARDER than the real case, and it still needs nothing from
# the stdlib but the ``package`` macro every recipe already uses.
#
# ``cpio`` is not an arbitrary choice: it is the archiver an actual next
# format would need (rpm payloads and initramfs images are both cpio),
# so this is a plausible producer rather than a strawman.
# ---------------------------------------------------------------------------

package `cpio-archive`:
  provisioning:
    nixPackage "nixpkgs#cpio", executablePath = "bin/cpio",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable cpioBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag createMode is bool, alias = "-o"
        flag format is string,
          alias = "-H",
          format = separate
        flag file is string,
          alias = "-F",
          format = separate,
          role = output
        flag directory is string,
          alias = "-D",
          format = separate,
          role = input

        outputs file

const cpioTool = cpio_archive

const CpioSelector = "cpio-archive"

# ---------------------------------------------------------------------------
# Step 2 — the producer. One proc matching ``ProducerFn``.
#
# Note what it does NOT do: it does not apply the §5 wrapper contract,
# patch an RPATH, set a file mode or decide a layout. ``stageInstallTree``
# did all of that before this proc's first statement, which is what
# makes a third-party producer as correct as a built-in one by
# construction rather than by the author having read §5.
# ---------------------------------------------------------------------------

proc cpioPackage(dist: Distribution;
                 site = noSite()): PackagedArtifact =
  let tree = stageInstallTree(dist, "cpio", site)
  let outPath = dist.outputDir & "/" & dist.name & "-" &
    dist.fullVersion & ".cpio"
  let edge = cpioTool(
    createMode = true,
    format = "newc",
    file = outPath,
    directory = tree.root,
    actionId = "pkg-cpio-" & dist.name,
    after = tree.terminal,
    extraInputs = tree.stagedPaths())
  declareProducerTool(site, edge.id, CpioSelector)
  PackagedArtifact(
    format: "cpio",
    path: outPath,
    edge: edge,
    toolSelectors: @[CpioSelector],
    tree: tree)

proc cpioProducer(dist: Distribution;
                  site: ToolDependencySite): PackagedArtifact {.nimcall.} =
  cpioPackage(dist, site)

suite "packaging: a third party adds a format with zero central changes":

  test "registering a new format needs only registerProducer":
    resetBuildActionRegistry()
    check not hasProducer("cpio")
    registerProducer("cpio", "cpio newc archive (tool: cpio)", cpioProducer)
    check hasProducer("cpio")
    check "cpio" in registeredProducerFormats()

  test "the new format is produced through the same generic entry point":
    # ``produce`` is a table lookup over a user-space registry. It has
    # no branch per format, so the built-in producers reach it by
    # exactly the path this one does — which is what "the built-ins are
    # non-privileged reference instances" means operationally.
    resetBuildActionRegistry()
    registerProducer("cpio", "cpio newc archive (tool: cpio)", cpioProducer)
    let artifact = produce("cpio", sampleDistribution(toLinux))
    check artifact.format == "cpio"
    check artifact.path.endsWith("sampletool-0.2.0-1.cpio")
    check artifact.edge.outputs == @[artifact.path]

  test "the third-party producer gets the §5 contract for free":
    # It never mentions patchelf, a wrapper or a mode, and its tree has
    # all three — because the contract is applied by staging, not by
    # producers. This is the property that makes an open producer set
    # safe: a format author cannot forget §5, because they were never
    # given the opportunity to apply it.
    resetBuildActionRegistry()
    let artifact = cpioPackage(sampleDistribution(toLinux))
    let paths = stagedRelPaths(artifact.tree)
    check "usr/bin/hello" in paths
    check "usr/bin/hello.real" in paths
    check edgesInvoking("patchelf").len == 2
    check writtenText("bin-hello.wrapper").contains(
      "if [ -z \"${SAMPLETOOL_MODE:-}\" ]; then")

  test "the third-party tool becomes a dependency by the same mechanism":
    resetBuildActionRegistry()
    let artifact = cpioPackage(sampleDistribution(toLinux))
    var refs: seq[string] = @[]
    for act in registeredBuildActions():
      if act.id == artifact.edge.id: refs = act.toolIdentityRefs
    check CpioSelector in refs

  test "re-registering a format swaps the tool behind it":
    # §6 rule 3 explicitly allows a user to "swap the tool behind an
    # existing one". If the registry refused a replacement, the
    # built-ins would be privileged — the one thing rule 3 says they are
    # not. The check is that the LAST registration wins for a format
    # that already has a built-in.
    resetBuildActionRegistry()
    registerProducer("tar.gz", "a third party's own tarball", cpioProducer)
    let artifact = produce("tar.gz", sampleDistribution(toLinux))
    check artifact.format == "cpio"
    # Put the built-in back so case order cannot affect other suites.
    registerProducer("tar.gz",
      "Relocatable gzipped tar of the install tree (tool: tar)",
      proc (dist: Distribution;
            site: ToolDependencySite): PackagedArtifact {.nimcall.} =
        tarballPackage(dist, site))

  test "an unregistered format fails by naming what IS registered":
    # The closest thing this layer has to a capability query, and it is
    # a pure user-space lookup: §6.1's "the engine does not know what a
    # .deb is, and must not" holds even for the error message.
    resetBuildActionRegistry()
    var message = ""
    try:
      discard produce("no-such-format", sampleDistribution(toLinux))
    except ValueError as err:
      message = err.msg
    check message.contains("no packaging producer registered for format")
    check message.contains("deb")
