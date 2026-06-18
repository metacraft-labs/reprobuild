## Source-from-tarball libcap recipe — the THIRTY-FOURTH real
## from-source production recipe to exercise the M9.H/I/K trio.
## libcap's unique coverage angle vs the prior thirty-three recipes
## is the M9.I ``makeFlags:`` channel feeding a RAW Makefile (no
## ``./configure`` step) — only the SECOND recipe in the corpus to
## consume ``makeFlags:`` (linux-kernel was the first), and the FIRST
## recipe to drive a non-kbuild raw Makefile through the channel. This
## pins the ``makeFlags:`` channel's grammar from a second flavour:
## kbuild variable-overrides (linux-kernel: ``ARCH=`` + ``LOCALVERSION=``
## + ``-j1``) plus libcap-style ``BUILD_CC=`` + ``prefix=`` overrides.
##
## ## Why libcap matters for the v1 desktop story
##
## libcap is the canonical POSIX capabilities library every Linux
## daemon links to drop-and-keep capabilities at startup:
##
##   * systemd's per-unit ``CapabilityBoundingSet=`` directive uses
##     libcap to compute the bounding set bitmap.
##   * sshd's privilege-separation child uses libcap to drop all
##     capabilities after fork.
##   * NetworkManager uses libcap to keep CAP_NET_ADMIN after dropping
##     the rest.
##   * Plasma's ``kwin_wayland`` uses libcap to keep CAP_SYS_NICE for
##     real-time scheduling.
##
## ``capsh`` is the canonical capability-shell debugger admin teams
## use to inspect capability sets; ``getcap`` / ``setcap`` are the
## file-capability CLIs that pin per-binary CAP_NET_BIND_SERVICE etc
## without making the binary suid-root.
##
## ## sha256 strategy
##
## We vendor the upstream v2.71 .tar.xz at
## ``recipes/packages/source/libcap/vendor/libcap-2.71.tar.xz`` and
## reference it via a ``file://`` URL. The kernel.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 2.71 (current upstream stable)
##
## libcap releases are cut on kernel.org under the libcap2 series;
## 2.71 is the current stable as of mid-2026 and the ABI has been
## stable since 2.60 — anything ``>=2.60`` covers the systemd / sshd /
## NetworkManager consumption.
##
## sha256 = b7006c9af5168315f35fc734bf1a8d2aa70766bd8b8c4340962e05b19c35b900
##  (computed locally over the vendored ``libcap-2.71.tar.xz``,
##  193,512 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## libcap uses a RAW Makefile (no ``./configure`` step). The
## c_cpp_make convention (M9.K's sibling lowering) reads both the
## M9.H ``fetch:`` block and the M9.I ``makeFlags:`` block off this
## package's registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``make`` compile BuildAction that depends on the fetch
##      action and passes every flag in ``makeFlags:`` to ``make``,
##      in declared order.
##   3. install/output collection actions for the four artifacts
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ``make`` + install glue lands in M9.L; the recipe
## records the four artifacts via the ``library`` + ``executable``
## blocks so the M9.K artifact registry already knows what shared
## object + binaries to expect.
##
## ## Artifacts
##
## libcap's build emits four load-bearing outputs from a single
## ``make`` invocation against the raw Makefile:
##
##   * ``libCap``  — ``libcap.so`` the POSIX capabilities library
##                    consumed by systemd / sshd / NetworkManager /
##                    kwin_wayland.
##   * ``capsh``   — ``/sbin/capsh`` the capability-shell debugger
##                    admin teams use to inspect capability sets.
##   * ``getcap``  — ``/sbin/getcap`` the file-capability inspector.
##   * ``setcap``  — ``/sbin/setcap`` the file-capability mutator
##                    that pins per-binary CAP_NET_BIND_SERVICE etc
##                    without making the binary suid-root.
##
## We register the artifacts under the package-level identifiers
## ``libCap`` (PascalCased from upstream SONAME ``cap`` per the
## libExpat / libZ / libGlib2 precedent) and the bare upstream binary
## names ``capsh`` / ``getcap`` / ``setcap`` (no rename needed —
## these are unambiguous and already lowercase).
##
## ## Configurables
##
## v1 ships NO configurables — the make flags are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``BUILD_CC=gcc``      — pin the host compiler used at build
##                              time (vs the cross compiler for
##                              target binaries). libcap's Makefile
##                              defaults to ``cc`` which is brittle
##                              on systems without a /usr/bin/cc
##                              symlink.
##   * ``RAISE_SETFCAP=no``  — skip the post-install ``setcap``
##                              invocation on ``setcap`` itself; the
##                              v1 desktop's install layer runs as
##                              the build user, not root, and cannot
##                              raise file capabilities.
##   * ``lib=lib``           — pin the library install subdir name to
##                              ``lib`` (vs ``lib64`` which libcap's
##                              Makefile picks on x86_64 by default).
##                              The v1 desktop uses ``/lib`` not
##                              ``/lib64`` per the FHS-3 merged-/usr
##                              layout.
##   * ``prefix=/usr``       — pin the install prefix to ``/usr``
##                              (vs the libcap default of ``/usr``
##                              which is fine but we pin it
##                              explicitly so the cache key is
##                              stable across a future Makefile
##                              default change).
##   * ``GOLANG=no``         — skip the Go bindings build (heavy Go
##                              toolchain dependency surface, not
##                              needed at runtime).
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a Go-edition variant that
## flips ``GOLANG=yes`` for the Go-based admin tooling, or a
## ``/lib64`` variant for distros following the SysV
## bi-arch convention).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libcapSource:
  ## From-source libcap — thirty-fourth M9.H/I/K production recipe
  ## and the SECOND consumer of the M9.I ``makeFlags:`` channel
  ## (linux-kernel was the first). FIRST recipe to drive a non-kbuild
  ## raw Makefile through the channel — pins the ``makeFlags:``
  ## channel's grammar from a second flavour angle.
  ##
  ## Tier-2b c_cpp_make convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``makeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"make"`` channel) and lowers
  ## them into fetch + make BuildActions wired with the right URL +
  ## hash + flags. One library + three executable artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## kernel.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical mirror on
    ## git.kernel.org that hosts the libcap source tree.
    "2.71":
      sourceRevision = "libcap-2.71"
      sourceUrl = "https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-2.71.tar.xz"
      sourceRepository = "https://git.kernel.org/pub/scm/libs/libcap/libcap.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 193,512-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above. libcap is the SMALLEST source tarball in
    ## the from-source corpus (< 200 KB).
    url: "file:///metacraft/reprobuild/recipes/packages/source/libcap/vendor/libcap-2.71.tar.xz"
    sha256: "b7006c9af5168315f35fc734bf1a8d2aa70766bd8b8c4340962e05b19c35b900"
    extractStrip: 1

  uses:
    ## make is the build-system driver — libcap's raw Makefile is
    ## driven directly by ``make`` (no ``./configure`` step).
    "make"
    ## gcc is the host C toolchain — libcap is plain C99 with a small
    ## kernel-header dependency surface.
    "gcc >=11"
    ## perl is invoked by libcap's ``Makefile`` to generate the
    ## ``cap_names.list.h`` header from the kernel's capability
    ## name table (a Perl one-liner in
    ## ``libcap/Makefile``).
    "perl >=5.32"

  makeFlags:
    ## Flag set tuned for a deterministic libcap build. Order is
    ## load-bearing: ``make`` evaluates variable assignments left-to-
    ## right and the ``GOLANG=no`` sentinel lives at the tail so M9.L
    ## can override (or a future Go-edition variant can append
    ## ``GOLANG=yes``) without re-ordering the variable-override
    ## block.
    ##
    ## ``BUILD_CC=gcc`` pins the host compiler (vs the brittle ``cc``
    ##                   default).
    ## ``RAISE_SETFCAP=no`` skips the post-install ``setcap``
    ##                       invocation on ``setcap`` itself.
    ## ``lib=lib`` pins the library install subdir name to ``lib``.
    ## ``prefix=/usr`` pins the install prefix to ``/usr``.
    ## ``GOLANG=no`` skips the Go bindings build.
    "BUILD_CC=gcc"
    "RAISE_SETFCAP=no"
    "lib=lib"
    "prefix=/usr"
    "GOLANG=no"

  library libCap:
    ## ``libcap.so`` — the POSIX capabilities library consumed by
    ## systemd's per-unit ``CapabilityBoundingSet=`` directive, sshd's
    ## privilege-separation child, NetworkManager's
    ## CAP_NET_ADMIN-keep path, and Plasma's ``kwin_wayland``'s
    ## CAP_SYS_NICE-keep path. The upstream SONAME ``cap`` is
    ## PascalCased to ``libCap`` per the libExpat / libZ / libGlib2
    ## precedent of preserving the canonical ``lib`` prefix while
    ## PascalCasing the SONAME body. v1 records the artifact only;
    ## the per-artifact build body lands in M9.L when the
    ## convention's make-spawn + install-glue closes.
    discard

  executable capsh:
    ## ``/sbin/capsh`` — the capability-shell debugger admin teams
    ## use to inspect capability sets at the command line (e.g.
    ## ``capsh --print``). v1 records the artifact only.
    discard

  executable getcap:
    ## ``/sbin/getcap`` — the file-capability inspector that prints
    ## the capability set attached to a binary (e.g.
    ## ``getcap /usr/bin/ping`` -> ``cap_net_raw+ep``). v1 records
    ## the artifact only.
    discard

  executable setcap:
    ## ``/sbin/setcap`` — the file-capability mutator that pins
    ## per-binary CAP_NET_BIND_SERVICE / CAP_NET_RAW etc without
    ## making the binary suid-root (e.g.
    ## ``setcap cap_net_bind_service=+ep /usr/bin/python3.11`` to let
    ## a Python script bind port 80 unprivileged). v1 records the
    ## artifact only.
    discard
