## ``repro_solver/solver_api`` — high-level public surface for the
## Spec-Implementation M2 ASP-based concretizer.
##
## M2a (this file) defines the *placeholder* shape of the API: a
## ``Solver`` record carrying nothing yet, a ``Solution`` record
## carrying nothing yet, and a ``Constraint`` variant capturing the
## three constraint shapes M2b/M2c will need to encode. ``solve`` is a
## stub that returns an empty ``Solution`` so callers can already
## reference the public surface without compile errors.
##
## **What M2b–M2e add on top of this scaffold**
##
## * **M2b — variant encoder**: walk the
##   ``libs/repro_dsl_stdlib/configurables/variants.nim`` registry,
##   emit ASP atoms (one per variant value) + priorities + the
##   ``requires:`` / ``conflicts:`` / ``propagates:`` rules. ``Solver``
##   grows a ``variants: seq[VariantDecl]`` field; ``Solution`` grows
##   ``variantAssignments: Table[string, string]``.
## * **M2c — version-constraint encoder**: lift the version-range
##   constraints out of the package model and onto the same control.
##   Spack's ``asp.py`` ``concretize.lp`` is the reference encoding.
## * **M2d — variant-conditioned ``uses:``**: feed the resolved variant
##   assignments back through the M1 ``finalizeVariants()`` path so the
##   conditional ``uses:`` arms come alive during graph emission.
## * **M2e — explanation paths**: walk the unsat core
##   (``clingo_solve_handle_core``) and the model atoms to produce
##   structured "why X chosen" / "why unsatisfiable" diagnostics.
##
## **Out of M2a scope:** every encoding decision above. M2a deliberately
## stops at the typed surface so the review agent has a small diff to
## sign off on.

import std/[sets, strutils, tables]

import clingo_bindings
import variant_encoder
import version_encoder
import version_constraints
import explainer

export clingo_bindings
export variant_encoder
export version_encoder
export version_constraints
export explainer

# --------------------------------------------------------------------
# Constraint surface (placeholder)
# --------------------------------------------------------------------

type
  ConstraintKind* = enum
    ## The three constraint shapes the variant addendum in
    ## ``Configurable-System.md`` §"Solver-Participating Configurables
    ## (Variants)" introduces. M2b's encoder dispatches on this tag.
    ckRequires        ## ``requires: variantA = "x" -> packageB`` etc.
    ckConflicts       ## ``conflicts: variantA = "x" with variantB = "y"``
    ckPropagates      ## ``propagates: variantA -> variantB`` (value carry)

  Constraint* = object
    ## Placeholder constraint record. M2b grows this into the typed
    ## expression tree the encoder consumes. The string ``raw`` field
    ## is here so M2a-era callers can stamp a debug label without
    ## committing to a tree shape.
    case kind*: ConstraintKind
    of ckRequires:
      requiresRaw*: string
    of ckConflicts:
      conflictsRaw*: string
    of ckPropagates:
      propagatesRaw*: string

# --------------------------------------------------------------------
# Solver / Solution (placeholder)
# --------------------------------------------------------------------

type
  Solver* = object
    ## Placeholder solver handle. M2b grows this into a real record
    ## carrying the variant registry, the package version-range index,
    ## the ASP encoding buffer, and the clingo control pointer. M2a
    ## ships the bare type so downstream lib code can reference it.
    constraints*: seq[Constraint]

  Solution* = object
    ## Placeholder solution record. M2b grows ``variantAssignments``;
    ## M2c grows a ``packageVersions`` table; M2d grows the lookup map
    ## ``finalizeVariants()`` consumes; M2e grows the explanation
    ## surface. M2a ships the bare type plus an ``isEmpty`` indicator.
    isEmpty*: bool
    variantAssignments*: Table[string, string]

# --------------------------------------------------------------------
# Public API (stub)
# --------------------------------------------------------------------

proc newSolver*(): Solver =
  ## M2a constructor: returns a Solver with no constraints. M2b will
  ## extend this with a variant-registry pull from
  ## ``libs/repro_dsl_stdlib/configurables/variants.nim``.
  Solver(constraints: @[])

proc addConstraint*(solver: var Solver; c: Constraint) =
  ## M2a accumulation hook so M2b's encoder has a single chokepoint to
  ## intercept. Today the constraint is stored verbatim; M2b will
  ## translate it into ASP rules as it lands.
  solver.constraints.add(c)

