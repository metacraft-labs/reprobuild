## The run-edge half of the build-script directive interpreter.
##
## A build script tells cargo what to pass to the compiles it feeds by
## printing directives on its standard output (Cargo Book, Build Scripts,
## "Outputs of the Build Script":
## https://doc.rust-lang.org/cargo/reference/build-scripts.html#outputs-of-the-build-script).
## In a workspace Reprobuild builds from cargo's plan, the script runs inside
## its run edge (`build_script_edges`), and this module is that edge's
## process: it runs the script, parses what it printed, checks it against the
## set of directives the edges model, and writes ONE NORMALISED FILE PER
## SLOT KIND, which the units the run feeds read (through the launcher) in
## place of the script's raw output.
##
##   repro-rustc-wrapper --build-script-run --package NAME@VERSION
##       --run RUN --out-dir DIR --directives DIR --stdout FILE --tmp DIR
##       [--root LABEL=PATH]... -- SCRIPT [ARGS...]
##
## THE TWO FORMS. Every directive is read in the `cargo::KEY=VALUE` form (Rust
## 1.77 and later) and in the older `cargo:KEY=VALUE` form, which older
## crates on crates.io print. In the older form an unknown key is `links`
## metadata (`KEY=VALUE`); in the newer form metadata is
## `cargo::metadata=KEY=VALUE` and an unknown key is an error, as it is for
## cargo. A line that starts with neither is not a directive. As in cargo, a
## value's trailing whitespace is not part of it, and a line without `=` is an
## error. A package whose `rust-version` is below 1.77 may not use the newer
## form; cargo rejects it, and so does this module.
##
## WHAT IS MODELLED (the directives that reach a compile, through the
## sentinel kinds of `record_mode`, and those that do not): `rustc-cfg`, `rustc-check-cfg`, `rustc-env`,
## `rustc-link-lib`, `rustc-link-search` (split into the search paths inside
## the run's `OUT_DIR` and those outside it, because cargo also puts the first
## on the dynamic-library path of what it runs), `rustc-flags` (read as the
## `-l` and `-L` it may carry), every `rustc-link-arg*` variant
## (`rustc-cdylib-link-arg` is the older name of `rustc-link-arg-cdylib`),
## `metadata`, `rerun-if-changed`, `rerun-if-env-changed`, `warning` and
## `error`. Within a kind the values keep the order the script printed them.
##
## WHAT A RUN FAILS ON, and how. Two classes, kept apart because they lead to
## different things:
##
## - a REFUSAL (`dfRefusal`, class `directive-unmodelled`): a directive cargo
##   accepts that these edges do not model. The workspace is then built by
##   cargo (Mode B), which handles it. Refused: a `rustc-link-lib` with link
##   modifiers (`static:+whole-archive=`), with the `framework` kind or with a
##   kind other than `static` or `dylib`; a `rustc-link-search` with a
##   relative path; a `rustc-env` of `RUSTC_BOOTSTRAP`, which cargo gates on
##   its own settings; and `cargo:metadata=` in the older form, whose meaning
##   there is not documented. Where cargo's handling is not certain, refusing
##   is the safe direction: Mode B is cargo itself.
## - a BUILD ERROR (`dfBuildError`): what cargo itself rejects, so Mode B
##   would fail the same way. A line without `=`; an unknown key in the newer
##   form; the newer form under a `rust-version` below 1.77; `rustc-flags`
##   with a flag other than `-l` or `-L`; a `rustc-env`, `rustc-link-arg-bin`
##   or newer-form `metadata` value without its `=`; a `cargo::error`; and a
##   script that exits non-zero or is killed.
##
## A refusal is written to standard error as one line starting
## `RefusalLinePrefix`, and the process exits `RefusalExitCode`; a build
## error exits 1 (or the script's own exit status). Classifying a failed
## edge is the engine's, from this and from the monitor's evidence; this
## module only keeps the two apart.
##
## NORMALISATION. Every value is written with its paths against logical
## roots (`record_mode.logicalize`): a path inside the run's `OUT_DIR` as the
## token `${OUT_DIR}` (`OutDirRootLabel`), which a reader expands to the
## `OUT_DIR` of the run that wrote the file (the record names it), and any
## other path under a root the caller declares (`--root`: the workspace, the
## store, the Nix store, the output root) as that root's token. A literal `$`
## is written `$$`. So the files name no physical path of this checkout, pass
## the cache's embedded-path scan, and can be shared. A path under no root (a
## host `/usr/lib` found by `pkg-config`) is kept as it is: it is not
## refused, and the record of the units that read it stays local. The
## script's standard output, also an output of the edge, is written
## normalised the same way, line by line, for the same reason.
##
## `rerun-if-*`. The run edge's key decides when the script runs again, and
## it is at least as strict as cargo's rule: its environment is closed and
## wholly keyed, so `rerun-if-env-changed` adds nothing, and the monitor
## records every file the script read. A `rerun-if-changed` path is folded
## into the recorded inputs as well: after the script exits, this process
## reads the file (or, for a directory, every file of its tree) inside the
## monitored edge, so the monitor records those reads and a listed path the
## script did not read still invalidates the run. Paths inside the output
## root are not folded in: they are outputs of edges, not sources.
##
## THE RECORD. Each normalised file is a fixed-schema binary record: the
## length-prefixed magic `DirectiveRecordMagic`, a `u16` schema version, a
## `u32` payload length and the SSZ-encoded payload (the run that wrote it,
## the kind, the values), the envelope `cargo_plan` uses. Every kind is
## written, an empty one too, so the edge's outputs are the same on every
## run.

