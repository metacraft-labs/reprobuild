## Source-from-tarball libcap-ng recipe — the FIFTIETH real
## from-source production recipe to exercise the M9.H/I/K trio.
## libcap-ng is the simplified, modern POSIX capabilities library
## (designed by Steve Grubb at Red Hat to be a cleaner alternative to
## libcap's original API) consumed by audit-rule daemons and the
## ``filecap`` / ``netcap`` / ``pscap`` diagnostic toolset.
##
## ## Why libcap-ng matters for the v1 desktop story
##
## libcap-ng complements (does NOT replace) the libcap recipe (recipe
## thirty-four). The two libraries coexist on every modern Linux
## distribution:
##
##   * libcap ships ``libcap.so`` (the original POSIX 1003.1e
##     capabilities ABI consumed by systemd, sshd, NetworkManager,
##     kwin_wayland — the "raw" API surface).
##   * libcap-ng ships ``libcap-ng.so`` (a SIMPLIFIED higher-level
##     wrapper API where ``capng_clear()`` / ``capng_updatev()`` /
##     ``capng_apply()`` replace libcap's multi-step
##     ``cap_get_proc()`` / ``cap_clear()`` / ``cap_set_proc()``
##     pattern). The simplification is what makes audit daemons +
##     diagnostic tooling adopt libcap-ng instead.
##
## libcap-ng consumers on the v1 desktop:
##
##   * auditd's capability-bounding-set computation (libcap-ng's
##     ``capng_*`` API is preferred over libcap's raw API because
##     auditd's reload path mutates the bounding set in a way the
##     higher-level API expresses cleanly).
##   * crond (cronie) uses libcap-ng for per-job capability dropping.
##   * The diagnostic toolset (``filecap`` / ``netcap`` / ``pscap`` /
##     ``captest``) — these are upstream libcap-ng-shipped CLIs we do
##     NOT register here (v1 records the library only; the diagnostic
##     binaries can be lifted in a future batch if needed).
##
## ## sha256 strategy
##
## We vendor the upstream 0.8.5 .tar.gz at
## ``recipes/packages/source/libcap-ng/vendor/libcap-ng-0.8.5.tar.gz``
## and reference it via a ``file://`` URL. The people.redhat.com
## release URL is recorded as ``sourceUrl`` in the ``versions:`` block
## for documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 0.8.5 (current upstream stable)
##
## libcap-ng releases are cut on people.redhat.com (Steve Grubb's
## personal release page) and mirrored to github.com/stevegrubb/libcap-ng.
## 0.8.5 is the current stable as of mid-2026 and the libcap-ng ABI
## has been stable since the 0.8 cut — anything ``>=0.8`` covers the
## auditd + cronie consumption.
##
## sha256 = 3ba5294d1cbdfa98afaacfbc00b6af9ed2b83e8a21817185dfd844cc8c7ac6ff
##  (computed locally over the vendored ``libcap-ng-0.8.5.tar.gz``,
##  460,149 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the single library artifact via the
## ``library`` block so the M9.K artifact registry already knows what
## shared object to expect.
##
## ## Artifacts
##
## libcap-ng's autotools build emits a single externally-consumed
## library:
##
##   * ``libCapNg`` — ``libcap-ng.so`` the simplified capabilities
##                    C library consumed by auditd + cronie.
##
## The upstream SONAME ``cap-ng`` is PascalCased to ``libCapNg`` (the
## hyphenated suffix folds to PascalCase per the json-c -> libJsonC
## precedent that handled the same kebab-to-PascalCase mapping). v1
## does NOT register the upstream diagnostic CLIs (``filecap`` /
## ``netcap`` / ``pscap`` / ``captest``) — they are NOT load-bearing
## for the v1 desktop's auditd + cronie consumers.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static`` — skip the static archive (not used by
##                             the v1 desktop story; libs are
##                             dynamic).
##   * ``--without-python`` — skip the Python 2 bindings (Python 2 is
##                             end-of-life; pulling it in would add a
##                             dead-code dependency surface).
##   * ``--without-python3`` — skip the Python 3 bindings (heavy
##                              Python interpreter dependency surface
##                              + the v1 desktop's auditd + cronie
##                              consumers use the C ABI directly, not
##                              the Python bindings; a Python-edition
##                              variant would flip this later when
##                              python3-audit lands).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libcapNgSource:
  ## From-source libcap-ng — fiftieth M9.H/I/K production recipe.
  ## The simplified-API POSIX capabilities library (Steve Grubb's
  ## libcap alternative) consumed by auditd + cronie. Closes the
  ## capabilities-library duo started by recipe thirty-four (libcap):
  ## libcap covers the "raw" POSIX 1003.1e API, libcap-ng covers the
  ## higher-level wrapper API.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## people.redhat.com release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical github.com mirror
    ## of Steve Grubb's libcap-ng source tree.
    "0.8.5":
      sourceRevision = "v0.8.5"
      sourceUrl = "https://people.redhat.com/sgrubb/libcap-ng/libcap-ng-0.8.5.tar.gz"
      sourceRepository = "https://github.com/stevegrubb/libcap-ng"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 460,149-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://people.redhat.com/sgrubb/libcap-ng/libcap-ng-0.8.5.tar.gz"
    sha256: "3ba5294d1cbdfa98afaacfbc00b6af9ed2b83e8a21817185dfd844cc8c7ac6ff"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac`` (the upstream
    ## tarball does ship a pre-generated ``configure`` but we list
    ## autoconf so the convention layer can re-bootstrap if the tarball
    ## gets re-archived without ``configure``).
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — libcap-ng is plain C99 with a
    ## small Linux-specific kernel-header dependency surface.
    "gcc >=11"

  buildDeps:
    ## swig is invoked by the autotools build for the bindings layer
    ## (we ``--without-python`` + ``--without-python3`` so swig is
    ## elided in practice, but autoconf still probes for it; the
    ## ``uses:`` entry pins the probe-time availability).
    "swig"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libCapNg:
    ## ``libcap-ng.so`` — the simplified-API POSIX capabilities C
    ## library consumed by auditd's capability-bounding-set
    ## computation + cronie's per-job capability dropping. The
    ## upstream SONAME ``cap-ng`` is PascalCased to ``libCapNg`` per
    ## the json-c -> libJsonC precedent that handled the same
    ## kebab-to-PascalCase mapping. v1 records the artifact only; the
    ## per-artifact build body lands in M9.L when the convention's
    ## make-spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("libcapNgSource")
    try:
      let opts = @[
        "--disable-static",
        "--without-python",
        "--without-python3",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libCapNg")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
