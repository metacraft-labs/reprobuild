# The reprobuild build system, in nixpkgs `pkgs/by-name/` form.
#
# ONE DERIVATION, TWO SOURCE-PROVISIONING STRATEGIES. This file is the single
# definition of the reprobuild derivation. A nixpkgs consumer gets it through
# the by-name resolver with every source argument defaulting to an ordinary
# fixed-output `fetchFromGitHub`; reprobuild's own `flake.nix` gets the SAME
# derivation through `pkgs.callPackage`, overriding each source argument with
# the corresponding flake input so `--override-input` and the `.envrc` sibling
# overrides keep working. Before this, `flake.nix` and this file each carried
# their own copy of the build and the copies had drifted badly — this one was
# still on version 0.1.0, `nim2` instead of the fork, `rev = "main"` (a retired
# branch, and a moving ref in a fixed-output fetch), and three of the thirteen
# source inputs the build actually needs.
#
# Distribution-And-Packaging §9 / M4: "Add a `reprobuild` package to the
# `metacraft-labs/nixpkgs` fork, packaged for eventual upstream submission
# (respecting nixpkgs conventions; reuse the flake derivation's wrapper/RPATH
# logic)."
#
# UPSTREAM-SUBMISSION STATUS — read `../../../../README.md` before assuming this
# is ready for a nixpkgs PR. In short: everything here is nixpkgs-legal
# (fixed-output fetches, no network at build time, no flake plumbing, no
# vendored binaries), but the `nimFork` dependency — a from-source build of an
# unreleased Nim compiler fork — is a genuine reviewer objection that packaging
# cannot paper over.
{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  just,
  makeWrapper,
  symlinkJoin,
  patchelf,
  python3,
  bash,
  coreutils,
  file,
  fixDarwinDylibNames,
  darwin,
  libblake3,
  xxhash,
  sqlite,
  openssl,
  zstd,
  clingo,

  # The Nim toolchain: the metacraft-labs/nim fork (Nim 2.3.1 devel), built from
  # source. See ./nim-fork.nix for why the stock nixpkgs `nim` cannot be used.
  nimFork ? callPackage ./nim-fork.nix { },

  # ── Sources ────────────────────────────────────────────────────────────────
  # Every entry mirrors a `flake.lock` pin. Bump a rev and its hash together:
  # set the hash to `lib.fakeHash`, build, and copy the `got:` line.
  #
  # `src` and `version` are deliberately NOT arguments: `callPackage` fills an
  # argument from the package set whenever the set HAS that name, default or no
  # default, and nixpkgs does have a `src` attribute (a throw that renames it to
  # `simple-revision-control`). A `src ? …` argument therefore blows up on any
  # nixpkgs revision carrying that alias. reprobuild's flake overrides both
  # through `overrideAttrs`, which is the idiom nixpkgs expects anyway, and the
  # `finalAttrs` self-reference below picks the override up.
  nimcryptoSrc ? fetchFromGitHub {
    owner = "cheatfate";
    repo = "nimcrypto";
    rev = "69eec0375dd146aede41f920c702c531bfe89c6b";
    hash = "sha256-Z6oaGzRiai/hLdudDb/VP6euoiEKG6T4sivucfmdFyM=";
  },
  # Submodules=1 pulls bearssl/csources (the upstream BearSSL C tree
  # nim-bearssl wraps); without it the bindings compile but link-fail.
  bearsslSrc ? fetchFromGitHub {
    owner = "status-im";
    repo = "nim-bearssl";
    rev = "9a4eed052abbded2d94feaf3f5bbd95a30ec4671";
    fetchSubmodules = true;
    hash = "sha256-igLvQSJWDL6Gq+pXGrNMDhEl+srXfW0vyLFVh8r9GuY=";
  },
  stackableHooksSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "nim-stackable-hooks";
    rev = "41ab1b987aba67e8bcc34a5945ac33e17b6418ed";
    hash = "sha256-Lv0i9MBGkwPFfEaOxB7y9ixwt7dOvJIKj3W4R/BpyOY=";
  },
  ctTraceFormatSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "codetracer-trace-format-nim";
    rev = "bc7c5d256d0a4b1246f9a9bbb51a83071d3d8e26";
    hash = "sha256-feW0vlgU6JTVkCLnZ1iyS2FwjXQuRCXHr3V+27oyDAw=";
  },
  ioMonSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "io-mon";
    rev = "65b190ba5704454dd33138a2dc82fac8fbc188d6";
    hash = "sha256-BtMWgvvEg+jONDnQIY8osCHshjwAbonB5ArZpqzmYDA=";
  },
  shmGsetSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "nim-shm-gset";
    rev = "c646982b354cb5b1fa8734f94b951a660419d75c";
    hash = "sha256-nO7XSWxBWrLgL8d9q1zhTcGMMjGokZKjYtX9byb9/Vk=";
  },
  shmQueueSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "nim-shm-queue";
    rev = "5a8e43b52fa202859658692c9f8432967f3971ea";
    hash = "sha256-QPYS3OJPza6M2l1FMKa+jt3+mIBHCHWGkLOb9jAKMHs=";
  },
  codetracerSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "codetracer";
    rev = "033f00a1d9df8d7e2cb0368010746acc272a9dce";
    hash = "sha256-L5N0v9haMBtmCjkt3aw4V6dBPPJqqHY17YZL2Muedsk=";
  },
  ctTestRunnerSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "reprobuild-ct-test-runner";
    rev = "397fc59ed3e3d8f774523a6723782c535aaabe58";
    hash = "sha256-Ndf8zh1QB1AeNb+2w0vmMP5UVzakJxj2z4Sv50FfSIQ=";
  },
  testAdaptersSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "reprobuild-test-adapters";
    rev = "360cd50767e548556a0a7510d879f28c87eb3e34";
    hash = "sha256-mj1z79GUGcOOVzADqIo9toLwM0k5xIHaLstKl4a9u64=";
  },
  # Source only. reprobuild compiles `runquota_client`/`_codec`/`_core`/`_ipc`/
  # `_process`/`_protocol` out of this tree; it does not build or ship
  # runquota's own binaries, so none of runquota's build-time dependencies
  # (nim-shm-lease and friends) are needed here.
  runquotaSrc ? fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "runquota";
    rev = "7a79877992908f64d3c8318bb7b20078ff5d1bf4";
    hash = "sha256-7wTdJkutu2VDQFuKIzZgAzJ7X8J3pHXbr3dEcqcVH2Q=";
  },
}:
let
  # libblake3 has split `out`/`dev` outputs (dev has include/blake3.h, out has
  # lib/libblake3.so). config.nims's prefix-lookup expects a single tree
  # containing both, so join them with symlinkJoin. Older/newer nixpkgs ship a
  # single-output libblake3 that already has both; handle either shape.
  blake3Prefix = symlinkJoin {
    name = "libblake3-prefix";
    paths =
      if libblake3 ? dev then
        [
          libblake3.dev
          libblake3.out
        ]
      else
        [ libblake3 ];
  };

  # CodeTracer's top-level ct entry point imports the span-stream writer. Fail
  # during evaluation if a future pin regression silently points at a pre-span
  # trace-format tree; otherwise the first symptom is a slow, opaque native
  # compile failure.
  codeTracerTraceFormatNimSrc =
    let
      sourceRoot = "${ctTraceFormatSrc}/src";
      requiredModule = "${sourceRoot}/codetracer_trace_writer/span_stream.nim";
    in
    if builtins.pathExists requiredModule then
      sourceRoot
    else
      throw "ctTraceFormatSrc must contain ${requiredModule}";

  runtimeLibraries = [
    blake3Prefix
    xxhash
    sqlite.out
    openssl.out
    zstd.out
    clingo
  ];
  runtimeLibraryPath = lib.makeLibraryPath runtimeLibraries;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "reprobuild";

  # A literal, as every nixpkgs package's version is: reading it out of
  # `${src}/reprobuild.nimble` would be import-from-derivation, which nixpkgs
  # forbids. reprobuild's flake overrides it with the value it parses from the
  # nimble manifest, and `checks.nixpkgs-package-version-sync` fails the build
  # if this literal and the manifest disagree, so the two cannot drift silently.
  version = "0.1.3";

  src = fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "reprobuild";
    rev = "f314140067a25fe53acc199481fb115aa1c6be7b";
    hash = "sha256-CLNxSZCVI1Qj8ggpKzgh4ytUeT0Q47XKMbFjsDZsh5E=";
  };

  strictDeps = true;
  dontConfigure = true;

  nativeBuildInputs = [
    just
    makeWrapper
    nimFork
    # Spec-Implementation M2a: clingo is the ASP solver reprobuild's
    # repro_solver lib binds against. The CLI tool is used by smoke tests and
    # the C library (libclingo.so + <clingo/clingo.h>) is what the Nim bindings
    # dlopen at runtime. Adding it to nativeBuildInputs makes the headers
    # visible during `just build`; the buildInputs entry below pulls the shared
    # library into the runtime closure.
    clingo
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    # Rewrites Mach-O install IDs and internal dependency paths before
    # postFixup adds the complete package LC_RPATH set. The signing hook is a
    # postFixupHooks entry: stdenv runs the derivation's postFixup body first,
    # so it signs only after our per-slice mutation and universal-image
    # reassembly.
    fixDarwinDylibNames
    darwin.autoSignDarwinBinariesHook
    coreutils
    file
  ];

  buildInputs = [
    libblake3
    sqlite
    xxhash
    clingo
    # repro-harvest-apt is compiled with --define:ssl (it walks
    # snapshot.debian.org's HTTPS InRelease signature chain), so Nim's std/net
    # openssl backend link step needs -lssl -lcrypto. macOS resolves these from
    # the system SDK, but the Linux nix sandbox has no system openssl — pull it
    # into the closure here.
    openssl
  ];

  env = {
    BLAKE3_PREFIX = "${blake3Prefix}";
    NIMCRYPTO_SRC = "${nimcryptoSrc}";
    BEARSSL_SRC = "${bearsslSrc}";
    STACKABLE_HOOKS_SRC = "${stackableHooksSrc}/src";
    CODETRACER_TRACE_FORMAT_NIM_SRC = codeTracerTraceFormatNimSrc;
    IO_MON_SRC = "${ioMonSrc}/src";
    SHM_GSET_SRC = "${shmGsetSrc}/src";
    SHM_QUEUE_SRC = "${shmQueueSrc}/src";
    # Tier 3 of `config.nims`'s incremental-test-seam resolution, and the tier
    # this build has always needed. It runs in a pure sandbox with no
    # `../codetracer` in reach, so before this variable existed the packaged
    # build was the one build that compiled the standalone copy in
    # `reprobuild-ct-test-runner` instead of the file CodeTracer actually owns
    # — silently, and only because of where the sandbox happens to sit.
    #
    # NOT `CODETRACER_SRC`: that name belongs to the user override.
    CODETRACER_PINNED_SRC = "${codetracerSrc}/src";
    REPRO_CT_TEST_RUNNER_SRC = "${ctTestRunnerSrc}";
    REPRO_TEST_ADAPTERS_SRC = "${testAdaptersSrc}/src";
    REPROBUILD_USE_SYSTEM_HASH_LIBS = "1";
    RUNQUOTA_SRC = "${runquotaSrc}";
    SQLITE_PREFIX = "${sqlite.out}";
    XXHASH_PREFIX = "${xxhash}";
  };

  buildPhase = ''
    runHook preBuild
    just build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/lib" \
      "$out/share/reprobuild/nim-macro-sourcemaps/bin" \
      "$out/share/reprobuild/nim-macro-sourcemaps/lib"
    for bin in build/bin/*; do
      case "$bin" in
        *.json)
          # Nim emits macro source maps next to compiled binaries. Keep them as
          # package data, outside the public entry-point directory audited for
          # executable runtime roles.
          install -m644 "$bin" \
            "$out/share/reprobuild/nim-macro-sourcemaps/bin/$(basename "$bin")"
          ;;
        *)
          install -m755 "$bin" "$out/bin/$(basename "$bin")"
          ;;
      esac
    done
    for lib in build/lib/*; do
      [ -e "$lib" ] || continue
      case "$lib" in
        *.json)
          install -m644 "$lib" \
            "$out/share/reprobuild/nim-macro-sourcemaps/lib/$(basename "$lib")"
          ;;
        *)
          install -m755 "$lib" "$out/lib/$(basename "$lib")"
          ;;
      esac
    done

    # `reprobuild-nix-daemon` is the helper that `tool-provisioning=nix`
    # resolutions talk to. It used to be reachable only through
    # $REPROBUILD_SOURCE_ROOT/tools, i.e. an unpatched source checkout, so its
    # `#!/usr/bin/env python3` picked up whatever interpreter happened to be on
    # PATH. Under launchd's default environment that is macOS's system python3
    # (3.9), which cannot parse the script's PEP 604 `X | None` annotations —
    # the child died instantly and its stderr went to an unread pipe.
    #
    # Installing it here pins an absolute, known-good interpreter. libexec (not
    # bin) keeps it out of the wrapProgram loop below, which is for CLI entry
    # points. The interpreter is substituted explicitly rather than via
    # patchShebangs: bare patchShebangs resolves against HOST_PATH, whereas a
    # nativeBuildInputs python3 lands on the build PATH, so it silently left
    # `env python3` in place. --replace-fail also turns a future upstream
    # shebang change into a build error instead of silently restoring the
    # ambient-PATH behaviour.
    mkdir -p "$out/libexec"
    install -m755 tools/reprobuild-nix-daemon/reprobuild-nix-daemon \
      "$out/libexec/reprobuild-nix-daemon"
    substituteInPlace "$out/libexec/reprobuild-nix-daemon" \
      --replace-fail '#!/usr/bin/env python3' \
        '#!${python3}/bin/python3'
    runHook postInstall
  '';

  # Installed entry points span ordinary linked libraries and bare leaf-name
  # dlopen()s (notably zstd and clingo). Normal fixup only retains paths visible
  # from link dependencies, so restore the full runtime family for every
  # installed ELF/Mach-O role. Linux uses a transitive DT_RPATH; Darwin needs
  # one LC_RPATH load command per directory and valid install IDs for every
  # installed dylib.
  postFixup = ''
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      for b in "$out"/bin/* "$out"/lib/*; do
        if orig=$(${patchelf}/bin/patchelf --print-rpath "$b" 2>/dev/null); then
          ${patchelf}/bin/patchelf --force-rpath \
            --set-rpath "$orig''${orig:+:}${runtimeLibraryPath}" "$b"
        fi
      done
    ''}

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      # fixDarwinDylibNames is a fixupOutputHook and has already run. Copy thin
      # images or extract universal slices, mutate each architecture
      # independently, then reassemble universal images.
      # autoSignDarwinBinariesHook is registered in postFixupHooks, which stdenv
      # invokes after this implicit postFixup body, so arm64/arm64e signatures
      # cover final bytes.
      FILE=${file}/bin/file \
      STAT=${coreutils}/bin/stat \
      CP=${coreutils}/bin/cp \
      MV=${coreutils}/bin/mv \
      ${bash}/bin/bash ${finalAttrs.src}/scripts/fixup_macho_runtime.sh "$out" \
        ${lib.concatStringsSep " " (map (library: "${library}/lib") runtimeLibraries)}
    ''}

    # Provider/interface compilation happens after installation, in the caller's
    # project. Keep the package's exact source inputs in its runtime closure and
    # expose them as defaults to every entry point. `--set-default` preserves
    # explicit development/source overrides while making an ordinary installed
    # package independent of sibling checkouts and the build-time dev shell.
    # REPROBUILD_RUNTIME_LIBRARY_PATH is compiler input, not a loader variable:
    # generated interface/provider binaries bake these dirs into their own
    # RPATH. In particular, do not inject LD_LIBRARY_PATH or DYLD_* into
    # wrappers because arbitrary user build actions inherit the wrapper
    # environment.
    #
    # THE NAME LIST IS A CONTRACT. `runtime_contract.ReprobuildWrapperVariables`
    # re-derives it and `t_packaging_wrapper_vars_match_flake.nim` fails if the
    # two disagree, because a `--set-default` the native packaging layer does
    # not know about produces a working Nix build and a `.deb` whose binary dies
    # on the user's machine.
    for b in "$out"/bin/*; do
      test -x "$b" || continue
      wrapProgram "$b" \
        --set-default REPROBUILD_RUNTIME_LIBRARY_PATH ${runtimeLibraryPath} \
        --set-default REPROBUILD_SOURCE_ROOT ${finalAttrs.src} \
        --set-default BLAKE3_PREFIX ${blake3Prefix} \
        --set-default NIMCRYPTO_SRC ${nimcryptoSrc} \
        --set-default BEARSSL_SRC ${bearsslSrc} \
        --set-default STACKABLE_HOOKS_SRC ${stackableHooksSrc}/src \
        --set-default CODETRACER_TRACE_FORMAT_NIM_SRC ${codeTracerTraceFormatNimSrc} \
        --set-default IO_MON_SRC ${ioMonSrc}/src \
        --set-default SHM_GSET_SRC ${shmGsetSrc}/src \
        --set-default SHM_QUEUE_SRC ${shmQueueSrc}/src \
        --set-default CODETRACER_PINNED_SRC ${codetracerSrc}/src \
        --set-default REPRO_CT_TEST_RUNNER_SRC ${ctTestRunnerSrc} \
        --set-default REPRO_TEST_ADAPTERS_SRC ${testAdaptersSrc}/src \
        --set-default REPROBUILD_USE_SYSTEM_HASH_LIBS 1 \
        --set-default REPROBUILD_NIX_DAEMON_BIN "$out/libexec/reprobuild-nix-daemon" \
        --set-default RUNQUOTA_SRC ${runquotaSrc} \
        --set-default SQLITE_PREFIX ${sqlite.out} \
        --set-default XXHASH_PREFIX ${xxhash} \
        --set-default CLINGO_PREFIX ${clingo} \
        --set-default REPRO_NIM_COMPILER ${nimFork}/bin/nim
    done
  '';

  # Exposed so a consumer that has to compile against the SAME prefixes this
  # package was fixed up against (reprobuild's dev shell, its pre-commit hooks,
  # and its packaged-runtime-compile check) can read them back instead of
  # re-deriving them. A second `symlinkJoin` or a second `runtimeLibraries` list
  # spelled out elsewhere is exactly how the two would come to differ.
  passthru = {
    inherit
      blake3Prefix
      codeTracerTraceFormatNimSrc
      runtimeLibraries
      runtimeLibraryPath
      nimFork
      ;
  };

  meta = {
    description = "Reprobuild build system";
    homepage = "https://github.com/metacraft-labs/reprobuild";
    license = lib.licenses.mit;
    mainProgram = "repro";
    maintainers = [ ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
})
