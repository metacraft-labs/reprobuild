## Spec-Implementation M1 — Solver-participating Configurables (variants).
##
## A *variant* is an ordinary ``Configurable[T]`` whose underlying
## ``ConfigurableNode`` carries the ``solverParticipating`` tag. See
## ``Configurable-System.md`` §"Solver-Participating Configurables
## (Variants)" for the design rationale and §"Why Not a Parallel
## Primitive" for the explicit choice not to introduce a separate type.
##
## M1 lifts the **declaration surface** (``variant: T = default`` and
## the ``@variant`` doc directive), the **runtime data-model tag**
## (``solverParticipating`` on the node), the **``.value`` accessor**
## (returns ``T`` once the surrounding ``evalConfig`` has finalized;
## raises ``EVariantNotResolved`` before that), and the **CLI hook**
## (``--variant name=value`` registers a ``prSet`` contribution before
## evaluation begins). NO solver integration yet — variants resolve at
## ``evalConfig`` finalize time using the same priority lattice
## (``prDefault < prSet < prOverride < prForce``) as every other
## ``Configurable[T]``.
##
## The variant identity store is a thread-local ``ConfigContext`` that
## the ``package`` macro opens lazily on the first variant declaration
## and finalizes once the ``config:`` block completes. The
## ``.value`` accessor consults the context's state; reading before
## finalize raises the structured ``EVariantNotResolved`` error rather
## than returning the default value silently.

import std/[options, os, strutils, tables]

import ./types
import ./context
import ./api

# Spec-Implementation M2d: ``finalizeVariants()`` now drives the
# Spack-shaped unified solver. We import the solver library here rather
# than from a higher level so the ``.value`` accessor's resolution path
# stays self-contained — the same module that owns the variant context
# also owns the solver call. The data-only inputs (``VariantDecl``,
# ``PackageDecl``, ``DependencyDecl``, ``ConditionalGate``) live in the
# solver library, so importing it is a leaf-side dependency from this
# module's perspective.
import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/version_constraints
import repro_solver/solver_api

# ---------------------------------------------------------------------------
# Process-wide ambient variant context
# ---------------------------------------------------------------------------
#
# The DSL's existing Configurable surface lives inside an explicit
# ``evalConfig:`` block. Variants declared via the ``package`` macro's
# ``config:`` section need to be reachable from the package's ``uses:``
# / ``build:`` blocks at module load time, without requiring authors
# to wrap the package in an ``evalConfig:``. We therefore maintain a
# thread-local *ambient* variant context that is auto-created on the
# first variant declaration and is explicitly finalised by the
# ``package`` macro's emitted code once the ``config:`` block ends.

type
  VariantCliContribution* = object
    name*: string
    value*: string

const VariantEnvVar* = "REPRO_VARIANTS"
  ## Environment variable carrying ``name=value`` pairs (comma-
  ## separated) propagated from the CLI's ``--variant`` flag into the
  ## provider / build process. Format mirrors typical key/value env
  ## conventions; values may contain ``=`` after the first separator.
  ## Empty pairs are skipped.

var ambientVariantContext {.threadvar.}: ConfigContext
var pendingCliOverrides {.threadvar.}: seq[VariantCliContribution]
var loadedEnvOverrides {.threadvar.}: bool

type
  EPackageNotResolved* = object of ConfigurableError
    ## Spec-Implementation M2d: raised when ``chosenVersion(name)`` is
    ## called before ``finalizeVariants()`` has run OR when the named
    ## package is not in the solver's solved set. The message names the
    ## missing package and the lifecycle phase so authors can locate
    ## the call-site error.

  SolverPackageInput* = object
    ## Spec-Implementation M2d: one dependency record the package macro
    ## hands to the solver. ``parentPackage`` is the package whose
    ## ``uses:`` listed the dependency; ``depPackage`` is the
    ## depended-on package selector (e.g. ``"nim"``); ``rng`` is the
    ## raw semver-range string (e.g. ``">=2.2 <3.0"``);
    ## ``gateVariant``/``gateValue`` carry an optional variant gate so
    ## variant-conditioned arms only contribute when the variant
    ## resolves to ``gateValue``.
    parentPackage*: string
    depPackage*: string
    rng*: string
    gateVariant*: string
    gateValue*: string

