## M1 (Realize-Closure spec) — fpc resolves through the default
## Windows chain via cakBuiltin.
##
## Validates the end-to-end resolution path that the M1 spec
## unblocks for the M71 Pascal Phase-2 partial:
##
##   * the catalog registry knows ``fpc``;
##   * ``chainResolvePackage`` with the default Windows chain returns a
##     resolution whose ``adapter == cakBuiltin``;
##   * the resolution carries a non-empty sha1 digest (the M1 weak-hash
##     fallback) and the digestAlgorithm is "sha1";
##   * the cakBuiltin step is the resolving one (the chain trace ends
##     at csoResolved on cakBuiltin).
##
## The test does NOT actually realize the package (no network). It
## only asserts the resolution shape so the realize-time pipeline has
## a structurally-valid CatalogResolution to consume.

import std/[options, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry
import repro_home_apply/package_catalog

suite "M1 — fpc end-to-end resolvable":

  test "catalog_registry knows fpc and the catalog is non-empty":
    let cat = getCatalog("fpc")
    check cat.isSome
    check cat.get.len > 0
    check isRegistered("fpc")

  test "selectDefault returns fpc 3.2.2 with a Windows platform slice":
    let cat = getCatalog("fpc").get
    let def = selectDefault(cat)
    check def.found
    check def.entry.version == "3.2.2"
    # The platform slice is the (pcAny, poWindows) one harvested from
    # the top-level url + hash (no architecture block in the Scoop
    # freepascal manifest).
    let pb = selectPlatformBinary(def.entry, pcAny, poWindows)
    check pb.found
    check pb.binary.sha1.len == 40
    check pb.binary.sha256 == ""
    check pb.binary.sha512 == ""

  test "validateCatalog accepts fpc (0 errors + 1 sha1 warning)":
    let cat = getCatalog("fpc").get
    var warnings: seq[string] = @[]
    let errors = validateCatalogEx(cat, warnings)
    check errors.len == 0
    check warnings.len == 1
    check "sha1 digest is weaker than sha256" in warnings[0]

  test "chainResolvePackage resolves fpc via cakBuiltin on Windows":
    ## Use the explicit Windows default chain so the test is meaningful
    ## on every host (the platform default is consulted only when the
    ## test runs on Windows; on Linux/macOS the default chain skips
    ## cakBuiltin first via cakNix/cakPath, but we pin the chain so the
    ## assertion is host-independent).
    var cat = openProductionCatalog()
    let resolution = chainResolvePackage(cat, "fpc",
      chain = @[cakBuiltin, cakPath],
      hostCpu = pcX86_64, hostOs = poWindows)
    check resolution.adapter == cakBuiltin
    check resolution.builtinVersion == "3.2.2"
    check resolution.digestAlgorithm == "sha1"
    check resolution.digestValue.len == 40
    # The chain trace records cakBuiltin as the resolving step.
    check resolution.chainTrace.len >= 1
    let last = resolution.chainTrace[resolution.chainTrace.len - 1]
    check last.adapter == cakBuiltin
    check last.outcome == csoResolved
