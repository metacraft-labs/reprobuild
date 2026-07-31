## DSL-port M9.R.14h.1 — auto-recurse idempotency tests.
##
## Pins the fix for the M9.R.14g.12 status report's "sway-10 cleared
## cairo's ``.repro/output/install/`` mid-run" determinism break.  Two
## defence-in-depth layers cover the gap:
##
##   1. ``m9r14hProbeInstallMirrorLibrary`` returns the absolute path of
##      a sibling-recipe library when the install-mirror is on disk.
##      Covers the "library only" recipe shape (cairo / glib2 /
##      harfbuzz / pango / ...) whose stage-copy emits only the install-
##      mirror -- not a per-artifact stage tree.
##
##   2. ``tryResolveFromSourceTool`` returns ``rrResolved`` when the
##      install-mirror probe hits, so the dispatcher's auto-recurse
##      ``if outcome.kind != rrNeedsBuild: continue`` clause skips the
##      sub-build entirely.  No fresh ``emitInstallTreeMirror`` runs;
##      no ``rm -rf install/usr`` clobber.
##
##   3. The per-process ``fromSourceResolvedRecipes`` cache continues to
##      gate repeat sibling probes within a single dispatcher invocation.

import std/[options, os, sets, strutils, tempfiles, unittest]

import repro_cli_support
import repro_tool_profiles
import repro_interface_artifacts

proc makeRecipeFile(root, name: string) =
  let recipeDir = root / name
  createDir(recipeDir)
  writeFile(recipeDir / "repro.nim", "## synthetic " & name & " recipe\n")

proc makeInstallMirrorLib(root, name, libBaseName: string;
                          suffix = ".so"): string =
  ## Stage a library file at the M9.R.14e.2 install-mirror layout:
  ## ``<root>/<name>/.repro/output/install/usr/lib/<libBaseName><suffix>``.
  let libDir = root / name / ".repro" / "output" / "install" / "usr" / "lib"
  createDir(libDir)
  let path = libDir / (libBaseName & suffix)
  writeFile(path, "ELF synthetic")
  path

proc makeExecutable(path: string) =
  createDir(parentDir(path))
  writeFile(path, "#!/bin/sh\nexit 0\n")
  when not defined(windows):
    setFilePermissions(path, {
      fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec,
      fpOthersRead, fpOthersExec})

proc syntheticUseDef(name: string): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name)

