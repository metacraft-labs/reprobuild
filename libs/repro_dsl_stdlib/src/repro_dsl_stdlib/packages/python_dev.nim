## ``python-dev`` — CPython distribution with full C dev headers and
## import libraries (``include/`` + ``libs/python<ver>.lib``).
##
## Distinct from ``python3`` (which on Windows resolves to the official
## *embeddable* zip — interpreter only, no ``libs/`` directory, no
## ``include/``). PyO3 and any maturin-built extension links against
## ``python<ver>.lib`` at build time, so the embeddable distribution
## fails with::
##
##     LINK : fatal error LNK1181: cannot open input file 'python312.lib'
##
## The astral-sh/python-build-standalone tarball (the same standalone
## build uv + maturin consume internally) ships the full Python install
## (``python/python.exe`` + ``python/include`` + ``python/libs/`` +
## ``python/Lib/``) under a top-level ``python/`` directory.
##
## On Nix-capable hosts the upstream ``nixpkgs#python3`` is sufficient
## (Nix python ships the dev headers + libs already); the Windows /
## non-Nix-Linux path is the M7 reprobuild-store tarball described
## below.
##
## Replaces ``D:\m\dev\windows\ensure-python-dev.ps1`` for recipes that
## opt into reprobuild's tarball provisioning (the recorder recipe is
## the first consumer; legacy env.ps1 callers continue to use the
## ensure-script path until M9 cleanup retires it).

import repro_project_dsl

package `python-dev`:
  provisioning:
    # Linux / macOS: the standard nixpkgs Python ships the dev headers
    # alongside the interpreter under the same prefix; reuse it rather
    # than carving out a "python-dev" Nix package that doesn't exist.
    nixPackage "nixpkgs#python3", executablePath = "bin/python3",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows: astral-sh/python-build-standalone install_only tarball.
    # Top-level ``python/`` directory holds ``python.exe`` plus the
    # full Lib/ + include/ + libs/ tree the PyO3 link step needs.
    # Pin (3.12.13, build 20260610) mirrors the
    # PYTHON_DEV_VERSION/PYTHON_DEV_BUILD pair in
    # ``D:\m\dev\windows\toolchain-versions.env``.
    tarball url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260610/cpython-3.12.13+20260610-x86_64-pc-windows-msvc-install_only.tar.gz",
      sha256 = "f5e4d9f856567493776f3d1e832c939fbaba5dcbcc5e0492a82ecfceea83b316",
      archiveType = "tar.gz",
      executablePath = "python/python.exe",
      packageId = "python-dev@3.12.13+20260610",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:python-dev@3.12.13+20260610:sha256:f5e4d9f856567493776f3d1e832c939fbaba5dcbcc5e0492a82ecfceea83b316"
