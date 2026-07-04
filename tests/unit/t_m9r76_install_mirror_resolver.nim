## M9.R.76.2 — install-mirror resolver regression tests.
##
## Pins:
##   1. Default mode (env var unset) is ``immLegacy``.
##   2. Legacy mode returns the byte-identical path shape the pre-M9.R.76
##      inline join produced.
##   3. ``REPRO_INSTALL_MIRROR_MODE=hashed`` falls back to legacy when
##      no recipe has opted in (v1 behavior — the hashed emit-side
##      wiring is not landed yet).
##   4. ``REPRO_INSTALL_MIRROR_MODE=hashed-with-legacy-fallback``
##      returns legacy when the hashed prefix does not exist on disk.
##   5. Empty inputs produce empty outputs.
##   6. Lib / pkgconfig / cmake / include / manifest helpers all
##      compose against the same resolved root.

import std/[os, strutils, unittest]

import repro_dsl_stdlib/types/install_mirror_resolver

const RecipesRoot = "/tmp/repro_test/recipes"
const DepName = "wayland"

suite "M9.R.76.2 — install-mirror resolver":

  test "default mode is legacy when env var unset":
    delEnv(InstallMirrorModeEnvVar)
    check currentInstallMirrorMode() == immLegacy

  test "legacy mode returns the pre-M9.R.76 path shape":
    delEnv(InstallMirrorModeEnvVar)
    let root = packageInstallMirrorRoot(RecipesRoot, DepName)
    check root == "/tmp/repro_test/recipes/wayland/.repro/output/install"

  test "empty dep or empty recipes root produces empty output":
    check packageInstallMirrorRoot("", DepName) == ""
    check packageInstallMirrorRoot(RecipesRoot, "") == ""
    check packageInstallMirrorLibDirs("", DepName).len == 0
    check packageInstallMirrorLibDirs(RecipesRoot, "").len == 0
    check packageInstallMirrorPkgConfigDirs("", DepName).len == 0
    check packageInstallMirrorCmakeRoot("", DepName) == ""

  test "lib dirs return both lib and lib64 in POSIX form":
    delEnv(InstallMirrorModeEnvVar)
    let libs = packageInstallMirrorLibDirs(RecipesRoot, DepName)
    check libs.len == 2
    check libs[0] == "/tmp/repro_test/recipes/wayland/.repro/output/install/usr/lib"
    check libs[1] == "/tmp/repro_test/recipes/wayland/.repro/output/install/usr/lib64"

  test "pkgconfig dirs enumerate lib, lib64, and share":
    delEnv(InstallMirrorModeEnvVar)
    let pcs = packageInstallMirrorPkgConfigDirs(RecipesRoot, DepName)
    check pcs.len == 3
    check pcs[0].endsWith("/usr/lib/pkgconfig")
    check pcs[1].endsWith("/usr/lib64/pkgconfig")
    check pcs[2].endsWith("/usr/share/pkgconfig")

  test "cmake root and include dir compose against the resolved root":
    delEnv(InstallMirrorModeEnvVar)
    let cmakeRoot = packageInstallMirrorCmakeRoot(RecipesRoot, DepName)
    let includeDir = packageInstallMirrorIncludeDir(RecipesRoot, DepName)
    check cmakeRoot ==
      "/tmp/repro_test/recipes/wayland/.repro/output/install/usr/lib/cmake"
    check includeDir ==
      "/tmp/repro_test/recipes/wayland/.repro/output/install/usr/include"

  test "manifest path composes with the given filename":
    delEnv(InstallMirrorModeEnvVar)
    let manifest = packageInstallMirrorPropagatedManifestPath(
      RecipesRoot, DepName, ".m9r30_propagated_libdirs.txt")
    check manifest ==
      "/tmp/repro_test/recipes/wayland/.repro/output/install/.m9r30_propagated_libdirs.txt"

  test "hashed mode falls back to legacy path when no recipe has opted in":
    # v1 (this milestone): the hashed emit-side wiring is not landed
    # yet, so ``hashedDepMirrorRoot`` returns "" and the resolver
    # falls back to legacy.
    putEnv(InstallMirrorModeEnvVar, "hashed")
    try:
      check currentInstallMirrorMode() == immHashed
      let root = packageInstallMirrorRoot(RecipesRoot, DepName)
      check root == "/tmp/repro_test/recipes/wayland/.repro/output/install"
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "hashed-with-legacy-fallback returns legacy when hashed absent":
    putEnv(InstallMirrorModeEnvVar, "hashed-with-legacy-fallback")
    try:
      check currentInstallMirrorMode() == immHashedWithLegacyFallback
      let root = packageInstallMirrorRoot(RecipesRoot, DepName)
      check root == "/tmp/repro_test/recipes/wayland/.repro/output/install"
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "unrecognised mode string falls back to legacy":
    putEnv(InstallMirrorModeEnvVar, "some-future-mode")
    try:
      check currentInstallMirrorMode() == immLegacy
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "human-friendly diagnostic path is always the legacy shape":
    # Even when the env is set to hashed, diagnostic messages should
    # print the legacy shape (documented use-case in the resolver
    # module).
    putEnv(InstallMirrorModeEnvVar, "hashed")
    try:
      let path = packageInstallMirrorHumanFriendlyPath(RecipesRoot, DepName)
      check path == "/tmp/repro_test/recipes/wayland/.repro/output/install"
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "paths are POSIX-slashed regardless of host":
    delEnv(InstallMirrorModeEnvVar)
    # Even on Windows-style input the output uses forward slashes so
    # the emitted shell scripts don't need extra escaping.
    let root = packageInstallMirrorRoot(
      "C:\\metacraft\\reprobuild\\recipes\\packages\\source", DepName)
    check '\\' notin root
    check root.contains("/wayland/.repro/output/install")

