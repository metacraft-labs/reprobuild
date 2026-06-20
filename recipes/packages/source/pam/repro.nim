## Source-from-tarball Linux-PAM recipe — the THIRTY-THIRD real
## from-source production recipe to exercise the M9.H/I/K trio.
## Linux-PAM's unique coverage angle vs the prior thirty-two recipes
## is being a THREE-library single-package autotools recipe matching
## the openssl two-library shape but expanded to three. This pins the
## per-channel partitioning property at the three-library autotools
## cardinality.
##
## ## Why Linux-PAM matters for the v1 desktop story
##
## PAM (Pluggable Authentication Modules) is the canonical Linux
## authentication stack: every login path (gdm greeter login, sddm
## greeter login, sshd, su, sudo, polkit-pam, screen-lock unlock) goes
## through libpam's ``pam_start`` -> ``pam_authenticate`` ->
## ``pam_end`` ABI. libpam_misc is the helper library greeters use to
## marshal interactive prompts; libpamc is the client-side library
## sshd's session-replay paths consume. Without PAM there is no login
## path on a modern Linux desktop.
##
## ## sha256 strategy
##
## We vendor the upstream v1.6.1 .tar.xz at
## ``recipes/packages/source/pam/vendor/Linux-PAM-1.6.1.tar.xz`` and
## reference it via a ``file://`` URL. The github.com release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 1.6.1 (current upstream stable)
##
## Linux-PAM releases are cut on GitHub under tags of the form
## ``v<X>.<Y>.<Z>``. 1.6.1 is the current stable in the 1.6.x line as
## of mid-2026 and the ABI of libpam / libpam_misc / libpamc has been
## stable since 1.4 — anything ``>=1.4`` covers the gdm / sddm / sshd
## / polkit consumption.
##
## sha256 = f8923c740159052d719dbfc2a2f81942d68dd34fcaf61c706a02c9b80feeef8e
##  (computed locally over the vendored ``Linux-PAM-1.6.1.tar.xz``,
##  1,054,152 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H
## ``fetch:`` block and the M9.I ``configureFlags:`` block off this
## package's registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``./configure`` BuildAction that depends on the fetch action
##      and passes every flag in ``configureFlags:`` to the upstream
##      configure script, in declared order.
##   3. a ``make`` compile BuildAction (M9.L).
##   4. install/output collection actions for the three library
##      artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ``make`` + install glue lands in M9.L; the recipe
## records the three artifacts via the ``library`` blocks so the
## M9.K artifact registry already knows what shared objects to expect.
##
## ## Library artifacts
##
## Linux-PAM's autotools build emits three load-bearing shared
## libraries from a single ``./configure`` + ``make`` invocation:
##
##   * ``libpam.so``      — the core PAM authentication API consumed
##                           by gdm, sddm, sshd, su, sudo, polkit-pam.
##   * ``libpam_misc.so`` — the helper library greeters use to marshal
##                           interactive prompts.
##   * ``libpamc.so``     — the client-side library sshd's session-
##                           replay paths consume.
##
## We register the artifacts under the package-level identifiers
## ``libpam`` / ``libpamMisc`` / ``libpamc`` (preserving the upstream
## SONAME casing where natural, camelCasing the ``_misc`` suffix to
## ``Misc``).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``               — skip the static archive
##                                          (not used by the v1 desktop
##                                          story).
##   * ``--disable-doc``                  — skip the doc build (heavy
##                                          docbook-xsl + xmlto
##                                          dependency surface, not
##                                          needed at runtime).
##   * ``--without-selinux``              — skip the SELinux integration
##                                          (NDE-K1 v1 does not run
##                                          SELinux in enforcing mode).
##   * ``--enable-securedir=/lib/security`` — pin the canonical
##                                          PAM-module directory; gdm
##                                          + sddm + sshd all
##                                          ``dlopen`` modules from
##                                          this path.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a Fedora-edition variant
## that flips ``--with-selinux`` for SELinux-enforcing bundles).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package pamSource:
  ## From-source Linux-PAM — thirty-third M9.H/I/K production recipe
  ## and the EIGHTH autotools-driven recipe (expat + gdm + freetype +
  ## fontconfig + zlib-custom + libxml2 + openssl-custom + util-linux
  ## precedents).
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Three library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the Linux-PAM source tree.
    "1.6.1":
      sourceRevision = "v1.6.1"
      sourceUrl = "https://github.com/linux-pam/linux-pam/releases/download/v1.6.1/Linux-PAM-1.6.1.tar.xz"
      sourceRepository = "https://github.com/linux-pam/linux-pam"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,054,152-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://github.com/linux-pam/linux-pam/releases/download/v1.6.1/Linux-PAM-1.6.1.tar.xz"
    sha256: "f8923c740159052d719dbfc2a2f81942d68dd34fcaf61c706a02c9b80feeef8e"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``.
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only
    ## build semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — Linux-PAM is plain C99.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe
    ## for libxcrypt (the modern crypt(3) implementation Linux-PAM
    ## links to hash passwords).
    "pkg-config"
    ## flex is the lexer generator paired with PAM's pam.conf parser.
    "flex >=2.6"
    ## bison is the parser generator pam.conf consumes alongside flex.
    "bison >=3.6"

  buildDeps:
    ## M9.R.15e.8 — libxcrypt provides the modern crypt(3) implementation
    ## (libcrypt.so) consumed by the pam_pwhistory + pam_unix modules to
    ## hash passwords. Without it the link step short-fails:
    ##   undefined reference to `crypt'
    ## at ``modules/pam_pwhistory/opasswd.c:139``.
    "libcrypt"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libpam:
    ## ``libpam.so`` — the core PAM authentication API consumed by
    ## gdm, sddm, sshd, su, sudo, polkit-pam, screen-lock unlock.
    ## The upstream SONAME ``pam`` is preserved as-is in the
    ## artifact identifier (``libpam`` rather than ``libPam``)
    ## because the canonical PAM API surface (``pam_start`` etc.)
    ## conventionally uses lowercase ``pam_`` prefixed names. v1
    ## records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue
    ## closes.
    discard

  library libpamMisc:
    ## ``libpam_misc.so`` — the helper library greeters use to marshal
    ## interactive prompts (``pam_misc_setenv`` /
    ## ``misc_conv``). The upstream SONAME ``pam_misc`` is
    ## camelCased at the ``_misc`` boundary to ``libpamMisc``
    ## (preserving the canonical ``pam`` lowercase prefix while
    ## camelCasing the suffix). v1 records the artifact only.
    discard

  library libpamc:
    ## ``libpamc.so`` — the client-side library sshd's session-
    ## replay paths consume (``pamc_start`` /
    ## ``pamc_converse``). The upstream SONAME ``pamc`` is preserved
    ## as-is in the artifact identifier. v1 records the artifact
    ## only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("pamSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-doc",
        "--without-selinux",
        "--enable-securedir=/lib/security",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libpam")
      discard pkg.library("libpamMisc")
      discard pkg.library("libpamc")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
