## DSL-port M9.R.33.2 — Auto-thread Qt6 FindXxx.cmake module dirs into
## CMAKE_MODULE_PATH + emit GLESv2 hints for fresh-configure
## correctness.
##
## ## Context
##
## M9.R.32 surfaced this gap: a fresh
## ``rm -rf recipes/packages/source/plasma-workspace/.repro/build &&
## repro build recipes/packages/source/plasma-workspace`` failed at
## cmake configure time with:
##
##   By not providing "FindPlatformGraphics.cmake" in CMAKE_MODULE_PATH
##   this project has asked CMake to find a package configuration file
##   provided by "PlatformGraphics", but CMake did not find one.
##
## and:
##
##   Could NOT find GLESv2 (missing: GLESv2_LIBRARY GLESv2_INCLUDE_DIR
##   HAVE_GLESv2)
##
## The fix shape lifted to ``cmake_package`` via M9.R.33.2 threads
## ``CMAKE_MODULE_PATH`` from every Qt6* dep's ``cmake/Qt6/`` +
## ``cmake/Qt6/platforms/`` dirs AND emits explicit
## ``GLESv2_INCLUDE_DIR`` + ``GLESv2_LIBRARY`` hints when mesa's
## install-mirror exists on disk.
##
## ## What this test pins
##
##   1. ``m9r33Collect2Qt6CmakeModulePathDirs`` enumerates the
##      ``cmake/Qt6/`` + ``cmake/Qt6/platforms/`` dirs for every qt6-*
##      dep with the appropriate on-disk layout.
##   2. The helper is inert when no qt6-* dep is declared.
##   3. The helper is inert when ``projectRoot`` is empty (unit-test
##      mode).
##   4. The helper skips the platforms sub-dir when it doesn't exist on
##      disk (older Qt6 versions don't ship it).
##   5. ``m9r33Emit2CmakeModulePathCacheVar`` formats the dir list as
##      a semicolon-joined ``CMAKE_MODULE_PATH=...`` entry.
##   6. ``m9r33Emit2MesaGlesv2CacheVars`` emits ``GLESv2_INCLUDE_DIR``
##      + ``GLESv2_LIBRARY`` hints when a qt6-* dep is present AND
##      mesa's install-mirror ships the GLES2 headers + libGLESv2.so.
##   7. ``m9r33Emit2MesaGlesv2CacheVars`` is inert when no qt6-* dep
##      is declared, when projectRoot is empty, or when mesa's mirror
##      is absent.
##   8. Determinism: two invocations against the same on-disk graph
##      produce identical output ordering.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/types/package_result
import repro_project_dsl

proc layQt6CmakeRoot(root, depName: string;
                     withPlatforms: bool = true) =
  ## Lay down a synthetic Qt6 install-mirror cmake/Qt6/ tree (and
  ## optionally a platforms/ sub-dir) so the helper's ``dirExists``
  ## probes return true.
  let qt6Root = root / depName / ".repro" / "output" / "install" /
    "usr" / "lib" / "cmake" / "Qt6"
  createDir(qt6Root)
  # FindGLESv2.cmake lives at the Qt6 root in real qt6-base.
  writeFile(qt6Root / "FindGLESv2.cmake", "# synthetic FindGLESv2\n")
  if withPlatforms:
    let platforms = qt6Root / "platforms"
    createDir(platforms)
    writeFile(platforms / "FindPlatformGraphics.cmake",
      "# synthetic FindPlatformGraphics\n")

proc layMesaGlesv2Install(root: string) =
  ## Lay down a synthetic mesa install-mirror with the GLESv2 headers +
  ## shared object so ``m9r33Emit2MesaGlesv2CacheVars``'s on-disk
  ## probes return true.
  let mesaRoot = root / "mesa" / ".repro" / "output" / "install" /
    "usr"
  createDir(mesaRoot / "include" / "GLES2")
  writeFile(mesaRoot / "include" / "GLES2" / "gl2.h",
    "/* synthetic gl2.h */\n")
  createDir(mesaRoot / "lib64")
  writeFile(mesaRoot / "lib64" / "libGLESv2.so",
    "/* synthetic shared object */\n")

