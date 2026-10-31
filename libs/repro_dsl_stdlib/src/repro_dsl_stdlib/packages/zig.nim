## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 0.16.0, 0.13.0
##
## M2 (hand-edited, 2026-05-31): the 0.13.0 version below is
## hand-merged to preserve the M44 zig-mode3 fixture pin (zig fixtures
## are pinned to 0.13.0 per M53 / M44, and a Zig pre-1.0 bump requires
## the M44 fixture audit per the env.ps1 comment). The HEAD 0.16.0
## version tracks ziglang.org's current stable; the 0.13.0 version backfills
## the ``ZIG_VERSION=0.13.0`` pin in ``windows/toolchain-versions.env``
## so a migrated home.nim resolves cleanly without forcing the M44
## fixture re-audit. URL + SHA-256 lifted from the Scoop bucket's
## ``zig.json`` at the 0.13.0 commit (cross-checked against
## ``windows/ensure-zig.ps1``'s hard-coded SHA-256 for the same asset
## — both match upstream ``ziglang.org/download/index.json``). 0.13.0 is
## the default: its statements come first (GM4b kept the retired
## catalog's default, its last entry), and 0.16.0 is selected by pinning
## it. The ``--version-history`` harvester walk reproduces both versions
## *modulo* this note.
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization to BOTH the 0.16.0 and 0.13.0 versions (Zig ships on
## ``ziglang.org/download/``, not GitHub Releases — the M7 gh-releases
## harvester doesn't apply). URLs + sha256s lifted from upstream's
## ``index.json``. The archive is ``tar.xz`` (vs. Windows ``zip``); the
## inner dir differs per release tagging convention
## (``zig-x86_64-linux-<ver>/`` for 0.16.0, ``zig-linux-x86_64-<ver>/``
## for 0.13.0); ``zig`` binary lacks .exe. Upstream Zig's Linux
## prebuilt is statically linked against musl on the x86_64 path —
## glibc floor is not a concern.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package zig:
  provisioning:
    tarball url = "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip",
      sha256 = "d859994725ef9402381e557c60bb57497215682e355204d754ee3df75ee3c158",
      archiveType = "zip",
      executablePath = "zig.exe",
      version = "0.13.0",
      packageId = "zig@0.13.0",
      extractPath = "zig-windows-x86_64-0.13.0",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://ziglang.org/download/0.13.0/zig-windows-aarch64-0.13.0.zip",
      sha256 = "95ff88427af7ba2b4f312f45d2377ce7a033e5e3c620c8caaa396a9aba20efda",
      archiveType = "zip",
      executablePath = "zig.exe",
      version = "0.13.0",
      packageId = "zig@0.13.0",
      extractPath = "zig-windows-aarch64-0.13.0",
      cpu = "aarch64",
      os = "windows"
    tarball url = "https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz",
      sha256 = "d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea",
      archiveType = "tar.xz",
      executablePath = "zig",
      version = "0.13.0",
      packageId = "zig@0.13.0",
      extractPath = "zig-linux-x86_64-0.13.0",
      cpu = "x86_64",
      os = "linux"
    tarball url = "https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip",
      sha256 = "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e",
      archiveType = "zip",
      executablePath = "zig.exe",
      version = "0.16.0",
      packageId = "zig@0.16.0",
      extractPath = "zig-x86_64-windows-0.16.0",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://ziglang.org/download/0.16.0/zig-aarch64-windows-0.16.0.zip",
      sha256 = "aee38316ee4111717900f45dd3130145c39289e105541d737eb8c5ed653c78ef",
      archiveType = "zip",
      executablePath = "zig.exe",
      version = "0.16.0",
      packageId = "zig@0.16.0",
      extractPath = "zig-aarch64-windows-0.16.0",
      cpu = "aarch64",
      os = "windows"
    tarball url = "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz",
      sha256 = "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
      archiveType = "tar.xz",
      executablePath = "zig",
      version = "0.16.0",
      packageId = "zig@0.16.0",
      extractPath = "zig-x86_64-linux-0.16.0",
      cpu = "x86_64",
      os = "linux"

  # zig as the C toolchain of a `cross_zig` target (Reprobuild-Standard-
  # Library.md §"`CrossTarget`" and step 4 of §"Worked Example:
  # Cross-Compilation"): `zig cc` is a clang driver carrying its own musl and
  # compiler-rt, and `zig ar` an LLVM archiver, for every target in
  # `adapters/cross_zig`'s table. `operations/compile`, `link` and `archive`
  # emit these when the active `CrossTarget` is a zig one; the adapter's
  # `cFlags` (`-target <zig triple> -mcpu=<cpu>`) arrive as `targetArgs`.
  # https://ziglang.org/learn/overview/#cross-compiling-is-a-first-class-use-case
  executable zig:
    cli:
      # Full capture for the same reasons as `packages/clang.nim`'s driver:
      # zig cc is clang, in process.
      dependencyPolicy automaticMonitor,
        captureBreadth = fullCapture

      subcmd "cc":
        boolFlag pic is bool, alias = "-fPIC"
        boolFlag debug3 is bool, alias = "-g3"
        boolFlag compileOnly is bool, alias = "-c"
        boolFlag shared is bool, alias = "-shared"
        boolFlag staticLink is bool, alias = "-static"
        flag includeDirs is seq[string],
          alias = "-I",
          format = concat,
          repeated = true
        flag libDirs is seq[string],
          alias = "-L",
          format = concat,
          repeated = true
        flag libs is seq[string],
          alias = "-l",
          format = concat,
          repeated = true
        flag defines is seq[string],
          alias = "-D",
          format = concat,
          repeated = true
        flag optimization is string,
          alias = "-O",
          format = concat
        flag standard is string,
          alias = "-std=",
          format = concat
        flag soname is string,
          alias = "-Wl,-soname,",
          format = concat
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        pos targetArgs is seq[string],
          position = 0,
          repeated = true
        pos sources is seq[string],
          position = 1,
          role = input,
          repeated = true

        outputs output

      subcmd "ar":
        pos modifiers is string,
          position = 0
        pos archive is string,
          position = 1,
          role = output
        pos objects is seq[string],
          position = 2,
          role = input,
          repeated = true

        outputs archive
