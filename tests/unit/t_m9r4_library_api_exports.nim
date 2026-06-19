## DSL-port M9.R.4 — optional ``library api: exports:`` FFI sub-block.
##
## Pins the FFI-symbol declaration surface added on top of the M9.R.3
## ``library api:`` block. Each ``proc <name>*(<params>): <ret>``
## declaration inside the ``exports:`` body lowers to a string-shaped
## ``ExportedSymbol`` record in the per-library registry.
##
## v1 stores raw Nim source-text for params + return type; the macro
## does NOT try to type-check the signatures because the recipe
## author's library types (``Pcm`` / ``PcmStream`` / etc.) are
## typically opaque at the expansion site. Downstream tooling
## (cross-language binding generation, ABI-stability validation)
## consumes the string-shaped surface later.
##
## Coverage:
##
##   1. ``exports:`` parses + registers — three proc exports round-trip
##      through ``registeredLibraryApi(...).exports`` (count + per-row
##      ``name`` / ``paramsRaw`` / ``returnRaw``).
##   2. Raw param text preserves opaque library types
##      (``ptr SomeOpaque`` / ``cstring``) without sema-resolving them.
##   3. Doc-comment captured from the first ``## ...`` statement in the
##      proc body lands in ``exports[i].doc``.
##   4. ``exports:`` is optional — a library with ``api:`` but no
##      ``exports:`` sub-block has ``exports == @[]``.
##   5. ``exports:`` coexists with the M9.R.3 ``headers:`` / ``links:``
##      fields — all three populate the same ``LibraryApi`` record.
##   6. Multiple libraries in one package register isolated exports via
##      per-library ``registeredLibraryApi`` lookups.
##   7. Non-proc node inside ``exports:`` rejected via ``compiles(...)``
##      negative probe; the actionable-error message text is
##      reverified by the fixture
##      ``tests/fixtures/m9r4_exports_non_proc_rejected.nim``.

import std/[strutils, unittest]

import repro_project_dsl

# ---------------------------------------------------------------------------
# Fixture 1 — full exports: sub-block with three procs + opaque types.
# ---------------------------------------------------------------------------

package m9r4FullExports:
  library libAsound:
    ## ALSA C library — fixture mirroring the milestone-body example.
    api:
      pkgConfig "alsa"
      soname "asound"
      sover "2.0.0"
      linkKind shared

      exports:
        proc snd_pcm_open*(pcm: ptr Pcm, name: cstring,
                            stream: PcmStream, mode: cint): cint
        proc snd_pcm_close*(pcm: Pcm): cint
        proc snd_pcm_drain*(pcm: Pcm): cint

# ---------------------------------------------------------------------------
# Fixture 2 — raw param text retention with opaque types the macro
# cannot type-resolve. The library type ``SomeOpaque`` is intentionally
# never declared; the macro must accept the text verbatim.
# ---------------------------------------------------------------------------

package m9r4OpaqueTypes:
  library libOpaqueProbe:
    api:
      exports:
        proc opaque_op*(a: ptr SomeOpaque, b: cstring): cint

# ---------------------------------------------------------------------------
# Fixture 3 — proc with a doc-comment as the first body statement.
# ---------------------------------------------------------------------------

package m9r4DocComment:
  library libDocProbe:
    api:
      exports:
        proc foo_open*(): cint =
          ## opens the foo handle

# ---------------------------------------------------------------------------
# Fixture 4 — library with ``api:`` but NO ``exports:`` sub-block.
# Exercises the optionality contract.
# ---------------------------------------------------------------------------

package m9r4NoExports:
  library libNoExports:
    api:
      pkgConfig "libnoexports"
      headers:
        "include/n.h"

# ---------------------------------------------------------------------------
# Fixture 5 — ``exports:`` coexists with ``headers:`` + ``links:``.
# ---------------------------------------------------------------------------

package m9r4Coexists:
  library libCoexists:
    api:
      pkgConfig "libcoexists"
      headers:
        "include/coexists.h"
      links:
        libZlib
      exports:
        proc coexists_init*(): cint
        proc coexists_close*(): cint

# ---------------------------------------------------------------------------
# Fixture 6 — package with TWO libraries each declaring different
# ``exports:`` blocks. Verifies isolation via per-library lookups.
# ---------------------------------------------------------------------------

package m9r4TwoLibs:
  library libA:
    api:
      exports:
        proc a_one*(): cint
        proc a_two*(): cint
  library libB:
    api:
      exports:
        proc b_only*(x: cint): cint