suite "DSL-port M9.R.33.2 — Qt6 CMAKE_MODULE_PATH + GLESv2 hint walker":

  test "collects_qt6_root_and_platforms_dirs_when_qt6_dep_present":
    let scratch = createTempDir("repro-m9r33-2-collect-", "")
    defer: removeDir(scratch)

    layQt6CmakeRoot(scratch, "qt6-base", withPlatforms = true)

    resetDslPortPackageDepsState()
    let pkgName = "m9r332CollectPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    registerPackageDep(pkgName, "build", "kconfig >=6.0")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let dirs = m9r33Collect2Qt6CmakeModulePathDirs(projectRoot, pkgName)

    check dirs.len == 2
    check dirs[0].endsWith("/qt6-base/.repro/output/install/usr/lib/cmake/Qt6")
    check dirs[1].endsWith(
      "/qt6-base/.repro/output/install/usr/lib/cmake/Qt6/platforms")

  test "inert_when_no_qt6_dep_declared":
    let scratch = createTempDir("repro-m9r33-2-noqt6-", "")
    defer: removeDir(scratch)

    layQt6CmakeRoot(scratch, "qt6-base", withPlatforms = true)

    resetDslPortPackageDepsState()
    let pkgName = "m9r332NoQt6Pkg"
    # No qt6-* dep declared — only kconfig.
    registerPackageDep(pkgName, "build", "kconfig >=6.0")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let dirs = m9r33Collect2Qt6CmakeModulePathDirs(projectRoot, pkgName)

    check dirs.len == 0

  test "inert_when_project_root_empty":
    resetDslPortPackageDepsState()
    let pkgName = "m9r332EmptyPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    let dirs = m9r33Collect2Qt6CmakeModulePathDirs("", pkgName)
    check dirs.len == 0

  test "skips_platforms_subdir_when_absent":
    # Older Qt6 versions don't ship the platforms/ sub-dir; the
    # collector must skip it gracefully without erroring out.
    let scratch = createTempDir("repro-m9r33-2-noplat-", "")
    defer: removeDir(scratch)

    layQt6CmakeRoot(scratch, "qt6-base", withPlatforms = false)

    resetDslPortPackageDepsState()
    let pkgName = "m9r332NoPlatformsPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let dirs = m9r33Collect2Qt6CmakeModulePathDirs(projectRoot, pkgName)

    check dirs.len == 1
    check dirs[0].endsWith("/qt6-base/.repro/output/install/usr/lib/cmake/Qt6")

  test "emits_semicolon_joined_cmake_module_path":
    let entry = m9r33Emit2CmakeModulePathCacheVar(
      @["/some/qt6-base/cmake/Qt6", "/some/qt6-base/cmake/Qt6/platforms"])
    check entry == "CMAKE_MODULE_PATH=/some/qt6-base/cmake/Qt6;" &
      "/some/qt6-base/cmake/Qt6/platforms"

  test "empty_input_returns_empty_string":
    let entry = m9r33Emit2CmakeModulePathCacheVar(@[])
    check entry == ""

  test "emits_glesv2_hints_when_mesa_mirror_present":
    let scratch = createTempDir("repro-m9r33-2-glesv2-", "")
    defer: removeDir(scratch)

    layMesaGlesv2Install(scratch)
    # qt6-base also needs to exist so the helper recognises this as a
    # Qt6Gui consumer (gated on a qt6-* dep being declared).
    layQt6CmakeRoot(scratch, "qt6-base", withPlatforms = true)

    resetDslPortPackageDepsState()
    let pkgName = "m9r332Glesv2Pkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let entries = m9r33Emit2MesaGlesv2CacheVars(projectRoot, pkgName)

    check entries.len == 2
    var sawInclude = false
    var sawLibrary = false
    for entry in entries:
      if entry.startsWith("GLESv2_INCLUDE_DIR="):
        sawInclude = true
        check entry.endsWith("/mesa/.repro/output/install/usr/include")
      if entry.startsWith("GLESv2_LIBRARY="):
        sawLibrary = true
        check entry.endsWith(
          "/mesa/.repro/output/install/usr/lib64/libGLESv2.so")
    check sawInclude
    check sawLibrary

  test "glesv2_hints_inert_when_no_qt6_dep":
    let scratch = createTempDir("repro-m9r33-2-glnoqt6-", "")
    defer: removeDir(scratch)

    layMesaGlesv2Install(scratch)

    resetDslPortPackageDepsState()
    let pkgName = "m9r332GlNoQt6Pkg"
    # No qt6-* dep declared.
    registerPackageDep(pkgName, "build", "kconfig >=6.0")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let entries = m9r33Emit2MesaGlesv2CacheVars(projectRoot, pkgName)

    check entries.len == 0

  test "glesv2_hints_inert_when_mesa_mirror_absent":
    let scratch = createTempDir("repro-m9r33-2-glnomesa-", "")
    defer: removeDir(scratch)

    # qt6-base present but mesa is NOT laid down.
    layQt6CmakeRoot(scratch, "qt6-base", withPlatforms = true)

    resetDslPortPackageDepsState()
    let pkgName = "m9r332GlNoMesaPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let entries = m9r33Emit2MesaGlesv2CacheVars(projectRoot, pkgName)

    check entries.len == 0

  test "glesv2_hints_inert_when_project_root_empty":
    resetDslPortPackageDepsState()
    let pkgName = "m9r332GlEmptyPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")
    let entries = m9r33Emit2MesaGlesv2CacheVars("", pkgName)
    check entries.len == 0

  test "determinism_two_invocations_produce_identical_output":
    let scratch = createTempDir("repro-m9r33-2-det-", "")
    defer: removeDir(scratch)

    layQt6CmakeRoot(scratch, "qt6-base", withPlatforms = true)
    layMesaGlesv2Install(scratch)

    resetDslPortPackageDepsState()
    let pkgName = "m9r332DetPkg"
    registerPackageDep(pkgName, "build", "qt6-base >=6.6")

    let projectRoot = scratch / pkgName
    createDir(projectRoot)
    let dirs1 = m9r33Collect2Qt6CmakeModulePathDirs(projectRoot, pkgName)
    let dirs2 = m9r33Collect2Qt6CmakeModulePathDirs(projectRoot, pkgName)
    check dirs1 == dirs2
    let glesv21 = m9r33Emit2MesaGlesv2CacheVars(projectRoot, pkgName)
    let glesv22 = m9r33Emit2MesaGlesv2CacheVars(projectRoot, pkgName)
    check glesv21 == glesv22
