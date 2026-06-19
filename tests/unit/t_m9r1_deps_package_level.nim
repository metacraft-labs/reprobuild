## DSL-port M9.R.1 — package-level dependency-declaration surface.
##
## Pins the three new package-level blocks plus the legacy synonym:
##
##   * ``buildDeps:``         — canonical spelling. Same minispec
##                              grammar as the legacy ``uses:`` block.
##   * ``uses:``              — legacy synonym for ``buildDeps:``;
##                              kept untouched until the M9.R.5
##                              recipe sweep renames the 84 existing
##                              from-source recipes.
##   * ``nativeBuildDeps:``   — BUILD-platform tools / code generators.
##   * ``runtimeDeps:``       — HOST-platform runtime / link deps.
##
## Coverage:
##
##   1. ``buildDeps:`` block parses + registers — two-entry sequence,
##      constraint strings preserved verbatim, queryable via
##      ``registeredBuildDeps``.
##   2. ``buildDeps:`` is a synonym of ``uses:`` — both spellings
##      populate the same registry (one recipe with each spelling
##      returns identical contents).
##   3. ``nativeBuildDeps:`` block parses + registers — confirmed
##      isolated from ``registeredBuildDeps``.
##   4. ``runtimeDeps:`` block parses + registers — confirmed isolated
##      from the other two registries.
##   5. All three blocks coexist on one package without cross-bleeding.
##   6. Codec round-trip — DEFERRED. There is no package-level codec
##      in tree (the v17 ``BuildActionPayload`` codec covers per-edge
##      ``toolIdentityRefs`` only). The package-level dep blocks live
##      in the in-memory ``dslPortPackageDeps`` registry; a follow-up
##      milestone owns the wire-format extension (see commit body).

import std/[unittest]

import repro_project_dsl

# ---------------------------------------------------------------------------
# Test fixtures — one ``package`` declaration per shape we want to pin.
# All blocks use the same constraint-string grammar as the legacy ``uses:``
# block; the M9.R.1 registries store the ``rawConstraint`` form verbatim.
# ---------------------------------------------------------------------------

package m9r1OnlyBuildDeps:
  buildDeps:
    "gcc >=12"
    "libZlib >=1.3"

package m9r1OnlyUses:
  uses:
    "foo"

package m9r1OnlyBuildDepsSingle:
  buildDeps:
    "foo"

package m9r1OnlyNativeDeps:
  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"

package m9r1OnlyRuntimeDeps:
  runtimeDeps:
    "python3 >=3.9"

package m9r1AllThree:
  buildDeps:
    "libZlib >=1.3"
  nativeBuildDeps:
    "meson >=1.0"
  runtimeDeps:
    "python3 >=3.9"

suite "DSL-port M9.R.1 — package-level dependency declarations":

  test "buildDeps: block registers two entries verbatim":
    # Constraint strings round-trip exact in source-declaration order.
    let deps = registeredBuildDeps("m9r1OnlyBuildDeps")
    check deps == @["gcc >=12", "libZlib >=1.3"]
    check deps.len == 2
    # No leakage into the other two registries.
    check registeredNativeBuildDeps("m9r1OnlyBuildDeps").len == 0
    check registeredRuntimeDeps("m9r1OnlyBuildDeps").len == 0

  test "buildDeps: is a synonym of uses:":
    # Both spellings populate the SAME registry; a recipe using one or
    # the other returns identical contents under ``registeredBuildDeps``.
    let usesEntries = registeredBuildDeps("m9r1OnlyUses")
    let buildDepsEntries = registeredBuildDeps("m9r1OnlyBuildDepsSingle")
    check usesEntries == @["foo"]
    check buildDepsEntries == @["foo"]
    check usesEntries == buildDepsEntries

  test "nativeBuildDeps: block registers entries isolated from buildDeps":
    let native = registeredNativeBuildDeps("m9r1OnlyNativeDeps")
    check native == @["meson >=1.0", "ninja >=1.10"]
    check native.len == 2
    # The nativeBuildDeps slot must NOT leak into the buildDeps slot —
    # the disambiguation is load-bearing for the cross-toolchain
    # follow-up (M9.R.7).
    check registeredBuildDeps("m9r1OnlyNativeDeps").len == 0
    check registeredRuntimeDeps("m9r1OnlyNativeDeps").len == 0

  test "runtimeDeps: block registers entries isolated from the other two":
    let runtime = registeredRuntimeDeps("m9r1OnlyRuntimeDeps")
    check runtime == @["python3 >=3.9"]
    check runtime.len == 1
    check registeredBuildDeps("m9r1OnlyRuntimeDeps").len == 0
    check registeredNativeBuildDeps("m9r1OnlyRuntimeDeps").len == 0

  test "all three blocks coexist on one package":
    # Each block's contents reach the corresponding registry independently
    # — no cross-bleed regardless of declaration order in the package
    # body.
    check registeredBuildDeps("m9r1AllThree") == @["libZlib >=1.3"]
    check registeredNativeBuildDeps("m9r1AllThree") == @["meson >=1.0"]
    check registeredRuntimeDeps("m9r1AllThree") == @["python3 >=3.9"]

  test "unknown packages return empty seqs":
    # The accessor never raises on an unknown package — it returns the
    # empty seq so callers (e.g. M9.R.5 sweep helpers) can probe a
    # recipe table without try/except.
    check registeredBuildDeps("m9r1NonexistentPackage").len == 0
    check registeredNativeBuildDeps("m9r1NonexistentPackage").len == 0
    check registeredRuntimeDeps("m9r1NonexistentPackage").len == 0
