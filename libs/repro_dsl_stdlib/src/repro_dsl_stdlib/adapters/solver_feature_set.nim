## Spec-Implementation M3 — solver-backed ``FeatureSet`` adapter.
##
## Per Reprobuild-Standard-Library §"`FeatureSet`", the stdlib's
## default implementation reads from a ``Configurable[HashSet[string]]``
## populated by per-feature variant decisions. In the reprobuild
## codebase the variant-resolved set is computed by M2d's solver and
## exposed through ``lastSolverSolution()`` /
## ``hasSolverSolution()``. The adapter below queries that surface so
## a recipe's ``currentBuildContext().featureSet.enabled("tls")``
## consults the same data the engine uses for build-graph emission.
##
## The adapter does NOT raise when the solver hasn't run yet — that
## state is reachable when a typed-tool wrapper is used outside a
## live ``package`` body. In that case ``enabled`` returns ``false``
## and ``allEnabled`` returns ``@[]`` so the recipe surface degrades
## gracefully.

import std/[strutils, tables]

import ../interfaces/feature_set
import ../configurables/variants

export feature_set

proc solverFeatureValue*(name: string): string =
  ## Helper — reads the solver-resolved string for a variant. Returns
  ## ``""`` when the solver hasn't run or the variant isn't in the
  ## solved set. Diagnostic surfaces consume this directly when they
  ## want the variant value without involving the FeatureSet vtable.
  if not hasSolverSolution():
    return ""
  let sol = lastSolverSolution()
  if name notin sol.variants: return ""
  sol.variants[name]

proc solverFeatureEnabled*(name: string): bool =
  ## Helper — true iff the named variant is resolved to a boolean
  ## ``true`` (or its truthy string forms). Recipes that consult
  ## boolean variants by their FeatureSet identity end up here.
  let v = solverFeatureValue(name).toLowerAscii()
  v in ["true", "1", "yes", "on"]

proc solverEnabledFeatures*(): seq[string] =
  ## Helper — every variant whose solver-resolved value is truthy.
  ## Diagnostic dumps and ``repro build --report`` consume this so the
  ## report can list the active feature flags.
  if not hasSolverSolution():
    return @[]
  let sol = lastSolverSolution()
  for k, v in sol.variants:
    let lower = v.toLowerAscii()
    if lower in ["true", "1", "yes", "on"]:
      result.add(k)

proc solverFeatureSet*(): FeatureSet =
  ## The stdlib's default solver-backed ``FeatureSet``. Installed into
  ## the active-build-context slot when no richer adapter is wired by
  ## a higher-priority variant.
  newFeatureSet(
    name = "solver-feature-set",
    enabled = solverFeatureEnabled,
    value = solverFeatureValue,
    allEnabled = solverEnabledFeatures)
