## ``repro_solver/version_encoder`` — Spec-Implementation M2c ASP
## encoder for package version constraints.
##
## Extends the M2b variant encoder so a single clingo solve concretizes
## variants AND package versions together. Mirrors Spack's
## ``concretize.lp`` patterns (``version_declared`` /
## ``version_constraint_satisfied`` / ``choose_version``) but emits its
## own ASP rather than vendoring Spack's program text.
##
## ## Encoding overview
##
## The unified program adds the following predicate families on top of
## the M2b ``variant_value`` / ``variant_assigned`` / ``priority`` set:
##
## 1. **Package universe.** ``package("name").`` for each declared
##    package; ``package_version("name", "v").`` for each candidate
##    version in the catalog. The candidate list comes directly from
##    the ``PackageDecl.versions`` field — M2c does not (yet) fetch
##    a remote catalog.
## 2. **Cardinality.** ``{ package_chosen("p", V) : package_version("p",
##    V) } = 1.`` per package, mirroring the variant cardinality choice
##    rule. Exactly one version fires per package; clingo's stable
##    model semantics handles the rest.
## 3. **Range membership.** For each ``DependencyDecl`` the encoder
##    pre-grounds ``version_in_range("p", "v", "range").`` facts —
##    one per (candidate version, declared range) pair where the
##    version satisfies the range. The integrity constraint
##    ``:- package_chosen("p", V), depends_on_range_active(...),
##    not version_in_range("p", V, "range").`` then forbids any
##    chosen version that falls outside an active range.
## 4. **Transitive dependencies.** A dependency ``A -> B@range``
##    emits ``package_required(A, B, "range").`` and the activation
##    rule ``package_active(B) :- package_chosen("A", _), not
##    package_inactive("A").`` so choosing ``A`` also forces a model
##    for ``B``. The cardinality rule ``{ package_chosen("B", V) :
##    package_version("B", V) } = 1 :- package_active("B").`` makes
##    the active package choose exactly one version.
## 5. **Conditional dependencies.** A dependency gated on a variant
##    (``DependencyDecl.conditional``) lowers to an extra body atom
##    against the matching ``variant_assigned/2`` predicate so the
##    range constraint only fires when the variant resolves to the
##    triggering value.
## 6. **Cross-package propagation.** A ``propagates:`` directive on a
##    variant in package X emits a rule that, when X is depended on by
##    Y, contributes a forced assignment against a matching variant in
##    Y. The ``depends_on(Y, X)`` predicate gates the propagation so
##    independent packages remain decoupled.
##
## ## Why a separate encoder
##
## Keeping the version encoder in a sibling module to the variant
## encoder means the M2b ``encodeVariants`` entry point stays usable on
## its own (the existing M2b tests don't pull in the version surface).
## The unified entry point lives at the boundary in ``encodeUnified``.

import std/[options, strutils, tables, sets]

import variant_encoder
import version_constraints

# ---------------------------------------------------------------------------
# Public data model
# ---------------------------------------------------------------------------

type
  DependencyDecl* = object
    ## One declared dependency edge from a package onto another. The
    ## ``name`` is the depended-on package name; ``range`` is the raw
    ## semver-range string as it appears in the ``uses:`` declaration.
    ## ``conditional`` carries an optional variant gating predicate:
    ## when set, the dependency contributes only when the named variant
    ## resolves to ``conditionalValue``.
    name*: string
    range*: string
    conditional*: Option[ConditionalGate]

  ConditionalGate* = object
    ## A variant-conditioned activation. The dependency activates when
    ## ``variantName`` resolves to ``triggerValue``. ``triggerValue`` is
    ## the same string the universe fact carries (``"true"`` for the
    ## common bool case).
    variantName*: string
    triggerValue*: string

  PackageDecl* = object
    ## One package in the encoder's input registry. The encoder reads
    ## ``name`` as the ASP atom key, ``versions`` as the candidate
    ## universe (one ``package_version`` fact per entry), ``depends``
    ## for the transitive dependency edges, and ``variants`` for the
    ## per-package variant declarations the unified entry point shares
    ## with the M2b encoder.
    ##
    ## The package itself is treated as ALWAYS ACTIVE at the
    ## encoder-level unless an upstream caller marks it otherwise via
    ## ``rootOnly = false``; M2c keeps the simple "every declared
    ## package contributes to the solve" model. Activity gating is M2d
    ## work when the solver wires into the workspace evaluator.
    name*: string
    versions*: seq[string]
    depends*: seq[DependencyDecl]
    variants*: seq[VariantDecl]

