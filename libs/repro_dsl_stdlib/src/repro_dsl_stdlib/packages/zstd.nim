## ``zstd`` -- Facebook's Zstandard compressor.
##
## On Linux/macOS the consumer is the recorder build path:
## ``codetracer_trace_writer_nim``'s build.rs Nim compile step needs
## ``zstd.h`` on the include path and the final cargo link step needs
## ``-lzstd``. nix provisioning supplies both via ``nixpkgs#zstd``'s
## ``dev`` + ``out`` outputs.
##
## On Windows the cargo crate ``zstd-sys`` (a transitive dep through
## ``zstd``/``zeekstd``) vendors libzstd from source and builds it with
## the active MSVC toolchain — see
## ``codetracer-trace-format/codetracer_trace_writer_nim/build.rs``
## which exports ``DEP_ZSTD_ROOT`` from that vendored build for the
## Nim FFI compile. The reprobuild ``zstd`` selector therefore only
## has to **satisfy the resolver** (Windows recorders declare
## ``uses: "zstd"`` for parity with the Linux dev shell); the tarball
## entry below is the upstream facebook/zstd v1.5.6 win64 release,
## which ships ``zstd.exe`` + ``dll/libzstd.dll`` + ``include/zstd.h``
## + ``static/libzstd_static.lib`` under a top-level
## ``zstd-v1.5.6-win64/`` directory. ``stripComponents = 1`` flattens
## that into the realized prefix so the standalone ``zstd.exe`` sits
## at the prefix root and ``include/`` / ``static/`` are reachable
## under ``${prefix}/include`` and ``${prefix}/static`` for any future
## build that wants to consume the prebuilt lib via ``ZSTD_DIR`` (the
## build.rs fallback path).

import repro_project_dsl

package zstd:
  provisioning:
    nixPackage "nixpkgs#zstd", executablePath = "bin/zstd",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows: facebook/zstd v1.5.6 win64 release. The zip's top-level
    # dir is ``zstd-v1.5.6-win64/`` containing ``zstd.exe`` (the CLI
    # the resolver probes), ``dll/libzstd.dll[.a]`` (runtime + import
    # lib), ``include/zstd.h`` (header), and ``static/libzstd_static.lib``
    # (static archive). ``stripComponents = 1`` flattens that wrapper
    # so the realized prefix is the layout the build.rs ``ZSTD_DIR``
    # fallback expects (``${prefix}/include/zstd.h`` +
    # ``${prefix}/static/libzstd_static.lib``).
    tarball url = "https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-v1.5.6-win64.zip",
      sha256 = "7b4eff6719990e38aca93a4844c2e86a1935090625c4611f7e89675e999c56cc",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "zstd.exe",
      packageId = "zstd@1.5.6",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:zstd@1.5.6:sha256:7b4eff6719990e38aca93a4844c2e86a1935090625c4611f7e89675e999c56cc"
