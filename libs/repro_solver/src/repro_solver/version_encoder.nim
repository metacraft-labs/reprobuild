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
## 7. **Selection.** ``package_selected("p").`` records whether anything
##    required ``p`` — the Named-Lock-Files §5.6 fact (owner decision
##    2026-08-21). Seeded on the packages nothing depends on and
##    propagated along dependency edges, with a conditional edge's
##    ``variant_assigned`` gate in the body so a DORMANT arm propagates
##    nothing. See ``encodeSelectionRoots`` for why this is derived in the
##    ASP rather than post-computed in Nim.
##
## ## Why a separate encoder
##
## Keeping the version encoder in a sibling module to the variant
## encoder means the M2b ``encodeVariants`` entry point stays usable on
## its own (the existing M2b tests don't pull in the version surface).
## The unified entry point lives at the boundary in ``encodeUnified``.

import std/[algorithm, options, strutils, tables, sets]

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
    source*: string
      ## Workspace-Manifest-Optional MO-11 — the declared SOURCE PROVENANCE
      ## of the package, threaded from the solver-inputs ``source:`` directive.
      ## Empty = a bare definition identity (the historical default; the solver
      ## ignores this field — it only reads ``name`` / ``versions`` / ``depends``
      ## / ``variants``). A non-empty value names where the realized package
      ## comes from: ``"store"`` (a repro-store-realized artifact) or
      ## ``"registry:<registry-name>"`` (a package-registry dependency). The
      ## committed-lock writer reads it to LIFT the solved package into a
      ## first-class ``LockedDep`` with store/registry coordinates + integrity.
    pinned*: bool
      ## Named-Lock-Files NLF-M2 (§10.1) — the package's version is OBSERVED,
      ## not selected. Set for a develop-mode dependency, whose source is a
      ## local checkout: its version is read off that checkout, so there is
      ## nothing for the solver to choose.
      ##
      ## A pinned package asserts ``package_chosen`` as a FACT and emits no
      ## cardinality rule. That is deliberately stronger than declaring a
      ## one-element candidate set, which would encode the same answer as a
      ## search: the corpus (NLF-DEV-3) rejects the one-element form because
      ## it leaves the solver free to pick something else under pressure and
      ## bills the search space for a version already known.
      ##
      ## Pinning the VERSION says nothing about the package's VARIANTS, which
      ## remain solved — owner decision Q-4, and the reason this is a field on
      ## the package rather than the package's removal from the program.
      ## ``versions`` must hold exactly one entry when this is set.
    instanceOf*: string
      ## Named-Lock-Files NLF-M8 (§9.1) — the BASE package this decl is one
      ## instance of, or ``""`` when ``name`` is itself the base.
      ##
      ## §9 is "two edges under different lock files feeding one artifact",
      ## and the encoder before NLF-M8 could not represent that at all: one
      ## ``package_chosen/2`` per NAME means one instance per package, so two
      ## irreconcilable demanders were a bare UNSAT — the exact failure §9.4
      ## forbids ("It MUST NOT report a bare unsat").
      ##
      ## An instance is an ordinary package in every other respect: same
      ## candidate universe, same cardinality rule, same range constraints.
      ## What ``instanceOf`` adds is the join the unification OBJECTIVE is
      ## written over (``encodeUnificationObjective``), so the solver prefers
      ## to land every instance of a base on ONE version and introduces a
      ## second only when the constraints leave it no choice. That is §9.1's
      ## "unification is therefore an optimisation objective, not a
      ## precondition" — Spack's ``when_possible`` objective without Spack's
      ## round structure, which §14.3.1 rejects for making the outcome
      ## history-dependent.
      ##
      ## A package set with no instances emits NO objective and NO join
      ## facts, so its program text is byte-for-byte what it was. That is
      ## NLF-STAT-4, and it is why this is a field rather than a mode.

  VersionPreference* = enum
    ## Named-Lock-Files NLF-M6 (§5.5) — the *version-selection rule* a solve
    ## runs under, as the SOLVER sees it.
    ##
    ## This is deliberately not `repro_lock_gen.LockStrategy`. A lock strategy
    ## is a user-facing rule for producing a lock file; a version preference is
    ## an objective function over `package_chosen/2`. The generation path maps
    ## one onto the other. Keeping them apart is what lets the solver stay a
    ## leaf below the generation path — the layering `repro_lock_gen`'s header
    ## records as structural rather than tidy.
    ##
    ## `vpNone` emits NOTHING, so the program text of every pre-NLF-M6 caller
    ## is byte-unchanged and no fingerprint moves. That is a requirement, not
    ## an optimisation: NLF-STAT-4 freezes the default path.
    ##
    ## ## Why this is an ASP objective rather than candidate narrowing
    ##
    ## NLF-M5 implemented `lowest`/`highest` by narrowing each package's
    ## candidate universe to its extreme published version before encoding.
    ## That is wrong as soon as a declared range is involved, and the failure
    ## is not subtle: `libfoo` publishing 1.0 … 1.9 under `uses: ">=1.2 <2.0"`
    ## narrows to `{1.0}` under `lowest`, and the solve then reports UNSAT for
    ## a workspace that has a perfectly good answer at 1.2. A preference is a
    ## soft objective over the FULL universe, so the hard range constraints
    ## still decide what is admissible and the objective only orders what
    ## remains. This is the "interaction with declared ranges" NLF-M5 left
    ## open.
    ##
    ## ## `vpLowestDirect`
    ##
    ## Direct dependencies take the lowest admissible version; everything
    ## reached only transitively takes the highest. That is Cargo's
    ## `-Z direct-minimal-versions` shape, and the asymmetry is the point: a
    ## workspace's own declared lower bounds are what it is responsible for and
    ## what `lowest` exists to falsify, while a transitive package's bounds
    ## belong to the intermediate package's author. `lowest` fails on THEIR
    ## under-declaration; `lowest-direct` does not.
    vpNone = "none"
    vpLowest = "lowest"
    vpHighest = "highest"
    vpLowestDirect = "lowest-direct"

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
                 variants: openArray[VariantDecl] = @[];
                 pinned = false; instanceOf = ""): PackageDecl =
  PackageDecl(name: name, versions: @versions, depends: @depends,
              variants: @variants, pinned: pinned, instanceOf: instanceOf)

