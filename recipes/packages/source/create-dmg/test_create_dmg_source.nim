## Smoke test for the from-source ``create-dmg`` recipe.
##
## Pins the M9.H fetch-spec + M2 versions + M3 artifact registry
## round-trip on the ``create-dmg`` recipe. create-dmg is the canonical
## shell-script tool that wraps ``hdiutil`` to produce polished macOS
## ``.dmg`` disk images (custom background, icon layout, code-signing);
## it ships as a single load-bearing ``create-dmg`` executable plus a
## ``support`` data tree.
##
## Coverage angles vs the wider from-source corpus:
##
##   * NO ``configureFlags:`` (or any build-system flag) block — the
##     recipe is a pure ``chmod`` + ``cp`` shell install, so there are
##     no flag assertions here. (The M9.I per-package flag registry was
##     retired in M9.R.6.1; the flag channels no longer exist to assert
##     against.)
##   * SINGLE ``create-dmg`` executable artifact (``dakExecutable``) —
##     verbatim (no kebab translation) artifact name carried through the
##     M3 registry.
##   * ``fetch:`` block round-trip (M9.H) — GitHub tag-archive URL +
##     sha256 length + algorithm + kind discriminant + ``extractStrip``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers the
# fetch spec + one executable artifact under ``create-dmg`` at module
# init time.
import ./repro

const ExpectedUrl =
  "https://github.com/create-dmg/create-dmg/archive/refs/tags/v1.2.3.tar.gz"

const ExpectedHash =
  "8cf7b4ae540801171f4f630f1f2956913aaa87483b7ac03458f52b6cd0c48953"

suite "create-dmg — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("create-dmg")
    check spec.packageName == "create-dmg"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # Length check guards against a future bump that forgets to widen
    # the hash alongside the URL.
    let spec = registeredFetchSpec("create-dmg")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention GitHub tag archives use (the
    # tarball's top-level directory is ``create-dmg-1.2.3``).
    let spec = registeredFetchSpec("create-dmg")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register a single create-dmg executable tagged dakExecutable":
    # M3 artifact registry: ``create-dmg`` is tagged ``dakExecutable``.
    # The recipe installs one load-bearing shell CLI (plus a bundled
    # ``support`` data tree copied by the same build body); only the
    # executable is registered as an artifact. A regression that
    # flattened the kind discriminator would mis-route the M9.L install
    # path; a regression that kebab-translated the artifact name would
    # break the verbatim ``create-dmg`` registration.
    let arts = registeredArtifacts("create-dmg")
    check arts.len == 1
    check arts[0].packageName == "create-dmg"
    check arts[0].artifactName == "create-dmg"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is recorded
    # for ``repro update-source``. The repository points at the
    # canonical create-dmg/create-dmg GitHub source tree.
    let vs = registeredVersions("create-dmg")
    check vs.len == 1
    check vs[0].version == "1.2.3"
    check vs[0].sourceRevision == "v1.2.3"
    check vs[0].sourceUrl == ExpectedUrl
    check vs[0].sourceRepository ==
      "https://github.com/create-dmg/create-dmg.git"
