import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
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
    nixPackage "nixpkgs#cargo", executablePath = "bin/cargo",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
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
    # `rust-1.92.0-<triple>/` dir; the realize loop then auto-detects
    # the rust-installer layout (via the `rust-installer-version` +
    # `components` sentinel files) and replays the upstream merge so
    # `cargo.exe` lands at `<prefix>/bin/cargo.exe` and libstd at
    # `<prefix>/lib/rustlib/<triple>/lib/`. See
    # ``mergeRustInstallerComponents`` in
    # ``repro_tool_profiles.nim`` for the merge implementation.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo.exe",
      packageId = "rust@1.92.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:rust@1.92.0:sha256:7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702"
    # Linux x86_64: same rust standalone-distribution tarball as the
    # Windows entry — different triple. The rust-installer auto-merge
    # in the realize loop flattens cargo / rustc / rust-std into a
    # single prefix so cargo lands at `<prefix>/bin/cargo`.
    tarball url = "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-unknown-linux-gnu.tar.xz",
      sha256 = "d2ccef59dd9f7439f2c694948069f789a044dc1addcc0803613232af8f88ee0c",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/cargo",
      packageId = "rust@1.92.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust@1.92.0:linux:sha256:d2ccef59dd9f7439f2c694948069f789a044dc1addcc0803613232af8f88ee0c"

  executable cargo:
    cli:
      # MR16: cargo + rustc emit one Make-format ``.d`` depfile per
      # crate under ``target/<profile>/deps/<crate>-<hash>.d`` (the
      # hash depends on compiler-input content so the recipe cannot
      # enumerate them at DSL-eval time). Each subcmd below declares
      # both the debug and release deps dirs as glob patterns; the
      # engine's evidence collector expands each glob at action-end
      # and parses every matching ``.d`` as a recognized make-depfile
      # report. Only the profile dir cargo actually wrote to has
      # files; the other glob legitimately expands to zero matches.
      #
      # This replaces the previous ``dependencyPolicy declaredOnly``
      # opt-out (which bypassed dependency evidence entirely) with
      # first-class evidence collection driven by cargo's own ``.d``
      # outputs. The recognized-format gathering kind does NOT wrap
      # subprocesses with the IAT-patching fs-snoop shim, so the
      # rustc-on-Windows monitor-shim crash class that motivated the
      # original ``declaredOnly`` opt-out is still avoided.

      subcmd "build":
        dependencyPolicy makeDepfile,
          depfiles = ["target/debug/deps/*.d", "target/release/deps/*.d"]
        boolFlag locked is bool, alias = "--locked"
        boolFlag release is bool, alias = "--release"
        flag manifestPath is string,
          alias = "--manifest-path",
          role = input
        flag targetDir is string,
          alias = "--target-dir"

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
        dependencyPolicy makeDepfile,
          depfiles = ["target/debug/deps/*.d", "target/release/deps/*.d"]
        boolFlag locked is bool, alias = "--locked"
        boolFlag release is bool, alias = "--release"
        boolFlag noRun is bool, alias = "--no-run"
        flag manifestPath is string,
          alias = "--manifest-path",
          role = input
        flag targetDir is string,
          alias = "--target-dir"
        flag testBinaryPath is string,
          alias = "--test",
          role = output
        outputs testBinary is CargoTestBinary, testBinaryPath

# ---------------------------------------------------------------------------
# Manual wrapper on the `CargoTestBinary` typed output — emits one
# execute edge per call. Recipes typically call `.run()` once per
# individual rust test discovered by enumerating the binary's
# `--list --format=terse` output at recipe-evaluation time (or once with
# `filter = ""` to run the whole binary as a single edge during the
# initial migration).
# ---------------------------------------------------------------------------

