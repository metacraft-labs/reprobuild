import repro_project_dsl

package emcc:
  provisioning:
    nixPackage "nixpkgs#emscripten", executablePath = "bin/emcc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: Scoop's `emscripten` manifest unzips the
    # upstream `emsdk` source tree to the prefix root. Unlike a true
    # `bin/<tool>` install, a freshly-scooped emsdk is NOT a working
    # emcc until the operator runs `emsdk install latest` and
    # `emsdk activate latest` (multi-hundred-MB download of LLVM +
    # Node + Python). The DSL's executablePath surfaces the emsdk
    # entry script — invoking it requires the post-install bootstrap
    # the manifest doesn't run; operators should treat this as a
    # one-time setup step until reprobuild grows an emsdk activator.
    scoopApp(bucket = "main", app = "emscripten",
      preferredVersion = ">=3", executablePath = "emsdk.bat",
      requiresExecutionProfileChecksum = false)
    # Direct-download: emsdk source archive from GitHub. Same caveat as
    # the scoopApp entry above — the realized prefix carries the emsdk
    # tooling but not a working emcc until the operator runs
    # `emsdk install latest && emsdk activate latest`. The
    # executablePath surfaces `emsdk.bat`; downstream callers that need
    # `emcc` must rely on the post-activation PATH.
    tarball url = "https://github.com/emscripten-core/emsdk/archive/refs/tags/6.0.0.zip",
      sha256 = "57aa2e320cd852598034c4bf636ea8693b1be44882111686d71ab1468a3cff9f",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "emsdk.bat",
      packageId = "emsdk@6.0.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:emsdk@6.0.0:sha256:57aa2e320cd852598034c4bf636ea8693b1be44882111686d71ab1468a3cff9f"
    # Linux x86_64: emsdk source tarball (same project + version as the
    # Windows entry — emsdk's source archive is platform-agnostic; the
    # POSIX entry script is `emsdk` rather than `emsdk.bat`). Same
    # post-install caveat applies: the realized prefix carries the emsdk
    # tooling but not a working emcc until the operator runs
    # `./emsdk install latest && ./emsdk activate latest`.
    tarball url = "https://github.com/emscripten-core/emsdk/archive/refs/tags/6.0.0.tar.gz",
      sha256 = "85c35c690ff6747243cb439076835c2a870df8cc5e8d304fe0800c69f6f6e265",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "emsdk",
      packageId = "emsdk@6.0.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:emsdk@6.0.0:linux:sha256:85c35c690ff6747243cb439076835c2a870df8cc5e8d304fe0800c69f6f6e265"
    # macOS aarch64: identical emsdk source tarball as the Linux entry —
    # emsdk's source archive is platform-agnostic so the same tarball
    # serves every POSIX host. Same post-install caveat: the realized
    # prefix carries the emsdk tooling but not a working emcc until the
    # operator runs `./emsdk install latest && ./emsdk activate latest`
    # (the activator downloads the per-platform LLVM + Node + Python
    # toolchain, which IS Apple-Silicon-specific).
    tarball url = "https://github.com/emscripten-core/emsdk/archive/refs/tags/6.0.0.tar.gz",
      sha256 = "85c35c690ff6747243cb439076835c2a870df8cc5e8d304fe0800c69f6f6e265",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "emsdk",
      packageId = "emsdk@6.0.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:emsdk@6.0.0:macos-aarch64:sha256:85c35c690ff6747243cb439076835c2a870df8cc5e8d304fe0800c69f6f6e265"
