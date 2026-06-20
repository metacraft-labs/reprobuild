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
import ./kf6_base
import ./karchive
import ./kbookmarks
import ./kcompletion
import ./kcrash
import ./kdbusaddons
import ./kguiaddons
import ./kiconthemes
import ./kitemviews
import ./kjobwidgets
import ./kwindowsystem

export qt6_tools
export qt6_declarative
export kf6_base
export karchive
export kbookmarks
export kcompletion
export kcrash
export kdbusaddons
export kguiaddons
export kiconthemes
export kitemviews
export kjobwidgets
export kwindowsystem
