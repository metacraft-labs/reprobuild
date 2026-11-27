## Shared pieces of the cargo-plan cases: the workspace both cases build, a
## closed-environment process runner, a logging `RUSTC` that records every
## invocation reaching the compiler, and a loopback listener that counts
## connections.
##
## NOTHING HERE IS A MOCK. The workspaces are planned and built by real cargo
## and rustc. The logging `RUSTC` runs the real compiler with the arguments
## it was given and changes nothing; the listener is a real TCP socket that
## only counts who connects. The registry crates are real `.crate` files made
## by `cargo package`, put in a mirror directory by their checksum and
## fetched into a private store root by the production fetch edges
## (`repro_cargo_fetch`), so their prefixes are exactly what a build's fetch
## wave leaves. Nothing contacts the network.

import std/[atomics, nativesockets, net, os, osproc, posix, sequtils,
            strtabs, strutils, tables, times]

import repro_core/process_env
import repro_core/process_streams
import nimcrypto/sha2

import repro_cargo_fetch
import repro_cargo_edge/plan_run

const ArgSeparator* = "\x1f"

proc writeFileIn*(dir, rel, content: string) =
  createDir(parentDir(dir / rel))
  writeFile(dir / rel, content)

type ScriptMode* = enum
  smMustNotRun
    ## Each build script, if it ever runs, connects to the probe address the
    ## environment names, leaves a marker file and panics.
  smReal
    ## Each build script runs and prints directives.

proc buildScript(pkg: string; mode: ScriptMode; useHelper = false): string =
  let helper = if useHelper: "  let _ = helper::id();\n  let _ = bdep::id();\n"
               else: ""
  case mode
  of smMustNotRun:
    "fn main() {\n" & helper &
      "  if let Ok(addr) = std::env::var(\"CG5_NET_PROBE\") {\n" &
      "    let _ = std::net::TcpStream::connect(addr);\n" &
      "  }\n" &
      "  if let Ok(dir) = std::env::var(\"CG5_MARKER_DIR\") {\n" &
      "    let _ = std::fs::create_dir_all(&dir);\n" &
      "    let _ = std::fs::write(format!(\"{}/ran-" & pkg & "\", dir), \"\");\n" &
      "  }\n" &
      "  panic!(\"the build script of " & pkg & " ran\");\n}\n"
  of smReal:
    "fn main() {\n" & helper &
      "  println!(\"cargo:rerun-if-changed=build.rs\");\n" &
      "  println!(\"cargo:rustc-cfg=built_" & pkg & "\");\n" &
      "  println!(\"cargo:rustc-check-cfg=cfg(built_" & pkg & ")\");\n" &
      "  println!(\"cargo:rustc-env=BUILT_" & pkg.toUpperAscii &
      "=yes\");\n}\n"