import std/[os, strutils, tables]

import ssz_serialization
import repro_core/codec

import ./[plan_run, record_mode]

const
  BuildScriptRunFlag* = "--build-script-run"
    ## The wrapper's argv[1] that selects the run-edge interpreter. Cargo
    ## runs the wrapper with a rustc path there, never with this flag.
  BuildScriptRunUsage* = "usage: repro-rustc-wrapper " & BuildScriptRunFlag &
    " --package NAME@VERSION --run RUN --out-dir DIR --directives DIR " &
    "--stdout FILE --tmp DIR [--root LABEL=PATH]... -- SCRIPT [ARGS...]\n"
  DirectiveRecordMagic* = "reprobuild.cargoBuildScriptDirectives.v1"
  DirectiveRecordSchemaVersion* = 1'u16
  DirectiveRecordExt* = ".rbsz"
  OutDirRootLabel* = "OUT_DIR"
    ## The token of a path inside the run's own `OUT_DIR`.
  RefusalClassUnmodelled* = "directive-unmodelled"
  RefusalLinePrefix* = "cargo build-script refusal "
    ## Followed by `(<class>): <package>: <why>`.
  RefusalExitCode* = 3
  NewFormMinRustVersion = (1, 77)
  SlotDirectiveKinds* = ["rustc-cfg", "rustc-check-cfg", "rustc-env",
    "rustc-link-lib", "rustc-link-search-in-out-dir",
    "rustc-link-search-outside-out-dir", "rustc-link-arg",
    "rustc-link-arg-bins", "rustc-link-arg-bin", "rustc-link-arg-tests",
    "rustc-link-arg-examples", "rustc-link-arg-benches",
    "rustc-link-arg-cdylib"]
    ## The kinds a unit's slot is filled from: the sentinel kinds the record
    ## stub prints (`record_mode.sentinelLines`), one file each.
  DirectiveKinds* = @SlotDirectiveKinds & @["metadata", "rerun-if-changed",
    "rerun-if-env-changed", "warning"]
    ## Every kind a run edge writes a file for. `metadata` is the `links`
    ## metadata (`KEY=VALUE`), which the runs of the package's immediate
    ## dependents receive as `DEP_<LINKS>_<KEY>`.
  LinkArgKeys = ["rustc-link-arg", "rustc-link-arg-bins",
    "rustc-link-arg-tests", "rustc-link-arg-examples",
    "rustc-link-arg-benches", "rustc-link-arg-cdylib"]
  LinkSearchKinds = ["dependency", "crate", "native", "framework", "all"]
    ## `rustc-link-search=[KIND=]PATH` (rustc's `-L [KIND=]PATH`).
  MaxRecordTextBytes = 1 shl 20
  MaxRecordValues = 1 shl 16

type
  DirectiveFailure* = enum
    dfBuildError  ## cargo fails the same way: a build error
    dfRefusal     ## cargo accepts it, these edges do not model it

  BuildScriptOutputError* = object of CatchableError
    failure*: DirectiveFailure
    refusalClass*: string  ## `directive-unmodelled` for a refusal
    line*: string          ## the line that failed, "" for none

  ParsedOutput* = object
    ## A script's directives, by kind, with their physical paths.
    values*: Table[string, seq[string]]
    errors*: seq[string]   ## `cargo::error` messages, in order

  DirectiveRecord* = object
    run*: string    ## the plan id of the run that wrote it
    kind*: string
    values*: seq[string]  ## normalised, in printed order

  DirectiveRecordError* = object of CatchableError