suite "M9.R.76.4 — read-only enforcement gating":

  test "legacy mode emits empty enforcement snippet":
    # The mutable stable path MUST stay writable in legacy mode so
    # the next rebuild's ``rm -rf`` can clobber it.
    delEnv(InstallMirrorModeEnvVar)
    let snippet = emitInstallMirrorReadOnlyEnforcement("/tmp/some/mirror")
    check snippet == ""
    check installMirrorEnforcesReadOnly() == false

  test "hashed mode emits chmod -R a-w snippet":
    putEnv(InstallMirrorModeEnvVar, "hashed")
    try:
      let snippet = emitInstallMirrorReadOnlyEnforcement("/tmp/some/mirror")
      check snippet.contains("chmod -R a-w")
      check snippet.contains("/tmp/some/mirror")
      check snippet.contains("[ -d ")  # guarded by dir-exists check
      check installMirrorEnforcesReadOnly() == true
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "hashed-with-legacy-fallback mode enforces read-only":
    putEnv(InstallMirrorModeEnvVar, "hashed-with-legacy-fallback")
    try:
      let snippet = emitInstallMirrorReadOnlyEnforcement("/tmp/some/mirror")
      check snippet.contains("chmod -R a-w")
      check installMirrorEnforcesReadOnly() == true
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "empty mirror root produces empty snippet even in hashed mode":
    # Defensive: if the resolver returns "" (e.g. dep name empty),
    # the enforcement snippet should be a no-op, not a syntax error.
    putEnv(InstallMirrorModeEnvVar, "hashed")
    try:
      let snippet = emitInstallMirrorReadOnlyEnforcement("")
      check snippet == ""
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "explicit mode arg overrides env var":
    putEnv(InstallMirrorModeEnvVar, "legacy")
    try:
      # Caller can pin the mode explicitly for the plan-time decision.
      let snippet = emitInstallMirrorReadOnlyEnforcement(
        "/tmp/some/mirror", mode = immHashed)
      check snippet.contains("chmod -R a-w")
      check installMirrorEnforcesReadOnly(mode = immHashed) == true
      check installMirrorEnforcesReadOnly(mode = immLegacy) == false
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "shell path escapes preserve double-quote safety":
    # If a mirror root ever contains a `"` (it shouldn't, but the
    # sanitizer guards against it), the emitted snippet MUST escape
    # it so the shell doesn't misparse the command.
    putEnv(InstallMirrorModeEnvVar, "hashed")
    try:
      let snippet = emitInstallMirrorReadOnlyEnforcement("/tmp/weird\"root")
      # `"` must be `\"` in the emitted script:
      check snippet.contains("\\\"")
    finally:
      delEnv(InstallMirrorModeEnvVar)
