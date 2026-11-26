## The cargo shim: record a live set from every compiling cargo invocation
## without changing anything the caller can observe.
##
## `repro-cargo-shim` is installed as a file named `cargo` in a directory that
## comes first on `PATH`. It finds the real cargo, runs it with the caller's
## argv, standard input and environment, and returns cargo's exit status. For a
## compiling subcommand it also asks cargo for the JSON message stream and, when
## cargo exited 0, stores the stream's live set with `repro_cargo_gc`
## (docs/cargo-gc.md, "The cargo shim").
##
## THE TWO PROPERTIES THIS FILE EXISTS TO KEEP
##
## 1. What the caller sees is byte-identical to bare cargo: standard output,
##    standard error and the exit status. The shim never writes to either
##    stream on its own account; every recording problem goes to
##    `<target>/.repro-cargo-gc/shim.log`. Where it cannot keep this promise
##    (an unparseable command line, `run`, `install`, a terminal under `test`),
##    it does not interpose at all: it `exec`s the real cargo, so there is no
##    pipe, no extra process and the terminal stays.
## 2. Recording is a side effect of a SUCCESSFUL compile: a failed build's
##    partial set would count as one of the last K and weaken the protection of
##    units that are still live.
##
## HOW THE STREAM IS OBTAINED
##
## `--message-format=json-render-diagnostics` makes cargo render rustc's
## diagnostics to standard error itself, as a human build does, and leaves
## standard output with the JSON artifact messages. The shim appends it BEFORE
## a bare `--` (what follows belongs to the program being run), reads
## cargo's standard output from a pipe in raw chunks, forwards every byte that
## is not a JSON line at once (`stream.StreamSplitter`), and diverts the JSON
## lines to a file. A caller that already chose a JSON `--message-format`
## (nextest's `cargo test --no-run`, an editor) keeps its argv; it receives the
## stream byte for byte and the recorder reads a copy.
##
## `cargo test` and `cargo bench` write the test binaries' own output to the
## same standard output, and a test binary that finds a terminal there behaves
## differently from one that finds a pipe (colour, progress). So for those two
## subcommands the shim stands aside whenever standard output is a terminal.
##
## Documentation of the cargo behaviour relied on:
## https://doc.rust-lang.org/cargo/commands/cargo-build.html#output-options
## https://doc.rust-lang.org/cargo/reference/external-tools.html

import std/[json, os, strutils, times]
when defined(posix):
  import std/posix
import ./[config, record, stream, store, types]

const
  ShimActiveVar* = "REPRO_CARGO_SHIM_ACTIVE"
    ## Set for the cargo the shim starts, so a `cargo` that real cargo's build
    ## scripts or test binaries run through `PATH` passes straight through.
  RecordVar* = "REPRO_CARGO_RECORD"
    ## `0` (also `off`, `false`, `no`) turns recording off: the shim execs
    ## the real cargo.
  RealVar* = "REPRO_CARGO_REAL"
    ## The real cargo, when it is not simply the next one on `PATH`.
  InjectedFormat* = "--message-format=json-render-diagnostics"
  ShimLogName* = "shim.log"
  ShimLogMaxBytes = 1_000_000

type
  ShimMode* = enum
    smPassThrough ## exec the real cargo untouched
    smDivert      ## inject the JSON message format, divert the JSON lines
    smTee         ## the caller chose a JSON format: forward it and copy it

  ShimPlan* = object
    mode*: ShimMode
    why*: string            ## the reason for `smPassThrough`, for the log and tests
    cargoArgs*: seq[string] ## what the real cargo is given
    prefixArgs*: seq[string] ## `+toolchain` and the global options before the verb
    subcommand*: string
    targetDirFlag*: string
    manifestPath*: string
    chdir*: string          ## the `-C DIR` global option

const
  ClassA = ["build", "b", "check", "c", "clippy", "doc", "d"]
    ## Compiling verbs whose standard output carries nothing but cargo's own.
  ClassB = ["test", "t", "bench"]
    ## Compiling verbs that also run programs writing to standard output.
  GlobalWithValue = ["-Z", "--config", "-C", "--color"]
  GlobalFlags = ["-v", "-vv", "-vvv", "-q", "-qq", "--verbose", "--quiet",
                 "--offline", "--frozen", "--locked"]