proc outputError(failure: DirectiveFailure; line, msg: string)
    {.noreturn.} =
  var e = newException(BuildScriptOutputError, msg)
  e.failure = failure
  e.line = line
  if failure == dfRefusal: e.refusalClass = RefusalClassUnmodelled
  raise e

proc buildError(line, msg: string) {.noreturn.} =
  outputError(dfBuildError, line, msg & ": `" & line & "`")

proc refusal(line, msg: string) {.noreturn.} =
  outputError(dfRefusal, line, msg & ": `" & line & "`")

proc rustVersionBelow(version: string; floor: (int, int)): bool =
  ## Whether a `rust-version` (`1.70`, `1.70.1`) is below `floor`; "" (none
  ## declared) is not.
  if version.len == 0: return false
  let parts = version.split('.')
  try:
    let major = parseInt(parts[0])
    let minor = if parts.len > 1: parseInt(parts[1]) else: 0
    (major, minor) < floor
  except ValueError:
    false

proc isUnder(path, dir: string): bool =
  path == dir or path.startsWith(dir & "/")

proc linkLib(line, v: string; values: var Table[string, seq[string]]) =
  ## `rustc-link-lib=[KIND=]NAME[:RENAME]`, kind `static` or `dylib` only.
  let at = v.find('=')
  if at >= 0:
    let kindPart = v[0 ..< at]
    if ':' in kindPart:
      refusal(line, "a rustc-link-lib with link modifiers is not modelled")
    if kindPart == "framework":
      refusal(line, "a rustc-link-lib of kind framework is not modelled")
    if kindPart notin ["static", "dylib"]:
      refusal(line, "a rustc-link-lib of kind " & kindPart.escape() &
        " is not modelled")
    if v[at + 1 .. ^1].len == 0:
      refusal(line, "a rustc-link-lib with no library name is not modelled")
  elif v.len == 0:
    refusal(line, "a rustc-link-lib with no library name is not modelled")
  values["rustc-link-lib"].add v

proc linkSearch(line, v: string; outDirs: openArray[RecordRoot];
                values: var Table[string, seq[string]]) =
  ## `rustc-link-search=[KIND=]PATH`, an absolute path, sorted by whether
  ## it lies inside the run's `OUT_DIR` (any spelling of it).
  var path = v
  let at = v.find('=')
  if at >= 0 and v[0 ..< at] in LinkSearchKinds: path = v[at + 1 .. ^1]
  if not path.isAbsolute:
    refusal(line, "a rustc-link-search with a relative path is not modelled")
  var inside = false
  for root in outDirs:
    if isUnder(path, root.path): inside = true
  values[if inside: "rustc-link-search-in-out-dir"
         else: "rustc-link-search-outside-out-dir"].add v

