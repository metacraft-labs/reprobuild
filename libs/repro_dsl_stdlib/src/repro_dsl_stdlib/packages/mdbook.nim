import repro_project_dsl

package mdbook:
  provisioning:
    nixPackage "nixpkgs#mdbook", executablePath = "bin/mdbook",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: mdbook static binary via ScoopInstaller/Main.
    scoopApp(bucket = "main", app = "mdbook",
      preferredVersion = ">=0", executablePath = "mdbook.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: rust-lang/mdBook GitHub Releases. Single static
    # binary at the archive root.
    tarball url = "https://github.com/rust-lang/mdBook/releases/download/v0.5.3/mdbook-v0.5.3-x86_64-pc-windows-msvc.zip",
      sha256 = "6bf1019d15e4cfa24d25d3a8571384ba1c703ca58029aac29b7c490f57e3ab85",
      archiveType = "zip",
      executablePath = "mdbook.exe",
      packageId = "mdbook@0.5.3",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:mdbook@0.5.3:sha256:6bf1019d15e4cfa24d25d3a8571384ba1c703ca58029aac29b7c490f57e3ab85"
    # Linux x86_64: rust-lang/mdBook GitHub Releases. musl static
    # binary; archive ships `mdbook` flat at the root.
    tarball url = "https://github.com/rust-lang/mdBook/releases/download/v0.5.3/mdbook-v0.5.3-x86_64-unknown-linux-musl.tar.gz",
      sha256 = "dfb86d8e20a3fed91bf549aa450b9d7f46a275b700292e050cdfd3171732e7fd",
      archiveType = "tar.gz",
      executablePath = "mdbook",
      packageId = "mdbook@0.5.3",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:mdbook@0.5.3:linux:sha256:dfb86d8e20a3fed91bf549aa450b9d7f46a275b700292e050cdfd3171732e7fd"