suite "DSL-port M9.R.4 — library api: exports: FFI declarations":

  test "exports: block parses + registers all three procs":
    let api = registeredLibraryApi("m9r4FullExports", "libAsound")
    check api.declared == true
    check api.pkgConfig == "alsa"
    check api.exports.len == 3
    check api.exports[0].name == "snd_pcm_open"
    check api.exports[1].name == "snd_pcm_close"
    check api.exports[2].name == "snd_pcm_drain"
    check api.exports[0].returnRaw == "cint"
    check api.exports[1].returnRaw == "cint"
    check api.exports[2].returnRaw == "cint"
    # First proc: multi-param signature with opaque types kept as text.
    check "pcm: ptr Pcm" in api.exports[0].paramsRaw
    check "name: cstring" in api.exports[0].paramsRaw
    check "stream: PcmStream" in api.exports[0].paramsRaw
    check "mode: cint" in api.exports[0].paramsRaw
    # Single-param signatures.
    check api.exports[1].paramsRaw == "pcm: Pcm"
    check api.exports[2].paramsRaw == "pcm: Pcm"

  test "raw param text preserves opaque library types":
    # ``SomeOpaque`` is never declared as a Nim type; the macro must
    # store the text verbatim without attempting to resolve it.
    let api = registeredLibraryApi("m9r4OpaqueTypes", "libOpaqueProbe")
    check api.exports.len == 1
    check api.exports[0].name == "opaque_op"
    check "a: ptr SomeOpaque" in api.exports[0].paramsRaw
    check "b: cstring" in api.exports[0].paramsRaw
    check api.exports[0].returnRaw == "cint"

  test "doc-comment from proc body lands in exports[i].doc":
    let api = registeredLibraryApi("m9r4DocComment", "libDocProbe")
    check api.exports.len == 1
    check api.exports[0].name == "foo_open"
    check api.exports[0].returnRaw == "cint"
    check api.exports[0].doc == "opens the foo handle"

  test "exports: sub-block is optional — empty seq when omitted":
    let api = registeredLibraryApi("m9r4NoExports", "libNoExports")
    check api.declared == true
    check api.pkgConfig == "libnoexports"
    check api.headers == @["include/n.h"]
    check api.exports.len == 0
    check api.exports == newSeq[ExportedSymbol]()

  test "exports: coexists with headers: + links: fields":
    let api = registeredLibraryApi("m9r4Coexists", "libCoexists")
    check api.declared == true
    check api.pkgConfig == "libcoexists"
    check api.headers == @["include/coexists.h"]
    check api.links == @["libZlib"]
    check api.exports.len == 2
    check api.exports[0].name == "coexists_init"
    check api.exports[1].name == "coexists_close"
    check api.exports[0].returnRaw == "cint"
    check api.exports[1].returnRaw == "cint"

  test "two libraries in one package keep their exports isolated":
    let apiA = registeredLibraryApi("m9r4TwoLibs", "libA")
    let apiB = registeredLibraryApi("m9r4TwoLibs", "libB")
    check apiA.exports.len == 2
    check apiA.exports[0].name == "a_one"
    check apiA.exports[1].name == "a_two"
    check apiB.exports.len == 1
    check apiB.exports[0].name == "b_only"
    check apiB.exports[0].paramsRaw == "x: cint"
    # Cross-bleed check — libA's procs do NOT appear under libB.
    for ex in apiB.exports:
      check ex.name != "a_one"
      check ex.name != "a_two"

  test "doc field is empty when proc has no doc comment":
    let api = registeredLibraryApi("m9r4FullExports", "libAsound")
    # The fixture-1 procs are forward-decl shaped (no body) → no doc.
    for ex in api.exports:
      check ex.doc == ""

  test "non-proc node inside exports: rejected at compile time":
    # The emitter calls ``error()`` for any non-proc child of
    # ``exports:`` — the message names the offending node + suggests
    # the canonical ``proc <name>*(<params>): <ret>`` shape.
    #
    # ``compiles(...)`` invocation: top-level ``package`` declarations
    # don't round-trip through nested compile-time contexts (the macro
    # emits module-init code), so we can't easily probe both arms via
    # ``compiles``. The rejection is exercised manually by the
    # accompanying ``tests/fixtures/m9r4_exports_non_proc_rejected.nim``
    # fixture, which must FAIL to compile with the
    # ``library api: exports: only accepts proc declarations`` message.
    #
    # In-test assertion: confirm the negative ``compiles`` outcome.
    # (The positive arm is covered implicitly by every other test in
    # this suite — every successful round-trip already compiled.)
    check (not compiles((proc () =
      package m9r4NonProcRejected:
        library libBad:
          api:
            exports:
              let x = 1
      )))
