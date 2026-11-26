## The rustc wrapper's record mode, its pure parts: how recorded paths are
## written against logical roots and expanded again, which placeholder files
## a rustc command line names, which sentinel directives the build-script
## stub prints, and how the stub finds its package in `cargo metadata`.
##
## The record run itself (real cargo, the real wrapper and stub) is the
## integration case `tests/integration/t_rqe_cg5_record_mode_compiles_nothing`.
## No mocks: these are functions of strings and JSON.

import std/[json, os, strutils, unittest]
import repro_cargo_edge/record_mode

proc testRoots(): seq[RecordRoot] =
  parseRecordRoots("project=/w/app\ntarget=/w/app/scratch/t\n" &
    "store=/nix/store/\n")

suite "recorded paths are written against logical roots":

  test "the longest root wins, and the rest of the path is kept":
    let roots = testRoots()
    check logicalize(roots, "/w/app/scratch/t/debug/deps/liba.rlib") ==
      "${target}/debug/deps/liba.rlib"
    check logicalize(roots, "/w/app/src/lib.rs") == "${project}/src/lib.rs"
    check logicalize(roots, "/w/app") == "${project}"
    check logicalize(roots, "/nix/store/abc-rustc/bin/rustc") ==
      "${store}/abc-rustc/bin/rustc"

  test "a root inside an argument or a path list is found":
    let roots = testRoots()
    check logicalize(roots, "a=/w/app/scratch/t/x.rlib") == "a=${target}/x.rlib"
    check logicalize(roots, "dependency=/w/app/scratch/t/debug/deps") ==
      "dependency=${target}/debug/deps"
    check logicalize(roots, "/nix/store/a/bin:/usr/bin:/w/app/bin") ==
      "${store}/a/bin:/usr/bin:${project}/bin"

  test "a root matches only as a whole path":
    let roots = testRoots()
    check logicalize(roots, "/w/appx/src") == "/w/appx/src"
    check logicalize(roots, "/x/w/app/src") == "/x/w/app/src"
    check logicalize(roots, "/w/app.old") == "/w/app.old"

  test "a literal dollar is escaped and everything expands back":
    let roots = testRoots()
    for text in ["$HOME/x", "${project}", "a$$b", "/w/app/$x",
                 "--cfg=feature=\"a\"", "/nix/store/q:/w/app/scratch/t/z"]:
      let recorded = logicalize(roots, text)
      check expandRecorded(roots, recorded) == text
    check logicalize(roots, "$HOME") == "$$HOME"

  test "an expansion with an unknown root or a lone dollar is refused":
    let roots = testRoots()
    expect RecordModeError: discard expandRecorded(roots, "${nowhere}/x")
    expect RecordModeError: discard expandRecorded(roots, "a$b")
    expect RecordModeError: discard expandRecorded(roots, "${project")

  test "a malformed root is refused, not dropped":
    expect RecordModeError: discard parseRecordRoots("project")
    expect RecordModeError: discard parseRecordRoots("pro ject=/w")
    expect RecordModeError: discard parseRecordRoots("project=relative/dir")
    check parseRecordRoots("").len == 0

suite "a compile unit's placeholders are the files rustc would write":

  test "a pipelined library writes its rlib, rmeta and dep-info":
    let outputs = unitOutputsOf(["--crate-name", "liba", "--edition=2021",
      "liba/src/lib.rs", "--error-format=json", "--crate-type", "lib",
      "--emit=dep-info,metadata,link", "-C", "extra-filename=-0123abcd",
      "--out-dir", "/t/debug/deps"])
    check outputs.files == @["/t/debug/deps/liba-0123abcd.d",
      "/t/debug/deps/libliba-0123abcd.rmeta",
      "/t/debug/deps/libliba-0123abcd.rlib"]
    check outputs.executable == ""
    check not outputs.buildScript

  test "a binary writes its executable; on Windows with .exe":
    let unix = unitOutputsOf(["--crate-name", "app", "--crate-type", "bin",
      "--emit=dep-info,link", "-Cextra-filename=-ff", "--out-dir", "/t/d"])
    check unix.executable == "/t/d/app-ff"
    check unix.files == @["/t/d/app-ff.d", "/t/d/app-ff"]
    let windows = unitOutputsOf(["--crate-name", "app", "--crate-type",
      "bin", "--target", "x86_64-pc-windows-msvc", "--out-dir=/t/d"])
    check windows.executable == "/t/d/app.exe"

  test "a proc-macro, a cdylib and a staticlib are named per target":
    check unitOutputsOf(["--crate-name", "pm", "--crate-type", "proc-macro",
      "--target", "x86_64-unknown-linux-gnu", "--out-dir", "/d"]).files ==
      @["/d/libpm.so"]
    check unitOutputsOf(["--crate-name", "pm", "--crate-type", "proc-macro",
      "--target", "aarch64-apple-darwin", "--out-dir", "/d"]).files ==
      @["/d/libpm.dylib"]
    check unitOutputsOf(["--crate-name", "c", "--crate-type",
      "cdylib,staticlib", "--target", "x86_64-pc-windows-msvc",
      "--out-dir", "/d"]).files == @["/d/c.dll", "/d/c.lib"]

  test "an explicit emit path or -o names its own file":
    let outputs = unitOutputsOf(["--crate-name", "a", "--crate-type", "bin",
      "--emit=dep-info=/x/a.d,link", "-o", "/x/a.out"])
    check outputs.files == @["/x/a.d", "/x/a.out"]
    check outputs.executable == "/x/a.out"

  test "a test harness is a binary whatever its crate types":
    let outputs = unitOutputsOf(["--crate-name", "a", "--test",
      "--crate-type", "lib", "--out-dir", "/d"])
    check outputs.executable == "/d/a"

  test "a build script's compile is told from a binary of the same name":
    let script = unitOutputsOf(["--crate-name", "build_script_build",
      "--crate-type", "bin", "--emit=dep-info,link",
      "-C", "extra-filename=-77", "--out-dir", "/t/debug/build/foo-77"])
    check script.buildScript
    check script.executable == "/t/debug/build/foo-77/build_script_build-77"
    # The same crate name compiled into `deps/` is an ordinary binary.
    check not unitOutputsOf(["--crate-name", "build_script_build",
      "--crate-type", "bin", "--out-dir", "/t/debug/deps"]).buildScript
    # A library is never a build script.
    check not unitOutputsOf(["--crate-name", "build_script_x",
      "--crate-type", "lib", "--out-dir", "/t/debug/build/x-1"]).buildScript

  test "a line that names no crate is refused":
    expect RecordModeError: discard unitOutputsOf(["-vV"])

