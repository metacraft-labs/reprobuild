import repro_project_dsl

package `wasm-opt`:
  provisioning:
    nixPackage "nixpkgs#binaryen", executablePath = "bin/wasm-opt",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: the upstream `binaryen` distribution
    # (which ships `wasm-opt.exe` alongside the rest of the suite) via
    # ScoopInstaller/Main.
    scoopApp(bucket = "main", app = "binaryen",
      preferredVersion = ">=100", executablePath = "bin/wasm-opt.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: WebAssembly/binaryen GitHub Releases. archive
    # ships under a single top-level `binaryen-version_130/` directory
    # so stripComponents=1 flattens to the prefix root.
    tarball url = "https://github.com/WebAssembly/binaryen/releases/download/version_130/binaryen-version_130-x86_64-windows.tar.gz",
      sha256 = "cc09c874f4332d00aa32ab72745a9b98c9a172f795762f21d03e70638a3f7f4c",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/wasm-opt.exe",
      packageId = "binaryen@130",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:binaryen@130:sha256:cc09c874f4332d00aa32ab72745a9b98c9a172f795762f21d03e70638a3f7f4c"
    # Linux x86_64: WebAssembly/binaryen GitHub Releases. Archive ships
    # under a single top-level `binaryen-version_130/` directory so
    # stripComponents=1 flattens to the prefix root.
    tarball url = "https://github.com/WebAssembly/binaryen/releases/download/version_130/binaryen-version_130-x86_64-linux.tar.gz",
      sha256 = "0a18362361ad05465118cd8eeb72edaeec89de6894bc283576ef4e07aa3babcc",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/wasm-opt",
      packageId = "binaryen@130",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:binaryen@130:linux:sha256:0a18362361ad05465118cd8eeb72edaeec89de6894bc283576ef4e07aa3babcc"
