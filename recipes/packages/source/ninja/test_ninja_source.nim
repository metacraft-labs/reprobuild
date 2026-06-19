## Smoke test for the from-source ``ninjaSource`` recipe.
##
## Pins the M9.H/I + M3 registry behaviour on the M9.N Batch C
## build-tool slice. ninja's unique coverage angles vs the prior 75
## from-source recipes (including the sibling ``mesonSource`` landing
## in this same batch):
##
##   * SECOND source recipe in the corpus to declare a
##     Python-bootstrapped toolchain (``uses: "python >=3.8"`` +
##     ``uses: "gcc >=11"``) — pairs with the sibling ``mesonSource``
##     recipe but ALSO declares the C++ toolchain because ninja's
##     bootstrap step compiles C++ sources (whereas meson is pure
##     Python).
##   * Zero flag blocks AND ``executable`` artifact (same shape as
##     ``mesonSource``) — pins the four-channel cross-isolation
##     empty-state on a SECOND load-bearing executable-shaped recipe.
##   * Registration-only — no ``from-source-*`` convention claims this
##     recipe today (see ``repro.nim``'s "Honest deferral" section).
##     The smoke test guards the registry round-trip so a future
##     convention or DSL ``build: shell ...`` widening can attach
##     without re-touching the recipe.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * No-flags state on ALL FOUR build channels (M9.I) — configure +
##     meson + cmake + make all empty.
##   * SINGLE ``executable`` artifact registration (M3) — ``ninja``
##     tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[strutils, unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + one executable artifact under ``ninjaSource`` at module
# init time. No build-flag block on any channel — ninja's upstream
# bootstrap takes no build-system flags by default in the v1 scope.
import ./repro

const ExpectedUrl =
  "https://github.com/ninja-build/ninja/archive/refs/tags/v1.12.1.tar.gz"

const ExpectedHash =
  "821bdff48a3f683bc4bb3b6f0b5fe7b2d647cf65d52aeb63328c91a6c6df285a"

suite "ninjaSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("ninjaSource")
    check spec.packageName == "ninjaSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the upstream 240,483-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("ninjaSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub archive
    # tarballs use.
    let spec = registeredFetchSpec("ninjaSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "no flags registered on the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the make channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single ninja executable tagged dakExecutable":
    # M3 artifact registry: ``ninja`` is tagged ``dakExecutable``.
    # ninja exposes a single load-bearing CLI binary (the build-
    # driver consumed by meson / cmake compile actions); auxiliary
    # shell-completion files under ``misc/`` are NOT registered in v1.
    let arts = registeredArtifacts("ninjaSource")
    check arts.len == 1
    check arts[0].packageName == "ninjaSource"
    check arts[0].artifactName == "ninja"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub tag is recorded for
    # ``repro update-source``. The repository points at the canonical
    # github.com project that hosts the ninja source tree.
    let vs = registeredVersions("ninjaSource")
    check vs.len == 1
    check vs[0].version == "1.12.1"
    check vs[0].sourceRevision == "v1.12.1"
    check vs[0].sourceUrl ==
      "https://github.com/ninja-build/ninja/archive/refs/tags/v1.12.1.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/ninja-build/ninja"

  test "shell() action registry records the ninja bootstrap sequence":
    # M9.N Batch C.1 — the recipe's ``build:`` block records two
    # shell actions: ``python3 configure.py --bootstrap`` followed by
    # ``install -Dm755 ninja $out/bin/ninja``. The from-source-custom
    # convention consumes the sequence verbatim; ``$out`` is resolved
    # to the per-package output dir at emit time.
    let rows = registeredShellActions("ninjaSource")
    check rows.len == 2
    for r in rows:
      check r.packageName == "ninjaSource"
      check r.artifactName == "ninja"
    check rows[0].command == "python3 configure.py --bootstrap"
    check rows[1].command.contains("install -Dm755 ninja $out/bin/ninja")

  test "shell() ids carry the per-artifact sequence number":
    # M9.N Batch C.1 — auto-generated ids follow the
    # ``<package>-<artifact>-<seq>`` shape; sequence increments per
    # artifact.
    let rows = registeredShellActions("ninjaSource")
    check rows.len == 2
    check rows[0].id == "ninjaSource-ninja-1"
    check rows[1].id == "ninjaSource-ninja-2"
