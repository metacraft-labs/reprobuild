## The record run keeps cargo inside the edge, and refuses what it cannot
## plan from inside the workspace.
##
## THE CONTRACT. The record-only graph-production edge's process
## (`repro-rustc-wrapper --cargo-plan`) must:
##
## - keep cargo's intermediate files in its scratch target directory even
##   when the project's configuration (`build.build-dir`) or the environment
##   (`CARGO_BUILD_BUILD_DIR`) points them elsewhere: placeholders and stubs
##   written there would enter a later real build's freshness state;
## - keep a project's own `build.rustc-workspace-wrapper` from running
##   between the record wrapper and rustc (it would run for every probe, and
##   a recorded unit's command line would start with it);
## - refuse a cargo configuration file above the workspace root, which cargo
##   reads and which lies outside every logical root;
## - refuse a workspace package whose manifest lies outside the workspace
##   root, before cargo builds anything;
## - refuse a project configuration that re-routes the replacement source
##   the run sets (a `[source]` table), and, behind that, refuse a crates.io
##   package cargo read from anywhere but the run's own vendor entry;
## - refuse a working directory inside an enclosing workspace, whose root
##   (with its own lock and patches) the run would never read.
##
## HOW IT IS OBSERVED. Each case writes a one-package workspace (with a
## build script) under a fresh temporary directory and runs the real record
## run on it in a closed environment, then looks at the filesystem and at
## the run's exit status and message.
##
## Falsifying mutations (applied, observed to fail, reverted; see the
## change's report): dropping the `build.build-dir` override (the configured
## directory is created); dropping the empty `build.rustc-workspace-wrapper`
## override (the project's wrapper runs, and the derivation refuses its
## command lines); dropping the check of configuration files above the
## workspace (the run succeeds); dropping the check of package manifests
## outside the workspace (the run is refused only later, by the derivation,
## after cargo has run, and with another message); dropping the refusal of
## `[source]` in the project configuration (the run is still refused, by the
## check of the manifests cargo read); dropping both (the re-routed run
## succeeds); dropping the workspace-root check (the enclosing case
## succeeds).
##
## NO MOCKS: real cargo and rustc, the real wrapper. The project's workspace
## wrapper is a shell script that logs that it ran and then runs rustc, as a
## project's own wrapper would.

import std/[os, strutils, tempfiles, unittest]

import repro_cargo_edge/[cargo_plan, plan_run]
import repro_test_support

import ./rqe_cg5_plan_fixture

proc writeSmall(root: string; extraManifest = "") =
  writeFileIn(root, "Cargo.toml",
    "[package]\nname = \"small\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n" & extraManifest)
  writeFileIn(root, "build.rs", "fn main() {}\n")
  writeFileIn(root, "src/lib.rs", "pub fn f() -> u32 { 1 }\n")

type Setup = object
  wrapper, cargo, rustc: string
  env: seq[(string, string)]

proc setup(work: string): Setup =
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  result.wrapper = requireBinary(
    reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
    "reprobuild.apps.repro-rustc-wrapper")
  result.cargo = findExe("cargo")
  result.rustc = findExe("rustc")
  require result.cargo.len > 0 and result.rustc.len > 0
  result.env = @[("PATH", storeOnlyPath()),
    ("TMPDIR", getEnv("TMPDIR", work))]

proc lock(s: Setup; ws, work: string) =
  let home = work / "lock-home"
  createDir(home)
  let r = runClosed([s.cargo, "generate-lockfile", "--offline"], ws,
    s.env & @[("HOME", home), ("CARGO_HOME", home / ".cargo")])
  checkpoint r.output
  require r.code == 0

proc recordRun(s: Setup; ws: string;
               extraEnv: seq[(string, string)] = @[]): ClosedRun =
  result = runClosed([s.wrapper, "--cargo-plan", "--plan", ".plan/p.rbsz",
    "--scratch", ".plan/scratch", "--cargo", s.cargo, "--rustc", s.rustc,
    "--"], ws, s.env & extraEnv)
  checkpoint result.output

suite "the record run keeps cargo inside the edge":

  test "test_rqe_cg5_record_run_keeps_the_build_dir: a configured or " &
      "exported build-dir does not move cargo's files out of the scratch " &
      "directory":
    let work = createTempDir("cg5-build-dir-", "")
    defer: removeDir(work)
    let s = setup(work)
    let ws = work / "ws"
    writeSmall(ws)
    writeFileIn(ws, ".cargo/config.toml",
      "[build]\nbuild-dir = \"" & work / "configured-build-dir" & "\"\n")
    s.lock(ws, work)
    let r = s.recordRun(ws, @[("CARGO_BUILD_BUILD_DIR",
      work / "exported-build-dir")])
    check r.code == 0
    check not dirExists(work / "configured-build-dir")
    check not dirExists(work / "exported-build-dir")
    check dirExists(ws / ".plan" / "scratch" / "target" / "debug" / "deps")
    check readCargoPlan(ws / ".plan" / "p.rbsz").units.len == 2

  test "test_rqe_cg5_record_run_neutralises_a_workspace_wrapper: a " &
      "project's rustc-workspace-wrapper never runs":
    let work = createTempDir("cg5-ws-wrapper-", "")
    defer: removeDir(work)
    let s = setup(work)
    let ws = work / "ws"
    writeSmall(ws)
    let log = work / "ws-wrapper.log"
    let wsWrapper = work / "ws-wrapper"
    writeFile(wsWrapper, "#!/bin/sh\necho ran >> " & quoteShell(log) &
      "\nexec \"$@\"\n")
    setFilePermissions(wsWrapper, {fpUserRead, fpUserWrite, fpUserExec})
    writeFileIn(ws, ".cargo/config.toml",
      "[build]\nrustc-workspace-wrapper = \"" & wsWrapper & "\"\n")
    s.lock(ws, work)
    let r = s.recordRun(ws)
    check r.code == 0
    check not fileExists(log)
    let plan = readCargoPlan(ws / ".plan" / "p.rbsz")
    for u in plan.units:
      check u.argv.len > 1 and u.argv[1].startsWith("-")