var pendingSolverPackages {.threadvar.}: seq[SolverPackageInput]
  ## Spec-Implementation M2d: thread-local registry of solver-bound
  ## dependencies. The ``package`` macro emits one
  ## ``registerSolverDependency(...)`` call per ``PackageUseDef`` so
  ## ``finalizeVariants()`` can build the ``PackageDecl`` list the
  ## solver consumes without importing the ``repro_project_dsl``
  ## registry (that would create a layering loop).

var lastUnifiedSolution {.threadvar.}: UnifiedSolution
var hasUnifiedSolution {.threadvar.}: bool
  ## Spec-Implementation M2d: cache the last ``solve(...)`` result so
  ## ``chosenVersion(pkg)`` and other accessor lookups don't re-solve.
  ## ``hasUnifiedSolution`` is the explicit sentinel — the ``Table``
  ## inside ``UnifiedSolution`` can be empty when no packages
  ## participated, so we cannot use emptiness as the "not yet solved"
  ## flag.

proc parseEnvOverrides() =
  if loadedEnvOverrides:
    return
  loadedEnvOverrides = true
  let raw = getEnv(VariantEnvVar)
  if raw.len == 0:
    return
  for entry in raw.split(','):
    let stripped = entry.strip()
    if stripped.len == 0: continue
    let eqIdx = stripped.find('=')
    if eqIdx <= 0: continue
    let name = stripped[0 ..< eqIdx].strip()
    let value = stripped[eqIdx + 1 .. ^1]
    if name.len == 0: continue
    pendingCliOverrides.add(VariantCliContribution(name: name, value: value))

proc ensureAmbientVariantContext*(): ConfigContext =
  ## Return the ambient (auto-managed) variant context, creating a
  ## fresh one if needed. Re-creates the context after
  ## ``resetVariantState`` even when the previous context was
  ## finalized.
  parseEnvOverrides()
  if ambientVariantContext.isNil or
      ambientVariantContext.state == ccsFinalized:
    ambientVariantContext = newConfigContext()
    pushContext(ambientVariantContext)
  result = ambientVariantContext

proc currentVariantContext*(): ConfigContext =
  ## Return the ambient variant context without creating one. Returns
  ## ``nil`` when no variant has been declared yet.
  ambientVariantContext

proc resetVariantState*() =
  ## Reset the ambient variant context AND the pending CLI overrides.
  ## Test helpers call this between scenarios so registry entries don't
  ## leak across cases.
  if not ambientVariantContext.isNil and
      tryCurrentContext() == ambientVariantContext:
    discard popContext()
  ambientVariantContext = nil
  pendingCliOverrides.setLen(0)
  loadedEnvOverrides = false
  pendingSolverPackages.setLen(0)
  lastUnifiedSolution = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: false)
  hasUnifiedSolution = false

proc registerSolverDependency*(parentPackage, depPackage, rng: string;
                                gateVariant = ""; gateValue = "") =
  ## Spec-Implementation M2d: append one solver-bound dependency record.
  ## The ``package`` macro emits one of these per ``PackageUseDef``
  ## immediately after ``registerPackageDef``; ``finalizeVariants()``
  ## then folds the records into the solver's ``PackageDecl`` list.
  ##
  ## Empty ``gateVariant`` means the dependency is unconditional; a
  ## non-empty pair means the dependency only contributes when the
  ## named variant resolves to ``gateValue`` (the M2c
  ## ``ConditionalGate`` shape).
  pendingSolverPackages.add(SolverPackageInput(
    parentPackage: parentPackage,
    depPackage: depPackage,
    rng: rng,
    gateVariant: gateVariant,
    gateValue: gateValue))

proc pendingSolverDependencies*(): seq[SolverPackageInput] =
  ## Test-facing accessor for the queued solver-package list. Returns a
  ## copy so callers cannot mutate the thread-local registry.
  pendingSolverPackages

