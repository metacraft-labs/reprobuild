## DSL-port M9.R.15p.0 — auto-inject ``libxkbcommon`` + ``mesa`` as
## buildDeps whenever any ``qt6-*`` dep is declared at the package
## macro level.
##
## ## Context
##
## M9.R.15n.3..5 + M9.R.15o.2..4 hand-patched six recipes (kcrash,
## kglobalaccel, kded, ksvg, kio, kwindowsystem) to add explicit
## ``libxkbcommon >=1.5`` + ``mesa >=23.3`` annotations so Qt6Gui's
## CMake config-package ``find_dependency(XKB)`` + ``find_dependency(
## GLESv2)`` succeeds. Every Qt6Gui consumer needed the same
## boilerplate.
##
## M9.R.15o.1 moved a runtime-driven version (``m9r15oCollectQt6Trans-
## itiveCmakeDeps``) into ``cmake_package``'s constructor, but only the
## cache-vars channel reached the action graph — the search-path
## channel still required tool identities at macro-expansion time, so
## the runtime helper silently dropped on the from-source provider's
## search-path lane.
##
## M9.R.15p.0 closes that gap by moving the injection to
## ``parsePackageDef``: when ANY qt6-* dep is in either ``buildDeps:``
## or ``nativeBuildDeps:``, the helper appends ``libxkbcommon >=1.5``
## + ``mesa >=23.3`` to ``pkg.toolUses`` BEFORE the
## ``packageUseSeqLiteral`` fold builds ``ProjectInterface.toolUses``.
## Both channels (search-path + cache-vars) inherit the injection
## transparently.
##
## ## What this test pins
##
##   1. ``nativeBuildDeps: "qt6-base"`` auto-injects libxkbcommon +
##      mesa into the package's ``buildDeps:`` registry.
##   2. ``buildDeps: "qt6-base"`` auto-injects (the gate triggers off
##      either kind).
##   3. A package with no qt6-* dep does NOT see libxkbcommon + mesa
##      injected.
##   4. A package that already declares libxkbcommon by hand sees only
##      mesa injected (no duplicate).
##   5. A package that already declares both by hand sees no injection.
##   6. A package with qt6-* via ``uses:`` (legacy synonym for
##      buildDeps:) also triggers auto-injection.
##   7. Determinism: injected entries always land in fixed order
##      (libxkbcommon then mesa) after the user-declared entries.
##   8. ``qt6`` bare (no ``-suffix``) also triggers auto-injection
##      (case-insensitive prefix match).

import std/[strutils, unittest]

import repro_project_dsl

# ---------------------------------------------------------------------------
# Fixture 1 — nativeBuildDeps qt6-base triggers auto-injection.
# ---------------------------------------------------------------------------

package m9r15p0Qt6Native:
  nativeBuildDeps:
    "qt6-base >=6.6"

# ---------------------------------------------------------------------------
# Fixture 2 — buildDeps qt6-base triggers auto-injection.
# ---------------------------------------------------------------------------

package m9r15p0Qt6Build:
  buildDeps:
    "qt6-base >=6.6"

# ---------------------------------------------------------------------------
# Fixture 3 — no qt6 dep, no injection.
# ---------------------------------------------------------------------------

package m9r15p0NoQt6:
  buildDeps:
    "libZlib >=1.3"
    "openssl >=3.0"

# ---------------------------------------------------------------------------
# Fixture 4 — recipe already declares libxkbcommon by hand; only mesa
# should be auto-added.
# ---------------------------------------------------------------------------

package m9r15p0PartialDecl:
  buildDeps:
    "qt6-base >=6.6"
    "libxkbcommon >=1.5"

# ---------------------------------------------------------------------------
# Fixture 5 — recipe already declares BOTH by hand; no auto-injection.
# (M9.R.15n / M9.R.15o hand-patched recipes pre-retirement.)
# ---------------------------------------------------------------------------

package m9r15p0BothDecl:
  buildDeps:
    "qt6-base >=6.6"
    "libxkbcommon >=1.5"
    "mesa >=23.3"

# ---------------------------------------------------------------------------
# Fixture 6 — legacy ``uses:`` block (synonym of buildDeps:) also
# triggers auto-injection.
# ---------------------------------------------------------------------------

package m9r15p0Qt6Uses:
  uses:
    "qt6-base >=6.6"

# ---------------------------------------------------------------------------
# Fixture 7 — additional buildDeps coexist with auto-injection; injected
# entries land at the END so user-declared content keeps its source
# ordering.
# ---------------------------------------------------------------------------

package m9r15p0Ordering:
  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kcoreaddons >=6.0"

# ---------------------------------------------------------------------------
# Fixture 8 — multiple qt6-* deps; libxkbcommon + mesa still auto-injected
# exactly once (not once per qt6-* dep).
# ---------------------------------------------------------------------------

package m9r15p0MultipleQt6:
  buildDeps:
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "qt6-declarative >=6.6"

# ---------------------------------------------------------------------------
# Fixture 9 — bare ``qt6`` (no -suffix) also triggers auto-injection
# (the prefix match is on ``qt6`` not ``qt6-``).
# ---------------------------------------------------------------------------

package m9r15p0BareQt6:
  buildDeps:
    "qt6 >=6.6"

