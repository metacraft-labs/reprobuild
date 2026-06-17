## Smoke test for the from-source ``kernelSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource`` / ``wlrootsSource`` /
## ``swaySource``). The kernel's specific coverage angle is that it
## is the FIRST consumer of the M9.I ``makeFlags:`` channel — the
## five prior from-source recipes all build under meson + ninja and
## consume ``mesonOptions:``. The kernel by contrast drives ``make``
## /kbuild, so this recipe's M9.I round-trip exercises the
## ``"make"`` channel of ``registeredBuildFlags``, complementing the
## five prior recipes' ``"meson"`` coverage.
##
## The recipe also exercises a MIXED artifact set: ONE
## ``executable`` (bzImage — the bootable kernel image) plus THREE
## ``files`` artifacts (vmlinux + System.map + KERNELRELEASE). The
## prior recipes covered: dbus-broker = 2 executables, libdrm = 3
## libraries, Wayland = 3 libs + 1 exec, wlroots = 1 library,
## Sway = 4 executables. The kernel is the first to combine 1
## ``dakExecutable`` with 3 ``dakFiles`` in a single recipe, so the
## M3 artifact registry's exec-vs-files discriminator gets a fresh
## angle of coverage.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``makeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-
##     isolation spot-check (the ``meson`` channel must NOT see
##     the make flags).
##   * MIXED artifact registration (M3) — ``bzImage`` registered as
##     ``dakExecutable``; ``vmlinux`` / ``systemMap`` /
##     ``kernelRelease`` registered as ``dakFiles``. All four
##     attributed to ``kernelSource``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + make flags + executable + files artifacts under
# ``kernelSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.142.tar.xz"

const ExpectedHash =
  "b2f6607a75cd27b2e368cf2d25e1637e1e0da9dfed4cda536658879eee6f2b70"

const ExpectedMakeFlags = @[
  "ARCH=x86_64",
  "LOCALVERSION=",
  "KBUILD_BUILD_USER=reprobuild",
  "KBUILD_BUILD_HOST=reprobuild",
  "KBUILD_BUILD_TIMESTAMP=@1577836800",
  "-j1",
]

suite "kernelSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kernelSource")
    check spec.packageName == "kernelSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 140,641,384-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("kernelSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream uses for
    # cdn.kernel.org tarballs (the top-level dir inside is
    # ``linux-<version>/`` which we strip).
    let spec = registeredFetchSpec("kernelSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "makeFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip — ``make`` evaluates variable
    # assignments left-to-right and a regression that reorders this
    # seq would silently change build behaviour. ARCH must come
    # first (it gates the kbuild Makefile selection); LOCALVERSION
    # must come BEFORE the KBUILD_BUILD_USER/HOST/TIMESTAMP block
    # so a regression that swapped them would leak a stale
    # LOCALVERSION suffix into the KERNELRELEASE string.
    let flags = registeredBuildFlags("kernelSource", "", "make")
    check flags == ExpectedMakeFlags
    check flags.len == 6
    check flags[0] == "ARCH=x86_64"
    check flags[1] == "LOCALVERSION="
    check flags[5] == "-j1"

  test "makeFlags does not leak into the meson channel":
    # Channel-isolation spot-check — a regression that flattens the
    # per-channel registries would surface here. The kernel is a
    # make/kbuild package; if its flags leaked into the ``meson``
    # channel a downstream recipe sharing a packageName fragment
    # could accidentally consume kernel flags as meson options.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("kernelSource", "", "meson") == emptyStrSeq
    check registeredBuildFlags("kernelSource", "", "cmake") == emptyStrSeq
    check registeredBuildFlags("kernelSource", "", "ninja") == emptyStrSeq
    check registeredBuildFlags("kernelSource", "", "configure") == emptyStrSeq

  test "artifacts register the bzImage as dakExecutable":
    # M3 artifact registry: bzImage must be tagged
    # ``dakExecutable`` because it is the BOOTABLE kernel image.
    # A regression that mis-tagged it as ``dakFiles`` would route
    # the binary under ``share/`` instead of ``bin/`` / ``boot/``,
    # breaking the activation layer's bootloader-menu generator.
    let arts = registeredArtifacts("kernelSource")
    check arts.len == 4
    var seenBzImage = false
    for art in arts:
      check art.packageName == "kernelSource"
      if art.artifactName == "bzImage":
        check art.kind == dakExecutable
        seenBzImage = true
    check seenBzImage

  test "artifacts register vmlinux / systemMap / kernelRelease as dakFiles":
    # M3 artifact registry: the three non-bootable outputs must all
    # be tagged ``dakFiles``. A regression that flattened the
    # discriminator (e.g. labelling them all as executable) would
    # mis-route them on install.
    let arts = registeredArtifacts("kernelSource")
    var seenVmlinux = false
    var seenSystemMap = false
    var seenKernelRelease = false
    for art in arts:
      case art.artifactName
      of "vmlinux":
        check art.kind == dakFiles
        seenVmlinux = true
      of "systemMap":
        check art.kind == dakFiles
        seenSystemMap = true
      of "kernelRelease":
        check art.kind == dakFiles
        seenKernelRelease = true
      else: discard
    check seenVmlinux
    check seenSystemMap
    check seenKernelRelease

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream cdn.kernel.org tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical Linus tree on git.kernel.org.
    let vs = registeredVersions("kernelSource")
    check vs.len == 1
    check vs[0].version == "6.6.142"
    check vs[0].sourceRevision == "v6.6.142"
    check vs[0].sourceUrl ==
      "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.142.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
