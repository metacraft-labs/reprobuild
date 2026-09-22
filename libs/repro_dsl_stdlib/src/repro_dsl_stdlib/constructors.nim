## DSL-port M9.R.2b — Layer-1 high-level constructor aggregator.

import ./constructors/c_library
import ./constructors/c_executable
import ./constructors/nim_library
import ./constructors/nim_executable
import ./constructors/meson_package
import ./constructors/cmake_package
import ./constructors/autotools_package
import ./constructors/cargo_package
import ./constructors/go_package
import ./constructors/node_package
# Pull the node / npm provisioning packages into every recipe that imports
# ``constructors`` so a from-source-npm recipe's ``nativeBuildDeps: "node"``
# resolves (their provisioning metadata only reaches the InterfaceToolUse once
# the package module is imported in the recipe's compilation unit — the same
# reason ``system_tools`` is pulled in below).
import ./packages/node
import ./packages/npm

# DSL-port M9.R.10a — pull the system-tool stdlib package set into
# ``registeredPackages()`` for every recipe that imports
# ``repro_dsl_stdlib/constructors``. Without this transitive import the
# from-source resolver hard-fails on common ``nativeBuildDeps`` /
# ``buildDeps`` names (texinfo, perl, bison, flex, m4, ...) because the
# provisioning metadata declared on each stdlib package only reaches
# the InterfaceToolUse when the package's module has been imported in
# the recipe's compilation unit.
import ./packages/system_tools
# DSL-port M9.R.10a — KF6 / Qt6 sub-module stubs. Pulled into the
# default constructors surface because every KF6 source recipe imports
# ``constructors`` anyway; the import cost on plain non-KDE recipes is
# bounded (a handful of empty ``package <name>:`` modules) and the
# alternative — adding ``import repro_dsl_stdlib/packages/kf6_qt6_modules``
# to every KF6 recipe by hand — is fragile under future renames.
import ./packages/kf6_qt6_modules

export c_library
export c_executable
export nim_library
export nim_executable
export meson_package
export cmake_package
export autotools_package
export cargo_package
export go_package
export node_package
export node
export npm
export system_tools
export kf6_qt6_modules
