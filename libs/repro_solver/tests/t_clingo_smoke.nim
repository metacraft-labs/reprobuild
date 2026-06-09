## ``t_clingo_smoke`` — Spec-Implementation M2a end-to-end smoke test
## for ``repro_solver/clingo_bindings``.
##
## **Purpose**: drive a real ``libclingo.so`` through the eight bound
## C entry points
## (``clingo_control_new``, ``clingo_control_add``,
## ``clingo_control_ground``, ``clingo_control_solve``,
## ``clingo_solve_handle_get``, ``clingo_solve_handle_model``,
## ``clingo_model_symbols`` and the cleanup pair) and assert the solve
## returns a satisfiable model containing the symbol ``answer``.
##
## The test program is the minimal three-line ASP fragment
## ``fact. answer :- fact.`` — a single fact and a single rule whose
## conclusion fires when the fact is in the model. Both ``fact`` and
## ``answer`` must therefore appear in the unique stable model.
##
## **What "broken bindings" looks like in the test report**: a wrong
## signature on any of the eight procs surfaces as a `linker` error at
## load time (Nim's ``{.dynlib.}`` runs ``dlopen`` + ``dlsym`` on first
## call); a structurally-correct binding that disagrees with the C
## struct layout (wrong field count on ``ClingoPart``, etc.) surfaces
## either as a clingo runtime error (``clingo_error_message`` non-NULL,
## test prints the diagnostic) OR as a missing ``answer`` symbol in
## the rendered model (``foundAnswer == false`` assertion fires). The
## test MUST FAIL if any of those happen — do not paper over with
## ``try / except`` around the assertions.

import std/[unittest, strutils]

import repro_solver/clingo_bindings

template ok(call: untyped; what: string) =
  ## ``unittest.check`` doesn't carry a custom failure message and
  ## ``doAssert`` short-circuits at the first failure (which we want
  ## here — once a clingo C call fails, every subsequent call sees an
  ## invalid handle). This wrapper raises ``AssertionDefect`` with the
  ## clingo per-thread error string included so the test report names
  ## the C-side complaint instead of a bare ``false != true``. The
  ## raise unwinds through the surrounding ``try / finally`` so the
  ## cleanup pair (``clingo_solve_handle_close`` +
  ## ``clingo_control_free``) still runs.
  if not (call):
    raise newException(AssertionDefect,
      what & " failed: " & lastError())

suite "repro_solver.clingo_bindings: end-to-end smoke test":
  test "solve 'fact. answer :- fact.' yields a model containing 'answer'":
    var control: ClingoControlPtr = nil
    var handle: ClingoSolveHandlePtr = nil
    var model: ptr ClingoModel = nil

    try:
      # 1. Construct a control with no argv. The empty-argv form is
      #    documented as "use defaults"; the third / fourth args are
      #    the logger callback and its userdata, both NULL.
      ok(clingo_control_new(nil, 0, nil, nil, 20, addr control),
         "clingo_control_new")
      check not control.isNil

      # 2. Add the program text to the canonical "base" part. The
      #    parameters array is NULL (no part parameters). Typed as
      #    ``cstring`` to silence the implicit-cstring-conv warning;
      #    string literals are read-only so the conversion is safe.
      let program: cstring = "fact. answer :- fact."
      ok(clingo_control_add(control, "base", nil, 0, program),
         "clingo_control_add")

      # 3. Ground the "base" part. The C API needs an array of
      #    ``clingo_part_t`` structs even for one part, so allocate
      #    a single-element seq and pass its first-element address.
      var parts = @[ClingoPart(name: "base", params: nil, size: 0)]
      ok(clingo_control_ground(control, addr parts[0], 1, nil, nil),
         "clingo_control_ground")

      # 4. Start the solve in YIELD mode so the handle blocks at every
      #    model. Without ``clingoSolveModeYield``, the
      #    ``clingo_solve_handle_model`` call returns NULL until the
      #    search finishes — see the C API docstring on
      #    ``clingo_solve_mode_e``. No assumptions, no event callback.
      ok(clingo_control_solve(
          control, clingoSolveModeYield, nil, 0, nil, nil, addr handle),
         "clingo_control_solve")
      check not handle.isNil

      # 5. Walk results until we see a model. The first
      #    ``clingo_solve_handle_model`` returns the first model (or
      #    NULL if the search is exhausted). The fragment
      #    ``fact. answer :- fact.`` has exactly one stable model.
      ok(clingo_solve_handle_model(handle, addr model),
         "clingo_solve_handle_model")
      check not model.isNil

      # 6. Read symbols of the model. Two-step pattern: ask the size
      #    first, then allocate + read. The ``shown`` filter selects
      #    the atoms exposed by default (the same set ``clingo`` CLI
      #    prints).
      var symCount: csize_t = 0
      ok(clingo_model_symbols_size(model, clingoShowTypeShown, addr symCount),
         "clingo_model_symbols_size")
      check symCount >= 2

      var syms = newSeq[ClingoSymbol](int(symCount))
      ok(clingo_model_symbols(
          model, clingoShowTypeShown, addr syms[0], symCount),
         "clingo_model_symbols")

      # 7. Render the symbols and assert ``answer`` is present.
      var rendered: seq[string] = @[]
      for sym in syms:
        rendered.add(symbolToString(sym))
      var foundAnswer = false
      var foundFact = false
      for s in rendered:
        if s.strip() == "answer":
          foundAnswer = true
        elif s.strip() == "fact":
          foundFact = true
      check foundAnswer
      check foundFact

      # 8. Resume + drain the rest of the search (so the handle is in
      #    a well-defined state for ``close``). ``resume`` advances
      #    past the current model; ``get`` then blocks on the final
      #    solve-result bitset.
      ok(clingo_solve_handle_resume(handle), "clingo_solve_handle_resume")
      var solveResult: ClingoSolveResult = 0
      ok(clingo_solve_handle_get(handle, addr solveResult),
         "clingo_solve_handle_get")
      check (solveResult and clingoSolveResultSatisfiable) != 0
    finally:
      # 9. Cleanup pair. Both run on the happy path AND the error
      #    path — if an early ``check`` raised an exception, we still
      #    want to release the underlying clingo state. Tolerate
      #    half-initialised handles (nil pointers from an early
      #    failure) by guarding each free.
      if not handle.isNil:
        discard clingo_solve_handle_close(handle)
      if not control.isNil:
        clingo_control_free(control)
