## Spec-Implementation M3 — stdlib-level ``currentBuildContext()``.
##
## Per Reprobuild-Standard-Library §"The active build context" recipes
## consume the four cross-cutting interfaces (``TestRunner``,
## ``Toolchain``, ``CrossTarget``, ``FeatureSet``) through a single
## ``currentBuildContext()`` handle. The underlying state is the
## ``PackageBuildState`` ref the ``package`` macro pushes onto the
## thread-local active-build stack (``runtime_core.nim`` §"M3 —
## cross-cutting interface slots"). The four interface slots there
## are typed as ``RootRef`` so the lower-level ``repro_project_dsl``
## library doesn't have to import the stdlib's interface types; the
## stdlib accessor in *this* module does the downcast to the proper
## interface type.
##
## The accessor lazily installs stdlib defaults when a slot is nil so
## a recipe that never opts into a variant still gets a working
## context. The defaults pick:
##
##   * ``testRunner`` → ``defaultTestRunner()`` (direct-binary runner)
##   * ``toolchain`` → ``gccToolchain()`` (matches the M3 default
##     ``compiler = "gcc"`` variant resolution)
##   * ``crossTarget`` → ``nativeCrossTarget()``
##   * ``featureSet`` → ``solverFeatureSet()``
##
## The variant solver from M2d can influence slot population: when
## the ``compiler`` variant resolves to ``"clang"`` the accessor
## prefers ``clangToolchain()``; when ``targetTriple`` resolves to a
## non-``"native"`` triple the accessor prefers
## ``crossTargetFromTriple(triple)``. Adapter packages that supply
## their own ``Toolchain`` / ``CrossTarget`` implementations bypass
## the default lookup by writing to the slot directly before the
## first recipe call (the M4 ct-test adapter follows this pattern).

import std/strutils

import repro_lock_files
import repro_project_dsl

import ./toolchain_policy
import ./interfaces/test_runner
import ./interfaces/toolchain
import ./interfaces/cross_target
import ./interfaces/feature_set
import ./adapters/gcc_toolchain
import ./adapters/clang_toolchain
import ./adapters/native_cross_target
import ./adapters/cross_aarch64_linux_gnu
import ./adapters/solver_feature_set
import ./configurables/variants

export test_runner
export toolchain
export cross_target
export feature_set
export repro_lock_files
export toolchain_policy

type
  BuildContext* = ref object
    ## The stdlib-level handle ``currentBuildContext()`` returns. Wraps
    ## the underlying ``PackageBuildState`` and exposes the four
    ## cross-cutting interface slots as typed fields. The handle is a
    ## thin facade — its identity is the underlying state — so two
    ## calls to ``currentBuildContext()`` inside the same ``build:``
    ## block return logically-equivalent handles.
    state*: PackageBuildState
      ## The raw state ref the ``package`` macro pushed.

proc resolveToolchain(): Toolchain =
  ## Pick the toolchain adapter that matches the current variant
  ## state. M3 reads the ``compiler`` variant; non-default values map
  ## to the matching adapter.
  ##
  ## Spec-Implementation M5: the ``targetTriple`` variant outranks the
  ## ``compiler`` variant for cross-compilation triples. A
  ## ``targetTriple = "aarch64-linux-gnu"`` resolution swaps the
  ## active toolchain to ``crossAarch64LinuxGnuToolchain`` so a
  ## recipe's ``currentBuildContext().toolchain.compile(...)`` reaches
  ## the cross gcc directly. When the ``targetTriple`` resolves to
  ## ``native`` (or is absent) the ``compiler`` variant drives the
  ## host-toolchain selection as before.
  ##
  ## Named-Lock-Files NLF-M7 (§4.4): the variant lookup itself moved to
  ## ``toolchain_policy.activeSolvedVariants`` — the ONE place a solved graph
  ## is read for a toolchain decision, and therefore the one place the
  ## lock-file slot has to be honoured. This proc keeps the adapter mapping
  ## and nothing else.
  let selected = activeSolvedVariants()
  if isCrossTriple(selected.targetTriple):
    if isCrossAarch64Triple(selected.targetTriple):
      return crossAarch64LinuxGnuToolchain()
    # Fall through to the host-compiler branch when no specialised
    # cross-toolchain adapter is registered for the triple. The
    # crossTarget slot still moves to the matching cross adapter via
    # ``resolveCrossTarget`` below; the toolchain slot's ``compile``
    # proc then has to thread the right ``--target=`` flag through the
    # build context's ``cFlags``. That is the standard "use a host
    # clang with --target=" pattern.
  case selected.compiler.toLowerAscii()
  of "clang": clangToolchain()
  else: gccToolchain()

