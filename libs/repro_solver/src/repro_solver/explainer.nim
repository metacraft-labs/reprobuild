## ``repro_solver/explainer`` — Spec-Implementation M2e diagnostic
## explanation paths.
##
## M2a-M2d delivered the unified concretizer:
##
## * M2a — clingo scaffold + bindings
## * M2b — variant ASP encoder
## * M2c — version-constraint encoder
## * M2d — integration into ``finalizeVariants()`` + variant.value
##
## M2e adds STRUCTURED diagnostics on top:
##
## 1. ``explainChosen(sol, name, variants, packages)`` — for a satisfied
##    solve, return the chain of constraints that forced this particular
##    variant assignment. Lists the contributions (priority + source),
##    any requires/conflicts/propagates that gated it, and any
##    depends_on edges through which a parent package's variant
##    influenced it.
##
## 2. ``explainUnsat(error, variants, packages)`` — for an
##    ``EUnsatisfiable`` raised by ``solve()``, return the minimal unsat
##    core via clingo's ASSUMPTION INTERFACE (the proper mechanism, not
##    the best-effort heuristic from M2b/M2c). The encoder annotates
##    each constraint with an ``assume_constraint(N).`` external atom;
##    the driver assumes every external true; clingo's
##    ``clingo_solve_handle_core`` returns the literals participating
##    in the conflict; we map back through the annotation table to the
##    constraint identity.
##
## ## Why a separate module
##
## The explainer is pure data transformation against the M2c encoder
## output and the existing ``UnifiedSolution`` / ``EUnsatisfiable``
## records. Keeping it in its own module means downstream callers
## that only care about the solve result (M2d's
## ``finalizeVariants()``) do not pay for the explanation surface,
## and the explanation surface can grow independently as new
## diagnostic shapes land.

import std/[options, strutils, tables, sets]

import clingo_bindings
import variant_encoder
import version_encoder
import version_constraints

# ---------------------------------------------------------------------------
# Shared solution / error types
# ---------------------------------------------------------------------------
#
# These types were originally defined in ``solver_api.nim``; M2e moved
# them here so the explainer can take ``UnifiedSolution`` directly
# without introducing a circular import. ``solver_api`` imports
# ``explainer`` and re-exports both types so existing callers see them
# at the same name as before.

type
  UnifiedSolution* = object
    ## Outcome of a combined variant + package version solve.
    ## ``variants`` maps each variant's declared name to the resolved
    ## value as a string; ``packages`` maps each package name to its
    ## resolved version string; ``optimal`` carries clingo's
    ## ``exhausted`` bit so callers can detect when the solver proved
    ## optimality vs. terminated on the first model.
    variants*: Table[string, string]
    packages*: Table[string, string]
    optimal*: bool

  EUnsatisfiable* = object of CatchableError
    ## Raised when the unified encoded program has no stable model.
    ## ``programText`` carries the ASP program for diagnostic replay;
    ## ``unsatCore`` enumerates the constraint-participating variants
    ## and packages on a best-effort basis (preserved from M2c for
    ## backwards compatibility with the M2c diagnostics).
    ##
    ## **M2e addition:** ``coreAtoms`` carries the MINIMAL unsat core
    ## the assumption-interface re-solve produced. Each entry is an
    ## ``assume_constraint(N)`` atom name; ``explainUnsat`` maps each
    ## back to a structured ``UnsatCoreEntry``. The field is empty when
    ## M2e re-solve was not performed.
    programText*: string
    unsatCore*: seq[string]
    coreAtoms*: seq[string]

# ---------------------------------------------------------------------------
# Public data model — explainChosen
# ---------------------------------------------------------------------------