# ---------------------------------------------------------------------------
# CLI overrides
# ---------------------------------------------------------------------------

proc addVariantCliOverride*(name, value: string) =
  ## Register a pending ``--variant name=value`` contribution. Applied
  ## as a ``prSet`` against the variant when ``declareVariant`` runs.
  ## The CLI dispatches this from ``runBuildCommand`` /
  ## ``runReproTestCommand`` before invoking the user's build proc.
  pendingCliOverrides.add(VariantCliContribution(name: name, value: value))

proc pendingVariantCliOverrides*(): seq[VariantCliContribution] =
  pendingCliOverrides

proc applyCliContributionFor[T](ctx: ConfigContext;
                                node: ConfigurableNode; name: string) =
  ## Walk the pending CLI overrides and apply any that target ``name``.
  ## The match is by scope-derived name (the variant's declaration
  ## ident). Values are parsed from strings into ``T`` via Nim's
  ## standard parsing surface.
  for entry in pendingCliOverrides:
    if entry.name != name:
      continue
    let site = SourceSite(file: "<cli>", line: 0, column: 0,
      kind: ckSet)
    when T is bool:
      let lower = entry.value.toLowerAscii()
      let v =
        if lower in ["true", "1", "yes", "on"]: true
        elif lower in ["false", "0", "no", "off"]: false
        else:
          raise newException(EConfigurable,
            "cannot parse --variant " & entry.name & "=" & entry.value &
              " as bool")
      ctx.addContribution(node, prSet, cvBool(v), site)
    elif T is SomeInteger:
      try:
        let v = parseInt(entry.value)
        ctx.addContribution(node, prSet, cvInt(v), site)
      except ValueError:
        raise newException(EConfigurable,
          "cannot parse --variant " & entry.name & "=" & entry.value &
            " as int")
    elif T is string:
      ctx.addContribution(node, prSet, cvString(entry.value), site)
    else:
      raise newException(EConfigurable,
        "unsupported variant value type for --variant " & entry.name)

# ---------------------------------------------------------------------------
# Declaration
# ---------------------------------------------------------------------------

proc declareVariantImpl*[T](defaultValue: T;
                            scopeName, description, explicitId: string;
                            descriptionFile: string;
                            descriptionLine, descriptionColumn: int;
                            site: SourceSite): Configurable[T] =
  ## Allocate a variant in the ambient variant context. Sets the
  ## ``solverParticipating`` tag on the underlying node and applies any
  ## matching ``--variant name=value`` CLI overrides as ``prSet``
  ## contributions before returning the handle.
  ##
  ## The accessor surface (``.value``) plus the priority lattice
  ## (``prDefault`` from the declaration, ``prSet`` from the CLI,
  ## ``prOverride`` from workspace ``Configurable.override``, ``prForce``
  ## from explicit ``force`` calls) is identical to every other
  ## ``Configurable[T]``. The tag exists for the solver stage that
  ## lands in M2.
  let ctx = ensureAmbientVariantContext()
  let handle = allocConfigurable[T](ctx, scopeName, defaultValue, site,
    description = description,
    descriptionFile = descriptionFile,
    descriptionLine = descriptionLine,
    descriptionColumn = descriptionColumn,
    explicitId = explicitId)
  let node = ctx.nodeOf(handle.id)
  node.solverParticipating = true
  applyCliContributionFor[T](ctx, node, scopeName)
  handle

template declareVariant*[T](defaultValue: T;
                            scopeName, description, explicitId: string;
                            descriptionFile: string;
                            descriptionLine, descriptionColumn: int;
                            site: SourceSite): Configurable[T] =
  declareVariantImpl[T](defaultValue, scopeName, description, explicitId,
    descriptionFile, descriptionLine, descriptionColumn, site)

proc variantImpl*[T](defaultValue: T; scopeName: string;
                     site: SourceSite): Configurable[T] =
  declareVariantImpl[T](defaultValue, scopeName, "", "", "", 0, 0, site)

