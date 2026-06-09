## Spec-Implementation M3 — ``FeatureSet`` cross-cutting interface.
##
## Per Reprobuild-Standard-Library §"Cross-Cutting Interfaces" /
## §"`FeatureSet`", a ``FeatureSet`` is the typed face of variant
## decisions for recipes that want to branch on multiple feature flags
## at once without scattering ``if`` checks across their ``build:``
## body. The interface is vtable-shaped so adapter packages can
## contribute richer implementations (e.g. one that materialises a
## feature DAG and reports the chosen leaves).
##
## The M3 methods are ``enabled``, ``value``, and ``allEnabled``. The
## default implementation reads from the M2d solver's resolved
## variants — when a boolean variant resolves to ``true`` the feature
## is enabled; when an enum variant resolves to a string value the
## feature's ``value`` returns that string. M4+ adapter packages can
## supply richer implementations.

import std/[strutils, tables]

type
  FeatureSet* = ref object of RootObj
    ## Vtable for a feature-set adapter. Stored on
    ## ``PackageBuildState.featureSetSlot`` as a ``RootRef``.
    name*: string
      ## Adapter identity, e.g. ``"solver-feature-set"``,
      ## ``"static-feature-set"``.
    enabled*: proc(name: string): bool
      ## True iff the named feature is currently enabled. Adapter
      ## packages may return ``false`` for unknown features rather
      ## than raising; the spec's ``isEnabled`` semantics are
      ## intentionally lenient so a recipe's
      ## ``if features.enabled("tls"): ...`` works in environments
      ## where the variant isn't declared.
    value*: proc(name: string): string
      ## The string-rendered value the underlying variant resolved to.
      ## For a boolean variant this is ``"true"`` / ``"false"``; for
      ## an enum it's the chosen string. Returns ``""`` when the
      ## feature isn't in the resolved set.
    allEnabled*: proc(): seq[string]
      ## Lists every feature name the adapter considers enabled.
      ## Useful for diagnostic dumps and for the "list active
      ## features" surface of ``repro build --report``.

proc newFeatureSet*(
    name: string;
    enabled: proc(name: string): bool;
    value: proc(name: string): string;
    allEnabled: proc(): seq[string]
    ): FeatureSet =
  FeatureSet(
    name: name,
    enabled: enabled,
    value: value,
    allEnabled: allEnabled)

proc validate*(f: FeatureSet) =
  doAssert f != nil,
    "FeatureSet is nil — the active build context's featureSet slot " &
    "was never populated"
  doAssert f.name.len > 0,
    "FeatureSet.name is empty — every adapter must set its identity"
  doAssert f.enabled != nil,
    "FeatureSet.enabled is nil — adapter '" & f.name & "' is incomplete"
  doAssert f.value != nil,
    "FeatureSet.value is nil — adapter '" & f.name & "' is incomplete"
  doAssert f.allEnabled != nil,
    "FeatureSet.allEnabled is nil — adapter '" & f.name &
      "' is incomplete"

# ---------------------------------------------------------------------
# Static-feature-set helper.
#
# A trivial ``FeatureSet`` adapter that wraps an explicit
# ``Table[string, string]`` of feature → value pairs. The default
# stdlib slot installs an empty static set so a recipe that calls
# ``features.enabled("tls")`` returns ``false`` rather than raising
# when no solver-backed adapter is wired. The solver-backed
# implementation lives in ``adapters/solver_feature_set.nim``.
# ---------------------------------------------------------------------

proc newStaticFeatureSet*(values: Table[string, string]): FeatureSet =
  ## A tiny ``FeatureSet`` that answers from an explicit table.
  ## Recipes use this in tests when they want a deterministic feature
  ## state without driving the full solver.
  let snapshot = values
  proc enabledImpl(name: string): bool =
    if name notin snapshot: return false
    let v = snapshot[name].toLowerAscii()
    v in ["true", "1", "yes", "on"]
  proc valueImpl(name: string): string =
    if name notin snapshot: return ""
    snapshot[name]
  proc allEnabledImpl(): seq[string] =
    for k, v in snapshot:
      let lower = v.toLowerAscii()
      if lower in ["true", "1", "yes", "on"]:
        result.add(k)
  newFeatureSet(
    name = "static-feature-set",
    enabled = enabledImpl,
    value = valueImpl,
    allEnabled = allEnabledImpl)
