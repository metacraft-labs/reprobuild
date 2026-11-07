## The published JSON form of a catalog's provisioning contribution records.
##
## A provisioning catalog (`reprobuild-nix-packages`, `reprobuild-scoop-packages`,
## ...) declares contributions in a Nim recipe (`provisioningFor`); the
## interface artifact carries them as `ProjectInterface.provisioningContributions`
## (reprobuild-pm spec Provisioning-Contributions.md §Interface Artifacts:
## "readable without running the provider"). A consumer that cannot run
## Reprobuild code at all -- a Nix evaluation reading a catalog through the
## reprobuild flake's `reprobuild.lib.nixRealizationOf` -- needs those records
## as data. This module renders them as one JSON document, which the catalog
## commits beside its recipe (`provisioning-contributions.json`) and checks
## for staleness in its own test suite, the way `repro home export --check`
## keeps a profile snapshot honest.
##
## The document is the records themselves, not a selection of their fields:
## every field of `InterfaceProvisioningContribution` and of each realization
## is rendered by `std/jsonutils` under its Nim name, so a field added to the
## artifact reaches the published form without anyone remembering to add it
## here. Format:
##
## ```json
## { "format": "repro.provisioning-contributions",
##   "schemaVersion": 1,
##   "contributions": [ { "targetPackage": "bash",
##                        "targetInterfaceFingerprint": "…",
##                        "contributor": "github:…", "developInterface": false,
##                        "nixProvisioning": [ { "selector": "nixpkgs#bash", … } ],
##                        "tarballProvisioning": [], "scoopProvisioning": [],
##                        "location": { "file": "repro.nim", "line": 11 } } ] }
## ```
##
## Contributions are sorted by target package, then contributor, then
## location. Source locations are made relative to the catalog root, and a
## document that would still carry the root's absolute path anywhere is
## refused: a committed file must not publish where someone's checkout lives.

import std/[algorithm, json, jsonutils, os, strutils]

import ../repro_interface_artifacts

const
  ContributionRecordsFormat* = "repro.provisioning-contributions"
  ContributionRecordsSchemaVersion* = 1
    ## Bumped when the meaning or shape of an existing field changes; a
    ## field added to the records is a compatible addition.

type
  EContributionRecords* = object of ValueError

proc relativeLocation(file, root: string): string =
  ## `file` relative to `root`, `/`-separated. A location outside the
  ## catalog cannot be made portable and is refused.
  if file.len == 0:
    return ""
  if not file.isAbsolute:
    return file.replace('\\', '/')
  let absRoot = root.absolutePath.normalizedPath
  let absFile = file.normalizedPath
  if not absFile.startsWith(absRoot & DirSep):
    raise newException(EContributionRecords, "contribution source " & file &
      " is outside the catalog root " & absRoot &
      "; its location cannot be published")
  absFile.relativePath(absRoot).replace('\\', '/')

proc relativize(node: JsonNode; root: string) =
  ## Rewrite every `location.file` under `node` relative to `root`.
  case node.kind
  of JObject:
    for key, value in node.pairs:
      # `value` is a ref: rewriting its members rewrites `node`'s.
      if key == "location" and value.kind == JObject and
          value.hasKey("file") and value["file"].kind == JString:
        value["file"] = %relativeLocation(value["file"].getStr, root)
      else:
        relativize(value, root)
  of JArray:
    for item in node.items:
      relativize(item, root)
  else:
    discard

proc mentions(node: JsonNode; needle: string): bool =
  case node.kind
  of JString: node.getStr.contains(needle)
  of JObject:
    for _, value in node.pairs:
      if mentions(value, needle): return true
    false
  of JArray:
    for item in node.items:
      if mentions(item, needle): return true
    false
  else: false

proc contributionRecordsJson*(contributions:
    openArray[InterfaceProvisioningContribution]; root: string): JsonNode =
  ## The published document for `contributions`, declared in the catalog
  ## whose checkout is `root`. Raises `EContributionRecords` when a record
  ## cannot be published without an absolute path of `root`.
  var sorted = @contributions
  sorted.sort(proc (a, b: InterfaceProvisioningContribution): int =
    result = cmp(a.targetPackage, b.targetPackage)
    if result == 0: result = cmp(a.contributor, b.contributor)
    if result == 0: result = cmp(a.location.file, b.location.file)
    if result == 0: result = cmp(a.location.line, b.location.line))
  var records = newJArray()
  for contribution in sorted:
    let record = toJson(contribution)
    relativize(record, root)
    records.add record
  result = %*{"format": ContributionRecordsFormat,
    "schemaVersion": ContributionRecordsSchemaVersion,
    "contributions": records}
  let absRoot = root.absolutePath.normalizedPath
  if mentions(result, absRoot):
    raise newException(EContributionRecords, "the contribution records " &
      "still name the catalog's absolute path " & absRoot &
      " after relativizing source locations; refusing to publish them")

proc renderContributionRecords*(contributions:
    openArray[InterfaceProvisioningContribution]; root: string): string =
  ## `contributionRecordsJson` as the committed file's bytes: two-space
  ## indentation and a trailing newline, so the file is stable across runs
  ## and diffs line by line.
  contributionRecordsJson(contributions, root).pretty(2) & "\n"
