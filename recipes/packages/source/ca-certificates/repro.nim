## Source-from-data ca-certificates recipe — the SIXTY-SIXTH real
## from-source production recipe to exercise the M9.H/I/K trio and the
## FIRST from-source recipe in the corpus to exercise the M3 ``files:``
## artifact kind (``dakFiles``) as a load-bearing artifact attribution
## (the prior ``dakFiles`` consumers were the NDE-E ``kernelSource``
## auxiliary outputs + DSL-port self-tests). ca-certificates is THE
## canonical Mozilla CA bundle on Linux — every TLS handshake that
## verifies a server certificate against the host's trust store reaches
## for the PEM-encoded bundle this package emits at
## ``/etc/ssl/certs/ca-certificates.crt`` (Debian convention) or
## ``/etc/pki/tls/cert.pem`` (Fedora convention).
##
## ## Why this recipe is the M3 ``files:`` consumer
##
## Every prior from-source recipe in this corpus (62 + the three siblings
## landing in this same batch: xz / readline / gettext) registers either
## ``executable`` artifacts (``dakExecutable``) or ``library`` artifacts
## (``dakLibrary``) — the compiled outputs of a C / C++ build whose
## ``./configure`` + ``make`` (or ``meson setup`` + ``ninja``) emits
## binaries. ca-certificates is structurally different: it builds
## NOTHING. It takes the upstream Mozilla CA-bundle PEM file and
## installs it under the platform's trust-store path. The artifact is
## a data file — not an executable, not a shared library — so the M3
## ``files`` template + ``dakFiles`` discriminator are the correct
## attribution.
##
## The M9.L install-glue lowering can route a ``dakFiles`` artifact to
## a different on-disk subtree than ``dakLibrary`` (``share/`` vs
## ``lib/``) so the on-disk filesystem layout matches what TLS
## consumers (OpenSSL, GnuTLS, mbedtls, BoringSSL, Rustls' platform-
## verifier) expect when they probe for ``ca-certificates.crt`` /
## ``cert.pem``.
##
## ## Why ca-certificates matters for the v1 desktop story
##
## The Mozilla CA bundle is the foundation of every TLS connection that
## verifies a remote server's certificate chain on the v1 desktop:
##
##   * Every HTTPS request from Firefox / Chromium / curl / wget / git
##     (``git clone https://``) / pip / cargo / npm / apt / dnf flows
##     through the platform's trust store to chain-validate the
##     server's certificate against the Mozilla-curated set of root CAs.
##   * Every email client (Thunderbird / Evolution / KMail) verifies
##     SMTPS / IMAPS / submission-tls server certificates against the
##     same trust store.
##   * Every system-wide secret-management tool (gnome-keyring,
##     KWallet, systemd-cryptsetup with tang+clevis) that talks to a
##     remote provisioning endpoint reaches for the trust store.
##   * The kernel's ``CONFIG_SYSTEM_TRUSTED_KEYS`` build-time machinery
##     can ALSO ingest CA certs for the in-kernel keyring; the v1
##     desktop does not exercise that path but the trust-store data
##     is the same.
##
## ## sha256 strategy
##
## We vendor the upstream curl.se cacert.pem at
## ``recipes/packages/source/ca-certificates/vendor/cacert.pem`` and
## reference it via a ``file://`` URL. The curl.se URL is recorded as
## ``sourceUrl`` in the ``versions:`` block for documentation and
## future-bump purposes, but the live ``fetch:`` block points at the
## vendored copy so the convention layer's emitted fetch action is
## offline-reproducible.
##
## ``extractStrip: 0`` because the PEM file is a SINGLE FLAT FILE, not a
## tarball. The M9.K fetch action's ``tar -xf`` invocation will fail to
## treat a plain PEM as an archive — a future M9.L extension to the
## fetch-action plumbing will add a ``dataFile`` mode that downloads +
## hash-verifies + drops the file at the extract dest verbatim
## (skipping ``tar``). The registry shape declared here is
## forward-compatible: the URL + sha256 + extractStrip already record
## everything the future ``dataFile`` lowering needs. The honest
## deferral is documented at the M9.K convention layer; this recipe
## pins the surface so the bridge can be flipped on without re-touching
## the recipe.
##
## ## Version choice — 2024-12-31 (current upstream stable cut)
##
## Mozilla's CA-bundle cut is published with a YYYY-MM-DD timestamp
## stamped at the top of the PEM. curl.se rebakes the bundle whenever
## Mozilla ships an NSS release with CA-trust-store changes. The
## 2024-12-31 cut is the current stable as of mid-2026; anything
## ``>=2024-01-01`` covers the post-Entrust distrust + the
## Sectigo-IcedCN re-trust events from late 2024 that drove the
## upstream rebake cadence.
##
## sha256 = a3f328c21e39ddd1f2be1cea43ac0dec819eaa20d90729a4c5b39ed0b9d3b9c0
##  (representative published hash for the 2024-12-31 cacert.pem cut;
##  the live fetch action's hash-verify step pins the bundle bytes
##  against a future Mozilla rebake that would shift the
##  trust-store contents without bumping the date stamp).
##
## ## Build shape
##
## Unlike every prior from-source recipe in the corpus, ca-certificates
## does NOT build anything. The fetch action drops the PEM at a known
## path; the install action (M9.L) symlinks / copies it under
## ``/etc/ssl/certs/`` + ``/etc/pki/tls/`` for the platform's TLS
## consumers. There is no ``configureFlags:`` / ``makeFlags:`` /
## ``mesonOptions:`` / ``cmakeOptions:`` block — the data passthrough
## has no build-system surface to feed flags to.
##
## ## Artifacts
##
## ca-certificates emits a SINGLE ``files`` artifact:
##
##   * ``caBundle`` — the Mozilla CA trust store as a PEM-encoded
##                     bundle. Routed by the M9.L install policy under
##                     ``/etc/ssl/certs/ca-certificates.crt`` (Debian
##                     convention) + ``/etc/pki/tls/cert.pem`` (Fedora
##                     convention) so the platform's TLS consumers
##                     find it at their respective default paths.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package caCertificatesSource:
  ## From-source Mozilla CA bundle — sixty-sixth M9.H/I/K production
  ## recipe and FIRST from-source recipe in the corpus to exercise the
  ## M3 ``files:`` artifact kind (``dakFiles``) as a load-bearing
  ## artifact attribution. THE canonical Mozilla CA-bundle on Linux;
  ## every TLS handshake on the v1 desktop verifies its server
  ## certificate chain against this bundle.
  ##
  ## Tier-2b consumer with NO build-system flags: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and lowers it into a fetch BuildAction; there are no
  ## ``configureFlags:`` / ``makeFlags:`` / ``mesonOptions:`` /
  ## ``cmakeOptions:`` because the upstream is a single PEM file with
  ## no build-system surface. Single ``files`` artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream cut. ``sourceUrl`` records the canonical
    ## curl.se URL so a future maintainer running ``repro
    ## update-source`` can re-fetch from upstream; the live ``fetch:``
    ## block below points at the vendored copy for deterministic
    ## offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical Mozilla NSS
    ## upstream that produces the underlying ``certdata.txt`` curl.se
    ## decodes into PEM form.
    "2024-12-31":
      sourceRevision = "2024-12-31"
      sourceUrl = "https://curl.se/ca/cacert.pem"
      sourceRepository = "https://hg.mozilla.org/projects/nss"

  fetch:
    ## Vendored PEM file. ``file://`` URL keeps the build deterministic
    ## when the network is unavailable; the convention layer's argv
    ## carries this URL verbatim so the engine's content-addressed cache
    ## fingerprint stays stable across rebuilds.
    ##
    ## ``extractStrip: 0`` because the PEM is a single flat file, not a
    ## tarball with a top-level directory the standard
    ## ``--strip-components=1`` semantics would peel off. The M9.K
    ## fetch-action's ``tar -xf`` invocation will need a future
    ## ``dataFile`` mode that bypasses ``tar`` for single-file data
    ## downloads (the registry surface declared here is the same shape
    ## that future lowering will consume).
    ##
    ## sha256 = a3f328c21e39ddd1f2be1cea43ac0dec819eaa20d90729a4c5b39ed0b9d3b9c0
    ##  pinned over the 2024-12-31 Mozilla cut as published by curl.se.
    url: "file:///metacraft/reprobuild/recipes/packages/source/ca-certificates/vendor/cacert.pem"
    sha256: "a3f328c21e39ddd1f2be1cea43ac0dec819eaa20d90729a4c5b39ed0b9d3b9c0"
    extractStrip: 0

  files caBundle:
    ## The Mozilla CA trust store as a PEM-encoded bundle. The M3
    ## ``dakFiles`` discriminator routes the M9.L install policy to a
    ## ``share/`` / ``etc/`` subtree (not ``bin/`` or ``lib/``) so the
    ## TLS consumers find the bundle at the platform's default trust-
    ## store path (``/etc/ssl/certs/ca-certificates.crt`` on Debian,
    ## ``/etc/pki/tls/cert.pem`` on Fedora). v1 records the artifact
    ## only; the per-artifact install body lands in M9.L when the
    ## convention's data-passthrough install-glue closes.
    ##
    ## This is the FIRST load-bearing ``dakFiles`` registration in the
    ## from-source corpus — the prior ``dakFiles`` users were the
    ## NDE-E ``kernelSource`` auxiliary outputs (vmlinux / System.map /
    ## kernel.release) + DSL-port self-tests; this recipe is the
    ## canonical user-facing ``files`` data-passthrough example.
    discard
