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
# M9.R.15q.9.2 — qt6-positioning prebuilt-nix channel; from-source
# sibling lives at recipes/packages/source/qt6-positioning.
import ./qt6_positioning
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
# M9.R.15q.9.2 — plasma-workspace's KF6 + Plasma dep family
# (CMakeLists.txt find_package probes). qcoro6 + kparts + krunner +
# knotifyconfig + kwallet + kprison + ktextwidgets + ksysguard +
# layer-shell-qt + phonon4qt6 + plasma5support + plasma-activities-
# stats + kscreen + breeze; kpipewire + kglobalacceld + kscreenlocker
# already lifted in earlier M9.R.15q.4 / M9.R.15q.6 waves.
import ./qcoro6
import ./kparts
import ./krunner
import ./knotifyconfig
import ./kwallet
import ./kprison
import ./ktextwidgets
import ./ksysguard
import ./layer_shell_qt
import ./phonon4qt6
import ./plasma5support
import ./plasma_activities_stats
import ./kscreen
import ./breeze
# M9.R.15q.9.8 — three more required plasma-workspace KF6 components
# (UnitConversion, TextEditor, StatusNotifierItem) surfaced after
# Plasma + KIO + KParts cleared via the M9.R.15q.9.2 stub batch.
import ./kunitconversion
import ./ktexteditor
import ./kstatusnotifieritem
# M9.R.15q.9.9 — sonnet is ktextwidgets's transitive find_package
# dep at configure time (KF6TextWidgets's CMake config calls
# find_dependency(KF6Sonnet)).
import ./sonnet
# M9.R.15q.10.7d — qrencode is a kprison build-time hard dep
# (CMakeLists declares ``find_package(QRencode REQUIRED)``).
import ./qrencode
# M9.R.15q.11.1 — libnl + lm-sensors are ksysguard's two REQUIRED
# non-KF6 deps (CMakeLists.txt declares
## ``find_package(NL)`` + ``find_package(Sensors)`` with
## ``TYPE REQUIRED``).
import ./libnl
import ./lm_sensors

export qt6_tools
export qt6_declarative
export qt6_svg
export qt6_positioning
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
export qcoro6
export kparts
export krunner
export knotifyconfig
export kwallet
export kprison
export ktextwidgets
export ksysguard
export layer_shell_qt
export phonon4qt6
export plasma5support
export plasma_activities_stats
export kscreen
export breeze
export kunitconversion
export ktexteditor
export kstatusnotifieritem
export sonnet
export qrencode
export libnl
export lm_sensors