proc newInstance*(instanceName, baseName: string;
                  versions: openArray[string];
                  depends: openArray[DependencyDecl] = @[];
                  variants: openArray[VariantDecl] = @[]): PackageDecl =
  ## Named-Lock-Files NLF-M8 — one INSTANCE of ``baseName``. See
  ## ``PackageDecl.instanceOf``. ``instanceName`` must be unique across the
  ## declaration set, because it is the ``package_chosen/2`` key.
  newPackage(instanceName, versions, depends, variants,
             pinned = false, instanceOf = baseName)

proc newPinnedPackage*(name, version: string;
                       depends: openArray[DependencyDecl] = @[];
                       variants: openArray[VariantDecl] = @[]): PackageDecl =
  ## A package whose version is OBSERVED rather than selected — see
  ## ``PackageDecl.pinned``. Takes a single version rather than a list,
  ## because "pinned to a set" is not a thing and accepting a list here
  ## would make the invalid state representable at the one call site that
  ## exists to avoid it.
  newPackage(name, [version], depends, variants, pinned = true)

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
  if p.pinned and p.versions.len > 0:
    # An observed version is stated, not searched for. The fact still has to
    # be emitted: every dependency constraint downstream is gated on
    # ``package_chosen`` for this package, so dropping the choice without
    # asserting the answer would silently stop those constraints applying —
    # coverage lost rather than a wrong answer.
    parts.add("package_chosen(\"" & aspQuote(p.name) & "\", \"" &
              aspQuote(p.versions[0]) & "\").")
  parts.join("\n")