proc solve*(solver: Solver): Solution {.exportc.} =
  ## M2a stub. Returns an empty ``Solution`` ready for M2b's encoder
  ## to fill in. The ``{.exportc.}`` pragma is here so M2d's
  ## variant.value finalize path can call into the solver across the
  ## (eventual) dynamic-library boundary used by the runtime DSL DLL.
  ## M2a's stub is intentionally pure-Nim with no clingo call so that
  ## this scaffold compiles cleanly on systems where ``libclingo.so``
  ## hasn't been pulled in yet (build-time visibility of the binding
  ## doesn't imply load-time presence of the shared library).
  Solution(isEmpty: true, variantAssignments: initTable[string, string]())

# --------------------------------------------------------------------
# M2b — variant solver
# --------------------------------------------------------------------

type
  VariantSolution* = object
    ## Outcome of a variant-only solve. ``assignments`` maps each
    ## variant's declared name to the resolved value as a string
    ## (clingo's symbol form). ``optimal`` is true when clingo proved
    ## optimality (the search exhausted alternatives), false when only
    ## one model was retrieved without an optimization proof — for M2b
    ## inputs the search space is small enough that clingo always
    ## proves optimality, but the flag is here so M2c/M2d can detect
    ## a non-optimal terminal model without breaking the API.
    assignments*: Table[string, string]
    optimal*: bool

  EVariantUnsatisfiable* = object of CatchableError
    ## Raised when the encoded program has no stable model. M2b carries
    ## the ASP program text in ``programText`` so callers can re-print
    ## it for the diagnostic; the explicit unsat-core enumeration is
    ## M2e work (clingo's ``solve_handle_core`` requires an
    ## assumption-based encoding that we don't ship in M2b). For M2b,
    ## the ``unsatCore`` field holds the list of variant names that
    ## participated in any constraint expression so the diagnostic at
    ## least names which variants are part of the conflict.
    programText*: string
    unsatCore*: seq[string]

# --------------------------------------------------------------------
# Internal helpers
# --------------------------------------------------------------------

proc parseModelSymbol(rendered: string;
                      assignments: var Table[string, string]) =
  ## Parse one rendered ``variant_assigned("name", "value")`` symbol
  ## into the assignments table. Tolerates extra whitespace clingo
  ## occasionally inserts in argument lists; rejects symbols whose
  ## structure does not match the predicate shape.
  const head = "variant_assigned("
  let stripped = rendered.strip()
  if not stripped.startsWith(head):
    return
  if not stripped.endsWith(")"):
    return
  let body = stripped[head.len .. ^2]  # strip head and closing ')'
  # Find the comma separating the two string arguments — the names
  # and values in M2b's encoder are clingo string literals
  # (double-quoted), so the first comma OUTSIDE quotes is the
  # delimiter.
  var inQuote = false
  var splitAt = -1
  for i, c in body:
    if c == '"': inQuote = not inQuote
    elif c == ',' and not inQuote:
      splitAt = i
      break
  if splitAt < 0:
    return
  proc dequote(s: string): string =
    let t = s.strip()
    if t.len >= 2 and t[0] == '"' and t[^1] == '"':
      return t[1 ..< ^1]
    t
  let name = dequote(body[0 ..< splitAt])
  let value = dequote(body[splitAt + 1 .. ^1])
  if name.len == 0:
    return
  assignments[name] = value

proc collectUnsatCore(variants: openArray[VariantDecl]): seq[string] =
  ## Best-effort: gather the names of every variant that participates
  ## in at least one constraint expression. Clingo's true unsat-core
  ## enumeration requires the assumption-based interface (M2e); for
  ## M2b we surface the constraint-participating variant set so the
  ## diagnostic at least narrows the suspect list.
  var seen: HashSet[string]
  for v in variants:
    if v.constraints.len > 0:
      if v.name notin seen:
        seen.incl(v.name)
        result.add(v.name)
      for c in v.constraints:
        if c.target notin seen:
          seen.incl(c.target)
          result.add(c.target)

# --------------------------------------------------------------------
# Public M2b entry point
# --------------------------------------------------------------------