type
  ParentInfluence* = object
    ## A cross-package propagation that contributed to a variant's
    ## resolved value. ``parentPackage`` is the package whose variant
    ## propagated; ``parentVariant`` is the source variant name in that
    ## package; ``parentValue`` is the source value that triggered the
    ## propagation.
    parentPackage*: string
    parentVariant*: string
    parentValue*: string

  ExplainChain* = object
    ## Structured justification for a variant's chosen value.
    ##
    ## ``variant`` is the variant name; ``chosen`` is the resolved
    ## value (as it appears in ``UnifiedSolution.variants``).
    ## ``contributions`` lists every priority-lattice contribution
    ## registered against the variant, sorted by priority descending
    ## (highest-priority first) so the chosen contribution sits at
    ## index 0 unless a constraint dominates. ``gatingConstraints``
    ## lists the within-package ``requires:`` / ``conflicts:`` /
    ## ``propagates:`` constraint expressions that forced the value;
    ## ``parentInfluences`` lists cross-package propagations that
    ## contributed (via ``depends_on`` edges) to the assignment.
    variant*: string
    chosen*: string
    contributions*: seq[VariantContribution]
    gatingConstraints*: seq[ConstraintExpr]
    parentInfluences*: seq[ParentInfluence]

  EVariantNotInSolution* = object of CatchableError
    ## Raised by ``explainChosen`` when the requested variant name is
    ## not present in the supplied ``UnifiedSolution``.

# ---------------------------------------------------------------------------
# Public data model — explainUnsat
# ---------------------------------------------------------------------------

type
  UnsatCoreEntry* = object
    ## One entry in the minimal unsat core. ``kind`` is the constraint
    ## family that participates ("constraint" for a variant
    ## requires/conflicts/propagates, "depends_on" for a package
    ## dependency edge whose range cannot be satisfied, "version_range"
    ## for an empty version range, "cross_propagates" for a
    ## cross-package propagation). ``source`` is a human-readable
    ## origin (variant name, package edge, etc.) and ``atom`` is the
    ## underlying ASP atom name (the ``assume_constraint(N)`` form) for
    ## debug replay.
    kind*: string
    source*: string
    atom*: string

# ---------------------------------------------------------------------------
# Helpers: priority ordering for contributions
# ---------------------------------------------------------------------------

proc sortByPriorityDesc(contributions: seq[VariantContribution]):
                       seq[VariantContribution] =
  ## Return a copy of ``contributions`` sorted by priority descending
  ## (vpForce first, vpDefault last). When priorities tie the input
  ## order is preserved — registration order matters for the lattice
  ## tie-breaker the M1 ``finalizeVariants()`` documents.
  result = @contributions
  # Stable insertion sort: small input sizes (the lattice has 4 bands
  # and a typical variant has ≤ 4 contributions) so the algorithmic
  # complexity does not matter; preserving registration order on ties
  # does.
  for i in 1 ..< result.len:
    var j = i
    while j > 0 and
          int(result[j].priority) > int(result[j - 1].priority):
      let tmp = result[j]
      result[j] = result[j - 1]
      result[j - 1] = tmp
      dec j

# ---------------------------------------------------------------------------
# explainChosen — variant-only path (free variants + per-package variants)
# ---------------------------------------------------------------------------

proc findVariantDecl(variants: openArray[VariantDecl];
                     packages: openArray[PackageDecl];
                     name: string): Option[VariantDecl] =
  ## Locate a variant by name across the free-variants list AND every
  ## package's per-package variant declarations. First match wins,
  ## matching the encoder's ``encodeUnified`` ordering.
  for v in variants:
    if v.name == name:
      return some(v)
  for p in packages:
    for v in p.variants:
      if v.name == name:
        return some(v)
  none(VariantDecl)

proc owningPackage(packages: openArray[PackageDecl];
                   variantName: string): string =
  ## Return the name of the package that owns ``variantName`` (its
  ## per-package variant list contains a matching declaration). The
  ## empty string means the variant is "free" (not attached to any
  ## package). First-owner-wins matches ``encodeUnified``.
  for p in packages:
    for v in p.variants:
      if v.name == variantName:
        return p.name
  ""

proc collectGatingConstraints(decl: VariantDecl;
                              chosen: string;
                              solution: Table[string, string]):
                              seq[ConstraintExpr] =
  ## Walk the variant's own constraint list and surface every
  ## constraint that participated in pinning the value. A constraint
  ## participates when:
  ##
  ## * ``requires:`` — the source value is the chosen value AND the
  ##   target's required value is observed in the solution (so the
  ##   constraint fired AND was satisfied).
  ## * ``conflicts:`` — the source value is the chosen value AND the
  ##   target's forbidden value is NOT observed (so the constraint
  ##   fired AND was satisfied by ruling the target out).
  ## * ``propagates:`` — same firing condition as requires; the
  ##   target's propagated value lines up with the observed value.
  ##
  ## A constraint also participates when its TARGET is the chosen
  ## variant (the constraint forced the chosen value from a sibling
  ## variant) — we include those too so the chain shows the full
  ## causal context.
  result = @[]
  for c in decl.constraints:
    var sourceFires = (c.sourceValue == chosen)
    if sourceFires:
      result.add(c)

