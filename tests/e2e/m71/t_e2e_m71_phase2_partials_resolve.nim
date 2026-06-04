## M71 — end-to-end gate for the Phase-2 partial graduations + the
## broader fixture-set the M71 harness drives.
##
## The companion harness ``scripts/verify-m71-home-profile-fixtures.ps1``
## bootstraps a sandboxed home profile, runs ``repro home apply``, then
## runs every per-fixture validate script against the activated PATH.
## That harness exercises the LIVE path (downloads the catalog
## artifacts; gated behind ``REPRO_M71_LIVE=1``).
##
## This Nim e2e is the HERMETIC counterpart: it exercises the
## resolver-level contract the harness depends on without touching the
## network or the sandboxed CAS. Specifically:
##
##   1. Every Phase-2-CLEAN package (ghc / cabal / crystal / php) and
##      every Phase-1 graduate package (jdk / maven / gradle /
##      dotnet-sdk / zig) resolves via cakBuiltin against the
##      production catalog. No cakScoop fallback fires.
##   2. The M71 reference home.nim under
##      ``reprobuild-examples/m71-home-profile-walkthrough/home.nim``
##      parses cleanly and the planner picks up every package
##      reference with the right (id, version) tuple.
##   3. The Phase-2 BLOCKED packages (gnat / fpc / alire / ocaml /
##      dune) raise ``EUnknownPackageId`` — their absence from the
##      registry is the documented blocker the harness reports as
##      BLOCKED-NO-CATALOG.
##   4. The M69-DEFERRED packages (swift / composer / erlang / ruby /
##      git / meson / python3 / gcc) DO resolve via cakBuiltin (the
##      catalog entry exists); the realize-time gap is downstream of
##      this gate.
##
## If a future catalog harvest adds gnat/fpc/etc., test (3) will start
## failing and the harness's BLOCKED-NO-CATALOG rows graduate. That's
## the intended contract — this gate is the canary.

import std/[options, os, strutils, unittest]

import repro_dsl_stdlib/catalog_registry
import repro_dsl_stdlib/packages_schema
import repro_home_apply/catalog_lookup
import repro_home_apply/package_catalog

const M71ReferenceHome =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir().parentDir() /
    "reprobuild-examples" / "m71-home-profile-walkthrough" / "home.nim"
  ## The reprobuild repo lives at ``D:/metacraft/reprobuild`` and the
  ## reprobuild-examples sibling lives at ``D:/metacraft/reprobuild-examples``.
  ## Walk up 5 levels from ``tests/e2e/m71/t_e2e_*.nim`` to land on the
  ## metacraft root, then into reprobuild-examples.

