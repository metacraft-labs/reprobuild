## Source-from-tarball iproute2 recipe — the FORTY-NINTH real
## from-source production recipe to exercise the M9.H/I/K trio.
## iproute2 is the canonical Linux networking-utilities userland —
## every ``ip`` / ``tc`` / ``ss`` / ``bridge`` call on every modern
## Linux distribution flows through the netlink ABI this recipe lifts.
##
## ## Why iproute2 matters for the v1 desktop story
##
## iproute2 is the modern replacement for the deprecated net-tools
## suite (ifconfig / route / netstat / arp). The binaries this recipe
## registers are the load-bearing surface every NetworkManager
## connection-up event, every wg-quick VPN session, every container-
## runtime network namespace, and every sysadmin network diagnostic
## flows through:
##
##   * ``ip`` is the canonical link / address / route / rule
##     manipulator. NetworkManager's dispatcher hooks shell into
##     ``ip route add`` for static-route configuration; systemd-networkd
##     uses libnl directly but shares the netlink ABI ``ip`` drives;
##     containerd / podman shell into ``ip link add veth ...`` for
##     network-namespace plumbing.
##   * ``tc`` is the traffic-control CLI; QoS policies, bandwidth caps,
##     and the FQ/CoDel default-queue setup all flow through it.
##   * ``ss`` is the socket-statistics CLI (the modern ``netstat``
##     replacement); every sysadmin connectivity diagnostic uses it.
##   * ``bridge`` is the L2-bridge configuration CLI; libvirt / docker /
##     podman shell into it for VM + container network bridges.
##
## ## sha256 strategy
##
## We vendor the upstream 6.12.0 .tar.xz at
## ``recipes/packages/source/iproute2/vendor/iproute2-6.12.0.tar.xz``
## and reference it via a ``file://`` URL. The kernel.org release URL
## is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 6.12.0 (current upstream stable)
##
## iproute2 releases are cut on kernel.org, version-numbered to track
## the kernel release they ship alongside. 6.12.0 is the current stable
## in the 6.x line as of mid-2026 — anything ``>=5.10`` covers the
## NetworkManager + systemd-networkd + containerd / podman consumption
## (the 5.10 cut added the ``ip vrf`` subcommand the systemd-networkd
## VRF integration needs).
##
## sha256 = bbd141ef7b5d0127cc2152843ba61f274dc32814fa3e0f13e7d07a080bef53d9
##  (computed locally over the vendored ``iproute2-6.12.0.tar.xz``,
##  925,392 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape — Makefile-driven with a light configure wrapper
##
## iproute2's build is unusual: it uses a top-level Makefile (NO
## autotools — no ``configure.ac``, no ``Makefile.am``, no libtool) plus
## a hand-rolled ``./configure`` shell script that probes for libelf /
## libbpf / libcap / SELinux / netlink-libmnl and writes a
## ``config.mk`` that the Makefile sources. The flags below feed THAT
## hand-rolled script's option grammar — they are NOT autotools-style
## ``./configure`` flags from autoconf, but the convention layer's
## ``configureFlags:`` channel is the correct lowering surface per the
## task brief.
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the four artifacts via the ``executable``
## blocks so the M9.K artifact registry already knows what binaries to
## expect.
##
## ## Artifacts
##
## iproute2's Makefile + ``./configure`` build emits four load-bearing
## binaries from a single invocation:
##
##   * ``ip``     — ``/sbin/ip`` the link/address/route/rule CLI.
##   * ``tc``     — ``/sbin/tc`` the traffic-control CLI.
##   * ``ss``     — ``/usr/bin/ss`` the socket-statistics CLI.
##   * ``bridge`` — ``/sbin/bridge`` the L2-bridge CLI.
##
## The upstream binary names are already unambiguous and used bare.
## iproute2 ALSO ships a static-only ``libnetlink.a`` archive and
## several internal helper libraries, but v1 registers only the four
## externally-consumed binaries (the libraries are not installed
## library artifacts in the distro-packaging sense; they are build-
## internal).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--without-libelf`` — skip the libelf dependency that would
##                             otherwise pull in the BPF-bytecode JIT
##                             probe (``tc bpf object-file ...``). The
##                             v1 desktop's traffic-control configuration
##                             uses queueing disciplines + filters, not
##                             eBPF programs, so libelf would add a
##                             heavy dependency for an unused code path.
##                             A future eBPF-edition variant would flip
##                             ``--with-libelf`` and add the libelf
##                             ``uses:`` entry.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package iproute2Source:
  ## From-source iproute2 — forty-ninth M9.H/I/K production recipe.
  ## The canonical Linux networking-utilities userland: ``ip`` + ``tc``
  ## + ``ss`` + ``bridge`` all built from one Makefile + ``./configure``
  ## invocation. FIRST recipe in the corpus to drive a hand-rolled
  ## ``./configure`` shell-script wrapper (NOT autoconf-generated)
  ## paired with a raw top-level Makefile.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Four executable artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## kernel.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical mirror on
    ## git.kernel.org that hosts the iproute2 source tree.
    "6.12.0":
      sourceRevision = "v6.12.0"
      sourceUrl = "https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.12.0.tar.xz"
      sourceRepository = "https://git.kernel.org/pub/scm/network/iproute2/iproute2.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 925,392-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/iproute2/vendor/iproute2-6.12.0.tar.xz"
    sha256: "bbd141ef7b5d0127cc2152843ba61f274dc32814fa3e0f13e7d07a080bef53d9"
    extractStrip: 1

  uses:
    ## make is the build-system driver — iproute2's top-level Makefile
    ## is driven directly by ``make`` after the hand-rolled
    ## ``./configure`` wrapper writes ``config.mk``.
    "make"
    ## gcc is the host C toolchain — iproute2 is C99 + Linux-specific
    ## netlink headers.
    "gcc >=11"
    ## pkg-config is invoked by the hand-rolled ``./configure`` wrapper
    ## to probe for libmnl / libbsd / libcap / SELinux availability;
    ## even with ``--without-libelf`` pinned the pkg-config probes for
    ## the always-on dependencies (libmnl) need to succeed.
    "pkg-config"
    ## bison + flex are required by iproute2's ``tc`` build for the
    ## traffic-control rule-syntax parser (``tc/emp_ematch.y`` +
    ## ``tc/emp_ematch.l``).
    "bison"
    "flex"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. iproute2's hand-rolled ``./configure`` wrapper accepts a
    ## SMALLER option grammar than autoconf-generated configure scripts
    ## but the ``--without-X`` shape is preserved.
    ##
    ## ``--without-libelf`` skips the libelf dependency that would
    ##                       otherwise pull in the BPF-bytecode JIT
    ##                       probe (``tc bpf object-file ...``).
    "--without-libelf"

  executable ip:
    ## ``/sbin/ip`` — the link/address/route/rule CLI consumed by
    ## NetworkManager's dispatcher hooks (``ip route add`` for static
    ## routes), containerd / podman (``ip link add veth ...`` for
    ## network-namespace plumbing), and every sysadmin network
    ## diagnostic. v1 records the artifact only; the per-artifact build
    ## body lands in M9.L when the convention's make-spawn + install-
    ## glue closes.
    discard

  executable tc:
    ## ``/sbin/tc`` — the traffic-control CLI consumed by systemd-
    ## networkd's QoS configuration, libvirt's per-VM bandwidth caps,
    ## and the default FQ/CoDel queue-discipline setup on modern
    ## kernels. v1 records the artifact only.
    discard

  executable ss:
    ## ``/usr/bin/ss`` — the socket-statistics CLI (modern ``netstat``
    ## replacement) consumed by every sysadmin connectivity diagnostic
    ## + every container-runtime port-scan helper. v1 records the
    ## artifact only.
    discard

  executable bridge:
    ## ``/sbin/bridge`` — the L2-bridge configuration CLI consumed by
    ## libvirt's per-VM bridge setup, docker / podman's bridge-network
    ## driver, and systemd-networkd's ``Bridge=`` directive. v1 records
    ## the artifact only.
    discard