template variant*[T](defaultValue: T): Configurable[T] =
  let site {.gensym.} = captureSite(ckDefault)
  variantImpl[T](defaultValue, "", site)

# ---------------------------------------------------------------------------
# Finalisation + the ``.value`` accessor
# ---------------------------------------------------------------------------

proc variantKindFor(valueKind: ConfigurableValueKind): VariantKind =
  ## Map the M1 configurable value kind onto the M2b encoder's variant
  ## kind. ``cvkBool`` is the bool universe; everything else maps to
  ## the corresponding scalar form. Object-typed variants (``cvkAny``)
  ## are out of scope for M2d; the caller treats them as scalars whose
  ## universe is derived from observed contributions.
  case valueKind
  of cvkBool: vkBool
  of cvkInt: vkInt
  of cvkString: vkEnum
  of cvkBytes, cvkAny: vkEnum

proc valueToString(v: ConfigurableValue): string =
  ## Render a configurable value as the string form the solver
  ## consumes. Bool / int / string fall back to their natural Nim
  ## representation; bytes and any-payload fall back to the ``$``
  ## operator so the universe-building step has something to anchor
  ## against.
  case v.kind
  of cvkBool: $v.boolVal
  of cvkInt: $v.intVal
  of cvkString: v.strVal
  of cvkBytes: $v
  of cvkAny: $v

proc priorityToVariantPriority(p: ContributionPriority): VariantPriority =
  case p
  of prDefault: vpDefault
  of prSet: vpSet
  of prOverride: vpOverride
  of prForce: vpForce

proc allowedValuesFromContributions(node: ConfigurableNode): seq[string] =
  ## Build the universe of allowed string values for a string/int/enum
  ## variant from the recorded contributions. The M2b encoder needs at
  ## least one allowed value per variant; we never emit a bool variant
  ## through this path because ``newBoolVariant`` hard-codes the
  ## true/false universe.
  for c in node.contributions:
    let s = valueToString(c.value)
    if s notin result:
      result.add(s)

proc buildVariantDecls(ctx: ConfigContext): seq[VariantDecl] =
  ## Walk the ambient variant context's nodes and project each
  ## solver-participating node onto a ``VariantDecl`` the M2c encoder
  ## consumes. Non-variant nodes are skipped so the encoder doesn't see
  ## stray plain Configurables.
  for node in ctx.nodes:
    if not node.solverParticipating: continue
    let kind = variantKindFor(node.valueKind)
    var contributions: seq[VariantContribution] = @[]
    for c in node.contributions:
      contributions.add(contribution(priorityToVariantPriority(c.priority),
        valueToString(c.value)))
    var decl: VariantDecl
    case kind
    of vkBool:
      decl = newBoolVariant(node.scopeDerivedName, contributions = contributions)
    else:
      let allowed = allowedValuesFromContributions(node)
      decl = newEnumVariant(node.scopeDerivedName, allowed,
        contributions = contributions)
    result.add(decl)

proc smallestSatisfyingVersion(rng: string): string =
  ## Spec-Implementation M2d: derive a single synthetic version that
  ## satisfies the supplied range. M2d does NOT (yet) reach into a
  ## remote catalog; for the integration-test scope the
  ## smallest-satisfying-version heuristic is enough: when an explicit
  ## lower bound exists we use it verbatim; otherwise we fall back to
  ## ``0.0.0`` so the package_chosen cardinality has something to pick.
  ##
  ## Unparseable ranges (e.g. plain selector "ct_test_nim_unittest"
  ## without an operator and without a version) get the synthetic
  ## ``"1.0.0"`` so the encoder still has a candidate.
  try:
    let parsed = parseSemverRange(rng)
    if parsed.lower.isSome:
      let lb = parsed.lower.get
      return $lb.major & "." & $lb.minor & "." & $lb.patch
    if parsed.upper.isSome:
      # Caret/tilde with only an upper bound is rare; fall back to a
      # very small version so the upper-exclusive bound still admits.
      return "0.0.0"
  except ESemverParse:
    discard
  "1.0.0"

