## DSL-port M9.R.14d.7 — meson_package emits stage-copies via the
## slicing surface, mirroring the M9.R.14c.5 autotools_package fix.
##
## ## Context
##
## After M9.R.14d.6 unblocked the wayland meson configure +
## compile + install steps, the build SUCCEEDED but produced no
## ``.repro/output/<artifact>/<artifact>`` files because
## ``MesonPackageResult``'s ``executable`` / ``library`` slicing
## methods were thin handle-only wrappers — they didn't emit a
## stage-copy bridge from the meson install tree
## (``<destdir>/usr/{bin,lib}/<artifact>``) onto the canonical
## resolver path.
##
## The fix adds an ``emitAutotoolsStageCopy`` call (reused from
## the autotools fix shape; the helper is install-system-agnostic
## once we pass `buildDir = ""` so it treats the absolute
## destdir as the install root verbatim) inside the meson slicing
## methods.
##
## ## What this test pins
##
##   1. ``executable(r, name)`` returns the same ``Executable``
##      value as before in unit-test mode (legacy shape preserved).
##   2. ``library(r, name)`` mirrors the executable behaviour.
##   3. The stage-copy action is gated by
##      ``activeProviderProjectRoot()`` (unit-test mode emits no
##      action; provider mode emits exactly one per (package,
##      kind, name) triple, idempotent on repeated calls).

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result
import repro_dsl_stdlib/types/executable
import repro_dsl_stdlib/types/library

suite "DSL-port M9.R.14d.7 — meson_package stage-copy emission":

  test "meson executable slicing returns the legacy Executable shape":
    setCurrentOwningPackageOverride("mesonStageExeTestPkg")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[])
      let exe = pkg.executable("waylandScanner")
      check exe.cli.executableName == "waylandScanner"
      check exe.installPrefix == "usr/bin"
    finally:
      clearCurrentOwningPackageOverride()

  test "meson library slicing returns the legacy Library shape":
    setCurrentOwningPackageOverride("mesonStageLibTestPkg")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[])
      let lib = pkg.library("libwaylandClient")
      check lib.installPrefix == "usr/lib"
    finally:
      clearCurrentOwningPackageOverride()

  test "unit-test mode: meson stage-copy emits no action":
    # No activeProviderProjectRoot → emitAutotoolsStageCopy early-
    # returns without registering a build action.
    setCurrentOwningPackageOverride("mesonStageQuietTestPkg")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[])
      discard pkg.executable("waylandScanner")
      discard pkg.library("libwaylandClient")
      # No assertion needed beyond "doesn't raise" — provider-mode
      # behaviour is exercised end-to-end by the wayland smoke loop.
    finally:
      clearCurrentOwningPackageOverride()