proc resolveCrossTarget(): CrossTarget =
  ## Pick the cross-target adapter that matches the current variant
  ## state. Reads the ``targetTriple`` variant through the same single
  ## resolver ``resolveToolchain`` uses; non-``"native"`` values build a
  ## ``crossTargetFromTriple`` adapter.
  ##
  ## Spec-Implementation M5: when the resolved triple matches the
  ## ``cross-aarch64-linux-gnu`` adapter the selector returns the
  ## populated adapter; other triples fall through to the M3 generic
  ## ``crossTargetFromTriple`` stub so the existing cross-target
  ## test surface keeps working.
  let selected = activeSolvedVariants()
  if isCrossTriple(selected.targetTriple):
    if isCrossAarch64Triple(selected.targetTriple):
      return crossAarch64LinuxGnuTarget()
    return crossTargetFromTriple(selected.targetTriple)
  nativeCrossTarget()

proc toolchainSlotIsStale(state: PackageBuildState): bool =
  ## Named-Lock-Files NLF-M7 (§4.4). A lazily-filled slot is stale when the
  ## designation has moved since it was filled — which is exactly what
  ## `withLockFile` does between two regions of one build body. An
  ## adapter-installed slot is never stale: writing the slot directly is the
  ## documented bypass and outranks the variant-driven default.
  if state.toolchainSlot == nil: return true
  if state.toolchainSlotLockFile == ExplicitSlotDesignation: return false
  state.toolchainSlotLockFile != activeLockFileName()

proc crossTargetSlotIsStale(state: PackageBuildState): bool =
  if state.crossTargetSlot == nil: return true
  if state.crossTargetSlotLockFile == ExplicitSlotDesignation: return false
  state.crossTargetSlotLockFile != activeLockFileName()

proc fillToolchainSlot(state: PackageBuildState) =
  state.toolchainSlot = resolveToolchain()
  state.toolchainSlotLockFile = activeLockFileName()

proc fillCrossTargetSlot(state: PackageBuildState) =
  state.crossTargetSlot = resolveCrossTarget()
  state.crossTargetSlotLockFile = activeLockFileName()

proc ensureSlots(state: PackageBuildState) =
  ## Lazily install stdlib defaults into any nil slot. Called from
  ## ``currentBuildContext()`` so a recipe sees fully-populated slots
  ## at first access. Adapter packages that pre-write the slot win
  ## because the lazy installer checks the explicit marker first.
  if state.testRunnerSlot == nil:
    state.testRunnerSlot = defaultTestRunner()
  if toolchainSlotIsStale(state):
    fillToolchainSlot(state)
  if crossTargetSlotIsStale(state):
    fillCrossTargetSlot(state)
  if state.featureSetSlot == nil:
    state.featureSetSlot = solverFeatureSet()

proc currentBuildContext*(): BuildContext =
  ## Return the stdlib-level handle for the active build context.
  ## Raises ``ValueError`` (via ``currentBuildState``) when no
  ## ``build:`` block is currently active. Recipes use
  ## ``currentBuildContext().toolchain.compile(...)`` and similar.
  let state = currentBuildState()
  ensureSlots(state)
  BuildContext(state: state)

