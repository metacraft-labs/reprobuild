## ``uv`` — astral-sh/uv Python package manager standalone binary.
##
## Used by the codetracer-python-recorder workflow to bootstrap
## ``maturin`` + ``pytest`` into a workspace-local tool dir without
## touching the system Python (and as the PEP 517 driver for
## ``uv pip install`` / ``uv tool install``).

import repro_project_dsl

package uv:
  provisioning:
    nixPackage "nixpkgs#uv", executablePath = "bin/uv",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows: astral-sh/uv ``uv-x86_64-pc-windows-msvc.zip`` ships
    # ``uv.exe`` + ``uvx.exe`` flat at the archive root (no inner
    # directory).
    #
    # MR13 (2026-06): bumped 0.5.7 -> 0.7.12. The 0.5.7 binary segfaulted
    # on Windows during the ``uv tool install`` PATH-print/cleanup step
    # (clean-shell ``repro build`` exited 139 after maturin.exe was
    # already extracted to ``.repro/uv-tools/bin/``). 0.7.x is the first
    # series with the stability fix; 0.7.12 is the last patch of that
    # series.
    #
    # NOTE: independent from the DIY env's ``UV_VERSION`` in
    # ``D:\m\dev\windows\toolchain-versions.env`` — that path provisions
    # uv via ``ensure-uv.ps1`` outside the repro store and bumps on its
    # own cadence.
    tarball url = "https://github.com/astral-sh/uv/releases/download/0.7.12/uv-x86_64-pc-windows-msvc.zip",
      sha256 = "2cf29c8ffaa2549aa0f86927b2510008e8ca3dcd2100277d86faf437382a371b",
      archiveType = "zip",
      executablePath = "uv.exe",
      packageId = "uv@0.7.12",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:uv@0.7.12:sha256:2cf29c8ffaa2549aa0f86927b2510008e8ca3dcd2100277d86faf437382a371b"
    # Linux x86_64: astral-sh/uv ships a glibc tarball that contains
    # `uv` + `uvx` under a single `uv-x86_64-unknown-linux-gnu/`
    # top-level directory. stripComponents=1 flattens to the prefix
    # root so the binaries sit at `<prefix>/uv` and `<prefix>/uvx`.
    tarball url = "https://github.com/astral-sh/uv/releases/download/0.7.12/uv-x86_64-unknown-linux-gnu.tar.gz",
      sha256 = "735891fb553d0be129f3aa39dc8e9c4c49aaa76ec17f7dfb6a732e79a714873a",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "uv",
      packageId = "uv@0.7.12",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:uv@0.7.12:linux:sha256:735891fb553d0be129f3aa39dc8e9c4c49aaa76ec17f7dfb6a732e79a714873a"