proc solveVariants*(variants: openArray[VariantDecl]): VariantSolution =
  ## Encode the registry through ``encodeVariants`` and drive it
  ## through ``libclingo.so`` via the M2a bindings. Returns the
  ## resolved assignment per variant. Raises
  ## ``EVariantUnsatisfiable`` when no stable model exists; the
  ## exception carries the ASP program text and a best-effort
  ## unsat-core enumeration of the variants that participated in
  ## constraint expressions.
  ##
  ## The driver follows the standard nine-step clingo lifecycle:
  ##
  ## 1. ``clingo_control_new`` with an empty argv.
  ## 2. ``clingo_control_add`` against the canonical ``"base"`` part.
  ## 3. ``clingo_control_ground`` on the same ``"base"`` part.
  ## 4. ``clingo_control_solve`` in ``yield`` mode.
  ## 5. ``clingo_solve_handle_model`` — extract the LAST model the
  ##    solver yields before exhausting the search; clingo's
  ##    optimization stream yields successively better models, so the
  ##    last model under ``yield`` mode is the optimum.
  ## 6. ``clingo_model_symbols`` — fetch the shown atoms.
  ## 7. Parse each ``variant_assigned("name","value")`` symbol into
  ##    the result table.
  ## 8. ``clingo_solve_handle_resume`` + ``clingo_solve_handle_get``
  ##    to drain the search and read the solve-result bitset; this is
  ##    how we know whether the search proved optimality.
  ## 9. Cleanup pair (``handle_close`` + ``control_free``) runs on
  ##    both happy and error paths.
  let program = encodeVariants(variants)
  result = VariantSolution(assignments: initTable[string, string](),
                           optimal: false)

  var control: ClingoControlPtr = nil
  var handle: ClingoSolveHandlePtr = nil
  var model: ptr ClingoModel = nil
  var sawAnyModel = false
  var solveResult: ClingoSolveResult = 0

  try:
    if not clingo_control_new(nil, 0, nil, nil, 20, addr control):
      raise newException(CatchableError,
        "clingo_control_new failed: " & lastError())
    # clingo copies the program buffer internally so a transient
    # cstring view of our Nim ``string`` is safe; explicit cast quiets
    # the implicit-conversion warning.
    let progC = cstring(program)
    if not clingo_control_add(control, "base", nil, 0, progC):
      raise newException(CatchableError,
        "clingo_control_add failed: " & lastError())
    var parts = @[ClingoPart(name: "base", params: nil, size: 0)]
    if not clingo_control_ground(control, addr parts[0], 1, nil, nil):
      raise newException(CatchableError,
        "clingo_control_ground failed: " & lastError())
    if not clingo_control_solve(control, clingoSolveModeYield, nil, 0,
                                 nil, nil, addr handle):
      raise newException(CatchableError,
        "clingo_control_solve failed: " & lastError())

    # Walk every model the optimizer yields; the LAST model is the
    # optimal one. clingo's #minimize directive emits intermediate
    # models in non-increasing cost order, so overwriting ``assignments``
    # on each step lands the optimum at the end of the loop.
    while true:
      model = nil
      if not clingo_solve_handle_model(handle, addr model):
        raise newException(CatchableError,
          "clingo_solve_handle_model failed: " & lastError())
      if model.isNil:
        break
      sawAnyModel = true
      var symCount: csize_t = 0
      if not clingo_model_symbols_size(model, clingoShowTypeShown,
                                       addr symCount):
        raise newException(CatchableError,
          "clingo_model_symbols_size failed: " & lastError())
      var syms = newSeq[ClingoSymbol](int(symCount))
      if symCount > 0:
        if not clingo_model_symbols(model, clingoShowTypeShown,
                                    addr syms[0], symCount):
          raise newException(CatchableError,
            "clingo_model_symbols failed: " & lastError())
      var pending = initTable[string, string]()
      for s in syms:
        parseModelSymbol(symbolToString(s), pending)
      result.assignments = pending
      if not clingo_solve_handle_resume(handle):
        raise newException(CatchableError,
          "clingo_solve_handle_resume failed: " & lastError())

    if not clingo_solve_handle_get(handle, addr solveResult):
      raise newException(CatchableError,
        "clingo_solve_handle_get failed: " & lastError())

    if not sawAnyModel:
      var e = newException(EVariantUnsatisfiable,
        "no satisfying assignment exists for the supplied variant " &
        "registry")
      e.programText = program
      e.unsatCore = collectUnsatCore(variants)
      raise e

    # The search is "optimal" when the solver exhausted the space
    # without interruption. clingo's #minimize problems carry the
    # ``exhausted`` bit on the final solve-result.
    result.optimal = (solveResult and clingoSolveResultExhausted) != 0
  finally:
    if not handle.isNil:
      discard clingo_solve_handle_close(handle)
    if not control.isNil:
      clingo_control_free(control)

