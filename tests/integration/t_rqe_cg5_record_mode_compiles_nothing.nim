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
## account, and every invocation that reached it must have the shape of a
## probe (judged here, independently of the wrapper's own classifier). The
## wrapper is given an enclosing lease and the `profiles` measurement, and
## `RUNQUOTA_SOCKET` names a socket this case listens on: in record mode no
## connection may arrive (the listener is first shown to count one), and
## every unit is logged as recorded and nothing else. No `.rlib`, `.rmeta`,
## library or executable under the target directory may hold a byte, the
## stubs excepted.
##
## Two more cases run the same workspace with lines the classifier must not
## take for probes: `--print=native-static-libs` added to every unit through
## `RUSTFLAGS` (a unit carrying `--print` must still be recorded), and an
## `@path` argument file in `RUSTFLAGS` (expanded before the line is
## classified, and recorded expanded).
##
## What this case does not cover, and why: the record run as a monitored
## graph-production edge (no network connection, edge-private cargo home,
## the plan as its one output) is the next piece of work, which wraps this
## mode in that edge; the network half of "compiles nothing" is asserted
## there, where the monitor's evidence exists.
##
## Falsifying mutations (each applied, observed to fail, reverted):
## letting the wrapper run rustc for a build-script unit (the first case);
## passing a line that carries `--print` through as a probe (the second);
## recording the line without expanding `@path` (the third).
##
## NO MOCKS: real cargo and rustc, the real wrapper and stub. The logging
## `RUSTC` shim is an observer in front of the real compiler (it runs it with
## the arguments it was given and changes nothing), the same instrument the
## wrapper's transparency cases use.

import std/[atomics, net, os, osproc, posix, sequtils, strutils, tempfiles,
            unittest]

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


var recordRunCount = 0
var acceptedConnections: Atomic[int]
var stopListening: Atomic[bool]

proc listenLoop(fd: cint) {.thread.} =
  ## Accept, count and close every connection to the listening socket `fd`
  ## until told to stop. Closing at once means a client that did connect
  ## fails fast instead of waiting for an answer that never comes.
  while not stopListening.load:
    var pfd = TPollfd(fd: fd, events: POLLIN)
    if poll(addr pfd, Tnfds(1), 100) > 0:
      let client = accept(SocketHandle(fd), nil, nil)
      if int(client) >= 0:
        acceptedConnections.atomicInc
        discard posix.close(cint(client))

proc isProbeShaped(args: seq[string]): bool =
  ## A rustc line that compiles nothing, judged from its shape alone: a bare
  ## version question, cargo's target-info call (source from standard input,
  ## crate `___`), or a line that names no crate at all.
  if args in [@["-vV"], @["-V"], @["--version"]]: return true
  let namesCrate = args.anyIt(it == "--crate-name" or
    it.startsWith("--crate-name="))
  if not namesCrate: return true
  "-" in args and ("___" in args or "--crate-name=___" in args)

type RecordRun = object
  wrapper, scratch, ws, targetDir, recordDir, markers: string
  rustcLog, wrapperLog: string
  roots: seq[RecordRoot]
  invocations: seq[seq[string]]
  recs: seq[RecordedInvocation]
  accepted: int

proc recordRun(scratch: string; extraEnv: openArray[(string, string)] = []):
    RecordRun =
  ## Write the workspace under `scratch` and run `cargo build` over it with
  ## the wrapper in record mode, `RUNQUOTA_SOCKET` naming a socket this
  ## process listens on.
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  result.wrapper = requireBinary(
    reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
    "reprobuild.apps.repro-rustc-wrapper")
  let cargo = findExe("cargo")
  let realRustc = findExe("rustc")
  require cargo.len > 0 and realRustc.len > 0
  result.scratch = scratch
  result.ws = scratch / "ws"
  result.targetDir = scratch / "target"
  result.recordDir = scratch / "record"
  result.markers = scratch / "markers"
  writeWorkspace(result.ws)
  let ws = result.ws

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

  result.rustcLog = scratch / "rustc.log"
  let logger = scratch / "rustc-logger"
  writeRustcLogger(logger, realRustc, result.rustcLog)
  result.wrapperLog = scratch / "wrapper.log"
  var rootLines = @["project=" & ws, "target=" & result.targetDir,
    "scratch=" & scratch]
  if dirExists("/nix/store"): rootLines.add "store=/nix/store"
  result.roots = parseRecordRoots(rootLines.join("\n"))

  # The socket a reporting wrapper would connect to, placed where RunQuota's
  # client trusts it (a private endpoint: a directory of this user's with
  # mode 0700 and a socket with mode 0600, `runquotaSocketEndpoint`), so a
  # client that tried WOULD connect, as the positive control below shows.
  inc recordRunCount
  let socketPath = runquotaSocketEndpoint("rec-mode-" &
    $getCurrentProcessId() & "-" & $recordRunCount)
  let socketDir = parentDir(socketPath)
  if fileExists(socketPath): removeFile(socketPath)
  createDir(socketDir)
  setFilePermissions(socketDir, {fpUserRead, fpUserWrite, fpUserExec})
  let listener = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
    Protocol.IPPROTO_IP)
  listener.bindUnix(socketPath)
  setFilePermissions(socketPath, {fpUserRead, fpUserWrite})
  listener.listen()
  acceptedConnections.store(0)
  stopListening.store(false)
  var thread: Thread[cint]
  createThread(thread, listenLoop, cint(listener.getFd))
  # Positive control: the listener counts a connection.
  block:
    let probe = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    probe.connectUnix(socketPath)
    for attempt in 0 ..< 50:
      if acceptedConnections.load == 1: break
      os.sleep(20)
    probe.close()
    require acceptedConnections.load == 1
    acceptedConnections.store(0)

  var env = @[("RUSTC", logger), ("RUSTC_WRAPPER", result.wrapper),
    (RecordDirEnv, result.recordDir), (RecordRootsEnv, rootLines.join("\n")),
    (RecordMetadataEnv, metadataFile),
    ("REPRO_RUSTC_WRAPPER_LOG", result.wrapperLog),
    # An enclosing lease and a measurement: the reporting path, if it were
    # taken, would connect to the socket above.
    ("RUNQUOTA_PARENT_LEASE", "4242"),
    ("RUNQUOTA_SOCKET", socketPath),
    ("RUNQUOTA_MEASUREMENT", "profiles"),
    ("CG5_MARKER_DIR", result.markers)]
  for pair in extraEnv: env.add pair
  discard run(shellCommand([cargo, "build", "--offline", "--locked",
      "--target-dir", result.targetDir], env = env))
  stopListening.store(true)
  joinThread(thread)
  listener.close()
  removeFile(socketPath)
  result.accepted = acceptedConnections.load

  for line in readFile(result.rustcLog).splitLines:
    if line.len > 0:
      result.invocations.add line.split(ArgSeparator).filterIt(it.len > 0)
  result.recs = readRecordings(result.recordDir)

