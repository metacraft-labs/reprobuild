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
    #
    # **sha256**: corrected 2026-10-14 against the bytes cpan serves,
    # which agree with upstream's own published digest at
    # ``perl-5.42.0.tar.xz.sha256.txt``. The arm had carried
    # ``e093ef18…``, which matches nothing upstream has ever served, so
    # it could never realize: every attempt failed the digest check with
    # "all tarball archive URLs failed for perl". Nothing noticed,
    # because no check had ever fetched the archive — found by the
    # catalog conformance sweep this pin now answers to.
    tarball url = "https://www.cpan.org/src/5.0/perl-5.42.0.tar.xz",
      sha256 = "73cf6cc1ea2b2b1c110a18c14bbbc73a362073003893ffcedc26d22ebdbdd0c3",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "Configure",
      packageId = "perl@5.42.0",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:perl@5.42.0:sha256:73cf6cc1ea2b2b1c110a18c14bbbc73a362073003893ffcedc26d22ebdbdd0c3"