proc run*(self: CargoTestBinary; filter = "";
         actionId = ""; deps: openArray[string] = [];
         after: openArray[BuildActionDef] = [];
         extraEnv: openArray[(string, string)] = []): BuildActionDef
    {.discardable.} =
  ## Schedules one cargo-test execute edge for this binary. When
  ## `filter` is non-empty, the binary is invoked with
  ## `--exact <filter>` (libtest's per-test selection). When empty,
  ## the binary runs every test it contains in one process — the
  ## "whole binary as one edge" fallback used before per-test
  ## enumeration is wired.
  ##
  ## The handle's `path` is recorded as a typed input so the engine
  ## action-cache keys on the binary's content; a rebuild of the
  ## binary correctly invalidates every per-test execute edge that
  ## reads it.
  ##
  ## ``extraEnv`` (MR10): per-edge env-var injection threaded onto the
  ## spawned test process. Useful for tests whose runtime needs
  ## additional env vars (e.g. cairo-corelib's ``CAIRO_CORELIB_DIR``)
  ## without resorting to a shell-wrapper indirection.
  var cliArgs: seq[PublicCliArg] = @[]
  cliArgs.add(inputArg("binary", self.path))
  if filter.len > 0:
    cliArgs.add(cliArg("filter", filter))
  let call = publicCliCall("cargo",
    "cargo-test-binary", "run",
    "cargo.test_binary.run", cliArgs)
  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)
  # MR16: the test-binary execute edge reuses the build-time ``.d``
  # files left behind in ``target/<profile>/deps/`` by the
  # ``cargo.test --no-run`` build that produced this binary. The
  # binary's true source-input set lives in that depfile (cargo's
  # rustc invocation wrote one ``.d`` per crate the binary links),
  # so keying the execute edge on it correctly invalidates the run
  # whenever a source file the binary depends on changed since the
  # last successful execution. We declare both the debug and release
  # globs for the same reason the build subcmd does: at most one
  # profile dir exists per workspace, the other glob legitimately
  # expands to zero matches.
  result = recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    dependencyPolicy = makeDepfilePolicy(depfiles = [
      "target/debug/deps/*.d", "target/release/deps/*.d"]),
    extraEnv = extraEnv)

# M65 cakBuiltin catalog -- consumed on Windows and non-Nix Linux.
# Same per-channel Rust toolchain archive as `rustc.nim` and
# `rustfmt.nim` / `clippy.nim`; bin_relpath points at the `cargo/`
# subdirectory inside the extracted archive.

let cargoCatalog* = @[
  VersionedProvisioning(
    version: "1.92.0",
    archive_format: afTarXz,
    install_method: imExtract,
    bin_relpath: @["cargo\\bin\\cargo.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-pc-windows-msvc.tar.xz",
        sha256: "7e536d87bb539cdf94a969ecb491e1340f2641a11cf57d6169892f395d68c702",
        sha512: "",
        extract_path: "rust-1.92.0-x86_64-pc-windows-msvc"),
      PlatformBinary(cpu: pcX86_64, os: poLinux,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-unknown-linux-gnu.tar.xz",
        sha256: "d2ccef59dd9f7439f2c694948069f789a044dc1addcc0803613232af8f88ee0c",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.92.0-x86_64-unknown-linux-gnu",
        bin_relpath_override: @["cargo/bin/cargo"]),
      PlatformBinary(cpu: pcX86_64, os: poMacos,
        url: "https://static.rust-lang.org/dist/rust-1.92.0-x86_64-apple-darwin.tar.xz",
        sha256: "ef71fcdcd50efd3301144e701faf15124113a1b2efe9a111175d7d1e4f2d31d2",
        sha512: "",
        sha1: "",
        extract_path: "rust-1.92.0-x86_64-apple-darwin",
        bin_relpath_override: @["cargo/bin/cargo"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string](),
    # See ``rustc.nim`` for the rationale: merge ``rust-std-<triple>``
    # into the rustc sysroot so any rustc.exe invoked from this prefix
    # (e.g. via the cargo-prefix bin dir hit by PATH on
    # this realized closure) can find libstd. The action is a no-op
    # when the source does not exist, so we can list all three
    # platform triples; only the matching one fires on each host.
    pre_install_actions: @[
      PreInstallAction(kind: piaMoveItem,
        source: "$dir/rust-std-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/lib",
        target: "$dir/rustc/lib/rustlib/x86_64-pc-windows-msvc/lib",
        recurse: false, literal: ""),
      PreInstallAction(kind: piaMoveItem,
        source: "$dir/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib",
        target: "$dir/rustc/lib/rustlib/x86_64-unknown-linux-gnu/lib",
        recurse: false, literal: ""),
      PreInstallAction(kind: piaMoveItem,
        source: "$dir/rust-std-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/lib",
        target: "$dir/rustc/lib/rustlib/x86_64-apple-darwin/lib",
        recurse: false, literal: "")
    ])
]
