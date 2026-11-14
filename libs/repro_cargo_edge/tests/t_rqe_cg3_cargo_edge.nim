## The thin cargo edge's library (`repro_cargo_edge`): how a rustc command line
## is read, how the wrapper is installed into a cargo action's environment, and
## product discovery from cargo's JSON, the last against REAL cargo and rustc
## on a small workspace in a temporary directory (`--offline`, no network).
## No mocks: the products asserted are files cargo itself wrote.
##
## The wrapper PROCESS (RunQuota reporting, transparency) is covered by the
## integration cases `t_rqe_cg3_*` in `tests/integration`.

import std/[os, strutils, tempfiles, unittest]
import repro_cargo_edge

suite "a rustc command line names a unit":

  test "a compile is a unit and carries its crate type and opt level":
    let parsed = rustcUnitOf(@["--crate-name", "serde", "--edition=2021",
      "src/lib.rs", "--error-format=json", "--crate-type", "lib", "-C",
      "opt-level=3", "--extern", "x=/t/libx.rlib"])
    check parsed.isUnit
    check parsed.unit.crateName == "serde"
    check parsed.unit.kind == "lib"
    check parsed.unit.optLevel == "3"
    check statsKeyOf(parsed.unit) == "rustc/serde/lib/o3"

  test "the same crate as a test harness or a build script is another unit":
    let harness = rustcUnitOf(@["--crate-name", "app", "--test",
      "--error-format", "json", "-Copt-level=0", "src/main.rs"])
    check harness.unit.kind == "test"
    check statsKeyOf(harness.unit) == "rustc/app/test/o0"
    let script = rustcUnitOf(@["--crate-name=build_script_build",
      "--error-format=json", "--crate-type", "bin", "build.rs"])
    check statsKeyOf(script.unit) == "rustc/build_script_build/bin/o0"

  test "no crate type is a binary, several are joined, -O is opt level 2":
    let json = "--error-format=json"
    check rustcUnitOf(@["--crate-name", "a", json, "-O"]).unit.kind == "bin"
    check rustcUnitOf(@["--crate-name", "a", json, "-O"]).unit.optLevel == "2"
    check rustcUnitOf(@["--crate-name", "a", json, "--crate-type",
      "cdylib,rlib"]).unit.kind == "cdylib+rlib"

  test "a question to rustc is not a unit":
    check not rustcUnitOf(@["-vV"]).isUnit
    check not rustcUnitOf(@["--version"]).isUnit
    # Cargo's target-info probe names a crate and compiles nothing.
    check not rustcUnitOf(@["-", "--crate-name", "___", "--print=file-names",
      "--crate-type", "bin"]).isUnit
    check not rustcUnitOf(@["--crate-name", "a", "--error-format=json",
      "--print", "cfg"]).isUnit
    check not rustcUnitOf(@["src/lib.rs"]).isUnit

  test "a build script's own probe compile is not a unit":
    # The shape proc-macro2's build script gives rustc: the crate's name, a
    # probe cfg, plain diagnostics.
    check not rustcUnitOf(@["--cfg=procmacro2_build_probe", "--edition=2021",
      "--crate-name=proc_macro2", "--crate-type=lib", "--cap-lints=allow",
      "--emit=dep-info,metadata", "--out-dir", "/t/probe",
      "src/probe/proc_macro_span.rs"]).isUnit
    # Source from standard input is a probe too.
    check not rustcUnitOf(@["--crate-name", "a", "--error-format=json",
      "-"]).isUnit

