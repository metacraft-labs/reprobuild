## Source-from-tarball libffi recipe — the FIFTY-FIRST real from-source
## production recipe to exercise the M9.H/I/K trio. libffi is the
## portable foreign-function-interface library every modern Linux
## desktop depends on for runtime ABI bridging: GObject Introspection's
## ``g_function_info_invoke`` shells into ``ffi_call``, Python's ``ctypes``
## links libffi, Ruby's FFI gem links libffi, every JIT'd language
## (Python via ctypes, Ruby via FFI, Java via JNA) reaches for it to
## construct callable trampolines at runtime. The FIFTY-FIRST recipe
## opens the crypto-and-FFI batch (libffi + nettle + libgcrypt + gnutls)
## that closes the Qt6 / glib2 / GNOME transitive crypto dependency
## surface.
##
## ## Why libffi matters for the v1 desktop story
##
## libffi is the portable foreign-function-interface library at the
## bottom of every "call a C function from a high-level language"
## stack on the modern Linux desktop:
##
##   * GObject Introspection (``libgirepository.so``) uses libffi to
##     synthesize the function-pointer trampoline that bridges typed
##     GObject signatures to libffi's variadic ``ffi_call`` ABI, which
##     is how every Python / JavaScript / Lua GTK consumer reaches into
##     C library code at runtime.
##   * Python's ``ctypes`` standard-library module links libffi to build
##     the call frames for dlopened C ABIs (every Python that talks to
##     a C library without a hand-written CPython extension goes through
##     libffi).
##   * Ruby's FFI gem links libffi to expose the same dynamic-call
##     ability to Ruby code (RubyGems' default GTK + DBus bindings ride
##     this surface).
##   * GJS (the GNOME JavaScript runtime) uses libffi for SpiderMonkey's
##     callback marshalling.
##
## Sibling consumers pinning ``libffi >=3.4`` include glib2 (via
## GObject Introspection's libgirepository), python (ctypes), and gjs
## (GNOME's JS engine).
##
## ## sha256 strategy
##
## We vendor the upstream 3.4.6 .tar.gz at
## ``recipes/packages/source/libffi/vendor/libffi-3.4.6.tar.gz`` and
## reference it via a ``file://`` URL. The github.com release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 3.4.6 (current upstream stable)
##
## libffi releases are cut on GitHub under tags of the form
## ``v<X>.<Y>.<Z>``. 3.4.6 is the current stable in the 3.4.x line as
## of mid-2026 and the ABI is stable since the 3.4 cut — anything
## ``>=3.4`` covers the GObject-Introspection / ctypes / Ruby-FFI
## consumption.
##
## sha256 = b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e
##  (computed locally over the vendored ``libffi-3.4.6.tar.gz``,
##  1,391,684 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H
## ``fetch:`` block and the M9.I ``configureFlags:`` block off this
## package's registries and lowers them into fetch + ``./configure`` +
## ``make`` BuildActions; the per-artifact build body + install glue
## lands in M9.L; the recipe records the single library artifact via
## the ``library`` block so the M9.K artifact registry already knows
## what shared object to expect.
##
## ## Library artifact
##
## libffi's autotools build emits a single shared library
## (``libffi.so``) bundling the foreign-function-call ABI core, the
## per-arch assembly trampolines (x86_64 / aarch64 / riscv64), and the
## type-encoding helpers. We register the artifact under the package-
## level identifier ``libFfi`` (PascalCased from the upstream SONAME
## ``ffi`` per the libExpat / libGlib2 / libZ precedent of preserving
## the canonical ``lib`` prefix while PascalCasing the SONAME body).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``             — skip the static archive (not
##                                         used by the v1 desktop story;
##                                         libs are dynamic).
##   * ``--disable-docs``               — skip the texinfo / pdf manual
##                                         build (heavy texinfo
##                                         dependency surface, not
##                                         needed at runtime).
##   * ``--disable-multi-os-directory`` — skip the multilib install
##                                         layout (libffi's autotools
##                                         build defaults to installing
##                                         into ``lib/`` or ``lib64/``
##                                         depending on host probe; v1
##                                         pins single-arch ``lib/`` for
##                                         deterministic install paths).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libffiSource:
  ## From-source libffi — fifty-first M9.H/I/K production recipe.
  ## FIRST recipe in the crypto-and-FFI batch (libffi + nettle +
  ## libgcrypt + gnutls). Single library artifact recipe driven by
  ## autotools.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the ``configureFlags:`` block
  ## (registered via ``registeredBuildFlags`` on the ``"configure"``
  ## channel) and lowers them into fetch + configure BuildActions
  ## wired with the right URL + hash + flags. Single library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the libffi source tree.
    "3.4.6":
      sourceRevision = "v3.4.6"
      sourceUrl = "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz"
      sourceRepository = "https://github.com/libffi/libffi"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,391,684-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/libffi/vendor/libffi-3.4.6.tar.gz"
    sha256: "b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac`` (the upstream
    ## release tarball does ship a pre-generated ``configure`` but we
    ## list autoconf so the convention layer can re-bootstrap if the
    ## tarball gets re-archived without ``configure``).
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — libffi is C99 + per-arch assembly
    ## fast-paths for the trampoline tail-call.
    "gcc >=11"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libFfi:
    ## ``libffi.so`` — the portable foreign-function-call ABI shim
    ## bundling the FFI core + per-arch assembly trampolines + type-
    ## encoding helpers. Consumed by GObject Introspection's
    ## libgirepository, Python's ctypes, Ruby's FFI gem, and GJS's
    ## SpiderMonkey callback marshalling. The upstream SONAME ``ffi``
    ## is PascalCased to ``libFfi`` per the libExpat / libGlib2 / libZ
    ## precedent of preserving the canonical ``lib`` prefix while
    ## PascalCasing the SONAME body. v1 records the artifact only; the
    ## per-artifact build body lands in M9.L when the convention's
    ## make-spawn + install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("libffiSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-docs",
        "--disable-multi-os-directory",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libFfi")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