proc passThrough(why: string; args: seq[string]): ShimPlan =
  ShimPlan(mode: smPassThrough, why: why, cargoArgs: args)

proc optionValue(args: seq[string]; i: int; name: string):
    tuple[matched: bool; value: string; width: int] =
  ## `--name VALUE` or `--name=VALUE` at `args[i]`.
  if args[i] == name:
    if i + 1 < args.len: (true, args[i + 1], 2) else: (true, "", 1)
  elif args[i].startsWith(name & "="):
    (true, args[i][name.len + 1 .. ^1], 1)
  else:
    (false, "", 0)

proc planShim*(args: seq[string]; stdoutIsTerminal: bool): ShimPlan =
  ## Decide what to do with the caller's argv. Pure: a command line that is
  ## not understood is `smPassThrough`, never an error.
  var i = 0
  var prefix: seq[string]
  var chdir = ""
  if args.len > 0 and args[0].startsWith("+"):
    prefix.add args[0]
    inc i
  var sub = ""
  while i < args.len:
    let a = args[i]
    if a in GlobalWithValue:
      if i + 1 >= args.len: return passThrough("global option without value", args)
      if a == "-C": chdir = args[i + 1]
      prefix.add [a, args[i + 1]]
      i += 2
    elif a.startsWith("-Z") and a.len > 2 or a.startsWith("--config=") or
        a.startsWith("--color="):
      prefix.add a
      inc i
    elif a in GlobalFlags:
      prefix.add a
      inc i
    elif a.startsWith("-"):
      # `--version`, `-h`, `--list`, `--explain`, an option this table does
      # not know: not a compiling invocation, or not one we can read.
      return passThrough("no subcommand before option " & a, args)
    else:
      sub = a
      break
  if sub.len == 0: return passThrough("no subcommand", args)
  let isA = sub in ClassA
  let isB = sub in ClassB
  if not isA and not isB:
    return passThrough("subcommand " & sub & " is not recorded", args)
  if isB and stdoutIsTerminal:
    return passThrough(sub & " with a terminal on standard output", args)
  let subAt = i
  # Arguments after the first bare `--` belong to the program being run.
  var dd = args.len
  for j in subAt + 1 ..< args.len:
    if args[j] == "--":
      dd = j
      break
  var hasJson = false
  var hasOther = false
  var target, manifest = ""
  var j = subAt + 1
  while j < dd:
    let a = args[j]
    if a == "-h" or a == "--help":
      return passThrough("help requested", args)
    if a == "--build-plan" or a == "--unit-graph":
      return passThrough(a & " prints its own JSON to standard output", args)
    let fmt = optionValue(args, j, "--message-format")
    if fmt.matched:
      if fmt.value.len == 0: return passThrough("--message-format without value", args)
      for token in fmt.value.split(','):
        if token.startsWith("json"): hasJson = true
        elif token.len > 0: hasOther = true
      j += fmt.width
      continue
    let tdir = optionValue(args, j, "--target-dir")
    if tdir.matched:
      target = tdir.value
      j += tdir.width
      continue
    let mpath = optionValue(args, j, "--manifest-path")
    if mpath.matched:
      manifest = mpath.value
      j += mpath.width
      continue
    inc j
  result = ShimPlan(prefixArgs: prefix, subcommand: sub, targetDirFlag: target,
                    manifestPath: manifest, chdir: chdir)
  if hasJson:
    result.mode = smTee
    result.cargoArgs = args
  elif hasOther:
    return passThrough("a non-JSON --message-format was chosen", args)
  else:
    result.mode = smDivert
    result.cargoArgs = args[0 ..< dd] & @[InjectedFormat] & args[dd .. ^1]

proc recordingDisabled*(value: string): bool =
  value.toLowerAscii in ["0", "off", "false", "no"]