proc testRunner*(ctx: BuildContext): TestRunner =
  ## Field accessor — exposed as a proc so the runtime can lazily
  ## install the default if the slot is nil and so the cast from
  ## ``RootRef`` to ``TestRunner`` is centralised. Recipes write
  ## ``currentBuildContext().testRunner`` and read this proc.
  if ctx.state.testRunnerSlot == nil:
    ctx.state.testRunnerSlot = defaultTestRunner()
  cast[TestRunner](ctx.state.testRunnerSlot)

proc toolchain*(ctx: BuildContext): Toolchain =
  if toolchainSlotIsStale(ctx.state):
    fillToolchainSlot(ctx.state)
  cast[Toolchain](ctx.state.toolchainSlot)

proc crossTarget*(ctx: BuildContext): CrossTarget =
  if crossTargetSlotIsStale(ctx.state):
    fillCrossTargetSlot(ctx.state)
  cast[CrossTarget](ctx.state.crossTargetSlot)

proc featureSet*(ctx: BuildContext): FeatureSet =
  if ctx.state.featureSetSlot == nil:
    ctx.state.featureSetSlot = solverFeatureSet()
  cast[FeatureSet](ctx.state.featureSetSlot)

# Convenience setters — adapter packages call these to install their
# implementation into the active build context before the first
# recipe call. The variant-conditioned ``uses:`` mechanism wires the
# call inside the adapter package's load-time code.

proc setTestRunner*(ctx: BuildContext; runner: TestRunner) =
  ## Override the test-runner slot. Validates the adapter so a
  ## malformed implementation trips at install time rather than at
  ## the first recipe call.
  validate(runner)
  ctx.state.testRunnerSlot = runner

proc setToolchain*(ctx: BuildContext; tc: Toolchain) =
  validate(tc)
  ctx.state.toolchainSlot = tc
  ctx.state.toolchainSlotLockFile = ExplicitSlotDesignation

proc setCrossTarget*(ctx: BuildContext; ct: CrossTarget) =
  validate(ct)
  ctx.state.crossTargetSlot = ct
  ctx.state.crossTargetSlotLockFile = ExplicitSlotDesignation

proc setFeatureSet*(ctx: BuildContext; fs: FeatureSet) =
  validate(fs)
  ctx.state.featureSetSlot = fs

# ---------------------------------------------------------------------------
# Named-Lock-Files NLF-M7 (§4.4) — the fifth slot
# ---------------------------------------------------------------------------

type
  LockFileDesignation* = ref object of RootObj
    ## What sits in ``PackageBuildState.lockFileSlot``. A ref object rather
    ## than a bare string because the slot is a ``RootRef``, for the same
    ## layering reason the other four are.
    name*: string

proc lockFileName*(ctx: BuildContext): string =
  ## The lock file governing the active build region, as a NAME.
  ##
  ## §4.4 spells this accessor ``lockFile*(ctx)``. It is ``lockFileName``
  ## here for one measured reason: ``lockFile`` is also the DECLARATION
  ## keyword (§4.2), and a one-typed-parameter ``lockFile(ctx: BuildContext)``
  ## in the same scope as the declaration macro makes ``lockFile hostTools``
  ## fail overload resolution — Nim types the argument against the proc
  ## candidate and reports `undeclared identifier: 'hostTools'`, which is a
  ## confusing way to be told two names collide. The normative spelling is
  ## the DECLARATION's, so the accessor moved.
  ##
  ## The fifth accessor, mirroring ``toolchain`` / ``crossTarget``: it fills
  ## its slot lazily when nothing has designated one, and the value it fills
  ## with is ``default`` — §4.3's last rung and §5.3's "there is no third
  ## case".
  ##
  ## It reads the designation STACK first. §4.4's block form and §4.5's
  ## per-call argument both scope a region NARROWER than the frame that owns
  ## the slot, so a reader that consulted only the slot would report the
  ## artifact's designation inside a ``withLockFile hostTools:`` body — which
  ## is the §4.9 failure shape at the reporting layer.
  let active = activeLockFileName()
  if active.len > 0:
    return active
  if ctx.state.lockFileSlot == nil:
    ctx.state.lockFileSlot = LockFileDesignation(name: DefaultLockFileName)
  cast[LockFileDesignation](ctx.state.lockFileSlot).name