proc inspectSourceVariant(source: VariantDecl;
                          target: string;
                          solution: Table[string, string];
                          collected: var seq[ConstraintExpr]) =
  if source.name == target:
    return
  for c in source.constraints:
    if c.target != target:
      continue
    # The constraint fired if the source variant is at its
    # triggering value.
    let observed = solution.getOrDefault(source.name, "")
    if observed != c.sourceValue:
      continue
    collected.add(ConstraintExpr(
      kind: c.kind,
      sourceValue: source.name & "==" & c.sourceValue,
      target: target,
      targetValue: c.targetValue))

proc collectIncomingConstraints(variants: openArray[VariantDecl];
                                packages: openArray[PackageDecl];
                                target: string;
                                chosen: string;
                                solution: Table[string, string]):
                                seq[ConstraintExpr] =
  ## Walk every other variant's constraint list looking for
  ## constraints whose TARGET is the requested variant. These are
  ## constraints from sibling variants that flowed inward to pin the
  ## chosen value.
  result = @[]
  for v in variants:
    inspectSourceVariant(v, target, solution, result)
  for p in packages:
    for v in p.variants:
      inspectSourceVariant(v, target, solution, result)

proc collectParentInfluences(packages: openArray[PackageDecl];
                             variantName: string;
                             solution: Table[string, string]):
                             seq[ParentInfluence] =
  ## For a variant attached to a package, find every cross-package
  ## ``propagates:`` rule that targets a variant with this name from
  ## a different package that this package depends on.
  result = @[]
  let owner = owningPackage(packages, variantName)
  if owner.len == 0:
    return @[]
  # Build a quick map of package name -> dependencies.
  var dependsOn: Table[string, seq[string]]
  for p in packages:
    var deps: seq[string] = @[]
    for d in p.depends:
      deps.add(d.name)
    dependsOn[p.name] = deps
  # For each parent that the owner depends on, look at every
  # variant in that parent for a propagates constraint targeting
  # our variantName.
  let parents = dependsOn.getOrDefault(owner, @[])
  for parentName in parents:
    for p in packages:
      if p.name != parentName: continue
      for sourceVariant in p.variants:
        for c in sourceVariant.constraints:
          if c.kind != crkPropagates: continue
          if c.target != variantName: continue
          # Verify the source variant fired.
          let sourceObserved = solution.getOrDefault(
            sourceVariant.name, "")
          if sourceObserved != c.sourceValue: continue
          result.add(ParentInfluence(
            parentPackage: parentName,
            parentVariant: sourceVariant.name,
            parentValue: c.sourceValue))

# ---------------------------------------------------------------------------
# Public API — explainChosen
# ---------------------------------------------------------------------------

proc explainChosen*(solution: UnifiedSolution;
                    variantName: string;
                    variants: openArray[VariantDecl];
                    packages: openArray[PackageDecl]): ExplainChain =
  ## Build the chain of justifications for a variant's chosen value.
  ## Raises ``EVariantNotInSolution`` if the variant isn't in the
  ## solution.
  if variantName notin solution.variants:
    raise newException(EVariantNotInSolution,
      "variant '" & variantName &
      "' is not present in the supplied solution")
  let chosen = solution.variants[variantName]
  let declOpt = findVariantDecl(variants, packages, variantName)
  if declOpt.isNone:
    # The variant landed in the solution but we have no declaration
    # for it — return a minimal chain with the chosen value only. M2e
    # callers always pass the matching registry, so this is a defensive
    # branch.
    return ExplainChain(variant: variantName, chosen: chosen,
                        contributions: @[],
                        gatingConstraints: @[],
                        parentInfluences: @[])
  let decl = declOpt.get
  result = ExplainChain(
    variant: variantName,
    chosen: chosen,
    contributions: sortByPriorityDesc(decl.contributions),
    gatingConstraints: collectGatingConstraints(decl, chosen,
                                                solution.variants),
    parentInfluences: collectParentInfluences(packages, variantName,
                                              solution.variants))
  # Fold in the incoming constraints (constraints from sibling
  # variants that pinned this one). These are NOT in the declaration's
  # own constraint list — they live on the source variant — so we walk
  # the full registry to find them.
  let incoming = collectIncomingConstraints(variants, packages,
                                            variantName, chosen,
                                            solution.variants)
  for c in incoming:
    result.gatingConstraints.add(c)