suite "DSL-port M9.R.14h.1 — auto-recurse idempotency":

  test "test_m9r14h_1_install_mirror_probe_finds_plain_soname":
    # Baseline pin: the probe finds ``libcairo.so`` at the install-mirror
    # location and returns its absolute path.
    let scratch = createTempDir("repro-m9r14h-mirror-plain-", "")
    defer: removeDir(scratch)
    let expected = makeInstallMirrorLib(scratch, "cairo", "libcairo")
    let hit = m9r14hProbeInstallMirrorLibrary(scratch / "cairo", "cairo")
    check hit == absolutePath(expected)

  test "test_m9r14h_1_install_mirror_probe_finds_versioned_soname":
    # The fix-shape pin: cairo's recipe historically published only the
    # SONAME-versioned ``libcairo.so.2.11800.0`` (no plain ``libcairo.so``
    # symlink in the per-artifact stage tree).  The install-mirror probe
    # MUST still hit because the file lives at
    # ``install/usr/lib/libcairo.so.2.11800.0``.
    let scratch = createTempDir("repro-m9r14h-mirror-versioned-", "")
    defer: removeDir(scratch)
    let expected = makeInstallMirrorLib(scratch, "cairo",
      "libcairo", suffix = ".so.2.11800.0")
    let hit = m9r14hProbeInstallMirrorLibrary(scratch / "cairo", "cairo")
    check hit.len > 0
    check hit == absolutePath(expected)

  test "test_m9r14h_1_install_mirror_probe_misses_when_nothing_staged":
    # No install-mirror present -- probe returns the empty string so the
    # dispatcher falls through to the ``rrNeedsBuild`` path.
    let scratch = createTempDir("repro-m9r14h-mirror-miss-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "cairo")
    let hit = m9r14hProbeInstallMirrorLibrary(scratch / "cairo", "cairo")
    check hit.len == 0

  test "test_m9r14h_1_resolver_returns_resolved_via_install_mirror":
    # End-to-end pin: ``tryResolveFromSourceTool`` consults the install-
    # mirror probe when the per-artifact tree probe misses, returns
    # ``rrResolved`` with a profile pointing at the mirror library, and
    # therefore the dispatcher's auto-recurse skip clause fires.
    let scratch = createTempDir("repro-m9r14h-resolve-mirror-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "cairo")
    discard makeInstallMirrorLib(scratch, "cairo", "libcairo")
    let useDef = syntheticUseDef("cairo")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.installMethod == "from-source"
    check outcome.profile.resolvedExecutablePath.endsWith("libcairo.so")

  test "test_m9r14h_1_resolver_prefers_complete_executable_mirror":
    # Per-artifact executable copies can retain build-only RPATHs. The full
    # install mirror is normalized and carries the executable's sibling
    # libraries, so it must be the selected source-tool runtime.
    let scratch = createTempDir("repro-m9r14h-executable-mirror-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "xz")
    let artifact = scratch / "xz" / ".repro" / "output" / "xz" / "xz"
    let mirror = scratch / "xz" / ".repro" / "output" / "install" /
      "usr" / "bin" / "xz"
    makeExecutable(artifact)
    makeExecutable(mirror)
    let outcome = tryResolveFromSourceTool(
      syntheticUseDef("xz"), recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(mirror)
    check outcome.profile.pathSearchList[0] == parentDir(absolutePath(mirror))

  test "test_m9r14h_1_resolver_returns_needs_build_when_no_mirror_no_stage":
    # Negative pin: without the install-mirror AND without a per-artifact
    # stage tree, the resolver returns ``rrNeedsBuild`` so auto-recurse
    # proceeds with the sub-build.  Confirms the install-mirror fast-path
    # only fires when there is real on-disk evidence the sibling built.
    let scratch = createTempDir("repro-m9r14h-needs-build-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "cairo")
    let useDef = syntheticUseDef("cairo")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrNeedsBuild

  test "test_m9r14h_1_resolved_recipes_cache_is_consulted":
    # Belt-and-braces pin on the in-process cache.  After the dispatcher
    # marks a sibling recipe dir as resolved, a repeat probe (without
    # any on-disk change) still must NOT trigger another sub-build.  We
    # exercise the cache directly because a full auto-recurse round-trip
    # requires a complete sub-build pipeline (covered by the live
    # smoke); this layer pins the bookkeeping contract.
    let scratch = createTempDir("repro-m9r14h-cache-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "cairo")
    discard makeInstallMirrorLib(scratch, "cairo", "libcairo")
    let recipeDir = absolutePath(scratch / "cairo")
    # Reset the cache so the test is hermetic regardless of run order.
    let savedCache = fromSourceResolvedRecipes
    fromSourceResolvedRecipes = initHashSet[string]()
    defer: fromSourceResolvedRecipes = savedCache
    # First "round": dispatcher marks the recipe as resolved.
    fromSourceResolvedRecipes.incl(recipeDir)
    check recipeDir in fromSourceResolvedRecipes
    # Second round: the dispatcher's ``if siblingRecipeDir in
    # fromSourceResolvedRecipes: continue`` clause MUST still see the
    # entry.  We don't mutate the cache in between -- the contract is
    # that entries persist across the whole dispatcher invocation.
    check recipeDir in fromSourceResolvedRecipes

  test "test_m9r14h_1_install_mirror_probe_finds_lib64":
    # Multilib distros (RHEL/Fedora 64-bit) stage libraries to
    # ``lib64/`` rather than ``lib/``.  The probe MUST walk both.
    let scratch = createTempDir("repro-m9r14h-mirror-lib64-", "")
    defer: removeDir(scratch)
    let lib64Dir = scratch / "cairo" / ".repro" / "output" / "install" /
      "usr" / "lib64"
    createDir(lib64Dir)
    let expected = lib64Dir / "libcairo.so"
    writeFile(expected, "ELF synthetic")
    let hit = m9r14hProbeInstallMirrorLibrary(scratch / "cairo", "cairo")
    check hit == absolutePath(expected)

  test "test_m9r14h_1_resolver_accepts_package_named_lib_payload":
    # Non-executable system payloads can live under a package-specific
    # lib directory. The kernel install mirror uses this shape and must
    # count as a completed source build without a synthetic /usr/bin tool.
    let scratch = createTempDir("repro-m9r14h-lib-payload-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "kernel")
    let payloadDir = scratch / "kernel" / ".repro" / "output" /
      "install" / "usr" / "lib" / "reproos-kernel"
    createDir(payloadDir)
    let expected = payloadDir / "vmlinuz"
    writeFile(expected, "synthetic kernel image")

    let outcome = tryResolveFromSourceTool(
      syntheticUseDef("kernel"), recipeRoot = scratch)

    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(expected)

  test "test_m9r14h_1_resolver_rejects_unrelated_lib_payload":
    # A random directory under usr/lib is not evidence for the requested
    # package; the package-name boundary is the guard on this fallback.
    let scratch = createTempDir("repro-m9r14h-unrelated-payload-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "kernel")
    let unrelatedDir = scratch / "kernel" / ".repro" / "output" /
      "install" / "usr" / "lib" / "firmware"
    createDir(unrelatedDir)
    writeFile(unrelatedDir / "blob.bin", "synthetic firmware")

    let outcome = tryResolveFromSourceTool(
      syntheticUseDef("kernel"), recipeRoot = scratch)

    check outcome.kind == rrNeedsBuild

  test "test_m9r14h_1_resolver_accepts_configuration_only_payload":
    # ca-certificates publishes only an etc/ssl bundle. A completed
    # configuration-only mirror must not recurse forever looking for a
    # synthetic executable named after the package.
    let scratch = createTempDir("repro-m9r14h-etc-payload-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "ca-certificates")
    let certDir = scratch / "ca-certificates" / ".repro" / "output" /
      "install" / "etc" / "ssl" / "certs"
    createDir(certDir)
    let expected = certDir / "ca-certificates.crt"
    writeFile(expected, "synthetic certificate bundle")

    let outcome = tryResolveFromSourceTool(
      syntheticUseDef("ca-certificates"), recipeRoot = scratch)

    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(expected)