# --------------------------------------------------------------------
# M2c — unified variant + version solver
# --------------------------------------------------------------------

## ``UnifiedSolution`` and ``EUnsatisfiable`` were moved into
## ``explainer.nim`` for M2e so the explainer can take the solution
## record directly without a circular import. They are re-exported
## above via ``export explainer``, so callers continue to see them at
## the same path.

# --------------------------------------------------------------------
# Internal helpers for the unified driver
# --------------------------------------------------------------------

proc parseUnifiedSymbol(rendered: string;
                        variants: var Table[string, string];
                        packages: var Table[string, string]) =
  ## Dispatch on the predicate name. The shape of the two predicates
  ## is identical so we share the same parsing core (lifted from
  ## ``parseModelSymbol``) and choose the output table on the head
  ## token.
  let stripped = rendered.strip()
  var head = ""
  if stripped.startsWith("variant_assigned("):
    head = "variant_assigned("
  elif stripped.startsWith("package_chosen("):
    head = "package_chosen("
  else:
    return
  if not stripped.endsWith(")"):
    return
  let body = stripped[head.len .. ^2]
  var inQuote = false
  var splitAt = -1
  for i, c in body:
    if c == '"': inQuote = not inQuote
    elif c == ',' and not inQuote:
      splitAt = i
      break
  if splitAt < 0:
    return
  proc dequote(s: string): string =
    let t = s.strip()
    if t.len >= 2 and t[0] == '"' and t[^1] == '"':
      return t[1 ..< ^1]
    t
  let name = dequote(body[0 ..< splitAt])
  let value = dequote(body[splitAt + 1 .. ^1])
  if name.len == 0:
    return
  if head == "variant_assigned(":
    variants[name] = value
  else:
    packages[name] = value

proc collectUnifiedUnsatCore(variants: openArray[VariantDecl];
                             packages: openArray[PackageDecl]): seq[string] =
  ## Enumerate the names of every variant and package that participates
  ## in any constraint or dependency edge. Best-effort: clingo's true
  ## unsat-core enumeration is M2e. This at least narrows the suspect
  ## set the diagnostic surface presents.
  var seen: HashSet[string]
  for v in variants:
    if v.constraints.len > 0:
      if v.name notin seen:
        seen.incl(v.name)
        result.add(v.name)
      for c in v.constraints:
        if c.target notin seen:
          seen.incl(c.target)
          result.add(c.target)
  for p in packages:
    if p.depends.len > 0 or p.variants.len > 0:
      if p.name notin seen:
        seen.incl(p.name)
        result.add(p.name)
    for d in p.depends:
      if d.name notin seen:
        seen.incl(d.name)
        result.add(d.name)
    for v in p.variants:
      if v.constraints.len > 0 and v.name notin seen:
        seen.incl(v.name)
        result.add(v.name)

# --------------------------------------------------------------------
# Public M2c entry point
# --------------------------------------------------------------------

# Forward declaration: the M2e unsat-core re-solve helper lives below
# the main ``solve()`` because Nim requires its definition order to
# follow the surface it consumes. ``solve()`` calls into this helper
# on the unsat path.
proc solveForUnsatCore*(variants: openArray[VariantDecl];
                        packages: openArray[PackageDecl]): seq[string]

