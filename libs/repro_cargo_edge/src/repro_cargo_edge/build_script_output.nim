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
##       --work DIR [--root LABEL=PATH]... -- SCRIPT [ARGS...]
##
## THE TWO FORMS. Every directive is read in the `cargo::KEY=VALUE` form (Rust
## 1.77 and later) and in the older `cargo:KEY=VALUE` form, which older
## crates on crates.io print. Each line is trimmed of leading and trailing
## whitespace first, as cargo trims it, so `  cargo:rustc-cfg=x` is a
## directive. A line that then starts with neither prefix is not a
## directive; a line without `=` is an error, as it is for cargo.
##
## In the newer form `links` metadata is `cargo::metadata=KEY=VALUE`, and an
## unknown key fails the build. In the older form an unknown key is
## metadata: measured with cargo 1.94.0, `cargo:error=boom` gives the
## dependents `DEP_<LINKS>_ERROR=boom` and the build succeeds (only
## `cargo::error` fails it), `cargo:metadata=k=v` gives
## `DEP_<LINKS>_METADATA=k=v`, and an unknown `cargo:rustc-*` or
## `cargo:rerun-*` key (`cargo:rustc-link-args=`) is metadata too. This
## module reads the first two as cargo does and refuses the third: a
## misspelt directive kept as metadata is not modelled until a test shows
## its dependents' use of it. A package whose `rust-version` is below 1.77
## may not use the newer form; cargo rejects it, and so does this module.
##
## WHAT IS MODELLED (the directives that reach a compile, through the
## sentinel kinds of `record_mode`, and those that do not): `rustc-cfg`,
## `rustc-check-cfg`, `rustc-env`, `rustc-link-lib`, `rustc-link-search`
## (split into the search paths inside the run's `OUT_DIR` and those outside
## it, because cargo also puts the first on the dynamic-library path of what
## it runs), `rustc-flags` (read as the `-l` and `-L` it may carry), every
## `rustc-link-arg*` variant (`rustc-cdylib-link-arg` is the older name of
## `rustc-link-arg-cdylib`), `metadata`, `rerun-if-changed`,
## `rerun-if-env-changed`, `warning` and the newer form's `error`. Within a
## kind the values keep the order the script printed them.
##
## WHAT A RUN ENDS WITH, and how. Three outcomes, kept apart because they lead
## to different things:
##
## - SUCCESS: the directive files are written.
## - a REFUSAL: what cargo accepts and these edges do not model, so the
##   workspace is built by cargo (Mode B), which handles it. Class
##   `directive-unmodelled`: a `rustc-link-lib` with link modifiers
##   (`static:+whole-archive=`), with the `framework` kind or a kind other
##   than `static` or `dylib`; a `rustc-link-search` with a relative path; a
##   `rustc-env` of `RUSTC_BOOTSTRAP` (cargo ignores it with a warning); an
##   unknown older-form `rustc-*` or `rerun-*` key; a value longer than
##   `MaxRecordTextBytes` or more than `MaxRecordValues` values of one kind,
##   which the record cannot hold. Class `write-outside-out-dir`: the script
##   wrote into the edge's interpreted outputs (the directives directory).
##   Where cargo's handling is not certain, refusing is the safe direction:
##   Mode B is cargo itself.
## - a BUILD ERROR: what cargo itself rejects, so Mode B would fail the same
##   way. A line without `=`; an unknown key in the newer form; the newer form
##   under a `rust-version` below 1.77; `rustc-flags` with a flag other than
##   `-l` or `-L`; a `rustc-env`, `rustc-link-arg-bin` or newer-form
##   `metadata` value without its `=`; a `cargo::error`; and a script that
##   exits non-zero or is killed.
##
## THE OUTCOME IS A RECORD, NOT AN EXIT STATUS. The script shares this
## process's standard error and can exit with any status, so neither can say
## which outcome a run had. The interpreter writes it into a declared output
## of the edge, the outcome record (`OutcomeFileName` in the directives
## directory), on every outcome, and a reader decides from that record
## alone. The directives directory is emptied of the edge's own files before
## the script runs and checked to be empty when it exits: a script that wrote
## there is refused (`write-outside-out-dir`), and the record is written
## after that check, so the script cannot forge it. The exit status follows
## the record (0 for success, `RefusalExitCode` for a refusal,
## `BuildErrorExitCode` for a build error, whatever status the script itself
## exited with), and a refusal is also reported on standard error, starting
## `RefusalLinePrefix`; both are for people, never the signal.
##
## NORMALISATION. Every value is written with its paths against logical
## roots (`record_mode.logicalize`): a path inside the run's `OUT_DIR` as the
## token `${OUT_DIR}` (`OutDirRootLabel`), which a reader expands to the
## `OUT_DIR` of the run that wrote the file (the record names it), and any
## other path under a root the caller declares (`--root`: the workspace, the
## store, the Nix store, the output root) as that root's token. Each root is
## matched under its given and its resolved spelling, so an `OUT_DIR` under
## a symbolic link is found whichever spelling the script prints; the roots
## are resolved after `OUT_DIR` is created. A literal `$` is written `$$`. So
## the files name no physical path of this checkout, pass the cache's
## embedded-path scan, and can be shared. A path under no root (a host
## `/usr/lib` found by `pkg-config`) is kept as it is: it is not refused,
## and the record of the units that read it stays local. The script's
## standard output, also an output of the edge, is written normalised the
## same way, line by line, for the same reason; the raw output goes to the
## interpreter's own scratch directory (`--work`), not the script's
## `TMPDIR`.
##
## `rerun-if-*`. The run edge's key decides when the script runs again, and
## it is at least as strict as cargo's rule: its environment is closed and
## wholly keyed, so `rerun-if-env-changed` adds nothing, and the monitor
## records every file the script read. A `rerun-if-changed` path is folded
## into the recorded inputs as well (`foldRerunPaths`): after the script
## exits, this process reads the file, or every file of a directory's tree,
## following symbolic links to directories as cargo's walk does, inside the
## monitored edge, so the monitor records those reads and a listed path the
## script did not read still invalidates the run. A path that does not exist
## is probed, which the monitor records as an absent path. Paths are
## normalised (`..` resolved) before they are compared with the roots, and
## paths inside the output root, the run's `OUT_DIR` or the workspace's
## `target` directory are never folded in: they are outputs, not sources.
##
## THE RECORDS. Each normalised file is a fixed-schema binary record: the
## length-prefixed magic `DirectiveRecordMagic`, a `u16` schema version, a
## `u32` payload length and the SSZ-encoded payload (the run that wrote it,
## the kind, the values), the envelope `cargo_plan` uses. Every kind is
## written, an empty one too, so the edge's outputs are the same on every
## run. The outcome record (`OutcomeRecordMagic`) has the same envelope and
## holds the run, the outcome, the refusal class and the message.

