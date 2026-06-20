## DSL-port M9.R.14d.3 — ``meson_package`` (and ``autotools_package``)
## auto-import the bootstrap toolchain so the cycle-break stdlib
## fall-through resolves.
##
## ## Context
##
## ``nativeBuildDeps: "gcc >=7"`` on the wayland recipe traps the
## auto-recurse dispatcher: it finds the sibling gcc source recipe,
## detects a cycle (gcc → binutils → gcc), marks ``gcc`` in
## ``fromSourceCycleBrokenTools`` (M9.R.10a), then falls through to
## ``tryResolveStdlibProvisioning`` which reads ``useDef.nixProvisioning``
## off the recipe-side ``InterfaceToolUse``. That sequence requires
## the stdlib ``package gcc:`` block to be in
## ``registeredPackages()`` at provider-compile time, OR the dep is
## lost.
##
## ``autotools_package`` (M9.R.14c.9) and now ``meson_package``
## (M9.R.14d.3) import the relevant stdlib packages so a recipe that
## consumes either constructor automatically lands the provisioning
## blocks in the registered set.
##
## ## What this test pins
##
##   1. ``meson_package``'s imports include gcc + ninja + make +
##      pkg_config (the bootstrap floor that meson-driven recipes
##      depend on).
##   2. ``autotools_package``'s imports include gcc + pkg_config.
##   3. The imported packages are registered with non-empty nix
##      provisioning blocks (so the cycle-break fall-through has
##      something to consume on a Nix host).

import std/[strutils, unittest]

const MesonPackageSrc =
  staticRead("../../libs/repro_dsl_stdlib/src/repro_dsl_stdlib/" &
    "constructors/meson_package.nim")
const AutotoolsPackageSrc =
  staticRead("../../libs/repro_dsl_stdlib/src/repro_dsl_stdlib/" &
    "constructors/autotools_package.nim")

suite "DSL-port M9.R.14d.3 — meson/autotools_package auto-imports":

  test "meson_package imports gcc + ninja + make + pkg_config":
    check MesonPackageSrc.contains("import ../packages/gcc")
    check MesonPackageSrc.contains("import ../packages/ninja")
    check MesonPackageSrc.contains("import ../packages/make")
    check MesonPackageSrc.contains("import ../packages/pkg_config")

  test "autotools_package imports gcc + pkg_config":
    check AutotoolsPackageSrc.contains("import ../packages/gcc")
    check AutotoolsPackageSrc.contains("import ../packages/pkg_config")
    # Existing M9.R.14c.9 imports must remain.
    check AutotoolsPackageSrc.contains("import ../packages/autoconf")
    check AutotoolsPackageSrc.contains("import ../packages/automake")
    check AutotoolsPackageSrc.contains("import ../packages/libtool")
    check AutotoolsPackageSrc.contains("import ../packages/m4")
    check AutotoolsPackageSrc.contains("import ../packages/perl")
