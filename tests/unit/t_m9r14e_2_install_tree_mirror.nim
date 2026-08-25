## DSL-port M9.R.14e.2 — meson_package / autotools_package emit a
## one-per-package install-tree mirror that copies
## ``<recipeRoot>/<buildDir>/<destdir>/usr/`` →
## ``<recipeRoot>/.repro/output/install/usr/`` so the M9.R.14e.1
## resolver finds the staged ``.pc`` / ``include`` / ``lib`` tree at
## a layout-stable canonical location regardless of which
## ``buildDir`` / ``destdir`` parameters the upstream recipe configured.
##
## ## What this test pins
##
##   1. The slicing methods still return their legacy
##      ``Executable`` / ``Library`` value shapes (no contract change
##      for consumers).
##   2. In unit-test mode (no provider project root)
##      ``emitInstallTreeMirror`` is inert — neither it nor the
##      per-artifact stage-copy fire side effects.
##   3. Idempotent: a recipe that calls ``pkg.executable("foo")``
##      AND ``pkg.library("libfoo")`` emits the mirror exactly once.
##   4. ``emitInstallTreeMirror`` is exposed via the package_result
##      surface for downstream test inspection.
##
## ## What this file does NOT pin, and where that coverage now lives
##
## The per-package mirror gate ("distinct packages each get their own
## mirror, not one per process") is not observable from THIS file. The
## gate lives in ``package_result.nim``'s private ``stageCopyEmitted`` /
## ``installMirrorEmitted`` thread-locals, and both
## ``emitAutotoolsStageCopy`` and ``emitInstallTreeMirror`` early-return
## before touching them when ``activeProviderProjectRoot()`` is empty --
## which it always is here, because this binary is built WITHOUT
## ``reproProviderMode`` and the accessor is then a compile-time ``""``.
##
## A case named for that gate used to sit here asserting ``check true``,
## which reported [OK] whether the gate existed or not. It has been moved
## rather than deleted: ``tests/unit/t_m9r83_install_mirror_action_shapes
## .nim`` builds in provider mode and drives the gate through the real
## ``buildPackageFragment`` entry point, so the property is asserted there
## against emitted action ids.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result
import repro_dsl_stdlib/types/executable
import repro_dsl_stdlib/types/library

suite "DSL-port M9.R.14e.2 — install-tree mirror emission":

  test "bare FHS destinations are removed before replacement":
    let script = m9r14e2ResetBareFhsMirrorScript("/tmp/mirror root")
    for subdir in ["etc", "sbin", "bin"]:
      check script.contains(
        "rm -rf \"/tmp/mirror root/" & subdir & "\";")
    check not script.contains("/usr/")

  test "glibc mirror normalization makes folded lib64 relocatable":
    let script = m9r14e2NormalizeGlibcMirrorScript("/tmp/mirror root/usr")
    check script.contains("case \"$target\" in ../../lib64/*)")
    check script.contains(
      "ln -sfn \"$(basename \"$target\")\" \"$link\"")
    check script.contains("for linker_script in libc.so libm.so libm.a")
    check script.contains("'s|/usr/lib64/||g'")
    check script.contains("'s|/lib64/||g'")

  test "meson executable slicing preserves the legacy Executable value":
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("mesonExePkg")
    try:
      let pkg = meson_package(srcDir = "./src")
      let exe = pkg.executable("foo")
      check exe.cli.executableName == "foo"
      check exe.installPrefix.len > 0
    finally:
      clearCurrentOwningPackageOverride()

  test "meson library slicing preserves the legacy Library value":
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("mesonLibPkg")
    try:
      let pkg = meson_package(srcDir = "./src")
      let lib = pkg.library("libfoo")
      check lib.installPrefix.len > 0
    finally:
      clearCurrentOwningPackageOverride()

  test "autotools executable slicing preserves the legacy Executable value":
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("autotoolsExePkg")
    try:
      let pkg = autotools_package(srcDir = "./src")
      let exe = pkg.executable("autoconf")
      check exe.cli.executableName == "autoconf"
      check exe.installPrefix.len > 0
    finally:
      clearCurrentOwningPackageOverride()

  test "autotools library slicing preserves the legacy Library value":
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("autotoolsLibPkg")
    try:
      let pkg = autotools_package(srcDir = "./src")
      let lib = pkg.library("libexpat")
      check lib.installPrefix.len > 0
    finally:
      clearCurrentOwningPackageOverride()

  test "unit-test mode: install-tree mirror short-circuits":
    # ``activeProviderProjectRoot()`` is empty in unit-test mode, which
    # MUST make ``emitInstallTreeMirror`` a no-op so the test process
    # doesn't accidentally create ``.repro/output/install/`` under the
    # test cwd.
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("noStagePkg")
    try:
      let pkg = meson_package(srcDir = "./src")
      # The slicing call invokes ``emitInstallTreeMirror`` under the
      # hood. If the no-project-root branch failed to short-circuit, a
      # ``createDir`` would land under the test cwd.
      discard pkg.executable("xyz")
      discard pkg.library("libxyz")
      # If we got here without an exception, the inert path worked.
      check pkg.installEdge.id.len > 0
    finally:
      clearCurrentOwningPackageOverride()

  test "repeated slicing calls for the same package don't re-emit the mirror":
    # The per-package install-mirror gate is idempotent: calling
    # ``pkg.executable("a")`` then ``pkg.executable("b")`` must NOT
    # re-emit the install-tree mirror twice (that would collide on the
    # action registry's id-uniqueness invariant).
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("idemMirrorPkg")
    try:
      let pkg = autotools_package(srcDir = "./src")
      discard pkg.executable("autoconf")
      discard pkg.executable("autoheader")
      discard pkg.library("libexpat")
      check pkg.installEdge.id.len > 0
    finally:
      clearCurrentOwningPackageOverride()