import std/[algorithm, os, sequtils, sets, strutils, tables]

import ssz_serialization
import repro_core/codec

import ./[plan_run, record_mode]

const
  BuildScriptRunFlag* = "--build-script-run"
    ## The wrapper's argv[1] that selects the run-edge interpreter. Cargo
    ## runs the wrapper with a rustc path there, never with this flag.
  BuildScriptRunUsage* = "usage: repro-rustc-wrapper " & BuildScriptRunFlag &
    " --package NAME@VERSION --run RUN --out-dir DIR --directives DIR " &
    "--stdout FILE --tmp DIR --work DIR [--root LABEL=PATH]... " &
    "-- SCRIPT [ARGS...]\n"
  DirectiveRecordMagic* = "reprobuild.cargoBuildScriptDirectives.v1"
  DirectiveRecordSchemaVersion* = 1'u16
  DirectiveRecordExt* = ".rbsz"
  OutDirRootLabel* = "OUT_DIR"
    ## The token of a path inside the run's own `OUT_DIR`.
  OutcomeRecordMagic* = "reprobuild.cargoBuildScriptOutcome.v1"
  OutcomeRecordSchemaVersion* = 1'u16
  OutcomeFileName* = "outcome.rbsz"
    ## The outcome record's name in the directives directory.
  RefusalClassUnmodelled* = "directive-unmodelled"
  RefusalClassWriteOutside* = "write-outside-out-dir"
  RefusalLinePrefix* = "cargo build-script refusal "
    ## Followed by `(<class>): <package>: <why>`. For people only: the
    ## outcome record is the signal.
  RefusalExitCode* = 3
  BuildErrorExitCode* = 1
    ## Every build error, the script's own non-zero exit included.
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
  MaxRecordTextBytes* = 1 shl 20
  MaxRecordValues* = 1 shl 16
  ReservedOlderPrefixes = ["rustc-", "rerun-"]
    ## Older-form keys cargo keeps as metadata when it does not know them,
    ## which these edges refuse until a key is modelled.

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

  RunOutcome* = enum
    roSuccess = "success"
    roRefusal = "refusal"
    roBuildError = "build-error"

  OutcomeRecord* = object
    run*: string
    outcome*: RunOutcome
    refusalClass*: string  ## for a refusal: its class
    message*: string

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
    # Cargo trims each line before it looks for a prefix (measured with cargo
    # 1.94.0: `   cargo:rustc-cfg=x` and a tab-indented line are applied).
    let line = raw.strip()
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
      # Only the newer form fails the build; the older form's `error` is
      # metadata, `DEP_<LINKS>_ERROR` (measured with cargo 1.94.0).
      if newForm: errors.add value
      else: values["metadata"].add "error=" & value
    of "metadata":
      if newForm:
        if value.find('=') <= 0:
          buildError(line, "cargo::metadata needs KEY=VALUE")
        values["metadata"].add value
      else:
        # The older form's key `metadata` is an ordinary metadata key,
        # `DEP_<LINKS>_METADATA` (measured with cargo 1.94.0).
        values["metadata"].add "metadata=" & value
    else:
      if key in LinkArgKeys:
        values[key].add value
      elif newForm:
        buildError(line, "unknown build-script directive key " &
          key.escape() & " in the `cargo::` form")
      elif key.len == 0:
        buildError(line, "a build-script directive with an empty key")
      elif ReservedOlderPrefixes.anyIt(key.startsWith(it)):
        refusal(line, "an unknown older-form key " & key.escape() & ", " &
          "which cargo keeps as links metadata, is not modelled")
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

