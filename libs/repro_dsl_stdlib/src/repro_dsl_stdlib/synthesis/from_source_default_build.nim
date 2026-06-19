## DSL-port M9.R.6 — default ``build:`` synthesis for from-source recipes.
##
## ## What this module covers
##
## The five Tier-2b ``from-source-*`` conventions (meson / cmake /
## autotools / make / custom) traditionally owned both
##
##   1. **Recognition + fetch action emission** — claim the recipe via
##      its declared ``fetch:`` block + ``nativeBuildDeps:`` toolset and
##      lower the URL+sha256 into a content-addressed fetch action.
##   2. **Build-graph emission** — generate the canonical configure +
##      compile + install + per-artifact stage-copy action chain.
##
## M9.R.6 splits these two concerns. The recognition+fetch responsibility
## stays in the convention layer (``libs/repro_standard_provider/.../
## conventions/from_source_*.nim``). The build-graph synthesis moves
## here. The convention's ``emitFragment`` now keeps the fetch action +
## emits a sentinel marker action that bridges to this module's
## synthesis path; recipes that declare an explicit ``build:`` block
## drive the build themselves (skipping synthesis); recipes that don't
## fall through to the convention sentinel and this module synthesises
## the canonical pipeline by calling the corresponding stdlib
## constructor (``meson_package`` / ``cmake_package`` /
## ``autotools_package``).
##
## ## Dispatch
##
## The single entry point ``defaultBuildConventionFor(packageName)``
## inspects ``registeredNativeBuildDeps(packageName)`` (M9.R.1) and
## returns one of:
##
##   * ``"meson"``      — recipe declares ``meson`` (drives
##                         ``meson_package(...)``).
##   * ``"cmake"``      — recipe declares ``cmake`` (drives
##                         ``cmake_package(...)``).
##   * ``"autotools"``  — recipe declares ``autoconf`` / ``automake`` /
##                         ``libtool`` (drives ``autotools_package(...)``).
##   * ``"make"``       — recipe declares ``make`` and none of the above
##                         (drives ``autotools_package(...)`` since
##                         autotools' Makefile path also covers raw make).
##   * ``"custom"``     — recipe declares ``sh`` / ``perl`` / ``python``
##                         shell driver and none of the standard
##                         channels (the synthesis layer DOES NOT have a
##                         default for custom; an explicit ``build:`` is
##                         REQUIRED).
##   * ``""``           — no recognised convention; synthesis declines.
##
## The dispatch is order-sensitive: meson > cmake > autotools > make >
## custom. A recipe that lists both ``meson`` and ``make`` is treated as
## meson-driven (make is meson's backend). This matches the convention
## registration order in ``apps/repro-standard-provider``.
##
## ## ``synthesizeDefaultBuildBody``
##
## Given a recipe identity + the resolved convention name + the
## ``srcDir`` path the fetch action extracted to, ``synthesizeDefault-
## BuildBody`` returns a typed-stdlib value matching the convention's
## multi-artifact result type (``MesonPackageResult`` /
## ``CmakePackageResult`` / ``AutotoolsPackageResult``). The macro's
## synthesised body assigns the result to a ``pkg`` binding then walks
## each declared artifact (``executable <name>:`` / ``library <name>:`` /
## ``files <name>``) and slices a binding via ``pkg.executable("<name>")``
## / ``pkg.library("<name>")`` / ``pkg.files("<name>")``.
##
## ## When synthesis is REQUIRED but no default works (custom)
##
## ``raiseCustomBuildRequired`` raises a ``ValueError`` documenting the
## issue: the recipe declared a custom-shell-driver toolset (sh / perl /
## python) and no explicit ``build:`` block. Custom recipes MUST author
## their build steps by hand via the ``shell()`` action surface in a
## ``build:`` block (see ``recipes/packages/source/cmake/repro.nim`` for
## a production example). The macro layer translates this runtime raise
## into a compile-time ``error()`` via the ``{.compileTime.}`` call from
## ``macros_b.nim``'s package macro.
##
## ## Backward-compat with M9.I ``registeredBuildFlags``
##
## The registry stays accessible for backward-decode; M9.R.5b will
## sweep its remaining call sites into the ``config:`` surface. This
## module DOES read the registry today via ``registeredBuildFlags`` so
## recipes whose ``mesonOptions:`` / ``cmakeFlags:`` / ``configureFlags:``
## / ``makeFlags:`` blocks haven't been swept still build with the right
## options. The accessor itself carries a deprecation comment.
##
## See ``reprobuild-specs/From-Source-DSL-Realignment.milestones.org``
## §M9.R.6 + ``From-Source-Build-Recipes.md`` §"Where this knowledge
## lives".

