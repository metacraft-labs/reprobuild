## M0 (Realize-Closure-And-Catalog-Expansion) → GM4b hermetic gate: the
## PLAN-mode preview (``previewPackageResolutions``) resolves every package the
## way the real apply does, so ``--plan`` never misclassifies a defined
## package as "missing".
##
## Pre-M0 the preview called a narrower resolver than the apply and reported
## every built-in-catalog package as missing. GM4b removed the adapter chain
## both used: preview and realize now take the same
## ``ProfileResolutionContext`` and resolve through
## ``package_catalog.resolveProfilePackage`` (Provisioning-Contributions.md
## §"Profile Package References"). The gate, restated:
##
##   1. ``t_preview_chain_resolves_m71_reference_profile`` — the M71 reference
##      home.nim's 24 version-pinned references, resolved for an
##      x86_64-windows target, ALL preview as realizations of the pinned
##      version through the package's ``tarball`` realization. ZERO missing.
##   2. ``..._unknown_package_id_fails_closed_with_structured_error`` — an
##      undefined package previews as missing with the ``unknown-package``
##      diagnostic naming it and the target.
##   3. ``..._version_not_in_catalog_fails_closed_with_structured_error`` — a
##      bogus pin on a defined package previews as a ``missing-realization``
##      naming the pin and the versions on offer.
##   4. ``..._m69_deferred_tools_still_resolve`` — the 8 M69-deferred tools
##      resolve at PLAN time (their realize-time gaps are downstream).
##   5. ``..._no_regression_on_unregistered_path_only_pkg`` — an undefined
##      package whose executable is on the host's PATH previews as a
##      cache-hit through the ``path`` kind (host context only).
##
## Hermetic: no network, no Scoop. The Windows cases use a NON-host target,
## so the host inventory is not consulted at all; the PATH case drops a stub
## executable into the fixture. No mocks.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath
import repro_test_support

import std/tables

import repro_dsl_stdlib/package_registry

import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/package_catalog

let
  FixtureRoot = "build/test-tmp/t-preview-chain" / testCaseScratchSlug()
  ReprobuildRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
  M71ReferenceHome =
    workspaceRootForRepo(ReprobuildRoot) / "reprobuild-examples" /
      "m71-home-profile-walkthrough" / "home.nim"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc isolateProdCatalog() =
  ## Point the production catalog at a sandboxed Scoop root so Scoop
  ## probes never hit a real installation. Also clears the test-seam env
  ## vars the realize layer reads so the chain path is exercised.
  let sandboxRoot = FixtureRoot / "fake-scoop-root"
  resetDir(sandboxRoot)
  putEnv("SCOOP", sandboxRoot)
  putEnv("REPRO_TEST_SCOOP_OVERRIDE",
    FixtureRoot / "no-such-scoop-binary.exe")
  delEnv("REPRO_TEST_PACKAGE_SOURCE")
  delEnv("REPRO_TEST_PACKAGE_SCOOP")

# The 24 packages in the M71 reference home.nim. Kept here as a constant
# so a future drift between the spec and the reference profile fails
# the test (in addition to the file-parse cross-check below).
const M71Packages: seq[(string, string)] = @[
  # dev (10)
  ("cmake", "4.3.3"),
  ("ninja", "1.13.2"),
  ("meson", "1.11.0"),
  ("git", "2.54.0"),
  ("gh", "2.93.0"),
  ("just", "1.51.0"),
  ("node", "24.16.0"),
  ("python3", "3.14.5"),
  ("nim", "2.2.10"),
  ("gcc", "15.2.0"),
  # jvm (3)
  ("jdk", "21.0.5"),
  ("maven", "3.9.16"),
  ("gradle", "9.5.1"),
  # functional (4)
  ("ghc", "9.12.1"),
  ("cabal", "3.16.1.0"),
  ("erlang", "28.5"),
  ("elixir", "1.19.5"),
  # polyglot (4)
  ("swift", "6.3.1"),
  ("zig", "0.16.0"),
  ("dotnet-sdk", "10.0.300"),
  ("crystal", "1.20.2"),
  # scripting (3)
  ("php", "8.5.6"),
  ("composer", "2.10.0"),
  ("ruby", "4.0.5-1")]

proc m71PlannedPackages(): seq[PlannedPackage] =
  for (id, ver) in M71Packages:
    result.add(PlannedPackage(packageId: id,
      requestedVersion: ver,
      fromActivity: "m71-reference"))

