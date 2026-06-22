## DSL-port M9.R.10a — system-tool stdlib aggregator.
##
## Re-exports the stub stdlib packages for common system / GNU build
## tools so any recipe that ``import repro_dsl_stdlib/constructors`` or
## ``import repro_dsl_stdlib/packages/system_tools`` automatically pulls
## them into the ``registeredPackages()`` set the project-interface
## extractor (``toInterfaceToolUse``) walks for provisioning metadata.
##
## Without this aggregator, every recipe whose ``nativeBuildDeps:`` /
## ``buildDeps:`` references one of these tools (e.g. ``"texinfo"``,
## ``"perl"``, ``"bison"``) would need a direct ``import
## repro_dsl_stdlib/packages/<name>`` AND that import has to land BEFORE
## the ``package <recipeName>:`` macro fires — otherwise the
## provisioning blocks never reach the InterfaceToolUse and the
## from-source resolver hard-fails with "no stdlib provisioning channel
## declared on the tool use".
##
## Aggregator scope: bootstrap GNU tools + common system libs +
## widely-used dev-tools that appear in 80+ source recipes'
## nativeBuildDeps / buildDeps. The KF6 / Qt6 sub-package aggregator
## lives separately to keep the import cost of plain non-KDE recipes
## bounded.

import ./bc
import ./bison
import ./file
import ./flex
import ./gperf
import ./m4
import ./perl
import ./rsync
import ./swig
import ./texinfo
# M9.R.14d.4 — the bootstrap C/C++ toolchain + ninja + pkg-config
# belong in the system-tools aggregator too: recipes whose only
# `import` line is `repro_dsl_stdlib/packages/system_tools` (the
# `from-source-custom` shell-script recipes like ninja itself, plus
# every recipe whose build calls compose shell actions directly) need
# the gcc / ninja / make / pkg-config provisioning blocks registered
# at compile time so their `nativeBuildDeps: "gcc"` use-defs carry
# the stdlib nix channel through to the cycle-break fall-through.
import ./gcc
import ./ninja
import ./make
import ./pkg_config
import ./gmp
import ./mpfr
import ./mpc
import ./libpng
import ./libjpeg
import ./libtiff
import ./libelf
import ./libevdev
import ./libudev
import ./libgpg_error
import ./libacl
import ./libcrypt
import ./libltdl
import ./libseccomp
import ./mtdev
import ./pcre2
import ./fribidi
import ./gjs
import ./shared_mime_info
import ./wayland_protocols
# M9.R.15o.3 — wayland-scanner is the protocol-stub code generator
# kio's transitive dep kwindowsystem invokes at build time. The
# sibling wayland recipe ships the binary; this stub exposes it via
# the Nix channel for recipes that don't already have a sibling.
import ./wayland_scanner
import ./linux_headers
import ./python3
import ./runquotad
# M9.R.15b.5 — gtk-update-icon-cache is referenced by adwaita-icon-theme
# (and any other icon-theme recipe) as a native build dep at meson-setup
# time. Routed through gtk3's bin/ for v1 (gtk4 not yet from-source).
import ./gtk_update_icon_cache
# M9.R.15b.2 — sassc is referenced by gtk4's nativeBuildDeps for Sass
# stylesheet compilation of the Adwaita default theme.
import ./sassc
# M9.R.15d.1 — libegl-headers exposes the Khronos EGL header set
# (EGL/egl.h + EGL/eglext.h + EGL/eglplatform.h) via nixpkgs#libglvnd.dev.
# Consumed by libepoxy's egl=yes meson option and downstream by gtk4 /
# qt6 OpenGL backends.
import ./libegl_headers
# M9.R.15d.2 — python3-with-modules wraps python3 with the
# setuptools + mako + markdown modules consumed by
# gobject-introspection's build-time scanner.
import ./python3_with_modules
# M9.R.15e.3 — gsettings-desktop-schemas surfaces the canonical GNOME
# GSettings .gschema.xml definitions (a11y, calendar, default-apps,
# input-sources, lockdown, peripherals, privacy, screen, sound, system,
# thumbnailers). Consumed by mutter (47.x src/meson.build:116) and
# gnome-shell. Pure-data; nixpkgs prebuilt is byte-identical to
# from-source so we keep this as a stdlib stub.
import ./gsettings_desktop_schemas
# M9.R.15e.4 — mutter 47.x's src/meson.build declares unconditional
# dependencies on: atk (line 126), colord (127), lcms2 (128), libeis
# (130), libei (131), gl/egl/glesv2 (189/195/209), libgbm (251),
# gudev (237), udev (238).  Each stub points at nixpkgs; the
# multi-output resolver walks ^* to pick up the .pc files in the
# -dev outputs.  The libei stub covers both libei-1.0.pc and
# libeis-1.0.pc (the nixpkgs#libei derivation ships both).
import ./atk
import ./colord
import ./lcms2
import ./libei
import ./libeis
import ./gl_egl_glesv2
import ./libgbm
import ./libgudev
import ./udev
# M9.R.15e.7 — mutter's native KMS/DRM backend invokes ``cvt`` (the
# VESA video-timings calculator) at compile time to generate the
# default-modes header. Routed through nixpkgs#libxcvt's bin/cvt.
import ./cvt
# M9.R.15e.10 — accountsservice is gdm 47.x's user-account D-Bus
# daemon dep (meson.build:69). Pure-runtime dep; routed via the
# nixpkgs prebuilt rather than a from-source recipe (the upstream
# build needs polkit + vala + dbus-daemon at configure-time).
import ./accountsservice
# M9.R.15e.12 — json-glib is gdm 47.x's GLib-style JSON library dep
# (meson.build:67).
import ./json_glib
# M9.R.15g.2 — itstool is the XML-to-PO translator GNOME projects
# (incl. gdm 47.x) use to localise DocBook user help.  gdm's
# ``src/docs/meson.build:1`` runs ``find_program('itstool')`` and
# fails the configure when missing.
import ./itstool
# M9.R.15g.2 — libsystemd is gdm 47.x's logind-provider client library
# (``src/common/gdm-common.c`` includes ``systemd/sd-login.h``).
# Pinned via nixpkgs#systemdMinimal.dev so the include path picks up
# ``systemd/sd-login.h`` + the rest of the ``sd-*`` headers.
import ./libsystemd
# M9.R.15q.4.1 — X11 stdlib stubs (nix-backed) so KF6 / Plasma modules
# that opt into the X11 backend (KX11Extras on kwindowsystem,
# plasma-framework's KX11Extras include) can resolve their X11
# buildDeps. Includes the core libX11 + libxcb client libraries, the
# xcb-util-* family (keysyms/wm/renderutil/image/cursor/util) and the
# canonical xorg extension libraries (libXext + libXfixes + libXrender)
# that kwin's X11 glue + Qt6's X11 platform plugin need.
import ./libx11
import ./libxcb
import ./xcb_util_keysyms
import ./xcb_util_wm
import ./xcb_util_renderutil
import ./xcb_util_image
import ./xcb_util_cursor
import ./xcb_util
import ./libxext
import ./libxfixes
import ./libxrender
# M9.R.15q.4.3 — xorgproto ships the protocol headers (X11/X.h,
# X11/Xatom.h, X11/keysymdef.h, X11/extensions/*). CMake's
# FindX11.cmake probes ``X11/X.h`` (in xorgproto), NOT
## ``X11/Xlib.h`` (in libX11), to set X11_X11_INCLUDE_PATH.
import ./xorgproto
# M9.R.15q.4.3 — libxau ships libXau.so + xau.pc; libxcb's xcb.pc has
# Requires.private: xau so any pkg-config probe through xcb needs it.
import ./libxau
# M9.R.15q.4.6 — libxdmcp ships xdmcp.pc; xcb.pc has
# Requires.private: xau xdmcp so probes through xcb need it.
import ./libxdmcp
# M9.R.15q.4.5 — kwin system-level deps.
import ./libcanberra
import ./libepoxy
import ./libdisplayinfo
import ./hwdata

export bc
export bison
export file
export flex
export gperf
export m4
export perl
export rsync
export swig
export texinfo
export gcc
export ninja
export make
export pkg_config
export gmp
export mpfr
export mpc
export libpng
export libjpeg
export libtiff
export libelf
export libevdev
export libudev
export libgpg_error
export libacl
export libcrypt
export libltdl
export libseccomp
export mtdev
export pcre2
export fribidi
export gjs
export shared_mime_info
export wayland_protocols
export wayland_scanner
export linux_headers
export python3
export runquotad
export gtk_update_icon_cache
export sassc
export libegl_headers
export python3_with_modules
export gsettings_desktop_schemas
export atk
export colord
export lcms2
export libei
export libeis
export gl_egl_glesv2
export libgbm
export libgudev
export udev
export cvt
export accountsservice
export json_glib
export itstool
export libsystemd
export libx11
export libxcb
export xcb_util_keysyms
export xcb_util_wm
export xcb_util_renderutil
export xcb_util_image
export xcb_util_cursor
export xcb_util
export libxext
export libxfixes
export libxrender
export xorgproto
export libxau
export libxdmcp
export libcanberra
export libepoxy
export libdisplayinfo
export hwdata
