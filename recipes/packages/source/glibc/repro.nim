## Source-from-tarball glibc recipe — the FORTY-SECOND real from-source
## production recipe to exercise the M9.H/I/K trio. glibc is the
## CANONICAL C library + dynamic linker every glibc-flavoured Linux
## userland binary links against. This is the **full glibc from
## source**, complementing the existing R5/R6 bootstrap glibc-2.42
## wrappers in ``recipes/bootstrap/tcc-chain/`` (which lift only the
## minimal subset needed to bootstrap a working compiler from hex0).
## The from-source recipe here builds the full library family
## (libc + libm + libpthread + libdl + librt + libcrypt + ld-linux) +
## ships the dynamic linker as an executable artifact.
##
## ## Why glibc matters for the v1 desktop story
##
## glibc is the foundation of every glibc-flavoured Linux userland.
## Every binary in /usr/bin links against libc.so.6, every floating-
## point-heavy binary links against libm.so.6, every threaded binary
## links against libpthread.so.0 (recently merged into libc.so.6 since
## glibc 2.34 but the SONAME stays for back-compat), every plugin-
## loading binary links against libdl.so.2, every clock-using binary
## links against librt.so.1, and every password-handling binary links
## against libcrypt.so.1. The dynamic linker (``ld-linux-x86-64.so.2``)
## is what the kernel hands every dynamically-linked ELF to at exec
## time. The musl-flavoured Linux userland is OUT OF SCOPE for v1 — the
## reproos-mvp target is a glibc Debian/Ubuntu-equivalent userland.
##
## ## Relationship to the R5/R6 bootstrap glibc
##
## The bootstrap glibc-2.42 wrappers under
## ``recipes/bootstrap/tcc-chain/`` lift only the minimal C library
## surface needed to bootstrap a working compiler from hex0 → tcc →
## gcc. They DO NOT ship libm / libpthread / libdl / librt / libcrypt
## and they DO NOT register the dynamic linker as a typed artifact.
## This recipe is the complement: the FULL glibc build that closes
## the foundation tier for the desktop story. The two coexist in the
## package universe — the bootstrap recipes are consumed by the lift
## chain only; everything downstream of the lifted gcc consumes the
## full glibc registered HERE.
##
## ## sha256 strategy
##
## We vendor the upstream 2.40 .tar.xz at
## ``recipes/packages/source/glibc/vendor/glibc-2.40.tar.xz`` and
## reference it via a ``file://`` URL. The ftp.gnu.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 2.40 (current upstream stable)
##
## glibc releases are cut on sourceware.org under tags of the form
## ``glibc-<X>.<Y>``. 2.40 is the current stable in the 2.4x line as of
## mid-2026 and the ABI is stable since the 2.34 cut — anything ``>=2.34``
## covers every consumer's pinning (the 2.34 cut is when libpthread +
## libdl + librt got folded into libc.so.6 but the per-library SONAMEs
## kept as compatibility forwarders).
##
## sha256 = 19a890175e9263d748f627993de6f4b1af9cd21e03f080e4bfb3a1fac10205a2
##  (computed locally over the vendored ``glibc-2.40.tar.xz``,
##  18,752,204 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions. NOTE: glibc's upstream build convention is to run
## ``./configure`` from a SEPARATE build directory (not in-tree); the
## M9.L convention layer will need to wire that knob when the per-
## artifact body lands. The recipe records the artifacts via the
## ``library`` / ``executable`` blocks so the M9.K artifact registry
## already knows what shared objects + the dynamic linker to expect.
##
## ## Artifacts
##
##   * ``libC`` (library)        — ``libc.so.6`` the canonical C runtime
##                                  library every glibc binary links
##                                  against.
##   * ``libM`` (library)        — ``libm.so.6`` the math library every
##                                  float-using binary links against.
##   * ``libPthread`` (library)  — ``libpthread.so.0`` the POSIX
##                                  threads library (since 2.34 a
##                                  back-compat stub forwarding into
##                                  libc.so.6 but still a separate
##                                  SONAME).
##   * ``libDl`` (library)       — ``libdl.so.2`` the dynamic-loader
##                                  ABI library (same 2.34 fold-in
##                                  caveat as libpthread).
##   * ``libRt`` (library)       — ``librt.so.1`` the POSIX real-time
##                                  library (clocks + timers +
##                                  message queues; same 2.34 fold-in
##                                  caveat).
##   * ``libCrypt`` (library)    — ``libcrypt.so.1`` the password-
##                                  hashing library (crypt() family).
##                                  Note: glibc 2.40 still ships libcrypt
##                                  in-tree but the longer-term plan
##                                  upstream is to migrate to libxcrypt
##                                  (out-of-tree); v1 uses the in-tree
##                                  build.
##   * ``ldso`` (executable)     — ``/lib64/ld-linux-x86-64.so.2`` the
##                                  dynamic linker the kernel hands every
##                                  dynamically-linked ELF at exec time.
##                                  Registered as an executable artifact
##                                  because it IS executable (the kernel
##                                  exec()'s it directly) — distinct from
##                                  the libraries that the linker
##                                  resolves.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``--disable-werror``           — turn off ``-Werror`` so a host
##                                       gcc version newer than the
##                                       tested-by-upstream set doesn't
##                                       fail the build on new warnings.
##   * ``--enable-bind-now``          — link the dynamic libraries with
##                                       ``BIND_NOW`` so symbol
##                                       resolution happens at load time
##                                       (eliminates the lazy-binding
##                                       JIT-shaped attack surface).
##   * ``--enable-stack-protector=strong``
##                                    — enable the gcc stack-smashing
##                                       protector at "strong" level
##                                       across glibc's own internal
##                                       code (modern hardening).
##   * ``--enable-kernel=4.19``       — set the minimum supported kernel
##                                       at 4.19 (LTS branch covering
##                                       every supported host); skip the
##                                       compatibility paths for older
##                                       kernels.
##   * ``--without-selinux``          — skip the libselinux dependency
##                                       (v1 desktop is non-SELinux; the
##                                       Plasma/GNOME stacks use
##                                       PolicyKit + AppArmor instead).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package glibcSource:
  ## From-source glibc — forty-second M9.H/I/K production recipe and
  ## the LARGEST single from-source artifact set (SEVEN artifacts:
  ## six libraries + one executable for the dynamic linker). Closes
  ## the foundation tier on the C-library side; the R5/R6 bootstrap
  ## glibc-2.42 wrappers under ``recipes/bootstrap/tcc-chain/``
  ## continue to cover the lift-from-hex0 chain while THIS recipe
  ## covers everything downstream of the lifted gcc.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical sourceware.org
    ## git mirror that hosts the glibc source tree.
    "2.40":
      sourceRevision = "glibc-2.40"
      sourceUrl = "https://ftp.gnu.org/gnu/glibc/glibc-2.40.tar.xz"
      sourceRepository = "https://sourceware.org/git/glibc.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 18,752,204-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/glibc/vendor/glibc-2.40.tar.xz"
    sha256: "19a890175e9263d748f627993de6f4b1af9cd21e03f080e4bfb3a1fac10205a2"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``.
    "autoconf"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — glibc requires a working
    ## C compiler + binutils for the assembly fast-paths in the
    ## memcpy / memset / strlen / atomic-builtin layer.
    "gcc >=11"
    ## binutils provides the assembler + linker glibc's own build
    ## invokes for its hand-rolled assembly translation units.
    "binutils >=2.39"
    ## bison is required by the build for the parser-generator passes
    ## in the localedef / iconv tools.
    "bison >=3.0"

  buildDeps:
    ## python is required by the build for the misc/syscall-list code
    ## generators glibc 2.x switched to in the 2.32 cut.
    "python >=3.9"
    ## Linux kernel headers — glibc's syscall layer pulls
    ## ``<linux/*>`` headers from the host kernel-headers package.
    "linux-headers >=4.19"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libC:
    ## ``libc.so.6`` — the canonical C runtime library every glibc
    ## binary links against. Since glibc 2.34 also absorbs the
    ## libpthread + libdl + librt + libutil + libanl ABIs into a single
    ## shared object; the separate SONAMEs (libpthread.so.0 etc.) ship
    ## as compatibility forwarders. v1 records the artifact only.
    discard

  library libM:
    ## ``libm.so.6`` — the math library every floating-point-heavy
    ## binary links against (sin / cos / sqrt / pow / exp / log /
    ## expm1 / log1p / atan2 / hypot / fma / round / floor / ceil).
    ## v1 records the artifact only.
    discard

  library libPthread:
    ## ``libpthread.so.0`` — the POSIX threads library. Since glibc
    ## 2.34 this is a back-compat stub forwarding into libc.so.6 but
    ## the SONAME stays for binary back-compat. v1 records the
    ## artifact only.
    discard

  library libDl:
    ## ``libdl.so.2`` — the dynamic-loader ABI library (dlopen /
    ## dlsym / dlclose / dlerror / dladdr). Same 2.34 fold-in caveat
    ## as libpthread — the SONAME ships as a back-compat forwarder.
    ## v1 records the artifact only.
    discard

  library libRt:
    ## ``librt.so.1`` — the POSIX real-time library (clock_gettime /
    ## clock_nanosleep / timer_create / shm_open / mq_*). Same 2.34
    ## fold-in caveat as libpthread + libdl. v1 records the artifact
    ## only.
    discard

  library libCrypt:
    ## ``libcrypt.so.1`` — the password-hashing library (crypt /
    ## crypt_r). Note: the longer-term upstream plan is to migrate
    ## to libxcrypt (out-of-tree) but v1 uses glibc 2.40's in-tree
    ## libcrypt. The libxcrypt migration would be a future per-distro
    ## variant. v1 records the artifact only.
    discard

  executable ldso:
    ## ``/lib64/ld-linux-x86-64.so.2`` — the dynamic linker the kernel
    ## hands every dynamically-linked ELF at exec time. Registered as
    ## an executable artifact because it IS executable (the kernel
    ## exec()'s it directly when the ELF interpreter field points at
    ## it); distinct from the libraries the linker itself resolves.
    ## v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("glibcSource")
    try:
      let opts = @[
        "--disable-werror",
        "--enable-bind-now",
        "--enable-stack-protector=strong",
        "--enable-kernel=4.19",
        "--without-selinux",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libC")
      discard pkg.library("libM")
      discard pkg.library("libPthread")
      discard pkg.library("libDl")
      discard pkg.library("libRt")
      discard pkg.library("libCrypt")
      discard pkg.executable("ldso")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
