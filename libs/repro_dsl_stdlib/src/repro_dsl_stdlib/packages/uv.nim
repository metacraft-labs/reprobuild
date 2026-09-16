## ``uv`` — astral-sh/uv Python package manager standalone binary.
##
## Used by the codetracer-python-recorder workflow to bootstrap
## ``maturin`` + ``pytest`` into a workspace-local tool dir without
## touching the system Python (and as the PEP 517 driver for
## ``uv pip install`` / ``uv tool install``).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package uv:
  provisioning:
    nixPackage "nixpkgs#uv", executablePath = "bin/uv",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: astral-sh/uv ``uv-x86_64-pc-windows-msvc.zip`` ships
    # ``uv.exe`` + ``uvx.exe`` flat at the archive root (no inner
    # directory).
    #
    # MR13 (2026-06): bumped 0.5.7 -> 0.9.28. The 0.5.7 binary segfaulted
    # on Windows during the ``uv tool install`` PATH-print/cleanup step
    # (clean-shell ``repro build`` exited 139 after maturin.exe was
    # already extracted to ``.repro/uv-tools/bin/``). 0.7.x is the first
    # series with the stability fix; 0.9.28 is the last patch of that
    # series.
    #
    # NOTE: independent from the DIY env's ``UV_VERSION`` in
    # ``D:\m\dev\windows\toolchain-versions.env`` — that path provisions
    # uv via ``ensure-uv.ps1`` outside the repro store and bumps on its
    # own cadence.
    tarball url = "https://github.com/astral-sh/uv/releases/download/0.9.28/uv-x86_64-pc-windows-msvc.zip",
      sha256 = "9cb567fcd92f31431220ce620787043b946c30b9bb46ca213780e5ef471453be",
      archiveType = "zip",
      executablePath = "uv.exe",
      packageId = "uv@0.9.28",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:uv@0.9.28:sha256:9cb567fcd92f31431220ce620787043b946c30b9bb46ca213780e5ef471453be"
    # Windows aarch64. Upstream has shipped this slice for a while; it was
    # absent here only because nothing had asked for it. Agent Harbor's
    # toolchain pins carry its digest too, and both Windows digests in this
    # block match that independently harvested file exactly.
    tarball url = "https://github.com/astral-sh/uv/releases/download/0.9.28/uv-aarch64-pc-windows-msvc.zip",
      sha256 = "081703fa19ae05a49f486f97468f7792e1cdacda403a091b151af7f5bd6f4595",
      archiveType = "zip",
      executablePath = "uv.exe",
      packageId = "uv@0.9.28",
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:uv@0.9.28:windows-aarch64:sha256:081703fa19ae05a49f486f97468f7792e1cdacda403a091b151af7f5bd6f4595"
    # Linux x86_64: astral-sh/uv ships a glibc tarball that contains
    # `uv` + `uvx` under a single `uv-x86_64-unknown-linux-gnu/`
    # top-level directory. stripComponents=1 flattens to the prefix
    # root so the binaries sit at `<prefix>/uv` and `<prefix>/uvx`.
    tarball url = "https://github.com/astral-sh/uv/releases/download/0.9.28/uv-x86_64-unknown-linux-gnu.tar.gz",
      sha256 = "66ad1822dd9cf96694b95c24f25bc05cff417a65351464da01682a91796d1f2b",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "uv",
      packageId = "uv@0.9.28",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:uv@0.9.28:linux:sha256:66ad1822dd9cf96694b95c24f25bc05cff417a65351464da01682a91796d1f2b"
    # macOS aarch64: astral-sh/uv ships a native Apple Silicon tarball
    # that contains `uv` + `uvx` under a single `uv-aarch64-apple-darwin/`
    # top-level directory. stripComponents=1 flattens to the prefix
    # root so the binaries sit at `<prefix>/uv` and `<prefix>/uvx`.
    tarball url = "https://github.com/astral-sh/uv/releases/download/0.9.28/uv-aarch64-apple-darwin.tar.gz",
      sha256 = "12163fe09eb292d3ad1ea0f132a84485c902e2ff360d57562bf676e6615fcba0",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "uv",
      packageId = "uv@0.9.28",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:uv@0.9.28:macos-aarch64:sha256:12163fe09eb292d3ad1ea0f132a84485c902e2ff360d57562bf676e6615fcba0"