proc parseBuildScriptOutput*(text: string; outDir: string;
                             rustVersion = ""): ParsedOutput =
  ## The directives of a build script's standard output ``text``, by kind
  ## (see the module docstring). ``outDir`` is the run's `OUT_DIR`, which
  ## sorts the link-search paths; ``rustVersion`` the package's declared
  ## `rust-version` ("" for none). Raises `BuildScriptOutputError`.
  var values = initTable[string, seq[string]]()
  var errors: seq[string]
  for kind in DirectiveKinds: values[kind] = @[]
  let outDirs = withResolvedSpellings([RecordRoot(label: OutDirRootLabel,
    path: outDir)])
  for raw in text.split('\n'):
    let line = if raw.endsWith("\r"): raw[0 ..< ^1] else: raw
    var rest: string
    var newForm = false
    if line.startsWith("cargo::"):
      newForm = true
      rest = line["cargo::".len .. ^1]
    elif line.startsWith("cargo:"):
      rest = line["cargo:".len .. ^1]
    else:
      continue
    let syntax = if newForm: "cargo::" else: "cargo:"
    if newForm and rustVersionBelow(rustVersion, NewFormMinRustVersion):
      buildError(line, "the `cargo::` form needs a rust-version of 1.77 " &
        "or later, and the package declares " & rustVersion)
    let eq = rest.find('=')
    if eq < 0:
      buildError(line, "invalid build-script output, expected `" & syntax &
        "KEY=VALUE`")
    let key = rest[0 ..< eq]
    let value = rest[eq + 1 .. ^1].strip(leading = false)
    case key
    of "rustc-flags":
      let words = value.splitWhitespace()
      var i = 0
      while i < words.len:
        let w = words[i]
        var flag, v: string
        if w in ["-l", "-L"]:
          if i + 1 >= words.len:
            buildError(line, "rustc-flags " & w & " has no value")
          flag = w
          v = words[i + 1]
          i += 2
        elif w.startsWith("-l") or w.startsWith("-L"):
          flag = w[0 .. 1]
          v = w[2 .. ^1]
          inc i
        else:
          buildError(line, "only `-l` and `-L` flags are allowed in " &
            "rustc-flags, not " & w.escape())
        if flag == "-l": linkLib(line, v, values)
        else: linkSearch(line, v, outDirs, values)
    of "rustc-link-lib": linkLib(line, value, values)
    of "rustc-link-search": linkSearch(line, value, outDirs, values)
    of "rustc-cdylib-link-arg": values["rustc-link-arg-cdylib"].add value
    of "rustc-link-arg-bin":
      if value.find('=') <= 0:
        buildError(line, "rustc-link-arg-bin needs BIN=ARG")
      values["rustc-link-arg-bin"].add value
    of "rustc-cfg", "rustc-check-cfg", "warning", "rerun-if-changed",
       "rerun-if-env-changed":
      values[key].add value
    of "rustc-env":
      let at = value.find('=')
      if at <= 0:
        buildError(line, "rustc-env needs VAR=VALUE")
      if value[0 ..< at] == "RUSTC_BOOTSTRAP":
        refusal(line, "a rustc-env of RUSTC_BOOTSTRAP is not modelled")
      values["rustc-env"].add value
    of "error":
      errors.add value
    of "metadata":
      if not newForm:
        refusal(line, "`cargo:metadata=` in the older form is not modelled")
      if value.find('=') <= 0:
        buildError(line, "cargo::metadata needs KEY=VALUE")
      values["metadata"].add value
    else:
      if key in LinkArgKeys:
        values[key].add value
      elif newForm:
        buildError(line, "unknown build-script directive key " &
          key.escape() & " in the `cargo::` form")
      elif key.len == 0:
        buildError(line, "a build-script directive with an empty key")
      else:
        # The older form: an unknown key is `links` metadata.
        values["metadata"].add key & "=" & value
  ParsedOutput(values: values, errors: errors)

proc normaliseValues*(roots: openArray[RecordRoot];
                      values: openArray[string]): seq[string] =
  ## ``values`` with their paths against ``roots`` (`logicalize`): roots
  ## given with `withResolvedSpellings`, the run's `OUT_DIR` among them.
  for v in values: result.add logicalize(roots, v)

# ---------------------------------------------------------------------------
# The record.

type
  SszText = List[byte, MaxRecordTextBytes]
  DirectiveRecordSsz = object
    run, kind: SszText
    values: List[SszText, MaxRecordValues]

proc recordFail(msg: string) {.noreturn.} =
  raise newException(DirectiveRecordError, msg)

proc toText(s: string): SszText =
  if s.len > MaxRecordTextBytes:
    recordFail("a directive value exceeds " & $MaxRecordTextBytes & " bytes")
  SszText.init(toBytes(s))

proc encodeDirectiveRecord*(r: DirectiveRecord): seq[byte] =
  ## The record's bytes (see the module docstring).
  if r.kind notin DirectiveKinds:
    recordFail("not a build-script directive kind: " & r.kind.escape())
  if r.values.len > MaxRecordValues:
    recordFail("a build script printed more than " & $MaxRecordValues &
      " directives of kind " & r.kind)
  var values: seq[SszText]
  for v in r.values: values.add toText(v)
  let wire = DirectiveRecordSsz(run: toText(r.run), kind: toText(r.kind),
    values: List[SszText, MaxRecordValues].init(values))
  var payload: seq[byte]
  try:
    payload = SSZ.encode(wire)
  except SszError as err:
    recordFail("could not encode a directive record: " & err.msg)
  except IOError as err:
    recordFail("could not encode a directive record: " & err.msg)
  result.writeString(DirectiveRecordMagic)
  result.writeU16Le(DirectiveRecordSchemaVersion)
  result.writeU32Le(uint32(payload.len))
  result.add payload

