## A `-sys` crate's build script, compiled and run as the two edges of the
## plan (`build_script_edges`), through the real engine and monitor: its
## interpreted output is what cargo makes of the same script, and its `links`
## metadata is what cargo hands the crate's immediate dependent.
##
## THE FIXTURE (`writeSysWorkspace`). `sysdep` declares `links = "sysdep"`;
## its build script compiles a C file with `$CC` and archives it with `$AR`
## into `$OUT_DIR/lib/libsysdep.a`, writes a header into `$OUT_DIR/include`
## and a file into its temporary directory, and prints, in both the `cargo::`
## and the `cargo:` form, a link search path inside `OUT_DIR`, a link
## library, two cfgs, two check-cfgs, an env whose value is an `OUT_DIR`
## path, `links` metadata in both forms (`include` and `root`, both `OUT_DIR`
## paths), a warning naming `NUM_JOBS`, and `rerun-if-changed` for
## `build.rs`, its C sources and a directory `extra/` it never reads. It also
## dumps its environment and working directory into `OUT_DIR`. `sysuser`
## depends on `sysdep` and its build script writes the `DEP_SYSDEP_*`
## variables it receives into its `OUT_DIR`; `app` links both.
##
## THE ORACLE. A real `cargo build --message-format=json` of the same
## workspace, with the same closed environment, compiler and `-j 1`: its
## `build-script-executed` message for `sysdep` is cargo's own reading of the
## script's output (cfgs, env, linked libraries and paths, `OUT_DIR`), its
## `sysuser` script's file is the metadata cargo delivered, and `sysdep`'s
## environment dump is what cargo gave the script.
##
## WHAT IS CHECKED.
##
## 1. The plan's build scripts are refused as a whole by `buildScriptEdges`,
##    naming exactly `sysuser`'s run, which receives `DEP_SYSDEP_*` (passed
##    to a run edge by a later change), and nothing is created.
## 2. `sysdep`'s compile and run edges (`buildScriptEdgesOf`): ids, the run's
##    policy (monitored, `hybrid`, network denied, one slot), `OUT_DIR` an
##    opaque output, `TMPDIR` a scratch directory, and the rewritten
##    variables.
## 3. Built through the engine and monitor, both succeed. The static library
##    the script built with the C toolchain it was given is in `OUT_DIR`.
##    The interpreted files, with `${OUT_DIR}` expanded to cargo's `OUT_DIR`,
##    equal cargo's cfgs, env, linked libraries and linked paths, and the
##    metadata file equals the `DEP_SYSDEP_*` cargo gave `sysuser`'s script.
##    No interpreted file names a physical path of the checkout or of the
##    output root.
## 4. The script's environment equals cargo's, except for exactly the
##    variables the run edge rewrites (`OUT_DIR`, mapped back; `TMPDIR`, the
##    edge's scratch directory; `CC`, `CXX`, `AR`; `PATH`, the dev
##    environment's with the C toolchain's directory first), those cargo's
##    own process adds and the run edge does not (`CARGO_MAKEFLAGS`, the
##    oracle's private `CARGO_HOME`, the certificate locations), and,
##    listed by name, those the engine and its monitor set in every launched
##    action outside its declared environment and its key: the host's
##    essential variables and the working directory, the monitor's injection
##    variables, and what the wrapped monitor's process re-seeds into its
##    child (an engine defect, explained where the list is). Any other variable
##    fails it. The dynamic-library path is compared without the target
##    directory's entries, which a run without build-dependencies has none
##    of here. Its working directory is cargo's. The script writes the
##    dumps into its temporary directory, a scratch directory of the edge,
##    so the environment is never in a published output.
##    Variables in the dev environment that would choose another compiler
##    or archiver ahead of `CC` and `AR` (`TARGET_CC`, `CC_<target>`, ...,
##    each naming a compiler that fails), and the shell's own variables,
##    reach no run: the script, which picks its compiler in the `cc`
##    crate's order, compiles with the edge's. A run edge built from a dev
##    environment that differs only in the shell's own variables has the
##    same weak fingerprint; one that differs in a real variable does not.
## 5. `rerun-if-changed` is folded into the run's recorded inputs: built
##    twice more (the second run is the engine's determinism probe, which a
##    deterministic script passes), nothing runs the second time; after an edit under a directory the script never
##    reads and never names, nothing runs (the control); after an edit under
##    `extra/`, which it names and never reads, the run edge runs again and
##    the compile edge does not; so does it after a new file appears under
##    `extra/`, and after `gen-input`, a listed path that did not exist, is
##    created.
##
## Falsifying mutations (applied, observed to fail, reverted): not folding
## `rerun-if-changed` paths into the inputs fails check 5 (the run edge is
## not run again after the edit under `extra/`); not rewriting `CC` fails
## check 2; writing the link-search values without normalising them fails
## check 3 (the comparison with cargo's linked paths and the physical-path
## scan); letting a run with providers through fails check 1. Not removing
## the toolchain selectors fails check 2 (they are in the run's
## environment) and check 3 (the script picks the failing compiler); taking
## the shell's own variables from the dev environment fails check 2 (in the
## environment, and the bumped run's fingerprint differs); a variable named
## like an engine one (`REPRO_LEAKED_SRC`) added to the run's environment
## fails check 4, which excuses only named variables; not folding
## `rerun-if-changed` paths fails check 5 at the edited file, the new file
## and the created path. In the second case, not trimming a line's leading
## whitespace fails the comparison with cargo.
##
## NO MOCKS: real cargo and rustc, the real wrapper (the record run and the
## run edge's interpreter), the real engine and monitor, and the dev shell's
## C compiler standing in for the store-root C toolchain's driver (the same
## kind of wrapped compiler; the store-root toolchain is realized by other
## tests, at a cost of gigabytes).

