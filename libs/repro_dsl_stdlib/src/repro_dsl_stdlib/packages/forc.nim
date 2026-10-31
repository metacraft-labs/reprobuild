## Forc -- the Fuel/Sway compiler driver.
##
## No ``nixpkgs#forc`` is available at the catalog-wide pinned
## nixpkgs rev; the metacraft-labs ``nix-blockchain-development``
## flake builds forc from source (FuelLabs/sway, pinned to
## ``v0.70.3``). The realization here pulls the matching upstream
## ``forc-binaries`` release tarballs so the recorder dev env stays
## self-contained on non-Nix hosts.
##
## ----------------------------------------------------------------------
## Windows: EXPLICITLY UNSUPPORTED (no tarball realization entry below).
## ----------------------------------------------------------------------
##
## FuelLabs/sway publishes Linux and macOS ``forc-binaries`` tarballs
## only; there is no Windows artefact upstream as of v0.70.3. See the
## upstream release pages for verification:
##   https://github.com/FuelLabs/sway/releases/tag/v0.70.3
##
## Building forc 0.70.3 from source on Windows fails at multiple
## distinct points and is not reliably reproducible:
##   * the ``Cargo.lock`` pins ``core2 0.4.0`` which was yanked from
##     crates.io;
##   * ``sway-core/src/debug_generation/dwarf.rs`` imports
##     ``std::os::unix::ffi::OsStringExt`` unconditionally (Unix-only);
##   * ``libssh2-sys`` (pulled transitively via the cargo-edit / git2
##     dependency graph) cannot locate ``libssh2.h`` headers under the
##     mingw-w64 toolchain shipped via reprobuild's gcc-winlibs realization.
##
## The deliberate omission of a Windows ``tarball`` realization causes
## the M65 adapter chain to surface a structured
## ``brePlatformNotSupported`` step from home archive realizer when a recorder
## declares ``uses: "forc"`` on Windows. Recorders that need forc must
## gate the dependency with ``when not defined(windows):`` in their
## ``repro.nim`` (see ``codetracer-fuel-recorder/repro.nim``); on
## Windows the sway-compile test edges skip cleanly and the rest of the
## build proceeds.
##
## The release tarball bundles ``forc``, ``forc-fmt``, ``forc-lsp``,
## ``forc-deploy``, and ``forc-run`` together under a single
## ``forc-binaries/`` directory. declared executable list walks each binary
## via per-platform overrides because the tarball is flat (the
## inner ``forc-binaries/`` dir is the only nesting).

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package forc:
  provisioning:
    tarball url = "https://github.com/FuelLabs/sway/releases/download/v0.70.3/forc-binaries-linux_amd64.tar.gz",
      sha256 = "572a61acae22887e28b1f3222b98951ae4cf253cab1d6c5668f71aee239f07cc",
      archiveType = "tar.gz",
      executablePath = "forc-binaries/forc",
      extraExecutable = "forc-binaries/forc-fmt",
      extraExecutable = "forc-binaries/forc-lsp",
      extraExecutable = "forc-binaries/forc-deploy",
      extraExecutable = "forc-binaries/forc-run",
      version = "0.70.3",
      packageId = "forc@0.70.3",
      cpu = "x86_64",
      os = "linux"
    tarball url = "https://github.com/FuelLabs/sway/releases/download/v0.70.3/forc-binaries-darwin_amd64.tar.gz",
      sha256 = "801ff4749eb8681229c8d4ce74142a8f206b9b0e79c626a3936beaec19f1646e",
      archiveType = "tar.gz",
      executablePath = "forc-binaries/forc",
      extraExecutable = "forc-binaries/forc-fmt",
      extraExecutable = "forc-binaries/forc-lsp",
      extraExecutable = "forc-binaries/forc-deploy",
      extraExecutable = "forc-binaries/forc-run",
      version = "0.70.3",
      packageId = "forc@0.70.3",
      cpu = "x86_64",
      os = "macos"
    tarball url = "https://github.com/FuelLabs/sway/releases/download/v0.70.3/forc-binaries-darwin_arm64.tar.gz",
      sha256 = "14d24cd9a42ff2499464592e13e4806aec3e3669768013e24cc98e2be0b573c2",
      archiveType = "tar.gz",
      executablePath = "forc-binaries/forc",
      extraExecutable = "forc-binaries/forc-fmt",
      extraExecutable = "forc-binaries/forc-lsp",
      extraExecutable = "forc-binaries/forc-deploy",
      extraExecutable = "forc-binaries/forc-run",
      version = "0.70.3",
      packageId = "forc@0.70.3",
      cpu = "aarch64",
      os = "macos"