proc decodeDirectiveRecord*(bytes: openArray[byte]): DirectiveRecord =
  ## The inverse of `encodeDirectiveRecord`. Raises `DirectiveRecordError` on
  ## a wrong magic, an unknown version, a length that does not match, an
  ## invalid payload or a kind that is not one of `DirectiveKinds`.
  var pos = 0
  var version: uint16
  var length: uint32
  try:
    let magic = readString(bytes, pos)
    if magic != DirectiveRecordMagic:
      recordFail("not a build-script directive record: magic " &
        magic.escape())
    version = readU16Le(bytes, pos)
    length = readU32Le(bytes, pos)
  except EnvelopeError as err:
    recordFail("a truncated build-script directive record: " & err.msg)
  if version != DirectiveRecordSchemaVersion:
    recordFail("unsupported build-script directive record version " &
      $version)
  if uint64(pos) + uint64(length) != uint64(bytes.len):
    recordFail("a build-script directive record whose length does not match")
  var wire: DirectiveRecordSsz
  try:
    wire = SSZ.decode(bytes.toOpenArray(pos, bytes.high), DirectiveRecordSsz)
  except SszError as err:
    recordFail("an invalid build-script directive record: " & err.msg)
  except IOError as err:
    recordFail("an unreadable build-script directive record: " & err.msg)
  result.run = fromBytes(wire.run.asSeq())
  result.kind = fromBytes(wire.kind.asSeq())
  for v in wire.values.asSeq(): result.values.add fromBytes(v.asSeq())
  if result.kind notin DirectiveKinds:
    recordFail("a build-script directive record of unknown kind " &
      result.kind.escape())

proc directiveFileName*(kind: string): string = kind & DirectiveRecordExt

proc writeBytes(path: string; bytes: openArray[byte]) =
  ## Write ``bytes`` to ``path`` in place. Not through a temporary sibling:
  ## inside a monitored edge that sibling would be a write outside the
  ## declared outputs, and a run that fails part-way is discarded whole by
  ## the engine, so no reader sees a partial file.
  var f = open(path, fmWrite)
  try:
    if bytes.len > 0 and
        f.writeBuffer(unsafeAddr bytes[0], bytes.len) != bytes.len:
      raise newException(IOError, "short write to " & path)
  finally:
    f.close()

proc writeDirectiveRecord*(path: string; r: DirectiveRecord) =
  writeBytes(path, encodeDirectiveRecord(r))

proc readDirectiveRecord*(path: string): DirectiveRecord =
  decodeDirectiveRecord(toBytes(readFile(path)))

# ---------------------------------------------------------------------------
# The run edge's process.

type
  BuildScriptRunOptions* = object
    package*, run*: string
    outDir*, directives*, stdoutFile*, tmpDir*: string
    roots*: seq[string]   ## `LABEL=PATH`
    script*: seq[string]  ## the script and its arguments

  BuildScriptRunError* = object of CatchableError

proc runFail(msg: string) {.noreturn.} =
  raise newException(BuildScriptRunError, msg)

proc parseBuildScriptRunArgs*(args: openArray[string]): BuildScriptRunOptions =
  ## The options after `BuildScriptRunFlag`. Raises `BuildScriptRunError`.
  var i = 0
  template value(i: var int; flag: string): string =
    if i + 1 >= args.len: runFail(flag & " needs a value")
    inc i
    args[i]
  while i < args.len:
    let a = args[i]
    case a
    of "--package": result.package = value(i, a)
    of "--run": result.run = value(i, a)
    of "--out-dir": result.outDir = value(i, a)
    of "--directives": result.directives = value(i, a)
    of "--stdout": result.stdoutFile = value(i, a)
    of "--tmp": result.tmpDir = value(i, a)
    of "--root": result.roots.add value(i, a)
    of "--":
      result.script = args[i + 1 .. ^1]
      break
    else: runFail("unknown argument " & a.escape())
    inc i
  for (flag, v) in [("--package", result.package), ("--run", result.run),
                    ("--out-dir", result.outDir),
                    ("--directives", result.directives),
                    ("--stdout", result.stdoutFile),
                    ("--tmp", result.tmpDir)]:
    if v.len == 0: runFail(flag & " is required")
  for (flag, v) in [("--out-dir", result.outDir),
                    ("--directives", result.directives),
                    ("--stdout", result.stdoutFile),
                    ("--tmp", result.tmpDir)]:
    if not v.isAbsolute: runFail(flag & " must be absolute: " & v)
  if result.script.len == 0: runFail("no build script to run after --")
  if not result.script[0].isAbsolute:
    runFail("the build script must be named by an absolute path: " &
      result.script[0])

