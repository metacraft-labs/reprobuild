## Shared Mode B autotools template for the macOS "sandbox tools" — the
## injectable, NON-SIP, drop-in replacements for the SIP-protected system
## binaries (``/bin/sh``, ``/bin/cat``, ``/usr/bin/*``) that a monitored
## process tree shells out to. See
## ``reprobuild-specs/Portable-Macos-Sandbox-Tools.milestones.org`` for the
## SIP/AMFI rationale (DYLD_INSERT_LIBRARIES is stripped for SIP binaries, and
## AMFI SIGKILLs a *copy* of a restricted platform binary on launch — so the
## drop-in must be a binary WE BUILD, not a copy).
##
## # Why this lives in its own ``recipes/sandbox-tools/`` project
##
## Per ``reprobuild-specs/Package-Model.md`` ("Concrete Package-Definition
## Module Shape" + "Projects And Third-Party Services"), a curated package
## *catalog* for a single deployment concern is the idiomatic unit. The
## ``recipes/packages/source/`` recipes already build these GNU tools, but they
## are tuned for the ReproOS / Linux desktop story (SELinux knobs, system
## libreadline, ~100-binary installs, GNU-tar assumptions). The macOS sandbox
## bundle has DIFFERENT requirements:
##
##   * PORTABILITY over features — every binary must link ONLY
##     ``/usr/lib/libSystem.B.dylib`` (no /nix/store refs, no extra dylibs) so
##     the bundle is relocatable and AMFI-safe. We therefore prefer the
##     in-tree/bundled deps (bash's own termcap, no system readline) and
##     ``--disable-nls`` / ``--disable-dependency-tracking`` to keep the link
##     surface minimal.
##   * macOS/clang compatibility — Apple clang defaults to C23, where implicit
##     function declarations are a hard ERROR. Several GNU 2020-era tarballs
##     (bash 5.2's bundled termcap, gnulib shims) still rely on implicit
##     declarations, so we pass ``CFLAGS=-Wno-implicit-function-declaration``
##     to restore the historical C89/C99 behaviour upstream assumed.
##
## Keeping the macOS-tuned set in its own project avoids regressing the Linux
## desktop recipes while sharing ONE Mode B template (this module) across the
## whole tool list — the DRY requirement.
##
## # Build flow (Mode B, per C-Cpp-Autotools.md §"Mode B — Crude fallback")
##
## Each recipe declares a ``fetch:`` block (vendored upstream RELEASED tarball,
## referenced by a ``file:./vendor/...`` URL so the build is offline-
## reproducible and uses the tarball's committed ``configure`` — avoiding the
## io-mon ``autom4te`` bug on the repo-checkout shape). The ``build:`` body
## calls ``sandboxAutotoolsPackage`` below, which delegates to the stdlib
## ``autotools_package`` constructor:
##
##     ./configure --prefix=/usr <opts> CFLAGS=-Wno-implicit-function-declaration
##     make -j<n>
##     make DESTDIR=<stage> install
##
## and the convention lifts the artifacts from ``<stage>/usr/bin``. The
## per-recipe ``executable`` blocks name the binaries the artifact registry
## should expose.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

const
  ## Apple clang defaults to C23; restore the implicit-declaration leniency the
  ## 2020-era GNU release tarballs were written against (bash's bundled
  ## ``lib/termcap/tparam.c`` calls ``write`` without a prototype, etc.).
  SandboxCFlags* = "CFLAGS=-Wno-implicit-function-declaration"

  ## PORTABILITY (libSystem-only invariant). The Nix clang cc-wrapper on Darwin
  ## injects ``-L<nix libiconv> -liconv`` (and similar) into EVERY link via
  ## ``NIX_LDFLAGS``. When the package's gnulib config compiles out the iconv
  ## calls (``am_cv_func_iconv=no``), nothing references those symbols — yet the
  ## linker still records a dead ``LC_LOAD_DYLIB`` for the nix ``libiconv.2.dylib``
  ## (Apple ld keeps ``-l`` libs as load commands even when unused). That stray
  ## /nix/store load command breaks relocatability (e.g. GNU grep linked nix
  ## libiconv while bash did not, purely by link-order luck).
  ##
  ## ``-Wl,-dead_strip_dylibs`` tells the linker to DROP any dylib load command
  ## whose symbols are never bound, so an injected-but-unreferenced nix dylib is
  ## removed and the binary stays libSystem-only. It is a safe no-op when every
  ## linked dylib is actually used (macOS provides iconv via libSystem, so no
  ## functionality is lost). Verified to turn grep's ``otool -L`` from
  ## "nix libiconv + libSystem" into "libSystem only".
  SandboxLdFlags* = "LDFLAGS=-Wl,-dead_strip_dylibs"

  ## Configure knobs shared by every sandbox tool, chosen for a MINIMAL,
  ## PORTABLE link surface (libSystem-only):
  ##   * ``--disable-dependency-tracking`` — drop automake's ``.deps/*.Po``
  ##     machinery (reprobuild captures deps itself; on macOS this also keeps
  ##     the recipe off the slow per-source probe path).
  ##   * ``--disable-nls`` — no gettext / libintl, so no extra dylib dependency
  ##     and no /usr/local libintl pickup.
  SandboxCommonConfigure*: seq[string] = @[
    "--disable-dependency-tracking",
    "--disable-nls",
  ]

proc sandboxAutotoolsPackage*(owningPackage: string;
                              executables: openArray[string];
                              extraConfigure: openArray[string] = [];
                              srcDir = "./src"): AutotoolsPackageResult
                              {.discardable.} =
  ## DRY Mode B builder for one sandbox tool. Wraps the stdlib
  ## ``autotools_package`` constructor with the portable-macOS defaults above
  ## and registers each named executable as a typed artifact so the convention
  ## layer + downstream bundle assembler know which binaries to expect.
  ##
  ## ``owningPackage`` is the recipe's ``package`` ident (e.g.
  ## ``"sandboxCoreutils"``); it scopes the auto-emitted fetch action + the
  ## artifact registry. ``executables`` is the binary set to register (the
  ## Mode B install always produces every binary the package builds; the
  ## registry just enumerates the load-bearing ones the bundle needs).
  ## ``extraConfigure`` carries per-tool flags (e.g. coreutils'
  ## ``--enable-no-install-program`` or bash's ``--without-bash-malloc``).
  setCurrentOwningPackageOverride(owningPackage)
  try:
    var opts: seq[string] = @[]
    for o in SandboxCommonConfigure: opts.add(o)
    for o in extraConfigure: opts.add(o)
    # ``CFLAGS=...`` / ``LDFLAGS=...`` are honoured by GNU ``configure`` as
    # positional variable-assignment arguments; placing them last keeps them
    # from being shadowed by an earlier ``--enable-*`` value. ``LDFLAGS`` carries
    # the ``-dead_strip_dylibs`` portability fix (see ``SandboxLdFlags``).
    opts.add(SandboxCFlags)
    opts.add(SandboxLdFlags)
    result = autotools_package(srcDir = srcDir, configureOptions = opts)
    for exe in executables:
      discard result.executable(exe)
  finally:
    clearCurrentOwningPackageOverride()
