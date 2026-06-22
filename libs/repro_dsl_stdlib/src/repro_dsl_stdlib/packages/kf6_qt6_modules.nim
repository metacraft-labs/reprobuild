## DSL-port M9.R.10a — KF6 / Qt6 sub-module stdlib aggregator.
##
## Re-exports the stub stdlib packages for KDE Frameworks 6 + Qt 6
## sub-modules that surface as ``nativeBuildDeps:`` / ``buildDeps:``
## entries on KF6 source recipes (kio, kded, plasma-*, etc.). Kept
## separate from ``system_tools.nim`` so plain non-KDE recipes don't
## pay the import cost.
##
## Recipes that need to resolve any of these tool names from stdlib
## provisioning should ``import repro_dsl_stdlib/packages/kf6_qt6_modules``
## alongside their existing constructor imports.

import ./qt6_tools
import ./qt6_declarative
import ./qt6_svg
import ./kf6_base
import ./karchive
import ./kbookmarks
import ./kcodecs
import ./kcolorscheme
import ./kcompletion
import ./kconfigwidgets
import ./kcrash
import ./kdbusaddons
import ./kguiaddons
import ./kiconthemes
import ./kitemviews
import ./kjobwidgets
import ./kwindowsystem
# M9.R.15q.4.5 — kwin's Plasma-stack dependency family.
import ./kdecoration2
import ./kwayland
import ./kscreenlocker
import ./kglobalacceld
import ./kpipewire
import ./libqaccessibilityclient

export qt6_tools
export qt6_declarative
export qt6_svg
export kf6_base
export karchive
export kbookmarks
export kcodecs
export kcolorscheme
export kcompletion
export kconfigwidgets
export kcrash
export kdbusaddons
export kguiaddons
export kiconthemes
export kitemviews
export kjobwidgets
export kwindowsystem
export kdecoration2
export kwayland
export kscreenlocker
export kglobalacceld
export kpipewire
export libqaccessibilityclient