proc rangePartOf(rawConstraint: string): string =
  ## Strip the leading package selector token from a raw ``uses:``
  ## constraint string. ``"nim >=2.2 <3.0"`` returns ``">=2.2 <3.0"``;
  ## ``"ct_test_nim_unittest"`` returns the empty string (no range
  ## clause); ``"openssl >=3.3 <4.0"`` returns ``">=3.3 <4.0"``.
  let trimmed = rawConstraint.strip()
  let space = trimmed.find(' ')
  if space < 0:
    return ""
  trimmed[space + 1 .. ^1].strip()

proc buildPackageDecls(parentPackages: openArray[string]): seq[PackageDecl] =
  ## Build the solver-side ``PackageDecl`` list from the pending
  ## dependency registry. We emit:
  ##
  ##   * One ``PackageDecl`` per parent package that declared at least
  ##     one dependency; the parent has a synthetic ``["0.1.0"]``
  ##     version (the solver never reads the parent's own version, but
  ##     ``package_chosen`` cardinality requires at least one candidate).
  ##   * One ``PackageDecl`` per unique depended-on package, with a
  ##     versions list that contains the smallest-satisfying version
  ##     of every range the dependency was declared with. This keeps
  ##     the encoding small while still allowing per-arm selection
  ##     when ``case variant.value:`` selects between two distinct
  ##     packages (e.g. ``gcc`` vs ``clang``).
  ##
  ## Conditional gates from ``case variant.value:`` arms land as
  ## ``ConditionalGate`` on the dependency record so the solver only
  ## activates the relevant arm.
  var depVersions: Table[string, seq[string]]
  for entry in pendingSolverPackages:
    let rangePart = rangePartOf(entry.rng)
    let v = smallestSatisfyingVersion(rangePart)
    if entry.depPackage notin depVersions:
      depVersions[entry.depPackage] = @[]
    if v notin depVersions[entry.depPackage]:
      depVersions[entry.depPackage].add(v)

  # Materialize the dep packages first so they're available before the
  # parent packages reference them.
  for depName, versions in depVersions:
    result.add(newPackage(depName, versions))

  # Materialize parent packages with their dependency edges.
  for parent in parentPackages:
    var deps: seq[DependencyDecl] = @[]
    for entry in pendingSolverPackages:
      if entry.parentPackage != parent: continue
      let rng = rangePartOf(entry.rng)
      let rngForSolver =
        if rng.len == 0: ">=0.0.0" else: rng
      if entry.gateVariant.len > 0 and entry.gateValue.len > 0:
        deps.add(newConditionalDependency(entry.depPackage, rngForSolver,
          entry.gateVariant, entry.gateValue))
      else:
        deps.add(newDependency(entry.depPackage, rngForSolver))
    result.add(newPackage(parent, ["0.1.0"], depends = deps))

proc applySolverAssignments(ctx: ConfigContext;
                             assignments: Table[string, string]) =
  ## Spec-Implementation M2d: write the solver's chosen value back onto
  ## each variant's ``resolvedVal`` slot. The M1 priority lattice does
  ## NOT run for variants under M2d — the solver subsumes it (every
  ## contribution becomes an input weight; the chosen value is the
  ## solver's optimization output). Non-variant nodes in the same
  ## context still resolve via ``ctx.finalize()`` so plain Configurables
  ## sharing the ambient context behave unchanged.
  for node in ctx.nodes:
    if not node.solverParticipating:
      # Drop through to the priority-lattice resolver for non-variant
      # nodes. The variant-only path leaves these for ``ctx.finalize``.
      continue
    if node.scopeDerivedName notin assignments:
      # No solver assignment landed for this variant (e.g. the encoder
      # filtered the constraints out). Fall back to the priority
      # lattice so the ``.value`` accessor still returns SOMETHING
      # rather than raising an obscure unwrap error.
      continue
    let chosen = assignments[node.scopeDerivedName]
    case node.valueKind
    of cvkBool:
      let v = chosen.toLowerAscii() in ["true", "1", "yes", "on"]
      node.resolvedVal = cvBool(v)
    of cvkInt:
      try:
        node.resolvedVal = cvInt(parseInt(chosen))
      except ValueError:
        # Solver returned a non-integer string for an int variant — fall
        # back to the priority lattice via ``ctx.finalize`` below.
        continue
    of cvkString:
      node.resolvedVal = cvString(chosen)
    of cvkBytes, cvkAny:
      # Out of M2d scope; let the priority lattice handle it.
      continue
    node.resolved = true