import std/strutils

import repro_project_dsl

import ../constructors/meson_package as meson_pkg
import ../constructors/cmake_package as cmake_pkg
import ../constructors/autotools_package as autotools_pkg
import ../types/package_result

export meson_pkg
export cmake_pkg
export autotools_pkg
export package_result

const
  ## Canonical convention names returned by
  ## ``defaultBuildConventionFor``. The string values mirror the
  ## ``LanguageConvention.name`` slot on the standard-provider side
  ## minus the ``from-source-`` prefix; the dispatch table is keyed on
  ## this short form so the synthesis layer stays decoupled from the
  ## provider-side naming.
  ConventionMeson*     = "meson"
  ConventionCmake*     = "cmake"
  ConventionAutotools* = "autotools"
  ConventionMake*      = "make"
  ConventionCustom*    = "custom"

proc firstToken(constraint: string): string =
  ## Extract the package-selector head from a constraint string
  ## ``"meson >=1.3"`` -> ``"meson"``. The DSL surface routes
  ## constraint strings unchanged through the registry; the matching
  ## logic only needs the head.
  let stripped = constraint.strip()
  if stripped.len == 0:
    return ""
  for i, ch in stripped:
    if ch in {' ', '\t', '>', '<', '=', '!', ',', ';'}:
      return stripped[0 ..< i]
  stripped

proc hasNativeBuildDep(packageName, token: string): bool =
  ## True when ``token`` appears as the leading name in any
  ## ``nativeBuildDeps:`` constraint string registered for
  ## ``packageName``. Case-sensitive — matches the registry's verbatim
  ## storage.
  for raw in registeredNativeBuildDeps(packageName):
    if firstToken(raw) == token:
      return true
  false

proc hasAnyNativeBuildDep(packageName: string;
                          tokens: openArray[string]): bool =
  ## True when ANY of ``tokens`` appears as a leading name in
  ## ``nativeBuildDeps:``. Useful for the autotools dispatch which
  ## claims a recipe declaring any of ``autoconf`` / ``automake`` /
  ## ``libtool``.
  for token in tokens:
    if hasNativeBuildDep(packageName, token):
      return true
  false

proc defaultBuildConventionFor*(packageName: string): string =
  ## Inspect the recipe's ``nativeBuildDeps:`` registry and return the
  ## convention identity that the synthesis layer would apply. Returns
  ## the empty string when no recognised convention matches.
  ##
  ## ## Dispatch order
  ##
  ## ``meson`` > ``cmake`` > ``autoconf|automake|libtool`` (autotools) >
  ## ``make`` > custom-shell driver (``sh`` / ``perl`` / ``python``)
  ## > nothing.
  if hasNativeBuildDep(packageName, "meson"):
    return ConventionMeson
  if hasNativeBuildDep(packageName, "cmake"):
    return ConventionCmake
  if hasAnyNativeBuildDep(packageName, ["autoconf", "automake", "libtool"]):
    return ConventionAutotools
  if hasNativeBuildDep(packageName, "make"):
    return ConventionMake
  if hasAnyNativeBuildDep(packageName, ["sh", "perl", "python"]):
    return ConventionCustom
  ""

