import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

package `llvm-objdump`:
  provisioning:
    nixPackage "nixpkgs#llvm", executablePath = "bin/llvm-objdump",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: the same tool from the llvm-mingw distribution
    # (packages/llvm_mingw.nim pins the x86_64 archive; the aarch64 digest is
    # the GitHub release asset digest of
    # https://github.com/mstorsjo/llvm-mingw/releases/tag/20260519).
    tarball url = "https://github.com/mstorsjo/llvm-mingw/releases/download/20260519/llvm-mingw-20260519-ucrt-x86_64.zip",
      sha256 = "72dbd6e64614e3b3401998992d1bd9c8ace29e74611d71c80309ea71c3fb26f9",
      archiveType = "zip",
      executablePath = "bin/llvm-objdump.exe",
      version = "20260519",
      packageId = "llvm-objdump@20260519",
      extractPath = "llvm-mingw-20260519-ucrt-x86_64",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://github.com/mstorsjo/llvm-mingw/releases/download/20260519/llvm-mingw-20260519-ucrt-aarch64.zip",
      sha256 = "7bb5e3c9964dc29555cababb55e69eea02a51e98e1240eb9513e6540c7bae0ea",
      archiveType = "zip",
      executablePath = "bin/llvm-objdump.exe",
      version = "20260519",
      packageId = "llvm-objdump@20260519",
      extractPath = "llvm-mingw-20260519-ucrt-aarch64",
      cpu = "aarch64",
      os = "windows"