proc solve*(variants: openArray[VariantDecl];
            packages: openArray[PackageDecl]): UnifiedSolution =
  ## Combined variant + package version solve. Encodes both via
  ## ``encodeUnified``, runs clingo, parses both
  ## ``variant_assigned/2`` and ``package_chosen/2`` from the optimum
  ## model. Raises ``EUnsatisfiable`` (carrying the ASP program text
  ## and best-effort unsat-core) when no stable model exists.
  ##
  ## The driver lifecycle mirrors ``solveVariants``'s nine-step
  ## sequence; the only difference is the show directive surfaces two
  ## predicate families and the parse step routes by predicate name.
  let program = encodeUnified(variants, packages)
  result = UnifiedSolution(variants: initTable[string, string](),
                           packages: initTable[string, string](),
                           optimal: false)

  var control: ClingoControlPtr = nil
  var handle: ClingoSolveHandlePtr = nil
  var model: ptr ClingoModel = nil
  var sawAnyModel = false
  var solveResult: ClingoSolveResult = 0

  try:
    if not clingo_control_new(nil, 0, nil, nil, 20, addr control):
      raise newException(CatchableError,
        "clingo_control_new failed: " & lastError())
    let progC = cstring(program)
    if not clingo_control_add(control, "base", nil, 0, progC):
      raise newException(CatchableError,
        "clingo_control_add failed: " & lastError())
    var parts = @[ClingoPart(name: "base", params: nil, size: 0)]
    if not clingo_control_ground(control, addr parts[0], 1, nil, nil):
      raise newException(CatchableError,
        "clingo_control_ground failed: " & lastError())
    if not clingo_control_solve(control, clingoSolveModeYield, nil, 0,
                                 nil, nil, addr handle):
      raise newException(CatchableError,
        "clingo_control_solve failed: " & lastError())

    while true:
      model = nil
      if not clingo_solve_handle_model(handle, addr model):
        raise newException(CatchableError,
          "clingo_solve_handle_model failed: " & lastError())
      if model.isNil:
        break
      sawAnyModel = true
      var symCount: csize_t = 0
      if not clingo_model_symbols_size(model, clingoShowTypeShown,
                                       addr symCount):
        raise newException(CatchableError,
          "clingo_model_symbols_size failed: " & lastError())
      var syms = newSeq[ClingoSymbol](int(symCount))
      if symCount > 0:
        if not clingo_model_symbols(model, clingoShowTypeShown,
                                    addr syms[0], symCount):
          raise newException(CatchableError,
            "clingo_model_symbols failed: " & lastError())
      var pendingVariants = initTable[string, string]()
      var pendingPackages = initTable[string, string]()
      for s in syms:
        parseUnifiedSymbol(symbolToString(s),
                           pendingVariants, pendingPackages)
      result.variants = pendingVariants
      result.packages = pendingPackages
      if not clingo_solve_handle_resume(handle):
        raise newException(CatchableError,
          "clingo_solve_handle_resume failed: " & lastError())

    if not clingo_solve_handle_get(handle, addr solveResult):
      raise newException(CatchableError,
        "clingo_solve_handle_get failed: " & lastError())

    if not sawAnyModel:
      var e = newException(EUnsatisfiable,
        "no satisfying assignment exists for the supplied variant + " &
        "package registry")
      e.programText = program
      e.unsatCore = collectUnifiedUnsatCore(variants, packages)
      # M2e: re-run with the annotation-based encoder so the assumption
      # interface populates the minimal core. We must close the current
      # handle FIRST because clingo's API forbids overlapping solve
      # contexts on the same control. The re-solve happens on a brand
      # new control object so it can never observe stale state.
      if not handle.isNil:
        discard clingo_solve_handle_close(handle)
        handle = nil
      if not control.isNil:
        clingo_control_free(control)
        control = nil
      e.coreAtoms = solveForUnsatCore(variants, packages)
      raise e

    result.optimal = (solveResult and clingoSolveResultExhausted) != 0
  finally:
    if not handle.isNil:
      discard clingo_solve_handle_close(handle)
    if not control.isNil:
      clingo_control_free(control)

# --------------------------------------------------------------------
# M2e — assumption-interface unsat-core enumeration
# --------------------------------------------------------------------

proc lookupAssumeLiteral(atomsPtr: ClingoSymbolicAtomsPtr;
                         constraintId: int;
                         literal: var ClingoLiteral): bool =
  ## Materialise the symbol ``assume_constraint(constraintId)`` and
  ## look up its program literal via the symbolic-atoms API. Returns
  ## false if the atom is not in the grounded program (which happens
  ## when clingo's grounder decided the external is unreferenced; we
  ## treat that as "constraint not in core" and skip the assumption).
  var idSym: ClingoSymbol = 0
  clingo_symbol_create_number(cint(constraintId), addr idSym)
  var fname: cstring = cstring("assume_constraint")
  var args = @[idSym]
  var funSym: ClingoSymbol = 0
  if not clingo_symbol_create_function(fname, addr args[0], 1, true,
                                        addr funSym):
    return false
  var it: ClingoSymbolicAtomIterator = 0
  if not clingo_symbolic_atoms_find(atomsPtr, funSym, addr it):
    return false
  var valid = false
  if not clingo_symbolic_atoms_is_valid(atomsPtr, it, addr valid):
    return false
  if not valid:
    return false
  if not clingo_symbolic_atoms_literal(atomsPtr, it, addr literal):
    return false
  return true

