## The published JSON form of a catalog's contribution records
## (`repro_interface_artifacts/contribution_records`, GM5).
##
## A catalog commits this document (`provisioning-contributions.json`) so a
## Nix evaluation can read its records (`reprobuild.lib.nixRealizationOf`).
## Three properties matter to a committed, public file and are checked here:
##
## * every field of a record reaches the document under its Nim name -- the
##   rendering is `std/jsonutils` over the record, so a realization's fields
##   (here a Nix selector, its executable path and nixpkgs pin) are all there
##   without a hand-kept list;
## * source locations are relative to the catalog root, records are sorted
##   (a stable file whatever order the recipe registered them in), and the
##   rendering is byte-stable;
## * a document that would still carry the checkout's absolute path -- a
##   location outside the root, or any other field naming the root -- is
##   refused rather than published.
##
## The real catalog's records are checked by reprobuild-nix-packages'
## `tests/test_nix_catalog.nim` ("the committed contribution records are the
## catalog's records"). No mocks: the records are plain values; the root is a
## real temporary directory.

import std/[json, os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/contribution_records

proc contribution(root, target: string; line: int;
                  expressionFile = ""): InterfaceProvisioningContribution =
  let file = root / "repro.nim"
  result = InterfaceProvisioningContribution(targetPackage: target,
    targetInterfaceFingerprint: "f".repeat(64),
    contributor: "github:example/catalog",
    location: SourceLocation(file: file, line: line))
  result.nixProvisioning.add InterfaceNixProvisioning(packageName: target,
    contributor: "github:example/catalog", selector: "nixpkgs#" & target,
    executablePath: "bin/" & target, expressionFile: expressionFile,
    nixpkgsRev: "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
    location: SourceLocation(file: file, line: line + 2))

suite "GM5: published contribution records":

  test "records are complete, relative, sorted and stable":
    let root = createTempDir("gm5-records-", "")
    defer: removeDir(root)
    let records = @[contribution(root, "zsh", 20),
                    contribution(root, "bash", 10)]
    let doc = contributionRecordsJson(records, root)
    check doc["format"].getStr == ContributionRecordsFormat
    check doc["schemaVersion"].getInt == ContributionRecordsSchemaVersion
    let first = doc["contributions"][0]
    check first["targetPackage"].getStr == "bash"
    check doc["contributions"][1]["targetPackage"].getStr == "zsh"
    check first["location"]["file"].getStr == "repro.nim"
    check first["location"]["line"].getInt == 10
    let nix = first["nixProvisioning"][0]
    check nix["selector"].getStr == "nixpkgs#bash"
    check nix["executablePath"].getStr == "bin/bash"
    check nix["nixpkgsRev"].getStr == "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"
    check nix["location"]["file"].getStr == "repro.nim"
    check first.hasKey("tarballProvisioning")
    check first.hasKey("scoopProvisioning")
    let rendered = renderContributionRecords(records, root)
    check rendered == renderContributionRecords(@[records[1], records[0]],
      root)
    check rendered.endsWith("}\n")
    check not rendered.contains(root)

  test "a location outside the catalog root is refused":
    let root = createTempDir("gm5-records-", "")
    let elsewhere = createTempDir("gm5-elsewhere-", "")
    defer:
      removeDir(root)
      removeDir(elsewhere)
    expect EContributionRecords:
      discard contributionRecordsJson([contribution(elsewhere, "bash", 1)],
        root)

  test "a field naming the checkout's absolute path is refused":
    let root = createTempDir("gm5-records-", "")
    defer: removeDir(root)
    expect EContributionRecords:
      discard contributionRecordsJson([contribution(root, "bash", 1,
        expressionFile = root / "pkgs" / "bash.nix")], root)