# ---------------------------------------------------------------------------
# Fixture 10 — case-insensitive: ``Qt6-Base`` still triggers.
# ---------------------------------------------------------------------------

package m9r15p0CaseInsensitive:
  buildDeps:
    "Qt6-Base >=6.6"

suite "DSL-port M9.R.15p.0 — Qt6Gui transitive auto-injection":

  test "nativeBuildDeps qt6-base auto-injects libxkbcommon + mesa":
    let deps = registeredBuildDeps("m9r15p0Qt6Native")
    # Auto-injection lands the two transitive deps in the buildDeps
    # registry (``pkg.toolUses`` slot). nativeBuildDeps stays untouched.
    check "libxkbcommon >=1.5" in deps
    check "mesa >=23.3" in deps
    check deps.len == 2
    # nativeBuildDeps should still hold only the user-declared entries.
    let native = registeredNativeBuildDeps("m9r15p0Qt6Native")
    check native == @["qt6-base >=6.6"]

  test "buildDeps qt6-base auto-injects libxkbcommon + mesa":
    let deps = registeredBuildDeps("m9r15p0Qt6Build")
    check "qt6-base >=6.6" in deps
    check "libxkbcommon >=1.5" in deps
    check "mesa >=23.3" in deps
    check deps.len == 3

  test "no qt6-* dep means no auto-injection":
    let deps = registeredBuildDeps("m9r15p0NoQt6")
    # Only user-declared entries; no Qt6 deps means no Qt6 transitives.
    check deps == @["libZlib >=1.3", "openssl >=3.0"]
    check "libxkbcommon >=1.5" notin deps
    check "mesa >=23.3" notin deps

  test "user-declared libxkbcommon is not duplicated; only mesa added":
    let deps = registeredBuildDeps("m9r15p0PartialDecl")
    # Exactly one libxkbcommon entry: the user's own.
    var xkbCount = 0
    for d in deps:
      if d.startsWith("libxkbcommon"):
        inc xkbCount
    check xkbCount == 1
    # mesa is auto-injected since the recipe didn't declare it.
    check "mesa >=23.3" in deps
    check deps == @["qt6-base >=6.6", "libxkbcommon >=1.5", "mesa >=23.3"]

  test "user-declared libxkbcommon + mesa means no auto-injection":
    # The pre-M9.R.15p.0 hand-patched recipes (kcrash et al) declare
    # both explicitly. The auto-injection must NOT duplicate them.
    let deps = registeredBuildDeps("m9r15p0BothDecl")
    var xkbCount = 0
    var mesaCount = 0
    for d in deps:
      if d.startsWith("libxkbcommon"):
        inc xkbCount
      if d.startsWith("mesa"):
        inc mesaCount
    check xkbCount == 1
    check mesaCount == 1
    check deps == @["qt6-base >=6.6", "libxkbcommon >=1.5", "mesa >=23.3"]

  test "legacy uses: block also triggers auto-injection":
    # The ``uses:`` synonym populates the same ``pkg.toolUses`` slot
    # the gate scans. Recipes that haven't migrated to ``buildDeps:``
    # still get the auto-injection.
    let deps = registeredBuildDeps("m9r15p0Qt6Uses")
    check "qt6-base >=6.6" in deps
    check "libxkbcommon >=1.5" in deps
    check "mesa >=23.3" in deps

  test "auto-injection determinism: libxkbcommon then mesa at the end":
    # The two auto-injected entries land in fixed (libxkbcommon, mesa)
    # order at the END of the buildDeps registry, after every user-
    # declared entry. Same input → same output every macro expansion.
    let deps = registeredBuildDeps("m9r15p0Ordering")
    # User-declared content keeps source-declaration order at the head.
    check deps[0] == "extra-cmake-modules >=6.0"
    check deps[1] == "qt6-base >=6.6"
    check deps[2] == "qt6-tools >=6.6"
    check deps[3] == "kcoreaddons >=6.0"
    # Auto-injected entries at the tail in fixed order.
    check deps[4] == "libxkbcommon >=1.5"
    check deps[5] == "mesa >=23.3"
    check deps.len == 6

  test "multiple qt6-* deps inject the transitives exactly once":
    let deps = registeredBuildDeps("m9r15p0MultipleQt6")
    var xkbCount = 0
    var mesaCount = 0
    for d in deps:
      if d.startsWith("libxkbcommon"):
        inc xkbCount
      if d.startsWith("mesa"):
        inc mesaCount
    check xkbCount == 1
    check mesaCount == 1
    check deps.len == 5

  test "bare ``qt6`` (no -suffix) also triggers auto-injection":
    # The prefix match is on ``qt6`` so a hypothetical bare ``qt6``
    # constraint still gates correctly. Defensive; no production recipe
    # uses this spelling today but it's covered by the case-insensitive
    # ``startsWith("qt6")`` test.
    let deps = registeredBuildDeps("m9r15p0BareQt6")
    check "libxkbcommon >=1.5" in deps
    check "mesa >=23.3" in deps

  test "case-insensitive: ``Qt6-Base`` triggers auto-injection":
    # Recipe authors writing the camel-case spelling are still served.
    let deps = registeredBuildDeps("m9r15p0CaseInsensitive")
    check "libxkbcommon >=1.5" in deps
    check "mesa >=23.3" in deps