proc shouldSynthesizeDefaultBuild*(packageName: string;
                                   hasExplicitBuild: bool;
                                   hasFetchBlock: bool): bool =
  ## Gate for the macro layer: synthesis fires when ALL of the
  ## following hold:
  ##
  ##   * the recipe declared a ``fetch:`` block (sources need
  ##     extraction first; without a fetch the constructors have no
  ##     ``srcDir`` to point at);
  ##   * the recipe has NO explicit ``build:`` block (an explicit
  ##     block opts out of synthesis verbatim);
  ##   * the recipe's ``nativeBuildDeps:`` map onto a recognised
  ##     convention.
  ##
  ## A recipe that fails the third gate but passes the first two falls
  ## through to the legacy convention emitFragment path (which still
  ## emits its own 5-stage pipeline for backward-compat).
  if hasExplicitBuild:
    return false
  if not hasFetchBlock:
    return false
  let conv = defaultBuildConventionFor(packageName)
  if conv.len == 0:
    return false
  if conv == ConventionCustom:
    # Custom convention has no canonical pipeline — the recipe MUST
    # carry an explicit ``build:`` block. The gate returns false here
    # AND raises via ``raiseCustomBuildRequired`` at the macro layer so
    # the author sees an actionable diagnostic at recipe compile time.
    return false
  true

proc raiseCustomBuildRequired*(packageName: string) =
  ## Raise a ``ValueError`` documenting the missing ``build:`` block on
  ## a custom-convention recipe. Called from the macro layer when
  ## ``defaultBuildConventionFor`` returned ``"custom"`` but the recipe
  ## declared no explicit ``build:`` block.
  raise newException(ValueError,
    "from-source synthesis: package '" & packageName &
      "' has no explicit ``build:`` block AND its ``nativeBuildDeps:`` " &
      "are shell-driver only (sh / perl / python). Custom-convention " &
      "recipes have no canonical pipeline; add a ``build:`` block " &
      "calling ``shell(...)`` per upstream step. See " &
      "``recipes/packages/source/cmake/repro.nim`` for a production " &
      "example.")

proc legacyMesonOptions*(packageName: string): seq[string] =
  ## Read the M9.I ``registeredBuildFlags`` channel on ``"meson"`` for
  ## ``packageName``. Backward-compat shim: M9.R.6 deprecates the
  ## ``registeredBuildFlags`` accessor but recipes still use the
  ## ``mesonOptions:`` block today (M9.R.5b sweep pending). The
  ## synthesis layer threads the registered options into the
  ## ``meson_package(...)`` constructor's ``configureOptions`` arg so
  ## the synthesised build graph matches what the convention's
  ## emitFragment would have produced.
  registeredBuildFlags(packageName, "", "meson")

proc legacyCmakeFlags*(packageName: string): seq[string] =
  registeredBuildFlags(packageName, "", "cmake")

proc legacyConfigureFlags*(packageName: string): seq[string] =
  registeredBuildFlags(packageName, "", "configure")

proc legacyMakeFlags*(packageName: string): seq[string] =
  registeredBuildFlags(packageName, "", "make")

proc synthesizeMesonPackage*(packageName, srcDir: string): MesonPackageResult =
  ## Drive ``meson_package(srcDir = <fetched/extracted dir>,
  ## configureOptions = legacyMesonOptions(...))``. The returned
  ## ``MesonPackageResult`` exposes ``.executable(name)`` /
  ## ``.library(name)`` / ``.files(name)`` slicing methods the macro
  ## binds to each declared artifact.
  meson_package(
    srcDir = srcDir,
    configureOptions = legacyMesonOptions(packageName))

proc synthesizeCmakePackage*(packageName, srcDir: string): CmakePackageResult =
  ## Drive ``cmake_package(srcDir = ..., cacheVars =
  ## legacyCmakeFlags(...))``. The ``cmakeFlags:`` block routes here
  ## as ``cacheVars`` because cmake's command-line ``-D<name>=<value>``
  ## form is what the registry holds.
  cmake_package(
    srcDir = srcDir,
    cacheVars = legacyCmakeFlags(packageName))

proc synthesizeAutotoolsPackage*(packageName, srcDir: string):
    AutotoolsPackageResult =
  ## Drive ``autotools_package(srcDir = ..., configureOptions =
  ## legacyConfigureFlags(...))``. The ``configureFlags:`` block routes
  ## here as ``configureOptions``. Raw-Makefile recipes (no
  ## ``configure`` step) end up here too — the autotools_package
  ## constructor handles them via its ``make`` step (configure is
  ## a no-op for projects without a real ``./configure`` script when
  ## the flags seq is empty).
  autotools_package(
    srcDir = srcDir,
    configureOptions = legacyConfigureFlags(packageName))