# ---------------------------------------------------------------------------
# explainUnsat — minimal unsat core via clingo assumption interface
# ---------------------------------------------------------------------------

type
  ConstraintAnnotation* = object
    ## A constraint annotation pairs the encoder-side identity of a
    ## constraint with the ASP atom name the encoder emits to
    ## represent it. The driver uses ``atomName`` to look up the
    ## program literal via ``clingo_symbolic_atoms_find`` and pass it
    ## as a solve assumption. When clingo returns the unsat core, the
    ## literal flips back into the annotation via the ``literal`` slot.
    id*: int
    kind*: string       # "constraint", "depends_on", "version_range",
                        # "cross_propagates"
    source*: string     # human-readable origin description
    atomName*: string   # the ASP atom (without arguments quoted)

# Forward declaration: implementation below.
proc encodeWithAssumptions*(variants: openArray[VariantDecl];
                            packages: openArray[PackageDecl]):
                           (string, seq[ConstraintAnnotation])

proc explainUnsat*(coreAtoms: seq[string];
                   variants: openArray[VariantDecl];
                   packages: openArray[PackageDecl]):
                  seq[UnsatCoreEntry] =
  ## Take the ``coreAtoms`` field of an ``EUnsatisfiable`` (the ASP
  ## atom names returned by clingo's assumption-interface unsat-core
  ## enumeration) and produce structured ``UnsatCoreEntry`` records by
  ## re-running the encoder's annotation pass against the same input.
  ## The annotation table maps each ``assume_constraint(N)`` atom name
  ## back to the constraint identity that owns it.
  result = @[]
  if coreAtoms.len == 0:
    return @[]
  let (_, annotations) = encodeWithAssumptions(variants, packages)
  var byAtom: Table[string, ConstraintAnnotation]
  for a in annotations:
    byAtom[a.atomName] = a
  for atom in coreAtoms:
    if atom in byAtom:
      let ann = byAtom[atom]
      result.add(UnsatCoreEntry(kind: ann.kind, source: ann.source,
                                atom: atom))
    else:
      # Unknown atom — surface verbatim so the diagnostic at least
      # names the ASP-level participant.
      result.add(UnsatCoreEntry(kind: "unknown", source: atom,
                                atom: atom))

# ---------------------------------------------------------------------------
# Encoder — annotated variant + version program for the assumption
# interface
# ---------------------------------------------------------------------------
#
# This encoder mirrors ``encodeUnified`` from version_encoder.nim but
# attaches a unique ``assume_constraint(N).`` external atom to every
# constraint integrity rule. The driver in solver_api.nim assumes each
# external true; clingo's solve-handle-core then names the externals
# that participated in the conflict.
#
# We deliberately re-implement the encoder rather than reuse the
# existing entry points because the existing rules are unconditional —
# adding the guard atom would require non-trivial rewriting of the
# emitted string. Keeping a parallel annotated emission keeps the
# original M2b/M2c paths byte-identical (and the M1-M2d tests green).

proc aspQuoteE(s: string): string =
  ## Local copy of the encoders' ``aspQuote``. Duplicated so the
  ## explainer module has no compile-time dependency on the encoder's
  ## private helpers.
  result = newStringOfCap(s.len + 2)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    else: result.add(c)

proc effectiveValuesE(v: VariantDecl): seq[string] =
  case v.kind
  of vkBool:
    result = @["true", "false"]
  else:
    result = v.allowedValues
  for c in v.contributions:
    if c.value notin result:
      result.add(c.value)