suite "the wrapper is installed into a cargo action":

  test "only cargo itself is the cargo edge":
    check isCargoProgram("cargo")
    check isCargoProgram("/nix/store/x-cargo/bin/cargo")
    check isCargoProgram("C:\\tools\\cargo.exe")
    check not isCargoProgram("cargo-nextest")
    check not isCargoProgram("/usr/bin/make")

  test "a plain environment gets the wrapper and nothing else":
    check rustcWrapperEntries(["PATH=/bin"], "/b/repro-rustc-wrapper") ==
      @["RUSTC_WRAPPER=/b/repro-rustc-wrapper"]

  test "a project's own wrapper keeps running, in front of rustc":
    check rustcWrapperEntries(["RUSTC_WRAPPER=/usr/bin/sccache"],
      "/b/w") == @["RUSTC_WRAPPER=/b/w",
      "REPRO_RUSTC_WRAPPER_INNER=/usr/bin/sccache"]
    check rustcWrapperEntries(["CARGO_BUILD_RUSTC_WRAPPER=/usr/bin/sccache"],
      "/b/w") == @["RUSTC_WRAPPER=/b/w",
      "REPRO_RUSTC_WRAPPER_INNER=/usr/bin/sccache"]

  test "an installed wrapper is not installed twice, none is not installed":
    check rustcWrapperEntries(["RUSTC_WRAPPER=/b/w"], "/b/w").len == 0
    check rustcWrapperEntries(["PATH=/bin"], "").len == 0

  test "the switch":
    check wrapperEnabled("on")
    check wrapperEnabled("1")
    check not wrapperEnabled("off")
    check not wrapperEnabled("0")
    check wrapperEnabled("") == WrapperDefaultOn

  test "the wrapper binary is found beside the engine or by override":
    let dir = createTempDir("rqe_cg3_wrapper_", "")
    defer: removeDir(dir)
    check wrapperBinaryPath(dir, "") == ""
    let name = when defined(windows): WrapperBinaryName & ".exe"
               else: WrapperBinaryName
    writeFile(dir / name, "x")
    check wrapperBinaryPath(dir, "") == dir / name
    check wrapperBinaryPath(dir, dir / "missing").len == 0
    check wrapperBinaryPath("", dir / name) == dir / name

  test "the command the wrapper runs puts the project's wrapper first":
    check realCommand(@["rustc", "-vV"], "") == @["rustc", "-vV"]
    check realCommand(@["rustc", "-vV"], "sccache") ==
      @["sccache", "rustc", "-vV"]

suite "cargo's arguments for the edge":

  test "the JSON format and the width go right after the subcommand":
    check withEdgeArguments(@["cargo", "build", "--release"], 4) ==
      @["cargo", "build", "--message-format=json-render-diagnostics", "-j",
        "4", "--release"]
    check withEdgeArguments(@["cargo", "+nightly", "test", "--",
      "--nocapture"], 0) == @["cargo", "+nightly", "test",
      "--message-format=json-render-diagnostics", "--", "--nocapture"]

  test "an argument the caller gave is left alone":
    check withEdgeArguments(@["cargo", "build", "-j2",
      "--message-format=json"], 8) == @["cargo", "build", "-j2",
      "--message-format=json"]
    check withEdgeArguments(@["cargo", "build", "--jobs=3"], 8) ==
      @["cargo", "build", "--message-format=json-render-diagnostics",
        "--jobs=3"]
    check messageFormatIsJson(@["cargo", "build", "--message-format", "json"])
    check not messageFormatIsJson(@["cargo", "build", "--message-format=short"])