proc encodePackageCardinality*(p: PackageDecl): string =
  ## Pick exactly one version per active package. Gating on
  ## ``package_active`` lets future work disable the cardinality for
  ## inactive packages without rewriting the program shape.
  ##
  ## A pinned package gets no rule at all: its ``package_chosen`` atom is
  ## asserted as a fact by ``encodePackageUniverse``, and emitting a
  ## cardinality rule alongside that fact would re-open as a search the very
  ## thing the pin settled.
  if p.pinned:
    return ""
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
    # NLF-M9 (§5.6) — selection propagates along the edge, gated by the SAME
    # ``variant_assigned`` atom that gates the range constraint. One gate, two
    # consequences: if the arm is dormant the range does not fire AND nothing
    # downstream of it is selected.
    #
    # The body is ``package_selected(parent)``, not ``package_chosen(parent, _)``:
    # every declared package is ``package_active`` and therefore chooses a
    # version, so gating on ``package_chosen`` would make every edge propagate
    # and the fact would be vacuously true everywhere. Selection is reachability
    # from a root, which is transitive, and this is what makes it so.
    var selBody = newSeq[string]()
    selBody.add("package_selected(" & parent & ")")
    if d.conditional.isSome:
      let g = d.conditional.get
      selBody.add("variant_assigned(\"" & aspQuote(g.variantName) &
                  "\", \"" & aspQuote(g.triggerValue) & "\")")
    lines.add("package_selected(" & child & ") :- " &
              selBody.join(", ") & ".")
  lines.join("\n")

# ---------------------------------------------------------------------------
# Selection roots (NLF-M9, design §5.6)
# ---------------------------------------------------------------------------

proc encodeSelectionRoots*(packages: openArray[PackageDecl]): string =
  ## Seed the selection relation: every declared package that NOTHING declares
  ## a dependency on is selected by the request itself.
  ##
  ## §5.6 defines the fact as "whether any non-dormant edge required it". A
  ## root has no incoming edge at all, so read literally the definition would
  ## report the very package the solve was asked for as unselected — a false
  ## report, and the one that would make the fact useless. The request is the
  ## edge; it is simply not spelled in the package set. This seeds it.
  ##
  ## "Nothing depends on it" is a STATIC property of the declaration set, not
  ## a solver outcome, so the seed is grounded here rather than derived through
  ## negation inside the program. That keeps the ASP free of negation-as-failure
  ## over a recursive predicate — ``package_selected`` is defined by positive
  ## rules only, so its least model is its unique answer and no stratification
  ## question arises.
  ##
  ## **Why the relation is derived in the ASP at all**, rather than post-computed
  ## in Nim from ``sol.variants`` plus the declarations: the gate a dormant arm
  ## turns on is `variant_assigned/2`, the exact atom the range constraint is
  ## gated on. Recomputing "was this arm taken" in Nim would be a second
  ## implementation of the gate, free to drift from the one the solver enforced
  ## — and drift between them is invisible, because both would still produce a
  ## plausible answer.
  var depended: HashSet[string]
  for p in packages:
    for d in p.depends:
      depended.incl(d.name)
  var lines: seq[string] = @[]
  for p in packages:
    if p.name notin depended:
      lines.add("package_selected(\"" & aspQuote(p.name) & "\").")
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
# Version preference (NLF-M6, §5.5)
# ---------------------------------------------------------------------------

proc rootPackageNames*(packages: openArray[PackageDecl]): HashSet[string] =
  ## The packages nothing in the declaration set depends on.
  ##
  ## The same "no incoming edge" predicate `encodeSelectionRoots` seeds
  ## selection from, exported because NLF-M6 needs it twice more (the
  ## `lowest-direct` objective and the materiality interval derivation) and a
  ## second definition of "root" is a second thing to drift.
  var depended: HashSet[string]
  for p in packages:
    for d in p.depends:
      depended.incl(d.name)
  for p in packages:
    if p.name notin depended:
      result.incl(p.name)