const SolverInputsEmitEnvVar* = "REPRO_EMIT_SOLVER_INPUTS"
  ## Workspace-Manifest-Optional MO-12 — when this env var names a writable
  ## file path, ``finalizeVariants()`` emits the EXACT solver inputs it just
  ## solved (the variant + package decls) as M2e explain-fixture text to that
  ## path. ``repro lock refresh`` sets it before running the compiled project
  ## provider so the committed lock is sourced from the REAL recipe's
  ## ``solve()`` rather than a hand-maintained ``repro.solver`` sidecar. When
  ## unset (every ordinary build / dev-env run) the hook is a no-op, so the
  ## provider's behaviour is byte-unchanged.

proc solverPriorityKeyword(p: VariantPriority): string =
  case p
  of vpDefault: "default"
  of vpSet: "set"
  of vpOverride: "override"
  of vpForce: "force"

proc solverConstraintKeyword(k: VariantConstraintKind): string =
  case k
  of crkRequires: "requires"
  of crkConflicts: "conflicts"
  of crkPropagates: "propagates"

proc renderSolverInputsFixture*(variants: openArray[VariantDecl];
                                packages: openArray[PackageDecl]): string =
  ## MO-12 — render the solver inputs the provider's ``finalizeVariants()``
  ## consumed into the M2e explain-fixture text the CLI's
  ## ``parseExplainFixture`` parses back. The round-trip is exact for the
  ## fields the solver reads (variant kind/values/contributions/constraints;
  ## package versions/depends/source), so re-parsing this text and re-solving
  ## reproduces the provider's solution. ``source`` provenance (MO-11
  ## ``store`` / ``registry:<name>``) is rendered back to its directive form
  ## so a recipe that declares a non-VCS source still yields store/registry
  ## coordinates on the provider path, exactly as the sidecar did.
  var blocks: seq[string] = @[]
  for v in variants:
    var b = "variant " & v.name & "\n"
    case v.kind
    of vkBool:
      b.add("kind: bool\n")
    else:
      b.add("kind: enum\n")
      if v.allowedValues.len > 0:
        b.add("values: " & v.allowedValues.join(", ") & "\n")
    for c in v.contributions:
      b.add(solverPriorityKeyword(c.priority) & ": " & c.value & "\n")
    for con in v.constraints:
      b.add(solverConstraintKeyword(con.kind) & ": " & con.sourceValue &
        " -> " & con.target & " = " & con.targetValue & "\n")
    blocks.add(b)
  for p in packages:
    var b = "package " & p.name & "\n"
    if p.versions.len > 0:
      b.add("versions: " & p.versions.join(", ") & "\n")
    for d in p.depends:
      var line = "depends: " & d.name
      if d.range.len > 0:
        line.add(" " & d.range)
      if d.conditional.isSome:
        let g = d.conditional.get()
        line.add(" when " & g.variantName & "=" & g.triggerValue)
      b.add(line & "\n")
    if p.source.len > 0:
      if p.source.startsWith("registry:"):
        b.add("source: registry " & p.source["registry:".len .. ^1] & "\n")
      elif p.source == "store":
        b.add("source: store\n")
      else:
        b.add("source: " & p.source & "\n")
    blocks.add(b)
  result = blocks.join("\n")
  if result.len > 0 and not result.endsWith("\n"):
    result.add("\n")

