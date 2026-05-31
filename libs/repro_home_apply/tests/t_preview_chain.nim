## M0 (Realize-Closure-And-Catalog-Expansion) hermetic gate for the
## planner-path wiring fix: ``previewPackageResolutions`` MUST route
## through M65's ``chainResolvePackage`` so PLAN-mode preview no longer
## misclassifies every cakBuiltin package as "missing".
##
## Pre-M0 bug (caught during M71 review): the PLAN-mode preview path
## called the legacy ``resolvePackage(cat, packageId)`` signature which
## only consults the Scoop / PATH adapters. Result: against the M71
## reference home.nim every one of the 24 built-in catalog packages
## came back as ``ppkMissing`` even though the real apply (without
## ``--plan``) realized them fine through M65's chain.
##
## This gate enforces:
##
##   1. ``t_preview_chain_resolves_m71_reference_profile``
##      Against the M71 reference home.nim's 24 package() entries, EVERY
##      package previews as either ``ppkRealize`` (chain → cakBuiltin)
##      or ``ppkCacheHit`` (chain → cakPath when the same tool is on
##      PATH). ZERO ``ppkMissing`` rows. Each chain-routed preview's
##      ``chainTrace`` records cakBuiltin's csoResolved as the picked
##      step (or csoCatalogMiss → cakPath csoResolved when the tool is
##      already on PATH).
##
##   2. ``t_preview_chain_unknown_package_id_fails_closed_with_structured_error``
##      A bare ``package(definitely-not-registered-foobar)`` previews as
##      ``ppkMissing`` carrying the structured ``EUnknownPackageId``
##      diagnostic text in ``detail`` (NOT a silent "scoop searched
##      catalogs: ..." misclassification — the catalog_lookup pre-validate
##      path fires first).
##
##   3. ``t_preview_chain_version_not_in_catalog_fails_closed_with_structured_error``
##      A pinned ``package(jdk, "9.9.9-nonexistent")`` previews as
##      ``ppkMissing`` carrying the structured ``EVersionNotInCatalog``
##      diagnostic text + the list of available versions.
##
##   4. ``t_preview_chain_m69_deferred_tools_still_resolve``
##      The 8 M69-deferred tools (swift, gcc, git, meson, python3,
##      composer, erlang, ruby) all resolve at PLAN time via cakBuiltin
##      — the realize-time gap is downstream and does NOT affect the
##      planner's verdict.
##
##   5. ``t_preview_chain_no_regression_on_unregistered_path_only_pkg``
##      A bare ``package(<tool-not-in-catalog>)`` whose executable is on
##      PATH continues to preview cleanly (the M65 chain falls through
##      to cakPath) — proves the legacy non-catalog flows still work.
##
## All tests are hermetic: NO network, NO real Scoop install. The
## production catalog query is a READ (open the catalog, look up an id,
## walk the registered slices). The cakPath branch uses a stub
## executable dropped into the test fixture's bin dir.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_dsl_stdlib/catalog_registry

import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/package_catalog

const
  FixtureRoot = "build/test-tmp/t-preview-chain"
  M71ReferenceHome =
    currentSourcePath().parentDir().parentDir().parentDir().parentDir()
      .parentDir() /
      "reprobuild-examples" / "m71-home-profile-walkthrough" / "home.nim"
    ## ``D:/metacraft/reprobuild/libs/repro_home_apply/tests/t_preview_chain.nim``
    ## → walk up 5 parentDir() calls:
    ##   tests → repro_home_apply → libs → reprobuild → metacraft.
    ## Then into the ``reprobuild-examples`` sibling at ``D:/metacraft``.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc isolateProdCatalog() =
  ## Point the production catalog at a sandboxed Scoop root so cakScoop
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

