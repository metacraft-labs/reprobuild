## ``repro_solver/variant_encoder`` — Spec-Implementation M2b ASP
## encoder for solver-participating Configurables (variants).
##
## Walks an in-memory variant registry (``openArray[VariantDecl]``)
## and emits a clingo-compatible ASP program text the M2b driver
## (``solver_api.solveVariants``) feeds into ``libclingo.so`` through
## the M2a bindings.
##
## ## Encoding overview
##
## The encoder lowers four orthogonal pieces onto a single
## ``#program base.`` body:
##
## 1. **Universe.** One ``variant_value("name", "v").`` fact per
##    declared candidate value. Bool variants emit the two-element
##    ``true``/``false`` universe verbatim; enum variants emit one
##    fact per declared value.
## 2. **Cardinality.** A choice rule ``{ variant_assigned("v", X) :
##    variant_value("v", X) } = 1.`` per variant. Exactly one
##    candidate fires; clingo's stable-model semantics rules out the
##    empty and the multi-assignment cases.
## 3. **Priority lattice.** Each contribution emits a
##    ``priority("name", "v", PriorityInt).`` fact whose
##    ``PriorityInt`` matches the same ``prDefault < prSet <
##    prOverride < prForce`` ordering the M1 ``evalConfig`` finalize
##    path uses. The final ``#minimize`` directive sums the priority
##    of the chosen assignment so the solver picks the highest-band
##    contribution. We encode the band as ``(4 - priority)`` — small
##    values win when minimizing — and stamp it as a weight in
##    ``#minimize { Weight, "name", X : variant_assigned("name", X),
##    priority("name", X, Priority), Weight = 4 - Priority }.``.
##    A variant with NO contribution falls back to the default-band
##    universe entry; if no default is registered the variant is
##    still solvable (any value the cardinality picks is fine) but
##    no preference is expressed.
## 4. **Constraint expressions.** The three forms from
##    ``Configurable-System.md`` §"Constraint Expressions" lower to
##    integrity constraints:
##
##    * ``requires:``  ``:- variant_assigned("A","x"),
##                          not variant_assigned("B","y").``
##    * ``conflicts:`` ``:- variant_assigned("A","x"),
##                          variant_assigned("B","y").``
##    * ``propagates:`` (within-package, M2b scope) — same shape as
##      ``requires:``. Cross-package propagation is M2c.
##
## ## Why a richer ``VariantDecl`` here than the parser ships
##
## The parser-side ``VariantDecl`` in
## ``libs/repro_project_dsl/types.nim`` is a minimal record
## (``name``, ``nimType``, ``defaultExpr``). It does NOT carry the
## ``requires:`` / ``conflicts:`` / ``propagates:`` lists or the
## enum universe, because the M1 parser had nothing to do with
## constraints. The encoder is a new library: it carries its own
## richer data model so M2b–M2e have a stable typed surface that
## doesn't ripple changes back into the M1 parser. M2d wires the
## parser's per-package ``VariantDecl`` records into ``encodeVariants``'s
## input by widening the parser surface; that wiring is deliberately
## OUT of M2b scope.

import std/[strutils, tables]

# ---------------------------------------------------------------------------
# Public data model
# ---------------------------------------------------------------------------

type
  VariantKind* = enum
    vkBool        ## Bool variant: universe is ``true``/``false``.
    vkEnum        ## Enumerated variant: universe is the declared values.
    vkInt         ## Integer variant: universe is the declared values.
    vkString      ## String variant: universe is the declared values.

  VariantPriority* = enum
    ## Same lattice as ``types.ContributionPriority``. Reproduced here
    ## so the encoder library has no compile-time dependency on the
    ## DSL stdlib's ``Configurable`` type tree — M2b's encoder is a
    ## leaf library that wraps clingo and nothing else.
    vpDefault = 0
    vpSet = 1
    vpOverride = 2
    vpForce = 3

  VariantContribution* = object
    ## A single (priority, value) contribution against a variant. The
    ## M1 lattice rule (``prDefault < prSet < prOverride < prForce``)
    ## means the encoder prefers contributions with higher priority.
    ## ``value`` is the candidate value as the string the universe
    ## fact carries.
    priority*: VariantPriority
    value*: string

  VariantConstraintKind* = enum
    ## The three constraint forms from ``Configurable-System.md``
    ## §"Constraint Expressions".
    crkRequires      ## ``requires: B == "y"`` — if A=x then B must be y.
    crkConflicts     ## ``conflicts: B == "y"`` — A=x and B=y is forbidden.
    crkPropagates    ## ``propagates: B == "y"`` — A=x forces B=y.

  ConstraintExpr* = object
    ## A constraint expression attached to a variant declaration. The
    ## source variant's value (``source``=``"x"``) triggers the rule;
    ## the constraint targets a sibling variant (``target``) at value
    ## ``targetValue``. For bool sources, the trigger value is
    ## conventionally ``"true"``.
    kind*: VariantConstraintKind
    sourceValue*: string
    target*: string
    targetValue*: string

  VariantDecl* = object
    ## One variant in the encoder's input registry. The encoder reads
    ## ``name`` as the ASP atom key, ``kind`` to pick the universe
    ## emission strategy, ``allowedValues`` for the enum / int / string
    ## universe (ignored for ``vkBool``), ``contributions`` for the
    ## priority lattice, and ``constraints`` for cross-variant rules.
    name*: string
    kind*: VariantKind
    allowedValues*: seq[string]
    contributions*: seq[VariantContribution]
    constraints*: seq[ConstraintExpr]

