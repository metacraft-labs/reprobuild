## GM4b: every archive realization of ``ruby`` is a ``tarball`` statement
## in the ``provisioning:`` block below. The M67 ``rubyCatalog``
## (``VersionedProvisioning``) record that once sat beside it — the
## rubyinstaller 4.0.5-1 archives harvested from ScoopInstaller/Main —
## was merged into those statements and removed. Its x86_64-windows
## archive follows the in-package rubyinstaller 3.3.5-1 archive for the
## same target, so it is selected by pinning 4.0.5-1. The harvester's
## ``--bin-default`` invocation was:
##   --bin-default "ruby=ruby.exe,gem.cmd,bundle.cmd,rake.cmd,irb.cmd"
## which synthesizes candidate executables from the manifest's
## ``env_add_path`` (``bin`` + ``gems\bin``).
##
## **M3 note (Realize-Closure-And-Catalog-Expansion spec).** ruby's
## harvest is byte-identical between the pre-M3 baseline and the M3
## re-harvest in archive format + URL + sha — the URL is a clean ``.7z``
## (the M64 basic 7z extraction already shipped). The
## manifest's ``post_install`` (``gem install rake``) needs a realized
## ruby prefix + network and is OUT of M3 scope (deferred to a future
## ``bundler``/``gem`` realize hook).
##
## **Executable-list divergence from the harvester.** The harvester
## cross-product synthesizes 10 candidate executable entries from the
## env_add_path (``bin`` + ``gems\bin``) and the --bin-default list
## (ruby + gem + bundle + rake + irb). Reality on the rubyinstaller
## 4.0.5-1 archive: ``bin/ruby.exe``, ``bin/gem.cmd``, ``bin/irb.cmd``
## ship at extraction time; ``bundle.cmd`` + ``rake.cmd`` are gem-
## installed by Scoop's ``post_install`` (``gem install rake``) +
## downstream by the user (``gem install bundler``). The ``gems/`` dir
## is also a runtime location, not present at extract time. We trim
## the list to the binaries that actually exist post-extract so the
## realize loop's bin-existence sanity check passes. M3 live smoke
## verifies: ``ruby --version`` returns 4.0.5p1 cleanly from the
## extracted prefix.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M67 harvest).
# ---------------------------------------------------------------------------

package ruby:
  provisioning:
    nixPackage "nixpkgs#ruby", executablePath = "bin/ruby",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # MR2 Windows: rubyinstaller2 portable 7z for Ruby 3.3.5-1. Inner
    # dir ``rubyinstaller-3.3.5-1-x64/`` flattens via stripComponents=1
    # so ``bin/ruby.exe``, ``bin/gem.cmd``, ``bin/irb.cmd``, plus the
    # ``lib/``, ``include/`` and ``msys64/`` trees sit at the prefix
    # root. sha256 was computed by downloading the asset and running
    # ``sha256sum`` — the upstream release page does not publish a
    # SHASUMS file (cf. nodejs.org). Linux/macOS hosts continue to use
    # ``nixpkgs#ruby`` above; rubyinstaller2 only ships Windows builds.
    tarball url = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-3.3.5-1/rubyinstaller-3.3.5-1-x64.7z",
      sha256 = "7b1715e464ce750c171d53b5191d549a599d07befb0f54fb56aa785e3f25ba8d",
      archiveType = "7z",
      stripComponents = 1,
      executablePath = "bin/ruby.exe",
      packageId = "ruby@3.3.5-1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:ruby@3.3.5-1:sha256:7b1715e464ce750c171d53b5191d549a599d07befb0f54fb56aa785e3f25ba8d",
      version = "3.3.5-1"
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-4.0.5-1/rubyinstaller-4.0.5-1-x64.7z",
      sha256 = "74e31613fc71e6e23431dfc4d8b6ec2818a4dc1fd16e0983b074144c16719c8b",
      archiveType = "7z",
      executablePath = "bin/ruby.exe",
      extraExecutable = "bin/gem.cmd",
      extraExecutable = "bin/irb.bat",
      version = "4.0.5-1",
      packageId = "ruby@4.0.5-1",
      extractPath = "rubyinstaller-4.0.5-1-x64",
      env = "GEM_HOME=${prefix}\\gems",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-4.0.5-1/rubyinstaller-4.0.5-1-arm.7z",
      sha256 = "c7c6bcd0b070bf7c2e0c03e70fb9754d022b8a216ebc4befab880874c6180b51",
      archiveType = "7z",
      executablePath = "bin/ruby.exe",
      extraExecutable = "bin/gem.cmd",
      extraExecutable = "bin/irb.bat",
      version = "4.0.5-1",
      packageId = "ruby@4.0.5-1",
      extractPath = "rubyinstaller-4.0.5-1-arm",
      env = "GEM_HOME=${prefix}\\gems",
      cpu = "aarch64",
      os = "windows"
