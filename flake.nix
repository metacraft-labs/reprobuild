{
  description = "Reprobuild development environment";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
    runquota-src = {
      url = "github:metacraft-labs/runquota/main";
      flake = false;
    };
    nimcrypto-src = {
      url = "github:cheatfate/nimcrypto/69eec0375dd146aede41f920c702c531bfe89c6b";
      flake = false;
    };
    bearssl-src = {
      # Submodules=1 pulls bearssl/csources (the upstream BearSSL C tree
      # nim-bearssl wraps); without it the bindings compile but link-fail.
      # The git+https URL form preserves the submodule flag through the lock
      # (the github: + ?submodules=1 form drops it on lock).
      url = "git+https://github.com/status-im/nim-bearssl?submodules=1&rev=9a4eed052abbded2d94feaf3f5bbd95a30ec4671";
      flake = false;
    };
    ct-test-src = {
      # ct-test ships the ct_test_nim_unittest adapter that
      # `buildNimUnittest.build` in repro.tests.nim depends on, plus the
      # ct_test_unittest_parallel framework adapter the parallel runner
      # speaks. config.nims reads CT_TEST_SRC to thread these onto Nim's
      # --path.
      url = "github:metacraft-labs/ct-test/main";
      flake = false;
    };
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks,
      nimcrypto-src,
      bearssl-src,
      ct-test-src,
      runquota-src,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          version =
            let
              versionMatches = builtins.filter (match: match != null) (
                map (line: builtins.match ''version = "([^"]+)"'' line) (
                  pkgs.lib.splitString "\n" (builtins.readFile ./reprobuild.nimble)
                )
              );
            in
            builtins.elemAt (builtins.head versionMatches) 0;
          # libblake3 has split `out`/`dev` outputs (dev has include/blake3.h,
          # out has lib/libblake3.so). config.nims's prefix-lookup expects a
          # single tree containing both, so join them with symlinkJoin.
          blake3Prefix = pkgs.symlinkJoin {
            name = "libblake3-prefix";
            paths = [
              pkgs.libblake3.dev
              pkgs.libblake3.out
            ];
          };
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks.just-lint = {
              enable = true;
              name = "just lint";
              entry = "${pkgs.writeShellScript "reprobuild-just-lint" ''
                export PATH=${
                  pkgs.lib.makeBinPath [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.gnugrep
                    pkgs.just
                    pkgs.nim2
                  ]
                }:$PATH
                export BLAKE3_PREFIX=${blake3Prefix}
                export NIMCRYPTO_SRC=${nimcrypto-src}
                export BEARSSL_SRC=${bearssl-src}
                export CT_TEST_SRC=${ct-test-src}
                export REPROBUILD_USE_SYSTEM_HASH_LIBS=1
                export RUNQUOTA_SRC=${runquota-src}
                export XXHASH_PREFIX=${pkgs.xxHash}
                exec ${pkgs.just}/bin/just lint
              ''}";
              language = "system";
              pass_filenames = false;
            };
          };
          reprobuild = pkgs.stdenv.mkDerivation {
            pname = "reprobuild";
            inherit version;
            src = ./.;

            strictDeps = true;
            dontConfigure = true;

            nativeBuildInputs = [
              pkgs.just
              pkgs.nim2
              # Spec-Implementation M2a: clingo is the ASP solver
              # reprobuild's repro_solver lib binds against. The CLI
              # tool is used by smoke tests and the C library
              # (libclingo.so + <clingo/clingo.h>) is what the Nim
              # bindings dlopen at runtime. Adding it to
              # nativeBuildInputs makes the headers visible during
              # `just build`; the buildInputs entry below pulls the
              # shared library into the runtime closure.
              pkgs.clingo
            ];

            buildInputs = [
              pkgs.libblake3
              pkgs.sqlite
              pkgs.xxHash
              pkgs.clingo
            ];

            BLAKE3_PREFIX = blake3Prefix;
            NIMCRYPTO_SRC = nimcrypto-src;
            BEARSSL_SRC = bearssl-src;
            CT_TEST_SRC = ct-test-src;
            REPROBUILD_USE_SYSTEM_HASH_LIBS = "1";
            RUNQUOTA_SRC = runquota-src;
            SQLITE_PREFIX = pkgs.sqlite.out;
            XXHASH_PREFIX = pkgs.xxHash;

            buildPhase = ''
              runHook preBuild
              just build
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib"
              for bin in build/bin/*; do
                install -m755 "$bin" "$out/bin/$(basename "$bin")"
              done
              for lib in build/lib/*; do
                [ -e "$lib" ] || continue
                install -m755 "$lib" "$out/lib/$(basename "$lib")"
              done
              runHook postInstall
            '';

            meta = {
              description = "Reprobuild build system";
              homepage = "https://github.com/metacraft-labs/reprobuild";
              license = pkgs.lib.licenses.mit;
              mainProgram = "repro";
              platforms = [
                "x86_64-linux"
                "aarch64-linux"
                "x86_64-darwin"
                "aarch64-darwin"
              ];
            };
          };
          reproApp = {
            type = "app";
            program = "${reprobuild}/bin/repro";
          };
        in
        {
          apps.default = reproApp;
          apps.repro = reproApp;

          packages.default = reprobuild;
          packages.reprobuild = reprobuild;

          checks = {
            inherit pre-commit-check;
            package-build = reprobuild;
            repo-requirements =
              pkgs.runCommand "reprobuild-repo-requirements" { nativeBuildInputs = [ pkgs.just ]; }
                ''
                  cp -R ${./.} source
                  chmod -R u+w source
                  cd source
                  ${pkgs.bash}/bin/bash scripts/check_repo_requirements.sh
                  mkdir -p $out
                '';
          };

          devShells.default = pkgs.mkShell {
            BLAKE3_PREFIX = blake3Prefix;
            NIMCRYPTO_SRC = nimcrypto-src;
            BEARSSL_SRC = bearssl-src;
            CT_TEST_SRC = ct-test-src;
            REPROBUILD_USE_SYSTEM_HASH_LIBS = "1";
            RUNQUOTA_SRC = runquota-src;
            SQLITE_PREFIX = pkgs.sqlite.out;
            XXHASH_PREFIX = pkgs.xxHash;
            packages = [
              pkgs.just
              pkgs.nim2
              pkgs.cmake
              pkgs.ninja
              pkgs.clang
              pkgs.curl
              pkgs.libblake3
              pkgs.p7zip
              pkgs.sqlite
              pkgs.xxHash
              pkgs.zip
              pkgs.zlib
              pkgs.nixfmt-rfc-style
              pkgs.repomix
              pkgs.pre-commit
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.typos
              # Spec-Implementation M2a: clingo for the repro_solver
              # ASP bindings. Ships the `clingo` CLI tool and the
              # libclingo.so shared library + <clingo/clingo.h> headers
              # the Nim bindings dlopen and pass to the compiler.
              pkgs.clingo
            ]
            # libbpf for the codetracer-subset `ct` build: CodeTracer's
            # native monitor under src/ct/bpf_monitor_native.nim and
            # src/ct/libbpf_wrapper.nim include <bpf/libbpf.h>, which is
            # gated by Linux. macOS doesn't ship libbpf, so don't drag
            # it into the dev shell there.
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.libbpf
            ];
            shellHook = pre-commit-check.shellHook;
          };
        };
    };
}
