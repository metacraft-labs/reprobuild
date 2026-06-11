## NSIS — Nullsoft Scriptable Install System.
##
## Authoring tool for Windows installer executables. The
## ``makensis`` compiler is the primary entry point; CodeTracer's
## reprobuild recipe drives it from its ``windows-installer`` build
## action to wrap the staged ``CodeTracer-win/`` tree into
## ``CodeTracer-Setup.exe``.
##
## Provisioning fan-out:
##
## * ``nixPackage "nixpkgs#nsis"`` — Nix-capable hosts (Linux /
##   macOS). nixpkgs ships the cross-compiled makensis that can
##   target Windows from a non-Windows host.
## * ``scoopApp(bucket = "extras", app = "nsis", ...)`` — Windows
##   hosts that prefer Scoop. The manifest lives in the
##   ``ScoopInstaller/Extras`` bucket (Main does not carry NSIS).
## * ``tarball(...)`` — Windows hosts using
##   ``--tool-provisioning=tarball``. The upstream Sourceforge
##   archive ships under a single ``nsis-<ver>/`` top-level dir;
##   ``stripComponents = 1`` flattens it so the prefix root holds
##   ``bin/makensis.exe`` directly.

import repro_project_dsl

package nsis:
  provisioning:
    nixPackage "nixpkgs#nsis", executablePath = "bin/makensis",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows: ScoopInstaller/Extras bucket. The manifest already
    # exposes makensis via env_add_path = "bin"; the executablePath
    # below matches the on-disk layout after Scoop's flatten.
    scoopApp(bucket = "extras", app = "nsis",
      preferredVersion = ">=3", executablePath = "bin/makensis.exe",
      requiresExecutionProfileChecksum = false)
    # Windows: direct-download from Sourceforge. The 3.12 zip is the
    # same archive Scoop's `extras/nsis` manifest harvests from, but
    # consuming it via the tarball adapter keeps the realize step
    # inside reprobuild's content-addressed store.
    tarball url = "https://downloads.sourceforge.net/project/nsis/NSIS%203/3.12/nsis-3.12.zip",
      sha256 = "56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/makensis.exe",
      packageId = "nsis@3.12",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:nsis@3.12:sha256:56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f"

  executable makensis:
    cli:
      dependencyPolicy automaticMonitor

      call:
        # `makensis` scripts pass defines via -D<NAME>=<VALUE>.
        # codetracer's windows-installer action uses these to
        # propagate APP_VERSION / STAGING_DIR / OUT_FILE into the
        # NSIS preprocessor.
        flag defines is seq[string],
          alias = "-D",
          format = concat,
          repeated = true
        # `-NOCD` prevents makensis from changing to the script's
        # directory before compiling — load-bearing for any setup
        # that passes absolute paths to defines.
        boolFlag noCd is bool, alias = "-NOCD"
        # The script path is the sole positional argument.
        pos script is string,
          role = input,
          position = 0