suite "the record run refuses what lies outside the workspace":

  test "test_rqe_cg5_record_run_refuses_an_outer_cargo_config: a cargo " &
      "configuration file above the workspace is refused":
    let work = createTempDir("cg5-outer-config-", "")
    defer: removeDir(work)
    let s = setup(work)
    let ws = work / "outer" / "ws"
    writeSmall(ws)
    s.lock(ws, work)
    # Control: without the outer file the run succeeds.
    check s.recordRun(ws).code == 0
    removeDir(ws / ".plan")
    writeFileIn(work / "outer", ".cargo/config.toml", "[build]\n")
    let r = s.recordRun(ws)
    check r.code == 1
    check (work / "outer" / ".cargo" / "config.toml") in r.output
    check not fileExists(ws / ".plan" / "p.rbsz")

  test "test_rqe_cg5_record_run_refuses_an_outside_member: a path package " &
      "outside the workspace root is refused before cargo builds":
    let work = createTempDir("cg5-outside-member-", "")
    defer: removeDir(work)
    let s = setup(work)
    let ws = work / "ws"
    writeSmall(ws, "\n[dependencies]\next = { path = \"../ext\" }\n")
    writeFileIn(work / "ext", "Cargo.toml",
      "[package]\nname = \"ext\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
    writeFileIn(work / "ext", "src/lib.rs", "pub fn g() {}\n")
    s.lock(ws, work)
    let r = s.recordRun(ws)
    check r.code == 1
    check "outside the workspace root" in r.output
    check "ext" in r.output
    check not fileExists(ws / ".plan" / "p.rbsz")
    # Refused before cargo built anything: no target directory was made.
    check not dirExists(ws / ".plan" / "scratch" / "target" / "debug")

  test "test_rqe_cg5_record_run_refuses_a_rerouted_source: a project " &
      "configuration that re-routes the store's replacement is refused":
    let work = createTempDir("cg5-rerouted-", "")
    defer: removeTestTree(work)
    let s = setup(work)
    let ws = work / "ws"
    writeSmall(ws, "\n[dependencies]\nregleaf = \"0.1.0\"\n")
    let reg = setupRegistry(work, smReal)
    let lockHome = work / "lock-home"
    createDir(lockHome)
    let lock = runClosed(@[s.cargo] & reg.sourceArgs &
      @["generate-lockfile", "--offline"], ws,
      s.env & @[("HOME", lockHome), ("CARGO_HOME", lockHome / ".cargo")])
    checkpoint lock.output
    require lock.code == 0
    var args = @["--store-root", reg.store]
    for c in reg.crates:
      if c.name == "regleaf": args.add ["--crate", crateArg(c)]
    proc run(): ClosedRun =
      result = runClosed(@[s.wrapper, "--cargo-plan", "--plan",
        ".plan/p.rbsz", "--scratch", ".plan/scratch", "--cargo", s.cargo,
        "--rustc", s.rustc] & args & @["--"], ws, s.env)
      checkpoint result.output
    # Control: served from the store, the run succeeds.
    check run().code == 0
    removeDir(ws / ".plan")
    # The project's configuration points the run's own replacement source
    # at a directory of its own, with a hand-written checksum file that
    # passes cargo's check.
    let evil = ws / "evil" / "regleaf-0.1.0"
    createDir(evil / "src")
    writeFile(evil / "Cargo.toml", "[package]\nname = \"regleaf\"\n" &
      "version = \"0.1.0\"\nedition = \"2021\"\n")
    writeFile(evil / "src" / "lib.rs", "pub fn leaf() -> u32 { 666 }\n")
    var cksum = ""
    for line in readFile(ws / "Cargo.lock").splitLines:
      if line.startsWith("checksum = "): cksum = line[12 ..< ^1]
    writeFile(evil / ".cargo-checksum.json",
      "{\"files\":{},\"package\":\"" & cksum & "\"}")
    writeFileIn(ws, ".cargo/config.toml",
      "[source.repro-store-crates]\nreplace-with = \"evil\"\n" &
      "[source.evil]\ndirectory = \"evil\"\n")
    let r = run()
    check r.code == 1
    # Refused by the configuration check, or, behind it, by the check of
    # where cargo read each crate from; never by anything else.
    check "sets `source`" in r.output or
      "not from the record run's vendor entry" in r.output
    check not fileExists(ws / ".plan" / "p.rbsz")

  test "test_rqe_cg5_record_run_refuses_an_enclosing_workspace: a " &
      "workspace whose root is above the working directory is refused":
    let work = createTempDir("cg5-enclosing-", "")
    defer: removeDir(work)
    let s = setup(work)
    let outer = work / "outer"
    writeFileIn(outer, "Cargo.toml", "[workspace]\nmembers = [\"ws\"]\n" &
      "resolver = \"2\"\n")
    let ws = outer / "ws"
    writeSmall(ws)
    s.lock(outer, work)
    let r = s.recordRun(ws)
    check r.code == 1
    check "workspace root" in r.output
    check not fileExists(ws / ".plan" / "p.rbsz")
