## ``repro_solver/clingo_bindings`` — hand-written subset of the clingo
## C API used by the Spec-Implementation M2 ASP-based concretizer.
##
## clingo is a state-of-the-art Answer Set Programming (ASP) solver
## published by the Potassco group (University of Potsdam). The C API
## ships as ``libclingo.so`` (or ``libclingo.dylib`` on macOS, or
## ``clingo.dll`` on Windows) with public headers at
## ``<clingo/clingo.h>``. We dlopen the shared library at runtime via
## Nim's ``{.dynlib.}`` pragma so no extra link-time wiring is needed
## from the Nim package.
##
## **Scope (M2a):** the minimal subset needed to:
##
## 1. construct a ``clingo_control_t`` from an empty argv list
##    (``clingo_control_new``)
## 2. feed it an ASP program string (``clingo_control_add``)
## 3. ground a single base part (``clingo_control_ground``)
## 4. solve in the default mode (``clingo_control_solve``)
## 5. block on the first result (``clingo_solve_handle_get``,
##    ``clingo_solve_handle_model``)
## 6. read out the symbols of the model
##    (``clingo_model_symbols_size``, ``clingo_model_symbols``,
##    ``clingo_symbol_to_string_size``, ``clingo_symbol_to_string``)
## 7. close the handle and free the control
##    (``clingo_solve_handle_close``, ``clingo_control_free``)
## 8. retrieve last-error diagnostics for assertion messages
##    (``clingo_error_message``)
##
## **Out of M2a scope:** assumptions / cores, theory atoms, observer
## callbacks, configuration, statistics, async solve, symbolic-atom
## iteration. M2b–M2e add what they need.
##
## **M2e additions:** symbolic-atoms lookup
## (``clingo_control_symbolic_atoms`` /
## ``clingo_symbolic_atoms_find`` / ``clingo_symbolic_atoms_literal``)
## so callers can map ground atoms back to program literals for use
## as assumptions; ``clingo_solve_handle_core`` to extract the
## minimal unsat core after a solve under assumptions; and the
## symbol construction entry points
## (``clingo_symbol_create_string`` /
## ``clingo_symbol_create_function``) needed to materialise a
## ``clingo_symbol_t`` for the ``find`` call.
##
## **Doc-page references:** signatures are taken verbatim from the
## clingo 5.8 C API headers shipped at
## ``<nixpkgs>/pkgs/development/tools/clingo``. Each proc's docstring
## links the upstream documentation group (Control, Solving, Model,
## Symbol) that the function belongs to so M2b–M2e have a fast path back
## to the upstream reference.

# Dynlib selection: clingo's shared object is plain ``libclingo``
# without a soname version on nixpkgs's clingo 5.8 derivation; both
# ``libclingo.so`` and ``libclingo.so.4`` exist as symlinks pointing at
# the same library. We prefer the unsuffixed soname so the binding
# stays version-agnostic.
const clingoLib* =
  when defined(windows):
    "clingo.dll"
  elif defined(macosx):
    "libclingo.dylib"
  else:
    "libclingo.so"

# --------------------------------------------------------------------
# Opaque handle types
# --------------------------------------------------------------------
#
# clingo exposes ``clingo_control_t``, ``clingo_solve_handle_t``, and
# ``clingo_model_t`` as opaque structs — the C header forward-declares
# them and the library owns the layout. On the Nim side we model them
# as ``object`` with no fields and only ever traffic in pointers.

