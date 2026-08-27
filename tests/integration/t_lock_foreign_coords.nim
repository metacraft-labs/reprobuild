## Test: Lock Foreign Coordinates Serialization & Deserialization
##
## This test validates that the `ckForeign` coordinate kind is correctly
## serialized to and parsed from the `repro.lock` TOML file, ensuring full
## schema-v2 backward and forward compatibility.
##
## Scenarios Tested:
##   * Scenario 2.1: TOML Serialization Correctness
##     Constructs a `LockedDependencies` object with a `LockedDep` containing
##     `ckForeign` coordinates (nix, nixpkgs#nim). Serializes it to TOML and
##     asserts that fields `coord_kind = "foreign"`, `provisioner = "nix"`, and
##     `foreign_coords = "nixpkgs#nim"` are present.
##   * Scenario 2.2: TOML Deserialization Correctness
##     Parses the serialized TOML back into a `LockedDependencies` object and
##     asserts that the `Coordinates` sum-type holds the original `ckForeign` values.
##   * Scenario 2.3: Backward Compatibility
##     Parses a legacy TOML string containing `vcs` and `store` coordinates to ensure
##     no parsing regressions occur for existing locks.
##
## Testing Strategy:
##   * Pure, strong integration test running against the actual `repro_lock`
##     parser and serializer code without any mock objects.

import std/[unittest, strutils]
import repro_lock

suite "Lockfile Foreign Coordinates Integration Tests":

  test "Scenario 2.1 & 2.2: Round-trip serialization of ckForeign coordinates":
    # 1. Setup coordinates
    let coords = Coordinates(
      kind: ckForeign,
      provisioner: "nix",
      foreignCoordinates: "nixpkgs#nim"
    )

    let dep = LockedDep(
      name: "nim",
      path: "",
      coordinates: coords,
      integrity: "sha256-42",
      version: "2.2.8",
      visibility: "public",
      participation: "",
      depends: @[],
      tags: @[]
    )

    let ld = LockedDependencies(
      schema: SolvedGraphLockSchemaV2,
      platform: "amd64-linux",
      optimal: true,
      inputsDigest: "fnv1a64:12345",
      variants: @[],
      packages: @[],
      deps: @[dep]
    )

    # 2. Serialize to TOML
    let tomlText = serializeLockedDependencies(ld)
    
    # Assert TOML representation
    check "coord_kind = \"foreign\"" in tomlText
    check "provisioner = \"nix\"" in tomlText
    check "foreign_coords = \"nixpkgs#nim\"" in tomlText

    # 3. Parse back from TOML
    let parsedLd = parseLockedDependencies(tomlText)
    
    check parsedLd.deps.len == 1
    let parsedDep = parsedLd.deps[0]
    check parsedDep.name == "nim"
    check parsedDep.coordinates.kind == ckForeign
    check parsedDep.coordinates.provisioner == "nix"
    check parsedDep.coordinates.foreignCoordinates == "nixpkgs#nim"
    check parsedDep.integrity == "sha256-42"
    check parsedDep.version == "2.2.8"

  test "Scenario 2.3: Backward compatibility with legacy coordinates (VCS and Store)":
    # TOML representation of legacy lockfile with vcs and store dependencies on single lines
    let legacyToml = """
schema = "reprobuild.solved-graph-lock.v2"

[lock]
platform = "amd64-linux"
optimal = true
inputs_digest = "fnv1a64:12345"
variants = []
packages = []
deps = [{ name = "reprobuild", path = "reprobuild", coord_kind = "vcs", url = "github.com", ref = "main", revision = "abc", integrity = "sha256-11", version = "1.0", visibility = "public", participation = "", depends = "", tags = "" }, { name = "nim", path = "", coord_kind = "store", store_hash = "xyz", integrity = "sha256-22", version = "2.2.0", visibility = "public", participation = "", depends = "", tags = "" }]
"""
    let ld = parseLockedDependencies(legacyToml)
    check ld.deps.len == 2
    
    # Verify VCS dep
    let dep0 = ld.deps[0]
    check dep0.name == "reprobuild"
    check dep0.coordinates.kind == ckVcs
    check dep0.coordinates.url == "github.com"
    check dep0.coordinates.gitRef == "main"
    check dep0.coordinates.revision == "abc"
    
    # Verify Store dep
    let dep1 = ld.deps[1]
    check dep1.name == "nim"
    check dep1.coordinates.kind == ckStore
    check dep1.coordinates.storeHash == "xyz"

