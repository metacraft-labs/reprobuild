## Smoke test for the from-source ``mesonSource`` recipe.
##
## Pins the M9.H/I + M3 registry behaviour on the M9.N Batch C
## build-tool slice. meson's unique coverage angles vs the prior 74
## from-source recipes:
##
##   * FIRST source recipe in the corpus to declare a Python-only
##     toolchain dependency (``uses: "python >=3.8"`` alone, no C / C++
##     compiler) — pins the M9.N Batch A "uses: emits bare tool names"
##     surface against a Python tool consumer (vs the prior precedents
##     that all bundle ``"gcc >=11"`` + a make/cmake/meson driver).
##   * FIRST source recipe in the corpus that ships zero flag blocks AND
##     ships an ``executable`` artifact (vs ca-certificates' zero-flag
##     ``files`` artifact). Pins the four-channel cross-isolation empty-
##     state on a load-bearing executable-shaped recipe.
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
##   * SINGLE ``executable`` artifact registration (M3) — ``meson``
##     tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[strutils, unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + one executable artifact under ``mesonSource`` at module
# init time. No build-flag block on any channel — meson's upstream
# install path takes no build-system flags.
import ./repro

const ExpectedUrl =
  "https://github.com/mesonbuild/meson/releases/download/1.6.1/meson-1.6.1.tar.gz"

const ExpectedHash =
  "1eca49eb6c26d58bbee67fd3337d8ef557c0804e30a6d16bfdf269db997464de"

suite "mesonSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("mesonSource")
    check spec.packageName == "mesonSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the upstream 2,276,144-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("mesonSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("mesonSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "no flags registered on the configure channel":
    # M9.I cross-channel registry empty-state — meson's upstream install
    # path takes no ``./configure`` flags (the recipe is registration-
    # only until a Python-tool convention lands). Defends against a
    # regression that defaults the configure channel to a non-empty
    # seq for executable-shaped recipes.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("mesonSource", "", "configure") == emptyStrSeq

  test "no flags registered on the meson channel":
    # M9.I cross-channel registry empty-state #2 — meson channel is
    # empty (we are not bootstrapping meson via meson, that would be
    # the chicken-and-egg).
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("mesonSource", "", "meson") == emptyStrSeq

  test "no flags registered on the cmake channel":
    # M9.I cross-channel registry empty-state #3 — cmake channel is
    # empty.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("mesonSource", "", "cmake") == emptyStrSeq

  test "no flags registered on the make channel":
    # M9.I cross-channel registry empty-state #4 — make channel is
    # empty. The combination of empty-state across ALL FOUR build
    # channels matches the ca-certificates precedent but applies here
    # to an executable-shaped recipe rather than a files-shaped one.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("mesonSource", "", "make") == emptyStrSeq

  test "artifacts register a single meson executable tagged dakExecutable":
    # M3 artifact registry: ``meson`` is tagged ``dakExecutable``.
    # meson exposes a single load-bearing CLI binary (the wrapper
    # script that ``exec``s the bundled ``mesonbuild`` Python
    # package); auxiliary helpers (``meson-test-rust``, etc) are NOT
    # registered in v1.
    let arts = registeredArtifacts("mesonSource")
    check arts.len == 1
    check arts[0].packageName == "mesonSource"
    check arts[0].artifactName == "meson"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is recorded
    # for ``repro update-source``. The repository points at the
    # canonical github.com project that hosts the meson source tree.
    let vs = registeredVersions("mesonSource")
    check vs.len == 1
    check vs[0].version == "1.6.1"
    check vs[0].sourceRevision == "1.6.1"
    check vs[0].sourceUrl ==
      "https://github.com/mesonbuild/meson/releases/download/1.6.1/meson-1.6.1.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/mesonbuild/meson"

  test "shell() action registry records the meson install sequence":
    # M9.N Batch C.1 — the recipe's ``build:`` block records four
    # shell actions that lay out the install tree, copy the bundled
    # ``mesonbuild`` Python package, write the wrapper script, and
    # make it executable. The from-source-custom convention consumes
    # the sequence verbatim.
    let rows = registeredShellActions("mesonSource")
    check rows.len == 4
    # Declaration-order shape: every row attributes to the ``meson``
    # executable's artifact-scoped ``build:`` block.
    for r in rows:
      check r.packageName == "mesonSource"
      check r.artifactName == "meson"
    # Commands round-trip verbatim including the ``$out`` / ``$extracted``
    # placeholders the from-source-custom convention substitutes at emit
    # time.
    check rows[0].command == "mkdir -p $out/share/meson $out/bin"
    check rows[1].command == "cp -r $extracted/mesonbuild $out/share/meson/"
    check rows[2].command.contains("printf")
    check rows[2].command.contains("$out/bin/meson")
    check rows[3].command == "chmod +x $out/bin/meson"

  test "shell() ids carry the per-artifact sequence number":
    # M9.N Batch C.1 — auto-generated ids follow the
    # ``<package>-<artifact>-<seq>`` shape; sequence increments per
    # artifact. Pins the runtime's id-synthesis contract from the
    # recipe side (the runtime acceptance lives in
    # ``libs/repro_project_dsl/tests/dsl_port/t_dsl_shell_action.nim``).
    let rows = registeredShellActions("mesonSource")
    check rows.len == 4
    check rows[0].id == "mesonSource-meson-1"
    check rows[1].id == "mesonSource-meson-2"
    check rows[2].id == "mesonSource-meson-3"
    check rows[3].id == "mesonSource-meson-4"