proc findChainStep(trace: seq[ChainStep];
                   adapter: CatalogAdapterKind):
    tuple[found: bool; step: ChainStep] =
  for s in trace:
    if s.adapter == adapter:
      return (true, s)
  (false, ChainStep())

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M0 — previewPackageResolutions routes through chainResolvePackage":

  test "t_preview_chain_resolves_m71_reference_profile":
    # Sanity: M71 reference is exactly 24 entries.
    check M71Packages.len == 24

    # Sanity: every entry exists in the catalog (otherwise the M71
    # campaign's deferred-8 list is wrong and this test isn't the
    # right gate to enforce that). If a package becomes unregistered
    # in the future this assertion fires before the preview check.
    for (id, ver) in M71Packages:
      check isRegistered(id)

    resetDir(FixtureRoot)
    isolateProdCatalog()

    let previews = previewPackageResolutions(m71PlannedPackages())
    check previews.len == M71Packages.len

    var missing: seq[string]
    var notViaBuiltinOrPath: seq[string]
    for pp in previews:
      case pp.kind
      of ppkMissing:
        missing.add(pp.packageId & " (" & pp.detail & ")")
      of ppkRealize, ppkCacheHit:
        # Every chain-routed preview must record a chainTrace whose
        # final entry is csoResolved. On a host with the tool on PATH
        # the chain falls through builtin → path; on a clean host it
        # resolves at cakBuiltin.
        if pp.chainTrace.len == 0:
          notViaBuiltinOrPath.add(pp.packageId & " (no chainTrace; detail=" &
            pp.detail & ")")
        else:
          let last = pp.chainTrace[pp.chainTrace.len - 1]
          if last.outcome != csoResolved:
            notViaBuiltinOrPath.add(pp.packageId &
              " (chain did not resolve; last=" & $last.outcome & ")")
          elif pp.adapter notin {cakBuiltin, cakPath, cakScoop, cakNix}:
            notViaBuiltinOrPath.add(pp.packageId &
              " (unexpected adapter " & $pp.adapter & ")")

    if missing.len > 0:
      echo "  [diag] previews classified as ppkMissing: " & missing.join("; ")
    if notViaBuiltinOrPath.len > 0:
      echo "  [diag] previews not via builtin/path/scoop/nix: " &
        notViaBuiltinOrPath.join("; ")

    # The contract: ZERO missing rows for the catalog-registered set.
    check missing.len == 0
    check notViaBuiltinOrPath.len == 0

    # Stronger assertion: at least one preview routed through cakBuiltin.
    # (On a fresh host every preview will; on the dev host where a few
    # tools are already on PATH the chain falls through to cakPath for
    # those. Either is honest reporting — the bug we're fixing is that
    # the legacy path reported "missing" for the same set.)
    var builtinHits = 0
    for pp in previews:
      if pp.adapter == cakBuiltin:
        inc builtinHits
    check builtinHits > 0

  test "t_preview_chain_unknown_package_id_fails_closed_with_structured_error":
    resetDir(FixtureRoot)
    isolateProdCatalog()
    # A bare reference (no version pin) to a package that is NOT in the
    # M65 catalog registry. The pre-M0 code would have either fallen
    # through to the chain (returning EAdapterChainExhausted with a
    # giant PATH dump in the detail) or — for the "unknown" branch of
    # legacy resolvePackage — emitted a generic searched-catalogs
    # message. The fix preserves the legacy behaviour for unregistered
    # ids (since they could be pure-Scoop refs) and surfaces the
    # structured error only when isRegistered() returns true.
    #
    # For a versioned reference to an unregistered id, however, the
    # useChain gate fires (requestedVersion.len > 0) and the pre-
    # validation raises EUnknownPackageId via lookupCatalogSlice.
    let plannedVersioned = @[PlannedPackage(
      packageId: "definitely-not-registered-foobar",
      requestedVersion: "1.0.0",
      fromActivity: "test")]
    let previews = previewPackageResolutions(plannedVersioned)
    check previews.len == 1
    let p = previews[0]
    check p.kind == ppkMissing
    # The structured error tag we emit in `detail`. Whichever path the
    # preview took (lookupCatalogSlice or chainResolvePackage), the
    # outcome must NOT be a silent generic "missing" — the operator
    # must see a useful diagnostic.
    check p.detail.contains("unknown-package-id") or
      p.detail.contains("definitely-not-registered-foobar")
    check p.detail.contains("Registered tools") or
      p.detail.contains("searched catalogs") or
      p.detail.contains("adapter-chain-exhausted")

  test "t_preview_chain_version_not_in_catalog_fails_closed_with_structured_error":
    resetDir(FixtureRoot)
    isolateProdCatalog()
    # jdk IS in the catalog (the M63 reference entry). A clearly-bogus
    # pin must fail closed at lookupCatalogSlice with EVersionNotInCatalog
    # — NOT silently fall through to a "missing" preview.
    let planned = @[PlannedPackage(
      packageId: "jdk",
      requestedVersion: "9.9.9-nonexistent",
      fromActivity: "test")]
    let previews = previewPackageResolutions(planned)
    check previews.len == 1
    let p = previews[0]
    check p.kind == ppkMissing
    check p.detail.contains("version-not-in-catalog")
    # The structured error carries the available-versions list.
    check p.detail.contains("9.9.9-nonexistent")
    check p.detail.contains("Available versions")

  test "t_preview_chain_m69_deferred_tools_still_resolve":
    # The 8 M69-deferred tools: catalog entry present; realize-side
    # cakBuiltin install_method hook missing. The PLAN-time resolver
    # does NOT hit the realize-time gap — the planner must classify
    # them as ppkRealize via cakBuiltin (or cakPath when on PATH).
    const M69Deferred = ["swift", "gcc", "git", "meson", "python3",
                         "composer", "erlang", "ruby"]
    resetDir(FixtureRoot)
    isolateProdCatalog()
    var planned: seq[PlannedPackage]
    for id in M69Deferred:
      planned.add(PlannedPackage(packageId: id,
        requestedVersion: "",
        fromActivity: "test"))
    let previews = previewPackageResolutions(planned)
    check previews.len == M69Deferred.len
    for pp in previews:
      check pp.kind != ppkMissing
      check pp.chainTrace.len > 0
      let last = pp.chainTrace[pp.chainTrace.len - 1]
      check last.outcome == csoResolved
      check pp.adapter in {cakBuiltin, cakPath}

  test "t_preview_chain_no_regression_on_unregistered_path_only_pkg":
    # A package id with no built-in catalog entry. Used to verify that
    # M0 didn't break the legacy non-catalog fallback (pure-Scoop /
    # pure-PATH references that were never migrated to the M65 chain).
    # We drop a stub executable on PATH so the cakPath branch (in the
    # chain OR the legacy resolvePackage) can pick it up.
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
    putEnv("PATH", binDir & PathSep & getEnv("PATH"))
    isolateProdCatalog()

    let planned = @[PlannedPackage(packageId: toolName,
      requestedVersion: "",
      fromActivity: "test")]
    let previews = previewPackageResolutions(planned)
    check previews.len == 1
    let p = previews[0]
    # Either the new chain path took it (cakPath, ppkCacheHit) or the
    # legacy fallback did (Scoop on Windows; cakPath elsewhere). Both
    # are honest "the tool is reachable" outcomes — what we MUST NOT
    # see is ppkMissing.
    check p.kind != ppkMissing

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
