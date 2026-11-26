## The rustc wrapper's record mode lets cargo run a whole build and compiles
## nothing.
##
## THE CONTRACT. With `REPRO_RUSTC_WRAPPER_RECORD` set, `repro-rustc-wrapper`
## records each compile unit cargo starts (argv, working directory,
## environment) and writes empty placeholders for the unit's outputs instead
## of compiling it; probes pass through to the real rustc; a build script's
## compile writes the recording stub, which cargo then runs in the script's
## place and which records the build script's argv, working directory and
## environment and prints the sentinel directives. Paths under the declared
## logical roots are recorded against them. Record mode takes no RunQuota
## sub-lease and starts no measurement.
##
## HOW IT IS OBSERVED. A five-package workspace, built by real cargo
## (`--offline --locked`, a scratch target directory) with the wrapper in
## record mode:
##
##   - `sysdep`: a library with `links = "sysdep"` and a build script;
##   - `mid`: a library depending on `sysdep` (its immediate dependent), with
##     a build script that has `helper` as a build-dependency;
##   - `helper`: a library, compiled for the host as a build-dependency;
##   - `pm`: a proc-macro;
##   - `app`: the root package, two binaries and an integration test, with a
##     build script, depending on `mid` (so `sysdep` is transitive) and `pm`.
##
## Every build script PANICS, after leaving a marker file, if it ever runs:
## a run of package code would fail the build and leave the marker. The
## compiler is named to cargo as `RUSTC`, a logging shim that records every
## invocation that reaches it and then runs the real rustc, so "no rustc but
## probes" is read from what reached the compiler, not from the wrapper's own
## account. The wrapper is given an enclosing lease and the `profiles`
## measurement, with no daemon behind the socket: outside record mode it
## would try to report and log why it could not; in record mode it must log
## every unit as recorded and nothing else.
##
## What this case does not cover, and why: the record run as a monitored
## graph-production edge (no network connection, edge-private cargo home,
## the plan as its one output) is the next piece of work, which wraps this
## mode in that edge; the network half of "compiles nothing" is asserted
## there, where the monitor's evidence exists.
##
## Falsifying mutation (applied, observed to fail, reverted): letting the
## wrapper run rustc for a build-script unit. The build-script compile then
## reaches the logging shim as a unit and the real build script runs, panics
## and fails cargo.
##
## NO MOCKS: real cargo and rustc, the real wrapper and stub. The logging
## `RUSTC` shim is an observer in front of the real compiler (it runs it with
## the arguments it was given and changes nothing), the same instrument the
## wrapper's transparency cases use.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support
import repro_cargo_edge/[record_mode, rustc_args]
import rqe_cg3_fixture

const ArgSeparator = "\x1f"

proc writeFileIn(dir, rel, content: string) =
  createDir(parentDir(dir / rel))
  writeFile(dir / rel, content)

proc buildScript(pkg: string; useHelper = false): string =
  ## A build script that must never run: it leaves a marker and panics.
  (if useHelper: "fn main() { let _ = helper::id();\n" else: "fn main() {\n") &
    "  if let Ok(dir) = std::env::var(\"CG5_MARKER_DIR\") {\n" &
    "    let _ = std::fs::create_dir_all(&dir);\n" &
    "    let _ = std::fs::write(format!(\"{}/ran-" & pkg & "\", dir), \"\");\n" &
    "  }\n" &
    "  panic!(\"the build script of " & pkg & " ran\");\n}\n"