type
  # All three opaque handles are modeled as Nim-side empty objects
  # (no ``importc``, no ``header`` pragma) so the C ``<clingo/clingo.h>``
  # header is NOT required at Nim-compile time. We dlopen
  # ``libclingo.so`` at runtime; the C entry points only traffic in
  # ``void *`` from the perspective of the bindings, so layout-free
  # opaque types are sufficient. ``isNil`` works directly on ``ptr T``
  # for any T so callers can null-check freshly-declared handles.
  ClingoControl* = object
  ClingoSolveHandle* = object
  ClingoModel* = object
  ClingoSymbolicAtoms* = object
    ## ``clingo_symbolic_atoms_t`` — the opaque handle the symbolic
    ## atoms API hangs off of. ``clingo_control_symbolic_atoms``
    ## returns one of these (borrowed from the control); we never
    ## free it directly.

  ClingoControlPtr* = ptr ClingoControl
  ClingoSolveHandlePtr* = ptr ClingoSolveHandle
  ClingoModelPtr* = ptr ClingoModel
  ClingoSymbolicAtomsPtr* = ptr ClingoSymbolicAtoms

  ClingoSymbol* = uint64
    ## ``clingo_symbol_t`` is a tagged uint64 encoding of a grounded
    ## symbol (number, string, function, infimum, supremum). We use
    ## ``clingo_symbol_to_string_*`` to render them for the smoke test
    ## rather than decoding the tag bits by hand.

  ClingoLiteral* = int32
    ## ``clingo_literal_t`` — a signed program literal. Positive
    ## means the atom holds; negative means the atom's negation
    ## holds. Used as the assumption type passed to
    ## ``clingo_control_solve`` and as the entry type of the unsat
    ## core returned by ``clingo_solve_handle_core``.

  ClingoSymbolicAtomIterator* = uint64
    ## Opaque iterator into the symbolic atoms collection. The C type
    ## is ``clingo_symbolic_atom_iterator_t`` (a 64-bit integer the
    ## library treats as an iterator handle).

  ClingoSolveResult* = cuint
    ## Bitset of ``clingo_solve_result_e`` (satisfiable=1,
    ## unsatisfiable=2, exhausted=4, interrupted=8).

  ClingoSolveMode* = cuint
    ## Bitset of ``clingo_solve_mode_e`` (async=1, yield=2). The smoke
    ## test uses the default mode (0) which blocks on the first model.

  ClingoShowType* = cuint
    ## Bitset of ``clingo_show_type_e`` selecting which symbols to
    ## extract from a model (shown=2, atoms=4, terms=8, theory=16,
    ## all=31, complement=32).

# --------------------------------------------------------------------
# Constants (mirror the C enum values verbatim)
# --------------------------------------------------------------------

const
  clingoSolveResultSatisfiable*: ClingoSolveResult = 1
  clingoSolveResultUnsatisfiable*: ClingoSolveResult = 2
  clingoSolveResultExhausted*: ClingoSolveResult = 4
  clingoSolveResultInterrupted*: ClingoSolveResult = 8

  clingoSolveModeDefault*: ClingoSolveMode = 0
  clingoSolveModeAsync*: ClingoSolveMode = 1
  clingoSolveModeYield*: ClingoSolveMode = 2

  clingoShowTypeShown*: ClingoShowType = 2
  clingoShowTypeAtoms*: ClingoShowType = 4
  clingoShowTypeTerms*: ClingoShowType = 8
  clingoShowTypeTheory*: ClingoShowType = 16
  clingoShowTypeAll*: ClingoShowType = 31

# --------------------------------------------------------------------
# Part description for clingo_control_ground
# --------------------------------------------------------------------

type
  ClingoPart* {.bycopy.} = object
    ## Mirrors ``clingo_part_t`` from the Control module. ``name`` is
    ## the program-part name (the ``#program`` directive identifier or
    ## ``"base"`` for the default part); ``params`` is an optional
    ## array of ground term parameters (NULL when there are none);
    ## ``size`` is the parameter count.
    name*: cstring
    params*: ptr ClingoSymbol
    size*: csize_t

# --------------------------------------------------------------------
# Bindings
# --------------------------------------------------------------------
#
# Every proc returns C ``bool`` (false on error). When false, the
# caller must consult ``clingo_error_message`` for the per-thread error
# string. ``clingo_control_free`` and ``clingo_solve_handle_close``
# are the cleanup pair; they must run on the happy path AND on the
# error path so the high-level wrapper uses ``try / finally``.

{.push cdecl, importc, dynlib: clingoLib.}

proc clingo_control_new*(arguments: ptr cstring;
                         argumentsSize: csize_t;
                         logger: pointer;
                         loggerData: pointer;
                         messageLimit: cuint;
                         control: ptr ClingoControlPtr): bool
  ## Allocate a new control object. Upstream doc: Control module,
  ## "Creating and Destroying Control Objects". ``arguments`` may be
  ## NULL when ``argumentsSize`` is 0; the smoke test passes the empty
  ## argv. ``logger`` is NULL when we don't want callback diagnostics.

proc clingo_control_free*(control: ClingoControlPtr)
  ## Destroy a control object. Upstream doc: Control module.