# ---------------------------------------------------------------------------
# Constructors (keep test-side construction terse)
# ---------------------------------------------------------------------------

proc newBoolVariant*(name: string;
                     contributions: openArray[VariantContribution] = @[];
                     constraints: openArray[ConstraintExpr] = @[]):
                     VariantDecl =
  VariantDecl(name: name, kind: vkBool,
              allowedValues: @["true", "false"],
              contributions: @contributions,
              constraints: @constraints)

proc newEnumVariant*(name: string; values: openArray[string];
                     contributions: openArray[VariantContribution] = @[];
                     constraints: openArray[ConstraintExpr] = @[]):
                     VariantDecl =
  VariantDecl(name: name, kind: vkEnum,
              allowedValues: @values,
              contributions: @contributions,
              constraints: @constraints)

proc contribution*(priority: VariantPriority; value: string):
                  VariantContribution =
  VariantContribution(priority: priority, value: value)

proc requiresExpr*(sourceValue, target, targetValue: string): ConstraintExpr =
  ConstraintExpr(kind: crkRequires, sourceValue: sourceValue,
                 target: target, targetValue: targetValue)

proc conflictsExpr*(sourceValue, target, targetValue: string): ConstraintExpr =
  ConstraintExpr(kind: crkConflicts, sourceValue: sourceValue,
                 target: target, targetValue: targetValue)

proc propagatesExpr*(sourceValue, target, targetValue: string): ConstraintExpr =
  ConstraintExpr(kind: crkPropagates, sourceValue: sourceValue,
                 target: target, targetValue: targetValue)

# ---------------------------------------------------------------------------
# Encoding helpers
# ---------------------------------------------------------------------------

proc aspQuote(s: string): string =
  ## Escape a Nim string for use inside a clingo string literal.
  ## clingo strings are double-quoted and use backslash for escape;
  ## we cover the two cases that actually occur in variant names and
  ## values (backslash and double-quote) and leave everything else
  ## verbatim. clingo accepts UTF-8 inside string literals so the
  ## variant names like ``mpiEnabled`` need no transformation.
  result = newStringOfCap(s.len + 2)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    else: result.add(c)

proc priorityWeight(priority: VariantPriority): int =
  ## Encode the priority as a ``#minimize`` weight. ``prDefault``
  ## maps to 4 (least preferred when minimizing); ``prForce`` maps
  ## to 1 (most preferred). The exact numbers do not matter beyond
  ## the strict-monotone order — the solver only ever compares sums
  ## of weights, and our encoding never has more than one
  ## contribution active per (variant, value) at solve time so the
  ## per-band gap is enough for the lattice to dominate.
  4 - int(priority)

proc effectiveValues(v: VariantDecl): seq[string] =
  ## Return the universe of allowed values for ``v``. For bool variants
  ## the universe is fixed; for the other kinds we use the declared
  ## ``allowedValues``. We additionally fold in the values of every
  ## contribution so a higher-priority contribution that names a
  ## value outside the declared set still appears in the universe
  ## (the cardinality constraint will then force the solver to pick
  ## one of these). Out-of-set diagnostics belong to a future M2e
  ## pass; for M2b we accept the contribution as authoritative.
  case v.kind
  of vkBool:
    result = @["true", "false"]
  else:
    result = v.allowedValues
  for c in v.contributions:
    if c.value notin result:
      result.add(c.value)

# ---------------------------------------------------------------------------
# Universe + cardinality
# ---------------------------------------------------------------------------

proc encodeUniverseFacts*(v: VariantDecl): string =
  ## Emit one ``variant_value("name", "value").`` fact per allowed
  ## value. The fact predicate is what every other rule predicates
  ## over, so this is the encoding's anchor.
  var parts: seq[string] = @[]
  for value in effectiveValues(v):
    parts.add("variant_value(\"" & aspQuote(v.name) & "\", \"" &
              aspQuote(value) & "\").")
  parts.join("\n")

proc encodeCardinality*(v: VariantDecl): string =
  ## Emit a choice rule that forces exactly-one ``variant_assigned``
  ## per variant. Clingo's ``{ ... } = N`` form lifts the lower and
  ## upper bound onto the candidate set in one shot.
  "{ variant_assigned(\"" & aspQuote(v.name) & "\", X) : " &
    "variant_value(\"" & aspQuote(v.name) & "\", X) } = 1."