proc solveForUnsatCore*(variants: openArray[VariantDecl];
                        packages: openArray[PackageDecl]): seq[string] =
  ## Run a parallel solve with the annotated encoding from
  ## ``explainer.encodeWithAssumptions``: each constraint is guarded
  ## by an ``assume_constraint(N).`` external atom; we assume every
  ## external true; clingo's ``clingo_solve_handle_core`` returns the
  ## literals participating in the conflict; the
  ## ``ConstraintAnnotation`` table maps each literal back to the
  ## constraint identity via its atom name.
  ##
  ## Returns the list of ``assume_constraint(N)`` atom names that
  ## participate in the minimal unsat core. Returns the empty seq if
  ## the annotated program is unexpectedly satisfiable, or if any
  ## clingo C call fails — in either case the caller's diagnostic
  ## still has the M2c best-effort core to fall back to.
  let (program, annotations) = encodeWithAssumptions(variants, packages)
  result = @[]
  if annotations.len == 0:
    return @[]

  var control: ClingoControlPtr = nil
  var handle: ClingoSolveHandlePtr = nil
  var atomsPtr: ClingoSymbolicAtomsPtr = nil
  var solveResult: ClingoSolveResult = 0

  try:
    if not clingo_control_new(nil, 0, nil, nil, 20, addr control):
      return @[]
    let progC = cstring(program)
    if not clingo_control_add(control, "base", nil, 0, progC):
      return @[]
    var parts = @[ClingoPart(name: "base", params: nil, size: 0)]
    if not clingo_control_ground(control, addr parts[0], 1, nil, nil):
      return @[]
    if not clingo_control_symbolic_atoms(control, addr atomsPtr):
      return @[]

    # Build the assumption literal list by looking up each annotation's
    # symbol in the symbolic atoms collection. Annotations whose atoms
    # didn't ground (clingo dropped the external as redundant) are
    # silently skipped — their constraint won't appear in any core.
    var literals: seq[ClingoLiteral] = @[]
    var litToAtomName: Table[ClingoLiteral, string]
    for ann in annotations:
      var lit: ClingoLiteral = 0
      if lookupAssumeLiteral(atomsPtr, ann.id, lit):
        literals.add(lit)
        litToAtomName[lit] = ann.atomName

    if literals.len == 0:
      return @[]

    let assumptionPtr = cast[pointer](addr literals[0])
    if not clingo_control_solve(control, clingoSolveModeYield,
                                 assumptionPtr, csize_t(literals.len),
                                 nil, nil, addr handle):
      return @[]
    # Drain — under unsat we expect no models. Resume each (none-found)
    # event until the search exhausts.
    while true:
      var model: ptr ClingoModel = nil
      if not clingo_solve_handle_model(handle, addr model):
        return @[]
      if model.isNil:
        break
      if not clingo_solve_handle_resume(handle):
        return @[]
    if not clingo_solve_handle_get(handle, addr solveResult):
      return @[]
    if (solveResult and clingoSolveResultUnsatisfiable) == 0:
      # Surprisingly satisfiable — the structural unsat is outside the
      # annotated rules. Return empty so the M2c best-effort core
      # survives as the caller's diagnostic.
      return @[]
    # Extract the core.
    var corePtr: ptr ClingoLiteral = nil
    var coreSize: csize_t = 0
    if not clingo_solve_handle_core(handle, addr corePtr, addr coreSize):
      return @[]
    if coreSize == 0:
      return @[]
    for i in 0 ..< int(coreSize):
      let lit = cast[ptr ClingoLiteral](
        cast[int](corePtr) + i * sizeof(ClingoLiteral))[]
      # Match on signed literal first (positive assumption); then on
      # the negated form clingo sometimes returns; then drop unknown
      # entries silently.
      if lit in litToAtomName:
        result.add(litToAtomName[lit])
      elif (-lit) in litToAtomName:
        result.add(litToAtomName[-lit])
  finally:
    if not handle.isNil:
      discard clingo_solve_handle_close(handle)
    if not control.isNil:
      clingo_control_free(control)
