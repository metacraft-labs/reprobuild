## The cargo plan's pure parts, the record run's start-up checks and the
## edge's key: the binary record round-trips and refuses what is not a valid
## plan; the derivation places what cargo wrote, keeps and drops the right
## variables, and refuses what it cannot place; the record run refuses a
## scratch directory that is not empty, cargo arguments it does not model and
## an environment that would make cargo compile for real; two checkouts of a
## workspace give the edge the same key.
##
## The record run itself, through the engine, and the plan against a real
## cargo build are the integration cases
## `tests/integration/t_rqe_cg5_record_run_compiles_nothing`,
## `tests/integration/t_rqe_cg5_plan_completes_to_cargos_argv` and
## `tests/integration/t_rqe_cg5_record_run_refusals`.
##
## No mocks. The recordings below are written by hand in the shape the record
## mode writes them (`RecordedInvocation`), because what is tested is the
## derivation's handling of inputs a real cargo run does not produce on
## demand (a path it cannot place, a run of another package's script). The
## start-up checks run the real `runCargoPlan` in a temporary directory and
## stop before it starts cargo. The key is the real `cargoPlanEdge`'s.

import std/[json, os, strutils, tempfiles, unittest]

import repro_core/codec
import repro_build_engine
import repro_cargo_edge/[cargo_plan, plan_edge, plan_run, record_mode]
import repro_cargo_fetch/[crate_identity, crate_rows]
import repro_local_store/prefix_paths

proc unitRec(extraArgs: seq[string] = @[];
             env: seq[(string, string)] = @[];
             argv1 = ""): RecordedInvocation =
  var argv = @["rustc"]
  if argv1.len > 0: argv.add argv1
  argv.add ["--crate-name", "a", "--crate-type", "lib",
    "--emit=dep-info,metadata,link", "-C", "extra-filename=-0123abcd",
    "--out-dir", "${target}/debug/deps"]
  RecordedInvocation(kind: rkUnit, argv: argv & extraArgs,
    cwd: "${project}",
    env: @[("CARGO_PKG_NAME", "a"), ("CARGO_PKG_VERSION", "1.0.0")] & env,
    placeholders: @["${target}/debug/deps/liba-0123abcd.rlib",
      "${target}/debug/deps/liba-0123abcd.rmeta"])

proc scriptCompileRec(pkg, hash: string): RecordedInvocation =
  RecordedInvocation(kind: rkUnit, buildScriptCompile: true,
    argv: @["rustc", "--crate-name", "build_script_build", "--crate-type",
      "bin", "--emit=dep-info,link", "-C", "extra-filename=-" & hash,
      "--out-dir", "${target}/debug/build/" & pkg & "-" & hash],
    cwd: "${project}",
    env: @[("CARGO_PKG_NAME", pkg), ("CARGO_PKG_VERSION", "1.0.0")],
    placeholders: @["${target}/debug/build/" & pkg & "-" & hash &
      "/build_script_build-" & hash])

proc runRec(pkg, compileDir, runHash: string): RecordedInvocation =
  RecordedInvocation(kind: rkBuildScriptRun,
    argv: @["${target}/debug/build/" & compileDir & "/build-script-build"],
    cwd: "${project}",
    env: @[("CARGO_PKG_NAME", pkg), ("CARGO_PKG_VERSION", "1.0.0"),
      ("OUT_DIR", "${target}/debug/build/" & pkg & "-" & runHash & "/out")],
    manifest: "${project}/Cargo.toml", manifestFrom: "CARGO_MANIFEST_PATH")

