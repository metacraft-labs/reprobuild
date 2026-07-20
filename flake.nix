{
  description = "Reprobuild development environment";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
    # `bundlers` is the official NixOS bundler collection (the same set
    # `nix bundle --bundler github:NixOS/bundlers#toArx` reaches for). We
    # only consume its `toArx` bundler (nix-community/nix-bundle under the
    # hood) to package the full `reprobuild` store closure into ONE
    # self-extracting, relocatable executable (see `packages.repro-portable`
    # below). Follow our nixpkgs so the bundler's arx/nix-user-chroot helper
    # tools share the fleet's package set rather than pulling a second one.
    bundlers = {
      url = "github:NixOS/bundlers";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      # stack). The build engine, CLI io-monitor driver and monitor tests import
      # it; config.nims reads IO_MON_SRC (then falls back to a ``../io-mon``
      # sibling). Like the other source inputs, the sandboxed package build and
      # the override-free CI jobs have no sibling, so seed it from this input.
      #
      # Pinned to the hardened io-mon revision validated for this retirement
      # campaign.
      #
      # Bumped to the Lossless-Event-Capture dev tip: io-mon's Linux dependency
      # channel is now the grow-only shared-memory set ``nim-shm-gset`` (Candidate
      # C — dedup-at-source, no orphan spill), NOT the ``shm_queue`` ring, which
      # io-mon no longer imports at all. fs_snoop.nim / writer.nim now
      # ``import shm_gset`` + ``shm_gset/transport``, so this pin requires the
      # nim-shm-gset-src input below and its SHM_GSET_SRC wiring.
      url = "github:metacraft-labs/io-mon/253ee15c117dace3c8af547f75efefa778ba82c1";
      flake = false;
    };
    nim-shm-gset-src = {
      # nim-shm-gset ships the ``shm_gset`` package: a lock-free grow-only set
      # (G-Set / join-semilattice CRDT over opaque byte blobs — idempotent
      # slot-claim CAS, no deletion, file-backed shards, app-id-scoped reaper).
      # It is io-mon's PRIMARY Linux dependency-capture transport (Candidate C of
      # the Lossless Event Capture campaign): dedup-at-source so ``configure`` /
      # ``cmake`` probe storms collapse to the *distinct* dependency set. io-mon's
      # config.nims reads SHM_GSET_SRC (then falls back to a ``../nim-shm-gset``
      # sibling); the sandboxed package build + override-free CI jobs have no
      # sibling, so seed it from here — exactly like nim-shm-queue-src.
      # reprobuild does not import shm_gset directly; it flows in transitively
      # through io_mon (fs_snoop / writer), so config.nims still adds it to Nim's
      # --path for the io-mon compile to resolve.
      #
      # Pinned to the nim-shm-gset dev tip matching the io-mon pin above (ShmGSet
      # API rename landed).
      url = "github:metacraft-labs/nim-shm-gset/8a9f2f13beb24ab7949ff93c14fb34ae753bbe48";
      flake = false;
    };
    nim-shm-queue-src = {
      # nim-shm-queue ships the ``shm_queue`` package: the extracted, single
      # lock-free MPSC ring (Layer 1 ``shm_queue/ring`` + ``segment``, over
      # byte blobs; Layer 2 ``typed_queue``). repro_shm_index's action-cache
      # submission ring and io-mon's dependency queue BOTH sit on it, so exactly
      # one MPSC implementation exists. config.nims reads SHM_QUEUE_SRC (then
      # falls back to a ``../nim-shm-queue`` sibling); the sandboxed package
      # build + override-free CI jobs have no sibling, so seed it from here.
      # repro_shm_index consumes ONLY Layer 1 (pure std/posix, no serialization).
      #
      # Pinned to the nim-shm-queue rev that adds the Layer-1 EmbeddedRing
      # (repro_shm_index's action-cache ring embeds it in the control region).
      url = "github:metacraft-labs/nim-shm-queue/08d87d26067568e980f4356c4abcf2a0d841a310";
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
      # Pinned to the rev that carries ``platform/linux_preload`` (and the rest
      # of io-mon's stackable surface); the older lock lacked it, so
      # io-mon's ``linux_preload_runtime.nim`` failed with "cannot open file:
      # stackable_hooks/platform/linux_preload" in both the sandboxed package
      # build and ``just bootstrap``.
      #
      # Bumped to the rev that additionally carries the Linux x86_64
      # syscall-scanner rel32 guard (``looksLikeLinuxX8664Syscall`` /
      # ``visitLinuxX8664SyscallMemory`` reject a ``0f 05`` sitting inside a
      # ``call``/``jmp rel32`` displacement). Without it the monitor shim's
      # INT3 syscall-trap patcher corrupted the ``call rmdir@plt`` displacement
      # in glibc/Nim ``removeDir`` (``e8 0f 05 fa ff``) and SIGILL'd every test
      # that removes a directory (e.g. isonim-tui
      # ``test_snapshot_six_formats_recorded``). The dev shell exports this
      # source as ``STACKABLE_HOOKS_SRC`` and ``build_shim.sh`` honors it, so
      # the store pin — not the sibling — is what ``just build`` (and CI)
      # actually compiles the shim from; the old pin therefore produced a
      # crashing shim even though the local sibling was already hardened.
      url = "github:metacraft-labs/nim-stackable-hooks/30f69b6ca69c7f06c9a9946b77a85a09f6e3881d";
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
      #
      # We use the ``git+https`` URL form (git wire protocol) rather than
      # the ``github:`` form (tarball archive via codeload.github.com):
      # the codeload tarball endpoint 404s for this repo even for
      # anonymous callers (see M9.R.55 evidence — tarball generation is
      # apparently disabled at the repo level), while the anonymous git
      # protocol clone works fine and produces a byte-identical narHash.
      url = "git+https://github.com/metacraft-labs/codetracer-native-recorder?ref=stable";
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
      nim-shm-gset-src,
      nim-shm-queue-src,
      bundlers,
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
                export SHM_GSET_SRC=${nim-shm-gset-src}/src
                export SHM_QUEUE_SRC=${nim-shm-queue-src}/src
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
            SHM_GSET_SRC = "${nim-shm-gset-src}/src";
            SHM_QUEUE_SRC = "${nim-shm-queue-src}/src";
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

            # The binary-cache client streaming path dlopen()s libzstd.so.1 at
            # runtime (zstd frame decompress on substitute). Because it is
            # dlopen'd it is NOT a DT_NEEDED dep, so the default fixupPhase
            # (`patchelf --shrink-rpath`) strips any rpath entry pointing at
            # zstd — which is why adding it in installPhase silently vanished.
            # Re-add it in postFixup (runs AFTER the shrink) as a forced DT_RPATH
            # (glibc reliably searches DT_RPATH — not always DT_RUNPATH — for a
            # binary's own dlopen calls). Without this, repro-binary-cache /
            # repro-binary-cache-crosshost fail at the first payload transfer
            # with "could not load: libzstd.so.1" (M1's healthz/cache-info gate
            # never transferred a payload, so it only surfaced under the M2
            # cross-host substitute test).
            #
            # clingo is the same story: repro_solver's Nim bindings dlopen()
            # libclingo.so by bare leaf name at runtime (see build_apps.sh's
            # .rodata-bake guard that clears NIX_LDFLAGS/LD_LIBRARY_PATH), so it
            # is not DT_NEEDED and the shrink strips any clingo rpath too.
            # Append clingo's lib dir alongside zstd so every reprobuild binary
            # (repro, repro-binary-cache — the latter is an overrideAttrs of
            # this derivation and inherits this
            # postFixup) resolves its clingo dlopen via its own DT_RPATH, with no
            # external LD_LIBRARY_PATH. This lets the nixos-modules
            # `mcl-repro-deploy-agent` unit drop its LD_LIBRARY_PATH workaround.
            postFixup = ''
              for b in "$out"/bin/*; do
                if orig=$(${pkgs.patchelf}/bin/patchelf --print-rpath "$b" 2>/dev/null); then
                  ${pkgs.patchelf}/bin/patchelf --force-rpath \
                    --set-rpath "$orig''${orig:+:}${pkgs.zstd.out}/lib:${pkgs.clingo}/lib" "$b"
                fi
              done
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
          # Windows-Runner-Binary-Cache-Deploy M1 — expose the binary-cache
          # HTTP daemon as its own package so the nixos-modules
          # `services.mcl-repro-binary-cache` systemd unit has a runnable
          # artifact to reference. It is the same `just build` closure as
          # `reprobuild` (which installs every build/bin/* entrypoint,
          # including the newly-added build/bin/repro-binary-cache); we only
          # retarget `meta.mainProgram` so `lib.getExe` resolves the daemon.
          reproBinaryCache = reprobuild.overrideAttrs (old: {
            pname = "repro-binary-cache";
            meta = (old.meta or { }) // {
              description = "Reprobuild binary-cache HTTP server daemon";
              mainProgram = "repro-binary-cache";
            };
          });
          reproBinaryCacheApp = {
            type = "app";
            program = "${reproBinaryCache}/bin/repro-binary-cache";
          };
          # Binary-Caches.md §"Client CLI Surface (`repro cache`)" — the
          # standalone `repro-binary-cache-client` package/app was RETIRED. Its
          # toolset (publish/substitute/lookup/derive-key/gen-key) was folded
          # into the `repro cache <subcommand>` dispatch shipped by the main
          # `reprobuild` package (`bin/repro`). Callers that used
          # `packages.repro-binary-cache-client` now use `packages.reprobuild`
          # and invoke `repro cache …`.
          # Portable/self-contained `repro`: package the ENTIRE `reprobuild`
          # store closure into one self-extracting, relocatable executable so
          # the CLI runs on a plain host (e.g. an im2-debian-cloud GitHub
          # Actions runner image, or a developer workstation) that has NO
          # /nix/store present.
          #
          # Why a bundle and NOT a static (musl/`--passL:-static`) build:
          #  * `repro` is a thin dispatcher that `execv`s its `repro-full`
          #    sibling for every real subcommand; `repro-full` links OpenSSL
          #    (`--define:ssl`) and, at MODULE-INIT time (Nim `{.dynlib.}`
          #    `DatInit`, before `main`), dlopens `libclingo.so` by the
          #    absolute path the Nim compiler baked into `.rodata`
          #    (libs/repro_solver/.../clingo_bindings.nim documents this eager
          #    load). A dlopen-by-baked-abs-path solver cannot be statically
          #    linked, and clingo/openssl/blake3/sqlite would all have to be
          #    static too. So a true static binary is infeasible here.
          #  * The `toArx` bundler embeds the whole closure and, at run time,
          #    uses `nix-user-chroot` to expose the extracted store at the
          #    real `/nix/store` inside a user namespace. That makes every
          #    baked `/nix/store/...` rpath, PT_INTERP, and the clingo dlopen
          #    path resolve WITHOUT a real `/nix/store` on the host. It
          #    requires unprivileged user namespaces (default on the target
          #    Debian image).
          #
          # This is the same machinery as `nix bundle --bundler
          # github:NixOS/bundlers#toArx .#reprobuild`, wired as a first-class
          # package output so callers can just `nix build .#repro-portable`.
          # The bundler keys off `meta.mainProgram` ("repro"), so the produced
          # executable launches `repro` (which finds its `repro-full` sibling
          # inside the same extracted closure). It ADDS to — and does not
          # disturb — `packages.default`/`packages.reprobuild` or `just build`.
          reproPortable = bundlers.bundlers.${system}.toArx reprobuild;
        in
        {
          apps.default = reproApp;
          apps.repro = reproApp;
          apps.repro-binary-cache = reproBinaryCacheApp;

          packages.default = reprobuild;
          packages.reprobuild = reprobuild;
          packages.repro-binary-cache = reproBinaryCache;
          # Self-contained, /nix/store-free `repro` (see `reproPortable`).
          packages.repro-portable = reproPortable;

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
            inputsFrom = [ pkgs.nix ];
            # repro_solver's clingo bindings dlopen libclingo.so at module init.
            # build_apps.sh clears NIX_LDFLAGS + LD_LIBRARY_PATH for every `nim c`
            # (the .rodata-bake guard) so the binaries carry a bare
            # `dlopen("libclingo.so")` with no rpath and rely on a runtime
            # LD_LIBRARY_PATH (as build_apps.sh documents). Provide it so `repro`
            # and the test binaries resolve clingo under `dev-exec`/CI `just test`.
            # zstd is the same story: the binary-cache client dlopen()s
            # libzstd.so.1 at runtime (its DT_RPATH is only patched into the Nix
            # package build's binaries, not the `just bootstrap` binaries the
            # ct build and `just test` run), so add it here too — otherwise a
            # bootstrapped `repro` aborts with "could not load: libzstd.so.1".
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
              pkgs.clingo
              pkgs.zstd
            ];
            BLAKE3_PREFIX = blake3Prefix;
            NIMCRYPTO_SRC = nimcrypto-src;
            BEARSSL_SRC = bearssl-src;
            STACKABLE_HOOKS_SRC = "${stackable-hooks-src}/src";
            IO_MON_SRC = "${io-mon-src}/src";
            SHM_GSET_SRC = "${nim-shm-gset-src}/src";
            SHM_QUEUE_SRC = "${nim-shm-queue-src}/src";
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
              # Used by the ct-build CI step to bake reprobuild's runtime library
              # dirs (clingo + zstd) into the bootstrapped `repro`'s RPATH, so it
              # resolves its dlopen()s when run inside CodeTracer's dev shell.
              pkgs.patchelf
              pkgs.cmake
              pkgs.pkg-config
              pkgs.nix
              pkgs.libsodium
              pkgs.boost
              pkgs.libgit2
              pkgs.libarchive
              pkgs.nlohmann_json
              pkgs.pcre2
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
              # Spec-Implementation M2a: clingo for the repro_solver
              # ASP bindings. Ships the `clingo` CLI tool and the
              # libclingo.so shared library + <clingo/clingo.h> headers
              # the Nim bindings dlopen and pass to the compiler.
              pkgs.clingo
              # Test-suite runtime tools: the M6 native-shell-hook gate
              # (tests/e2e/dev-env/t_e2e_native_shell_hooks.nim) requires real
              # zsh + fish binaries on PATH (their `nix build nixpkgs#…`
              # fallback can't resolve the registry in the pure-flake CI shell),
              # and the codetracer-subset build gate
              # (tests/e2e/codetracer-subset/t_e2e_codetracer_build_subset_without_tup.nim)
              # shells out to node. (Safe now that the test runner isolates git
              # config — adding shells no longer perturbs the gpg-signing tests.)
              pkgs.nodejs
              pkgs.zsh
              pkgs.fish
            ]
            # libbpf for the codetracer-subset `ct` build: CodeTracer's
            # native monitor under src/ct/bpf_monitor_native.nim and
            # src/ct/libbpf_wrapper.nim include <bpf/libbpf.h>, which is
            # gated by Linux. macOS doesn't ship libbpf, so don't drag
            # it into the dev shell there.
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.libbpf
              # M9.R.54: the reproos-image recipe's ``runtimeDeps`` list
              # (recipes/reproos-image/repro.nim) enumerates 35 host
              # tools the build-reproos-image.sh driver invokes.  Under
              # ``defaultToolProvisioning "path"`` the M9.N Batch B
              # resolver probes each name against the host PATH at
              # build-plan time and hard-fails on the first miss with
              # ``tool-resolution failed: <name> requested by uses ...``.
              # A typical NixOS interactive PATH already carries
              # coreutils / util-linux / rsync / mkfs.* etc., but is
              # missing qemu-{img,nbd}, grub-install / grub-mkconfig
              # (grub2), and modprobe / rmmod / lsmod (kmod).  Wiring
              # them into the dev shell makes ``nix develop`` /
              # ``.envrc``-loaded shells sufficient for
              # ``./build/bin/repro build recipes/reproos-image`` with
              # no ad-hoc ``nix-shell -p qemu grub2 kmod`` wrap.
              #
              # These are Linux-only: qemu-nbd is a Linux kernel-module
              # bridge, grub-install writes MBR/EFI blocks, and modprobe
              # /rmmod /lsmod talk to the Linux kmod interface.  macOS
              # /Windows operators don't build reproos-image so the
              # cost of pulling these in there wouldn't buy anything.
              #
              # ``grub2_efi`` (not plain ``grub2``): the reproos-image
              # target is an EFI-bootable qcow2 (``grub-install
              # --target=x86_64-efi``), and nixpkgs splits the grub
              # module output — ``pkgs.grub2`` ships only the
              # ``i386-pc`` (BIOS) modules, so ``grub-install
              # --target=x86_64-efi`` fails with ``modinfo.sh doesn't
              # exist``.  ``pkgs.grub2_efi`` carries the ``x86_64-efi``
              # module tree; validated end-to-end in the M9.R.54 Phase
              # B build (grub-install reached ``modinfo.sh`` search
              # only after the switch to ``grub2_efi``).
              pkgs.qemu
              pkgs.grub2_efi
              pkgs.kmod
            ];
            shellHook = pre-commit-check.shellHook;
          };
        };
    };
}
