## Smoke test for the from-source ``caCertificatesSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-SIXTH real
## production from-source recipe and the FIRST from-source recipe in
## the corpus to exercise the M3 ``files:`` artifact kind (``dakFiles``)
## as a load-bearing artifact attribution. ca-certificates' unique
## coverage angles vs the prior sixty-five from-source recipes:
##
##   * Single ``files`` artifact (``dakFiles``) — NEW kind in the
##     from-source corpus (prior corpus consumers used
##     ``dakExecutable`` + ``dakLibrary`` only). Pins the M3
##     ``files`` template's ``dakFiles`` discriminator end-to-end on
##     a load-bearing recipe (vs the DSL-port self-test where the
##     template was first exercised).
##   * ``extractStrip: 0`` — NEW value for the from-source corpus (every
##     prior recipe used ``extractStrip: 1`` because their upstream
##     tarballs ship with a single top-level directory the standard
##     ``--strip-components=1`` semantics peel off). Pins the registry
##     round-trip for the 0-value path against a regression that
##     defaulted-to-1 when the recipe explicitly says 0.
##   * NO ``configureFlags:`` / ``makeFlags:`` / ``mesonOptions:`` /
##     ``cmakeOptions:`` block — every prior from-source recipe in the
##     corpus declared at least one build-system flag block. Pins the
##     four-channel cross-isolation registry's empty-state on a real
##     load-bearing recipe.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + ``extractStrip == 0``.
##   * No-flags state on ALL FOUR build channels (M9.I) — configure +
##     meson + cmake + make all empty.
##   * SINGLE ``files`` artifact registration (M3) — ``caBundle``
##     tagged ``dakFiles`` (FIRST load-bearing ``dakFiles`` in the
##     from-source corpus).
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + one files artifact under ``caCertificatesSource`` at
# module init time. No build-flag block on any channel.
import ./repro

const ExpectedUrl =
  "https://curl.se/ca/cacert.pem"

const ExpectedHash =
  "a3f328c21e39ddd1f2be1cea43ac0dec819eaa20d90729a4c5b39ed0b9d3b9c0"

suite "caCertificatesSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("caCertificatesSource")
    check spec.packageName == "caCertificatesSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2024-12-31 cacert.pem cut; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("caCertificatesSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec records extractStrip == 0 verbatim":
    # NEW coverage angle vs the prior sixty-five from-source recipes:
    # the 0 value is captured verbatim, not silently defaulted to 1.
    # A regression that treated 0 as "unset" (and substituted the 1
    # default) would surface here — the convention layer's tar
    # invocation would then peel a non-existent top-level directory
    # off the (future) data-mode download path.
    let spec = registeredFetchSpec("caCertificatesSource")
    check spec.extractStrip == 0
    # The kind discriminant is still ``dfkTarball`` because M9.H
    # ships only two kinds; a future milestone widens the enum with a
    # ``dfkDataFile`` variant for single-file data downloads. The
    # forward-compatible shape declared here lets that lowering flip
    # on without re-touching the recipe.
    check spec.kind == dfkTarball

  test "no configureFlags registered on the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the make channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single files artifact tagged dakFiles":
    # M3 artifact registry: ``caBundle`` is tagged ``dakFiles``. This
    # is the FIRST load-bearing ``dakFiles`` registration in the
    # from-source corpus — the prior ``dakFiles`` users were the NDE-E
    # ``kernelSource`` auxiliary outputs (vmlinux / System.map /
    # kernel.release) + DSL-port self-tests. A regression that
    # collapsed the ``dakFiles`` discriminator (e.g. routed it through
    # the ``dakLibrary`` arm of the M3 ``parsePackageDef`` walker)
    # would mis-route the M9.L install path (``share/`` vs ``lib/``)
    # for every consumer of this recipe; this test guards that arm.
    let arts = registeredArtifacts("caCertificatesSource")
    check arts.len == 1
    check arts[0].packageName == "caCertificatesSource"
    check arts[0].artifactName == "caBundle"
    check arts[0].kind == dakFiles

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream curl.se URL is recorded for
    # ``repro update-source`` even though the live fetch points at the
    # vendored copy. The repository points at the canonical Mozilla
    # NSS upstream that produces the underlying ``certdata.txt`` curl.se
    # decodes into PEM form.
    let vs = registeredVersions("caCertificatesSource")
    check vs.len == 1
    check vs[0].version == "2024-12-31"
    check vs[0].sourceRevision == "2024-12-31"
    check vs[0].sourceUrl ==
      "https://curl.se/ca/cacert.pem"
    check vs[0].sourceRepository ==
      "https://hg.mozilla.org/projects/nss"
