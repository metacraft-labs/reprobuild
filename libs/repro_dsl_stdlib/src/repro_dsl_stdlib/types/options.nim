## DSL-port M9.R.2b — typed per-operation option records.
##
## Each Layer-2 mid-level operation (``compile``, ``link``,
## ``archive``, ``strip``) takes a typed ``*Options`` record. Per-field
## semantics:
##
##   * ``CompileOptions`` — describes one source-file compile step. The
##     dispatch routine reads ``inputs`` for ``-I`` / ``-D`` header
##     contributions from each consumed library's ``LibraryApi``.
##   * ``LinkOptions``    — describes one link step. ``objects`` carries
##     the compiled artifacts feeding the linker; ``deps`` carries the
##     transitively-closed link inputs (already-built libraries).
##   * ``ArchiveOptions`` — describes ``ar`` invocation (static archive
##     packing).
##   * ``StripOptions``   — describes ``strip`` invocation (debug-symbol
##     removal).
##
## The dispatch routines (under ``operations/``) read these records and
## branch to the matching per-compiler implementation
## (``packages/gcc.nim`` / ``packages/clang.nim``) which translates the
## record contents into the right argv shape.
##
## See [[file:Reprobuild-Standard-Library.md][Reprobuild-Standard-Library]]
## §"Typed-value layer" for the canonical field-by-field contract.

import repro_project_dsl
import ./library

type
  LinkOutputKind* = enum
    ## Link-output discriminator consumed by ``LinkOptions.kind`` and
    ## the per-compiler ``<x>Link`` implementations. ``lokExecutable``
    ## produces an executable (``c_executable`` constructor);
    ## ``lokShared`` / ``lokStatic`` produce shared / static libraries
    ## (``c_library`` constructor's two flavours). The ``lok`` prefix
    ## disambiguates from ``repro_project_dsl``'s ``LibraryKind``
    ## (``lkStatic`` / ``lkShared`` / ``lkBoth`` / ``lkHeaderOnly``).
    lokExecutable
    lokShared
    lokStatic

  CompileOptions* = object
    ## One source-file compile step. The dispatch routine
    ## (``operations/compile.nim``) reads the active
    ## ``Configurable[string]`` named ``compiler`` and routes to
    ## ``gccCompile`` / ``clangCompile`` / ``msvcCompile``.
    source*: string
      ## Path to the source file (``.c`` / ``.cpp`` / ``.S``).
    target*: string
      ## Path to the output object file (``-o``).
    inputs*: seq[LibraryApi]
      ## Library interfaces this compile reads — each contributes its
      ## ``headers`` (``-I``) and ``defines`` (``-D``) to the
      ## compiler's argv. Empty when the source has no library
      ## dependencies.
    defines*: seq[string]
      ## Extra ``-D`` macros (``"NAME"`` or ``"NAME=value"``) the
      ## constructor or recipe author wants to add on top of the
      ## ``inputs`` contributions.
    standard*: string
      ## Language standard, e.g. ``"c11"`` / ``"c++17"``. Translated
      ## to ``-std=c11`` / ``-std=c++17`` on gcc/clang.
    extra*: seq[string]
      ## Pass-through flags appended to the compiler argv verbatim —
      ## an escape hatch for one-off knobs the dispatch routine
      ## doesn't model. Empty for the canonical compile shape.

  LinkOptions* = object
    ## One link step. Routes through the per-compiler ``<x>Link``
    ## implementation.
    objects*: seq[BuildActionDef]
      ## Compiled object edges (the ``BuildActionDef`` produced by
      ## ``compile(...)``) feeding the link.
    deps*: seq[Library]
      ## Transitively-closed library dependencies. Each contributes
      ## its ``-l`` / ``-L`` to the link argv.
    kind*: LinkOutputKind
      ## Output shape (executable / shared lib / static archive).
    target*: string
      ## Output path (``-o``).
    soname*: string
      ## When non-empty, emit ``-Wl,-soname=<value>``. Auto-lifted
      ## from the surrounding ``library <name>: api: soname "..."``
      ## declaration; recipes calling Layer 2 directly may override
      ## by populating this field explicitly.
    extra*: seq[string]
      ## Pass-through linker flags.

  ArchiveOptions* = object
    ## One ``ar`` invocation — bundle one or more compiled objects
    ## into a static archive. Routes through ``<x>Archive``.
    objects*: seq[BuildActionDef]
      ## Object files to pack.
    target*: string
      ## Output ``.a`` path.
    modifiers*: string
      ## ``ar`` modifier string (default ``"rcs"``). Carried verbatim
      ## into the ``ar`` argv.

  StripOptions* = object
    ## One ``strip`` invocation — remove debug symbols from a built
    ## binary or library. Routes through ``<x>Strip``.
    input*: BuildActionDef
      ## The binary / library edge feeding ``strip``.
    target*: string
      ## Output path. Empty means strip in-place (the per-compiler
      ## implementation drops the ``-o`` flag).
    keepSymbols*: seq[string]
      ## Symbols to retain (``-K <name>``). Empty for the canonical
      ## "strip everything" shape.