proc directDependencyNames*(packages: openArray[PackageDecl]): HashSet[string] =
  ## The packages a ROOT package declares a dependency on.
  ##
  ## "Direct" is relative to the request, so it is the roots' `depends` and
  ## nothing deeper. A package reachable both directly and transitively counts
  ## as direct — the workspace does declare a bound on it, so the workspace is
  ## answerable for that bound, which is the whole basis of the split.
  ##
  ## Conditional (variant-gated) arms are INCLUDED, for the same
  ## over-approximation reason `fetchPlan` includes them: which arm is live is
  ## the solve's own output, so a gate-respecting walk here would need the
  ## answer it is helping to produce. Over-approximating "direct" costs a
  ## dormant package a preference term that never fires, because the term is
  ## conditioned on `package_chosen` and a dormant package still chooses.
  ## Measured consequence, stated rather than implied: a dormant direct arm
  ## does get a term, and it is harmless because §5.7's interval derivation
  ## records nothing for an UNSELECTED package.
  let roots = rootPackageNames(packages)
  for p in packages:
    if p.name notin roots: continue
    for d in p.depends:
      result.incl(d.name)

proc encodeVersionRanks*(packages: openArray[PackageDecl]): string =
  ## Emit `version_rank("pkg", "version", N).` — the position of each candidate
  ## in that package's semver-ascending order.
  ##
  ## The rank is per-package and dense from 0, so the objective's weight is
  ## bounded by the candidate count rather than by the version numbers, and two
  ## packages contribute comparable magnitudes. Encoding the version itself as
  ## a weight would let a package that happens to number its releases in the
  ## thousands outvote every other package in the sum.
  ##
  ## A candidate whose string does not parse as semver keeps its raw-string
  ## position in the order rather than aborting the encode: the registry's
  ## naming is not the encoder's to police, and the resulting order is still
  ## total and still deterministic.
  ##
  ## A PINNED package gets no ranks. Its `package_chosen` atom is a fact, so a
  ## preference term over it could only ever evaluate to a constant, and
  ## emitting one would put a constant in the objective sum that a reader would
  ## reasonably mistake for a live choice.
  var lines: seq[string] = @[]
  for p in packages:
    if p.pinned: continue
    var sorted = p.versions
    sorted.sort(proc(a, b: string): int =
      try:
        cmpSemver(parseSemver(a), parseSemver(b))
      except ESemverParse:
        cmp(a, b))
    for i, v in sorted:
      lines.add("version_rank(\"" & aspQuote(p.name) & "\", \"" &
                aspQuote(v) & "\", " & $i & ").")
  lines.join("\n")

proc instanceBases*(packages: openArray[PackageDecl]):
    OrderedTable[string, seq[string]] =
  ## Base package name → the instance names declared for it, in declaration
  ## order. Only bases with at least ONE instance appear; a base with exactly
  ## one instance is kept, because "one instance today, two tomorrow" is a
  ## property of the workspace and not of the encoder, and a table that
  ## silently dropped singletons would make the two cases encode differently
  ## for a reason nobody wrote down.
  result = initOrderedTable[string, seq[string]]()
  for p in packages:
    if p.instanceOf.len == 0: continue
    if not result.hasKey(p.instanceOf):
      result[p.instanceOf] = @[]
    result[p.instanceOf].add(p.name)

proc hasUnificationChoice*(packages: openArray[PackageDecl]): bool =
  ## Whether any base has TWO OR MORE instances — the only case in which
  ## unification is a question at all, and therefore the only case in which
  ## anything is emitted.
  for _, instances in instanceBases(packages).pairs:
    if instances.len >= 2:
      return true
  false

