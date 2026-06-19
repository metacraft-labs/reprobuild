## DSL-port M9.R.7 — engine-side platform tagging for binary-cache
## namespacing.
##
## This module lands the engine-side plumbing that honors the resolved
## ``targetTriple`` variant (see ``Configurable-System.md`` §"Solver-
## Participating Configurables") at the binary-cache key layer:
##
##   * ``buildPlatformTriple()`` returns the conventional GNU triple of
##     the engine's BUILD platform (i.e. the host this very ``repro``
##     binary is running on). Used to namespace cache entries for
##     ``nativeBuildDeps:`` — tools the build invokes from the BUILD
##     platform (Nix's ``nativeBuildInputs`` equivalent).
##   * ``resolvedTargetTriple()`` returns the resolved value of the
##     ``targetTriple`` variant (defaults to ``"native"`` when the
##     variant is undeclared or the resolver closure is nil). Used to
##     namespace cache entries for ``buildDeps:`` / ``runtimeDeps:`` —
##     libraries the produced binaries link against on the HOST
##     platform (Nix's ``buildInputs`` / ``propagatedBuildInputs``
##     equivalent).
##   * ``cachePlatformTagFor(kind, resolveTargetTriple)`` picks the
##     correct namespace tag for a dep of the given kind. On a native
##     build (``resolvedTargetTriple() == "native"``) both BUILD and
##     HOST collapse to the same tag, so existing recipes get
##     byte-identical cache keys to pre-M9.R.7.
##
## ## Scope
##
## This milestone is engine-side ONLY. It DOES NOT ship cross-
## compilation support (no ``gcc.cross`` adapter, no sysroot
## orchestration, no end-to-end cross build). It lands the cache-key
## namespacing shape so a follow-up cross-compilation campaign can
## register adapter packages without further engine surgery.
##
## The variant-resolution seam is a closure (``TargetTripleResolver``)
## wired onto ``BuildEngineConfig`` by the CLI driver layer. The engine
## itself doesn't import ``repro_dsl_stdlib`` — that would be a layering
## inversion. The CLI's resolver reads
## ``configurables.lastSolverSolution().variants.getOrDefault(
## "targetTriple", "native")`` and hands the string back.
##
## ``"native"`` is the universal sentinel for "BUILD == HOST".
## Recipes that don't declare ``targetTriple`` keep the same cache keys
## as today (the tag is ``"native"``), passive across the 84-recipe
## corpus.

type
  DepKind* = enum
    ## M9.R.7. Marks a tool-identity ref by which dep-list it came
    ## from so the engine can route the materialization cache lookup
    ## against the correct platform-tagged cache key.
    ##
    ##   * ``dkBuild`` — ``buildDeps:`` (HOST-platform libraries the
    ##     produced binaries link against). Default kind when the
    ##     legacy ``uses:`` block is used. Routed against the
    ##     ``resolvedTargetTriple()`` cache key (the variant's
    ##     resolved value).
    ##   * ``dkNative`` — ``nativeBuildDeps:`` (BUILD-platform tools
    ##     that drive the build). Routed against the
    ##     ``buildPlatformTriple()`` cache key (the host the build is
    ##     running on).
    ##   * ``dkRuntime`` — ``runtimeDeps:`` (HOST-platform runtime
    ##     dependencies propagated to consumers). Routed against the
    ##     ``resolvedTargetTriple()`` cache key, like ``dkBuild``.
    dkBuild = 0'u8
    dkNative = 1'u8
    dkRuntime = 2'u8

  TargetTripleResolver* = proc(): string {.gcsafe, closure.}
    ## M9.R.7. The CLI driver wires a closure that reads the resolved
    ## ``targetTriple`` variant value (or ``"native"`` when the variant
    ## is undeclared) and hands the string back to the engine on
    ## demand. ``nil`` is the explicit "no variant resolver configured"
    ## signal — the engine then treats the build as native (returns
    ## ``"native"``) and the namespacing collapses to the legacy
    ## single-key behaviour.

const
  NativeTriple* = "native"
    ## Universal sentinel for "BUILD == HOST". When
    ## ``resolvedTargetTriple()`` returns this value, the engine
    ## collapses both BUILD-platform and HOST-platform cache keys onto
    ## the same tag so existing recipes get byte-identical cache keys
    ## to pre-M9.R.7.