proc clingo_control_add*(control: ClingoControlPtr;
                         name: cstring;
                         parameters: ptr cstring;
                         parametersSize: csize_t;
                         program: cstring): bool
  ## Append a non-ground program (an ASP program text) to a named
  ## part of the control. Upstream doc: Control module,
  ## "Loading Programs". ``"base"`` is the canonical default part.

proc clingo_control_ground*(control: ClingoControlPtr;
                            parts: ptr ClingoPart;
                            partsSize: csize_t;
                            groundCallback: pointer;
                            groundCallbackData: pointer): bool
  ## Ground the requested parts. Upstream doc: Control module,
  ## "Grounding". The callback is for external functions
  ## (``@name(...)``); we pass NULL because the smoke test's program
  ## has none.

proc clingo_control_solve*(control: ClingoControlPtr;
                           mode: ClingoSolveMode;
                           assumptions: pointer;
                           assumptionsSize: csize_t;
                           notify: pointer;
                           data: pointer;
                           handle: ptr ClingoSolveHandlePtr): bool
  ## Start a solve and obtain a handle. Upstream doc: Solving module,
  ## "Solve Functions". ``assumptions`` is NULL when we have none;
  ## ``notify`` is the event callback (NULL for the smoke test).

proc clingo_solve_handle_get*(handle: ClingoSolveHandlePtr;
                              result: ptr ClingoSolveResult): bool
  ## Block on the next result. Upstream doc: Solving module,
  ## "Solve Handle".

proc clingo_solve_handle_model*(handle: ClingoSolveHandlePtr;
                                model: ptr ptr ClingoModel): bool
  ## Get the current model when the solve is at a model event.
  ## Upstream doc: Solving module, "Solve Handle". The pointed-to
  ## model is valid only until the next handle call.

proc clingo_solve_handle_resume*(handle: ClingoSolveHandlePtr): bool
  ## Resume the search after a model event. Upstream doc: Solving
  ## module, "Solve Handle". In yield mode, the search blocks at every
  ## model; ``resume`` advances it to the next model (or to the end of
  ## the search). The smoke test calls this after extracting symbols
  ## from the first model so the final ``clingo_solve_handle_get``
  ## sees a fully-finished solve.

proc clingo_solve_handle_close*(handle: ClingoSolveHandlePtr): bool
  ## Stop solving and release the handle. Upstream doc: Solving
  ## module, "Solve Handle". Must run on both the happy and error
  ## paths.

proc clingo_model_symbols_size*(model: ptr ClingoModel;
                                show: ClingoShowType;
                                size: ptr csize_t): bool
  ## Two-step pattern's first call: ask how many symbols the model
  ## holds for the requested show mask. Upstream doc: Model module,
  ## "Symbols".

proc clingo_model_symbols*(model: ptr ClingoModel;
                           show: ClingoShowType;
                           symbols: ptr ClingoSymbol;
                           size: csize_t): bool
  ## Two-step pattern's second call: fill a pre-allocated buffer with
  ## ``size`` symbols. Upstream doc: Model module, "Symbols".

proc clingo_symbol_to_string_size*(symbol: ClingoSymbol;
                                   size: ptr csize_t): bool
  ## Two-step rendering: ask how many bytes ``symbol``'s string form
  ## takes (including the trailing NUL). Upstream doc: Symbol module,
  ## "Symbols Inspection".

proc clingo_symbol_to_string*(symbol: ClingoSymbol;
                              str: ptr char;
                              size: csize_t): bool
  ## Two-step rendering: write the string form of ``symbol`` into the
  ## caller's buffer. Upstream doc: Symbol module, "Symbols
  ## Inspection".

proc clingo_error_message*(): cstring
  ## Per-thread last-error message. Returns NULL when no error has
  ## been recorded since the previous successful call. Upstream doc:
  ## "Error Handling".

# --------------------------------------------------------------------
# M2e — assumption interface + symbolic atom lookup
# --------------------------------------------------------------------

proc clingo_solve_handle_core*(handle: ClingoSolveHandlePtr;
                               core: ptr ptr ClingoLiteral;
                               size: ptr csize_t): bool
  ## Extract the unsat core from a handle whose solve completed
  ## unsatisfiably under assumptions. Upstream doc: Solving module,
  ## "Solve Handle". The returned ``core`` array is borrowed from
  ## the handle and stays valid until the handle is closed. Each
  ## entry is a ``clingo_literal_t`` matching one of the assumption
  ## literals the caller passed to ``clingo_control_solve``; the sign
  ## tells whether the positive or the negative form participates in
  ## the conflict.