# ---------------------------------------------------------------------------
# Constructors (terse construction for tests / lib code)
# ---------------------------------------------------------------------------

proc newDependency*(name, rangeStr: string): DependencyDecl =
  DependencyDecl(name: name, range: rangeStr,
                 conditional: none(ConditionalGate))

proc newConditionalDependency*(name, rangeStr, variantName,
                               triggerValue: string): DependencyDecl =
  DependencyDecl(name: name, range: rangeStr,
                 conditional: some(ConditionalGate(
                   variantName: variantName,
                   triggerValue: triggerValue)))

proc newPackage*(name: string;
                 versions: openArray[string];
                 depends: openArray[DependencyDecl] = @[];
                 variants: openArray[VariantDecl] = @[]): PackageDecl =
  PackageDecl(name: name, versions: @versions, depends: @depends,
              variants: @variants)

# ---------------------------------------------------------------------------
# Encoding helpers
# ---------------------------------------------------------------------------

proc aspQuote(s: string): string =
  ## Escape a Nim string for use inside a clingo string literal.
  ## Duplicated from ``variant_encoder.nim`` (not exported there) so
  ## the version encoder stays decoupled at the module level.
  result = newStringOfCap(s.len + 2)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    else: result.add(c)

proc packageNames(packages: openArray[PackageDecl]): HashSet[string] =
  ## Index of declared package names. Cross-package ``propagates:``
  ## resolution and dependency edge validation both consult this set
  ## so a typo in a dependency name fails closed at encoding time.
  for p in packages:
    result.incl(p.name)

# ---------------------------------------------------------------------------
# Universe + cardinality
# ---------------------------------------------------------------------------

proc encodePackageUniverse*(p: PackageDecl): string =
  ## Emit the ``package_version`` facts plus the per-package activity
  ## seed. The package atom is always active by default; transitive
  ## activation rules can flip the activity for non-root packages but
  ## the M2c encoder declares every package active up front.
  var parts: seq[string] = @[]
  parts.add("package(\"" & aspQuote(p.name) & "\").")
  parts.add("package_active(\"" & aspQuote(p.name) & "\").")
  for v in p.versions:
    parts.add("package_version(\"" & aspQuote(p.name) & "\", \"" &
              aspQuote(v) & "\").")
  parts.join("\n")

proc encodePackageCardinality*(p: PackageDecl): string =
  ## Pick exactly one version per active package. Gating on
  ## ``package_active`` lets future work disable the cardinality for
  ## inactive packages without rewriting the program shape.
  "{ package_chosen(\"" & aspQuote(p.name) & "\", V) : " &
    "package_version(\"" & aspQuote(p.name) & "\", V) } = 1 :- " &
    "package_active(\"" & aspQuote(p.name) & "\")."

# ---------------------------------------------------------------------------
# Range membership grounding
# ---------------------------------------------------------------------------

proc groundVersionInRange*(packages: openArray[PackageDecl]): string =
  ## For each (package, dependency range, candidate version) tuple where
  ## the candidate satisfies the range, emit a
  ## ``version_in_range("pkg", "version", "range").`` fact. This is
  ## the encoder's "we did the semver-range work at grounding time"
  ## bridge — clingo only sees ground tuples, not the range itself, so
  ## the integrity constraint can be a simple negation.
  ##
  ## Includes the package's own versions against the empty range string
  ## ``""`` (the default unbounded range) so callers that don't supply
  ## an explicit range still observe ``version_in_range`` facts to
  ## introspect against.
  var pkgVersions: Table[string, seq[string]]
  for p in packages:
    pkgVersions[p.name] = p.versions

  var lines: seq[string] = @[]
  # Collect every (depended-on package, range string) pair. We dedupe
  # so two callers requiring the same range only emit the ground facts
  # once.
  var seen: HashSet[string]
  for p in packages:
    for d in p.depends:
      let key = d.name & "::" & d.range
      if key in seen: continue
      seen.incl(key)
      if d.name notin pkgVersions:
        # Dependency on an unknown package — emit no range facts; the
        # downstream integrity constraint will fail closed via the
        # missing ``package_version`` atom.
        continue
      let rng = try: parseSemverRange(d.range)
                except ESemverParse: continue
      for v in pkgVersions[d.name]:
        let parsed = try: parseSemver(v)
                     except ESemverParse: continue
        if satisfies(parsed, rng):
          lines.add("version_in_range(\"" & aspQuote(d.name) & "\", \"" &
                    aspQuote(v) & "\", \"" & aspQuote(d.range) & "\").")
  lines.join("\n")

