## Source build for libX11, the client-side X protocol library required by
## Xwayland and the remaining X11 compatibility surface in ReproOS.
## Version and source hash match the workspace's pinned nixpkgs libX11.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libx11Source:
  versions:
    "1.8.12":
      sourceRevision = "libX11-1.8.12"
      sourceUrl = "https://www.x.org/releases/individual/lib/libX11-1.8.12.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libx11"

  fetch:
    url: "https://www.x.org/releases/individual/lib/libX11-1.8.12.tar.xz"
    sha256: "fa026f9bb0124f4d6c808f9aef4057aad65e7b35d8ff43951cef0abe06bb9a9a"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    ## Protocol headers and transport macros are source-built siblings.
    "xorgproto"
    "xtrans"
    ## libX11 implements Xlib over XCB. This remains a Nix-provisioned
    ## dependency until the XCB protocol generator stack is migrated.
    "libxcb >=1.11.1"

  config:
    discard

  library libX11:
    discard

  build:
    setCurrentOwningPackageOverride("libx11Source")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libX11")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## libX11.so delegates wire-protocol transport to libxcb.so.
    "libxcb >=1.11.1"