suite "the build-script stub's sentinels":

  test "one directive of each kind, each naming the kind and the run":
    let lines = sentinelLines(PackageTargets(name: "sysdep",
      version: "0.1.0", isPathPackage: true), "/t/debug/build/sysdep-9f/out")
    check lines == @[
      "cargo:rustc-cfg=__repro_slot=\"__repro_slot.rustc-cfg.sysdep-9f\"",
      "cargo:rustc-check-cfg=cfg(__repro_slot, values(" &
        "\"__repro_slot.rustc-check-cfg.sysdep-9f\"))",
      "cargo:rustc-env=__REPRO_SLOT_RUSTC_ENV=" &
        "__repro_slot.rustc-env.sysdep-9f",
      "cargo:rustc-link-lib=__repro_slot.rustc-link-lib.sysdep-9f",
      "cargo:rustc-link-search=/t/debug/build/sysdep-9f/out/" &
        "__repro_slot.rustc-link-search-in-out-dir.sysdep-9f",
      "cargo:rustc-link-search=/t/debug/build/sysdep-9f/" &
        "__repro_slot.rustc-link-search-outside-out-dir.sysdep-9f",
      "cargo:rustc-link-arg=__repro_slot.rustc-link-arg.sysdep-9f"]

  test "link-arg variants only for targets the package has, and the provider":
    let lines = sentinelLines(PackageTargets(name: "app", version: "1.0.0",
      bins: @["app", "app-tool"], hasTests: true, hasCdylib: true),
      "/t/debug/build/app-01/out", provider = "${project}/app")
    check "cargo:rustc-link-arg-bins=__repro_slot.rustc-link-arg-bins.app-01" in
      lines
    check "cargo:rustc-link-arg-bin=app-tool=" &
      "__repro_slot.rustc-link-arg-bin.app-01.app-tool" in lines
    check "cargo:rustc-link-arg-tests=__repro_slot.rustc-link-arg-tests.app-01" in
      lines
    check "cargo:rustc-link-arg-cdylib=" &
      "__repro_slot.rustc-link-arg-cdylib.app-01" in lines
    check lines[^1] == "cargo:__repro_provider=${project}/app"
    for line in lines:
      check "rustc-link-arg-examples" notin line
      check "rustc-link-arg-benches" notin line

  test "the stub finds its package in cargo metadata by manifest path":
    let metadata = parseJson("""{"packages": [
      {"name": "other", "version": "0.1.0", "source": null,
       "manifest_path": "/w/other/Cargo.toml", "targets": []},
      {"name": "serde", "version": "1.0.200",
       "source": "registry+https://github.com/rust-lang/crates.io-index",
       "manifest_path": "/r/serde-1.0.200/Cargo.toml",
       "targets": [{"name": "serde", "kind": ["lib"]},
                   {"name": "build-script-build", "kind": ["custom-build"]}]},
      {"name": "app", "version": "0.2.0", "source": null,
       "manifest_path": "/w/app/Cargo.toml",
       "targets": [{"name": "app", "kind": ["bin"]},
                   {"name": "smoke", "kind": ["test"]},
                   {"name": "demo", "kind": ["example"]},
                   {"name": "plug", "kind": ["cdylib", "rlib"]}]}]}""")
    let serde = packageTargetsOf(metadata, "/r/serde-1.0.200/Cargo.toml")
    check serde.name == "serde" and serde.version == "1.0.200"
    check not serde.isPathPackage
    check serde.bins.len == 0
    let app = packageTargetsOf(metadata, "/w/app/Cargo.toml")
    check app.isPathPackage
    check app.bins == @["app"]
    check app.hasTests and app.hasExamples and app.hasCdylib
    check not app.hasBenches
    expect RecordModeError:
      discard packageTargetsOf(metadata, "/w/missing/Cargo.toml")

  test "a stub is recognised by a build script's name":
    check isStubImage(["/t/debug/build/a-1/build-script-build"])
    check isStubImage(["/t/debug/build/a-1/build_script_build-1"])
    check not isStubImage(["/b/repro-rustc-wrapper", "repro-rustc-wrapper"])
