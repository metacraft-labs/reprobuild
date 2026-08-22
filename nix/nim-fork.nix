# Builds the metacraft-labs/nim fork (codetracer-nim, Nim 2.3.1 devel) as
# reprobuild's Nim toolchain, replacing nixpkgs' nim-unwrapped-2.2.4.
#
# Why the fork: it carries a compiler-side effect-inference fix that makes
# `std/streams`/`std/json` compile under `--mm:orc -d:useNimRtl` (which the
# stock 2.2.x compiler rejects), and adds CodeTracer's column-aware tracer.
#
# Build is koch-boot-free (koch's nifler/nimony tools fail and are irrelevant to
# the compiler proper): bootstrap a stage-0 `nim` from csources_v3, then compile
# `compiler/nim.nim` directly. The fork compiler itself imports the CodeTracer
# trace-writer + stew + results, so those three are vendored under `dist/`
# exactly where `config/nim.cfg` expects them (`$nim/dist/...`).
{
  pkgs,
  forkSrc,
  csourcesSrc,
  traceFormatSrc,
  stewSrc,
  resultsSrc,
  checksumsSrc,
  nimonySrc,
}:
pkgs.stdenv.mkDerivation {
  pname = "nim-fork";
  version = "2.3.1-codetracer";
  src = forkSrc;

  nativeBuildInputs = [
    pkgs.gcc
    pkgs.gnumake
    pkgs.which
  ]
  # patchelf is only used to fix up the ELF RUNPATH on Linux (see installPhase);
  # on Darwin the compiler is a Mach-O binary and stdenv's own install_name
  # fixup handles library references, so patchelf is neither available nor needed.
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [pkgs.patchelf];
  # zstd is a link-time requirement of the fork compiler (CTFS-M1 trace writer);
  # pcre/openssl are pulled in for the compiler's runtime dlopen safety.
  buildInputs = [
    pkgs.zstd
    pkgs.zstd.dev
    pkgs.pcre
    pkgs.openssl
  ];

  dontConfigure = true;
  # The compiler + stage-0 are already optimized; stripping the fork tree's
  # stdlib would break nothing but keep the tree faithful to a normal checkout.
  dontStrip = true;
  # The vendored dist/ trees carry dev-only symlinks (e.g. a pre-commit config)
  # that dangle once separated from their source repo; they are irrelevant to
  # the compiler. Prune them in installPhase and also disable the fixup check.
  dontCheckForBrokenSymlinks = true;
  # nim dlopens libpcre/libzstd at runtime by soname; they are not DT_NEEDED, so
  # nixpkgs' fixup `patchelf --shrink-rpath` would strip the RUNPATH we set in
  # installPhase (leaving `nim` unable to load libpcre). Disable the auto-patchelf
  # so our explicit --set-rpath survives. This is an ELF-only concern; on Darwin
  # the analogous fixup is stdenv's install_name pass, which we want to run.
  dontPatchELF = pkgs.stdenv.hostPlatform.isLinux;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"

    echo "[nim-fork] 1/4 bootstrap stage-0 nim from csources_v3"
    cp -r ${csourcesSrc} csources_v3
    chmod -R u+w csources_v3
    make -C csources_v3 -j"$NIX_BUILD_CORES" CC="$CC"
    test -x bin/nim

    echo "[nim-fork] 2/4 vendor the fork compiler's deps under dist/"
    mkdir -p dist
    cp -r ${traceFormatSrc} dist/codetracer-trace-format-nim
    cp -r ${stewSrc}        dist/nim-stew
    cp -r ${resultsSrc}     dist/nim-results
    # nim devel split md5/sha1 into the standalone `checksums` package, which
    # koch normally bundles into dist/; the compiler imports checksums/{md5,sha1}.
    cp -r ${checksumsSrc}   dist/checksums
    # nim devel's compiler also imports nimony/src/lib/treemangler (koch bundles
    # nimony non-recursively — its submodule is Nim itself, which we already are).
    cp -r ${nimonySrc}      dist/nimony
    chmod -R u+w dist

    # `nimpretty` is the FORMATTER half of the toolchain, and it has to come
    # from the FORK for the same reason the compiler does. `scripts/
    # format_sources.sh` (and therefore `just format`, a command CLAUDE.md
    # documents) guards its nimpretty arm with `command -v nimpretty`, and this
    # derivation shipped none — the fork's `bin/` carries only `nim`, `nim-gdb`
    # and `nim-gdb.bat` — so `just format` formatted `flake.nix` and exited 0
    # having touched ZERO Nim files. Silently.
    #
    # The obvious repair, adding nixpkgs' `nim` wrapper (which does bundle
    # nimpretty) to the dev shell, is the WRONG one and was correctly declined
    # before: that nimpretty is built from Nim 2.2.4 while this tree is compiled
    # by a 2.3.1 fork, so the formatter's parser and the compiler's parser would
    # be different programs. A formatter that cannot parse what the compiler
    # accepts rewrites or mangles it. Building nimpretty from `${forkSrc}`
    # removes the skew by construction: same lexer, same parser, same layouter
    # source as the compiler installed next to it.
    #
    # Built with the STAGE-0 compiler, deliberately. Only codegen depends on
    # which compiler builds it; nimpretty's BEHAVIOUR comes from the fork's
    # `compiler/{lexer,parser,layouter,...}` modules, which are the ones being
    # compiled here either way. Using stage-0 also keeps the buildPhase rule
    # below intact — the freshly built fork `bin/nim` must not be RUN before
    # installPhase patchelfs its RUNPATH. This must therefore stay BEFORE the
    # step that overwrites `bin/nim`.
    #
    # `nimpretty/nimpretty.nim.cfg` supplies `--define:nimpretty`, which the
    # source hard-requires ({.error.} without it); `--skipParentCfg` does not
    # suppress a project's own cfg, only parent-directory ones.
    echo "[nim-fork] 3/4 build nimpretty from the fork (formatter/compiler skew)"
    ./bin/nim c -d:release \
      --skipUserCfg --skipParentCfg --noNimblePath \
      --warning:BareExcept:off --warning:UnusedImport:off \
      -o:bin/nimpretty nimpretty/nimpretty.nim
    test -x bin/nimpretty

    echo "[nim-fork] 4/4 compile the fork compiler proper (koch-boot-free)"
    ./bin/nim c -d:release -d:nimKochBootstrap \
      --skipUserCfg --skipParentCfg --noNimblePath \
      --warning:BareExcept:off --warning:UnusedImport:off \
      --passC:-I${pkgs.zstd.dev}/include \
      --passL:-L${pkgs.zstd.out}/lib \
      -o:bin/nim compiler/nim.nim
    # NB: do not run the freshly-built `bin/nim` here — it dlopens libpcre at
    # startup and is not RPATH-wrapped until installPhase, so it would fail in
    # the sandbox. The post-patchelf `nim --version` in installPhase is the real
    # runnable-output check.
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    # Ship a faithful Nim installation tree: the compiler + stdlib + config +
    # the vendored dist/ deps that config/nim.cfg references on every compile.
    cp -r bin lib config dist "$out/"
    ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      # Linux: nim dlopens libpcre/libzstd by soname, so bake the store lib dirs
      # into the compiler's RUNPATH (dontPatchELF above keeps this from being
      # shrunk away).
      patchelf --set-rpath "${
        pkgs.lib.makeLibraryPath [
          pkgs.zstd
          pkgs.pcre
          pkgs.openssl
          pkgs.stdenv.cc.cc.lib
        ]
      }" "$out/bin/nim"
      # Same treatment for the fork-built nimpretty: `dontPatchELF` is on for
      # Linux, so nothing else will give it a RUNPATH, and it links the same
      # compiler modules `nim` does.
      patchelf --set-rpath "${
        pkgs.lib.makeLibraryPath [
          pkgs.zstd
          pkgs.pcre
          pkgs.openssl
          pkgs.stdenv.cc.cc.lib
        ]
      }" "$out/bin/nimpretty"
    ''}
    ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      # Darwin: the Mach-O equivalent — add each dependency's store lib dir as an
      # LC_RPATH entry so any @rpath-relative dylib references resolve. (Bare
      # `dlopen("libpcre")` calls also consult these rpaths on macOS.) Use
      # `getLib` for the same output selection as the Linux makeLibraryPath above,
      # so we point at each package's `lib` output rather than its default one.
      for libdir in ${
        pkgs.lib.concatMapStringsSep " " (p: "${pkgs.lib.getLib p}/lib") [
          pkgs.zstd
          pkgs.pcre
          pkgs.openssl
        ]
      }; do
        install_name_tool -add_rpath "$libdir" "$out/bin/nim" || true
      done
    ''}
    # Prune dev-only dangling symlinks from the vendored dist/ trees.
    find "$out" -xtype l -delete 2>/dev/null || true
    "$out/bin/nim" --version
    runHook postInstall
  '';

  meta = {
    description = "metacraft-labs/nim fork (Nim 2.3.1 devel) — reprobuild toolchain";
    # Linux + Darwin: the build is portable (koch-boot-free), and the ELF-only
    # RUNPATH fixup in installPhase is guarded to Linux with a Mach-O rpath
    # equivalent on Darwin. Not BSD (untested), so this is narrower than
    # `platforms.unix`.
    platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
  };
}
