## DSL-port M9.R.15q.5.7 — stdlib provisioning stub for ``attica``.
##
## Attica is the KDE Open Collaboration Services (OCS) client library
## ``libKF6Attica.so``. knewstuff 6.10.0's CMakeLists.txt:43 declares
## ``find_package(KF6Attica ${KF_DEP_VERSION} CONFIG REQUIRED)`` as a
## mandatory build dependency (the "Get Hot New Stuff" download
## back-end uses it to talk to OCS servers).
##
## We don't carry a from-source attica recipe yet -- the v1 stretch
## ships kwin and a minimal Plasma 6.x stack; attica's only consumer
## in that tree is knewstuff, and knewstuff is only consumed by
## kwin's "Get New Window Decorations" feature (which has no
## runtime path in a v1 boot). The nix-shipped
## ``nixpkgs#kdePackages.attica`` derivation publishes the cmake
## config + libKF6Attica.so + headers in its ``out`` output.
##
## The ``^*`` suffix asks nix to realize ALL outputs so the resolver's
## multi-output walk (M9.R.14f.10 in resolveNixTool) finds the cmake
## configs and headers consumers need.
##
## TODO(M9.R.10b+): widen the channel set (scoop on Windows, tarball
## as a universal fall-through). Until then the stub keeps the audit
## test green by registering the name + a single nix channel.

import repro_project_dsl

package `attica`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.attica^*",
      executablePath = "lib/libKF6Attica.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
