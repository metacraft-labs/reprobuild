## ``mix`` — Elixir's build tool.
##
## One package per executable, realised from the Elixir distribution
## ``elixir.nim`` describes, the way ``npm`` and ``npx`` share ``node``'s: a
## path-mode ``uses: "mix"`` probes PATH for ``mix``, and only a package
## of that name gives a recipe a declared ``mix``
## (reprobuild-pm/issues/2026-11-07-the-stdlib-beam-packages-cannot-provision-erl-mix-or-rebar3.md).
## Keep both arms in step with ``elixir.nim``'s.
##
## Elixir runs on the BEAM, so ``erl`` is a requirement of the Windows arm
## that this package cannot express: ``mix.bat`` finds the runtime on PATH,
## and a recipe that uses ``mix`` there declares ``erl`` as well. nixpkgs
## wraps its ``bin/mix`` with its own erlang.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/nixpkgs_pin
export packages_schema

package mix:
  provisioning:
    # Nix-capable hosts: nixpkgs' elixir at the canonical pin, as elixir.nim.
    nixPackage "nixpkgs#elixir", executablePath = "bin/mix",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: the same hex.pm Elixir 1.19.5 zip as elixir.nim (downloads are
    # deduplicated by content hash); only ``executablePath`` differs.
    tarball url = "https://builds.hex.pm/builds/elixir/v1.19.5.zip",
      sha256 = "db6701f2232be899190ecb8dbf280104fe2434675093c2b5935e563a08052afb",
      archiveType = "zip",
      executablePath = "bin/mix.bat",
      version = "1.19.5",
      packageId = "elixir@1.19.5",
      os = "windows"
