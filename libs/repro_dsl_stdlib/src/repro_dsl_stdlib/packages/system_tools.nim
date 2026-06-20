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