proc clingo_control_symbolic_atoms*(control: ClingoControlPtr;
                                    atoms: ptr ClingoSymbolicAtomsPtr): bool
  ## Borrow the symbolic-atoms collection from a grounded control.
  ## Upstream doc: Control module, "Inspection". The collection is
  ## only meaningful AFTER grounding; calling this before
  ## ``clingo_control_ground`` returns an empty collection.

proc clingo_symbolic_atoms_find*(atoms: ClingoSymbolicAtomsPtr;
                                 symbol: ClingoSymbol;
                                 iterator_out: ptr ClingoSymbolicAtomIterator): bool
  ## Locate an atom in the symbolic-atoms collection by its grounded
  ## symbol. Upstream doc: SymbolicAtoms module. When the atom is
  ## present the iterator points at it; when absent the iterator
  ## equals the end iterator (test with ``clingo_symbolic_atoms_is_valid``).

proc clingo_symbolic_atoms_is_valid*(atoms: ClingoSymbolicAtomsPtr;
                                     iterator_in: ClingoSymbolicAtomIterator;
                                     valid: ptr bool): bool
  ## Check whether an iterator points at a real atom (true) or at the
  ## end-of-collection sentinel (false). Upstream doc: SymbolicAtoms
  ## module.

proc clingo_symbolic_atoms_literal*(atoms: ClingoSymbolicAtomsPtr;
                                    iterator_in: ClingoSymbolicAtomIterator;
                                    literal: ptr ClingoLiteral): bool
  ## Read the program literal of the atom an iterator points at.
  ## Upstream doc: SymbolicAtoms module. Use this literal as an
  ## assumption to ``clingo_control_solve``.

proc clingo_symbol_create_string*(str: cstring;
                                  symbol: ptr ClingoSymbol): bool
  ## Construct a string symbol from a cstring. Upstream doc: Symbol
  ## module, "Symbols Construction". The returned tagged ``uint64``
  ## carries the string by reference into clingo's symbol table; the
  ## caller's buffer can be freed immediately afterwards.

proc clingo_symbol_create_number*(number: cint; symbol: ptr ClingoSymbol)
  ## Construct a number symbol from a C int. Upstream doc: Symbol
  ## module, "Symbols Construction". Cannot fail (the operation is
  ## pure tagging); returns ``void`` in the C header.

proc clingo_symbol_create_function*(name: cstring;
                                    arguments: ptr ClingoSymbol;
                                    argumentsSize: csize_t;
                                    positive: bool;
                                    symbol: ptr ClingoSymbol): bool
  ## Construct a function symbol from a name + argument array.
  ## Upstream doc: Symbol module, "Symbols Construction". ``positive``
  ## is true for the standard ``name(args)`` form; false produces the
  ## negation form ``-name(args)``.

{.pop.}

# --------------------------------------------------------------------
# Nim-side convenience for two-step string rendering
# --------------------------------------------------------------------

proc symbolToString*(symbol: ClingoSymbol): string =
  ## Convenience wrapper for the standard two-step
  ## ``clingo_symbol_to_string_*`` rendering pattern. Returns the empty
  ## string on error and stamps the per-thread error slot with
  ## ``clingo_error_message`` for the caller to read. Used by the
  ## smoke test to render the symbols in the solve model.
  var sz: csize_t = 0
  if not clingo_symbol_to_string_size(symbol, addr sz):
    return ""
  if sz == 0:
    return ""
  result = newString(int(sz) - 1)
  # We pass `int(sz)` so clingo writes the trailing NUL byte into the
  # one byte past `result[^1]`. Nim's `newString(n)` allocates n + 1
  # bytes internally (the n visible characters plus a sentinel NUL)
  # so writing the NUL is safe.
  var buf = newSeq[char](int(sz))
  if not clingo_symbol_to_string(symbol, addr buf[0], sz):
    return ""
  # Strip the trailing NUL byte clingo writes at index sz - 1.
  for i in 0 ..< int(sz) - 1:
    result[i] = buf[i]

proc lastError*(): string =
  ## Convenience wrapper around ``clingo_error_message`` that returns
  ## the empty string when no error is set (rather than a NULL
  ## cstring). Smoke test uses this when an assertion fires so the
  ## test report names the clingo-side complaint.
  let raw = clingo_error_message()
  if raw.isNil:
    ""
  else:
    $raw
