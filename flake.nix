{
  description = "Reprobuild development environment";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
    runquota-src = {
      # runquota's mainline is ``dev``; ``main`` is stale and lacks the
      # bounded grant-stream API (``pollNextGrantBounded`` / ``GrantPollResult``)
      # that repro_runquota now compiles against. The ``test`` CI job already
      # overrides this to the ``dev`` sibling clone; pin the default here so the
      # override-free ``lint`` and ``nix-build`` jobs resolve the same source.
      url = "github:metacraft-labs/runquota/dev";
      flake = false;
    };
    io-mon-src = {
      # io-mon ships the ``io_mon`` Nim package (the byte-identical wire-format
      # + ABI relocation of the former repro_monitor_depfile / shim / hooks
      # stack). The build engine, CLI fs-snoop driver and monitor tests import
      # it; config.nims reads IO_MON_SRC (then falls back to a ``../io-mon``
      # sibling). Like the other source inputs, the sandboxed package build and
      # the override-free CI jobs have no sibling, so seed it from this input.
      #
      # Pinned to the Linux monitor-completeness fix (f1dcd43): later main
      # commits also rework writer/capabilities completeness logic and are not
      # yet validated for the Linux LD_PRELOAD ct-build path. Unpin once they are.
      url = "github:metacraft-labs/io-mon/f1dcd43f989d7f5d407f3133c46e676828c5cd6f";
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
    # nim-stackable-hooks (the framework the macOS monitor shim migrated to in
    # 86cb1bf). The package build compiles repro_monitor_hooks against it, so —
    # like bearssl-src — it must be supplied as a source input; the dev shell
    # resolves it from the sibling checkout, but the sandboxed package build has
    # no sibling and otherwise fails with "cannot open file: stackable_hooks/…".
    stackable-hooks-src = {
      url = "github:metacraft-labs/nim-stackable-hooks";
      flake = false;
    };
    reprobuild-ct-test-runner-src = {
      # The run-side ``ct_test_runner_adapter`` — the in-process
      # ``TestRunner`` adapter reprobuild installs (it depends only on the
      # ``repro_test_adapters`` contract, not the engine). config.nims
      # reads REPRO_CT_TEST_RUNNER_SRC to thread it onto Nim's --path.
      # (The build-side typed-tool — ct_test_interface / ct_test_nim_unittest
      # / ct_test_unittest_parallel — now lives in-tree under libs/.)
      url = "github:metacraft-labs/reprobuild-ct-test-runner";
      flake = false;
    };
    reprobuild-test-adapters-src = {
      # The ``TestRunner`` cross-cutting contract (Nim package
      # ``repro_test_adapters``). config.nims reads
      # REPRO_TEST_ADAPTERS_SRC to thread it onto Nim's --path; the dev
      # shell resolves it from the sibling checkout, but the sandboxed
      # package build has no sibling so we seed it from this input.
      url = "github:metacraft-labs/reprobuild-test-adapters";
      flake = false;
    };
    codetracer-native-recorder = {
      # ct_interpose lives under ``ct_interpose/src`` in the native-recorder
      # repo. ``repro_monitor_hooks/macos_interpose_runtime`` imports
      # ``ct_interpose/propagation`` and the cross-platform monitor shim uses
      # ``ct_interpose/hook_registry``; config.nims threads CT_INTERPOSE_SRC
      # onto Nim's --path (falling back to a sibling checkout or a vendored
      # copy when the env var is unset). The Nix build is sandboxed and sees
      # neither, so we must seed CT_INTERPOSE_SRC from this input. In the
      # CodeTracer workspace this input ``follows`` codetracer's own
      # native-recorder input, so a local sibling checkout is used.
      url = "github:metacraft-labs/codetracer-native-recorder/stable";
      flake = false;
    };
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks,
      nimcrypto-src,
      bearssl-src,
      stackable-hooks-src,
      reprobuild-ct-test-runner-src,
      reprobuild-test-adapters-src,
      codetracer-native-recorder,
      runquota-src,
      io-mon-src,
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
          # CT_INTERPOSE_SRC points at the directory that *contains* the
          # ``ct_interpose`` package (config.nims validates it by probing
          # ``<dir>/ct_interpose/hook_registry.nim``), which is
          # ``ct_interpose/src`` inside the native-recorder checkout.
          ctInterposeSrc = "${codetracer-native-recorder}/ct_interpose/src";
          # Build the RunQuota daemon (and CLI) from the ``runquota-src``
          # input, the same source the reprobuild client compiles against
          # (``RUNQUOTA_SRC``). Putting this on the dev-shell PATH means the
          # auto-started ``runquotad`` tracks the pinned/overridable source
          # rather than a separately-installed binary, so
          # ``--override-input runquota-src path:../runquota`` yields a daemon
          # built from the local sibling — no ``RUNQUOTAD_BIN`` and no push
          # needed to iterate. Mirrors runquota's own flake package.
          runquotaTools = pkgs.stdenv.mkDerivation {
            pname = "runquota";
            version = "0.1.0";
            src = runquota-src;
            strictDeps = true;
            dontConfigure = true;
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.just
              pkgs.nim2
            ];
            buildPhase = ''
              runHook preBuild
              mkdir -p test-logs
              ${pkgs.bash}/bin/bash scripts/build_apps.sh 2>&1 | tee test-logs/build.log
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin"
              install -m755 build/bin/runquota "$out/bin/runquota"
              install -m755 build/bin/runquotad "$out/bin/runquotad"
              runHook postInstall
            '';
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
                export STACKABLE_HOOKS_SRC=${stackable-hooks-src}/src
                export IO_MON_SRC=${io-mon-src}/src
                export REPRO_CT_TEST_RUNNER_SRC=${reprobuild-ct-test-runner-src}
                export REPRO_TEST_ADAPTERS_SRC=${reprobuild-test-adapters-src}/src
                export CT_INTERPOSE_SRC=${ctInterposeSrc}
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
              # repro-harvest-apt is compiled with --define:ssl (it walks
              # snapshot.debian.org's HTTPS InRelease signature chain), so
              # Nim's std/net openssl backend link step needs -lssl -lcrypto.
              # macOS resolves these from the system SDK, but the Linux nix
              # sandbox has no system openssl — pull it into the closure here.
              pkgs.openssl
            ];

            BLAKE3_PREFIX = blake3Prefix;
            NIMCRYPTO_SRC = nimcrypto-src;
            BEARSSL_SRC = bearssl-src;
            STACKABLE_HOOKS_SRC = "${stackable-hooks-src}/src";
            IO_MON_SRC = "${io-mon-src}/src";
            REPRO_CT_TEST_RUNNER_SRC = reprobuild-ct-test-runner-src;
            REPRO_TEST_ADAPTERS_SRC = "${reprobuild-test-adapters-src}/src";
            CT_INTERPOSE_SRC = ctInterposeSrc;
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
            # repro_solver's clingo bindings dlopen libclingo.so at module init.
            # build_apps.sh clears NIX_LDFLAGS + LD_LIBRARY_PATH for every `nim c`
            # (the .rodata-bake guard) so the binaries carry a bare
            # `dlopen("libclingo.so")` with no rpath and rely on a runtime
            # LD_LIBRARY_PATH (as build_apps.sh documents). Provide it so `repro`
            # and the test binaries resolve clingo under `dev-exec`/CI `just test`.
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.clingo ];
            BLAKE3_PREFIX = blake3Prefix;
            NIMCRYPTO_SRC = nimcrypto-src;
            BEARSSL_SRC = bearssl-src;
            STACKABLE_HOOKS_SRC = "${stackable-hooks-src}/src";
            IO_MON_SRC = "${io-mon-src}/src";
            REPRO_CT_TEST_RUNNER_SRC = reprobuild-ct-test-runner-src;
            REPRO_TEST_ADAPTERS_SRC = "${reprobuild-test-adapters-src}/src";
            CT_INTERPOSE_SRC = ctInterposeSrc;
            REPROBUILD_USE_SYSTEM_HASH_LIBS = "1";
            RUNQUOTA_SRC = runquota-src;
            SQLITE_PREFIX = pkgs.sqlite.out;
            XXHASH_PREFIX = pkgs.xxHash;
            packages = [
              runquotaTools
              pkgs.just
              pkgs.nim2
              pkgs.cmake
              pkgs.ninja
              pkgs.clang
              pkgs.curl
              pkgs.libblake3
              pkgs.openssl
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
              # Test-suite runtime tools: the native-shell-hook e2e gates
              # require real zsh + fish binaries on PATH (their `nix build
              # nixpkgs#…` fallback can't resolve the registry in the pure-flake
              # CI shell), and the codetracer-subset build e2e needs node.
              pkgs.nodejs
              pkgs.zsh
              pkgs.fish
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