proc emitSolverInputsIfRequested(variants: openArray[VariantDecl];
                                 packages: openArray[PackageDecl]) =
  ## MO-12 — if ``REPRO_EMIT_SOLVER_INPUTS`` is set, write the just-solved
  ## inputs as explain-fixture text. Best-effort: a write failure never
  ## disturbs the build (the lock-refresh caller falls back to the sidecar).
  let emitPath = getEnv(SolverInputsEmitEnvVar)
  if emitPath.len == 0:
    return
  try:
    writeFile(emitPath, renderSolverInputsFixture(variants, packages))
  except CatchableError:
    discard

proc finalizeVariants*() =
  ## Spec-Implementation M2d: finalize the ambient variant context by
  ## driving the unified ASP solver from ``repro_solver``. M1's
  ## priority-lattice-only path is REPLACED for solver-participating
  ## nodes — the priority bands now flow into the solver as
  ## ``contribution`` weights and the solver picks the best value per
  ## its global optimization. After this proc returns, every declared
  ## variant's ``.value`` returns the solver-chosen ``T``, and
  ## ``chosenVersion(pkg)`` returns the solver-chosen version per
  ## package.
  ##
  ## When NO variant is declared (the ambient context is nil) the call
  ## is a no-op so packages without a ``config:`` block continue to
  ## work. When the context is finalized already we also no-op so the
  ## call is idempotent on re-entry.
  ##
  ## The solver runs even when only packages are declared (no
  ## variants): the unified solver concretizes packages alone in that
  ## case. The ``ConditionalGate`` plumbing means a variant-gated
  ## ``uses:`` arm only contributes when the gating variant resolves
  ## to the trigger value, which keeps the variant-feature-flag
  ## fixture's ``if enableTLS.value: "openssl ..."`` arm working
  ## end-to-end through the solver.
  let ctxPresent = not ambientVariantContext.isNil and
    ambientVariantContext.state != ccsFinalized

  # Build the solver inputs. Variants come from the ambient context (if
  # any); package decls come from the pending dependency registry that
  # the ``package`` macro populated immediately after
  # ``registerPackageDef``.
  var variants: seq[VariantDecl] = @[]
  if ctxPresent:
    variants = buildVariantDecls(ambientVariantContext)
  var parentSet: seq[string] = @[]
  for entry in pendingSolverPackages:
    if entry.parentPackage notin parentSet:
      parentSet.add(entry.parentPackage)
  let packages = buildPackageDecls(parentSet)

  # Drive the solver. When neither variants nor packages are present
  # we skip the call entirely — the solver has nothing to do and the
  # priority-lattice fallback below handles the degenerate case.
  if variants.len > 0 or packages.len > 0:
    try:
      let sol = solve(variants, packages)
      lastUnifiedSolution = sol
      hasUnifiedSolution = true
      # MO-12 — surface the EXACT inputs this solve consumed to the lock-
      # refresh caller when it asked for them (env-var gated; no-op otherwise).
      emitSolverInputsIfRequested(variants, packages)
      if ctxPresent:
        applySolverAssignments(ambientVariantContext, sol.variants)
    except EUnsatisfiable:
      # Bubble the structured unsat error up so callers can render the
      # diagnostic. M2e will replace this with a richer explanation
      # path; for M2d we surface the encoder's best-effort
      # ``unsatCore`` annotation verbatim.
      hasUnifiedSolution = false
      raise

  if ctxPresent:
    let ctx = ambientVariantContext
    # Run the priority-lattice resolver for any nodes the solver did NOT
    # write to (plain Configurables that share the ambient context, or
    # variant kinds the solver path skipped). The lattice resolver is a
    # no-op for nodes whose ``resolved`` flag we already set, so this
    # double-pass is safe.
    ctx.finalize()
    # Pop the ambient context off the thread-local stack so subsequent
    # explicit ``evalConfig:`` blocks see a clean slate. Idempotent: if
    # another context was pushed on top after ours we leave it alone.
    if tryCurrentContext() == ctx:
      discard popContext()