proc checkNothingCompiled(r: RecordRun) =
  ## The properties every record run must have: only probe-shaped lines
  ## reached rustc, no build script ran, no compile output holds a byte (the
  ## stubs excepted), nobody connected to RunQuota, every unit was logged as
  ## recorded, and no recording names a physical path of the scratch tree or
  ## a variable of the record run itself.
  checkpoint "rustc invocations: " & $r.invocations.len
  check r.invocations.len > 0
  for args in r.invocations:
    if not isProbeShaped(args):
      checkpoint "a line that is not a probe reached rustc: " & args.join(" ")
      check false
  check not dirExists(r.markers)

  let wrapperSize = getFileSize(r.wrapper)
  var looked = 0
  for path in walkDirRec(r.targetDir):
    let name = extractFilename(path)
    let isOutput = name.endsWith(".rlib") or name.endsWith(".rmeta") or
      name.endsWith(".so") or name.endsWith(".dylib") or
      name.endsWith(".a") or fpUserExec in getFilePermissions(path)
    if not isOutput: continue
    inc looked
    checkpoint path
    if name.startsWith("build_script_") or name.startsWith("build-script-"):
      check getFileSize(path) == wrapperSize
    else:
      check getFileSize(path) == 0
  check looked > 0

  check r.accepted == 0
  let units = r.recs.filterIt(it.kind == rkUnit)
  let outcomes = readFile(r.wrapperLog).splitLines.filterIt(it.len > 0)
  check outcomes.len == units.len
  for line in outcomes:
    checkpoint line
    check line.endsWith("\trecorded")

  for path in walkFiles(r.recordDir / "*.json"):
    let text = readFile(path)
    checkpoint path
    check r.scratch notin text
  for rec in r.recs:
    for (name, _) in rec.env:
      check not name.startsWith("RUNQUOTA_")
      check name notin [RecordDirEnv, RecordRootsEnv, RecordMetadataEnv]

  # The record run wrote nothing into the checkout's own target directory.
  check not dirExists(r.ws / "target")

suite "the wrapper's record mode":

  test "test_rqe_cg5_record_mode_compiles_nothing: cargo completes a build " &
      "of a workspace with build scripts and a proc-macro, and nothing but " &
      "probes reaches rustc":
    let scratch = createTempDir("record-mode-", "")
    defer: removeDir(scratch)
    let r = recordRun(scratch)
    checkNothingCompiled(r)

    # Every unit was recorded, the build-script compiles as such, and each
    # build script's run was recorded in its place.
    let recs = r.recs
    let roots = r.roots
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
    let wrapperSize = getFileSize(r.wrapper)
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
    check fileExists(r.targetDir / "debug" / "app")
    check getFileSize(r.targetDir / "debug" / "app") == 0

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

    # Paths are recorded against the logical roots.
    var sawProject, sawTarget = false
    for path in walkFiles(r.recordDir / "*.json"):
      let text = readFile(path)
      if "${project}" in text: sawProject = true
      if "${target}" in text: sawTarget = true
    check sawProject and sawTarget

  test "test_rqe_cg5_record_mode_records_a_unit_carrying_print: " &
      "--print=native-static-libs on every unit does not make a unit a probe":
    let scratch = createTempDir("record-mode-print-", "")
    defer: removeDir(scratch)
    let r = recordRun(scratch,
      [("RUSTFLAGS", "--print=native-static-libs")])
    checkNothingCompiled(r)
    # The flag reached the units, and every unit was still recorded.
    let units = r.recs.filterIt(it.kind == rkUnit)
    check units.len == 9
    for unit in units:
      checkpoint unit.argv.join(" ")
      check "--print=native-static-libs" in unit.argv

  test "test_rqe_cg5_record_mode_expands_argument_files: an @path argument " &
      "is expanded before the line is classified, and recorded expanded":
    let scratch = createTempDir("record-mode-argfile-", "")
    defer: removeDir(scratch)
    writeFile(scratch / "flags", "--cfg=from_argfile\n")
    let r = recordRun(scratch, [("RUSTFLAGS", "@" & scratch / "flags")])
    checkNothingCompiled(r)
    let units = r.recs.filterIt(it.kind == rkUnit)
    check units.len == 9
    for unit in units:
      checkpoint unit.argv.join(" ")
      check "--cfg=from_argfile" in unit.argv
      check not unit.argv.anyIt(it.startsWith("@"))