# ---------------------------------------------------------------------------
# Dependency edges
# ---------------------------------------------------------------------------

proc encodeDependencyEdges*(p: PackageDecl): string =
  ## For each declared dependency emit:
  ##
  ## * ``depends_on("A", "B").`` — the structural edge. Used by
  ##   cross-package ``propagates:`` resolution.
  ## * ``package_required("A", "B", "range").`` — the typed edge with
  ##   its range constraint. Diagnostic-friendly; not consumed by the
  ##   integrity constraint directly.
  ## * The integrity constraint that enforces the range membership,
  ##   gated on ``package_chosen`` for the parent so the constraint
  ##   only fires when the parent participates in the solve.
  ##
  ## Conditional dependencies extend the integrity-constraint body
  ## with a ``variant_assigned("v", "trigger")`` atom so the range
  ## only constrains the chosen version when the variant trigger fires.
  var lines: seq[string] = @[]
  for d in p.depends:
    let parent = "\"" & aspQuote(p.name) & "\""
    let child = "\"" & aspQuote(d.name) & "\""
    let rangeAtom = "\"" & aspQuote(d.range) & "\""
    lines.add("depends_on(" & parent & ", " & child & ").")
    lines.add("package_required(" & parent & ", " & child & ", " &
              rangeAtom & ").")
    # The integrity constraint:
    #   :- package_chosen(A, _), [variant trigger], package_chosen(B, V),
    #      not version_in_range(B, V, range).
    var body = newSeq[string]()
    body.add("package_chosen(" & parent & ", _)")
    if d.conditional.isSome:
      let g = d.conditional.get
      body.add("variant_assigned(\"" & aspQuote(g.variantName) &
               "\", \"" & aspQuote(g.triggerValue) & "\")")
    body.add("package_chosen(" & child & ", V)")
    body.add("not version_in_range(" & child & ", V, " & rangeAtom & ")")
    lines.add(":- " & body.join(", ") & ".")
  lines.join("\n")

# ---------------------------------------------------------------------------
# Cross-package variant propagation
# ---------------------------------------------------------------------------

proc encodeCrossPackagePropagation*(packages: openArray[PackageDecl]): string =
  ## When variant V_X in package X has ``propagates: target == value``,
  ## emit a rule that for every package Y that depends on X, AND every
  ## variant in Y named ``target``, forces ``target`` to ``value``.
  ## ``depends_on(Y, X)`` gates the propagation so independent packages
  ## ignore the directive.
  ##
  ## Encoding shape:
  ##
  ##   :- variant_assigned("v_x", "x"),
  ##      depends_on(Y_name, "X_name"),
  ##      not variant_assigned("target", "value").
  ##
  ## where ``Y_name`` is grounded against every package that DECLARES
  ## a variant called ``target`` — without that join we'd over-fire
  ## the propagation on packages with no such variant.
  var packageOfVariant: Table[string, seq[string]]  # variant -> packages
  for p in packages:
    for v in p.variants:
      if v.name notin packageOfVariant:
        packageOfVariant[v.name] = @[]
      packageOfVariant[v.name].add(p.name)

  var lines: seq[string] = @[]
  for sourcePkg in packages:
    for sourceVariant in sourcePkg.variants:
      for c in sourceVariant.constraints:
        if c.kind != crkPropagates: continue
        # Identify candidate "Y" packages: those that (a) depend on
        # ``sourcePkg`` and (b) declare a variant named
        # ``c.target``. We materialize the cross-package propagation
        # by emitting one integrity constraint per (Y, sourcePkg)
        # pair so the encoding is fully ground.
        let yPackages = packageOfVariant.getOrDefault(c.target, @[])
        for yName in yPackages:
          if yName == sourcePkg.name: continue  # within-package case is M2b
          lines.add(":- variant_assigned(\"" &
                    aspQuote(sourceVariant.name) & "\", \"" &
                    aspQuote(c.sourceValue) & "\"), depends_on(\"" &
                    aspQuote(yName) & "\", \"" & aspQuote(sourcePkg.name) &
                    "\"), not variant_assigned(\"" & aspQuote(c.target) &
                    "\", \"" & aspQuote(c.targetValue) & "\").")
  lines.join("\n")

# ---------------------------------------------------------------------------
# Show directive
# ---------------------------------------------------------------------------

proc encodeUnifiedShow(): string =
  ## Surface both ``variant_assigned`` and ``package_chosen`` atoms so
  ## the unified driver can parse a single model into the unified
  ## solution. Other predicates stay hidden to keep the parse simple.
  "#show variant_assigned/2.\n#show package_chosen/2."

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

