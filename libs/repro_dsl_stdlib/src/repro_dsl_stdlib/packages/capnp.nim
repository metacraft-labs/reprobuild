import repro_project_dsl

package capnp:
  provisioning:
    nixPackage "nixpkgs#capnproto", executablePath = "bin/capnp",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: capnproto-tools-win32 via ScoopInstaller/Main.
    # Scoop unzips the upstream `capnproto-tools-win32-<ver>.zip` archive
    # without flattening, so capnp.exe lives at the nested
    # `capnproto-tools-win32-<ver>\capnp.exe` path. Pinning to 1.4.0 — the
    # version currently published in main.
    scoopApp(bucket = "main", app = "capnp",
      preferredVersion = ">=1",
      executablePath = "capnproto-tools-win32-1.4.0/capnp.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: capnproto.org's official Windows tools zip.
    # The archive ships TWO top-level directories (the C++ source tree
    # at `capnproto-c++-1.4.0/` plus the tools tree at
    # `capnproto-tools-win32-1.4.0/`), so flatten-via-stripComponents
    # cannot uniquely pick one. The executablePath references the
    # nested capnp.exe path inside the tools directory; the rest of
    # the archive stays at the prefix root unmodified.
    tarball url = "https://capnproto.org/capnproto-c++-win32-1.4.0.zip",
      sha256 = "8b5d72177d3e3ed4808baf43494f871ae05c7ba0bb7db7dcf0e92ba47136a407",
      archiveType = "zip",
      executablePath = "capnproto-tools-win32-1.4.0/capnp.exe",
      packageId = "capnp@1.4.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:capnp@1.4.0:sha256:8b5d72177d3e3ed4808baf43494f871ae05c7ba0bb7db7dcf0e92ba47136a407"
