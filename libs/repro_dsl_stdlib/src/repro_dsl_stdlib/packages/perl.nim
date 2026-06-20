## DSL-port M9.R.10a — stdlib provisioning stub for ``perl``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
##
## ``perl`` surfaces on the wayland from-source chain via
## ``wayland → gcc → binutils → perl`` (binutils' autotools driver +
## the various ``.pl`` helpers under ``binutils-2.43/`` invoke perl at
## configure + build time). The widening adds scoop (Windows Strawberry
## Perl via the ScoopInstaller/Main ``perl`` manifest) + the GNU
## upstream tarball so the resolver lands on the same perl across
## hosts.
##
## sha256 cross-checked against nixpkgs's ``pkgs/development/
## interpreters/perl/default.nix`` (version 5.42.0).

import repro_project_dsl

package `perl`:
  provisioning:
    nixPackage "nixpkgs#perl", executablePath = "bin/perl",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows: ScoopInstaller/Main ships StrawberryPerl under the
    # ``perl`` manifest; the realized prefix carries ``perl\bin\perl.exe``.
    scoopApp(bucket = "main", app = "perl",
      preferredVersion = ">=5", executablePath = "perl/bin/perl.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: cpan.org upstream release tarball. Cross-platform
    # — the perl source tree ships ``Configure`` + ``Makefile.SH``;
    # Windows hosts that opt into the tarball channel (rare — Scoop is
    # the conventional Windows route) fall through to MSYS2's perl.
    #
    # **executablePath**: The resolver requires this file to exist + be
    # executable post-extract. Perl's source tarball ships ``Configure``
    # (capitalised — perl's bespoke autoconf-replacement) at the root
    # with +x; pointing at it lets the resolver succeed so the chain
    # advances past tool identity resolution. The convention layer
    # drives ``./Configure -des && make && make install`` at build time
    # to produce ``./perl``. M9.R.11.1 follow-up: surface ``bin/perl``
    # once the from-source convention's install glue is wired, or
    # migrate to a prebuilt Strawberry/Active Perl bundle.
    tarball url = "https://www.cpan.org/src/5.0/perl-5.42.0.tar.xz",
      sha256 = "e093ef184d7f9a1b9797e2465296f55510adb6dab8842b0c3ed53329663096dc",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "Configure",
      packageId = "perl@5.42.0",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:perl@5.42.0:sha256:e093ef184d7f9a1b9797e2465296f55510adb6dab8842b0c3ed53329663096dc"
