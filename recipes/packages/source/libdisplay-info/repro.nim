## Source-from-tarball libdisplay-info recipe — M9.R.59.2 (second of
## two recipes closing the wlroots DRM-backend compile-time gate
## residual from M9.R.58).
##
## libdisplay-info is Simon Ser's C library for parsing EDID
## (Extended Display Identification Data — the byte blob a monitor
## reports over I2C/DDC / DisplayPort AUX) and DisplayID (the modern
## VESA replacement for EDID). It's a small (~4 KLOC) MIT-licensed
## meson-built library that ships one .so + a headers set + a
## debugging CLI (``di-edid-decode``).
##
## ## Why libdisplay-info matters for the NDE-H Sway DRM-backend story
##
## wlroots 0.19's DRM backend meson probe at
## ``wlroots-0.19.3/backend/drm/meson.build:8-13`` declares
## ``libdisplay_info = dependency('libdisplay-info', required: 'drm'
## in backends, fallback: 'libdisplay-info')`` and immediately below,
## the DRM subdir gate at line 22 reads
## ``if not (hwdata.found() and libdisplay_info.found() and
## features['session']) { subdir_done() }``. wlroots' DRM backend
## consumes libdisplay-info to parse EDID payloads from connected
## displays; without it, the backend is compiled out entirely.
##
## Along with M9.R.59.1's hwdata recipe, this closes the last two
## upstream deps of wlroots' DRM backend, moving wlroots' meson-log
## line ``drm-backend : NO`` to ``drm-backend : YES``.
##
## ## Upstream project — libdisplay-info (single-repo, C library)
##
## Simon Ser's ``libdisplay-info`` upstream at
## ``https://gitlab.freedesktop.org/emersion/libdisplay-info`` is the
## canonical home. nixpkgs pins
## ``pkgs/development/libraries/libdisplay-info`` against the same
## upstream tags. The library is developed alongside wlroots (Simon
## Ser is a wlroots maintainer), so version coordination between the
## two is tight.
##
## ## Version choice — 0.2.0 (matches wlroots 0.19 upstream test matrix)
##
## Upstream ships two active release lines: 0.2.0 (April 2024, MAJOR
## symbol addition for the CTA-861 codec-3D parsing) and 0.3.0
## (October 2024, ergonomics/API-cleanup). wlroots 0.19 was written
## against 0.2.0 (per the wlroots 0.19 release notes) and does not
## use any 0.3.x-only symbols. Pinning 0.2.0 gives a byte-for-byte
## match with what upstream wlroots 0.19 was tested against.
##
## sha256 = 5a2f002a16f42dd3540c8846f80a90b8f4bdcd067a94b9d2087bc2feae974176
##  (computed locally over the vendored ``libdisplay-info-0.2.0.tar.xz``,
##  95,280 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_meson convention (M9.K) reads the ``fetch:`` block and
## the inline mesonOptions (via the M9.R.5b explicit ``build:``
## block) and lowers them into fetch + configure + compile + install
## BuildActions. libdisplay-info's meson build is minimal —
## meson.build has no explicit options; it auto-detects hwdata via
## ``dependency('hwdata', required: false, native: true)`` and
## consumes ``hwdata_dir/pnp.ids`` at build time via a Python
## ``gen-search-table.py`` custom_target to synthesize the
## ``pnp-id-table.c`` PnP-vendor lookup file.
##
## ## Artifacts
##
## libdisplay-info's meson build emits:
##
##   * ``libdisplay-info.so`` — the shared library wlroots links
##                              against (registered as
##                              ``libdisplayInfo`` in this recipe;
##                              the M9.L install glue resolves it to
##                              ``$prefix/lib/libdisplay-info.so*``).
##   * headers under ``include/libdisplay-info/`` — public API for
##                              consumers.
##   * ``libdisplay-info.pc`` — pkg-config metadata.
##   * ``di-edid-decode`` — CLI debugging tool that dumps parsed
##                          EDID/DisplayID as human-readable text.
##                          (Registered as ``diEdidDecode``; not
##                          consumed by wlroots but shipped alongside
##                          the library per the upstream convention.)
##
## ## Configurables
##
## v1 ships NO configurables — libdisplay-info's meson project
## exposes no options file (``meson_options.txt`` doesn't exist), so
## there's nothing to knob. The build always emits the library +
## di-edid-decode + tests; the tests are skipped at meson-setup time
## when the test-runtime dep (edid-decode) isn't on PATH.
##
## The ``--buildtype=release`` flag is the constructor's default
## (matches the sibling from-source recipes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libdisplayInfoSource:
  ## From-source libdisplay-info — closes the M9.R.58 wlroots
  ## DRM-backend gap (paired with hwdata via M9.R.59.1).
  ##
  ## Small C library + a small CLI; single library artifact + one
  ## executable per the upstream meson build.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## freedesktop.org gitlab release tarball URL so a future
    ## maintainer running ``repro update-source`` can re-fetch from
    ## upstream; the live ``fetch:`` block below points at the
    ## vendored copy for deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream freedesktop.org
    ## gitlab project — libdisplay-info's canonical home.
    "0.2.0":
      sourceRevision = "0.2.0"
      sourceUrl = "https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/0.2.0/downloads/libdisplay-info-0.2.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/emersion/libdisplay-info"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the
    ## network is unavailable; the convention layer's argv carries
    ## this URL verbatim so the engine's content-addressed cache
    ## fingerprint stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 95,280-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/0.2.0/downloads/libdisplay-info-0.2.0.tar.xz"
    sha256: "5a2f002a16f42dd3540c8846f80a90b8f4bdcd067a94b9d2087bc2feae974176"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson
    ## convention's configure action invokes ``meson setup``.
    "meson >=0.57"
    ## ninja is meson's default backend — the compile action
    ## invokes ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — libdisplay-info is plain C11
    ## with a modest compiler-flag surface (-Wundef,
    ## -Wmissing-prototypes, -Wdeclaration-after-statement,
    ## -Wconversion — nothing exotic).
    "gcc >=7"
    ## pkg-config is required by libdisplay-info's meson probe for
    ## hwdata (native: true; used to locate pnp.ids at build time).
    "pkg-config"
    ## python3 runs the ``tool/gen-search-table.py`` custom_target
    ## that synthesizes ``pnp-id-table.c`` from
    ## ``$hwdata_dir/pnp.ids`` at build time. Meson's find_program
    ## consumes the python3 shebang line at the top of the script.
    "python3"

  buildDeps:
    ## hwdata is a BUILD-TIME dep (native: true in the meson
    ## probe): libdisplay-info's meson.build reads hwdata's
    ## pkgdatadir via pkg-config to locate pnp.ids at compile time,
    ## then runs a Python script over it to synthesize the
    ## pnp-id-table.c PnP-vendor lookup source file that gets
    ## linked into libdisplay-info.so. Without hwdata on
    ## pkg-config, libdisplay-info's fallback path uses the
    ## hardcoded /usr/share/hwdata/pnp.ids literal — which
    ## doesn't exist in the from-source sandbox root and fails
    ## meson setup with "File //usr/share/hwdata/pnp.ids does not
    ## exist." (This behaviour was observed live during
    ## M9.R.59.1's local probe; hwdata's mirror-emit resolves
    ## the .pc file's pkgdatadir to the mirror-absolute path so
    ## meson picks it up correctly on the from-source build.)
    "hwdata"

  config:
    ## No prefix lifted; the meson options are inlined in the
    ## ``build:`` block below.
    discard

  library libdisplayInfo:
    ## ``libdisplay-info.so`` — the EDID/DisplayID parsing library
    ## that wlroots' DRM backend links against for
    ## monitor-descriptor parsing. v1 records the artifact only;
    ## the per-artifact build body lands in M9.L when the
    ## convention's ninja-spawn + install-glue closes.
    discard

  executable diEdidDecode:
    ## ``di-edid-decode`` — CLI debugging tool that dumps parsed
    ## EDID/DisplayID as human-readable text. Not consumed by
    ## wlroots but shipped alongside the library per the upstream
    ## convention. Registered under the DSL identifier
    ## ``diEdidDecode`` to avoid a Nim identifier collision with
    ## the ``libdisplayInfo`` library name.
    discard

  build:
    ## M9.R.5b — explicit ``build:`` block. Calls the M9.R.2b
    ## high-level ``meson_package(...)`` constructor.
    setCurrentOwningPackageOverride("libdisplayInfoSource")
    try:
      let opts = @[
        # M9.R.57.4 — pin libdir=lib so libdisplay-info's install
        # landing matches every other sibling recipe (libinput,
        # libseat, mesa uses libdir=lib64, but wlroots' pkg-config
        # search-path handling covers both). Without this meson
        # defaults to lib64 on x86_64 hosts, which drops
        # libdisplay-info.so under usr/lib64/ instead of usr/lib/.
        "libdir=lib",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libdisplayInfo")
      discard pkg.executable("di-edid-decode")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