import std/[algorithm, json, os, sequtils, strutils, tables, tempfiles,
            unittest]

import repro_build_engine
import repro_build_engine/embedded_root_scan
import repro_cargo_edge/[build_script_edges, build_script_output, cargo_plan,
                         plan_units, record_mode]
import repro_test_support

import ./rqe_cg5_plan_fixture

proc writeSysWorkspace(root: string) =
  writeFileIn(root, "Cargo.toml",
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n" &
    "[dependencies]\nsysdep = { path = \"sysdep\" }\n" &
    "sysuser = { path = \"sysuser\" }\n\n" &
    "[workspace]\nmembers = [\"sysdep\", \"sysuser\"]\n")
  writeFileIn(root, "src/main.rs",
    "fn main() { println!(\"{} {}\", sysdep::answer(), sysuser::id()); }\n")
  writeFileIn(root, "sysdep/Cargo.toml",
    "[package]\nname = \"sysdep\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "links = \"sysdep\"\nbuild = \"build.rs\"\n")
  writeFileIn(root, "sysdep/csrc/sys.c", "int sys_answer(void) { return 42; }\n")
  writeFileIn(root, "sysdep/extra/data.txt", "never read\n")
  writeFileIn(root, "sysdep/unlisted/data.txt", "never read either\n")
  writeFileIn(root, "sysdep/build.rs", """
use std::process::Command;
fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    // The `cc` crate's order: `CC_<target>`, `CC_<target with _>`,
    // `TARGET_CC`, then `CC` (and the same for `AR`).
    let target = std::env::var("TARGET").unwrap();
    let pick = |tool: &str, dflt: &str| -> String {
        for name in [format!("{}_{}", tool, target),
                     format!("{}_{}", tool, target.replace("-", "_")),
                     format!("TARGET_{}", tool), tool.to_string()] {
            if let Ok(v) = std::env::var(&name) { return v; }
        }
        dflt.to_string()
    };
    let cc = pick("CC", "cc");
    let ar = pick("AR", "ar");
    std::fs::create_dir_all(format!("{}/lib", out)).unwrap();
    std::fs::create_dir_all(format!("{}/include", out)).unwrap();
    std::fs::write(format!("{}/include/sys.h", out), "int sys_answer(void);\n").unwrap();
    let obj = format!("{}/sys.o", out);
    assert!(Command::new(&cc).args(["-c", "csrc/sys.c", "-o", &obj]).status().unwrap().success());
    let lib = format!("{}/lib/libsysdep.a", out);
    assert!(Command::new(&ar).args(["crsD", &lib, &obj]).status().unwrap().success());
    // The environment and working directory, for the test to compare with
    // cargo's: written into the temporary directory, which for the run edge
    // is a scratch directory and so not an output that could be published.
    let tmp = std::env::temp_dir();
    let mut env = String::new();
    for (k, v) in std::env::vars_os() {
        env.push_str(&format!("{}={}\0", k.to_string_lossy(), v.to_string_lossy()));
    }
    std::fs::write(tmp.join("sysdep-env.dump"), env).unwrap();
    std::fs::write(tmp.join("sysdep-cwd.dump"),
        std::env::current_dir().unwrap().to_string_lossy().as_bytes()).unwrap();
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=csrc");
    println!("cargo:rerun-if-changed=extra");
    println!("cargo:rerun-if-changed=gen-input");
    println!("cargo::rustc-link-search=native={}/lib", out);
    println!("cargo:rustc-link-lib=static=sysdep");
    println!("cargo::rustc-cfg=sys_linked");
    println!("cargo:rustc-cfg=sys_level=\"2\"");
    println!("cargo::rustc-check-cfg=cfg(sys_linked)");
    println!("cargo:rustc-check-cfg=cfg(sys_level, values(\"2\"))");
    println!("cargo:rustc-env=SYS_INCLUDE={}/include", out);
    println!("cargo::metadata=include={}/include", out);
    println!("cargo:root={}", out);
    println!("cargo:warning=num_jobs={}", std::env::var("NUM_JOBS").unwrap());
}
""")
  writeFileIn(root, "sysdep/src/lib.rs",
    "extern \"C\" { fn sys_answer() -> i32; }\n" &
    "pub fn answer() -> i32 { unsafe { sys_answer() } }\n" &
    "#[cfg(all(sys_linked, sys_level = \"2\"))]\n" &
    "pub const INCLUDE: &str = env!(\"SYS_INCLUDE\");\n")
  writeFileIn(root, "sysuser/Cargo.toml",
    "[package]\nname = \"sysuser\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n\n[dependencies]\nsysdep = { path = \"../sysdep\" }\n")
  writeFileIn(root, "sysuser/build.rs", """
fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    let inc = std::env::var("DEP_SYSDEP_INCLUDE").unwrap_or_default();
    let root = std::env::var("DEP_SYSDEP_ROOT").unwrap_or_default();
    std::fs::write(format!("{}/dep.txt", out),
        format!("include={}\nroot={}\n", inc, root)).unwrap();
    println!("cargo:rerun-if-changed=build.rs");
}
""")
  writeFileIn(root, "sysuser/src/lib.rs",
    "pub fn id() -> i32 { sysdep::answer() + 1 }\n")