proc writePlanWorkspace*(root: string; mode: ScriptMode; registry = false) =
  ## A five-package workspace with build scripts, `links`, a
  ## build-dependency, a proc-macro and per-unit features:
  ##
  ##   - `sysdep`: `links = "sysdep"` and a build script;
  ##   - `mid`: depends on `sysdep` (its immediate dependent); its build
  ##     script has `helper` (feature `a`) and `bdep` as build-dependencies;
  ##   - `bdep`: a library with a build script of its own, so cargo puts its
  ##     link-search paths on the dynamic-library path of `mid`'s build
  ##     script when it runs it;
  ##   - `helper`: features `a` and `b`; built twice, for the build script
  ##     with `a` and for `app` with `b` (resolver 2 keeps them apart);
  ##   - `pm`: a proc-macro;
  ##   - `app`: two binaries and a build script, depending on `mid`, `pm`
  ##     and `helper` (feature `b`), and, with `registry`, on the crates.io
  ##     crate `regbs` (`setupRegistry`).
  writeFileIn(root, "Cargo.toml",
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n\n" &
    "[[bin]]\nname = \"app\"\npath = \"src/main.rs\"\n\n" &
    "[[bin]]\nname = \"app-tool\"\npath = \"src/bin/tool.rs\"\n\n" &
    "[dependencies]\nmid = { path = \"mid\" }\npm = { path = \"pm\" }\n" &
    "helper = { path = \"helper\", features = [\"b\"] }\n" &
    (if registry: "regbs = \"0.1.0\"\n" else: "") & "\n" &
    "[workspace]\nmembers = [\"sysdep\", \"mid\", \"helper\", \"pm\", " &
    "\"bdep\"]\n")
  writeFileIn(root, "build.rs", buildScript("app", mode))
  writeFileIn(root, "src/main.rs",
    "fn main() { println!(\"{} {} {}\", mid::id(), pm::answer!(), " &
    "helper::id()); " &
    (if registry: "let _ = regbs::bs(); " else: "") & "}\n")
  writeFileIn(root, "src/bin/tool.rs", "fn main() {}\n")
  writeFileIn(root, "sysdep/Cargo.toml",
    "[package]\nname = \"sysdep\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "links = \"sysdep\"\nbuild = \"build.rs\"\n")
  writeFileIn(root, "sysdep/build.rs", buildScript("sysdep", mode))
  writeFileIn(root, "sysdep/src/lib.rs", "pub fn id() -> u32 { 1 }\n")
  writeFileIn(root, "mid/Cargo.toml",
    "[package]\nname = \"mid\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n\n[dependencies]\nsysdep = { path = \"../sysdep\" }\n" &
    "\n[build-dependencies]\n" &
    "helper = { path = \"../helper\", features = [\"a\"] }\n" &
    "bdep = { path = \"../bdep\" }\n")
  writeFileIn(root, "mid/build.rs", buildScript("mid", mode, useHelper = true))
  writeFileIn(root, "mid/src/lib.rs", "pub fn id() -> u32 { sysdep::id() }\n")
  writeFileIn(root, "bdep/Cargo.toml",
    "[package]\nname = \"bdep\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n")
  writeFileIn(root, "bdep/build.rs", buildScript("bdep", mode))
  writeFileIn(root, "bdep/src/lib.rs", "pub fn id() -> u32 { 3 }\n")
  writeFileIn(root, "helper/Cargo.toml",
    "[package]\nname = \"helper\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "\n[features]\na = []\nb = []\n")
  writeFileIn(root, "helper/src/lib.rs", "pub fn id() -> u32 { 2 }\n")
  writeFileIn(root, "pm/Cargo.toml",
    "[package]\nname = \"pm\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n" &
    "[lib]\nproc-macro = true\n")
  writeFileIn(root, "pm/src/lib.rs",
    "use proc_macro::TokenStream;\n#[proc_macro]\n" &
    "pub fn answer(_: TokenStream) -> TokenStream { \"42\".parse().unwrap() }\n")

type ClosedRun* = object
  code*: int
  output*: string

proc runClosed*(argv: openArray[string]; cwd: string;
                env: openArray[(string, string)]): ClosedRun =
  ## Run `argv` in `cwd` with exactly `env` as its environment (nothing
  ## inherited), standard error merged into the output.
  var table = newEnvTable()
  for (name, value) in env: table[name] = value
  let p = startProcess(argv[0], workingDir = cwd, args = argv[1 .. ^1],
    env = table, options = {poStdErrToStdOut})
  let outStream = p.outputStream
  result.output = drainStream(outStream)
  result.code = p.waitForExit()
  p.close()

proc writeRustcLogger*(path, realRustc, log: string) =
  ## `RUSTC` for cargo: append every invocation's arguments, joined by a unit
  ## separator, to `log`, then run the real compiler unchanged.
  writeFile(path, "#!/bin/sh\nline=\nfor a in \"$@\"; do line=\"$line$a" &
    ArgSeparator & "\"; done\nprintf '%s\\n' \"$line\" >> " &
    quoteShell(log) & "\nexec " & quoteShell(realRustc) & " \"$@\"\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc readArgLog*(log: string): seq[seq[string]] =
  if not fileExists(log): return
  for line in readFile(log).splitLines:
    if line.len > 0:
      result.add line.split(ArgSeparator).filterIt(it.len > 0)

proc isProbeShaped*(args: seq[string]): bool =
  ## A rustc line that compiles nothing, judged from its shape alone: a bare
  ## version question, cargo's target-info call (source from standard input,
  ## crate `___`), or a line that names no crate at all.
  if args in [@["-vV"], @["-V"], @["--version"]]: return true
  let namesCrate = args.anyIt(it == "--crate-name" or
    it.startsWith("--crate-name="))
  if not namesCrate: return true
  "-" in args and ("___" in args or "--crate-name=___" in args)

# ---------------------------------------------------------------------------
# A loopback listener that counts connections.

var acceptedConnections: Atomic[int]
var stopListening: Atomic[bool]

proc listenLoop(fd: cint) {.thread.} =
  while not stopListening.load:
    var pfd = TPollfd(fd: fd, events: POLLIN)
    if poll(addr pfd, Tnfds(1), 100) > 0:
      let client = accept(SocketHandle(fd), nil, nil)
      if int(client) >= 0:
        acceptedConnections.atomicInc
        discard posix.close(cint(client))

type Listener* = object
  socket: Socket
  thread: Thread[cint]
  port*: int

proc startListener*(): ref Listener =
  ## A TCP listener on 127.0.0.1 that accepts, counts and closes every
  ## connection (closing at once makes a client that connected fail fast).
  result = new Listener
  result.socket = newSocket()
  result.socket.setSockOpt(OptReuseAddr, true)
  result.socket.bindAddr(Port(0), "127.0.0.1")
  result.socket.listen()
  result.port = int(result.socket.getLocalAddr()[1])
  acceptedConnections.store(0)
  stopListening.store(false)
  createThread(result.thread, listenLoop, cint(result.socket.getFd))

proc address*(l: ref Listener): string = "127.0.0.1:" & $l.port

proc accepted*(l: ref Listener): int =
  ## The connections counted so far, after giving a just-made one time to
  ## arrive.
  var last = -1
  for _ in 0 ..< 10:
    let now = acceptedConnections.load
    if now == last: break
    last = now
    os.sleep(50)
  acceptedConnections.load

proc resetCount*(l: ref Listener) = acceptedConnections.store(0)

proc stop*(l: ref Listener) =
  stopListening.store(true)
  joinThread(l.thread)
  l.socket.close()

proc storeOnlyPath*(): string =
  ## This process's `PATH` with only its Nix store entries: the closed
  ## development environment a record run is given names its tools by store
  ## path, and a plan refuses a host path under no logical root.
  var parts: seq[string]
  for entry in getEnv("PATH").split(':'):
    if entry.startsWith("/nix/store/") and entry notin parts: parts.add entry
  parts.join(":")

proc proxyEnv*(l: ref Listener): seq[(string, string)] =
  ## Every proxy variable cargo (and the HTTP library under it) reads, all
  ## naming the listener, so any network request cargo makes arrives there.
  let url = "http://" & l.address
  for name in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
               "ALL_PROXY", "all_proxy", "CARGO_HTTP_PROXY"]:
    result.add (name, url)
  result.add ("CARGO_NET_RETRY", "0")

# ---------------------------------------------------------------------------
# Registry crates in a store root.

type RegistrySetup* = object
  store*: string          ## the store root holding the fetched prefixes
  crates*: seq[CratePrefix]  ## each crate with its prefix
  testVendor*: string
    ## A vendor directory the TEST made by copying each prefix, for the
    ## lockfile and for a real cargo build: independent of the record run's
    ## own vendor directory, whose links are what is under test.
  sourceArgs*: seq[string]
    ## `--config` values replacing crates.io with `testVendor`.

proc removeTestTree*(dir: string) =
  ## Remove a test's directory, read-only store prefixes included.
  if not dirExists(dir): return
  for path in walkDirRec(dir, yieldFilter = {pcDir}):
    setFilePermissions(path, getFilePermissions(path) + {fpUserWrite})
  setFilePermissions(dir, getFilePermissions(dir) + {fpUserWrite})
  removeDir(dir)

proc packRegistryCrates(work: string;
                        packages: seq[(string, string, seq[(string, string)])]):
    Table[string, string] =
  ## Real `.crate` files (name -> bytes) of `packages` (name, manifest
  ## tail, files), made by one `cargo package --workspace --offline` over a
  ## workspace holding them, so one may depend on another by `path` and
  ## `version` and be published with a registry dependency, as crates.io
  ## serves it. The packager's cargo home is private and empty.
  let cargo = findExe("cargo")
  doAssert cargo.len > 0, "cargo is not on PATH"
  let ws = work / "workspace"
  var members: seq[string]
  for (name, extra, files) in packages:
    members.add "\"" & name & "\""
    writeFileIn(ws / name, "Cargo.toml", "[package]\nname = \"" & name &
      "\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
      "description = \"fixture\"\nlicense = \"MIT\"\n" & extra)
    for (rel, content) in files: writeFileIn(ws / name, rel, content)
  writeFileIn(ws, "Cargo.toml", "[workspace]\nmembers = [" &
    members.join(", ") & "]\nresolver = \"2\"\n")
  var env: seq[(string, string)]
  for k, v in envPairs():
    if k notin ["CARGO_HOME", "CARGO_TARGET_DIR"]: env.add (k, v)
  env.add [("CARGO_HOME", work / "packager-cargo-home"),
    ("CARGO_TARGET_DIR", work / "packager-target")]
  let r = runClosed([cargo, "package", "--workspace", "--no-verify",
    "--allow-dirty", "--offline", "--quiet"], ws, env)
  doAssert r.code == 0, "cargo package failed:\n" & r.output
  for (name, _, _) in packages:
    result[name] = readFile(work / "packager-target" / "package" /
      (name & "-0.1.0.crate"))

proc setupRegistry*(work: string; mode: ScriptMode): RegistrySetup =
  ## Two crates.io crates in a fresh store root under `work`: `regleaf`, a
  ## plain library, and `regbs`, which has a build script and depends on
  ## `regleaf`, so the plan has a registry unit, a registry build script and
  ## a registry run.
  let packed = packRegistryCrates(work / "pack", @[
    ("regleaf", "", @[("src/lib.rs", "pub fn leaf() -> u32 { 5 }\n")]),
    ("regbs", "\n[dependencies]\nregleaf = { path = \"../regleaf\", " &
        "version = \"0.1.0\" }\n",
      @[("src/lib.rs", "pub fn bs() -> u32 { regleaf::leaf() }\n"),
        ("build.rs", buildScript("regbs", mode))])])
  let mirror = work / "mirror"
  var rows: seq[CrateRow]
  for name in ["regleaf", "regbs"]:
    let bytes = packed[name]
    let row = CrateRow(name: name, version: "0.1.0",
      cksum: toLowerAscii($sha256.digest(bytes)))
    rows.add row
    createDir(parentDir(mirror / crateObjectPath(row.cksum)))
    writeFile(mirror / crateObjectPath(row.cksum), bytes)
  result.store = work / "store"
  var cfg = defaultCrateFetchConfig(work / "fetch-state",
    @[parseMirror(mirror)])
  cfg.storeRoot = result.store
  cfg.originBase = ""
  let fetched = fetchLockedCrates(rows, cfg)
  doAssert fetched.ok, "the fixture's crates were not fetched"
  result.testVendor = work / "test-vendor"
  for c in fetched.crates:
    result.crates.add CratePrefix(name: c.row.name, version: c.row.version,
      prefix: c.prefix)
    let dir = result.testVendor / (c.row.name & "-" & c.row.version)
    copyDir(c.prefix, dir)
    for path in walkDirRec(dir, yieldFilter = {pcFile, pcDir}):
      setFilePermissions(path, getFilePermissions(path) + {fpUserWrite})
    setFilePermissions(dir, getFilePermissions(dir) + {fpUserWrite})
    writeFile(dir / ".cargo-checksum.json",
      "{\"files\":{},\"package\":\"" & c.row.cksum & "\"}")
  result.sourceArgs = @["--config",
    "source.crates-io.replace-with=\"test-vendor\"", "--config",
    "source.test-vendor.directory=\"" & result.testVendor & "\""]

proc treeSnapshot*(dir: string): seq[string] =
  ## Every entry under `dir` (and `dir`) with its kind, size, permissions and
  ## modification time.
  for path in @[dir] & toSeq(walkDirRec(dir, yieldFilter = {pcFile, pcDir,
      pcLinkToFile, pcLinkToDir})):
    let info = getFileInfo(path, followSymlink = false)
    result.add path & " " & $info.kind & " " & $info.size & " " &
      $info.permissions & " " & $info.lastWriteTime.toUnixFloat()
