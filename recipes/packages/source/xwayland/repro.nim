## Source-from-tarball xwayland recipe — closes M9.R.26 Gap 4.
##
## Xwayland is the X11 server that runs inside a Wayland compositor
## session to host legacy X11 clients (Steam, older Wine apps, every
## non-Wayland-native toolkit). The v1 desktop story is pure-Wayland
## by default, but the live ISO ships xwayland so legacy applications
## launched from a Plasma / GNOME session still work.
##
## ## sha256 strategy
##
## Vendored at ``recipes/packages/source/xwayland/vendor/xwayland-24.1.6.tar.xz``.
##
## sha256 = 737e612ca36bbdf415a911644eb7592cf9389846847b47fa46dc705bd754d2d7
##  (computed over the 1,302,600-byte tarball).
##
## ## Version choice — 24.1.6 (current stable)
##
## xwayland releases are cut at x.org under tags of the form
## ``xwayland-X.Y.Z``. 24.1.6 is the current stable as of mid-2026.
##
## ## Build shape
##
## meson + ninja. The c_cpp_meson convention lowers the fetch + meson
## setup + ninja + install chain.
##
## ## Artifact
##
## xwayland emits a single binary (``/usr/bin/Xwayland``) that the
## Wayland compositor spawns as a child process whenever an X11 client
## connects to the compositor's X11 socket.
##
## ## Honest deferral on leaf deps
##
## xwayland's full from-source closure pulls in a long chain of
## historically-orphaned x.org leaf libraries (libxshmfence,
## libxfont2, libxkbfile, libtirpc, xkeyboard-config, xorgproto,
## xkbcomp). All of those are declared as buildDeps below; their
## resolution at build time still goes through the stdlib nix-stub
## fall-through when no sibling from-source recipe exists, which is
## the M9.R.25 inherited posture. The xwayland recipe SHAPE closes
## the gap at the DSL surface; full-from-source closure of the long
## tail is M9.R.27 work.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xwaylandSource:
  ## From-source xwayland — closes M9.R.26 Gap 4. Tier-2b c_cpp_meson
  ## convention consumer.

  versions:
    "24.1.6":
      sourceRevision = "xwayland-24.1.6"
      sourceUrl = "https://www.x.org/releases/individual/xserver/xwayland-24.1.6.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/xserver"

  fetch:
    url: "https://www.x.org/releases/individual/xserver/xwayland-24.1.6.tar.xz"
    sha256: "737e612ca36bbdf415a911644eb7592cf9389846847b47fa46dc705bd754d2d7"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "python3"

  buildDeps:
    ## Already-from-source siblings.
    "libxkbcommon >=1.5"
    "libdrm >=2.4.110"
    "mesa"
    "pixman >=0.42"
    "wayland >=1.22"
    "wayland-protocols >=1.31"
    ## libxcb is a transitive of every X11 client; the sibling
    ## libxkbcommon recipe declares it too.
    "libxcb"
    ## libtirpc — Sun-RPC userspace, consumed by xwayland's
    ## secure-rpc xauth helpers. Stdlib nix-stub for now.
    "libtirpc"
    ## libxshmfence — synchronisation primitive xwayland's DRI3
    ## codepath uses.
    "libxshmfence"
    ## libxfont2 — historic xorg font helper xwayland's font path
    ## bootstrap requires when no Wayland-side font config is set.
    "libxfont2"
    ## libxkbfile — xkb compose-table reader.
    "libxkbfile"
    ## xorgproto — the X11 protocol headers (defines XProto / XKB /
    ## DRI3 / dri2 / Composite / Damage / Fixes / Render / Randr /
    ## Resource / Present / Scrnsaver / Sync / Xinerama / Xv).
    "xorgproto"
    ## xkbcomp — keymap compiler invoked at run time by xwayland to
    ## translate the wayland session keymap into an X11 keymap.
    "xkbcomp"
    ## xkeyboard-config — the data archive shipping the keymap
    ## rules / models / layouts / variants.
    "xkeyboard-config"
    ## xtrans — transport-layer abstraction; pure-header.
    "xtrans"
    ## libxau — X11 authentication helper (the xauth file format
    ## decoder).
    "libxau"

  config:
    discard
  executable xwaylandBin:
    discard

  build:
    setCurrentOwningPackageOverride("xwaylandSource")
    try:
      let opts = @[
        # Pure-Wayland posture: drop the X11 server's TCP listener
        # and DRI2 (legacy direct rendering, superseded by DRI3).
        "listen_tcp=false",
        # Glamor: GL-accelerated rendering. Enable so X11 clients
        # under a Wayland compositor can use OpenGL.
        "glamor=true",
        # XVFB: the framebuffer-only mode is unused for the
        # compositor-hosted Wayland use case.
        "xvfb=false",
        # Drop optional surfaces.
        "dtrace=false",
        # XKB defaults — match the live ISO's `us` baseline.
        "xkb_default_rules=evdev",
        "xkb_default_model=pc105",
        "xkb_default_layout=us",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("xwaylandBin")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