proc runRoots(opts: BuildScriptRunOptions): seq[RecordRoot] =
  var text = OutDirRootLabel & "=" & opts.outDir
  for r in opts.roots:
    if r.startsWith(OutDirRootLabel & "="):
      runFail("the root label " & OutDirRootLabel & " is the run's own")
    text.add "\n" & r
  try:
    withResolvedSpellings(parseRecordRoots(text))
  except RecordModeError as err:
    runFail(err.msg)

proc foldRerunPath(path: string; skip: openArray[RecordRoot]) =
  ## Read ``path`` (a `rerun-if-changed` path, relative to the package
  ## directory, the working directory) inside the monitored edge, so that
  ## the monitor records it: every file of its tree for a directory. A path
  ## that does not exist is only probed, which is itself recorded. Paths
  ## under ``skip`` (the output root, `OUT_DIR`) are outputs, not sources.
  let abs = absolutePath(path)
  for root in skip:
    if isUnder(abs, root.path): return
  if dirExists(abs):
    for file in walkDirRec(abs, yieldFilter = {pcFile, pcLinkToFile},
                           relative = false):
      try:
        discard readFile(file)
      except IOError:
        discard
  elif fileExists(abs):
    try:
      discard readFile(abs)
    except IOError:
      discard

proc dirEmptyOrAbsent(dir: string): bool =
  if not dirExists(dir): return true
  for _ in walkDir(dir): return false
  true

proc runBuildScript*(opts: BuildScriptRunOptions): int =
  ## Run the script, interpret its output and write the normalised files
  ## (see the module docstring). Returns the exit status to end with.
  let who = opts.package
  if getEnv("OUT_DIR") != opts.outDir:
    runFail("the run's OUT_DIR is " & getEnv("OUT_DIR").escape() &
      ", not its --out-dir " & opts.outDir)
  if not dirEmptyOrAbsent(opts.outDir):
    runFail("the run's OUT_DIR " & opts.outDir & " is not empty: it is an " &
      "opaque output directory, which the engine removes before each run")
  let roots = runRoots(opts)
  createDir(opts.outDir)
  createDir(opts.tmpDir)
  createDir(opts.directives)
  createDir(parentDir(opts.stdoutFile))
  let rawStdout = opts.tmpDir / ".build-script-stdout"
  when defined(posix):
    let code = spawnWait(opts.script, rawStdout)
  else:
    runFail("the build-script run edge is supported on POSIX hosts only")
  if code != 0:
    stderr.writeLine "error: the build script of " & who & " failed (exit " &
      "status " & $code & ")"
    return (if code > 0: code else: 1)
  let text = readFile(rawStdout)
  var parsed: ParsedOutput
  try:
    parsed = parseBuildScriptOutput(text, opts.outDir,
      getEnv("CARGO_PKG_RUST_VERSION"))
  except BuildScriptOutputError as err:
    if err.failure == dfRefusal:
      stderr.writeLine RefusalLinePrefix & "(" & err.refusalClass & "): " &
        who & ": " & err.msg
      return RefusalExitCode
    stderr.writeLine "error: the build script of " & who & ": " & err.msg
    return 1
  for w in parsed.values["warning"]:
    stderr.writeLine "warning: " & who & ": " & w
  if parsed.errors.len > 0:
    for e in parsed.errors:
      stderr.writeLine "error: the build script of " & who & ": " & e
    return 1
  for path in parsed.values["rerun-if-changed"]:
    var skip: seq[RecordRoot]
    for r in roots:
      if r.label in [OutDirRootLabel, "out"]: skip.add r
    foldRerunPath(path, skip)
  var lines: seq[string]
  for line in text.split('\n'): lines.add logicalize(roots, line)
  writeBytes(opts.stdoutFile, toBytes(lines.join("\n")))
  for kind in DirectiveKinds:
    writeDirectiveRecord(opts.directives / directiveFileName(kind),
      DirectiveRecord(run: opts.run, kind: kind,
        values: normaliseValues(roots, parsed.values[kind])))
  0

proc runBuildScriptCommand*(args: openArray[string]): int =
  ## The wrapper's `--build-script-run` entry point.
  try:
    runBuildScript(parseBuildScriptRunArgs(args))
  except BuildScriptRunError, PlanRunError, DirectiveRecordError,
      IOError, OSError:
    stderr.writeLine "repro-rustc-wrapper " & BuildScriptRunFlag & ": " &
      getCurrentExceptionMsg()
    if getCurrentException() of BuildScriptRunError:
      stderr.write BuildScriptRunUsage
    1