proc targetFromEnvironment*(chdir: string; flag: string;
                            env: proc (name: string): string): string =
  ## The target directory a flag or variable names, absolute. "" when neither
  ## does (the answer is then cargo's own, from `cargo metadata`).
  let base = if chdir.len > 0: absolutePath(chdir) else: getCurrentDir()
  for candidate in [flag, env("CARGO_TARGET_DIR"), env("CARGO_BUILD_TARGET_DIR")]:
    if candidate.len > 0:
      return absolutePath(candidate, base)
  ""

proc targetFromMetadata*(json: string): string =
  ## `target_directory` of `cargo metadata --format-version 1`'s output, or "".
  try:
    let node = parseJson(json)
    if node.kind == JObject: node{"target_directory"}.getStr else: ""
  except CatchableError:
    ""

proc shimLogPath*(targetDir: string): string =
  storeDir(targetDir) / ShimLogName

proc logShim*(targetDir, message: string) =
  ## One line in `<target>/.repro-cargo-gc/shim.log`. Never raises: a log that
  ## cannot be written is not worth a changed exit status.
  try:
    createDir(storeDir(targetDir))
    let path = shimLogPath(targetDir)
    if fileExists(path) and getFileSize(path) > ShimLogMaxBytes:
      removeFile(path)
    let f = open(path, fmAppend)
    defer: close(f)
    f.writeLine now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'") & " pid " &
      $getCurrentProcessId() & ": " & message
  except CatchableError, IOError, OSError:
    discard

proc findRealCargo*(pathVar, explicit: string): string =
  ## `explicit` (`REPRO_CARGO_REAL`) when it names an executable file, else
  ## the first `cargo` on `pathVar` that is not this program: not the same
  ## file (by identity, so a symlink or hard link to the shim is skipped) and
  ## not in the directory the shim was found in. Not resolved through
  ## symlinks, so a rustup proxy still sees the name it dispatches on.
  ## "" when there is none.
  when defined(posix):
    proc executableFile(path: string): bool =
      var st: Stat
      stat(path.cstring, st) == 0 and S_ISREG(st.st_mode) and
        access(path.cstring, X_OK) == 0
    if explicit.len > 0 and executableFile(explicit): return explicit
    var self: Stat
    let haveSelf = stat(getAppFilename().cstring, self) == 0
    var shimDirs: seq[string]
    for dir in pathVar.split(':'):
      let candidate = (if dir.len == 0: "." else: dir) / "cargo"
      if not executableFile(candidate): continue
      var st: Stat
      discard stat(candidate.cstring, st)
      if haveSelf and st.st_dev == self.st_dev and st.st_ino == self.st_ino:
        shimDirs.add (try: expandFilename(parentDir(candidate)) except OSError: dir)
        continue
      let real = try: expandFilename(parentDir(candidate)) except OSError: ""
      if real.len > 0 and real in shimDirs: continue
      return candidate
  ""

