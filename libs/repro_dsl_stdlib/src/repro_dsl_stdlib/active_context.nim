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

import std/[strutils, tables]

import repro_project_dsl
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
  ## state. M3 reads the ``compiler`` variant via the M2d solver
  ## solution; non-default values map to the matching adapter.
  ##
  ## Spec-Implementation M5: the ``targetTriple`` variant outranks the
  ## ``compiler`` variant for cross-compilation triples. A
  ## ``targetTriple = "aarch64-linux-gnu"`` resolution swaps the
  ## active toolchain to ``crossAarch64LinuxGnuToolchain`` so a
  ## recipe's ``currentBuildContext().toolchain.compile(...)`` reaches
  ## the cross gcc directly. When the ``targetTriple`` resolves to
  ## ``native`` (or is absent) the ``compiler`` variant drives the
  ## host-toolchain selection as before.
  if hasSolverSolution():
    let sol = lastSolverSolution()
    if "targetTriple" in sol.variants:
      let triple = sol.variants["targetTriple"]
      if triple.len > 0 and triple.toLowerAscii() != "native":
        if isCrossAarch64Triple(triple):
          return crossAarch64LinuxGnuToolchain()
        # Fall through to the host-compiler branch when no
        # specialised cross-toolchain adapter is registered for the
        # triple. The crossTarget slot still moves to the matching
        # cross adapter via ``resolveCrossTarget`` below; the
        # toolchain slot's ``compile`` proc then has to thread the
        # right ``--target=`` flag through the build context's
        # ``cFlags``. That is the standard "use a host clang with
        # --target=" pattern.
    if "compiler" in sol.variants:
      case sol.variants["compiler"].toLowerAscii()
      of "clang": return clangToolchain()
      else: discard
  gccToolchain()

proc resolveCrossTarget(): CrossTarget =
  ## Pick the cross-target adapter that matches the current variant
  ## state. Reads the ``targetTriple`` variant via the M2d solver
  ## solution; non-``"native"`` values build a
  ## ``crossTargetFromTriple`` adapter.
  ##
  ## Spec-Implementation M5: when the resolved triple matches the
  ## ``cross-aarch64-linux-gnu`` adapter the selector returns the
  ## populated adapter; other triples fall through to the M3 generic
  ## ``crossTargetFromTriple`` stub so the existing cross-target
  ## test surface keeps working.
  if hasSolverSolution():
    let sol = lastSolverSolution()
    if "targetTriple" in sol.variants:
      let triple = sol.variants["targetTriple"]
      if triple.len > 0 and triple.toLowerAscii() != "native":
        if isCrossAarch64Triple(triple):
          return crossAarch64LinuxGnuTarget()
        return crossTargetFromTriple(triple)
  nativeCrossTarget()

proc ensureSlots(state: PackageBuildState) =
  ## Lazily install stdlib defaults into any nil slot. Called from
  ## ``currentBuildContext()`` so a recipe sees fully-populated slots
  ## at first access. Adapter packages that pre-write the slot win
  ## because the lazy installer checks for nil first.
  if state.testRunnerSlot == nil:
    state.testRunnerSlot = defaultTestRunner()
  if state.toolchainSlot == nil:
    state.toolchainSlot = resolveToolchain()
  if state.crossTargetSlot == nil:
    state.crossTargetSlot = resolveCrossTarget()
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
  if ctx.state.toolchainSlot == nil:
    ctx.state.toolchainSlot = resolveToolchain()
  cast[Toolchain](ctx.state.toolchainSlot)

proc crossTarget*(ctx: BuildContext): CrossTarget =
  if ctx.state.crossTargetSlot == nil:
    ctx.state.crossTargetSlot = resolveCrossTarget()
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

proc setCrossTarget*(ctx: BuildContext; ct: CrossTarget) =
  validate(ct)
  ctx.state.crossTargetSlot = ct

proc setFeatureSet*(ctx: BuildContext; fs: FeatureSet) =
  validate(fs)
  ctx.state.featureSetSlot = fs