proc writeWorkspace(root: string) =
  scrubAmbientCargoEnv()
  writeFileIn(root, "Cargo.toml",
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n\n" &
    "[[bin]]\nname = \"app\"\npath = \"src/main.rs\"\n\n" &
    "[[bin]]\nname = \"app-tool\"\npath = \"src/bin/tool.rs\"\n\n" &
    "[dependencies]\nmid = { path = \"mid\" }\npm = { path = \"pm\" }\n\n" &
    "[workspace]\nmembers = [\"sysdep\", \"mid\", \"helper\", \"pm\"]\n")
  writeFileIn(root, "build.rs", buildScript("app"))
  writeFileIn(root, "src/main.rs",
    "fn main() { println!(\"{} {}\", mid::id(), pm::answer!()); }\n")
  writeFileIn(root, "src/bin/tool.rs", "fn main() {}\n")
  writeFileIn(root, "tests/smoke.rs", "#[test]\nfn smoke() {}\n")

  writeFileIn(root, "sysdep/Cargo.toml",
    "[package]\nname = \"sysdep\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "links = \"sysdep\"\nbuild = \"build.rs\"\n")
  writeFileIn(root, "sysdep/build.rs", buildScript("sysdep"))
  writeFileIn(root, "sysdep/src/lib.rs", "pub fn id() -> u32 { 1 }\n")

  writeFileIn(root, "mid/Cargo.toml",
    "[package]\nname = \"mid\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n\n[dependencies]\nsysdep = { path = \"../sysdep\" }\n" &
    "\n[build-dependencies]\nhelper = { path = \"../helper\" }\n")
  writeFileIn(root, "mid/build.rs", buildScript("mid", useHelper = true))
  writeFileIn(root, "mid/src/lib.rs", "pub fn id() -> u32 { sysdep::id() }\n")

  writeFileIn(root, "helper/Cargo.toml",
    "[package]\nname = \"helper\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
  writeFileIn(root, "helper/src/lib.rs", "pub fn id() -> u32 { 2 }\n")

  writeFileIn(root, "pm/Cargo.toml",
    "[package]\nname = \"pm\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n" &
    "[lib]\nproc-macro = true\n")
  writeFileIn(root, "pm/src/lib.rs",
    "use proc_macro::TokenStream;\n#[proc_macro]\n" &
    "pub fn answer(_: TokenStream) -> TokenStream { \"42\".parse().unwrap() }\n")

proc writeRustcLogger(path, realRustc, log: string) =
  ## `RUSTC` for cargo: append every invocation's arguments, joined by a unit
  ## separator, to `log`, then run the real compiler unchanged.
  writeFile(path, "#!/bin/sh\nline=\nfor a in \"$@\"; do line=\"$line$a" &
    ArgSeparator & "\"; done\nprintf '%s\\n' \"$line\" >> " &
    quoteShell(log) & "\nexec " & quoteShell(realRustc) & " \"$@\"\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc unitsNamed(recs: seq[RecordedInvocation]; crate: string):
    seq[RecordedInvocation] =
  for rec in recs:
    if rec.kind == rkUnit:
      let parsed = rustcUnitOf(rec.argv[1 .. ^1])
      if parsed.isUnit and parsed.unit.crateName == crate: result.add rec

proc runOf(recs: seq[RecordedInvocation]; pkg: string): RecordedInvocation =
  for rec in recs:
    if rec.kind == rkBuildScriptRun and rec.envOf("CARGO_PKG_NAME") == pkg:
      return rec
  raise newException(KeyError, "no recorded build-script run of " & pkg)

proc runName(roots: seq[RecordRoot]; run: RecordedInvocation): string =
  ## Cargo's name for the run: the directory holding its `OUT_DIR`.
  extractFilename(parentDir(expandRecorded(roots, run.envOf("OUT_DIR"))))

suite "the wrapper's record mode":

  test "test_rqe_cg5_record_mode_compiles_nothing: cargo completes a build " &
      "of a workspace with build scripts and a proc-macro, and nothing but " &
      "probes reaches rustc":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let wrapper = requireBinary(
      reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
      "reprobuild.apps.repro-rustc-wrapper")
    let cargo = findExe("cargo")
    let realRustc = findExe("rustc")
    require cargo.len > 0 and realRustc.len > 0

    let scratch = createTempDir("record-mode-", "")
    defer: removeDir(scratch)
    let ws = scratch / "ws"
    let targetDir = scratch / "target"
    let recordDir = scratch / "record"
    let markers = scratch / "markers"
    writeWorkspace(ws)

    proc run(cmd: CmdSpec): string =
      let res = runShell(cmd, ws, timeoutMs = 600_000)
      checkpoint res.output
      require res.code == 0
      res.output

    discard run(shellCommand([cargo, "generate-lockfile", "--offline"]))
    let metadataFile = scratch / "metadata.json"
    # Standard output only: the file must hold cargo's JSON and nothing else.
    let metadata = execCmdEx(quoteShellCommand([cargo, "metadata",
      "--offline", "--format-version", "1"]) & " 2>/dev/null",
      workingDir = ws)
    checkpoint metadata.output
    require metadata.exitCode == 0
    writeFile(metadataFile, metadata.output)

    let rustcLog = scratch / "rustc.log"
    let logger = scratch / "rustc-logger"
    writeRustcLogger(logger, realRustc, rustcLog)
    let wrapperLog = scratch / "wrapper.log"
    var rootLines = @["project=" & ws, "target=" & targetDir,
      "scratch=" & scratch]
    if dirExists("/nix/store"): rootLines.add "store=/nix/store"
    let roots = parseRecordRoots(rootLines.join("\n"))

    discard run(shellCommand([cargo, "build", "--offline", "--locked",
        "--target-dir", targetDir],
      env = [("RUSTC", logger), ("RUSTC_WRAPPER", wrapper),
             (RecordDirEnv, recordDir), (RecordRootsEnv, rootLines.join("\n")),
             (RecordMetadataEnv, metadataFile),
             ("REPRO_RUSTC_WRAPPER_LOG", wrapperLog),
             # An enclosing lease and a measurement, with no daemon: the
             # reporting path, if it were taken, would log its failure.
             ("RUNQUOTA_PARENT_LEASE", "4242"),
             ("RUNQUOTA_SOCKET", scratch / "no-daemon.sock"),
             ("RUNQUOTA_MEASUREMENT", "profiles"),
             ("CG5_MARKER_DIR", markers)]))

    # Nothing but probes reached the compiler, and the probes did (the
    # logger works: cargo cannot plan without `rustc -vV`).
    let invocations = readFile(rustcLog).splitLines.filterIt(it.len > 0)
    checkpoint "rustc invocations: " & $invocations.len
    check invocations.len > 0
    for line in invocations:
      let args = line.split(ArgSeparator).filterIt(it.len > 0)
      if rustcUnitOf(args).isUnit:
        checkpoint "a unit reached rustc: " & args.join(" ")
        check false

    # No build script ran.
    check not dirExists(markers)

    # Every unit was recorded, the build-script compiles as such, and each
    # build script's run was recorded in its place.
    let recs = readRecordings(recordDir)
    for (crate, count) in [("app", 1), ("app_tool", 1), ("mid", 1),
                           ("sysdep", 1), ("helper", 1), ("pm", 1),
                           ("build_script_build", 3)]:
      checkpoint crate
      check unitsNamed(recs, crate).len == count
    check unitsNamed(recs, "smoke").len == 0  # `cargo build` builds no tests
    for rec in unitsNamed(recs, "build_script_build"):
      check rec.buildScriptCompile
    check recs.filterIt(it.kind == rkBuildScriptRun).len == 3

    # The placeholders exist: a build script's executable is the stub (the
    # wrapper's own image), everything else an empty file. Cargo's uplifted
    # binary is a link of the placeholder.
    let wrapperSize = getFileSize(wrapper)
    for rec in recs.filterIt(it.kind == rkUnit):
      check rec.placeholders.len > 0
      for recorded in rec.placeholders:
        let path = expandRecorded(roots, recorded)
        checkpoint path
        check fileExists(path)
        if rec.buildScriptCompile and not path.endsWith(".d"):
          check getFileSize(path) == wrapperSize
        else:
          check getFileSize(path) == 0
    let sysdepUnit = unitsNamed(recs, "sysdep")[0]
    for suffix in [".rlib", ".rmeta", ".d"]:
      check sysdepUnit.placeholders.anyIt(it.endsWith(suffix))
    check unitsNamed(recs, "pm")[0].placeholders.anyIt(it.endsWith(".so") or
      it.endsWith(".dylib"))
    check fileExists(targetDir / "debug" / "app")
    check getFileSize(targetDir / "debug" / "app") == 0

    # The stub recorded what cargo gave each build script.
    let sysdepRun = runOf(recs, "sysdep")
    let midRun = runOf(recs, "mid")
    let appRun = runOf(recs, "app")
    for run in [sysdepRun, midRun, appRun]:
      for name in ["OUT_DIR", "TARGET", "HOST", "CARGO_MANIFEST_DIR"]:
        checkpoint name
        check run.hasEnv(name)
      check run.printed.len > 0
      check run.manifestFrom in ["CARGO_MANIFEST_PATH", "CARGO_MANIFEST_DIR"]
      check run.cwd.startsWith("${project}")
    # `links` metadata reaches the immediate dependent's run only, and a
    # path member is named by its logical manifest directory.
    # The provider is an identifier, not a recorded string: in the run's
    # environment it was escaped like any other value, and expands back to
    # the identifier.
    check sysdepRun.provider == "${project}/sysdep"
    check expandRecorded(roots,
      midRun.envOf("DEP_SYSDEP___REPRO_PROVIDER")) == "${project}/sysdep"
    check not appRun.env.anyIt(it[0].startsWith("DEP_SYSDEP_"))
    check midRun.provider == ""

    # Cargo accepted the sentinels and placed them: the package's own compile
    # carries its cfg and env sentinels, and each binary its own link arg.
    let sysdepName = runName(roots, sysdepRun)
    check ("__repro_slot=\"" & sentinelValue("rustc-cfg", sysdepName) &
      "\"") in sysdepUnit.argv
    check sysdepUnit.envOf(SentinelEnvName) ==
      sentinelValue("rustc-env", sysdepName)
    let appName = runName(roots, appRun)
    let appArgs = unitsNamed(recs, "app")[0].argv.join(" ")
    let toolArgs = unitsNamed(recs, "app_tool")[0].argv.join(" ")
    check sentinelValue("rustc-link-arg-bin", appName, "app") in appArgs
    check sentinelValue("rustc-link-arg-bin", appName, "app-tool") notin appArgs
    check sentinelValue("rustc-link-arg-bin", appName, "app-tool") in toolArgs

    # Paths are recorded against the logical roots: no recording names the
    # checkout's or the scratch directory's physical path.
    var sawProject, sawTarget = false
    for path in walkFiles(recordDir / "*.json"):
      let text = readFile(path)
      checkpoint path
      check scratch notin text
      if "${project}" in text: sawProject = true
      if "${target}" in text: sawTarget = true
    check sawProject and sawTarget

    # Record mode took no sub-lease and started no measurement: every unit
    # is logged as recorded, and nothing else.
    let outcomes = readFile(wrapperLog).splitLines.filterIt(it.len > 0)
    check outcomes.len == recs.filterIt(it.kind == rkUnit).len
    for line in outcomes:
      checkpoint line
      check line.endsWith("\trecorded")

    # The record run wrote nothing into the checkout's own target directory.
    check not dirExists(ws / "target")