when defined(posix):
  type ShimOutcome = object
    exitCode: int
    recorded: bool

  var gChild: Pid = 0

  proc underscoreExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

  proc forwardSignal(sig: cint) {.noconv.} =
    if gChild > 0: discard kill(gChild, sig)

  proc execReal(real: string; args: seq[string]) {.noreturn.} =
    ## Replace this process with the real cargo. argv[0] is the path it was
    ## found at, so a proxy that dispatches on its name sees `cargo`.
    let argv = allocCStringArray(@[real] & args)
    discard execv(real.cstring, argv)
    let err = errno
    stderr.writeLine "repro-cargo-shim: cannot execute " & real & ": " &
      $strerror(err)
    quit(if err == ENOENT: 127 else: 126)

  proc writeAll(fd: cint; data: string): bool =
    ## Write every byte or say why not (false on a closed reader or a hard
    ## error); retries interruptions and a full non-blocking descriptor.
    var done = 0
    while done < data.len:
      let n = write(fd, unsafeAddr data[done], data.len - done)
      if n >= 0:
        done += int(n)
      elif errno == EINTR:
        discard
      elif errno == EAGAIN:
        var p = TPollfd(fd: fd, events: POLLOUT)
        discard poll(addr p, 1, 1000)
      else:
        return false
    true

  proc devNull(flags: cint): cint = open("/dev/null", flags)

  proc captureMetadata(real: string; plan: ShimPlan): string =
    ## Standard output of `cargo metadata --no-deps --format-version 1`, run
    ## with the caller's toolchain and global options and silenced otherwise.
    ## "" on any failure.
    var args = plan.prefixArgs & @["metadata", "--no-deps", "--format-version", "1"]
    if plan.manifestPath.len > 0: args.add ["--manifest-path", plan.manifestPath]
    var fds: array[2, cint]
    if pipe(fds) != 0: return ""
    let argv = allocCStringArray(@[real] & args)
    let pid = fork()
    if pid < 0:
      discard close(fds[0]); discard close(fds[1])
      return ""
    if pid == 0:
      discard dup2(fds[1], 1)
      discard close(fds[0]); discard close(fds[1])
      let nullIn = devNull(O_RDONLY)
      let nullErr = devNull(O_WRONLY)
      if nullIn >= 0: discard dup2(nullIn, 0)
      if nullErr >= 0: discard dup2(nullErr, 2)
      discard execv(real.cstring, argv)
      underscoreExit(127)
    discard close(fds[1])
    var text = ""
    var buffer = newString(ReadChunkBytes)
    while true:
      let n = read(fds[0], addr buffer[0], buffer.len)
      if n > 0: text.add buffer[0 ..< int(n)]
      elif n < 0 and errno == EINTR: continue
      else: break
    discard close(fds[0])
    var status: cint
    while waitpid(pid, status, 0) < 0 and errno == EINTR: discard
    if WIFEXITED(status) and WEXITSTATUS(status) == 0: text else: ""

  proc runRecording(real: string; plan: ShimPlan; targetDir: string;
                    original: seq[string]): int =
    ## Run cargo with its standard output on a pipe, route the pipe, and
    ## record when cargo succeeded. Returns cargo's exit status.
    let streamDir =
      if dirExists(targetDir): storeDir(targetDir) else: getTempDir()
    try: createDir(streamDir) except CatchableError: discard
    let streamPath = streamDir / ("shim-" & $getCurrentProcessId() & ".stream")
    let sfd = open(streamPath.cstring, O_WRONLY or O_CREAT or O_EXCL, 0o600)
    if sfd < 0:
      # Nowhere to put the stream: do not interpose at all.
      execReal(real, original)
    var fds: array[2, cint]
    if pipe(fds) != 0:
      discard close(sfd)
      removeFile(streamPath)
      execReal(real, original)
    putEnv(ShimActiveVar, "1")
    let argv = allocCStringArray(@[real] & plan.cargoArgs)
    # Ctrl-C reaches the whole foreground group (the child too); a signal sent
    # to the shim alone is passed on.
    var act: Sigaction
    act.sa_handler = forwardSignal
    discard sigemptyset(act.sa_mask)
    act.sa_flags = SA_RESTART
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT]:
      discard sigaction(sig, act)
    let pid = fork()
    if pid < 0:
      discard close(sfd); discard close(fds[0]); discard close(fds[1])
      removeFile(streamPath)
      execReal(real, original)
    if pid == 0:
      discard dup2(fds[1], 1)
      discard close(fds[0]); discard close(fds[1]); discard close(sfd)
      discard execv(real.cstring, argv)
      underscoreExit(127)
    gChild = pid
    var ignore: Sigaction
    ignore.sa_handler = SIG_IGN
    discard sigemptyset(ignore.sa_mask)
    discard sigaction(SIGPIPE, ignore)
    discard close(fds[1])

    var splitter = initStreamSplitter()
    var stdoutOk = true
    var streamOk = true
    var streamError = ""
    let passChunk: ChunkSink = proc (chunk: string) =
      if stdoutOk and chunk.len > 0 and not writeAll(1, chunk):
        # The reader of our standard output is gone. Close the pipe: cargo
        # then sees the same broken pipe it would see writing there itself.
        stdoutOk = false
    let divertChunk: ChunkSink = proc (chunk: string) =
      if streamOk and not writeAll(sfd, chunk):
        streamOk = false
        streamError = "cannot write " & streamPath & ": " & $strerror(errno)
    var buffer = newString(ReadChunkBytes)
    var childStatus: cint = 0
    var reaped = false
    var streamOpen = true
    while streamOpen and stdoutOk:
      var p = TPollfd(fd: fds[0], events: POLLIN)
      let ready = poll(addr p, 1, 50)
      if ready < 0:
        if errno == EINTR: continue
        break
      if ready == 0:
        # No data: has cargo gone while something else still holds the pipe?
        if waitpid(pid, childStatus, WNOHANG) == pid:
          reaped = true
          # Drain what is already there and stop waiting for stragglers.
          while true:
            var q = TPollfd(fd: fds[0], events: POLLIN)
            if poll(addr q, 1, 0) <= 0: break
            let n = read(fds[0], addr buffer[0], buffer.len)
            if n <= 0: break
            if plan.mode == smTee:
              let chunk = buffer[0 ..< int(n)]
              passChunk(chunk); divertChunk(chunk)
            else:
              splitter.feed(buffer.toOpenArray(0, int(n) - 1), passChunk, divertChunk)
          break
        continue
      let n = read(fds[0], addr buffer[0], buffer.len)
      if n < 0:
        if errno == EINTR: continue
        break
      if n == 0:
        streamOpen = false
        break
      if plan.mode == smTee:
        let chunk = buffer[0 ..< int(n)]
        passChunk(chunk)
        divertChunk(chunk)
      else:
        splitter.feed(buffer.toOpenArray(0, int(n) - 1), passChunk, divertChunk)
    if plan.mode == smDivert: splitter.finish(passChunk)
    discard close(fds[0])
    while not reaped:
      let w = waitpid(pid, childStatus, 0)
      if w == pid: reaped = true
      elif w < 0 and errno != EINTR: break
    discard close(sfd)
    gChild = 0
    let code =
      if WIFEXITED(childStatus): int(WEXITSTATUS(childStatus))
      elif WIFSIGNALED(childStatus): 128 + int(WTERMSIG(childStatus))
      else: 1
    # Nothing below may change what the caller has seen or the status.
    try:
      if code == 0 and stdoutOk and streamOk:
        let resolved = resolveGcConfig(proc (n: string): string = getEnv(n))
        let input = open(streamPath, fmRead)
        try:
          let report = recordLiveSetFromStream(targetDir, input, nil,
            resolved.config.keepSets)
          if report.units == 0:
            logShim(targetDir, "no unit under " & targetDir &
              " in the stream; nothing recorded (" & $report.unresolved.len &
              " paths outside the target directory)")
        finally:
          close(input)
      elif code == 0:
        logShim(targetDir, "stream not recorded: " &
          (if streamError.len > 0: streamError else: "standard output closed"))
    except CatchableError as err:
      logShim(targetDir, "recording failed: " & err.msg)
    except Exception as err:
      logShim(targetDir, "recording failed: " & err.msg)
    try: removeFile(streamPath) except CatchableError: discard
    code


proc runShim*(args: seq[string]): int =
  ## The shim's whole behaviour; returns the exit status for a recorded run
  ## and does not return for a pass-through (it execs the real cargo).
  when defined(posix):
    let real = findRealCargo(getEnv("PATH"), getEnv(RealVar))
    if real.len == 0:
      stderr.writeLine "repro-cargo-shim: cannot find the real cargo on PATH " &
        "(set " & RealVar & " to its path)"
      return 127
    if getEnv(ShimActiveVar).len > 0 or recordingDisabled(getEnv(RecordVar)):
      execReal(real, args)
    let plan = planShim(args, isatty(1) != 0)
    if plan.mode == smPassThrough:
      execReal(real, args)
    var targetDir = targetFromEnvironment(plan.chdir, plan.targetDirFlag,
      proc (n: string): string = getEnv(n))
    if targetDir.len == 0:
      targetDir = targetFromMetadata(captureMetadata(real, plan))
    if targetDir.len == 0:
      # Cargo will fail or name its own target directory; either way the
      # caller should get cargo's own behaviour.
      execReal(real, args)
    runRecording(real, plan, targetDir, args)
  else:
    stderr.writeLine "repro-cargo-shim: not supported on this platform"
    127