proc samplePlan(): CargoPlan =
  result.units.add PlanUnit(id: "a-1.0.0-0123abcd", package: "a",
    version: "1.0.0", crateName: "a", cargoOutDir: "debug/deps",
    cargoIncrementalDir: "debug/incremental",
    argv: @["rustc", "--crate-name", "a", "${slot:rustc-cfg:b-1.0.0-ff}"],
    cwd: "${project}", env: @[("CARGO_PKG_NAME", "a"),
      ("OUT_DIR", "${out}/b-1.0.0-ff/out")],
    envRemoved: @["GONE"],
    envSlots: @[PlanSlot(kind: "rustc-env", run: "b-1.0.0-ff")],
    outputs: @["${out}/a-1.0.0-0123abcd/liba-0123abcd.rlib"],
    consumes: @["c-1.0.0-1"], closure: @["c-1.0.0-1"],
    fedBy: @["b-1.0.0-ff"], outDirRun: "b-1.0.0-ff")
  result.units.add PlanUnit(id: "b-1.0.0-ee", package: "b", version: "1.0.0",
    crateName: "build_script_build", buildScriptCompile: true,
    argv: @["rustc"],
    outputs: @["${out}/b-1.0.0-ee/build_script_build-ee"],
    executable: "${out}/b-1.0.0-ee/build_script_build-ee")
  result.units.add PlanUnit(id: "c-1.0.0-1", package: "c", version: "1.0.0",
    crateName: "c", argv: @["rustc"])
  result.runs.add PlanRun(id: "b-1.0.0-ff", package: "b", version: "1.0.0",
    compileUnit: "b-1.0.0-ee",
    argv: @["${out}/b-1.0.0-ee/build_script_build-ee"],
    cwd: "${project}/b", env: @[("NUM_JOBS", "1")],
    outDir: "${out}/b-1.0.0-ff/out",
    cargoOutDir: "debug/build/b-ff/out", manifest: "${project}/b/Cargo.toml",
    manifestFrom: "CARGO_MANIFEST_PATH", provider: "${project}/b",
    providers: @[PlanProvider(links: "C", provider: "c@1.0.0")],
    fedBy: @["d-1.0.0-dd"])
  result.units.add PlanUnit(id: "d-1.0.0-cc", package: "d", version: "1.0.0",
    crateName: "build_script_build", buildScriptCompile: true,
    argv: @["rustc"], outputs: @["${out}/d-1.0.0-cc/build_script_build-cc"],
    executable: "${out}/d-1.0.0-cc/build_script_build-cc")
  result.runs.add PlanRun(id: "d-1.0.0-dd", package: "d", version: "1.0.0",
    compileUnit: "d-1.0.0-cc",
    argv: @["${out}/d-1.0.0-cc/build_script_build-cc"],
    outDir: "${out}/d-1.0.0-dd/out")

proc envNames(u: PlanUnit): seq[string] =
  for (name, _) in u.env: result.add name

