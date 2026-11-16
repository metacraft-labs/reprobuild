## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: gh-releases:mstorsjo/llvm-mingw
## Versions (newest-first): 20260519
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization harvested via ``--source
## gh-releases:mstorsjo/llvm-mingw --asset-pattern
## 'llvm-mingw-20260519-ucrt-ubuntu-22\.04-x86_64\.tar\.xz'
## --platform-os linux``. The Linux asset is ``tar.xz`` (vs. Windows
## ``zip``) and the inner dir is
## ``llvm-mingw-<tag>-ucrt-ubuntu-22.04-x86_64/`` (vs. the Windows
## ``llvm-mingw-<tag>-ucrt-x86_64/``). Binaries lack the .exe suffix.
## Built on Ubuntu 22.04 LTS (glibc 2.35); operators on older distros
## should fall back to the nix realization or a distro-side llvm install. Not
## strictly within the M9.5 spec's glibc-2.17 honest-scope target —
## documented here for the operator's awareness.
##
## windows/aarch64 (hand-added 2026-11-16): the native C toolchain of the
## windows-aarch64 leg, reprobuild-pm Distribution-And-Packaging.md §7.1, W1.
## The aarch64-HOSTED UCRT asset of release 20261104; its sha256 is the one
## GitHub publishes for the asset and is the same pin as
## ``LLVM_MINGW_WIN_ARM64_*`` in ``windows/toolchain-versions.env``. It
## carries ``gcc.exe``/``cc.exe`` driver names (clang target wrappers), which
## is what the engine's windows-aarch64 bootstrap C compiler invokes.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package `llvm-mingw`:
  provisioning:
    tarball url = "https://github.com/mstorsjo/llvm-mingw/releases/download/20260519/llvm-mingw-20260519-ucrt-x86_64.zip",
      sha256 = "72dbd6e64614e3b3401998992d1bd9c8ace29e74611d71c80309ea71c3fb26f9",
      archiveType = "zip",
      executablePath = "bin/clang.exe",
      extraExecutable = "bin/clang++.exe",
      extraExecutable = "bin/ld.lld.exe",
      version = "20260519",
      packageId = "llvm-mingw@20260519",
      extractPath = "llvm-mingw-20260519-ucrt-x86_64",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://github.com/mstorsjo/llvm-mingw/releases/download/20260519/llvm-mingw-20260519-ucrt-ubuntu-22.04-x86_64.tar.xz",
      sha256 = "a48f8c2801508272ccde64d87a26747ecc5306623d9a080a42ed80dc61f79fa2",
      archiveType = "tar.xz",
      # The primary must be a regular file; keep clang as the exposed alias.
      executablePath = "bin/clang-22",
      executableAlias = "clang",
      extraExecutable = "bin/clang++",
      extraExecutable = "bin/ld.lld",
      version = "20260519",
      packageId = "llvm-mingw@20260519",
      extractPath = "llvm-mingw-20260519-ucrt-ubuntu-22.04-x86_64",
      cpu = "x86_64",
      os = "linux"
    tarball url = "https://github.com/mstorsjo/llvm-mingw/releases/download/20261104/llvm-mingw-20261104-ucrt-aarch64.zip",
      sha256 = "7d7f8387a8706639b0b47a629d6e23f8b3ef9acce67e9832b8cd4c5bb2816eab",
      archiveType = "zip",
      executablePath = "bin/clang.exe",
      extraExecutable = "bin/clang++.exe",
      extraExecutable = "bin/gcc.exe",
      extraExecutable = "bin/ld.lld.exe",
      version = "20261104",
      packageId = "llvm-mingw@20261104",
      extractPath = "llvm-mingw-20261104-ucrt-aarch64",
      cpu = "aarch64",
      os = "windows"