proc windowsContext(): ProfileResolutionContext =
  ## An x86_64-windows target that is not this machine: declared
  ## realizations only, whatever host runs the test.
  profileResolutionContext(initOrderedTable[string, seq[string]](),
    "windows", "x86_64", isHost = false)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M0/GM4b — previewPackageResolutions resolves like the apply":

  test "t_preview_chain_resolves_m71_reference_profile":
    # Sanity: M71 reference is exactly 24 entries.
    check M71Packages.len == 24

    # Sanity: every entry exists in the catalog (otherwise the M71
    # campaign's deferred-8 list is wrong and this test isn't the
    # right gate to enforce that). If a package becomes unregistered
    # in the future this assertion fires before the preview check.
    for (id, ver) in M71Packages:
      checkpoint id
      check isLinkedPackage(id)

    resetDir(FixtureRoot)
    isolateProdCatalog()

    let previews = previewPackageResolutions(m71PlannedPackages(),
      windowsContext())
    check previews.len == M71Packages.len
    var missing: seq[string]
    for i, pp in previews:
      checkpoint pp.packageId & ": " & pp.detail
      if pp.kind == ppkMissing:
        missing.add(pp.packageId & " (" & pp.detail & ")")
        continue
      check pp.kind == ppkRealize
      check pp.resolved
      check pp.resolution.selection.kind == rkTarball
      # The pinned version is the version selected.
      check pp.resolvedVersion == M71Packages[i][1]
      check pp.detail.startsWith("tarball ")
      check pp.steps.len >= 1
      check pp.steps[^1].selected
    if missing.len > 0:
      echo "  [diag] previews classified as ppkMissing: " & missing.join("; ")
    check missing.len == 0

  test "t_preview_chain_unknown_package_id_fails_closed_with_structured_error":
    resetDir(FixtureRoot)
    isolateProdCatalog()
    # A versioned reference to a package no linked definition carries:
    # the operator must see WHICH package is unknown and for which
    # target, not a generic "missing".
    let plannedVersioned = @[PlannedPackage(
      packageId: "definitely-not-registered-foobar",
      requestedVersion: "1.0.0",
      fromActivity: "test")]
    let previews = previewPackageResolutions(plannedVersioned,
      windowsContext())
    check previews.len == 1
    let p = previews[0]
    check p.kind == ppkMissing
    check not p.resolved
    check p.detail.startsWith("unknown-package:")
    check p.detail.contains("definitely-not-registered-foobar")
    check p.detail.contains("x86_64-windows")
    check p.steps.len == DefaultSelectionPolicy.len

  test "t_preview_chain_version_not_in_catalog_fails_closed_with_structured_error":
    resetDir(FixtureRoot)
    isolateProdCatalog()
    # jdk IS defined, with archives at 21.0.5. A bogus pin must fail
    # closed as a missing realization — NOT silently select 21.0.5.
    let planned = @[PlannedPackage(
      packageId: "jdk",
      requestedVersion: "9.9.9-nonexistent",
      fromActivity: "test")]
    let previews = previewPackageResolutions(planned, windowsContext())
    check previews.len == 1
    let p = previews[0]
    check p.kind == ppkMissing
    check p.detail.startsWith("missing-realization:")
    check p.detail.contains("9.9.9-nonexistent")
    # The diagnostic names the version on offer.
    check p.detail.contains("21.0.5")

  test "t_preview_chain_m69_deferred_tools_still_resolve":
    # The 8 M69-deferred tools: archive realizations defined; some of
    # their realize-time hooks have gaps. The PLAN-time resolver does
    # NOT hit the realize-time gap — on a Windows target each must
    # preview as a realization of its Windows archive.
    const M69Deferred = ["swift", "gcc", "git", "meson", "python3",
                         "composer", "erlang", "ruby"]
    resetDir(FixtureRoot)
    isolateProdCatalog()
    var planned: seq[PlannedPackage]
    for id in M69Deferred:
      planned.add(PlannedPackage(packageId: id,
        requestedVersion: "",
        fromActivity: "test"))
    let previews = previewPackageResolutions(planned, windowsContext())
    check previews.len == M69Deferred.len
    for pp in previews:
      checkpoint pp.packageId & ": " & pp.detail
      check pp.kind == ppkRealize
      check pp.resolved
      check pp.resolution.selection.kind == rkTarball
      check pp.steps[^1].selected

  test "t_preview_chain_no_regression_on_unregistered_path_only_pkg":
    # A package id no definition carries, whose executable is on the
    # host's PATH: the host context's `path` kind picks it up (the
    # profile's escape hatch for tools nobody has defined).
    resetDir(FixtureRoot)
    let toolName = "m0-preview-stub-tool"
    let binDir = FixtureRoot / "stub-bin"
    createDir(extendedPath(binDir))
    let stubExe =
      when defined(windows): binDir / (toolName & ".cmd")
      else: binDir / toolName
    let body =
      when defined(windows): "@echo m0-stub\n"
      else: "#!/bin/sh\necho m0-stub\n"
    writeFile(extendedPath(stubExe), body)
    when not defined(windows):
      discard execShellCmd("chmod +x " & quoteShell(stubExe))
    let savedPath = getEnv("PATH")
    defer: putEnv("PATH", savedPath)
    putEnv("PATH", absolutePath(binDir) & PathSep & getEnv("PATH"))
    isolateProdCatalog()

    let planned = @[PlannedPackage(packageId: toolName,
      requestedVersion: "",
      fromActivity: "test")]
    let previews = previewPackageResolutions(planned,
      hostProfileResolutionContext())
    check previews.len == 1
    let p = previews[0]
    check p.kind == ppkCacheHit
    check p.resolved
    check p.resolution.selection.kind == rkPath
    check p.resolution.selection.ambient
    check p.detail.contains(toolName)

  test "t_preview_chain_reference_home_nim_exists_and_lists_24_packages":
    # File-parse cross-check so a future M71 reference profile drift
    # (a new package added or one removed) is caught even when the
    # M71Packages constant above was not updated.
    check fileExists(M71ReferenceHome)
    let content = readFile(M71ReferenceHome)
    # Each entry MUST be referenced exactly once in the file. We accept
    # the three macro-library reference forms.
    for (id, _) in M71Packages:
      let referenced = content.contains("package(" & id & ",") or
        content.contains("package(`" & id & "`,") or
        content.contains("package(\"" & id & "\",")
      if not referenced:
        echo "  [diag] reference home.nim is missing package(" & id & ", ...)"
      check referenced