type OutcomeRecordSsz = object
  run, outcome, refusalClass, message: SszText

proc encodeOutcomeRecord*(r: OutcomeRecord): seq[byte] =
  ## The outcome record's bytes (see the module docstring).
  let wire = OutcomeRecordSsz(run: toText(r.run), outcome: toText($r.outcome),
    refusalClass: toText(r.refusalClass),
    message: toText(r.message[0 ..< min(r.message.len, MaxRecordTextBytes)]))
  var payload: seq[byte]
  try:
    payload = SSZ.encode(wire)
  except SszError as err:
    recordFail("could not encode an outcome record: " & err.msg)
  except IOError as err:
    recordFail("could not encode an outcome record: " & err.msg)
  result.writeString(OutcomeRecordMagic)
  result.writeU16Le(OutcomeRecordSchemaVersion)
  result.writeU32Le(uint32(payload.len))
  result.add payload

proc decodeOutcomeRecord*(bytes: openArray[byte]): OutcomeRecord =
  ## The inverse of `encodeOutcomeRecord`. Raises `DirectiveRecordError`.
  var pos = 0
  var version: uint16
  var length: uint32
  try:
    let magic = readString(bytes, pos)
    if magic != OutcomeRecordMagic:
      recordFail("not a build-script outcome record: magic " & magic.escape())
    version = readU16Le(bytes, pos)
    length = readU32Le(bytes, pos)
  except EnvelopeError as err:
    recordFail("a truncated build-script outcome record: " & err.msg)
  if version != OutcomeRecordSchemaVersion:
    recordFail("unsupported build-script outcome record version " & $version)
  if uint64(pos) + uint64(length) != uint64(bytes.len):
    recordFail("a build-script outcome record whose length does not match")
  var wire: OutcomeRecordSsz
  try:
    wire = SSZ.decode(bytes.toOpenArray(pos, bytes.high), OutcomeRecordSsz)
  except SszError as err:
    recordFail("an invalid build-script outcome record: " & err.msg)
  except IOError as err:
    recordFail("an unreadable build-script outcome record: " & err.msg)
  result.run = fromBytes(wire.run.asSeq())
  let outcome = fromBytes(wire.outcome.asSeq())
  var known = false
  for o in RunOutcome:
    if $o == outcome:
      result.outcome = o
      known = true
  if not known:
    recordFail("a build-script outcome record with outcome " &
      outcome.escape())
  result.refusalClass = fromBytes(wire.refusalClass.asSeq())
  result.message = fromBytes(wire.message.asSeq())
  if (result.outcome == roRefusal) != (result.refusalClass.len > 0):
    recordFail("a build-script outcome record whose refusal class does " &
      "not match its outcome")

proc readOutcomeRecord*(path: string): OutcomeRecord =
  decodeOutcomeRecord(toBytes(readFile(path)))

proc outputFileNames*(): seq[string] =
  ## The files the interpreter writes into the directives directory.
  for kind in DirectiveKinds: result.add directiveFileName(kind)
  result.add OutcomeFileName

