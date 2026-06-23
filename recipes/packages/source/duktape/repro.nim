## Source-from-tarball duktape recipe — supports M9.R.26 Gap 3 (polkit
## from-source recipe). polkit's meson build defaults to ``js_engine=
## duktape`` and probes for libduktape.so via pkg-config first, then
## falls back to ``cc.find_library('duktape', has_headers: ['duktape.h'])``.
## Vendoring duktape from-source lets polkit's build complete without
## reaching for a nix-store shim.
##
## ## Why duktape (not mozjs)?
##
## polkit's two supported JS engines are mozjs (Mozilla SpiderMonkey)
## and duktape. mozjs is a full multi-MB JS runtime with a Rust /
## clang dep chain that's far out of scope for v1; duktape is a 3-file
## C library (duktape.c + duktape.h + duk_config.h) that builds in
## seconds with a hand-rolled Makefile.
##
## ## sha256 strategy
##
## Vendored at ``recipes/packages/source/duktape/vendor/duktape-2.7.0.tar.xz``.
##
## sha256 = 90f8d2fa8b5567c6899830ddef2c03f3c27960b11aca222fa17aa7ac613c2890
##  (computed over the 1,026,524-byte tarball).
##
## ## Build shape
##
## duktape ships a single source file (``src/duktape.c``) and a
## reference Makefile (``Makefile.sharedlibrary``) for building the
## shared library. We use the autotools_package constructor in
## ``skipConfigure = true`` mode to copy the source tree into a build
## dir, then drive the upstream Makefile.sharedlibrary directly.
##
## ## Library artifact
##
## duktape emits one shared library (``libduktape.so.207``, SONAME
## ``libduktape.so.207``) plus the duktape pkg-config file.
## Registered as ``libDuktape``.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package duktapeSource:
  ## From-source duktape. Tier-2b custom-Makefile via the
  ## skipConfigure shape of autotools_package.

  versions:
    "2.7.0":
      sourceRevision = "v2.7.0"
      sourceUrl = "https://duktape.org/duktape-2.7.0.tar.xz"
      sourceRepository = "https://github.com/svaarala/duktape"

  fetch:
    url: "https://duktape.org/duktape-2.7.0.tar.xz"
    sha256: "90f8d2fa8b5567c6899830ddef2c03f3c27960b11aca222fa17aa7ac613c2890"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"

  buildDeps:
    discard

  config:
    discard
  library libDuktape:
    discard

  build:
    setCurrentOwningPackageOverride("duktapeSource")
    try:
      # duktape's Makefile.sharedlibrary builds libduktape.so.207 in
      # the source tree. We override INSTALL_PREFIX via the
      # configureOptions channel (which skipConfigure threads through
      # to ``make`` as ``VAR=VALUE`` overrides) so the install lands
      # under our DESTDIR/usr.
      let opts = @[
        "-f", "Makefile.sharedlibrary",
        "INSTALL_PREFIX=/usr",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts,
                                  skipConfigure = true)
      discard pkg.library("libDuktape")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
