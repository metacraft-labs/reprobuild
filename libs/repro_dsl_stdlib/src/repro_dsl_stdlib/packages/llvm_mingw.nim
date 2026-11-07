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