# ---------------------------------------------------------------------------
# The run edge's process.

type
  BuildScriptRunOptions* = object
    package*, run*: string
    outDir*, directives*, stdoutFile*, tmpDir*, workDir*: string
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
    of "--work": result.workDir = value(i, a)
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
                    ("--tmp", result.tmpDir), ("--work", result.workDir)]:
    if v.len == 0: runFail(flag & " is required")
  for (flag, v) in [("--out-dir", result.outDir),
                    ("--directives", result.directives),
                    ("--stdout", result.stdoutFile),
                    ("--tmp", result.tmpDir), ("--work", result.workDir)]:
    if not v.isAbsolute: runFail(flag & " must be absolute: " & v)
  if result.workDir == result.tmpDir:
    runFail("--work must not be the script's --tmp")
  if result.script.len == 0: runFail("no build script to run after --")
  if not result.script[0].isAbsolute:
    runFail("the build script must be named by an absolute path: " &
      result.script[0])

proc runRoots(opts: BuildScriptRunOptions): seq[RecordRoot] =
  ## The roots values are normalised against, each under its given and its
  ## resolved spelling. Called once `OUT_DIR` exists, so its resolved
  ## spelling is one of them.
  var text = OutDirRootLabel & "=" & opts.outDir
  for r in opts.roots:
    if r.startsWith(OutDirRootLabel & "="):
      runFail("the root label " & OutDirRootLabel & " is the run's own")
    text.add "\n" & r
  try:
    withResolvedSpellings(parseRecordRoots(text))
  except RecordModeError as err:
    runFail(err.msg)

proc foldRerunPaths*(paths: openArray[string];
                     skip: openArray[string]): seq[string] =
  ## Read each ``paths`` entry (a `rerun-if-changed` path, relative to the
  ## working directory, the package's) inside the monitored edge, so that the
  ## monitor records it: every file of its tree for a directory, following
  ## symbolic links to directories (each real directory once). A path that
  ## does not exist is probed. Each path is normalised before it is compared
  ## with ``skip`` (absolute directories, each under any spelling given): a
  ## path at or under one is not folded in. Returns the files read, for
  ## tests.
  var seen = initHashSet[string]()
  let skipDirs = @skip
  proc skipped(p: string): bool =
    for dir in skipDirs:
      if isUnder(p, dir): return true
  proc readOne(file: string; into: var seq[string]) =
    try:
      discard readFile(file)
      into.add file
    except IOError:
      discard
  proc walk(dir: string; into: var seq[string]) =
    var real = dir
    try:
      real = expandFilename(dir)
    except OSError:
      return
    if real in seen or skipped(real) or skipped(dir): return
    seen.incl real
    var entries: seq[(PathComponent, string)]
    for kind, entry in walkDir(dir): entries.add (kind, entry)
    entries.sort(proc (a, b: (PathComponent, string)): int = cmp(a[1], b[1]))
    for (kind, entry) in entries:
      if skipped(entry): continue
      case kind
      of pcFile, pcLinkToFile: readOne(entry, into)
      of pcDir, pcLinkToDir: walk(entry, into)
  for path in paths:
    let abs = normalizedPath(absolutePath(path))
    if skipped(abs): continue
    if dirExists(abs): walk(abs, result)
    elif fileExists(abs): readOne(abs, result)
    else: discard fileExists(abs)   # the probe the monitor records

proc dirEmptyOrAbsent(dir: string): bool =
  if not dirExists(dir): return true
  for _ in walkDir(dir): return false
  true

proc writeOutcome(opts: BuildScriptRunOptions; outcome: RunOutcome;
                  refusalClass, message: string): int =
  ## Write the outcome record and return the exit status that follows it.
  writeBytes(opts.directives / OutcomeFileName, encodeOutcomeRecord(
    OutcomeRecord(run: opts.run, outcome: outcome,
      refusalClass: refusalClass, message: message)))
  case outcome
  of roSuccess: 0
  of roRefusal:
    stderr.writeLine RefusalLinePrefix & "(" & refusalClass & "): " &
      opts.package & ": " & message
    RefusalExitCode
  of roBuildError:
    stderr.writeLine "error: the build script of " & opts.package & ": " &
      message
    BuildErrorExitCode

