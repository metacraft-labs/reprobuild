## Shared pieces of the cargo-plan cases: the workspace both cases build, a
## closed-environment process runner, a logging `RUSTC` that records every
## invocation reaching the compiler, and a loopback listener that counts
## connections.
##
## NOTHING HERE IS A MOCK. The workspaces are planned and built by real cargo
## and rustc. The logging `RUSTC` runs the real compiler with the arguments
## it was given and changes nothing; the listener is a real TCP socket that
## only counts who connects.

import std/[atomics, nativesockets, net, os, osproc, posix, sequtils,
            strtabs, strutils]

import repro_core/process_env
import repro_core/process_streams

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
  let helper = if useHelper: "  let _ = helper::id();\n" else: ""
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

proc writePlanWorkspace*(root: string; mode: ScriptMode) =
  ## A five-package workspace with build scripts, `links`, a
  ## build-dependency, a proc-macro and per-unit features:
  ##
  ##   - `sysdep`: `links = "sysdep"` and a build script;
  ##   - `mid`: depends on `sysdep` (its immediate dependent); its build
  ##     script has `helper` (feature `a`) as a build-dependency;
  ##   - `helper`: features `a` and `b`; built twice, for the build script
  ##     with `a` and for `app` with `b` (resolver 2 keeps them apart);
  ##   - `pm`: a proc-macro;
  ##   - `app`: two binaries and a build script, depending on `mid`, `pm`
  ##     and `helper` (feature `b`).
  writeFileIn(root, "Cargo.toml",
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n\n" &
    "[[bin]]\nname = \"app\"\npath = \"src/main.rs\"\n\n" &
    "[[bin]]\nname = \"app-tool\"\npath = \"src/bin/tool.rs\"\n\n" &
    "[dependencies]\nmid = { path = \"mid\" }\npm = { path = \"pm\" }\n" &
    "helper = { path = \"helper\", features = [\"b\"] }\n\n" &
    "[workspace]\nmembers = [\"sysdep\", \"mid\", \"helper\", \"pm\"]\n")
  writeFileIn(root, "build.rs", buildScript("app", mode))
  writeFileIn(root, "src/main.rs",
    "fn main() { println!(\"{} {} {}\", mid::id(), pm::answer!(), " &
    "helper::id()); }\n")
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
    "helper = { path = \"../helper\", features = [\"a\"] }\n")
  writeFileIn(root, "mid/build.rs", buildScript("mid", mode, useHelper = true))
  writeFileIn(root, "mid/src/lib.rs", "pub fn id() -> u32 { sysdep::id() }\n")
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

proc proxyEnv*(l: ref Listener): seq[(string, string)] =
  ## Every proxy variable cargo (and the HTTP library under it) reads, all
  ## naming the listener, so any network request cargo makes arrives there.
  let url = "http://" & l.address
  for name in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
               "ALL_PROXY", "all_proxy", "CARGO_HTTP_PROXY"]:
    result.add (name, url)
  result.add ("CARGO_NET_RETRY", "0")
