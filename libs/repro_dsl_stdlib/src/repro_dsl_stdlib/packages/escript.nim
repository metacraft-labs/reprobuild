## ``escript`` — the Erlang/OTP script runner.
##
## One package per executable, realised from the OTP distribution
## ``erlang.nim`` describes (its header says why a recipe names ``escript``
## rather than ``erlang``): a path-mode ``uses: "escript"`` probes PATH for
## ``escript``, so this package's realisations expose an executable of exactly
## that name. Keep both arms in step with ``erlang.nim``'s.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/nixpkgs_pin
export packages_schema

package escript:
  provisioning:
    # Nix-capable hosts: nixpkgs' erlang at the canonical pin, as erlang.nim.
    nixPackage "nixpkgs#erlang", executablePath = "bin/escript",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: the same OTP 28.5 installer as erlang.nim (downloads are
    # deduplicated by content hash, so a recipe using several BEAM
    # executables fetches it once); only ``executablePath`` differs.
    tarball url = "https://github.com/erlang/otp/releases/download/OTP-28.5/otp_win64_28.5.exe",
      sha256 = "46f56351e2e67865c6aaff83bcd0a7d97d73bea643a0531774dd9ba8fbee7dc0",
      archiveType = "installer-nsis",
      executablePath = "erts-16.4\\bin\\escript.exe",
      version = "28.5",
      packageId = "erlang@28.5",
      installMethod = "installer-nsis",
      env = "ERLANG_HOME=${prefix}",
      cpu = "x86_64",
      os = "windows"