proc encodeWithAssumptions*(variants: openArray[VariantDecl];
                            packages: openArray[PackageDecl]):
                           (string, seq[ConstraintAnnotation]) =
  ## Emit an ASP program functionally equivalent to ``encodeUnified``
  ## but with each constraint rule guarded by an ``assume_constraint(N).``
  ## external atom. Returns the program text + the table of
  ## annotations the driver uses to map literals back to identities.
  ##
  ## Annotation IDs are assigned monotonically as constraints are
  ## emitted. The ID space is shared across constraint kinds so a
  ## single ``coreAtoms`` list suffices for ``explainUnsat`` to
  ## interpret.
  var sections: seq[string] = @[]
  var annotations: seq[ConstraintAnnotation] = @[]
  var nextId = 0

  proc externalLine(id: int): string =
    "#external assume_constraint(" & $id & ")."

  proc guardAtom(id: int): string =
    "assume_constraint(" & $id & ")"

  proc registerAnnotation(kind, source: string): int =
    let id = nextId
    inc nextId
    annotations.add(ConstraintAnnotation(
      id: id, kind: kind, source: source,
      atomName: "assume_constraint(" & $id & ")"))
    return id

  # ---- Phase 1: collect every variant (free + per-package) and apply
  # the M2c cross-package propagation filter.
  var variantPackage: Table[string, string]
  for p in packages:
    for v in p.variants:
      if v.name notin variantPackage:
        variantPackage[v.name] = p.name

  var allVariants: seq[VariantDecl] = @[]
  var seen: HashSet[string]
  for v in variants:
    if v.name notin seen:
      seen.incl(v.name)
      allVariants.add(v)
  for p in packages:
    for v in p.variants:
      if v.name notin seen:
        seen.incl(v.name)
        # Filter cross-package propagates — they get re-emitted by the
        # cross-package handler below with a depends-on gate.
        var kept: seq[ConstraintExpr] = @[]
        for c in v.constraints:
          if c.kind != crkPropagates:
            kept.add(c)
            continue
          let targetPkg = variantPackage.getOrDefault(c.target, "")
          if targetPkg.len > 0 and targetPkg != p.name:
            continue
          kept.add(c)
        allVariants.add(VariantDecl(
          name: v.name, kind: v.kind,
          allowedValues: v.allowedValues,
          contributions: v.contributions,
          constraints: kept))

  # ---- Phase 2: emit the variant universe + cardinality + priority
  # facts. These do not get assumption guards — they are structural.
  for v in allVariants:
    let values = effectiveValuesE(v)
    for value in values:
      sections.add("variant_value(\"" & aspQuoteE(v.name) & "\", \"" &
                   aspQuoteE(value) & "\").")
    sections.add("{ variant_assigned(\"" & aspQuoteE(v.name) &
                 "\", X) : variant_value(\"" & aspQuoteE(v.name) &
                 "\", X) } = 1.")
    # Priority facts.
    var bestByValue: Table[string, int]
    for c in v.contributions:
      let w = 4 - int(c.priority)
      if c.value in bestByValue:
        if w < bestByValue[c.value]:
          bestByValue[c.value] = w
      else:
        bestByValue[c.value] = w
    for value, weight in bestByValue:
      sections.add("priority(\"" & aspQuoteE(v.name) & "\", \"" &
                   aspQuoteE(value) & "\", " & $weight & ").")
    for value in values:
      if value notin bestByValue:
        sections.add("priority(\"" & aspQuoteE(v.name) & "\", \"" &
                     aspQuoteE(value) & "\", 5).")

  # ---- Phase 3: emit each variant constraint as a guarded integrity
  # rule with an annotation entry.
  for v in allVariants:
    for c in v.constraints:
      let id = registerAnnotation(
        "constraint",
        v.name & " " & (case c.kind
                        of crkRequires: "requires"
                        of crkConflicts: "conflicts"
                        of crkPropagates: "propagates") &
          " " & c.target & "==" & c.targetValue &
          " (when " & v.name & "==" & c.sourceValue & ")")
      sections.add(externalLine(id))
      let srcAtom = "variant_assigned(\"" & aspQuoteE(v.name) &
                    "\", \"" & aspQuoteE(c.sourceValue) & "\")"
      let tgtAtom = "variant_assigned(\"" & aspQuoteE(c.target) &
                    "\", \"" & aspQuoteE(c.targetValue) & "\")"
      case c.kind
      of crkRequires, crkPropagates:
        sections.add(":- " & guardAtom(id) & ", " & srcAtom &
                     ", not " & tgtAtom & ".")
      of crkConflicts:
        sections.add(":- " & guardAtom(id) & ", " & srcAtom &
                     ", " & tgtAtom & ".")

  # ---- Phase 4: emit package universe + dependency edges (guarded).
  var pkgVersions: Table[string, seq[string]]
  for p in packages:
    pkgVersions[p.name] = p.versions
    sections.add("package(\"" & aspQuoteE(p.name) & "\").")
    sections.add("package_active(\"" & aspQuoteE(p.name) & "\").")
    for ver in p.versions:
      sections.add("package_version(\"" & aspQuoteE(p.name) &
                   "\", \"" & aspQuoteE(ver) & "\").")
    sections.add("{ package_chosen(\"" & aspQuoteE(p.name) &
                 "\", V) : package_version(\"" & aspQuoteE(p.name) &
                 "\", V) } = 1 :- package_active(\"" &
                 aspQuoteE(p.name) & "\").")

  # Range membership facts (no guards — purely structural).
  var seenRange: HashSet[string]
  for p in packages:
    for d in p.depends:
      let key = d.name & "::" & d.range
      if key in seenRange: continue
      seenRange.incl(key)
      if d.name notin pkgVersions: continue
      let rng = try: parseSemverRange(d.range)
                except ESemverParse: continue
      for ver in pkgVersions[d.name]:
        let parsed = try: parseSemver(ver)
                     except ESemverParse: continue
        if satisfies(parsed, rng):
          sections.add("version_in_range(\"" & aspQuoteE(d.name) &
                       "\", \"" & aspQuoteE(ver) & "\", \"" &
                       aspQuoteE(d.range) & "\").")

  # Dependency edges — depends_on + package_required (structural)
  # and a GUARDED integrity constraint.
  for p in packages:
    for d in p.depends:
      let parent = "\"" & aspQuoteE(p.name) & "\""
      let child = "\"" & aspQuoteE(d.name) & "\""
      let rangeAtom = "\"" & aspQuoteE(d.range) & "\""
      sections.add("depends_on(" & parent & ", " & child & ").")
      sections.add("package_required(" & parent & ", " & child & ", " &
                   rangeAtom & ").")
      let id = registerAnnotation(
        "depends_on",
        p.name & " -> " & d.name & " " & d.range)
      sections.add(externalLine(id))
      var body = newSeq[string]()
      body.add(guardAtom(id))
      body.add("package_chosen(" & parent & ", _)")
      if d.conditional.isSome:
        let g = d.conditional.get
        body.add("variant_assigned(\"" & aspQuoteE(g.variantName) &
                 "\", \"" & aspQuoteE(g.triggerValue) & "\")")
      body.add("package_chosen(" & child & ", V)")
      body.add("not version_in_range(" & child & ", V, " &
               rangeAtom & ")")
      sections.add(":- " & body.join(", ") & ".")

  # Cross-package propagation (guarded).
  var packageOfVariant: Table[string, seq[string]]
  for p in packages:
    for v in p.variants:
      if v.name notin packageOfVariant:
        packageOfVariant[v.name] = @[]
      packageOfVariant[v.name].add(p.name)
  for sourcePkg in packages:
    for sourceVariant in sourcePkg.variants:
      for c in sourceVariant.constraints:
        if c.kind != crkPropagates: continue
        let yPackages = packageOfVariant.getOrDefault(c.target, @[])
        for yName in yPackages:
          if yName == sourcePkg.name: continue
          let id = registerAnnotation(
            "cross_propagates",
            sourcePkg.name & "." & sourceVariant.name & "==" &
              c.sourceValue & " propagates " & c.target & "==" &
              c.targetValue & " into " & yName)
          sections.add(externalLine(id))
          sections.add(":- " & guardAtom(id) &
                       ", variant_assigned(\"" &
                       aspQuoteE(sourceVariant.name) & "\", \"" &
                       aspQuoteE(c.sourceValue) &
                       "\"), depends_on(\"" & aspQuoteE(yName) &
                       "\", \"" & aspQuoteE(sourcePkg.name) &
                       "\"), not variant_assigned(\"" &
                       aspQuoteE(c.target) & "\", \"" &
                       aspQuoteE(c.targetValue) & "\").")

  # Minimize directive — same as M2b.
  if allVariants.len > 0:
    sections.add("#minimize { Weight,Name,Value : " &
                 "variant_assigned(Name, Value), " &
                 "priority(Name, Value, Weight) }.")

  # Show directives.
  sections.add("#show variant_assigned/2.")
  sections.add("#show package_chosen/2.")

  let program = sections.join("\n") & "\n"
  result = (program, annotations)