proc chosenVersion*(packageName: string): string =
  ## Spec-Implementation M2d: return the solver-chosen version for the
  ## named package. Raises ``EPackageNotResolved`` when called before
  ## ``finalizeVariants()`` has run, or when the named package is not
  ## in the solver's solved set.
  ##
  ## ``uses:`` resolution paths and provisioning catalog lookups
  ## consume this accessor to materialize the concrete version after
  ## the solve completes.
  if not hasUnifiedSolution:
    raise newException(EPackageNotResolved,
      "chosenVersion('" & packageName & "') read before " &
      "finalizeVariants — call finalizeVariants() first or guard the " &
      "read with a phase-ordering check")
  if packageName notin lastUnifiedSolution.packages:
    raise newException(EPackageNotResolved,
      "package '" & packageName & "' is not in the solver's solved " &
      "set — check that the package appears in the active uses: " &
      "section (and that any conditional arm gating it is active)")
  lastUnifiedSolution.packages[packageName]

proc lastSolverSolution*(): UnifiedSolution =
  ## Diagnostic accessor for the most recently computed
  ## ``UnifiedSolution``. Returns an empty solution before
  ## ``finalizeVariants()`` runs. Tests consume this to verify the
  ## solver actually ran and that the assignment matches expectations.
  lastUnifiedSolution

proc hasSolverSolution*(): bool =
  ## True iff ``finalizeVariants()`` has driven the solver to
  ## completion. False before finalize or after a ``resetVariantState``.
  hasUnifiedSolution

proc variantNodeOf[T](c: Configurable[T]): ConfigurableNode =
  let ctx = currentVariantContext()
  if ctx.isNil:
    raise newException(ENoContext,
      "no ambient variant context — declare the variant via " &
      "`variant: T = default` inside a package `config:` block")
  ctx.nodeOf(c.id)

proc value*[T](c: Configurable[T]): T =
  ## Return the resolved variant value. Raises ``EVariantNotResolved``
  ## when the ambient variant context has not yet been finalised; the
  ## diagnostic names the violated phase ordering per
  ## ``Configurable-System.md`` §"Static-Value Contract".
  ##
  ## When the configurable is NOT a variant (no ``solverParticipating``
  ## tag) the call raises ``ENotAVariant`` so authors do not silently
  ## blend the variant-specific accessor onto a plain Configurable.
  let ctx = currentVariantContext()
  if ctx.isNil:
    raise newException(EVariantNotResolved,
      "variant.value read before any variant context exists — " &
      "ensure the package's `config:` block has been evaluated " &
      "before `build:` reads the variant")
  if ctx.state != ccsFinalized:
    raise newException(EVariantNotResolved,
      "variant.value read before finalize — recipe code at " &
      "graph emission time (stage 4) requires the variant context " &
      "to have completed `evalConfig` finalisation (stage 2/3)")
  let node = ctx.nodeOf(c.id)
  if not node.solverParticipating:
    raise newException(ENotAVariant,
      "Configurable '" & node.scopeDerivedName & "' is not a variant; " &
      "use `read(ctx, c)` for plain Configurables")
  unwrapValue[T](node.resolvedVal)

proc isSolverParticipating*[T](c: Configurable[T]): bool =
  ## Whether the underlying node carries the variant tag. Test helpers
  ## consume this to verify the declaration surface lands the tag
  ## correctly.
  let ctx = currentVariantContext()
  if ctx.isNil: return false
  let node = ctx.nodeOf(c.id)
  node.solverParticipating

proc variantContributions*[T](c: Configurable[T]): seq[Contribution] =
  ## Expose the variant's contribution list for test assertions. The
  ## list preserves declaration order; callers should inspect priority
  ## bands rather than positional offsets.
  let ctx = currentVariantContext()
  if ctx.isNil: return @[]
  ctx.nodeOf(c.id).contributions

proc variantsFinalized*(): bool =
  ## True iff the ambient variant context has been finalised. Used by
  ## diagnostic helpers and by tests asserting the finalize lifecycle.
  let ctx = currentVariantContext()
  not ctx.isNil and ctx.state == ccsFinalized