proc setLockFile*(ctx: BuildContext; name: string) =
  ## Designate the active frame's lock file (§4.3's artifact-level and
  ## package-level rungs). Writes the slot AND the ambient designation, so
  ## the mirror described on ``lockFileSlot`` cannot drift.
  ##
  ## An undeclared name raises rather than resolving to ``default``: §4.9's
  ## requirement is that such a name "MUST NOT silently resolve to `default`",
  ## and while the primary enforcement is the compile error the macro emits,
  ## a runtime setter that quietly accepted an unknown name would be a second
  ## door into exactly the state §4.9 forbids.
  if not isDeclaredLockFile(name, ctx.state.packageName):
    raise newException(LockFileError,
      undeclaredLockFileDiagnostic(name, "", 0, 0, ctx.state.packageName))
  ctx.state.lockFileSlot = LockFileDesignation(name: name)
  if activeLockFileScopes().len == 0 or
      activeLockFileScopes()[^1].kind != lskArtifact:
    pushLockFileScope(lskArtifact, name)
  else:
    popLockFileScope()
    pushLockFileScope(lskArtifact, name)

template withLockFile*(name: untyped; body: untyped) {.dirty.} =
  ## §4.4 — designate a REGION of one ``build:`` body.
  ##
  ## ```nim
  ## build:
  ##   withLockFile hostTools:
  ##     discard nim.c(source = "tools/tablegen.nim", binary = "build/tablegen")
  ##
  ##   let tables = tablegen.emit("gen/tables.c")
  ## ```
  ##
  ## Two properties are load-bearing and §4.4 states both in terms, having
  ## measured them off ``evalConfig`` and ``stateGroup``:
  ##
  ##   * ``{.dirty.}`` — ``evalConfig`` is dirty "deliberately, so identifiers
  ##     introduced by inner macros flow back into the surrounding scope
  ##     without hygienic renaming";
  ##   * an ``untyped`` block argument — "block arguments in this DSL are
  ##     declared ``untyped`` rather than ``string`` so the command-call block
  ##     form parses at all (the ``stateGroup`` template says so in terms)".
  ##
  ## "``withLockFile`` should follow both, or its body will not be able to
  ## introduce ``let`` bindings the rest of the ``build:`` block can see —
  ## which the examples above rely on."
  ##
  ## The push/pop is in a ``try``/``finally`` for the same reason
  ## ``evalConfig``'s is: a recipe that raises inside the body must not leave
  ## the rest of the build body designated to a lock file nobody wrote.
  ##
  ## No ``bind``: a ``{.dirty.}`` template resolves its symbols at the
  ## INSTANTIATION site, which is the property being asked for, and a `bind`
  ## would be the one thing that partly undoes it. ``pushLockFileScope`` and
  ## ``popLockFileScope`` reach recipes through the stdlib prelude, which
  ## re-exports ``repro_lock_files`` for exactly this.
  pushLockFileScope(lskBlock, name)
  try:
    body
  finally:
    popLockFileScope()

template withLockFileArgument*(name: string; body: untyped) =
  ## §4.5 — the per-call ``lockFile = <name>`` argument, as the typed-tool
  ## wrappers implement it.
  ##
  ## §4.5 keeps the per-call form as an escape hatch and demotes it
  ## deliberately: with propagation settled it is "usually redundant", and "a
  ## ``lockFile =`` on every call is exactly the kind of repeated annotation
  ## that gets copy-pasted wrong — one call in twenty carrying the wrong lock
  ## file is a silent misbuild of the §4.9 class, not a compile error, because
  ## every individual call is well-formed."
  ##
  ## An empty ``name`` means the argument was not supplied, and the call
  ## inherits — so a wrapper can thread ``lockFile = ""`` unconditionally
  ## without a branch at every call site.
  bind pushLockFileScope, popLockFileScope, lskCall
  let designated = name
  if designated.len > 0:
    pushLockFileScope(lskCall, designated)
  try:
    body
  finally:
    if designated.len > 0:
      popLockFileScope()