proc runBuildScript*(opts: BuildScriptRunOptions): int =
  ## Run the script, interpret its output and write the normalised files
  ## and the outcome record (see the module docstring). Returns the exit
  ## status to end with, which follows the record.
  if getEnv("OUT_DIR") != opts.outDir:
    runFail("the run's OUT_DIR is " & getEnv("OUT_DIR").escape() &
      ", not its --out-dir " & opts.outDir)
  if not dirEmptyOrAbsent(opts.outDir):
    runFail("the run's OUT_DIR " & opts.outDir & " is not empty: it is an " &
      "opaque output directory, which the engine removes before each run")
  createDir(opts.outDir)
  createDir(opts.tmpDir)
  createDir(opts.workDir)
  createDir(opts.directives)
  createDir(parentDir(opts.stdoutFile))
  # The edge's own files from an earlier run go first; anything else in the
  # directory is not the edge's, and the directory must be empty when the
  # script starts, so that what is there when it exits is the script's.
  for name in outputFileNames():
    if fileExists(opts.directives / name): removeFile(opts.directives / name)
  if not dirEmptyOrAbsent(opts.directives):
    runFail("the directives directory " & opts.directives & " holds files " &
      "that are not the run edge's")
  let roots = runRoots(opts)
  let rawStdout = opts.workDir / "build-script-stdout"
  when defined(posix):
    let code = spawnWait(opts.script, rawStdout)
  else:
    runFail("the build-script run edge is supported on POSIX hosts only")
  if not dirEmptyOrAbsent(opts.directives):
    var names: seq[string]
    for _, entry in walkDir(opts.directives, relative = true): names.add entry
    names.sort()
    return writeOutcome(opts, roRefusal, RefusalClassWriteOutside,
      "the build script wrote into the run edge's interpreted outputs (" &
      names.join(", ") & ")")
  if code != 0:
    return writeOutcome(opts, roBuildError, "",
      "the build script failed (exit status " & $code & ")")
  let text = readFile(rawStdout)
  var parsed: ParsedOutput
  try:
    parsed = parseBuildScriptOutput(text, opts.outDir,
      getEnv("CARGO_PKG_RUST_VERSION"))
  except BuildScriptOutputError as err:
    if err.failure == dfRefusal:
      return writeOutcome(opts, roRefusal, err.refusalClass, err.msg)
    return writeOutcome(opts, roBuildError, "", err.msg)
  for w in parsed.values["warning"]:
    stderr.writeLine "warning: " & opts.package & ": " & w
  if parsed.errors.len > 0:
    return writeOutcome(opts, roBuildError, "", parsed.errors.join("; "))
  var normalised = initTable[string, seq[string]]()
  for kind in DirectiveKinds:
    let values = normaliseValues(roots, parsed.values[kind])
    if values.len > MaxRecordValues:
      return writeOutcome(opts, roRefusal, RefusalClassUnmodelled,
        "the build script printed " & $values.len & " directives of kind " &
        kind & ", more than the " & $MaxRecordValues & " a record holds")
    for v in values:
      if v.len > MaxRecordTextBytes:
        return writeOutcome(opts, roRefusal, RefusalClassUnmodelled,
          "the build script printed a " & kind & " value of " & $v.len &
          " bytes, more than the " & $MaxRecordTextBytes & " a record holds")
    normalised[kind] = values
  var skip: seq[string]
  for r in roots:
    if r.label in [OutDirRootLabel, "out"]: skip.add r.path
    if r.label == "project": skip.add r.path / "target"
  discard foldRerunPaths(parsed.values["rerun-if-changed"], skip)
  var lines: seq[string]
  for line in text.split('\n'): lines.add logicalize(roots, line)
  writeBytes(opts.stdoutFile, toBytes(lines.join("\n")))
  for kind in DirectiveKinds:
    writeDirectiveRecord(opts.directives / directiveFileName(kind),
      DirectiveRecord(run: opts.run, kind: kind, values: normalised[kind]))
  writeOutcome(opts, roSuccess, "", "")

proc runBuildScriptCommand*(args: openArray[string]): int =
  ## The wrapper's `--build-script-run` entry point. A failure of the
  ## interpreter itself (a bad argument, an unwritable output) leaves no
  ## outcome record and exits `BuildErrorExitCode`.
  try:
    runBuildScript(parseBuildScriptRunArgs(args))
  except BuildScriptRunError, PlanRunError, DirectiveRecordError,
      IOError, OSError:
    stderr.writeLine "repro-rustc-wrapper " & BuildScriptRunFlag & ": " &
      getCurrentExceptionMsg()
    if getCurrentException() of BuildScriptRunError:
      stderr.write BuildScriptRunUsage
    BuildErrorExitCode
