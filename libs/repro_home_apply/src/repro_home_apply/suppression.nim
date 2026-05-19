## Phase B: stow vs package-output suppression and the related
## `WStowOverridesShadowed` / `WStowAmbiguousSuppression` diagnostic
## emitters (see [Home-Profile-Intent-Layer.md] "Suppression Of
## Package-Generated Files").
##
## Contract:
##
##   Inputs:  the combined `generatedFiles` list (package outputs +
##            stow entries, both with the same `relativeHomePath` key)
##            plus the configurable graph (Phase B uses
##            `(packageName, key)` pairs harvested from
##            `config.<pkg>.<key>` entries in `home.nim`).
##
##   Outputs: a deduplicated `generatedFiles` list where each
##            `relativeHomePath` appears at most once (the stow entry
##            wins if both kinds are present), plus a list of
##            `StowDiagnostic` records the pipeline forwards to stderr.

import std/[tables]

import ./errors
import ./plan

proc suppressStowShadowed*(generatedFiles: seq[PlannedGeneratedFile];
                          configContributions: seq[ConfigContribution]):
    tuple[files: seq[PlannedGeneratedFile];
          diagnostics: seq[StowDiagnostic]] =
  ## Resolve overlapping `package-output` and `stow-file` entries.
  ## The stow entry always wins; the package's record is dropped.
  ## A `WStowOverridesShadowed` is emitted naming each dead
  ## configurable contribution.
  var buckets = initTable[string, seq[PlannedGeneratedFile]]()
  for g in generatedFiles:
    let key = g.relativeHomePath
    if key in buckets:
      buckets[key].add g
    else:
      buckets[key] = @[g]
  for relPath, group in buckets:
    var stowEntry: PlannedGeneratedFile
    var hasStow = false
    var packageEntries: seq[PlannedGeneratedFile]
    for g in group:
      case g.sourceKind
      of pgfsStowFile:
        if not hasStow:
          stowEntry = g
          hasStow = true
      of pgfsPackageOutput:
        packageEntries.add g
    if hasStow and packageEntries.len > 0:
      # Suppression: emit one record per suppressed package + one
      # WStowOverridesShadowed diagnostic per package whose config:
      # overrides target it. If multiple packages were suppressed,
      # emit WStowAmbiguousSuppression naming them.
      if packageEntries.len >= 2:
        var related: seq[string]
        for pe in packageEntries:
          related.add(pe.contributingPackage)
        result.diagnostics.add(StowDiagnostic(
          severity: dsWarning,
          code: sdWStowAmbiguousSuppression,
          path: stowEntry.absoluteOutputPath,
          relatedPackages: related,
          message: "WStowAmbiguousSuppression: stow file " &
            stowEntry.absoluteOutputPath &
            " suppresses outputs from multiple packages; the stow " &
            "file wins. Packages: " & $related))
      for pe in packageEntries:
        var deadKeys: seq[string]
        for c in configContributions:
          if c.packageName == pe.contributingPackage:
            deadKeys.add c.configKey
        if deadKeys.len > 0:
          result.diagnostics.add(StowDiagnostic(
            severity: dsWarning,
            code: sdWStowOverridesShadowed,
            path: stowEntry.absoluteOutputPath,
            package: pe.contributingPackage,
            deadConfigKeys: deadKeys,
            message: "WStowOverridesShadowed: stow file " &
              stowEntry.absoluteOutputPath & " shadows the output of " &
              "package " & pe.contributingPackage &
              "; the following `config:` overrides are dead code for " &
              "that file: " & $deadKeys))
        else:
          # No config:, still useful to know the package was shadowed.
          result.diagnostics.add(StowDiagnostic(
            severity: dsWarning,
            code: sdWStowOverridesShadowed,
            path: stowEntry.absoluteOutputPath,
            package: pe.contributingPackage,
            deadConfigKeys: @[],
            message: "WStowOverridesShadowed: stow file " &
              stowEntry.absoluteOutputPath & " shadows the output of " &
              "package " & pe.contributingPackage))
      result.files.add(stowEntry)
    elif hasStow:
      result.files.add(stowEntry)
    else:
      for pe in packageEntries:
        result.files.add(pe)
