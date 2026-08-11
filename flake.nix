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
      url = "github:metacraft-labs/io-mon/8b6d0b9b91ee8fb907b5cb99ce8f535b7cacb9d8";
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
      url = "github:metacraft-labs/nim-shm-gset/360bfc15cadab1ff583e6d1cbc20b389d5d6825f";
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
      url = "github:metacraft-labs/nim-shm-queue/5a8e43b52fa202859658692c9f8432967f3971ea";
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
    codetracer-src = {
      # CodeTracer owns the cross-language test driver ``ct-test``
      # (``src/ct_test/ct_test.nim``): TestCatalog v1 discovery over the
      # provider registry plus the partitioned parallel runner, declared as
      # the ``ct-test`` target in codetracer's ``repro.nim``. ``ctTestTools``
      # below builds that binary from this input and the dev shell puts it on
      # PATH, exactly as ``runquotaTools`` does for ``runquota-src`` — so the
      # shipped tool tracks a pinned/overridable source instead of whatever
      # someone hand-compiled into a sibling checkout.
      #
      # Pinned to ``dev``, CodeTracer's active branch, mirroring the
      # ``runquota/dev`` pin above and for the same reason: the repo's default
      # branch is ``stable``, a release pointer that can sit behind ``dev``.
      # (At this pin ``stable`` and ``dev`` happen to name the same commit, and
      # that commit is a strict descendant of ``main``; all three carry
      # ``src/ct_test``.)
      #
      # ``flake = false`` — we want the source tree only. CodeTracer's own
      # flake drags in the Electron/frontend/db-backend toolchain, none of
      # which ``ct-test`` needs (its only non-stdlib dependency is runquota;
      # see ctTestTools). The ``.envrc`` auto-override
      # (NIX_FLAKE_OVERRIDE_AUTO + the ``-src`` suffix convention) names this
      # input for a ``../codetracer`` sibling when one exists. Be aware of what
      # that costs before leaning on it: overriding a source input to a plain
      # path copies the whole directory into the store, and a working
      # CodeTracer checkout is several gigabytes. An override-free shell builds
      # the pin, which is the cheap and reproducible default.
      url = "github:metacraft-labs/codetracer/dev";
      flake = false;
    };

    # ── reprobuild Nim toolchain: the metacraft-labs/nim fork ──────────────
    # The fork (codetracer-nim, Nim 2.3.1 devel) replaces nixpkgs'
    # nim-unwrapped-2.2.4. It carries a compiler effect-inference fix (so
    # `std/streams`/`std/json` compile under `--mm:orc -d:useNimRtl`, which stock
    # 2.2.x rejects) plus CodeTracer's column-aware tracer. Built koch-boot-free
    # by nix/nim-fork.nix. The fork uses the ``git+https`` clone form (its
    # codeload tarball 404s, same as codetracer-native-recorder above); the
    # compiler itself imports the three vendored deps below (trace/stew/results).
    nim-fork-src = {
      url = "git+https://github.com/metacraft-labs/nim?ref=codetracer&rev=362d42954ecc4becf19b50ae898bc59538bd3b46";
      flake = false;
    };
    nim-csources-src = {
      url = "github:nim-lang/csources_v3/eeab3ac46e93f10efda8e58c4db02b9438319d71";
      flake = false;
    };
    ct-trace-format-src = {
      url = "github:metacraft-labs/codetracer-trace-format-nim/c2f3dfc3bcb423a939ff4d6eab42f848957f7048";
      flake = false;
    };
    nim-stew-src = {
      url = "github:status-im/nim-stew/83eb1157963b7f49351dbdd858355fa990bbe23c";
      flake = false;
    };
    nim-results-src = {
      url = "github:metacraft-labs/nim-result/df8113dda4c2d74d460a8fa98252b0b771bf1f27";
      flake = false;
    };
    # nim devel bundles `checksums` (md5/sha1, split out of the stdlib) into
    # dist/; the compiler imports it. Pinned to koch's ChecksumsStableCommit.
    nim-checksums-src = {
      url = "github:nim-lang/checksums/0b8e46379c5bc1bf73d8b3011908389c60fb9b98";
      flake = false;
    };
    # nim devel's compiler imports nimony/src/lib/treemangler; koch bundles it
    # into dist/ non-recursively. Pinned to koch's NimonyStableCommit.
    nim-nimony-src = {
      url = "github:nim-lang/nimony/bbfb21529845567c55b67d176354daef0e7d6c29";
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
      codetracer-src,
      runquota-src,
      io-mon-src,
      nim-shm-gset-src,
      nim-shm-queue-src,
      nim-fork-src,
      nim-csources-src,
      ct-trace-format-src,
      nim-stew-src,
      nim-results-src,
      nim-checksums-src,
      nim-nimony-src,
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
          # The reprobuild Nim toolchain: the metacraft-labs/nim fork (Nim 2.3.1
          # devel), built from source (nix/nim-fork.nix). Used everywhere the
          # flake previously used `pkgs.nim2` (nixpkgs nim-unwrapped-2.2.4).
          nimFork = import ./nix/nim-fork.nix {
            inherit pkgs;
            forkSrc = nim-fork-src;
            csourcesSrc = nim-csources-src;
            traceFormatSrc = ct-trace-format-src;
            stewSrc = nim-stew-src;
            resultsSrc = nim-results-src;
            checksumsSrc = nim-checksums-src;
            nimonySrc = nim-nimony-src;
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
              nimFork
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
          # Build CodeTracer's standalone cross-language test driver ``ct-test``
          # from the ``codetracer-src`` input and put it on the dev-shell PATH.
          # Same shape and same motivation as ``runquotaTools`` above: the tool
          # tracks a pinned, overridable source rather than a hand-built binary
          # in someone's sibling checkout, so
          # ``--override-input codetracer-src path:../codetracer`` (which the
          # ``.envrc`` auto-override does for you when the sibling exists)
          # yields a ``ct-test`` built from the local tree with no push.
          #
          # Dependency surface: ``ct-test`` compiles from ``src/ct_test/**``,
          # the Nim stdlib, and runquota's ``runquota_process`` /
          # ``runquota_core`` / ``runquota_host*`` packages — and nothing else.
          # (Verified against the Nim compilation cache of a full build: no
          # vendored ``libs/`` tree, no Electron/frontend stack, no db-backend,
          # no io-mon, no codetracer-trace-format-nim.) That is why this
          # derivation is cheap despite CodeTracer being a large repo, why a
          # submodule-less source input suffices, and why ``RUNQUOTA_SRC`` is
          # the only source path it has to thread through: codetracer's
          # repo-root ``config.nims`` reads that variable and adds the runquota
          # library paths, the sandbox having no ``../runquota`` sibling.
          ctTestTools = pkgs.stdenv.mkDerivation {
            pname = "ct-test";
            version = "0.1.0";
            src = codetracer-src;
            strictDeps = true;
            dontConfigure = true;
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              nimFork
            ];
            RUNQUOTA_SRC = runquota-src;
            # The compile is spelled out here rather than delegated to a script
            # in the codetracer checkout (which is how ``runquotaTools`` calls
            # ``scripts/build_apps.sh``) for one concrete reason: codetracer has
            # no such script, and adding one would make this derivation
            # unbuildable at the pinned revision until that script is pushed —
            # i.e. an override-free ``nix develop`` would break. Keeping the
            # invocation self-contained means this input can be pinned to any
            # codetracer revision that carries ``src/ct_test``.
            #
            # It intentionally mirrors the ``ct-test`` target in codetracer's
            # ``repro.nim``, which stays the graph's declaration of this binary.
            # The two are not flag-identical — the graph target additionally
            # asks for debug info, line/stack traces and bound checks, and this
            # one does not — so treat the graph as authoritative for the shipped
            # product and this as the dev-shell convenience build.
            #
            # They do agree on the one flag that changes what the binary can do:
            # ``--mm:orc``. It is spelled out below rather than left to the
            # compiler's default because ``test run`` drives a worker pool whose
            # threads share the discovered sequences, which refc's per-thread
            # heaps cannot support; a refc build of these sources therefore
            # either refuses ``run`` outright (newer sources, which carry an
            # explicit guard) or crashes in the worker loop (older ones). Either
            # way, silently inheriting a changed default would turn this from a
            # runner into a discover-only tool, so the flag is stated.
            buildPhase = ''
              runHook preBuild
              mkdir -p build/bin build/nimcache
              nim c \
                --threads:on \
                --mm:orc \
                --nimcache:build/nimcache/ct-test \
                --out:build/bin/ct-test \
                src/ct_test/ct_test.nim
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin"
              install -m755 build/bin/ct-test "$out/bin/ct-test"
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
                    nimFork
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
          reprobuildSource = ./.;
          runtimeLibraries = [
            blake3Prefix
            pkgs.xxHash
            pkgs.sqlite.out
            pkgs.openssl.out
            pkgs.zstd.out
            pkgs.clingo
          ];
          runtimeLibraryPath = pkgs.lib.makeLibraryPath runtimeLibraries;
          reprobuild = pkgs.stdenv.mkDerivation {
            pname = "reprobuild";
            inherit version;
            src = reprobuildSource;

            strictDeps = true;
            dontConfigure = true;

            nativeBuildInputs = [
              pkgs.just
              pkgs.makeWrapper
              nimFork
              # Spec-Implementation M2a: clingo is the ASP solver
              # reprobuild's repro_solver lib binds against. The CLI
              # tool is used by smoke tests and the C library
              # (libclingo.so + <clingo/clingo.h>) is what the Nim
              # bindings dlopen at runtime. Adding it to
              # nativeBuildInputs makes the headers visible during
              # `just build`; the buildInputs entry below pulls the
              # shared library into the runtime closure.
              pkgs.clingo
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              # Rewrites Mach-O install IDs and internal dependency paths
              # before postFixup adds the complete package LC_RPATH set. The
              # signing hook is a postFixupHooks entry: stdenv runs the
              # derivation's postFixup body first, so it signs only after our
              # per-slice mutation and universal-image reassembly.
              pkgs.fixDarwinDylibNames
              pkgs.darwin.autoSignDarwinBinariesHook
              pkgs.coreutils
              pkgs.file
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

              # `reprobuild-nix-daemon` is the helper that `tool-provisioning=nix`
              # resolutions talk to. It used to be reachable only through
              # $REPROBUILD_SOURCE_ROOT/tools, i.e. an unpatched source checkout,
              # so its `#!/usr/bin/env python3` picked up whatever interpreter
              # happened to be on PATH. Under launchd's default environment that
              # is macOS's system python3 (3.9), which cannot parse the script's
              # PEP 604 `X | None` annotations — the child died instantly and its
              # stderr went to an unread pipe, surfacing only as the opaque
              # "Failed to connect or spawn reprobuild-nix-daemon".
              #
              # Installing it here pins an absolute, known-good interpreter so
              # the helper no longer depends on the ambient PATH. libexec (not
              # bin) keeps it out of the wrapProgram loop below, which is for
              # CLI entry points.
              #
              # The interpreter is substituted explicitly rather than via
              # patchShebangs: bare patchShebangs resolves against HOST_PATH,
              # whereas a nativeBuildInputs python3 lands on the build PATH, so
              # it silently left `env python3` in place. --replace-fail also
              # turns a future upstream shebang change into a build error
              # instead of silently restoring the ambient-PATH behaviour.
              mkdir -p "$out/libexec"
              install -m755 tools/reprobuild-nix-daemon/reprobuild-nix-daemon \
                "$out/libexec/reprobuild-nix-daemon"
              substituteInPlace "$out/libexec/reprobuild-nix-daemon" \
                --replace-fail '#!/usr/bin/env python3' \
                  '#!${pkgs.python3}/bin/python3'
              runHook postInstall
            '';

            # Installed entry points span ordinary linked libraries and bare
            # leaf-name dlopen()s (notably zstd and clingo). Normal fixup only
            # retains paths visible from link dependencies, so restore the full
            # runtime family for every installed ELF/Mach-O role. Linux uses a
            # transitive DT_RPATH; Darwin needs one LC_RPATH load command per
            # directory and valid install IDs for every installed dylib.
            postFixup = ''
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                for b in "$out"/bin/* "$out"/lib/*; do
                  if orig=$(${pkgs.patchelf}/bin/patchelf --print-rpath "$b" 2>/dev/null); then
                    ${pkgs.patchelf}/bin/patchelf --force-rpath \
                      --set-rpath "$orig''${orig:+:}${runtimeLibraryPath}" "$b"
                  fi
                done
              ''}

              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
                # fixDarwinDylibNames is a fixupOutputHook and has already run.
                # Copy thin images or extract universal slices, mutate each
                # architecture independently, then reassemble universal images.
                # autoSignDarwinBinariesHook is registered in
                # postFixupHooks, which stdenv invokes after this implicit
                # postFixup body, so arm64/arm64e signatures cover final bytes.
                FILE=${pkgs.file}/bin/file \
                STAT=${pkgs.coreutils}/bin/stat \
                CP=${pkgs.coreutils}/bin/cp \
                MV=${pkgs.coreutils}/bin/mv \
                ${pkgs.bash}/bin/bash ${./scripts/fixup_macho_runtime.sh} "$out" \
                  ${pkgs.lib.concatStringsSep " " (map (library: "${library}/lib") runtimeLibraries)}
              ''}

              # Provider/interface compilation happens after installation, in
              # the caller's project. Keep the package's exact source inputs in
              # its runtime closure and expose them as defaults to every entry
              # point. `--set-default` preserves explicit development/source
              # overrides while making an ordinary installed package
              # independent of sibling checkouts and the build-time dev shell.
              # REPROBUILD_RUNTIME_LIBRARY_PATH is compiler input, not a loader
              # variable: generated interface/provider binaries bake these dirs
              # into their own RPATH. In particular, do not inject LD_LIBRARY_PATH
              # or DYLD_* into wrappers because arbitrary user build actions
              # inherit the wrapper environment.
              for b in "$out"/bin/*; do
                wrapProgram "$b" \
                  --set-default REPROBUILD_RUNTIME_LIBRARY_PATH ${runtimeLibraryPath} \
                  --set-default REPROBUILD_SOURCE_ROOT ${reprobuildSource} \
                  --set-default BLAKE3_PREFIX ${blake3Prefix} \
                  --set-default NIMCRYPTO_SRC ${nimcrypto-src} \
                  --set-default BEARSSL_SRC ${bearssl-src} \
                  --set-default STACKABLE_HOOKS_SRC ${stackable-hooks-src}/src \
                  --set-default IO_MON_SRC ${io-mon-src}/src \
                  --set-default SHM_GSET_SRC ${nim-shm-gset-src}/src \
                  --set-default SHM_QUEUE_SRC ${nim-shm-queue-src}/src \
                  --set-default REPRO_CT_TEST_RUNNER_SRC ${reprobuild-ct-test-runner-src} \
                  --set-default REPRO_TEST_ADAPTERS_SRC ${reprobuild-test-adapters-src}/src \
                  --set-default CT_INTERPOSE_SRC ${ctInterposeSrc} \
                  --set-default REPROBUILD_USE_SYSTEM_HASH_LIBS 1 \
                  --set-default REPROBUILD_NIX_DAEMON_BIN "$out/libexec/reprobuild-nix-daemon" \
                  --set-default RUNQUOTA_SRC ${runquota-src} \
                  --set-default SQLITE_PREFIX ${pkgs.sqlite.out} \
                  --set-default XXHASH_PREFIX ${pkgs.xxHash} \
                  --set-default CLINGO_PREFIX ${pkgs.clingo}
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
          reprobuildClosure = pkgs.closureInfo {
            rootPaths = [ reprobuild ];
          };
          packagedRuntimeCompileCheck =
            pkgs.runCommand "reprobuild-packaged-runtime-compile"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gcc
                  pkgs.gnugrep
                ]
                ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ]
                ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
                  pkgs.binutils
                  pkgs.cctools
                  pkgs.darwin.sigtool
                ];
              }
              ''
                                    export HOME="$TMPDIR/home"
                                    export TMPDIR="$TMPDIR/tmp"
                                    mkdir -p "$HOME" "$TMPDIR" "$TMPDIR/direct/project"

                                    daemonEndpoint="$TMPDIR/packaged-repro-daemon.sock"
                                    daemonState="$TMPDIR/packaged-daemon-state"
                                    daemonRuntime="$TMPDIR/packaged-daemon-runtime"
                                    runtimePath=${
                                      pkgs.lib.makeBinPath [
                                        pkgs.bash
                                        pkgs.coreutils
                                        pkgs.gcc
                                        pkgs.gnugrep
                                      ]
                                    }

                                    runDaemonControl() {
                                      ${pkgs.coreutils}/bin/env -i \
                                        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$runtimePath" \
                                        REPRO_DAEMON_RUNTIME_DIR="$daemonRuntime" \
                                        ${reprobuild}/bin/repro daemon "$1" \
                                          --endpoint "$daemonEndpoint" \
                                          --state-dir "$daemonState" \
                                          --log "$daemonState/logs/repro-daemon.log"
                                    }
                                    cleanupDaemon() {
                                      runDaemonControl stop >/dev/null 2>&1 || true
                                      rm -f "$daemonEndpoint"
                                    }
                                    showFailureLogs() {
                                      status=$?
                                      for log in \
                                        "$TMPDIR/direct-build.log" \
                                        "$TMPDIR/daemon-build.log" \
                                        "$TMPDIR/daemon-status.log" \
                                        "$TMPDIR/explicit-override.log"; do
                                        if test -f "$log"; then
                                          echo "--- tail of $log ---" >&2
                                          tail -n 200 "$log" >&2
                                        fi
                                      done
                                      exit "$status"
                                    }
                                    trap cleanupDaemon EXIT
                                    trap showFailureLogs ERR

                                    assertColdActionLog() {
                                      log="$1"
                                      test "$(grep -Ec '^providerCompileAction: ' "$log")" -eq 1
                                      test "$(grep -Ec '^action: ' "$log")" -eq 3
                                      test "$(grep -Ec '^providerCompileAction: __repro_provider_compile status=asSucceeded launched=true( |$)' "$log")" -eq 1
                                      for actionName in build-dir compile-hello run-hello; do
                                        test "$(grep -Ec "^action: $actionName status=asSucceeded launched=true( |$)" "$log")" -eq 1
                                      done
                                      if grep -Eq '^(providerCompileAction|action): .*status=(asFailed|asBlocked|asSkipped|asUpToDate|asCacheHit)' "$log"; then
                                        echo "cold package gate accepted a non-launched action" >&2
                                        return 1
                                      fi
                                    }

                                    # Every public entry point must be a wrapper paired with one
                                    # hidden target. Enumerate rather than hard-code the current
                                    # binaries so newly installed helpers (including scripts)
                                    # cannot bypass the packaged defaults.
                                    wrapperCount=0
                                    for wrapper in ${reprobuild}/bin/*; do
                                      name=$(basename "$wrapper")
                                      hidden=${reprobuild}/bin/.$name-wrapped
                                      test -f "$hidden"
                                      grep -Fq "$hidden" "$wrapper"
                                      if grep -Eq 'LD_LIBRARY_PATH|DYLD_(LIBRARY_PATH|FALLBACK_LIBRARY_PATH)' "$wrapper"; then
                                        echo "loader search path leaked through wrapper: $wrapper" >&2
                                        exit 1
                                      fi
                                      while IFS='|' read -r variable expected; do
                                        grep -Fq "$variable" "$wrapper"
                                        grep -Fq "$expected" "$wrapper"
                                      done <<DEFAULTS
                REPROBUILD_RUNTIME_LIBRARY_PATH|${runtimeLibraryPath}
                REPROBUILD_SOURCE_ROOT|${reprobuildSource}
                BLAKE3_PREFIX|${blake3Prefix}
                NIMCRYPTO_SRC|${nimcrypto-src}
                BEARSSL_SRC|${bearssl-src}
                STACKABLE_HOOKS_SRC|${stackable-hooks-src}/src
                IO_MON_SRC|${io-mon-src}/src
                SHM_GSET_SRC|${nim-shm-gset-src}/src
                SHM_QUEUE_SRC|${nim-shm-queue-src}/src
                REPRO_CT_TEST_RUNNER_SRC|${reprobuild-ct-test-runner-src}
                REPRO_TEST_ADAPTERS_SRC|${reprobuild-test-adapters-src}/src
                CT_INTERPOSE_SRC|${ctInterposeSrc}
                REPROBUILD_USE_SYSTEM_HASH_LIBS|1
                RUNQUOTA_SRC|${runquota-src}
                SQLITE_PREFIX|${pkgs.sqlite.out}
                XXHASH_PREFIX|${pkgs.xxHash}
                CLINGO_PREFIX|${pkgs.clingo}
                DEFAULTS
                                      wrapperCount=$((wrapperCount + 1))
                                    done
                                    test "$wrapperCount" -gt 0
                                    for hidden in ${reprobuild}/bin/.*-wrapped; do
                                      name=$(basename "$hidden")
                                      publicName=$(printf '%s' "$name" | sed -e 's/^\.//' -e 's/-wrapped$//')
                                      test -f "${reprobuild}/bin/$publicName"
                                    done

                                    ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                                      # Every installed ELF role, including hidden wrapper
                                      # targets and .old libraries, carries all six package
                                      # runtime dirs as distinct DT_RPATH entries.
                                      elfCount=0
                                      for candidate in ${reprobuild}/bin/* ${reprobuild}/bin/.*-wrapped ${reprobuild}/lib/*; do
                                        if rpath=$(${pkgs.patchelf}/bin/patchelf --print-rpath "$candidate" 2>/dev/null); then
                                          elfCount=$((elfCount + 1))
                                          for requiredRpath in \
                                            ${blake3Prefix}/lib \
                                            ${pkgs.xxHash}/lib \
                                            ${pkgs.sqlite.out}/lib \
                                            ${pkgs.openssl.out}/lib \
                                            ${pkgs.zstd.out}/lib \
                                            ${pkgs.clingo}/lib; do
                                            case ":$rpath:" in
                                              *":$requiredRpath:"*) ;;
                                              *) echo "incomplete RPATH on $candidate: $rpath" >&2; exit 1 ;;
                                            esac
                                          done
                                        else
                                          case "$candidate" in
                                            ${reprobuild}/lib/*|${reprobuild}/bin/.*-wrapped)
                                              echo "non-ELF installed binary/library role: $candidate" >&2
                                              exit 1
                                              ;;
                                          esac
                                        fi
                                      done
                                      test "$elfCount" -gt 0
                                    ''}

                                    ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
                                      # Use the same strict per-slice audit exercised by the
                                      # Linux-hosted behavioral fixture. It resolves dependency
                                      # tokens against each architecture's own LC_RPATH list and
                                      # verifies final arm signatures after postFixup mutation.
                                      ${pkgs.bash}/bin/bash ${./scripts/audit_macho_runtime.sh} \
                                        ${reprobuild} \
                                        ${blake3Prefix}/lib \
                                        ${pkgs.xxHash}/lib \
                                        ${pkgs.sqlite.out}/lib \
                                        ${pkgs.openssl.out}/lib \
                                        ${pkgs.zstd.out}/lib \
                                        ${pkgs.clingo}/lib

                                      # Prove the installed program bytes use LC_RPATH-aware
                                      # dlopen names, not bare leaf names. The pure target helper
                                      # tests pin the same constants on Linux before this gate.
                                      zstdLoaderCount=0
                                      clingoLoaderCount=0
                                      for candidate in ${reprobuild}/bin/.*-wrapped ${reprobuild}/lib/*; do
                                        if lipo -archs "$candidate" >/dev/null 2>&1; then
                                          loaderStrings=$(strings "$candidate")
                                          if printf '%s\n' "$loaderStrings" | grep -Fxq '@rpath/libzstd.1.dylib'; then
                                            zstdLoaderCount=$((zstdLoaderCount + 1))
                                          fi
                                          if printf '%s\n' "$loaderStrings" | grep -Fxq '@rpath/libclingo.dylib'; then
                                            clingoLoaderCount=$((clingoLoaderCount + 1))
                                          fi
                                          if printf '%s\n' "$loaderStrings" | grep -Fxq 'libzstd.1.dylib'; then
                                            echo "bare zstd Darwin loader name in $candidate" >&2
                                            exit 1
                                          fi
                                          if printf '%s\n' "$loaderStrings" | grep -Fxq 'libclingo.dylib'; then
                                            echo "bare clingo Darwin loader name in $candidate" >&2
                                            exit 1
                                          fi
                                        fi
                                      done
                                      test "$zstdLoaderCount" -gt 0
                                      test "$clingoLoaderCount" -gt 0
                                    ''}

                                    cp -R ${./tests/fixtures/packaged-runtime-compile}/. \
                                      "$TMPDIR/direct/project/"
                                    chmod -R u+w "$TMPDIR/direct/project"

                                    # A source-looking sibling must not shadow the package's pinned
                                    # adapter. The file is intentionally uncompilable: reaching it
                                    # makes the positive real-execution gate fail hard.
                                    hostile="$TMPDIR/direct/reprobuild-test-adapters/src/repro_test_adapters"
                                    mkdir -p "$hostile"
                                    printf '%s\n' '{.error: "HOSTILE_SIBLING_ADAPTER_WAS_USED".}' \
                                      > "$hostile/test_runner.nim"

                                    # Direct cold build: env -i deliberately omits the source root
                                    # and every package prefix so the wrapper defaults are exercised.
                                    (
                                      cd "$TMPDIR/direct/project"
                                      ${pkgs.coreutils}/bin/env -i \
                                        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$runtimePath" \
                                        REPROBUILD_STORE_ROOT="$TMPDIR/direct-store" \
                                        REPROBUILD_ACTION_CACHE_ROOT="$TMPDIR/direct-action-cache" \
                                        ${reprobuild}/bin/repro build . \
                                          --daemon=off --no-runquota \
                                          --tool-provisioning=path --progress=none --log=actions
                                    ) > "$TMPDIR/direct-build.log" 2>&1
                                    assertColdActionLog "$TMPDIR/direct-build.log"
                                    test "$(cat "$TMPDIR/direct/project/build/hello-output.txt")" = \
                                      "reprobuild packaged runtime: hello"
                                    if grep -Fq HOSTILE_SIBLING_ADAPTER_WAS_USED "$TMPDIR/direct-build.log"; then
                                      echo "packaged build selected the hostile sibling adapter" >&2
                                      exit 1
                                    fi

                                    # CodeTracer-style positive override: a writable source copy
                                    # with spaces and shell metacharacters, while every external
                                    # source/prefix remains the installed wrapper default. Start a
                                    # real isolated daemon first so --daemon=require cannot fall
                                    # back to direct execution.
                                    sourceOverride="$TMPDIR/CodeTracer source [override] #1;copy"
                                    daemonProject="$TMPDIR/daemon project [override] #1"
                                    mkdir -p "$sourceOverride" "$daemonProject"
                                    cp -R ${reprobuildSource}/. "$sourceOverride/"
                                    cp -R ${./tests/fixtures/packaged-runtime-compile}/. "$daemonProject/"
                                    chmod -R u+w "$sourceOverride" "$daemonProject"
                                    runDaemonControl start > "$TMPDIR/daemon-start.log" 2>&1
                                    runDaemonControl status > "$TMPDIR/daemon-status.log" 2>&1
                                    grep -Fq 'repro daemon: running' "$TMPDIR/daemon-status.log"
                                    (
                                      cd "$daemonProject"
                                      ${pkgs.coreutils}/bin/env -i \
                                        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$runtimePath" \
                                        REPRO_DAEMON_ENDPOINT="$daemonEndpoint" \
                                        REPRO_DAEMON_STATE_DIR="$daemonState" \
                                        REPRO_DAEMON_RUNTIME_DIR="$daemonRuntime" \
                                        REPROBUILD_SOURCE_ROOT="$sourceOverride" \
                                        REPROBUILD_STORE_ROOT="$TMPDIR/daemon-store" \
                                        REPROBUILD_ACTION_CACHE_ROOT="$TMPDIR/daemon-action-cache" \
                                        ${reprobuild}/bin/repro build . \
                                          --daemon=require --no-runquota \
                                          --tool-provisioning=path --progress=none --log=actions
                                    ) > "$TMPDIR/daemon-build.log" 2>&1
                                    assertColdActionLog "$TMPDIR/daemon-build.log"
                                    test "$(cat "$daemonProject/build/hello-output.txt")" = \
                                      "reprobuild packaged runtime: hello"
                                    runDaemonControl status > "$TMPDIR/daemon-status.log" 2>&1
                                    grep -Fq 'active-sessions: 0' "$TMPDIR/daemon-status.log"
                                    runDaemonControl stop > "$TMPDIR/daemon-stop.log" 2>&1
                                    runDaemonControl status > "$TMPDIR/daemon-after-stop.log" 2>&1
                                    grep -Fq 'repro daemon: not-running' "$TMPDIR/daemon-after-stop.log"
                                    test ! -e "$daemonEndpoint"

                                    # makeWrapper defaults must preserve explicit overrides. A
                                    # deliberately broken adapter must be selected, not masked.
                                    mkdir -p "$TMPDIR/explicit-adapter/src/repro_test_adapters" \
                                      "$TMPDIR/override-project"
                                    cp -R ${./tests/fixtures/packaged-runtime-compile}/. \
                                      "$TMPDIR/override-project/"
                                    chmod -R u+w "$TMPDIR/override-project"
                                    printf '%s\n' '{.error: "EXPLICIT_ADAPTER_OVERRIDE_WAS_USED".}' \
                                      > "$TMPDIR/explicit-adapter/src/repro_test_adapters/test_runner.nim"
                                    if (
                                      cd "$TMPDIR/override-project"
                                      ${pkgs.coreutils}/bin/env -i \
                                        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$runtimePath" \
                                        REPRO_TEST_ADAPTERS_SRC="$TMPDIR/explicit-adapter/src" \
                                        REPROBUILD_STORE_ROOT="$TMPDIR/override-store" \
                                        REPROBUILD_ACTION_CACHE_ROOT="$TMPDIR/override-action-cache" \
                                        ${reprobuild}/bin/repro build . \
                                          --daemon=off --no-runquota \
                                          --tool-provisioning=path --progress=none --log=actions
                                    ) > "$TMPDIR/explicit-override.log" 2>&1; then
                                      echo "packaged wrapper masked an explicit adapter override" >&2
                                      exit 1
                                    fi
                                    grep -Fq EXPLICIT_ADAPTER_OVERRIDE_WAS_USED \
                                      "$TMPDIR/explicit-override.log"

                                    # Every source/prefix used as an installed-runtime default must be
                                    # a real member of the package closure, not an ambient store path.
                                    cp ${reprobuildClosure}/store-paths "$TMPDIR/package-closure"
                                    for required in \
                                      ${reprobuildSource} \
                                      ${nimcrypto-src} \
                                      ${bearssl-src} \
                                      ${stackable-hooks-src} \
                                      ${io-mon-src} \
                                      ${nim-shm-gset-src} \
                                      ${nim-shm-queue-src} \
                                      ${reprobuild-ct-test-runner-src} \
                                      ${reprobuild-test-adapters-src} \
                                      ${codetracer-native-recorder} \
                                      ${runquota-src} \
                                      ${blake3Prefix} \
                                      ${pkgs.sqlite.out} \
                                      ${pkgs.xxHash} \
                                      ${pkgs.openssl.out} \
                                      ${pkgs.zstd.out} \
                                      ${pkgs.clingo}; do
                                      if ! grep -Fxq "$required" "$TMPDIR/package-closure"; then
                                        echo "missing packaged runtime closure path: $required" >&2
                                        exit 1
                                      fi
                                    done

                                    mkdir -p "$out"
                                    cp "$TMPDIR/direct-build.log" "$out/"
                                    cp "$TMPDIR/daemon-build.log" "$out/"
                                    cp "$TMPDIR/package-closure" "$out/"
              '';
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
          #  * The single `repro` CLI links OpenSSL (`--define:ssl`) and, at
          #    MODULE-INIT time (Nim `{.dynlib.}`
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
          # executable launches the single `repro` image from the extracted
          # closure. It ADDS to — and does not
          # disturb — `packages.default`/`packages.reprobuild` or `just build`.
          reproPortable = bundlers.bundlers.${system}.toArx reprobuild;
        in
        {
          apps.default = reproApp;
          apps.repro = reproApp;
          apps.repro-binary-cache = reproBinaryCacheApp;

          packages.default = reprobuild;
          packages.reprobuild = reprobuild;
          # The Nim fork toolchain, exposed for standalone build/verification.
          packages.nim-fork = nimFork;
          packages.repro-binary-cache = reproBinaryCache;
          # Self-contained, /nix/store-free `repro` (see `reproPortable`).
          packages.repro-portable = reproPortable;

          checks = {
            inherit pre-commit-check;
            package-build = reprobuild;
            packaged-runtime-compile = packagedRuntimeCompileCheck;
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
            # openssl is likewise dlopen'd: binaries built `--define:ssl` (e.g.
            # repro-harvest-apt's HTTPS fetch via std/net) carry a bare
            # `dlopen("libcrypto.so.3")`, so a bootstrapped `repro` aborts with
            # "could not load: libcrypto.so" in the bare dev shell without it.
            #
            # pcre is here for a DIFFERENT reason, and the distinction matters
            # for anyone tempted to "fix" it in `nix/nim-fork.nix` instead. The
            # Nim toolchain IS self-contained: `nix/nim-fork.nix` already lists
            # pcre in `buildInputs` and patchelfs the pcre lib dir into
            # `bin/nim`'s RUNPATH, and a bare `nim --version` loads
            # `libpcre.so.1` fine. What breaks is monitored execution. The
            # provider-compile edge runs `nim c` under automatic monitoring,
            # which LD_PRELOADs `librepro_monitor_shim.so`; the shim interposes
            # `dlopen`, so the forwarded call is issued from the shim's own DSO
            # and the monitored binary's DT_RUNPATH stops governing the lookup:
            # `LD_PRELOAD=<shim> nim --version` fails with "could not load:
            # libpcre.so(.3|.1|)" while the identical command without the shim
            # succeeds. LD_LIBRARY_PATH is process-global — consulted before
            # any DT_RUNPATH and independent of which DSO issued the call — so
            # listing pcre here restores resolution under interposition. The
            # durable fix is in io-mon's dlopen hook, which should resolve
            # against the calling binary's link map; that lives in io-mon's
            # repo, not this one. `scripts/check_toolchain_dlopen.sh` guards
            # this whole class (see `just check-toolchain-dlopen`).
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
              pkgs.clingo
              pkgs.zstd
              pkgs.openssl
              pkgs.pcre
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
              # ``ct-test`` — CodeTracer's cross-language test driver. On PATH
              # so `ct-test test discover|run` is available in the dev shell
              # without a hand build. Nothing in reprobuild's own build or test
              # path consumes it yet; wiring it into scripts/run_tests.sh is a
              # separate, later step. One thing to know before relying on it:
              # it is whatever ``codetracer-src`` is pinned to, not whatever is
              # in a sibling checkout. Changes made in a local codetracer tree
              # reach this binary only once they are pushed and the pin is
              # bumped (or the input is overridden for the session).
              #
              # ``test run`` is safe at any ``--threads`` value on this pin. An
              # earlier pin aborted during teardown once a run used 21 or more
              # workers — a heap-lifetime bug in CodeTracer's
              # ``run_orchestration.runUnits``, where worker-allocated results
              # were freed after their threads had exited. It is fixed at the
              # source by that module's ``ResultHandoff``, and the pin is now
              # past the fix. Any ``--threads`` cap set because of it can go;
              # such a cap never made anything safe in the first place.
              ctTestTools
              pkgs.just
              nimFork
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
