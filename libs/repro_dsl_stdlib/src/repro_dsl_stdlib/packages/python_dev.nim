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
    # Linux x86_64: same astral-sh/python-build-standalone install_only
    # tarball pinned to the same (3.12.13, build 20260610) pair. Ships
    # ``python/bin/python3`` plus the full Lib/ + include/ tree the PyO3
    # link step needs (the Linux variant uses the standard POSIX layout
    # under `python/bin/` rather than the Windows `python/` root).
    tarball url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260610/cpython-3.12.13+20260610-x86_64-unknown-linux-gnu-install_only.tar.gz",
      sha256 = "c218f50baeb2c06a30c2f03db5986b2bad6ab7c8a52faad2d5a59bda0677b93a",
      archiveType = "tar.gz",
      executablePath = "python/bin/python3",
      packageId = "python-dev@3.12.13+20260610",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:python-dev@3.12.13+20260610:linux:sha256:c218f50baeb2c06a30c2f03db5986b2bad6ab7c8a52faad2d5a59bda0677b93a"
    # macOS aarch64: same astral-sh/python-build-standalone install_only
    # tarball pinned to the same (3.12.13, build 20260610) pair — native
    # Apple Silicon build. Ships ``python/bin/python3`` plus the full
    # Lib/ + include/ tree the PyO3 link step needs (POSIX layout under
    # `python/bin/`, matching the Linux entry).
    tarball url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260610/cpython-3.12.13+20260610-aarch64-apple-darwin-install_only.tar.gz",
      sha256 = "e18ddd4c1e8f4a1d6c4590b37f423d76aec734447edc20ed08e93983d95f2132",
      archiveType = "tar.gz",
      executablePath = "python/bin/python3",
      packageId = "python-dev@3.12.13+20260610",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:python-dev@3.12.13+20260610:macos-aarch64:sha256:e18ddd4c1e8f4a1d6c4590b37f423d76aec734447edc20ed08e93983d95f2132"
