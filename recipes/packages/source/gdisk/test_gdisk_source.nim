## Smoke test for the from-source ``gdiskSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[algorithm, sequtils, unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://downloads.sourceforge.net/gptfdisk/gptfdisk-1.0.10.tar.gz"
const ExpectedHash =
  "2abed61bc6d2b9ec498973c0440b8b804b7a72d7144069b5a9209b2ad693a282"

## The names reprobuild's own emitters append to ``gdiskSource``'s native
## build-dep row, spelled out rather than recomputed from the emitters.
## Deriving them from ``shellFetchToolIdentityRefs`` /
## ``typedInstallMirrorShellTools`` would make the case agree with whatever
## those procs currently return, which is precisely the property under test.
##
## Two emitters contribute, and the union is deduplicated:
##
## * the fetch emitter, for the generated download-and-extract script —
##   its fixed ``sh``/``rm``/``mkdir``/``curl``/``mv`` core, the checksum
##   tool named by this recipe's ``sha256:`` field, and — because the
##   ``fetch:`` is a tarball rather than a data file — ``tar`` plus the
##   decompressor for the ``.tar.gz`` URL above;
## * the install-mirror emitter, for the generated mirror script, whose
##   rpath-patching half is Linux-only.
const ExpectedFetchEmitted = [
  "sh", "rm", "mkdir", "curl", "mv", "sha256sum", "tar", "gzip",
]
const ExpectedMirrorEmitted =
  when defined(linux):
    [
      "sh", "rm", "mkdir", "cp", "touch", "sed", "chmod",
      "find", "head", "od", "tr", "sort", "grep", "dirname", "basename",
      "wc", "patchelf", "readlink", "mktemp", "mv", "readelf",
    ]
  else:
    ["sh", "rm", "mkdir", "cp", "touch", "sed", "chmod"]

suite "gdiskSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("gdiskSource")
    check spec.packageName == "gdiskSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("gdiskSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("gdiskSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "build dependencies are exact":
    # AUTHORED, not the full row: reprobuild's fetch and install-mirror
    # emitters append the commands their generated scripts run (``sh``,
    # ``curl``, ``tar``, ``patchelf``, …) to every ``fetch:``-bearing
    # recipe. What this case states is what the RECIPE declared, so it
    # reads the authored accessor. The appended half is the next case.
    check registeredAuthoredNativeBuildDeps("gdiskSource") == @[
      "make", "gcc >=11", "pkg-config",
    ]
    check registeredBuildDeps("gdiskSource") == @[
      "ncurses", "popt", "util-linux",
    ]

  test "emitter-contributed build tools are exact":
    # The other half of the row, and the half nothing else pins on a real
    # recipe. ``t_source_fetch_tool_metadata`` asks only for CONTAINMENT
    # and only of the synthetic ``archiveFetchMetadata`` fixture;
    # ``t_install_mirror_tool_metadata`` never reads the accessor at all;
    # and every surviving ``registeredNativeBuildDeps(...) == @[...]``
    # elsewhere in the tree is against a fixture with no ``fetch:``, so no
    # equality assertion anywhere reaches an appended name. Measured:
    # deleting ``curl`` from ``shellFetchToolIdentityRefs`` outright left
    # both of those suites fully green — the one place either mentions
    # ``curl`` reads a constraint the fixture declares itself
    # (``"curl >=8"``), not the bare name the emitter registers. An extra
    # name is caught only when it also happens to lack Nix provisioning
    # metadata, which is a different property.
    #
    # Stated as the DIFFERENCE rather than as the whole row: the authored
    # half is already pinned above, and repeating it here would give it a
    # second home to drift from. The difference is what lost coverage.
    #
    # Compared as SETS. The row's order is emission order — authored
    # entries, then whichever of the two emitters the ``package`` macro
    # runs first — and no contract makes that order stable, so an
    # order-sensitive assertion here would be a latent flake rather than a
    # stronger check. Sorted-seq equality still fails on a name appearing,
    # a name disappearing, or a name appearing twice.
    let complete = registeredNativeBuildDeps("gdiskSource")
    let authored = registeredAuthoredNativeBuildDeps("gdiskSource")
    let emitted = complete.filterIt(it notin authored)
    let expected = deduplicate(
      @ExpectedFetchEmitted & @ExpectedMirrorEmitted)
    check emitted.sorted == expected.sorted
    # Authored and emitted partition the row: nothing is counted twice and
    # nothing falls through the accessor pair.
    check complete.len == authored.len + emitted.len

  test "four partitioning tools are registered":
    let artifacts = registeredArtifacts("gdiskSource")
    check artifacts.len == 4
    check artifacts[0].artifactName == "gdisk"
    check artifacts[1].artifactName == "sgdisk"
    check artifacts[2].artifactName == "cgdisk"
    check artifacts[3].artifactName == "fixparts"
    for artifact in artifacts:
      check artifact.kind == dakExecutable
