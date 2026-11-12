## The generated half of the `cargo` package: the `package cargo:` block, whose
## `cli:` spec declares cargo's subcommands and flags, and the typed output
## `cargo.test` returns.
##
## Nothing imports this module directly. `cargo.nim` wraps `build`, `install`
## and `test` -- each must name cargo's target directory and the depfile globs
## under it per call, which a `cli:` declaration (one literal policy per
## subcommand) cannot express -- and re-exports everything else. See there.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/rust_toolchain_pins
export packages_schema

# ---------------------------------------------------------------------------
# Typed output: a cargo test binary that speaks the rust libtest CLI.
#
# `cargo test --no-run --message-format=json-render-diagnostics` builds the
# integration-test + lib-test binaries under
# `target/<profile>/deps/<crate>-<hash>` (a hashed filename libtest picks)
# and emits one JSON line per produced binary so the recipe can wire the
# resulting paths through the engine. The recipe surfaces each produced
# binary as a `CargoTestBinary` and then calls `.run(filter = ...)` to
# schedule a per-test execute edge.
#
# Mirrors the `NimUnittestBinary` shape documented in
# Test-Edges-And-Parallel-Runner.milestones.org §M0/M1 — same `.run()`
# convention, same `TestBinary`-style interface so a future
# `ct-test-runner` adapter can drive cargo test binaries through the
# same parallel scheduler that handles Nim ones today.
# ---------------------------------------------------------------------------

type CargoTestBinary* = object
  ## Typed handle returned by `cargo.test.build(...)`. Carries the
  ## on-disk path of one cargo-test binary so `.run()` / `.runTest()`
  ## can wire it into the input set of an execute edge and the engine
  ## action-cache keys on the binary content.
  path*: string