suite "the plan's binary record":

  test "a plan round-trips through its record":
    let plan = samplePlan()
    validatePlan(plan)
    check decodeCargoPlan(encodeCargoPlan(plan)) == plan

  test "a record that is not a plan is refused":
    let good = encodeCargoPlan(samplePlan())
    var wrongMagic: seq[byte]
    wrongMagic.writeString("reprobuild.somethingElse.v1")
    wrongMagic.add good[4 + CargoPlanMagic.len .. ^1]
    expect CargoPlanError: discard decodeCargoPlan(wrongMagic)
    var wrongVersion = good
    wrongVersion[4 + CargoPlanMagic.len] = 99
    expect CargoPlanError: discard decodeCargoPlan(wrongVersion)
    expect CargoPlanError: discard decodeCargoPlan(good[0 ..< good.len - 1])
    expect CargoPlanError: discard decodeCargoPlan(good & @[0'u8])
    expect CargoPlanError: discard decodeCargoPlan(good[0 ..< 3])

  test "a well-formed record of an inconsistent plan is refused":
    for broken in 0 .. 3:
      var plan = samplePlan()
      case broken
      of 0: plan.units[0].consumes = @["nobody-1.0.0-0"]
      of 1: plan.runs[0].compileUnit = "nobody-1.0.0-0"
      of 2: plan.units[0].outputs = @["${out}/elsewhere/liba.rlib"]
      else: plan.runs[0].id = plan.units[0].id
      checkpoint $broken
      expect CargoPlanError: discard decodeCargoPlan(encodeCargoPlan(plan))

  test "a list longer than the record's bound is refused when encoding":
    var plan = samplePlan()
    for i in 0 .. 65536: plan.units[2].env.add ("V" & $i, "")
    expect CargoPlanError: discard encodeCargoPlan(plan)

  test "a failed write leaves no temporary file":
    let dir = createTempDir("cg5-plan-write-", "")
    defer: removeDir(dir)
    let target = dir / "plan.rbsz"
    createDir(target)   # the rename onto a directory fails
    expect CargoPlanError: writeCargoPlan(target, samplePlan())
    check not fileExists(target & ".partial")
    writeCargoPlan(dir / "ok.rbsz", samplePlan())
    check readCargoPlan(dir / "ok.rbsz") == samplePlan()
    check not fileExists(dir / "ok.rbsz.partial")

suite "the derivation places what cargo wrote":

  test "a unit's directory and outputs are rewritten under ${out}":
    let plan = derivePlan([unitRec()], [], "/wrapper")
    check plan.units.len == 1
    let u = plan.units[0]
    check u.id == "a-1.0.0-0123abcd"
    check u.cargoOutDir == "debug/deps"
    check "${out}/a-1.0.0-0123abcd" in u.argv
    check u.outputs == @["${out}/a-1.0.0-0123abcd/liba-0123abcd.rlib",
      "${out}/a-1.0.0-0123abcd/liba-0123abcd.rmeta"]
    check not u.isFed

  test "a run fed through its dynamic-library path is fed, not refused":
    let recs = @[scriptCompileRec("a", "aaaa"), runRec("a", "a-aaaa", "bbbb"),
      scriptCompileRec("m", "cccc"),
      block:
        var r = runRec("m", "m-cccc", "dddd")
        r.env.add ("LD_LIBRARY_PATH", "${target}/debug/build/a-bbbb/out/" &
          "__repro_slot.rustc-link-search-in-out-dir.a-bbbb")
        r]
    let plan = derivePlan(recs, [], "/wrapper")
    check plan.runById("m-1.0.0-dddd").fedBy == @["a-1.0.0-bbbb"]
    check plan.runById("m-1.0.0-dddd").isFed
    check not plan.runById("a-1.0.0-bbbb").isFed

  test "a unit with an OUT_DIR is fed":
    let recs = @[scriptCompileRec("a", "aaaa"), runRec("a", "a-aaaa", "bbbb"),
      unitRec(env = @[("OUT_DIR", "${target}/debug/build/a-bbbb/out")])]
    let plan = derivePlan(recs, [], "/wrapper")
    check plan.unitById("a-1.0.0-0123abcd").outDirRun == "a-1.0.0-bbbb"
    check plan.unitById("a-1.0.0-0123abcd").isFed

  test "a run of another package's script is refused":
    expect CargoPlanError:
      discard derivePlan([scriptCompileRec("a", "aaaa"),
        runRec("b", "a-aaaa", "bbbb")], [], "/wrapper")

  test "a run whose directory would be a unit's is refused":
    expect CargoPlanError:
      discard derivePlan([scriptCompileRec("a", "aaaa"),
        runRec("a", "a-aaaa", "aaaa")], [], "/wrapper")

  test "a program between the record wrapper and rustc's arguments is " &
      "refused":
    expect CargoPlanError:
      # Under a root, so that only this check can refuse it.
      discard derivePlan([unitRec(argv1 = "${project}/tools/ws-wrapper")], [],
        "/wrapper")

  test "a target-directory path no rule places is refused":
    expect CargoPlanError:
      discard derivePlan([unitRec(@["-L", "native=${target}/elsewhere"])],
        [], "/wrapper")

  test "a scratch path left in the environment is refused":
    expect CargoPlanError:
      discard derivePlan([unitRec(env = @[("X", "${scratch}/home")])], [],
        "/wrapper")

  test "an absolute path under no logical root is refused":
    check derivePlan([unitRec(@["--cfg", "x"])], [], "/wrapper").units.len == 1
    expect CargoPlanError:
      discard derivePlan([unitRec(@["/home/someone/ext/src/lib.rs"])], [],
        "/wrapper")
    expect CargoPlanError:
      discard derivePlan([unitRec(env = @[("CARGO_MANIFEST_DIR",
        "/home/someone/ext")])], [], "/wrapper")
    expect CargoPlanError:
      discard derivePlan([unitRec(env = @[("X", "${project}/a:/usr/lib")])],
        [], "/wrapper")
    # A URL is not a path.
    check derivePlan([unitRec(env = @[("X", "http://127.0.0.1:1")])], [],
      "/wrapper").units.len == 1

  test "a dependency search path outside the target directory is kept":
    let plan = derivePlan([unitRec(@["-L", "dependency=${project}/vendored"])],
      [], "/wrapper")
    let argv = plan.units[0].argv
    check "dependency=${project}/vendored" in argv

  test "no unit at all is refused":
    expect CargoPlanError: discard derivePlan([], [], "/wrapper")

  test "the record run's own variables are not in the difference, and " &
      "cargo's are kept":
    let plan = derivePlan([unitRec(env = @[
      ("CARGO_MAKEFLAGS", "-j --jobserver-fds=7,8"),
      ("RUSTC_WRAPPER", "/wrapper"), ("KEPT", "1"), ("SAME", "base"),
      ("SSL_CERT_FILE", "/etc/ssl/cert.pem"),
      ("CARGO_CRATE_NAME", "a")])],
      [("SAME", "base"), ("DROPPED_BY_CARGO", "v"), ("CARGO_PKG_NAME", "a"),
       ("CARGO_CRATE_NAME", "a")], "/wrapper")
    let u = plan.units[0]
    let names = envNames(u)
    check "KEPT" in names
    check "CARGO_MAKEFLAGS" notin names
    check "RUSTC_WRAPPER" notin names
    check "SAME" notin names
    check "SSL_CERT_FILE" notin names
    # Documented crate variables stay although the base has the same value.
    check "CARGO_PKG_NAME" in names
    check "CARGO_CRATE_NAME" in names
    check u.envRemoved == @["DROPPED_BY_CARGO"]

suite "vendor entries are mapped as whole paths":

  test "an entry maps only itself, never a longer name it is a prefix of":
    let m = @[("${scratch}/vendor/foo-1.0", "${store}/p/foo/1.0-a"),
              ("${scratch}/vendor/foo-1.0.1", "${store}/p/foo/1.0.1-b")]
    check mapVendor("${scratch}/vendor/foo-1.0/src/lib.rs", m) ==
      "${store}/p/foo/1.0-a/src/lib.rs"
    check mapVendor("${scratch}/vendor/foo-1.0.1/src/lib.rs", m) ==
      "${store}/p/foo/1.0.1-b/src/lib.rs"
    check mapVendor("${scratch}/vendor/foo-1.0", m) == "${store}/p/foo/1.0-a"
    check mapVendor("a=${scratch}/vendor/foo-1.0:${scratch}/vendor/" &
      "foo-1.0.1", m) == "a=${store}/p/foo/1.0-a:${store}/p/foo/1.0.1-b"
    # A pre-release, build metadata or another version is another entry.
    for other in ["foo-1.0-beta", "foo-1.0+build", "foo-1.0.10", "foo-1.00"]:
      checkpoint other
      check mapVendor("${scratch}/vendor/" & other & "/x", m) ==
        "${scratch}/vendor/" & other & "/x"

suite "the record run's start-up checks":

  template keepingHome(body: untyped) =
    # `runCargoPlan` points this process's `HOME` and `CARGO_HOME` at its
    # edge-private directories (it is the edge's whole process); put them
    # back.
    let savedHome = getEnv("HOME")
    let savedCargoHome = getEnv("CARGO_HOME")
    try:
      body
    finally:
      putEnv("HOME", savedHome)
      if savedCargoHome.len > 0: putEnv("CARGO_HOME", savedCargoHome)
      else: delEnv("CARGO_HOME")

  proc options(args: seq[string] = @[]): PlanRunOptions =
    PlanRunOptions(planFile: "plan.rbsz", scratch: "scratch",
      cargo: "/no/cargo", rustc: "/no/rustc", cargoArgs: args)

  proc refusal(opts: PlanRunOptions): string =
    keepingHome:
      try: discard runCargoPlan(opts)
      except CatchableError as err: result = err.msg

  test "leftovers in the scratch directory are refused":
    for (rel, isDir) in [(RecordSubdir & "/left-over.json", false),
                         (TargetSubdir & "/debug/x", false),
                         (MetadataFile, false)]:
      let dir = createTempDir("cg5-plan-run-", "")
      defer: removeDir(dir)
      let saved = getCurrentDir()
      setCurrentDir(dir)
      defer: setCurrentDir(saved)
      # Control: with an empty scratch directory the run gets past the
      # checks and fails only where it starts cargo, which does not exist.
      let reached = refusal(options())
      checkpoint reached
      check "cargo metadata" in reached or "cannot start" in reached
      removeDir(dir / "scratch")
      createDir(parentDir(dir / "scratch" / rel))
      if isDir: createDir(dir / "scratch" / rel)
      else: writeFile(dir / "scratch" / rel, "{}")
      let refused = refusal(options())
      checkpoint rel & ": " & refused
      check "not empty" in refused or "exists at the start" in refused

  test "cargo arguments outside the modelled selection are refused":
    check validateCargoArgs(["--release", "-p", "app", "--features=x",
      "--target", "x86_64-unknown-linux-gnu", "--bin", "app"]) == ""
    for args in [@["--config", "x=1"], @["--target-dir", "t"],
                 @["--manifest-path", "m"], @["-j", "8"], @["-Zunstable"],
                 @["--tests"], @["--all-targets"], @["-p"]]:
      checkpoint $args
      check validateCargoArgs(args).len > 0
    let dir = createTempDir("cg5-plan-run-args-", "")
    defer: removeDir(dir)
    let saved = getCurrentDir()
    setCurrentDir(dir)
    defer: setCurrentDir(saved)
    check "--target-dir" in refusal(options(@["--target-dir", "t"]))

  test "sources the record run does not serve are refused before cargo":
    const crates = "registry+https://github.com/rust-lang/crates.io-index"
    proc lockWith(source, checksum: string; name = "dep"): string =
      "version = 4\n\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\n" &
        "dependencies = [\"" & name & "\"]\n\n[[package]]\nname = \"" &
        name & "\"\nversion = \"1.0.0\"\nsource = \"" & source & "\"\n" &
        (if checksum.len > 0: "checksum = \"" & checksum & "\"\n" else: "")
    let cksum = repeat("ab", 32)
    let otherCksum = repeat("cd", 32)
    proc prefixOf(store, name, version, sum: string): string =
      store / prefixRelativePath(name, version, crateRealizationId(
        CrateRow(name: name, version: version, cksum: sum)))
    proc makePrefix(dir, name, version: string) =
      createDir(dir)
      writeFile(dir / "Cargo.toml", "[package]\nname = \"" & name &
        "\"\nversion = \"" & version & "\"\n")
    for (name, expected) in [
        ("git source", "not crates.io"),
        ("no prefix", "no store prefix"),
        ("patch", "[patch]"),
        ("replace", "[replace]"),
        ("config paths", "`paths`"),
        ("config source", "`source`"),
        ("config patch", "`patch`"),
        ("config include", "`include`"),
        ("bad checksum", "not 64 lower-case hex"),
        ("bad name", "not a crates.io crate name"),
        ("parent walk", "without `..`"),
        ("outside link", "outside the store root"),
        ("another crate's prefix", "is not the store's prefix"),
        ("other checksum", "is not the store's prefix"),
        ("wrong manifest", "holds the manifest of other@1.0.0"),
        ("duplicate", "more than one prefix"),
        ("extra", "does not lock it"),
        ("served", "")]:
      let dir = createTempDir("cg5-plan-run-src-", "")
      defer: removeDir(dir)
      let saved = getCurrentDir()
      setCurrentDir(dir)
      defer: setCurrentDir(saved)
      var manifestExtra, config = ""
      var lock = lockWith(crates, cksum)
      let store = dir / "store"
      let good = prefixOf(store, "dep", "1.0.0", cksum)
      makePrefix(good, "dep", "1.0.0")
      var prefix = good
      var extraCrates: seq[CratePrefix]
      case name
      of "git source":
        lock = lockWith("git+https://example.invalid/dep?rev=1#" &
          repeat("c", 40), "")
      of "patch": manifestExtra = "\n[patch.crates-io]\ndep = { path = \"d\" }\n"
      of "replace": manifestExtra = "\n[replace]\n\"dep:1.0.0\" = { path = \"d\" }\n"
      of "config paths": config = "paths = [\"d\"]\n"
      of "config source":
        config = "[source.repro-store-crates]\nreplace-with = \"evil\"\n" &
          "[source.evil]\ndirectory = \"evil\"\n"
      of "config patch": config = "[patch.crates-io]\ndep = { path = \"d\" }\n"
      of "config include": config = "include = \"other.toml\"\n"
      of "bad checksum": lock = lockWith(crates, toUpperAscii(cksum))
      of "bad name": lock = lockWith(crates, cksum, name = "a/b")
      of "parent walk":
        # Spelled by concatenation: `/` would fold the `..` away.
        prefix = store & "/prefixes/../prefixes/" &
          good[store.len + "/prefixes/".len .. ^1]
      of "outside link":
        makePrefix(dir / "elsewhere", "dep", "1.0.0")
        createDir(parentDir(dir / "store" / "prefixes" / "dep" / "link"))
        createSymlink(dir / "elsewhere", store / "prefixes" / "dep" / "link")
        prefix = store / "prefixes" / "dep" / "link"
      of "another crate's prefix":
        prefix = prefixOf(store, "other", "1.0.0", cksum)
        makePrefix(prefix, "dep", "1.0.0")
      of "other checksum":
        prefix = prefixOf(store, "dep", "1.0.0", otherCksum)
        makePrefix(prefix, "dep", "1.0.0")
      of "wrong manifest": makePrefix(good, "other", "1.0.0")
      of "duplicate": extraCrates = @[CratePrefix(name: "dep",
        version: "1.0.0", prefix: good)]
      of "extra": extraCrates = @[CratePrefix(name: "more", version: "2.0.0",
        prefix: good)]
      else: discard
      writeFile(dir / "Cargo.toml", "[package]\nname = \"app\"\n" &
        "version = \"0.1.0\"\n" & manifestExtra)
      writeFile(dir / "Cargo.lock", lock)
      if config.len > 0:
        createDir(dir / ".cargo")
        writeFile(dir / ".cargo" / "config.toml", config)
      var opts = options()
      opts.storeRoot = store
      if name != "no prefix":
        opts.crates = @[CratePrefix(name: (if name == "bad name": "a/b"
          else: "dep"), version: "1.0.0", prefix: prefix)] & extraCrates
      let msg = refusal(opts)
      checkpoint name & ": " & msg
      if expected.len > 0:
        check expected in msg
      else:
        # Served: the run gets as far as starting cargo, with the vendor
        # entry written: a link per prefix entry and the checksum file.
        check "cannot start" in msg
        let entry = dir / "scratch" / VendorSubdir / "dep-1.0.0"
        check symlinkExists(entry / "Cargo.toml")
        check expandSymlink(entry / "Cargo.toml") == good / "Cargo.toml"
        check readFile(entry / ".cargo-checksum.json") ==
          "{\"files\":{},\"package\":\"" & cksum & "\"}"

  test "cargo's metadata must show every served crate read from its " &
      "vendor entry, in this workspace":
    let dir = createTempDir("cg5-plan-meta-", "")
    defer: removeDir(dir)
    let vendored = dir / "scratch" / "vendor" / "dep-1.0.0" / "Cargo.toml"
    proc meta(root, depManifest: string; extra = ""): JsonNode =
      parseJson("""{"workspace_root": """ & escapeJson(root) &
        ""","packages":[{"name":"app","version":"0.1.0","source":null,""" &
        """"manifest_path":""" & escapeJson(dir / "Cargo.toml") & """},""" &
        """{"name":"dep","version":"1.0.0","source":"registry+https://""" &
        """github.com/rust-lang/crates.io-index","manifest_path":""" &
        escapeJson(depManifest) & "}" & extra & "]}")
    let served = @[("dep", "1.0.0", vendored)]
    checkServedManifests(meta(dir, vendored), dir, served)
    expect PlanRunError:
      checkServedManifests(meta(dir, dir / "evil" / "dep-1.0.0" /
        "Cargo.toml"), dir, served)
    expect PlanRunError:
      checkServedManifests(meta(parentDir(dir), vendored), dir, served)
    expect PlanRunError:
      checkServedManifests(meta(dir, vendored, "," &
        """{"name":"more","version":"1.0.0","source":"registry+https://""" &
        """github.com/rust-lang/crates.io-index","manifest_path":"/x"}"""),
        dir, served)
    expect PlanRunError:
      checkServedManifests(meta(dir, vendored), dir,
        served & @[("gone", "1.0.0", "/y")])

  test "an environment variable that outranks the record wrapper is " &
      "refused":
    let dir = createTempDir("cg5-plan-run-env-", "")
    defer: removeDir(dir)
    let saved = getCurrentDir()
    setCurrentDir(dir)
    defer: setCurrentDir(saved)
    putEnv("RUSTC_WRAPPER", "/some/other/wrapper")
    defer: delEnv("RUSTC_WRAPPER")
    check "RUSTC_WRAPPER" in refusal(options())

suite "the edge's key":

  test "two checkouts of a workspace give the edge the same key":
    proc edgeAt(root: string; devEnv = @["PATH=/nix/store/x/bin"]):
        BuildAction =
      cargoPlanEdge(CargoPlanEdgeConfig(name: "app", projectRoot: root,
        planFile: ".repro/build/cargo/app.plan.rbsz",
        scratchDir: ".repro/build/cargo/app.plan-scratch",
        wrapper: "/opt/repro/bin/repro-rustc-wrapper",
        cargo: "/nix/store/c/bin/cargo", rustc: "/nix/store/r/bin/rustc",
        devEnv: devEnv))
    let a = edgeAt("/work/one/ws")
    let b = edgeAt("/work/two/ws")
    check a.relocatable
    check a.weakFingerprint == b.weakFingerprint
    # Control: the key does move with what the edge is given.
    check edgeAt("/work/one/ws", @["PATH=/nix/store/y/bin"]).weakFingerprint !=
      a.weakFingerprint