# ---------------------------------------------------------------------------
# Priority lattice
# ---------------------------------------------------------------------------

proc encodePriorityFacts*(v: VariantDecl): string =
  ## Emit one ``priority("name", "value", weight).`` fact per
  ## contribution against the variant. The ``#minimize`` block at
  ## the end of the program references these facts to bias the
  ## solver toward the highest-priority contribution.
  var parts: seq[string] = @[]
  # Track the best (lowest-weight) priority per value across multiple
  # contributions targeting the same value — only that one matters
  # for the minimize sum since we encode one priority fact per
  # (variant, value) pair.
  var bestByValue: Table[string, int]
  for c in v.contributions:
    let w = priorityWeight(c.priority)
    if c.value in bestByValue:
      if w < bestByValue[c.value]:
        bestByValue[c.value] = w
    else:
      bestByValue[c.value] = w
  for value, weight in bestByValue:
    parts.add("priority(\"" & aspQuote(v.name) & "\", \"" &
              aspQuote(value) & "\", " & $weight & ").")
  # Values with NO contribution receive a synthetic "no preference"
  # weight of 5 (worse than vpDefault=4) so the solver actively
  # prefers any contribution to none. This matters when no default
  # contribution exists and the universe has multiple candidates.
  for value in effectiveValues(v):
    if value notin bestByValue:
      parts.add("priority(\"" & aspQuote(v.name) & "\", \"" &
                aspQuote(value) & "\", 5).")
  parts.join("\n")

# ---------------------------------------------------------------------------
# Constraint expressions
# ---------------------------------------------------------------------------

proc encodeConstraint*(v: VariantDecl; c: ConstraintExpr): string =
  ## Lower one constraint expression to its integrity-constraint shape.
  ## The three kinds share a body prefix (``variant_assigned("A","x"),``)
  ## and differ on the target predication. ``propagates:`` lowers to
  ## the same shape as ``requires:`` in M2b — within a single package
  ## variant set a propagation is just a forced equality.
  let srcAtom = "variant_assigned(\"" & aspQuote(v.name) & "\", \"" &
                aspQuote(c.sourceValue) & "\")"
  let tgtAtom = "variant_assigned(\"" & aspQuote(c.target) & "\", \"" &
                aspQuote(c.targetValue) & "\")"
  case c.kind
  of crkRequires, crkPropagates:
    ":- " & srcAtom & ", not " & tgtAtom & "."
  of crkConflicts:
    ":- " & srcAtom & ", " & tgtAtom & "."

proc encodeConstraintExpressions*(v: VariantDecl): string =
  var parts: seq[string] = @[]
  for c in v.constraints:
    parts.add(encodeConstraint(v, c))
  parts.join("\n")

# ---------------------------------------------------------------------------
# Top-level: full program text
# ---------------------------------------------------------------------------

proc encodeMinimize(variants: openArray[VariantDecl]): string =
  ## Emit the global ``#minimize`` directive that sums priority weights
  ## across every active assignment. One block — clingo merges
  ## multi-term minimize directives if any future work splits this.
  if variants.len == 0:
    return ""
  # Use the four-place form so the per-variant per-value contributions
  # are aggregated by clingo's #minimize accumulator. Without the
  # name-and-value terms in the tuple, clingo would deduplicate
  # equal-weight terms and silently lose contributions.
  "#minimize { Weight,Name,Value : variant_assigned(Name, Value), " &
    "priority(Name, Value, Weight) }."

proc encodeShow(): string =
  ## Restrict the solver's printed model to ``variant_assigned`` atoms.
  ## Without ``#show``, every grounded atom (including the universe
  ## and priority facts) appears in the model, which makes parsing
  ## the result back into a ``VariantSolution`` noisier than needed.
  "#show variant_assigned/2."

proc encodeVariants*(variants: openArray[VariantDecl]): string =
  ## Walk the variant registry and emit a clingo-compatible ASP
  ## program. The returned string includes the universe atoms, the
  ## cardinality constraints, the priority-lattice optimization, and
  ## the constraint expressions translated from
  ## ``requires:`` / ``conflicts:`` / ``propagates:``.
  ##
  ## The output is meant to be passed verbatim to
  ## ``clingo_control_add(control, "base", nil, 0, programCstring)``;
  ## see ``solver_api.solveVariants`` for the driver that closes the
  ## loop.
  var sections: seq[string] = @[]
  for v in variants:
    let universe = encodeUniverseFacts(v)
    if universe.len > 0:
      sections.add(universe)
    sections.add(encodeCardinality(v))
    let priorities = encodePriorityFacts(v)
    if priorities.len > 0:
      sections.add(priorities)
    let constraints = encodeConstraintExpressions(v)
    if constraints.len > 0:
      sections.add(constraints)
  let minimize = encodeMinimize(variants)
  if minimize.len > 0:
    sections.add(minimize)
  sections.add(encodeShow())
  sections.join("\n") & "\n"