proc buildPlatformTriple*(): string =
  ## Return the conventional GNU triple for the BUILD platform — i.e.
  ## the host this very ``repro`` binary is running on. The triple is
  ## namespacing metadata only; it does NOT participate in
  ## reproducibility invariants.
  ##
  ## Per-OS table (v1 — refined as cross-build adapters land):
  ##
  ##   * Windows MSVC:  ``x86_64-pc-windows-msvc`` (or aarch64 variant)
  ##   * Linux glibc:   ``x86_64-unknown-linux-gnu`` (or aarch64)
  ##   * macOS:         ``x86_64-apple-darwin`` (or aarch64-apple-darwin)
  ##
  ## On unknown OS / CPU combinations the proc falls back to a
  ## descriptive ``unknown-unknown-unknown`` form so the cache tag is
  ## still a deterministic string (rather than empty), which keeps the
  ## key derivation robust on uncommon hosts. A real cross-build
  ## campaign would surface the unknown-host case via a richer
  ## diagnostic; for M9.R.7 the milestone is passive on the recognised
  ## hosts and merely traceable on the rest.
  const cpu =
    when defined(amd64) or defined(x86_64): "x86_64"
    elif defined(arm64) or defined(aarch64): "aarch64"
    elif defined(i386): "i686"
    elif defined(riscv64): "riscv64"
    else: "unknown"
  when defined(windows):
    cpu & "-pc-windows-msvc"
  elif defined(macosx) or defined(macos):
    cpu & "-apple-darwin"
  elif defined(linux):
    when defined(musl):
      cpu & "-unknown-linux-musl"
    else:
      cpu & "-unknown-linux-gnu"
  elif defined(freebsd):
    cpu & "-unknown-freebsd"
  elif defined(netbsd):
    cpu & "-unknown-netbsd"
  elif defined(openbsd):
    cpu & "-unknown-openbsd"
  else:
    cpu & "-unknown-unknown"

proc resolvedTargetTriple*(resolver: TargetTripleResolver): string =
  ## Return the resolved ``targetTriple`` variant value. When
  ## ``resolver`` is ``nil`` (no variant resolver configured) OR the
  ## resolver hands back an empty string (variant undeclared /
  ## unresolved), return ``"native"``. NEVER raises — the engine must
  ## be able to derive a cache key even when no variant state is
  ## present (this is the common case across the 84-recipe corpus).
  ##
  ## The closure is invoked once per call site; cheap reads on the
  ## hot path (one ``Table[string, string].getOrDefault`` inside the
  ## CLI's closure body) but cached at the call site of
  ## ``cachePlatformTagFor`` so the resolver isn't walked per ref.
  if resolver == nil:
    return NativeTriple
  let raw =
    try: resolver()
    except CatchableError: ""
  if raw.len == 0:
    return NativeTriple
  raw

proc cachePlatformTagFor*(kind: DepKind;
                          resolver: TargetTripleResolver = nil): string =
  ## Pick the correct cache-platform namespace tag for a dep of the
  ## given kind. ``nativeBuildDeps:`` route against the BUILD
  ## platform's triple (the host running the build); ``buildDeps:`` and
  ## ``runtimeDeps:`` route against the HOST platform's triple (the
  ## resolved ``targetTriple`` variant value, or ``"native"`` when
  ## undeclared).
  ##
  ## On a native build (``resolvedTargetTriple(resolver) ==
  ## "native"``) BOTH routes collapse to the literal string
  ## ``"native"``, which keeps cache keys byte-identical to
  ## pre-M9.R.7 across the 84-recipe corpus.
  ##
  ## Cross-build case (e.g. ``targetTriple = "aarch64-unknown-linux-
  ## gnu"`` while running on x86_64 Linux):
  ##   * ``dkNative`` → ``"x86_64-unknown-linux-gnu"`` (BUILD)
  ##   * ``dkBuild``  → ``"aarch64-unknown-linux-gnu"`` (HOST)
  ##   * ``dkRuntime``→ ``"aarch64-unknown-linux-gnu"`` (HOST)
  let host = resolvedTargetTriple(resolver)
  if host == NativeTriple:
    # Native build — collapse both routes onto the same sentinel so
    # the cache keys stay byte-identical to pre-M9.R.7.
    return NativeTriple
  case kind
  of dkNative:
    buildPlatformTriple()
  of dkBuild, dkRuntime:
    host

const
  CachePlatformTagOptionKey* = "__cachePlatformTag__"
    ## Synthetic ``selectedOptions`` key used to fold the cache-
    ## platform tag into ``CacheEntryIdentity`` derivation. Distinct
    ## from any user-facing option name (the ``__...__`` reserved-
    ## namespace convention) so a recipe accidentally naming an
    ## option ``cachePlatformTag`` doesn't collide with the engine's
    ## namespacing. The tag flows into the canonical key bytes via
    ## the existing ``selectedOptions`` channel — no codec change.