proc encodeUnificationObjective*(packages: openArray[PackageDecl]): string =
  ## Named-Lock-Files NLF-M8, design §9.1 — **unify first, and only then
  ## diverge**, as a soft objective over the full instance set.
  ##
  ## The encoding is two rules and one directive per base:
  ##
  ## ```
  ## instance_version("libfoo", V) :- package_chosen("libfoo@hostTools", V).
  ## instance_version("libfoo", V) :- package_chosen("libfoo@targetRuntime", V).
  ## #minimize { 1@-1, B, V : instance_version(B, V) }.
  ## ```
  ##
  ## `instance_version/2` is a SET: two instances that choose the same version
  ## contribute one tuple, two that disagree contribute two. Minimising its
  ## cardinality is therefore exactly "use as few distinct versions of each
  ## library as the constraints permit", which is §9.1's three consequences —
  ## shared dependencies collapse, divergence is confined to what genuinely
  ## could not agree, and nothing needs to coordinate for content-derived
  ## identity to share the rest.
  ##
  ## ## Why an objective and not a constraint
  ##
  ## A hard constraint saying "all instances agree" would turn every genuine
  ## disagreement back into the bare UNSAT §9.4 forbids. A soft objective
  ## finds the split, and the split is what the §9.4 diagnostic is written
  ## about. This is the difference the corpus draws between NLF-DIA-6 (ranges
  ## overlap: one instance) and NLF-DIA-2 (ranges do not: two instances and an
  ## error naming both) — one encoder answers both.
  ##
  ## ## The priority level, and why it is above the version preference
  ##
  ## `@-1`, with `encodeVersionPreference` moved down to `@-2`/`@-3` whenever
  ## this fires. clingo optimises higher levels first, so unification
  ## outranks `--strategy lowest`/`highest`. That ordering is §9.1's
  ## "divergence is a fallback, not a starting point" made mechanical: a
  ## version preference that outranked unification could split a library the
  ## constraints permitted to unify, purely to reach a lower or higher
  ## version, and the split would be invisible in the answer.
  ##
  ## Variant priorities keep `@0` and still outrank both, so a `prForce`
  ## contribution is never overturned to save an instance.
  ##
  ## Emits `""` when no base has two instances, so every pre-NLF-M8 program
  ## is byte-unchanged (NLF-STAT-4).
  if not hasUnificationChoice(packages):
    return ""
  var lines: seq[string] = @[]
  let bases = instanceBases(packages)
  for base, instances in bases.pairs:
    if instances.len < 2: continue
    for inst in instances:
      lines.add("instance_version(\"" & aspQuote(base) & "\", V) :- " &
        "package_chosen(\"" & aspQuote(inst) & "\", V).")
  lines.add("#minimize { 1@-1, B, V : instance_version(B, V) }.")
  lines.join("\n")

