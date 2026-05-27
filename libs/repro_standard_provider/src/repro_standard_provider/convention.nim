## ``LanguageConvention`` + ``ConventionRegistry`` — the dispatch surface
## the standard provider walks on every ``prkGraphInvocation``.
##
## Design decisions (M1):
##
## * Convention probes receive the *project root* plus the in-flight
##   ``ProviderGraphRequest`` — they do NOT receive a parsed
##   ``PackageDef``. The Tier 2c trycompile provider proved this pattern:
##   the engine hands the binary only the inputs it strictly needs and
##   the convention does its own filesystem probing. Re-reading
##   ``reprobuild.nim`` for the diagnostic-only ``uses:`` hint lives in
##   ``project_intro.nim`` and is a heuristic line-scan, not a DSL
##   evaluator — that's M2's concern.
##
## * The registry is a plain ``seq`` walked in registration order. First
##   ``recognize`` returning ``true`` wins. Language plugin libraries
##   register themselves into the module-level
##   ``defaultConventionRegistry`` from their own startup code — either
##   by calling ``addDefaultConvention`` directly, or by depending on a
##   ``conventions/<name>.nim`` module whose top-level code performs the
##   registration. The provider binary triggers all of this by importing
##   the language libraries it ships with.
##
## * ``firstMatchingConvention`` returns ``Option[LanguageConvention]``
##   rather than ``seq[LanguageConvention]`` because the milestone spec
##   is explicit that the first matching convention wins — there is no
##   merge step. Conventions that need to chain to another path do so
##   inside their own ``emitFragment``.

import std/[options]

import repro_provider_runtime

type
  RecognizeProc* = proc(projectRoot: string;
                        request: ProviderGraphRequest): bool {.closure, gcsafe.}
    ## Returns ``true`` when the convention claims this project.
    ## Implementations probe the project filesystem (look for
    ## ``Cargo.toml``, ``go.mod``, ``<name>.nimble``, ...) and inspect
    ## ``request.arguments``. They must be cheap — the dispatch loop
    ## calls them in registration order until one returns ``true``.

  EmitFragmentProc* = proc(projectRoot: string;
                           request: ProviderGraphRequest): GraphFragment {.
                             closure, gcsafe.}
    ## Produces the ``GraphFragment`` the engine consumes for this
    ## project. The convention owns the digest computation — callers
    ## treat the returned fragment as opaque and forward it on the wire.

  CrudeFallbackProc* = proc(projectRoot: string;
                            request: ProviderGraphRequest):
                              GraphFragment {.closure, gcsafe.}
    ## Optional Mode B fallback. Conventions whose ``emitFragment`` can
    ## detect a fine-grained-incompatible shape (e.g. Rust's ``build.rs``
    ## or Cargo workspaces) set this to a closure that delegates to the
    ## native build tool via ``crude.emitCrudeFragment``. The convention's
    ## own ``emitFragment`` is responsible for routing to the fallback;
    ## the dispatch loop does NOT consult ``crudeFallback`` directly. The
    ## proc is optional — leaving it ``nil`` means the convention does
    ## not opt into Mode B and any non-Mode-A project the convention
    ## ``recognize``s must be handled inside ``emitFragment``.
    ##
    ## See ``crude.emitCrudeFragment`` for the canonical helper.

  LanguageConvention* = object
    ## Snapshot of a single per-language convention. Conventions are
    ## value objects so the registry can hold them by value and tests
    ## can construct fakes without going through any global plumbing.
    name*: string
      ## Convention identifier (``"nim"``, ``"rust"``, ``"go"``, ...).
      ## Used purely for diagnostics; the dispatch loop matches by
      ## ``recognize``, not by name.
    recognize*: RecognizeProc
    emitFragment*: EmitFragmentProc
    crudeFallback*: CrudeFallbackProc
      ## Optional — may be ``nil``. See ``CrudeFallbackProc``.

  ConventionRegistry* = object
    ## Append-only registry. ``conventions`` is exported as ``seq`` (not
    ## ``Table``) because order matters — ``firstMatchingConvention``
    ## scans linearly and the first match wins.
    conventions*: seq[LanguageConvention]

proc registerConvention*(reg: var ConventionRegistry;
                         convention: LanguageConvention) =
  ## Append a convention to ``reg``. Duplicates are *not* rejected —
  ## tests deliberately register multiple fakes with the same name, and
  ## production plugins are responsible for not double-registering.
  reg.conventions.add(convention)

proc firstMatchingConvention*(reg: ConventionRegistry;
                              projectRoot: string;
                              request: ProviderGraphRequest):
                                Option[LanguageConvention] =
  ## Linear-scan ``reg.conventions`` in registration order; return the
  ## first whose ``recognize`` returns ``true``. ``none`` if no
  ## convention matches — callers decide whether that's a fatal error
  ## (the standard-provider binary's policy) or a fall-through (a hosted
  ## dispatch test).
  for convention in reg.conventions:
    if convention.recognize == nil:
      continue
    if convention.recognize(projectRoot, request):
      return some(convention)
  none(LanguageConvention)

var defaultConventionRegistry*: ConventionRegistry
  ## Module-level registry the standard provider consults at startup.
  ## Per-language plugin libraries register themselves here from their
  ## own module-level code (or by calling ``addDefaultConvention``).
  ## Tests that want isolation should build their own ``ConventionRegistry``
  ## locally instead of touching this one.

proc addDefaultConvention*(convention: LanguageConvention) =
  ## Convenience over ``registerConvention(defaultConventionRegistry, c)``.
  ## Language-plugin libraries call this from their startup code so the
  ## provider binary picks them up purely via ``import``.
  registerConvention(defaultConventionRegistry, convention)