proc readEnvDump(path: string): Table[string, string] =
  for entry in readFile(path).split('\0'):
    let eq = entry.find('=')
    if eq > 0: result[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

proc homeEnv(dir: string): seq[(string, string)] =
  createDir(dir / "cargo-home")
  createDir(dir / "home")
  @[("CARGO_HOME", dir / "cargo-home"), ("HOME", dir / "home")]

proc cargoConfigArgs(rustc, target: string): seq[string] =
  ## The `--config` values the record run passes, which cargo mixes into its
  ## unit hashes and some of which it passes to build scripts.
  @["--config", "build.rustc=\"" & rustc & "\"",
    "--config", "build.rustc-workspace-wrapper=\"\"",
    "--config", "build.build-dir=\"" & target & "\""]

proc engineConfig(tools: MonitorTools; cacheRoot: string): BuildEngineConfig =
  BuildEngineConfig(cacheRoot: cacheRoot,
    runQuotaCliPath: tools.monitorCliPath,
    monitorCliPath: tools.monitorCliPath,
    monitorCliArgs: tools.monitorCliArgs,
    maxParallelism: 1'u32, stdoutLimit: 1024 * 1024,
    stderrLimit: 1024 * 1024, bypassRunQuota: true)

proc traceOf(run: BuildRunResult; what: string) =
  ## The engine's cache and probe events, for the failure report.
  for t in run.trace:
    if "cache" in t.event or "probe" in t.event or "ineligib" in t.event or
        "evidence" in t.event:
      checkpoint what & " trace " & t.actionId & " " & t.event & " " &
        t.detail[0 ..< min(t.detail.len, 400)]

proc statusOf(run: BuildRunResult; id: string): ActionStatus =
  for r in run.results:
    if r.id == id:
      checkpoint id & ": " & $r.status & " " & $r.cacheDecision & " " &
        r.reason
      return r.status
  raise newException(KeyError, "no result for " & id)

proc expandOutDir(values: seq[string]; outDir: string): seq[string] =
  ## The interpreted values with `${OUT_DIR}` read as ``outDir`` (cargo's).
  let roots = parseRecordRoots(OutDirRootLabel & "=" & outDir)
  for v in values: result.add expandRecorded(roots, v)

suite "a build script as edges":

  test "test_rqe_cg5_build_script_cfg_and_links: a -sys crate's build " &
      "script runs as an edge, and its interpreted output and links " &
      "metadata are cargo's":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let wrapper = requireBinary(
      reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
      "reprobuild.apps.repro-rustc-wrapper")
    let cargo = findExe("cargo")
    let rustc = findExe("rustc")
    require cargo.len > 0 and rustc.len > 0
    let work = createTempDir("cg5-bs-links-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeSysWorkspace(ws)
    let devEnv = @[("PATH", storeOnlyPath()),
      ("TMPDIR", getEnv("TMPDIR", work))]

    # The plan, as the record-only edge makes it.
    let lock = runClosed([cargo, "generate-lockfile", "--offline"], ws,
      devEnv & homeEnv(work / "lock"))
    checkpoint lock.output
    require lock.code == 0
    let record = runClosed([wrapper, "--cargo-plan", "--plan",
      ".plan/app.rbsz", "--scratch", ".plan/scratch", "--cargo", cargo,
      "--rustc", rustc, "--"], ws, devEnv)
    checkpoint record.output
    require record.code == 0
    let plan = readCargoPlan(ws / ".plan" / "app.rbsz")
    var sysRun, userRun: PlanRun
    for r in plan.runs:
      if r.package == "sysdep": sysRun = r
      if r.package == "sysuser": userRun = r
    require sysRun.id.len > 0 and userRun.id.len > 0
    check sysRun.provider.len > 0
    check userRun.providers.len == 1 and userRun.providers[0].links == "SYSDEP"

    # The oracle: a real cargo build.
    let oracleTarget = work / "oracle-target"
    # Its own TMPDIR, where the script leaves its environment dump.
    let oracleTmp = work / "oracle-tmp"
    createDir(oracleTmp)
    let real = runClosed(@[cargo] & cargoConfigArgs(rustc, oracleTarget) &
      @["build", "--offline", "--locked", "-j", "1", "--message-format=json",
      "--target-dir", oracleTarget], ws,
      @[("PATH", storeOnlyPath()), ("TMPDIR", oracleTmp)] &
      homeEnv(work / "oracle"))
    require real.code == 0
    var executed = initTable[string, JsonNode]()
    for line in real.output.splitLines:
      if not line.startsWith("{"): continue
      let msg = parseJson(line)
      if msg{"reason"}.getStr == "build-script-executed":
        for pkg in ["sysdep", "sysuser"]:
          if ("/" & pkg & "#") in msg["package_id"].getStr:
            executed[pkg] = msg
    require "sysdep" in executed and "sysuser" in executed
    let cargoOut = executed["sysdep"]["out_dir"].getStr
    checkpoint "cargo's OUT_DIR: " & cargoOut

    # The C toolchain the run edge is given: the dev shell's wrapped
    # compiler, its directory a directory of its own.
    let tcBin = work / "c-toolchain"
    createDir(tcBin)
    let cc = findExe("cc")
    let cxx = findExe("c++")
    let ar = findExe("ar")
    require cc.len > 0 and cxx.len > 0 and ar.len > 0
    createSymlink(cc, tcBin / "cc")
    let outRoot = work / "edges-out"
    # The dev environment the edges are given carries what must not reach a
    # run: variables that would choose another C compiler or archiver ahead
    # of CC and AR (each naming a compiler that fails), and the variables a
    # shell sets for itself.
    let bogus = work / "bogus-cc"
    writeFile(bogus, "#!/bin/sh\necho 'the dev environment chose me' >&2\n" &
      "exit 1\n")
    setFilePermissions(bogus, {fpUserRead, fpUserWrite, fpUserExec})
    let target = block:
      var t = ""
      for (name, value) in sysRun.env:
        if name == "TARGET": t = value
      t
    require target.len > 0
    let selectors = @["TARGET_CC=" & bogus, "HOST_CC=" & bogus,
      "CC_" & target & "=" & bogus, "CC_" & target.replace('-', '_') & "=" &
      bogus, "TARGET_AR=" & bogus, "AR_" & target & "=" & bogus,
      "TARGET_CXX=" & bogus, "RANLIB_" & target & "=" & bogus,
      "CARGO_TARGET_" & target.toUpperAscii.replace('-', '_') & "_LINKER=" &
      bogus]
    let shellVars = @["PWD=/somewhere", "OLDPWD=/elsewhere", "SHLVL=4",
      "_=/bin/env"]
    let edgeDevEnv = devEnv.mapIt(it[0] & "=" & it[1]) & selectors & shellVars
    proc edgesConfig(dev: seq[string]): BuildScriptEdgesConfig =
      BuildScriptEdgesConfig(
        units: PlanUnitsConfig(projectRoot: ws, outRoot: outRoot,
          toolchainEnv: @["PATH=" & tcBin & ":" & storeOnlyPath()]),
        devEnv: dev, rustc: rustc,
        cToolchain: CToolchain(cc: cc, cxx: cxx, ar: ar, binDir: tcBin),
        interpreter: wrapper)
    let cfg = edgesConfig(edgeDevEnv)

    # 1. The plan as a whole is refused, for sysuser's DEP_* alone.
    try:
      discard buildScriptEdges(plan, cfg)
      checkpoint "the plan was not refused"
      check false
    except BuildScriptRefusal as err:
      checkpoint err.msg
      check err.refused.mapIt(it[0]) == @[userRun.id]
      check "DEP_SYSDEP_*" in err.refused[0][1]
    check not dirExists(outRoot)

    # 2. sysdep's two edges.
    let e = buildScriptEdgesOf(plan, sysRun.id, cfg)
    check e.compile.id == "cargo.build-script-compile/sysdep@0.1.0-" &
      e.compileUnit.id.split('-')[^1]
    check e.runAction.id == "cargo.build-script-run/sysdep@0.1.0-" &
      sysRun.id.split('-')[^1]
    check e.compile.argv == e.compileCargoArgv
    check e.runAction.deps == @[e.compile.id]
    check e.runAction.cacheable
    check e.runAction.isolateHostEnvironment
    check e.runAction.networkMode == netDenied
    check e.runAction.cpuMilli == 1000'u32
    check e.runAction.removeBeforeRun == @[e.outDir]
    check e.outDir in e.runAction.outputs
    check e.runAction.scratchDirs == @[e.tmpDir, e.workDir]
    check e.directivesDir / OutcomeFileName in e.runAction.outputs
    check e.executable in e.runAction.inputs and
      wrapper in e.runAction.inputs
    check e.runAction.cwd == ws / "sysdep"
    var runEnv = initTable[string, string]()
    for entry in e.runAction.env:
      let eq = entry.find('=')
      runEnv[entry[0 ..< eq]] = entry[eq + 1 .. ^1]
    check runEnv["OUT_DIR"] == outRoot / sysRun.id / "out"
    check runEnv["RUSTC"] == rustc
    check runEnv["TMPDIR"] == e.tmpDir
    check runEnv["NUM_JOBS"] == "1"
    check runEnv["CC"] == cc and runEnv["CXX"] == cxx and runEnv["AR"] == ar
    check runEnv["PATH"] == tcBin & ":" & storeOnlyPath()
    for name in ["CARGO_MAKEFLAGS", "MAKEFLAGS", "MFLAGS"]:
      check name notin runEnv
    for entry in selectors & shellVars:
      let name = entry[0 ..< entry.find('=')]
      checkpoint "removed: " & name
      check name notin runEnv
    # A dev-shell bump that moves only the shell's own variables moves no
    # run edge's key; a real dev-environment variable does (the control).
    let bumped = buildScriptEdgesOf(plan, sysRun.id,
      edgesConfig(devEnv.mapIt(it[0] & "=" & it[1]) & selectors &
        @["PWD=/moved", "SHLVL=9", "_=/usr/bin/other"]))
    check bumped.runAction.weakFingerprint == e.runAction.weakFingerprint
    let changed = buildScriptEdgesOf(plan, sysRun.id,
      edgesConfig(edgeDevEnv & @["CG5_DEV_SETTING=1"]))
    check changed.runAction.weakFingerprint != e.runAction.weakFingerprint

    # 3. Through the engine and monitor.
    let tools = prepareMonitorTools(repoRoot, work / "monitor",
      "cg5-bs-links")
    putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
    let config = engineConfig(tools, work / "engine-cache")
    let actions = @[e.compile, e.runAction]
    let first = runBuild(graph(actions), config)
    traceOf(first, "first")
    for r in first.results:
      checkpoint r.id & ": " & $r.status & " " & r.reason &
        (if r.stderr.len > 0: "\nstderr: " & r.stderr else: "")
      check r.status == asSucceeded
    check fileExists(e.outDir / "lib" / "libsysdep.a")
    check getFileSize(e.outDir / "lib" / "libsysdep.a") > 0
    check readOutcomeRecord(e.directivesDir / OutcomeFileName).outcome ==
      roSuccess
    proc values(kind: string): seq[string] =
      readDirectiveRecord(directivePath(e.directivesDir, kind)).values
    let oracle = executed["sysdep"]
    check values("rustc-cfg") == oracle["cfgs"].getElems.mapIt(it.getStr)
    var cargoEnv: seq[string]
    for pair in oracle["env"].getElems:
      cargoEnv.add pair[0].getStr & "=" & pair[1].getStr
    check expandOutDir(values("rustc-env"), cargoOut) == cargoEnv
    check values("rustc-link-lib") ==
      oracle["linked_libs"].getElems.mapIt(it.getStr)
    check expandOutDir(values("rustc-link-search-in-out-dir"), cargoOut) ==
      oracle["linked_paths"].getElems.mapIt(it.getStr)
    check values("rustc-link-search-outside-out-dir").len == 0
    check values("rustc-check-cfg") == @["cfg(sys_linked)",
      "cfg(sys_level, values(\"2\"))"]
    check values("warning") == @["num_jobs=1"]
    check values("rerun-if-changed") == @["build.rs", "csrc", "extra",
      "gen-input"]
    # The links metadata is what cargo handed sysuser's script.
    let delivered = readFile(executed["sysuser"]["out_dir"].getStr /
      "dep.txt").splitLines.filterIt(it.len > 0)
    check expandOutDir(values("metadata"), cargoOut) == delivered
    # No interpreted file, and not the normalised standard output, names a
    # physical path of the checkout or the output root.
    var files = @[e.stdoutFile]
    for name in outputFileNames(): files.add e.directivesDir / name
    for f in files:
      let found = scanOutputForEmbeddedRoots(f, [
        EmbeddedRootNeedle(label: "project", path: ws),
        EmbeddedRootNeedle(label: "out", path: outRoot)])
      checkpoint f & ": found=" & $found.found & " " & found.where
      check not found.found

    # 4. The script's environment and working directory are cargo's, but
    # for what the run edge rewrites and what the engine adds.
    let ours = readEnvDump(e.tmpDir / "sysdep-env.dump")
    let theirs = readEnvDump(oracleTmp / "sysdep-env.dump")
    check readFile(e.tmpDir / "sysdep-cwd.dump") ==
      readFile(oracleTmp / "sysdep-cwd.dump")
    check ours["OUT_DIR"] == e.outDir and theirs["OUT_DIR"] == cargoOut
    check ours["TMPDIR"] == e.tmpDir
    check ours["CC"] == cc and ours["CXX"] == cxx and ours["AR"] == ar
    check ours["PATH"] == tcBin & ":" & storeOnlyPath()
    const Rewritten = ["OUT_DIR", "TMPDIR", "CC", "CXX", "AR", "PATH"]
    const CargoOnly = ["CARGO_MAKEFLAGS", "CARGO_HOME", "SSL_CERT_FILE",
      "SSL_CERT_DIR"]
    # What the engine sets in every action it launches, isolated ones
    # included, outside the declared environment and outside the key: the
    # host's essential variables, the action's working directory (and the
    # previous one and the program path the wrapped monitor's `repro`
    # process leaves), and the switches that keep a nested build unmanaged
    # and the monitor quiet. The run edge itself declares none of them.
    const EngineLaunch = ["HOME", "LANG", "USER", "LOGNAME", "PWD", "OLDPWD",
      "_", "REPROBUILD_NO_RUNQUOTA", "IO_MON_MUTE"]
    # The io monitor's own injection variables in the monitored tree.
    const MonitorInjection = ["LD_PRELOAD", "REPRO_MONITOR_SHIM_LIB",
      "REPRO_MONITOR_OUTPUT", "REPRO_MONITOR_FRAGMENT_DIR",
      "REPRO_MONITOR_SITE_TABLES", "REPRO_MONITOR_COLLECTION_EVIDENCE",
      "REPRO_MONITOR_SESSION", "REPRO_MONITOR_EVIDENCE",
      "REPRO_MONITOR_EXEC_GEN", "REPRO_MONITOR_APP_ID",
      "REPRO_MONITOR_INTEREST", "REPRO_MONITOR_DEP_SHM"]
    # What the wrapped io monitor's own process seeds and passes on to every
    # monitored child: the engine withholds its seeded source roots from an
    # action (`withheldSeededSourceRoots`), but the `repro` process hosting
    # the monitor seeds them again and its child inherits them, outside the
    # action's declared environment and its key. That is an engine defect,
    # not the run edge's. Listed by name, so that any other variable
    # reaching the script fails this check.
    const MonitorReseeds = ["REPRO_INVOKING_CLI", "REPRO_SHARED_POOL_CLI",
      "REPRO_BOOTSTRAP_SOURCE_ENV",
      "BEARSSL_SRC", "CLI_SPEC_SRC", "CODETRACER_PINNED_SRC", "CONFUTILS_SRC",
      "ENTRYPOINTS_SRC", "IO_MON_SRC", "NIMCRYPTO_SRC",
      "REPRO_CT_TEST_RUNNER_SRC", "REPRO_TEST_ADAPTERS_SRC", "RUNQUOTA_SRC",
      "SHM_GSET_SRC", "SHM_QUEUE_SRC", "STACKABLE_HOOKS_SRC"]
    proc dylibPath(value, drop: string): string =
      value.split(':').filterIt(it.len > 0 and not it.startsWith(drop)).join(":")
    for name in toSeq(ours.keys) & toSeq(theirs.keys):
      checkpoint "variable " & name
      if name in Rewritten: continue
      if name in CargoOnly:
        check name notin ours
        continue
      if name in MonitorInjection or name in MonitorReseeds:
        check name notin theirs
        continue
      if name in EngineLaunch:
        check name in ours
        continue
      var o = ours.getOrDefault(name, "<unset>")
      var t = theirs.getOrDefault(name, "<unset>")
      if name == "LD_LIBRARY_PATH":
        o = dylibPath(o, outRoot)
        t = dylibPath(t, oracleTarget)
      checkpoint name & ": ours " & o & " | cargo's " & t
      check o == t

    # 5. rerun-if-changed is folded into the run's recorded inputs. The
    # second build is the engine's determinism probe (rustc and the C
    # compiler read entropy, so an edge is cached once a second run with the
    # same inputs writes the same bytes); the third runs nothing.
    let second = runBuild(graph(actions), config)
    traceOf(second, "second")
    for r in second.results:
      checkpoint r.id & " second: " & $r.status & " " & r.reason
      check r.status in {asSucceeded, asCacheHit, asUpToDate}
    let settled = runBuild(graph(actions), config)
    traceOf(settled, "settled")
    for id in [e.compile.id, e.runAction.id]:
      checkpoint id & " third: " & $settled.statusOf(id)
      check settled.statusOf(id) in {asCacheHit, asUpToDate}
    writeFile(ws / "sysdep" / "unlisted" / "data.txt", "edited\n")
    let control = runBuild(graph(actions), config)
    traceOf(control, "control")
    for id in [e.compile.id, e.runAction.id]:
      checkpoint id & " control: " & $control.statusOf(id)
      check control.statusOf(id) in {asCacheHit, asUpToDate}
    writeFile(ws / "sysdep" / "extra" / "data.txt", "edited\n")
    let third = runBuild(graph(actions), config)
    traceOf(third, "third")
    checkpoint "third: " & $third.statusOf(e.compile.id) & " " &
      $third.statusOf(e.runAction.id)
    check third.statusOf(e.compile.id) in {asCacheHit, asUpToDate}
    check third.statusOf(e.runAction.id) == asSucceeded
    # A new file under a listed directory runs it again.
    writeFile(ws / "sysdep" / "extra" / "new.txt", "new\n")
    let fourth = runBuild(graph(actions), config)
    traceOf(fourth, "fourth")
    check fourth.statusOf(e.runAction.id) == asSucceeded
    # So does a listed path that did not exist and now does.
    writeFile(ws / "sysdep" / "gen-input", "now here\n")
    let fifth = runBuild(graph(actions), config)
    traceOf(fifth, "fifth")
    check fifth.statusOf(e.runAction.id) == asSucceeded

  test "the interpreter reads the older and newer forms as cargo does":
    # Each line is printed by a real build script of a `links` package
    # under real cargo, whose dependent records the `DEP_SYS_*` it gets; the
    # interpreter's reading of the same line must agree: the same cfgs, the
    # same metadata, the same build failures. A line the interpreter
    # refuses must be one cargo accepts (a refusal hands the workspace to
    # cargo, so it must never stand for a build cargo fails).
    let cargo = findExe("cargo")
    require cargo.len > 0
    let work = createTempDir("cg5-bs-forms-", "")
    defer: removeTestTree(work)
    let lines = ["   cargo:rustc-cfg=lead_ws", "\tcargo:rustc-cfg=lead_tab",
      "cargo:rustc-cfg=trail_ws   ", "cargo:error=boom", "cargo::error=boom",
      "cargo:metadata=k=v", "cargo::metadata=k=v", "cargo:rustc-link-args=-x",
      "cargo:rerun-bogus=1", "cargo::bogus=1", "cargo:noequals",
      "cargo:include=/i"]
    for i, line in lines:
      checkpoint "line " & line.escape()
      let ws = work / ("c" & $i)
      writeFileIn(ws, "Cargo.toml", "[package]\nname = \"app\"\n" &
        "version = \"0.1.0\"\nedition = \"2021\"\n[dependencies]\n" &
        "user = { path = \"user\" }\n[workspace]\nmembers = [\"sys\", " &
        "\"user\"]\n")
      writeFileIn(ws, "src/main.rs", "fn main() {}\n")
      writeFileIn(ws, "sys/Cargo.toml", "[package]\nname = \"sys\"\n" &
        "version = \"0.1.0\"\nedition = \"2021\"\nlinks = \"sys\"\n" &
        "build = \"build.rs\"\n")
      writeFileIn(ws, "sys/src/lib.rs", "")
      writeFileIn(ws, "sys/build.rs", "fn main() { println!(\"{}\", " &
        line.escape() & "); }\n")
      writeFileIn(ws, "user/Cargo.toml", "[package]\nname = \"user\"\n" &
        "version = \"0.1.0\"\nedition = \"2021\"\nbuild = \"build.rs\"\n" &
        "[dependencies]\nsys = { path = \"../sys\" }\n")
      writeFileIn(ws, "user/src/lib.rs", "")
      writeFileIn(ws, "user/build.rs", "fn main() { let mut s = " &
        "String::new(); for (k, v) in std::env::vars() { if " &
        "k.starts_with(\"DEP_SYS_\") { s.push_str(&format!(\"{}={}\\n\", " &
        "k, v)); } } std::fs::write(format!(\"{}/dep.txt\", " &
        "std::env::var(\"OUT_DIR\").unwrap()), s).unwrap(); }\n")
      let r = runClosed([cargo, "build", "--offline", "-j", "1",
        "--message-format=json", "--target-dir", ws / "target"], ws,
        @[("PATH", storeOnlyPath()), ("TMPDIR", work)] & homeEnv(ws))
      var cfgs: seq[string]
      var dep: seq[string]
      for l in r.output.splitLines:
        if not l.startsWith("{"): continue
        let msg = parseJson(l)
        if msg{"reason"}.getStr == "build-script-executed":
          let id = msg["package_id"].getStr
          if "/sys#" in id:
            cfgs = msg["cfgs"].getElems.mapIt(it.getStr)
          if "/user#" in id:
            dep = readFile(msg["out_dir"].getStr / "dep.txt").splitLines.
              filterIt(it.len > 0)
      var failure = ""
      var parsed: ParsedOutput
      try:
        parsed = parseBuildScriptOutput(line & "\n", "/o")
      except BuildScriptOutputError as err:
        failure = $err.failure
      checkpoint "cargo exit " & $r.code & ", ours " &
        (if failure.len > 0: failure else: "accepted")
      if failure == $dfRefusal:
        check r.code == 0
        continue
      let oursFails = failure == $dfBuildError or parsed.errors.len > 0
      check oursFails == (r.code != 0)
      if oursFails: continue
      check parsed.values["rustc-cfg"] == cfgs
      var ours: seq[string]
      for m in parsed.values["metadata"]:
        let eq = m.find('=')
        ours.add "DEP_SYS_" & m[0 ..< eq].toUpperAscii.replace('-', '_') &
          "=" & m[eq + 1 .. ^1]
      check ours.sorted == dep.sorted