proc encodeVersionPreference*(packages: openArray[PackageDecl];
                              preference: VersionPreference;
                              levelBase = -1): string =
  ## The objective directives for `preference`, or `""` for `vpNone`.
  ##
  ## ## The priority level, and why it is negative
  ##
  ## `variant_encoder`'s priority objective sits at clingo's DEFAULT level
  ## (`@0`). Version preference is emitted at `@-1` (and `@-2`), which clingo
  ## optimises AFTER level 0. So a variant priority always outranks a version
  ## preference, and a `--strategy lowest` invocation cannot silently overturn
  ## a `prForce` contribution. Sharing level 0 would have summed unrelated
  ## weights — a variant band (1…4) against a candidate rank (0…N) — and made
  ## the trade-off between them depend on how many versions a registry
  ## happened to publish.
  ##
  ## ## `vpLowestDirect` is two directives, at two levels
  ##
  ## Direct packages minimise at `@-1`; everything else maximises at `@-2`. Two
  ## levels rather than one summed level, because at one level a single direct
  ## package's rank could be traded against a transitive package's rank and the
  ## answer would depend on candidate counts. Lexicographic levels make "direct
  ## minimal, then transitive maximal" mean exactly that.
  ##
  ## ## `levelBase`, and why it is a parameter rather than a constant
  ##
  ## NLF-M8 adds a unification objective (§9.1), which must outrank the
  ## version preference — see `encodeUnificationObjective`. It takes `@-1`,
  ## and this one steps down to `@-2`/`@-3` when it does. The step is a
  ## PARAMETER so that a program with no unification choice keeps `@-1`/`@-2`
  ## and stays byte-identical to every pre-NLF-M8 program: NLF-STAT-4 freezes
  ## the default path, and a renumbering applied unconditionally would move
  ## the text of every existing `--strategy` invocation for no reason.
  if preference == vpNone:
    return ""
  let l1 = "@" & $levelBase
  let l2 = "@" & $(levelBase - 1)
  var sections: seq[string] = @[]
  let ranks = encodeVersionRanks(packages)
  if ranks.len > 0:
    sections.add(ranks)
  case preference
  of vpNone:
    discard
  of vpLowest:
    sections.add("#minimize { R" & l1 & ", P : package_chosen(P, V), " &
      "version_rank(P, V, R) }.")
  of vpHighest:
    sections.add("#maximize { R" & l1 & ", P : package_chosen(P, V), " &
      "version_rank(P, V, R) }.")
  of vpLowestDirect:
    var directFacts: seq[string] = @[]
    var directs: seq[string] = @[]
    for name in directDependencyNames(packages):
      directs.add(name)
    directs.sort()
    for name in directs:
      directFacts.add("version_direct(\"" & aspQuote(name) & "\").")
    if directFacts.len > 0:
      sections.add(directFacts.join("\n"))
    sections.add("#minimize { R" & l1 & ", P : package_chosen(P, V), " &
      "version_rank(P, V, R), version_direct(P) }.")
    sections.add("#maximize { R" & l2 & ", P : package_chosen(P, V), " &
      "version_rank(P, V, R), not version_direct(P) }.")
  sections.join("\n")

# ---------------------------------------------------------------------------
# Show directive
# ---------------------------------------------------------------------------

proc encodeUnifiedShow(): string =
  ## Surface ``variant_assigned``, ``package_chosen`` and (NLF-M9)
  ## ``package_selected`` atoms so the unified driver can parse a single
  ## model into the unified solution. Other predicates stay hidden to keep
  ## the parse simple.
  "#show variant_assigned/2.\n#show package_chosen/2.\n" &
    "#show package_selected/1."

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
    let cardinality = encodePackageCardinality(p)
    if cardinality.len > 0:
      sections.add(cardinality)
    let edges = encodeDependencyEdges(p)
    if edges.len > 0:
      sections.add(edges)
  let ranges = groundVersionInRange(packages)
  if ranges.len > 0:
    sections.add(ranges)
  # NLF-M9 — the selection seed. Emitted after the edges so the whole
  # ``package_selected`` block reads together in a dumped program.
  let roots = encodeSelectionRoots(packages)
  if roots.len > 0:
    sections.add(roots)
  sections.join("\n") & "\n"

proc encodeUnified*(variants: openArray[VariantDecl];
                    packages: openArray[PackageDecl];
                    preference: VersionPreference = vpNone): string =
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
                constraints: kept,
                pinnedValue: v.pinnedValue)

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
  # NLF-M8 (§9.1) — unification, as an objective, BEFORE the version
  # preference both in the text and in the priority lattice. Empty unless
  # some base carries two instances, which is what keeps every pre-NLF-M8
  # program byte-identical (NLF-STAT-4).
  let unificationText = encodeUnificationObjective(packages)
  if unificationText.len > 0:
    sections.add(unificationText)
  # NLF-M6 — the version-selection objective. Emitted LAST among the rule
  # sections and empty for `vpNone`, so every pre-NLF-M6 program is byte-for-
  # byte what it was. NLF-M8 steps its levels down by one when the
  # unification objective is present, so unification outranks it — see
  # `encodeVersionPreference`'s `levelBase`.
  let preferenceText = encodeVersionPreference(packages, preference,
    levelBase = (if unificationText.len > 0: -2 else: -1))
  if preferenceText.len > 0:
    sections.add(preferenceText)
  sections.add(encodeUnifiedShow())
  sections.join("\n") & "\n"