package cargo:
  provisioning:
    # The Nix channel realizes rust-lang's own releases, the same
    # archives as the ``tarball`` arms below, with their ELF loader and
    # RUNPATH pointed into the pinned nixpkgs' glibc. The pinned nixpkgs'
    # own cargo is 1.91, outside the range the ``tarball`` arms pin, and a
    # nixpkgs-built rustc cannot load rust-lang's prebuilt ``rust-std`` for
    # a cross target. See ``nix/rust-1.94.0/default.nix``. ``rustc`` and
    # ``cargo`` name the same expression per release, so they realize one
    # prefix.
    #
    # One arm per release, each declaring its ``version`` so a ``uses:``
    # range selects among them; the default release is first, so an
    # unranged or wide ``uses:`` takes it, as with the ``tarball`` arms.
    nixPackage "reprobuild-stdlib-rust-1.94.0",
      executablePath = "bin/cargo",
      expressionFile = "nix/rust-1.94.0/default.nix",
      version = RustRelease1940.version,
      # The archive of THIS platform (decision 35(a)): see
      # ``rust_toolchain_pins``.
      lockIdentity = rustNixLockIdentity(RustRelease1940)
    nixPackage "reprobuild-stdlib-rust-1.97.1",
      executablePath = "bin/cargo",
      expressionFile = "nix/rust-1.97.1/default.nix",
      version = RustRelease1971.version,
      lockIdentity = rustNixLockIdentity(RustRelease1971)
    # Windows / non-Nix Linux: cargo ships as part of the Rust toolchain
    # that Scoop's ``rustup-msvc`` installs via ``rustup-init.exe``.
    # The bytes live at ``<scoop-persist>/rustup-msvc/.cargo/bin/cargo.exe``;
    # scoop's persist mechanism junctions ``.cargo`` into the app dir
    # (``<scoop-app>/<ver>/.cargo`` -> ``<scoop-persist>/.cargo``), and the
    # reprobuild scoop adapter junctions ``<prefix>/bin`` ->
    # ``<scoop-app>/<ver>``, so the binary is reachable at
    # ``<prefix>/bin/.cargo/bin/cargo.exe``. Operators who haven't yet
    # had rustup bootstrap a default toolchain should run
    # ``rustup default stable-msvc`` once after the scoop install so
    # the persist tree actually contains ``cargo.exe``.
    scoopApp(bucket = "main", app = "rustup-msvc",
      preferredVersion = ">=1.20",
      executablePath = ".cargo/bin/cargo.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: the upstream Rust standalone-distribution tarball
    # ships cargo / rustc / rustfmt / rust-std under a single
    # `rust-X.Y.Z-x86_64-pc-windows-msvc/` top-level dir, with each
    # component nested under its own subdir (`cargo/`, `rustc/`,
    # `rust-std-<triple>/`, `rustfmt-preview/`, ...) — the official
    # `install.sh` MERGES these components into one flat prefix at
    # install time, which is the only layout where rustc can find
    # libstd at `<bin>/../lib/rustlib/<triple>/lib/`. With
    # `stripComponents=1` we strip the outer
    # `rust-1.94.0-<triple>/` dir; the realize loop then auto-detects
    # the rust-installer layout (via the `rust-installer-version` +
    # `components` sentinel files) and replays the upstream merge so
    # `cargo.exe` lands at `<prefix>/bin/cargo.exe` and libstd at
    # `<prefix>/lib/rustlib/<triple>/lib/`. See
    # ``mergeRustInstallerComponents`` in
    # ``repro_tool_profiles.nim`` for the merge implementation.
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "2e65904a4340df11a1ed8a86a7cc5c08e09f65453ce822ef36159c605a97f6a5",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo.exe",
      packageId = "rust@1.94.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.94.0:sha256:2e65904a4340df11a1ed8a86a7cc5c08e09f65453ce822ef36159c605a97f6a5",
      version = "1.94.0"
    # Linux x86_64: same rust standalone-distribution tarball as the
    # Windows entry — different triple. The rust-installer auto-merge
    # in the realize loop flattens cargo / rustc / rust-std into a
    # single prefix so cargo lands at `<prefix>/bin/cargo`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo",
      packageId = "rust@1.94.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.94.0:linux:sha256:e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a",
      version = "1.94.0"
    # macOS aarch64: same rust standalone-distribution tarball — different
    # triple (Apple Silicon). All current GitHub-hosted macOS runners are
    # M1/M2/M3, so aarch64 is the only macOS entry we ship. The realize
    # loop's rust-installer auto-merge applies the same way as on Linux
    # and Windows so `cargo` lands at `<prefix>/bin/cargo`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-aarch64-apple-darwin.tar.xz",
      sha256 = "9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo",
      packageId = "rust@1.94.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:rust@1.94.0:macos-aarch64:sha256:9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c",
      version = "1.94.0"
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://static.rust-lang.org/dist/rust-1.94.0-x86_64-apple-darwin.tar.xz",
      sha256 = "63fe27931d4b8da0b0069f13d4d2c04792203a5cabb4df17ff15495aaaab0ef7",
      archiveType = "tar.xz",
      executablePath = "cargo/bin/cargo",
      version = "1.94.0",
      packageId = "cargo@1.94.0",
      extractPath = "rust-1.94.0-x86_64-apple-darwin",
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/lib", "$dir/rustc/lib/rustlib/x86_64-pc-windows-msvc/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib", "$dir/rustc/lib/rustlib/x86_64-unknown-linux-gnu/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/lib", "$dir/rustc/lib/rustlib/x86_64-apple-darwin/lib", false, ""),
      cpu = "x86_64",
      os = "macos"
    # Rust 1.97.1: the same four archives of a newer release, for a recipe
    # whose ``uses:`` range excludes 1.94 (a crate that needs a newer stable
    # compiler). Declared after the 1.94.0 arms, so an unranged or wide
    # ``uses:`` keeps taking 1.94.0 (selection takes the first eligible arm
    # in declaration order). Digests: upstream's ``<archive>.sha256``, read
    # 2026-11-11, equal to channel-rust-1.97.toml's ``xz_hash`` rows.
    tarball url = "https://static.rust-lang.org/dist/rust-1.97.1-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "a1cdfcfd1e351ba21823d6bd454a297fa95190abca2f432a372e3c47bef8b863",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo.exe",
      packageId = "rust@1.97.1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.97.1:sha256:a1cdfcfd1e351ba21823d6bd454a297fa95190abca2f432a372e3c47bef8b863",
      version = "1.97.1"
    tarball url = "https://static.rust-lang.org/dist/rust-1.97.1-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "88f28fa9af20594179f85d6df67078dfd6fa93e2f6da5e1e9b0ac4997988ca4f",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo",
      packageId = "rust@1.97.1",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.97.1:linux:sha256:88f28fa9af20594179f85d6df67078dfd6fa93e2f6da5e1e9b0ac4997988ca4f",
      version = "1.97.1"
    tarball url = "https://static.rust-lang.org/dist/rust-1.97.1-aarch64-apple-darwin.tar.xz",
      sha256 = "c9748cc86107734a2a024069908a895de7caa2d37062fb641eef9f756938ace2",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo",
      packageId = "rust@1.97.1",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:rust@1.97.1:macos-aarch64:sha256:c9748cc86107734a2a024069908a895de7caa2d37062fb641eef9f756938ace2",
      version = "1.97.1"
    tarball url = "https://static.rust-lang.org/dist/rust-1.97.1-x86_64-apple-darwin.tar.xz",
      sha256 = "891c32ea77b750dccc7fb0ea98e3feb9db3d29fe0cfea5907d002f270c59cf58",
      archiveType = "tar.xz",
      executablePath = "cargo/bin/cargo",
      version = "1.97.1",
      packageId = "cargo@1.97.1",
      extractPath = "rust-1.97.1-x86_64-apple-darwin",
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/lib", "$dir/rustc/lib/rustlib/x86_64-pc-windows-msvc/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib", "$dir/rustc/lib/rustlib/x86_64-unknown-linux-gnu/lib", false, ""),
      preInstall = preInstallAction("move-item", "$dir/rust-std-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/lib", "$dir/rustc/lib/rustlib/x86_64-apple-darwin/lib", false, ""),
      cpu = "x86_64",
      os = "macos"

  executable cargo:
    cli:
      # cargo does not compile or link Rust itself. It runs ``rustc``, and
      # ``rustc`` runs a C compiler driver (``cc``) as its linker. Both are
      # found by BARE NAME on the edge's PATH, so they are this tool's
      # sub-tools: a recipe that declares ``"rustc"`` and its C compiler
      # (``"gcc"`` on Linux, ``"clang"`` on macOS) in ``uses:`` gets their
      # resolved directories on every cargo edge's PATH, and their profiles'
      # include and library directories on its ``CPATH`` and
      # ``LIBRARY_PATH``. The library directories are what let rustc link
      # through a Nix clang on macOS: Rust's standard library links
      # ``-liconv``, which the Nix Apple SDK splits out into a package of
      # its own that only the clang profile's library path names. A name
      # the recipe does not declare is inert. Tools a crate's build script
      # runs are the recipe's to declare at the call site; they are not
      # cargo's.
      # ``zig`` is the cross C toolchain of a ``--target`` build
      # (``adapters/cross_zig``); ``cmake``, ``perl`` and ``make`` are what
      # the build scripts of the common ``*-sys`` crates run (``aws-lc-sys``
      # configures with cmake, ``openssl-src`` with perl + make).
      subTools "rustc", "gcc", "clang", "zig", "cmake", "perl", "make"

      # MR16: cargo + rustc emit one Make-format ``.d`` depfile per
      # crate under ``<target-dir>/<profile>/deps/<crate>-<hash>.d`` (the
      # hash depends on compiler-input content so the recipe cannot
      # enumerate them at DSL-eval time). The engine's evidence collector
      # expands a glob per profile at action-end and parses every matching
      # ``.d`` as a recognized make-depfile report; only the profile dir
      # cargo actually wrote to has files, so the other glob legitimately
      # expands to zero matches.
      #
      # This replaces the previous ``dependencyPolicy declaredOnly``
      # opt-out (which bypassed dependency evidence entirely) with
      # first-class evidence collection driven by cargo's own ``.d``
      # outputs. The recognized-format gathering kind does NOT wrap
      # subprocesses with the IAT-patching io-monitor shim, so the
      # rustc-on-Windows monitor-shim crash class that motivated the
      # original ``declaredOnly`` opt-out is still avoided.
      #
      # The globs are NOT declared here. ``<target-dir>`` is a per-call
      # value, and a literal ``target/...`` in this spec was wrong whenever
      # the crate sat below the working directory or the host moved cargo's
      # output (``CARGO_TARGET_DIR``). ``cargo.nim`` passes them per call;
      # the bare ``makeDepfile`` below only selects the policy kind.

      subcmd "build":
        # The vendored-sources configuration, by path: cargo reads
        # `.cargo/config.toml` from its WORKING directory upward, not from
        # the `--manifest-path` directory
        # (https://doc.rust-lang.org/cargo/reference/config.html#hierarchical-structure).
        flag config is string, alias = "--config"
        dependencyPolicy makeDepfile
        boolFlag locked is bool, alias = "--locked"
        boolFlag release is bool, alias = "--release"
        # ``--offline`` is what a from-source recipe's build is FOR: the
        # dependency closure has already been vendored and the build must
        # not reach the network, so a crate the vendor step missed has to
        # fail here rather than be silently downloaded. Without the flag on
        # this surface a recipe would be spelling it through a verbatim
        # ``shell()``, which is exactly the hand-written acquisition the
        # from-source tier exists to remove.
        boolFlag offline is bool, alias = "--offline"
        boolFlag noDefaultFeatures is bool, alias = "--no-default-features"
        flag features is string, alias = "--features"
        flag manifestPath is string,
          alias = "--manifest-path",
          role = input
        flag targetDir is string,
          alias = "--target-dir"
        # Package / binary selectors: let a recipe restrict a virtual
        # workspace build to one member crate + binary (a granular
        # per-artifact edge) instead of building every member.
        flag package is string, alias = "--package"
        flag bin is string, alias = "--bin"
        # ``--target <triple>``: build for another target. The compiled
        # artefacts land under ``<target-dir>/<triple>/<profile>/``; cargo
        # finds the target's standard library under rustc's sysroot
        # (``lib/rustlib/<triple>/``) and the target's C toolchain through
        # the ``CC_<triple>`` / ``CARGO_TARGET_<TRIPLE>_LINKER`` environment
        # (``adapters/cross_zig`` renders both for a zig-driven cross build).
        flag target is string, alias = "--target"

      subcmd "install":
        # The vendored-sources configuration, by path: cargo reads
        # `.cargo/config.toml` from its WORKING directory upward, not from
        # the `--manifest-path` directory
        # (https://doc.rust-lang.org/cargo/reference/config.html#hierarchical-structure).
        flag config is string, alias = "--config"
        ## The canonical way to land a built binary in an FHS-shaped tree:
        ## ``cargo install --root <dir>`` writes ``<dir>/bin/<binary>``,
        ## which is what the standard component layout already expects.
        ## Hand-copying out of ``target/<profile>/`` would have to guess
        ## which of the profile directory's many files are the package's
        ## binaries — cargo knows, from the manifest.
        ##
        ## Sharing ``--target-dir`` with the build subcommand above is what
        ## keeps this from being a second full compile: cargo reuses the
        ## artefacts it already produced.
        dependencyPolicy makeDepfile
        boolFlag locked is bool, alias = "--locked"
        boolFlag offline is bool, alias = "--offline"
        boolFlag noTrack is bool, alias = "--no-track"
        # Without ``--force`` cargo refuses a root that already holds the
        # binary (``binary … already exists in destination``), so an edge
        # re-run after an input changed would fail on its own previous
        # output.
        boolFlag force is bool, alias = "--force"
        boolFlag noDefaultFeatures is bool, alias = "--no-default-features"
        flag features is string, alias = "--features"
        flag path is string, alias = "--path", role = input
        flag root is string, alias = "--root"
        flag targetDir is string,
          alias = "--target-dir"
        # The same ``--target`` as ``build``, so the install reuses the
        # cross artefacts the build produced instead of compiling the host
        # variant a second time.
        flag target is string, alias = "--target"

      subcmd "test":
        ## `cargo test` orchestrates build + run in one verb. The
        ## reprobuild-native shape ALWAYS passes `--no-run` from this
        ## subcommand so the action emits the test binaries as outputs;
        ## individual tests are then driven via the typed handle's
        ## `.run()` method below. Direct `cargo test` invocations that
        ## run inside this subcommand without `--no-run` are still
        ## supported (the legacy `just test` carries them) but they do
        ## not produce reusable typed outputs.
        ##
        ## MR16: ``cargo test --no-run`` writes the same
        ## ``target/<profile>/deps/<crate>-<hash>.d`` files for the
        ## test crates as ``cargo build`` does for normal crates, so
        ## the same multi-glob spec applies.
        dependencyPolicy makeDepfile
        boolFlag locked is bool, alias = "--locked"
        boolFlag release is bool, alias = "--release"
        boolFlag noRun is bool, alias = "--no-run"
        # `cargo test` accepts --no-default-features exactly as `cargo build`
        # does, and a crate whose default features are host-specific has to be
        # able to test the same feature set it builds. `build` and `install`
        # above carry the flag; its absence here was the gap.
        boolFlag noDefaultFeatures is bool, alias = "--no-default-features"
        flag manifestPath is string,
          alias = "--manifest-path",
          role = input
        flag targetDir is string,
          alias = "--target-dir"
        # Same selectors as `build`: a test edge has to be able to target
        # the member crate / binary its build edge built.
        flag package is string, alias = "--package"
        flag bin is string, alias = "--bin"
        flag testBinaryPath is string,
          alias = "--test",
          role = output
        outputs testBinary is CargoTestBinary, testBinaryPath