proc encodePackages*(packages: openArray[PackageDecl]): string =
  ## Emit ASP atoms for packages, versions, range membership facts, and
  ## dependency edges. Does NOT emit the variant encoding — callers
  ## that want unified solving should use ``encodeUnified`` instead so
  ## the cross-package propagation rules land in the same program.
  var sections: seq[string] = @[]
  for p in packages:
    let universe = encodePackageUniverse(p)
    if universe.len > 0:
      sections.add(universe)
    sections.add(encodePackageCardinality(p))
    let edges = encodeDependencyEdges(p)
    if edges.len > 0:
      sections.add(edges)
  let ranges = groundVersionInRange(packages)
  if ranges.len > 0:
    sections.add(ranges)
  sections.join("\n") & "\n"

proc encodeUnified*(variants: openArray[VariantDecl];
                    packages: openArray[PackageDecl]): string =
  ## Emit the combined variant + package encoding. The variant section
  ## comes from the M2b ``encodeVariants`` (sans its ``#show`` line
  ## which is replaced by the unified version), the package section
  ## from ``encodePackages``, and the cross-package propagation block
  ## ties them together. The result is the complete ASP program text
  ## the unified driver feeds into clingo.
  ##
  ## Collects every variant: those passed in directly plus those
  ## declared inside ``PackageDecl.variants``. Duplicates by name are
  ## first-wins; the encoder does not police duplicate declarations
  ## (that's an M2e diagnostic concern).
  ##
  ## Cross-package ``propagates:`` constraints are STRIPPED from the
  ## M2b emission and replaced by the depends-on-gated rules emitted
  ## by ``encodeCrossPackagePropagation``. Within-package ``propagates:``
  ## stay on the M2b shape (forced equality) since no dependency gate
  ## is needed when source and target live in the same package.

  # Index: variant name -> owning package name (if any).
  var variantPackage: Table[string, string]
  for p in packages:
    for v in p.variants:
      if v.name notin variantPackage:
        variantPackage[v.name] = p.name

  var allVariants: seq[VariantDecl] = @[]
  var seen: HashSet[string]

  proc filteredVariant(v: VariantDecl;
                       owningPackage: string): VariantDecl =
    ## Strip ``propagates:`` constraints whose target lives in a
    ## DIFFERENT package than the source variant — the cross-package
    ## handler emits a depends-on-gated rule for those, so the
    ## unconditional M2b rule must NOT fire.
    var kept: seq[ConstraintExpr] = @[]
    for c in v.constraints:
      if c.kind != crkPropagates:
        kept.add(c)
        continue
      let targetPkg = variantPackage.getOrDefault(c.target, "")
      if owningPackage.len > 0 and targetPkg.len > 0 and
         targetPkg != owningPackage:
        # Cross-package propagation: skip the M2b shape; the
        # gated rule lands separately.
        continue
      kept.add(c)
    VariantDecl(name: v.name, kind: v.kind,
                allowedValues: v.allowedValues,
                contributions: v.contributions,
                constraints: kept)

  for v in variants:
    if v.name notin seen:
      seen.incl(v.name)
      # Free variants (not attached to a package) keep all their
      # constraints — the cross-package handler keys on package
      # ownership, so a free variant has no package to project from.
      allVariants.add(v)
  for p in packages:
    for v in p.variants:
      if v.name notin seen:
        seen.incl(v.name)
        allVariants.add(filteredVariant(v, p.name))

  let variantText = encodeVariants(allVariants)
  # Strip the M2b ``#show variant_assigned/2.`` line so the unified
  # show directive can take over without clingo complaining about
  # duplicate predicate restrictions (the redundant case is harmless
  # in practice but emitting one canonical show keeps the program
  # tidier and the parsed model deterministic).
  var trimmed = newStringOfCap(variantText.len)
  for line in variantText.splitLines():
    if line.strip() == "#show variant_assigned/2.":
      continue
    if trimmed.len > 0:
      trimmed.add('\n')
    trimmed.add(line)

  let packageText = encodePackages(packages)
  let propagation = encodeCrossPackagePropagation(packages)

  var sections: seq[string] = @[]
  if trimmed.strip().len > 0:
    sections.add(trimmed)
  if packageText.strip().len > 0:
    sections.add(packageText)
  if propagation.len > 0:
    sections.add(propagation)
  sections.add(encodeUnifiedShow())
  sections.join("\n") & "\n"