suite "final products come from cargo's JSON":

  proc workspace(root: string) =
    createDir(root / "app" / "src")
    createDir(root / "native" / "src")
    createDir(root / "core" / "src")
    writeFile(root / "Cargo.toml",
      "[workspace]\nmembers = [\"app\", \"native\", \"core\"]\n" &
      "resolver = \"2\"\n")
    writeFile(root / "core" / "Cargo.toml",
      "[package]\nname = \"core_lib\"\nversion = \"0.1.0\"\n" &
      "edition = \"2021\"\n")
    writeFile(root / "core" / "src" / "lib.rs",
      "pub fn n() -> u32 { 7 }\n")
    writeFile(root / "native" / "Cargo.toml",
      "[package]\nname = \"native_lib\"\nversion = \"0.1.0\"\n" &
      "edition = \"2021\"\n[lib]\ncrate-type = [\"cdylib\", \"rlib\"]\n" &
      "[dependencies]\ncore_lib = { path = \"../core\" }\n")
    writeFile(root / "native" / "src" / "lib.rs",
      "pub fn n() -> u32 { core_lib::n() }\n")
    writeFile(root / "app" / "Cargo.toml",
      "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
      "[dependencies]\ncore_lib = { path = \"../core\" }\n")
    writeFile(root / "app" / "src" / "main.rs",
      "fn main() { println!(\"{}\", core_lib::n()); }\n")

  proc edgeOptions(root, target: string): CargoEdgeOptions =
    CargoEdgeOptions(
      cargo: @[findExe("cargo"), "build", "--offline", "--manifest-path",
        root / "Cargo.toml", "--target-dir", target],
      width: 2,
      productsFile: root / "out" / "products.txt",
      fragmentFile: root / "out" / "products.dyndep",
      actionId: "demo.build")

  test "the executable and the cdylib are products, the rlibs are not":
    require findExe("cargo").len > 0 and findExe("rustc").len > 0
    let root = createTempDir("rqe_cg3_products_", "")
    defer: removeDir(root)
    workspace(root)
    let target = root / "target"
    let options = edgeOptions(root, target)
    let outcome = runCargoEdge(options)
    check outcome.exitCode == 0
    check outcome.units >= 3
    var names: seq[string]
    for p in outcome.products: names.add extractFilename(p)
    check "app" in names or "app.exe" in names
    var hasCdylib = false
    for name in names:
      if "native_lib" in name and
          (name.endsWith(".so") or name.endsWith(".dylib") or
           name.endsWith(".dll")):
        hasCdylib = true
    check hasCdylib
    for name in names:
      check not name.endsWith(".rlib")
      check "core_lib" notin name
    # Every product exists; the answer is written and well formed.
    for p in outcome.products: check fileExists(p)
    let listed = readFile(root / "out" / "products.txt").splitLines()
    check listed[0] == "repro-cargo-products-v1"
    let fragment = readFile(root / "out" / "products.dyndep")
    check fragment.startsWith("repro-dynamic-graph-v1\n")
    check fragment.count("output\tdemo.build\t") == outcome.products.len

  test "a rebuild of an unchanged tree reuses every unit and keeps the answer":
    require findExe("cargo").len > 0 and findExe("rustc").len > 0
    let root = createTempDir("rqe_cg3_products_", "")
    defer: removeDir(root)
    workspace(root)
    let options = edgeOptions(root, root / "target")
    let first = runCargoEdge(options)
    check first.exitCode == 0
    check first.freshUnits == 0
    let stamp = getLastModificationTime(root / "out" / "products.dyndep")
    sleep(1100)
    let second = runCargoEdge(options)
    check second.exitCode == 0
    check second.units == first.units
    check second.freshUnits == second.units
    # Same answer, so the file that consumers key on was not touched.
    check getLastModificationTime(root / "out" / "products.dyndep") == stamp

  test "a failed build leaves no answer behind":
    require findExe("cargo").len > 0 and findExe("rustc").len > 0
    let root = createTempDir("rqe_cg3_products_", "")
    defer: removeDir(root)
    workspace(root)
    let options = edgeOptions(root, root / "target")
    check runCargoEdge(options).exitCode == 0
    check fileExists(root / "out" / "products.txt")
    writeFile(root / "core" / "src" / "lib.rs", "pub fn n() -> u32 { \n")
    let failed = runCargoEdge(options)
    check failed.exitCode != 0
    check not fileExists(root / "out" / "products.txt")
    check not fileExists(root / "out" / "products.dyndep")

  test "a message format that is not JSON is refused":
    var options = CargoEdgeOptions(cargo: @["cargo", "build",
      "--message-format=short"])
    expect ValueError:
      discard runCargoEdge(options)
    options.cargo = @[]
    expect ValueError:
      discard runCargoEdge(options)

  test "a fragment needs the action it declares outputs for":
    require findExe("cargo").len > 0 and findExe("rustc").len > 0
    let root = createTempDir("rqe_cg3_products_", "")
    defer: removeDir(root)
    workspace(root)
    var options = edgeOptions(root, root / "target")
    options.actionId = ""
    expect ValueError:
      discard runCargoEdge(options)

  test "paths can be written relative to a directory":
    check "/w/target/debug/app".relativeTo("/w") == "target/debug/app"
    check "/other/app".relativeTo("/w") == "/other/app"
    check "/w/x".relativeTo("/w/") == "x"

suite "the command line of the edge":

  test "usage errors are exit 2 and run nothing":
    check runEdge(@["--bogus"]) == 2
    check runEdge(@[]) == 2
    check runEdge(@["-j", "many", "--", "cargo", "build"]) == 2
    check runEdge(@["--products", "x"]) == 2

  test "the helper command puts the width flag before the separator":
    let argv = edgeCommand("/b/repro-standard-provider", "/p/x.products",
      ["cargo", "build", "--release"])
    check argv == @["/b/repro-standard-provider", EdgeHelperFlag, "-j", "0",
      "--products", "/p/x.products", "--", "cargo", "build", "--release"]
    # The engine finds the width flag before the first `--`; a flag after it
    # would be cargo's, not the edge's.
    check argv.find("-j") < argv.find("--")
    check edgeCommand("h", "p", ["cargo"], relativeTo = "/w")[6 .. 7] ==
      @["--relative-to", "/w"]