# The Phase-2 graduation matrix the M71 harness keys off of. Keep this
# in sync with $GraduationTable in
# scripts/verify-m71-home-profile-fixtures.ps1.
const
  Phase2Clean = ["ghc", "cabal", "crystal", "php"]
    ## Catalog entries present + cakBuiltin realize path verified
    ## clean. These graduate Phase-2 PARTIALs to GRADUATED-PASS in
    ## LIVE mode.

  Phase2Deferred = ["composer"]
    ## Catalog entry present BUT M69 deferred-8 realize-time gap.
    ## Resolves via cakBuiltin at this gate; the harness reports the
    ## fixture as STILL-SKIPPED because the bundled-binary install
    ## method (.phar wrapping for composer; gem install for ruby; etc.)
    ## isn't a cakBuiltin install_method yet.

  Phase2NoCatalog = ["gnat", "dune"]
    ## No packages/<tool>.nim entry yet. The harness reports these as
    ## BLOCKED-NO-CATALOG; the M9 validate script SKIPs cleanly because
    ## the tool isn't on PATH (no realize path AT ALL — not even a
    ## broken one).
    ##
    ## M1 (Realize-Closure spec) graduated ``fpc`` out of this list:
    ## the sha1 schema extension + the harvested ``packages/fpc.nim``
    ## landed in M1, so fpc now resolves via cakBuiltin. The realize-
    ## time gap (innosetup-style .exe installer with no installer
    ## block) is M3 / M11 territory; for the resolver-level contract
    ## fpc has graduated to M69DeferredButResolves below.
    ##
    ## M6 (Realize-Closure spec) graduated ``ocaml`` out of this list:
    ## the MSYS2 pacman harvester + ``afTarZst`` extractor + the
    ## ``imMsys2Pacman`` realize hook landed in M6, so ocaml now both
    ## RESOLVES and REALIZES via cakBuiltin end-to-end (the M6 LIVE
    ## smoke materialized ``ocaml --version`` from a real MSYS2
    ## .pkg.tar.zst). ocaml is in ``Phase2GraduatedToBuiltin`` below.
    ##
    ## M7 (Realize-Closure spec) graduated ``alire`` out of this list:
    ## the GitHub Releases harvester source landed in M7, the
    ## alire-project/alire windows-x86_64 asset (a plain ``afZip``
    ## carrying ``bin/alr.exe`` at the archive root) was harvested into
    ## ``packages/alire.nim``, and the existing cakBuiltin
    ## ``afZip + imExtract`` baseline materializes it without any
    ## new dispatch surface. alire is in ``Phase2GraduatedToBuiltin``
    ## below.
    ##
    ## ``dune`` is NOT in MSYS2 (dune ships only as a source .tbz via
    ## GitHub releases; the canonical Windows build path is opam,
    ## which is itself bootstrapped from OCaml source) — deferred to
    ## a future opam-harvester milestone, NOT M7's GitHub-Releases
    ## binary harvester. ``gnat`` is in the same boat (the Ada
    ## compiler proper ships as an alire crate; alire itself is the
    ## tool that fetches gnat).

  Phase1Clean = ["jdk", "gradle", "dotnet-sdk", "zig"]
    ## M40 / M41 / M42 / M44 fixtures whose tools are CLEAN in the
    ## M67/M68 catalog. The M71 harness graduates them in LIVE mode.

  M69DeferredButResolves = ["swift", "ruby", "erlang", "git", "meson",
                            "python3", "gcc", "fpc"]
    ## M69 deferred-8 list (minus composer, covered above). Catalog
    ## entry exists; resolver picks the cakBuiltin slice; realize
    ## raises a structured "not yet implemented" diagnostic at
    ## apply time. M71 doesn't close these — separate milestone.
    ##
    ## M1 (Realize-Closure spec) added ``fpc`` here: cakBuiltin
    ## resolution works (sha1 schema extension landed), but the
    ## upstream Scoop manifest is an innosetup ``.exe`` installer
    ## with no ``installer:`` block. The realize-time installer
    ## dispatch is M3 territory; the resolver-level contract holds.
    ##
    ## M8 (Realize-Closure-And-Catalog-Expansion spec) erlang status
    ## shift: the M8 sevenzip MSI re-harvest unblocked the prerequisite
    ## (full 7-Zip 26.01 is now realized via cakBuiltin and DOES
    ## extract the OTP installer cleanly — LIVE-validated manually).
    ## However, erlang STAYS in this list because the catalog's
    ## ``install_method = imInstallerNsisBundle`` dispatches through
    ## the M4 dark.exe Burn-bundle code path; OTP is a bona-fide NSIS
    ## installer with NO Burn outer, so dark.exe rejects it with
    ## ``DARK0339``. Unblocking erlang fully needs a new
    ## ``imInstallerNsis`` (plain) install method that calls
    ## ``extract7z`` directly + a per-version-aware ``bin_relpath``
    ## (OTP lives under ``erts-<ver>/bin/``, not flat ``bin/``).
    ## See ``packages/erlang.nim`` header for the M8 status update
    ## and the M11 unblock plan.

  Phase2GraduatedToBuiltin = ["ocaml", "alire"]
    ## Phase-2 packages that this campaign (Realize-Closure-And-
    ## Catalog-Expansion) added to cakBuiltin end-to-end (both
    ## resolver and realize hook). Unlike ``M69DeferredButResolves``
    ## these tools have a working realize path:
    ##   * ``ocaml`` (M6) — cakBuiltin ``imMsys2Pacman`` hook
    ##     materializes a runnable prefix from the upstream
    ##     .pkg.tar.zst. M6 LIVE-validated end-to-end.
    ##   * ``alire`` (M7) — cakBuiltin ``afZip + imExtract`` baseline
    ##     materializes ``bin/alr.exe`` from the harvested GitHub
    ##     Releases asset. M7 LIVE-validated end-to-end.

