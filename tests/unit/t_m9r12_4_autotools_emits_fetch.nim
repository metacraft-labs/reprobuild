## DSL-port M9.R.12.4 — ``autotools_package`` auto-emits a fetch
## action when the active package declared a ``fetch:`` block.
##
## ## Context
##
## After M9.R.12.1 (configure-via-inlineExecCall) + M9.R.12.2
## (profile-lookup fallback by packageName) + M9.R.12.3 (runquotad
## named-pool budgets) the wayland from-source smoke peeled to the
## next gap: ``./src/configure: No such file or directory``. The
## binutils sub-build was actually executing the configure action but
## the source tree wasn't there because no fetch action ran first.
##
## Root cause: recipes with an explicit ``build:`` block route through
## the per-project provider; the convention layer's ``emitFragment``
## (which owns fetch-action emission for the from-source-* family) is
## NOT called for them. The recipe's ``build:`` body therefore had to
## produce its own fetch action, but the constructor API
## (``autotools_package`` / ``meson_package`` / ``cmake_package``)
## didn't expose one — and recipe authors had no documented hook to
## include a fetch step. Result: every from-source autotools recipe
## with a ``fetch:`` block (binutils, expat, autoconf, ...) tried to
## run ``./src/configure`` against a non-existent source tree.
##
## Fix: ``autotools_package`` reads ``registeredFetchSpec(
## currentOwningPackage())`` and, when the spec carries a non-empty
## URL + hashHex AND the active provider context is available, emits a
## fetch action (sh + curl + sha256sum + tar) and threads the action's
## stamp output through the configure action's ``deps`` + ``inputs``
## so the engine sequences them correctly.
##
## ## What this test pins
##
## The auto-emission gate fires only inside the provider mode (the
## ``currentProviderProjectRoot()`` accessor returns a non-empty path
## only when ``reproProviderMode`` is defined and the dispatcher seeded
## the project root). In the non-provider unit-test mode the helper
## bails out and the configure action's deps stay empty — by design,
## because there's no project root to write scratch files to.
##
## STRUCTURAL arm (unit-test mode):
##
##   1. ``autotools_package`` STILL produces a configure action even
##      when ``registeredFetchSpec`` returns a populated spec but the
##      provider context is unavailable. The configure action's id is
##      stable (driven by ``defaultToolActionId``).
##   2. ``autotools_package`` does NOT emit a fetch action in unit-test
##      mode — the helper's ``projectRoot.len == 0`` guard fires and
##      ``BuildActionDef.deps`` stays empty. This protects unit tests
##      from accidentally writing scratch files into the test cwd.
##   3. The ``currentProviderProjectRoot()`` accessor is exported and
##      returns the empty string in non-provider mode (so callers can
##      branch on it without ``when defined(reproProviderMode)`` walls).
##
## The end-to-end behaviour (fetch action actually emitted in provider
## mode, configure depends on it) is exercised by the wayland from-
## source smoke; this test pins the structural contract only.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/constructors

suite "DSL-port M9.R.12.4 — autotools_package fetch wiring structural contract":

  test "configure action is still emitted when no fetch spec exists":
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("noFetchPkg")
    try:
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = @["--enable-gold"])
      check pkg.buildEdge.id.len > 0
      check pkg.buildEdge.deps.len == 0
      check pkg.buildEdge.inputs.len == 0
    finally:
      clearCurrentOwningPackageOverride()

  test "non-provider mode: helper inert even when fetch spec registered":
    # In unit-test mode (``reproProviderMode`` undefined) the
    # ``currentProviderProjectRoot()`` accessor returns the empty
    # string, so ``maybeEmitFetchAction`` bails out early and the
    # configure action stays without fetch wiring. This keeps unit
    # tests hermetic (no scratch files appear under the test cwd).
    resetDslPortFetchState()
    registerFetchSpec(
      packageName = "withFetchPkg",
      url = "https://example.org/binutils-2.43.tar.xz",
      gitRevision = "",
      hashAlg = dshaSha256,
      hashHex = "b53606f443ac8f01d1d5fc9c39497f2af322d99e14cea5c0b4b124d630379365",
      kind = dfkTarball,
      extractStrip = 1,
      extractedRoot = "")
    setCurrentOwningPackageOverride("withFetchPkg")
    try:
      let pkg = autotools_package(srcDir = "./src",
        configureOptions = @["--enable-shared"])
      # Provider context not seeded -> fetch helper bails. The
      # configure action still emits (no regression vs. M9.R.12.1).
      check pkg.buildEdge.id.len > 0
      # When ``currentProviderProjectRoot()`` is empty no fetch action
      # is emitted, so configure stays without fetch deps.
      check pkg.buildEdge.deps.len == 0
    finally:
      clearCurrentOwningPackageOverride()

  test "activeProviderProjectRoot accessor is exported (compiles)":
    # The accessor must be public so the stdlib constructors can
    # branch on it without requiring callers to define
    # ``reproProviderMode`` themselves. In non-provider mode the
    # accessor returns the empty string.
    let root = activeProviderProjectRoot()
    check root == ""
