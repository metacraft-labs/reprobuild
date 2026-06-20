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
import ./libseccomp
import ./mtdev
import ./pcre2
import ./fribidi
import ./gjs
import ./shared_mime_info
import ./wayland_protocols
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
export libseccomp
export mtdev
export pcre2
export fribidi
export gjs
export shared_mime_info
export wayland_protocols
export linux_headers
export python3
export runquotad
export gtk_update_icon_cache
export sassc
export libegl_headers
export python3_with_modules