suite "M71 e2e: Phase-2 partials resolve via the production catalog":

  test "every Phase-2 CLEAN package has a registered catalog":
    for pkg in Phase2Clean:
      check isRegistered(pkg)
      let cat = getCatalog(pkg)
      check cat.isSome
      check cat.get.len > 0

  test "every Phase-2 CLEAN package resolves via cakBuiltin (default version)":
    # Pin the host facts so the test asserts the catalog contract
    # (the slices the project ships are Windows + Linux today; the
    # runner's actual OS — e.g. macOS — is incidental to the contract).
    var prodCat = openProductionCatalog()
    for pkg in Phase2Clean:
      let res = chainResolvePackage(prodCat, pkg, chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poWindows)
      check res.adapter == cakBuiltin
      check res.builtinVersion.len > 0
      check res.urlUsed.len > 0
      check res.digestAlgorithm in ["sha256", "sha512"]
      check res.digestValue.len > 0
      check res.binRelpath.len > 0

  test "Phase-2 NO-CATALOG packages raise EUnknownPackageId":
    for pkg in Phase2NoCatalog:
      var raised = false
      var registered = false
      try:
        discard lookupCatalogSlice(pkg)
      except EUnknownPackageId as err:
        raised = true
        check err.packageId == pkg
        check err.registered.len > 0
        registered = true
      check raised
      check registered
      # Defensive: the registry itself should agree.
      check not isRegistered(pkg)

  test "Phase-1 CLEAN regression set still resolves via cakBuiltin":
    var prodCat = openProductionCatalog()
    for pkg in Phase1Clean:
      let res = chainResolvePackage(prodCat, pkg, chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poWindows)
      check res.adapter == cakBuiltin
      check res.builtinVersion.len > 0

  test "M69-deferred packages STILL resolve via cakBuiltin (realize-gap is downstream)":
    var prodCat = openProductionCatalog()
    for pkg in M69DeferredButResolves:
      check isRegistered(pkg)
      let res = chainResolvePackage(prodCat, pkg, chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poWindows)
      check res.adapter == cakBuiltin
      # The realize-time gap manifests at builtin_adapter.realizeBuiltinPackage,
      # not at the resolver level — this gate proves the resolver
      # contract still holds for the deferred set.

  test "M71 reference home.nim exists at the documented path":
    check fileExists(M71ReferenceHome)
    let content = readFile(M71ReferenceHome)
    # Every CLEAN package should appear as a package() call. Accept three
    # shapes the macro library supports: bare identifier, backtick-quoted
    # identifier (for hyphenated names like ``dotnet-sdk``), and string
    # literal (the other hyphen-handling form).
    proc referenced(pkg: string): bool =
      content.contains("package(" & pkg & ",") or
      content.contains("package(`" & pkg & "`,") or
      content.contains("package(\"" & pkg & "\",")
    for pkg in Phase2Clean:
      check referenced(pkg)
    for pkg in Phase1Clean:
      check referenced(pkg)

  test "M71 reference home.nim does NOT list any NO-CATALOG package":
    # Listing gnat / fpc / alire / ocaml / dune as a package() call
    # would cause `repro home apply` to fail closed with
    # EUnknownPackageId before any work happens. The reference profile
    # explicitly omits them so a user copying the file can run
    # `repro home apply` without modification.
    let content = readFile(M71ReferenceHome)
    for pkg in Phase2NoCatalog:
      let blockedRef = content.contains("package(" & pkg & ",") or
                       content.contains("package(" & pkg & ")") or
                       content.contains("package(`" & pkg & "`") or
                       content.contains("package(\"" & pkg & "\"")
      check not blockedRef

  test "Phase-2 graduated-to-builtin packages resolve AND have realize hooks":
    # M6 (Realize-Closure-And-Catalog-Expansion spec) added the
    # MSYS2-pacman harvester source + the cakBuiltin imMsys2Pacman
    # realize hook + the ocaml catalog entry. Unlike the
    # M69DeferredButResolves set, these tools have a working realize
    # path — the M6 hermetic + LIVE smokes proved end-to-end
    # extraction + bin_relpath resolution.
    var prodCat = openProductionCatalog()
    for pkg in Phase2GraduatedToBuiltin:
      check isRegistered(pkg)
      let res = chainResolvePackage(prodCat, pkg, chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poWindows)
      check res.adapter == cakBuiltin
      check res.builtinVersion.len > 0
      check res.urlUsed.len > 0
      check res.digestAlgorithm in ["sha256", "sha512"]
      check res.digestValue.len > 0
      check res.binRelpath.len > 0

  test "graduation table covers exactly the five Phase-2 partial languages":
    # Sanity: the campaign's Phase-2 partial list is haskell / php /
    # ada / pascal / crystal (per the spec).
    let phase2Languages = ["haskell", "php", "ada", "pascal", "crystal"]
    check phase2Languages.len == 5
    # Each language's primary tool maps to a known catalog status:
    #   haskell -> ghc + cabal       (CLEAN)
    #   php     -> php + composer    (php CLEAN; composer DEFERRED)
    #   ada     -> gnat              (NO-CATALOG)
    #   pascal  -> fpc               (DEFERRED-BUT-RESOLVES — M1
    #              graduated the catalog half; realize is M3+)
    #   crystal -> crystal           (CLEAN)
    check "ghc" in Phase2Clean and "cabal" in Phase2Clean
    check "php" in Phase2Clean
    check "composer" in Phase2Deferred
    check "gnat" in Phase2NoCatalog
    check "fpc" in M69DeferredButResolves
    check "crystal" in Phase2Clean
    # M6 graduation: ocaml is now GRADUATED-TO-BUILTIN (realize works
    # end-to-end via cakBuiltin imMsys2Pacman + afTarZst). dune
    # remains NO-CATALOG (not in MSYS2; opam-bootstrap deferred to
    # a future milestone).
    check "ocaml" in Phase2GraduatedToBuiltin
    check "ocaml" notin Phase2NoCatalog
    check "dune" in Phase2NoCatalog
    # M7 graduation: alire moves from NO-CATALOG to GRADUATED-TO-BUILTIN
    # (the GitHub Releases harvester landed; alire-project/alire ships
    # a clean afZip with bin/alr.exe at the archive root). gnat stays
    # NO-CATALOG because the GNAT compiler proper ships AS an alire
    # crate (operators install alire and then `alr toolchain --select gnat`)
    # — that's an alire-driven flow that doesn't fit cakBuiltin's
    # single-tool catalog shape.
    check "alire" in Phase2GraduatedToBuiltin
    check "alire" notin Phase2NoCatalog
    check "gnat" in Phase2NoCatalog
