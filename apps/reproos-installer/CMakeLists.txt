# M9.R.18.4 -- ReproOS Installer Qt6/QML CMakeLists.
#
# Per ReproOS-Installer-PRD.md Sec 7.1 the installer is a Qt6 + QML app
# (Wayland-native). This CMakeLists.txt is the build entry point that
# the reprobuild from-source recipe in repro.nim wraps via the M9.K
# c_cpp_cmake convention. The binary is installed at
# /usr/bin/reproos-installer; the launcher script at
# /usr/bin/reproos-installer-launcher (M9.R.18.1) execs it.
#
# Standalone-buildable shape: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
# && cmake --build build` produces the binary against the host Qt6, given
# Qt6Core / Qt6Gui / Qt6Quick / Qt6QuickControls2 are findable.

cmake_minimum_required(VERSION 3.16)

project(reproos-installer
    VERSION 0.1.0
    DESCRIPTION "ReproOS first-boot installer wizard"
    LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Per PRD Sec 7.1 we need Qt6 base + qtdeclarative + qtwayland. The
# wizard's UI lives in QML so QtQuick + QtQuickControls2 are mandatory.
# QtWayland is required at runtime (the live ISO's sway session) but
# CMake doesn't link against it -- it's loaded via the QPA plugin.
find_package(Qt6 6.6 REQUIRED COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2)

qt_standard_project_setup(REQUIRES 6.6)

qt_add_executable(reproos-installer
    src/main.cpp
    src/installer_state.cpp
    src/installer_state.h)

# The QML files ship as a Qt resource so the binary is fully self-
# contained (no /usr/share/reproos-installer/qml/ needed). qt_add_qml_module
# would be the modern shape, but it requires extra plumbing for the
# Connections-in-Component pattern Summary.qml uses; the .qrc path is
# simpler for v0.1.
qt_add_resources(reproos-installer "qml-resources"
    PREFIX "/"
    FILES
        qml/main.qml
        qml/screens/Welcome.qml
        qml/screens/Locale.qml
        qml/screens/Keyboard.qml
        qml/screens/Users.qml
        qml/screens/DeSelect.qml
        qml/screens/Activities.qml
        qml/screens/Summary.qml
        qml/screens/Install.qml
        qml/screens/Finished.qml)

target_link_libraries(reproos-installer PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2)

target_include_directories(reproos-installer PRIVATE src)

include(GNUInstallDirs)
install(TARGETS reproos-installer
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# Companion data files -- activity catalog TOML, locale data, DE options.
# v0.1 ships placeholders; M9.R.19 populates them and switches the QML
# screens to read these instead of the inline catalogs.
install(DIRECTORY data/
    DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/reproos-installer
    FILES_MATCHING PATTERN "*.toml")
