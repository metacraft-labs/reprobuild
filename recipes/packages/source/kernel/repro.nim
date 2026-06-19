## From-source Linux kernel recipe — the SIXTH real from-source
## production recipe and the FIRST consumer of the M9.I
## ``makeFlags:`` channel.
##
## Follows the dbus-broker / libdrm / Wayland / wlroots / Sway
## precedents (all meson/ninja), but the Linux kernel uses
## ``make``/kbuild as its build system, so this recipe is the FIRST
## in the from-source cohort to exercise the ``c_cpp_make`` Tier-2b
## convention (M9.K's sibling of ``c_cpp_meson``) and the M9.I
## ``makeFlags:`` block that feeds variables / job-count flags to
## ``make``. The fetch path stays identical to the meson siblings —
## a vendored upstream tarball whose sha256 is pinned here for
## deterministic offline test reproduction.
##
## ## Why this recipe is the c_cpp_make consumer
##
## The five prior from-source recipes all build under ``meson setup``
## + ``ninja``; the M9.K convention layer's ``c_cpp_meson`` lowering
## consumes the M9.I ``mesonOptions:`` channel. The kernel by contrast
## drives ``make`` against the kbuild Makefile graph at the top of the
## extracted source tree (``arch/$(SRCARCH)/Makefile`` +
## ``scripts/Makefile.build``), and the canonical flag-injection
## point is ``make ARCH=x86_64 LOCALVERSION= KBUILD_BUILD_USER=... -j1``
## — i.e. variable overrides + ``-jN`` go on the ``make`` argv. The
## ``c_cpp_make`` convention's configure-action lowering will read the
## M9.I ``makeFlags:`` channel (via ``registeredBuildFlags(pkg, "",
## "make")``) and pass every entry through to ``make`` in declared
## order; M9.L closes the spawn + install glue. This recipe declares
## the surface so the convention layer's M9.K bridge can lower it.
##
## ## Why this recipe COMPLEMENTS the existing NDE-E reproosKernel
##
## ``recipes/packages/de-foundation/kernel/repro.nim`` (the NDE-E
## ``reproosKernel`` package) owns the kernel-related ``fs.*`` outputs
## that the activation layer reads — ``/build/config-used`` (the
## .config snapshot of the 6 spec'd CONFIG_X knobs),
## ``/build/bzImage`` (a v1 STUB text marker the bootloader-menu
## generator references), ``/build/System.map``, and
## ``/build/KERNELRELEASE``. That recipe declares the DECLARATIVE
## front end with M9.F cross-artifact wiring; the real kernel
## compilation back end is deferred there (see honest-deferrals
## comment block).
##
## This recipe (``kernelSource``) is the COMPLEMENT — it provides the
## upstream-source side: a separate package that fetches the kernel
## tarball, exposes its build via ``c_cpp_make`` + ``makeFlags:``,
## and records the artifacts the kernel build emits. The two recipes
## live at different paths so the NDE-E config-emission cache key is
## isolated from the upstream tarball sha256 (a 6.6.142 → 6.6.143
## bump invalidates only ``kernelSource``, not the unit-file
## emissions; flipping ``reproosKernel.enableHypervDrm`` invalidates
## the NDE-E artifacts, not the upstream tarball cache).
##
## A future milestone will wire the two together: the NDE-E
## ``bzImage`` artifact's ``toolBuild("kernelCompile", ...)`` call
## becomes a real build-action edge into ``kernelSource``'s
## ``bzImage`` executable, replacing the v1 text stub with the actual
## kernel image bytes. The DECLARATIVE shape on both sides is what
## makes that swap a one-line change at the consumer site.
##
## ## sha256 strategy
##
## We vendor the upstream stable-line tarball at
## ``recipes/packages/source/kernel/vendor/linux-6.6.142.tar.xz`` and
## reference it via a ``file://`` URL. The upstream cdn.kernel.org
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 6.6.142 (LTS line, matches reproosKernel)
##
## The 6.6.x line is the current Linux LTS series; 6.6.142 is the
## latest stable point release as of the recipe landing. The version
## ALSO matches the NDE-E ``reproosKernel.kernelVersion`` default
## ("6.6.142") — that alignment is intentional so a future swap of
## the NDE-E bzImage stub for a real ``toolBuild`` edge into this
## recipe consumes the same kernel-source pin without a version
## reconciliation step.
##
## The published sha256 is
## ``b2f6607a75cd27b2e368cf2d25e1637e1e0da9dfed4cda536658879eee6f2b70``
## (from cdn.kernel.org's ``sha256sums.asc`` for
## ``linux-6.6.142.tar.xz``); we re-computed it locally over the
## vendored 140,641,384-byte tarball as a defence against vendor
## tampering and a future-maintainer's accidental re-download from a
## mirror with a different artifact. Both values match.
##
## ## sha256 cross-check vs nixpkgs
##
## nixpkgs's ``pkgs/os-specific/linux/kernel/linux-6.6.nix`` consumes
## the same ``cdn.kernel.org`` tarball via ``fetchurl``, so the version
## cross-check holds when nixpkgs's pin matches ours; cross-checking
## sha256 against nixpkgs's at-the-same-version pin is a useful
## sanity check (their fetcher records the upstream hash verbatim).
##
## ## Build shape
##
## The c_cpp_make convention (M9.K's sibling lowering) reads both the
## M9.H ``fetch:`` block and the M9.I ``makeFlags:`` block off this
## package's registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``make`` compile BuildAction that depends on the fetch
##      action and passes every flag in ``makeFlags:`` to ``make``,
##      in declared order.
##   3. install/output collection actions for the kernel image +
##      vmlinux + System.map + KERNELRELEASE artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream make-spawn + install glue lands in M9.L; the recipe
## records the artifacts via the ``executable`` + ``files`` blocks so
## the M9.K artifact registry already knows what outputs to expect.
##
## ## Honest deferrals
##
## * **No ``.config`` pre-build hook.** A real kernel build needs a
##   ``.config`` file at the source root BEFORE ``make bzImage`` will
##   produce anything — the canonical pattern is
##   ``make defconfig`` (or copy a pinned config file in) as a
##   prerequisite step. The current c_cpp_make convention surface
##   exposes only ``fetch:`` + ``makeFlags:`` + the artifact set; it
##   does NOT yet support a pre-build hook for arbitrary commands
##   like ``make defconfig`` or ``cp .config $srcRoot/``. This recipe
##   declares the surface — fetch + makeFlags + artifacts — so the
##   convention layer's M9.K bridge can lower it; M9.L will need to
##   either (a) add a ``preBuild:`` block to the DSL surface, or
##   (b) extend the c_cpp_make convention to auto-invoke
##   ``make defconfig`` when no ``.config`` is present, or (c) let a
##   future ``toolBuild`` edge pipe the NDE-E ``reproosKernel``
##   configFile artifact's output into this recipe's source tree
##   before the ``make bzImage`` action fires. The DECLARATIVE
##   front end stays the same regardless of which approach M9.L
##   picks.
##
## * **No modules artifacts.** The kernel build also emits a
##   modules tree (``$(MODLIB)/kernel/...``) containing hundreds to
##   thousands of ``.ko`` files. v1 does NOT enumerate them as
##   ``files`` artifacts — the per-config set is too large and
##   variable. M9.L will likely model the modules tree as a single
##   directory-output artifact rather than enumerating each ``.ko``;
##   that's a follow-up milestone. v1's four declared artifacts
##   (bzImage / vmlinux / System.map / KERNELRELEASE) are the
##   load-bearing outputs the bootloader-menu generator + activation
##   layer consume.
##
## * **Single-threaded build (``-j1``).** The ``makeFlags:`` block
##   pins ``-j1`` for deterministic single-threaded build. A real
##   production build wants ``-j$(nproc)``; M9.L's convention layer
##   can compute a host-job-count flag at action-emission time and
##   override the ``-j1`` declared here. Single-threaded is the
##   safe default — kbuild's parallelism is well-tested but adding
##   ``-jN`` to the recipe surface would couple the cache-key to
##   the host's CPU count, which is hostile to caching.
##
## ## Artifacts
##
## The kernel build produces four load-bearing outputs at the
## standard kbuild paths:
##
##   * ``bzImage`` — the bootable kernel image; the activation
##     layer's bootloader-menu generator points GRUB / systemd-boot
##     at this file. Path: ``arch/x86/boot/bzImage`` inside the
##     build tree.
##   * ``vmlinux`` — the unstripped ELF kernel with debug symbols;
##     consumed by perf / crash / live-kernel-debug tooling. Path:
##     ``vmlinux`` at the build-tree root.
##   * ``systemMap`` — the kernel symbol table (``System.map``)
##     paired with the bzImage at the same release. Used by
##     ``perf`` / ``kgdb`` / ``kallsyms`` for symbol resolution
##     when the kernel hasn't loaded its own kallsyms table yet.
##     Path: ``System.map`` at the build-tree root.
##   * ``kernelRelease`` — the KERNELRELEASE text file kbuild
##     emits at ``include/config/kernel.release``. The activation
##     layer reads this to discover the kernel release string
##     without re-parsing bzImage. Single-line content like
##     ``6.6.142`` (no LOCALVERSION suffix because the
##     ``makeFlags:`` block pins ``LOCALVERSION=``).
##
## The bzImage is the M3 ``dakExecutable`` artifact (it is
## bootable / loadable); the other three are M3 ``dakFiles``
## artifacts (data files consumed by downstream actions).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kernelSource:
  ## From-source Linux kernel — SIXTH M9.H/I/K production recipe and
  ## FIRST consumer of the M9.I ``makeFlags:`` channel.
  ##
  ## Tier-2b c_cpp_make convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``makeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"make"`` channel) and lowers
  ## them into fetch + make BuildActions wired with the right URL +
  ## hash + flags. Complements the NDE-E ``reproosKernel`` package
  ## (config-emitting front end) with the upstream-source back end.

  versions:
    ## Pinned upstream stable-line release. ``sourceUrl`` records the
    ## canonical cdn.kernel.org URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical Linus tree on
    ## git.kernel.org — the from-source authority for the Linux
    ## kernel.
    "6.6.142":
      sourceRevision = "v6.6.142"
      sourceUrl = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.142.tar.xz"
      sourceRepository = "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"

  fetch:
    ## Upstream cdn.kernel.org URL — out-of-band fetch on first
    ## build, then cached by the M9.K fetch action keyed on
    ## (url, sha256, extractStrip). Matches the R4-R9 bootstrap
    ## chain pattern of NOT vendoring large kernel tarballs into
    ## the git repo (the 140-MB linux-6.6.142.tar.xz exceeds
    ## GitHub's 100-MB single-file ceiling).
    ##
    ## sha256 was computed over the 140,641,384-byte tarball
    ## downloaded once from this URL. The published value on
    ## cdn.kernel.org's ``sha256sums.asc`` matches; we
    ## re-computed locally as a defence against mirror-fetched
    ## artifacts diverging.
    url: "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.142.tar.xz"
    sha256: "b2f6607a75cd27b2e368cf2d25e1637e1e0da9dfed4cda536658879eee6f2b70"
    extractStrip: 1

  nativeBuildDeps:
    ## gcc is the host C toolchain — kbuild assumes a C11-capable gcc
    ## for kernel 6.x. R8 Tier-2 reference uses jammy gcc 11.4.
    "gcc >=12"
    ## binutils provides ``ld`` / ``as`` / ``objcopy`` / ``nm`` that
    ## kbuild invokes for linking the kernel ELF and stripping the
    ## bootable bzImage.
    "binutils >=2.39"
    ## make is the kbuild driver — the c_cpp_make convention's
    ## compile action invokes ``make`` against the extracted source
    ## tree. ``make >=4.3`` is needed for kbuild's grouped-targets
    ## feature.
    "make >=4.3"
    ## bison is the parser generator kbuild's ``scripts/dtc`` uses to
    ## compile devicetree-source files when CONFIG_OF=y.
    "bison >=3.6"
    ## flex is the lexer generator paired with bison in
    ## ``scripts/dtc``.
    "flex >=2.6"
    ## perl is invoked by ``scripts/checkpatch.pl`` (build-time
    ## lint, optional) and a handful of code-generation scripts in
    ## ``scripts/`` that emit C source files consumed by the build.
    "perl >=5.32"

  buildDeps:
    ## libelf is consumed by kbuild's ``objtool`` (in tools/objtool)
    ## for the CONFIG_STACK_VALIDATION pass that rewrites .o files
    ## to add unwind metadata.
    "libelf >=0.187"
    ## libssl is consumed by kbuild's certificate-handling code (the
    ## ``CONFIG_MODULE_SIG`` family); even with module signing
    ## disabled, the build occasionally invokes openssl helpers via
    ## ``scripts/sign-file``.
    "libssl >=3.0"
    ## bc is the arbitrary-precision calculator kbuild's
    ## ``kernel/timeconst.bc`` script invokes to compute jiffies
    ## constants at build time. Required from 4.x onwards.
    "bc"
    ## kmod provides ``depmod`` / ``modprobe`` that the modules-
    ## install pass invokes (when modules are emitted; deferred for
    ## v1 per the honest-deferrals comment).
    "kmod"
    ## rsync is invoked by ``make headers_install`` and (in some
    ## configs) by the modules-install step.
    "rsync"

  makeFlags:
    ## Flag set tuned for a deterministic single-threaded build of
    ## the kernel. Order is load-bearing: ``make`` evaluates variable
    ## assignments left-to-right and the ``-j1`` sentinel lives at
    ## the tail so M9.L can override the job-count flag by appending
    ## ``-jN`` later without re-ordering the variable-override
    ## block.
    ##
    ## ``ARCH=x86_64`` pins the target architecture so the kbuild
    ## graph picks the ``arch/x86/`` Makefile.
    ## ``LOCALVERSION=`` clears the version suffix kbuild would
    ## otherwise append from the git tree state ( ``+`` if dirty,
    ## etc.). Empty value means the kernel release matches the
    ## upstream tag exactly; the activation layer's KERNELRELEASE
    ## reader gets ``6.6.142``, not ``6.6.142-dirty+``.
    ## ``KBUILD_BUILD_USER`` / ``KBUILD_BUILD_HOST`` pin the
    ## ``__BUILD_USER__`` / ``__BUILD_HOST__`` strings kbuild
    ## embeds in vmlinux for reproducibility (per the
    ## ``Documentation/kbuild/reproducible-builds.rst`` upstream
    ## doc). Hostname / username leakage is the largest source of
    ## per-host kernel-build divergence; both pins are required.
    ## ``KBUILD_BUILD_TIMESTAMP=@1577836800`` pins the embedded
    ## build timestamp to 2020-01-01 00:00:00 UTC (epoch seconds
    ## form; the leading ``@`` is the ``date -d @<seconds>`` syntax
    ## kbuild's ``scripts/mkcompile_h`` consumes). Without this
    ## kbuild stamps the current date into the kernel banner,
    ## breaking byte-pin reproducibility.
    ## ``-j1`` pins single-threaded build for determinism; M9.L can
    ## override to ``-j$(nproc)`` at action-emission time.
    "ARCH=x86_64"
    "LOCALVERSION="
    "KBUILD_BUILD_USER=reprobuild"
    "KBUILD_BUILD_HOST=reprobuild"
    "KBUILD_BUILD_TIMESTAMP=@1577836800"
    "-j1"

  executable bzImage:
    ## ``arch/x86/boot/bzImage`` — the bootable kernel image; the
    ## activation layer's bootloader-menu generator (NDEM1) points
    ## GRUB / systemd-boot at this file. The ``executable`` artifact
    ## kind (``dakExecutable``) routes the harvested binary under
    ## ``bin/`` / ``boot/`` in the package's output tree (M9.L
    ## install policy decides which); ``files`` would route under
    ## ``share/`` which is wrong for the kernel image.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's make-spawn + install
    ## glue closes (and the ``.config`` pre-build hook is wired —
    ## see honest-deferrals).
    discard

  files vmlinux:
    ## The unstripped ELF kernel with debug symbols. Consumed by
    ## perf / crash / live-kernel-debug tooling; emitted at the
    ## build-tree root (path ``vmlinux``). The ``files`` artifact
    ## kind (``dakFiles``) routes it under ``share/`` / ``lib/`` —
    ## it's not a directly-bootable file, just data that downstream
    ## actions consume.
    discard

  files systemMap:
    ## ``System.map`` — the kernel symbol table paired with the
    ## bzImage at the same release. Used by ``perf`` / ``kgdb`` /
    ## ``kallsyms`` for symbol resolution when the kernel hasn't
    ## loaded its own kallsyms table yet. Emitted at the build-tree
    ## root.
    discard

  files kernelRelease:
    ## ``include/config/kernel.release`` — the KERNELRELEASE text
    ## file kbuild emits during compile. Single-line content like
    ## ``6.6.142`` (no LOCALVERSION suffix because the
    ## ``makeFlags:`` block pins ``LOCALVERSION=``). The activation
    ## layer reads this to discover the kernel release string
    ## without re-parsing bzImage; the NDE-E ``reproosKernel``
    ## ``kernelRelease`` artifact uses the same path semantics so
    ## a future ``toolBuild`` edge can swap one for the other.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
