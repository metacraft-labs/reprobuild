## Stdlib provisioning for ``perl``.
##
## ``perl`` surfaces on the wayland from-source chain via
## ``wayland → gcc → binutils → perl`` (binutils' autotools driver +
## the various ``.pl`` helpers under ``binutils-2.43/`` invoke perl at
## configure + build time), and on Windows it is what OpenSSL's MSVC
## ``Configure`` needs: a native perl, not Git's MSYS one.
##
## Every realization below yields a runnable ``perl``:
##
## * ``nixPackage`` — nixpkgs' perl, the Nix-capable hosts' channel.
## * ``scoopApp`` — Strawberry Perl through ScoopInstaller/Main's ``perl``
##   manifest.
## * ``tarball`` — the Strawberry Perl portable zip, Windows only.
##
## **No Linux or macOS tarball, on purpose.** ``spec/CLI/build.md``
## (``--tool-provisioning=tarball``): "a package with no tarball for the
## host falls through to its from-source recipe" — for perl,
## ``reprobuild-packages/packages/source/perl``. Upstream publishes no
## relocatable binary perl for those hosts, and the cpan.org release is a
## source tree. That source tree used to be declared here as an
## ``os = "any"`` arm whose executable was ``Configure``, so tarball mode
## handed a configure script to every consumer that asked for a perl, and
## the fall-through to the from-source recipe never happened
## (reprobuild-pm/issues/
## 2026-10-20-stdlib-perl-tarball-realization-is-a-source-tree-not-a-perl.md).
## A source tree belongs in the from-source recipe, not in a ``tarball`` arm.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `perl`:
  provisioning:
    nixPackage "nixpkgs#perl", executablePath = "bin/perl",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: ScoopInstaller/Main ships StrawberryPerl under the
    # ``perl`` manifest; the realized prefix carries ``perl\bin\perl.exe``.
    scoopApp(bucket = "main", app = "perl",
      preferredVersion = ">=5", executablePath = "perl/bin/perl.exe",
      requiresExecutionProfileChecksum = false)
    # Windows x86_64: the Strawberry Perl PORTABLE zip — a complete,
    # relocatable perl (interpreter, core modules, and the bundled
    # mingw toolchain under ``c/`` that XS module builds use), unpacked
    # with no installer. The zip has no top-level wrapper directory: its
    # entries are ``perl/``, ``c/``, ``cpan/``, ``data/``, ``licenses/``,
    # ``win32/`` and a few files at the root, so ``stripComponents`` is 0
    # and the interpreter is ``perl/bin/perl.exe``.
    #
    # **sha256**: computed 2026-10-20 from the downloaded asset
    # (304765269 bytes) and checked against the digest GitHub publishes
    # for the release asset.
    #
    # **version**: ``5.42.3`` is the perl the zip carries; Strawberry's
    # own fourth component (``.1``, its packaging revision) stays in
    # ``packageId`` and the URL. Selection matches ``version`` against a
    # consumer's ``uses: "perl >=…"`` range as semver, which takes at
    # most three components, so writing ``5.42.3.1`` there would make
    # the arm unselectable by any versioned ``uses:``.
    tarball url = "https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_54231_64bit/strawberry-perl-5.42.3.1-64bit-portable.zip",
      sha256 = "6a081a811781c30aca51dbc036afd93092af91e3297901f02c17043795a10690",
      archiveType = "zip",
      stripComponents = 0,
      executablePath = "perl/bin/perl.exe",
      packageId = "strawberry-perl@5.42.3.1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:strawberry-perl@5.42.3.1:windows-x86_64:sha256:6a081a811781c30aca51dbc036afd93092af91e3297901f02c17043795a10690",
      version = "5.42.3"
    # Windows aarch64: the SAME x64 zip. Strawberry Perl publishes no
    # arm64 build; Windows 11 on ARM runs the x64 interpreter under its
    # built-in x64 emulation. That is adequate for perl as a build-script
    # interpreter (OpenSSL's ``Configure``, autotools helpers) and slow
    # for heavy perl work. A native arm64 perl replaces this arm when
    # one is published. The lock identity names the target so the two
    # arms stay distinguishable in a lock even though their bytes agree.
    tarball url = "https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_54231_64bit/strawberry-perl-5.42.3.1-64bit-portable.zip",
      sha256 = "6a081a811781c30aca51dbc036afd93092af91e3297901f02c17043795a10690",
      archiveType = "zip",
      stripComponents = 0,
      executablePath = "perl/bin/perl.exe",
      packageId = "strawberry-perl@5.42.3.1",
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:strawberry-perl@5.42.3.1:windows-aarch64:sha256:6a081a811781c30aca51dbc036afd93092af91e3297901f02c17043795a10690",
      version = "5.42.3"
