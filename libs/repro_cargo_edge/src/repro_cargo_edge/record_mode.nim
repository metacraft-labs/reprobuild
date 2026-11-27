## The rustc wrapper's record mode: learn cargo's build plan without
## compiling anything.
##
## Stable cargo has no interface that prints, before building, the command
## line, working directory and environment it gives each rustc invocation and
## each build-script run. (`--unit-graph` is unstable and carries no command
## lines; `--build-plan` was removed.) So the plan is learned by letting cargo
## run its whole schedule with the wrapper in RECORD MODE, which makes every
## step a no-op that records what cargo asked for:
##
## - A COMPILE UNIT is recorded and not run. The wrapper writes an empty
##   placeholder for each output the unit's `--emit` asks for, under its
##   `--out-dir` and with its `-C extra-filename`, the names rustc itself
##   would have written, and exits 0. Cargo then finds the files it expects
##   (it hard-links final artifacts out of `deps/`) and moves on to the
##   dependents. Output naming follows rustc's documented rules:
##   https://doc.rust-lang.org/rustc/command-line-arguments.html#--emit-specifies-the-types-of-output-files-to-generate
##   and https://doc.rust-lang.org/reference/linkage.html.
## - A PROBE passes through to the real rustc: it compiles nothing, and
##   cargo needs its answers (they become the build scripts' `TARGET`,
##   `HOST` and `CARGO_CFG_*`). Only a line that is POSITIVELY a probe passes
##   (`recordLineKind`): one that names no crate (`rustc -vV`, `--version`,
##   `--print sysroot`), cargo's target-info call (crate `___`), or one that
##   reads its source from standard input (`-`). Every other line that names
##   a crate is recorded, even one carrying `--print` (a project's
##   `build.rustflags` can add `--print=native-static-libs` to every unit) or
##   lacking `--error-format=json`: passing such a line through would compile
##   it for real, record nothing and still let cargo succeed. `@path`
##   arguments (rustc reads one argument per line from the file:
##   https://doc.rust-lang.org/rustc/command-line-arguments.html#path-load-command-line-flags-from-a-path)
##   are expanded before the line is classified, and the expanded argv is
##   what is recorded.
## - A BUILD-SCRIPT COMPILE (a `bin` unit named `build_script_<stem>` whose
##   output directory is under cargo's `build/`) writes, as that unit's
##   executable, a copy of the wrapper's own image. When cargo runs it, the
##   copy sees its own name and runs as the RECORDING STUB instead
##   (`runRecordStub`): it records the argv, working directory and
##   environment cargo gave the build script, prints the SENTINEL directives
##   below, and exits 0. No package code runs.
##
## THE SENTINELS. For its package the stub prints one directive of each kind
## a build script's output can carry into a compile (Cargo Book, Build
## Scripts, "Outputs of the Build Script":
## https://doc.rust-lang.org/cargo/reference/build-scripts.html#outputs-of-the-build-script),
## each with a value that names the kind and the build-script run:
## `__repro_slot.<kind>.<run>`, where `<run>` is the name of the directory
## cargo made for that run (the parent of its `OUT_DIR`, `<package>-<hash>`).
## Cargo then places each sentinel itself, in every unit it reaches, at the
## position it takes, so the recording shows cargo's own answer to "which
## units does this kind of directive reach, and where in their command line"
## instead of a reimplementation of cargo's rules. A package with `links`
## also prints `cargo:__repro_provider=<provider>`, which cargo hands to the
## build scripts of the package's immediate dependents as
## `DEP_<LINKS>___REPRO_PROVIDER` (Build Scripts, "The `links` Manifest
## Key"). The older `cargo:` spelling is printed, not `cargo::`, because
## cargo rejects the newer one in a package whose declared `rust-version` is
## below 1.77.
##
## Cargo refuses `rustc-link-arg-bin=BIN=...` for a binary the package does
## not have, and a build script is told nothing about its package's targets.
## So the stub reads them from the output of `cargo metadata --offline
## --format-version 1`, saved to a file before the record run, and finds its
## package there by manifest path.
##
## WHAT IS RECORDED, AND WHERE. Each recorded process writes one JSON file
## (`RecordFormat`) into the directory the switch names. Every path under a
## logical root the caller DECLARES (the checkout, the store, the scratch
## target directory) is written as `${<label>}` followed by the rest of the
## path, and a literal `$` as `$$`; `expandRecorded` gives it back. Only the
## declared roots are rewritten: a path under none of them (the home
## directory, `TMPDIR`, a `PATH` entry outside the store) stays physical, and
## keeping such values out of the record run is the caller's environment
## policy. Each root is registered under both its given spelling and its
## resolved one (`withResolvedSpellings`), because cargo's paths come from
## `getcwd`, which returns the resolved directory (on macOS `/var/folders`
## is `/private/var/folders`). Rewriting FAILS CLOSED: a recording in which
## any spelling of a declared root is still present anywhere, as a substring,
## is refused and the process exits 1 (`checkNoRootLeft`).
##
## The record mode's own control variables and every `RUNQUOTA_*` variable
## are left out of the recorded environment (`recordedEnvSkipped`): they
## describe this record run (its directory, its lease and session), not the
## build, and keeping them would change the plan on every run.
##
## THE SWITCH. `REPRO_RUSTC_WRAPPER_RECORD`, set to the record directory, an
## absolute path (a build-script stub runs in its package's directory, so a
## relative one would scatter the recordings). It is separate from
## `REPRO_RUSTC_WRAPPER` (which installs the measuring wrapper), and in
## record mode the wrapper never connects to RunQuota, takes no sub-lease and
## starts no measurement: there is no compile to measure. The directory
## should be empty when the record run starts; the wrapper cannot see where
## a run starts (each process is on its own), so that is the caller's check.
## Record mode is refused on Windows until drive-letter paths are rewritten
## against the roots.
##
## NOT MODELLED (yet). With no `--target`, placeholder names follow the
## system the wrapper was built for, not rustc's host. The `.pdb`, `.dll.lib`
## and `.dSYM` side outputs, and emscripten and UEFI output names, are not
## written. A build-script compile is recognised by cargo's
## `build/<package>-<hash>/` layout of the target directory.
##
## This module holds the pure parts (output naming, path rewriting, the
## sentinel lines) and the two record-mode entry points the wrapper calls.

import std/[algorithm, json, os, strutils, times]

const
  RecordDirEnv* = "REPRO_RUSTC_WRAPPER_RECORD"
    ## The record-mode switch: the directory to write recordings into. Unset
    ## or empty means the wrapper is not in record mode.
  RecordRootsEnv* = "REPRO_RUSTC_WRAPPER_RECORD_ROOTS"
    ## The logical roots, one `<label>=<absolute path>` per line. A path
    ## under one of them is recorded against it (the longest match wins).
  RecordMetadataEnv* = "REPRO_RUSTC_WRAPPER_RECORD_METADATA"
    ## The file holding `cargo metadata --offline --format-version 1`'s
    ## output for the workspace, read by the recording stub.
  RecordFormat* = "repro-rustc-record-v1"
  SentinelPrefix* = "__repro_slot"
    ## Every sentinel value begins `__repro_slot.`; nothing else in a real
    ## command line does.
  SentinelCfgKey* = "__repro_slot"
    ## The cfg key of the `rustc-cfg` and `rustc-check-cfg` sentinels.
  SentinelEnvName* = "__REPRO_SLOT_RUSTC_ENV"
    ## The variable the `rustc-env` sentinel sets.
  ProviderMetadataKey* = "__repro_provider"
    ## The `links` metadata key that names the providing package.
  StubNamePrefixes = ["build-script-", "build_script_"]
    ## How a build-script executable is named: cargo's uplifted
    ## `build-script-<stem>` and rustc's `build_script_<stem>-<hash>`.

type
  RecordRoot* = object
    label*: string
    path*: string   ## Absolute physical path, without a trailing separator.
    resolved*: bool
      ## An extra spelling added by `withResolvedSpellings` (the root's
      ## resolved path); `expandRecorded` expands to the given spelling.

  RecordLineKind* = enum
    rlProbe   ## Passes through to the real rustc.
    rlUnit    ## Recorded, not run.

  RecordKind* = enum
    rkUnit = "unit"                      ## A rustc compile, not run.
    rkBuildScriptRun = "build-script-run"  ## The stub, run by cargo.

  RecordedInvocation* = object
    ## One recording, as `readRecordings` returns it. Strings are as recorded:
    ## paths under a logical root carry the `${label}` token.
    kind*: RecordKind
    argv*: seq[string]
      ## For a unit, the command cargo gave the wrapper: the rustc path and
      ## rustc's arguments. For a run, the build script's own argv.
    cwd*: string
    env*: seq[(string, string)]   ## Sorted by name.
    placeholders*: seq[string]
      ## A unit's outputs, as written: empty files, or the stub.
    buildScriptCompile*: bool
      ## A unit that compiles a build script (its executable is the stub).
    manifest*: string
      ## A run: the manifest it was matched by, and which variable named it
      ## (`CARGO_MANIFEST_PATH` when cargo sets it, else
      ## `CARGO_MANIFEST_DIR` joined with `Cargo.toml`).
    manifestFrom*: string
    provider*: string
      ## A run of a package with `links`: the provider's identifier, kept
      ## verbatim (it is not a recorded string, so it is not escaped): a
      ## registry crate's `<name>@<version>`, a path member's manifest
      ## directory as `${label}/<relative path>`. Where cargo passes it on
      ## (a dependent's `DEP_<LINKS>___REPRO_PROVIDER`), the recorded value
      ## is escaped like any other and `expandRecorded` gives it back.
    printed*: seq[string]  ## A run: the directive lines the stub printed.

  RecordModeError* = object of CatchableError

  UnitOutputs* = object
    ## The files a rustc command line asks rustc to write.
    files*: seq[string]
    executable*: string
      ## The `link` output of a binary unit ("" for any other).
    buildScript*: bool

  PackageTargets* = object
    ## What the stub needs to know about its package from `cargo metadata`.
    name*, version*: string
    isPathPackage*: bool   ## `source` is null: a path member.
    bins*: seq[string]
    hasTests*, hasExamples*, hasBenches*, hasCdylib*: bool

# ---------------------------------------------------------------------------
# Logical roots.

proc parseRecordRoots*(text: string): seq[RecordRoot] =
  ## `<label>=<path>` lines. Raises on a malformed line: a recording made with
  ## a root silently dropped would name physical paths.
  for raw in text.splitLines:
    let line = raw.strip()
    if line.len == 0: continue
    let eq = line.find('=')
    if eq <= 0:
      raise newException(RecordModeError, "malformed record root: " & line)
    let label = line[0 ..< eq]
    for ch in label:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
        raise newException(RecordModeError,
          "a record root label may hold only letters, digits, '_' and '-': " &
          label)
    var path = line[eq + 1 .. ^1]
    while path.len > 1 and path.endsWith("/"): path.setLen(path.len - 1)
    if not path.isAbsolute:
      raise newException(RecordModeError,
        "a record root must be an absolute path: " & line)
    result.add RecordRoot(label: label, path: path)
  # Longest first, so a root nested in another wins.
  result.sort(proc (a, b: RecordRoot): int = cmp(b.path.len, a.path.len))

const PathNameChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '+',
                       '@', '~'}

proc withResolvedSpellings*(roots: openArray[RecordRoot]): seq[RecordRoot] =
  ## `roots` plus, for each root that exists and resolves (through symbolic
  ## links) to another path, that path under the same label. Longest first.
  result = @roots
  for root in roots:
    if root.resolved or not dirExists(root.path): continue
    var real = ""
    try:
      real = expandFilename(root.path)
    except OSError:
      continue
    if real.len > 0 and real != root.path:
      result.add RecordRoot(label: root.label, path: real, resolved: true)
  result.sort(proc (a, b: RecordRoot): int = cmp(b.path.len, a.path.len))

proc rootMayStartAt(text: string; i: int): bool =
  ## Whether a root may begin at `text[i]` (a `/`): at the start, after a
  ## character that cannot continue a path (`=`, `:`, a space), after the
  ## empty authority of a URL (`file:///root`), or glued to a flag or prefix
  ## (`-L/root`, `@/root`, `-Lnative=/root`): a run of path characters that
  ## holds no `/` and starts the string or follows a non-path character. Not
  ## inside another path: in `/x/nix/store` the run before `/nix` (`x`)
  ## follows a `/`, so `/nix/store` does not match there.
  if i == 0: return true
  let prev = text[i - 1]
  if prev == '/':
    return i >= 3 and text[i - 3 ..< i] == "://"
  if prev notin PathNameChars: return true
  var j = i - 1
  while j >= 0 and text[j] in PathNameChars: dec j
  j < 0 or text[j] != '/'

proc logicalize*(roots: openArray[RecordRoot]; text: string): string =
  ## Rewrite every occurrence of a root inside `text` (an argument such as
  ## `--extern a=/r/x.rlib`, `-L/r/lib`, a `PATH` list) to `${label}`, and
  ## escape a literal `$` as `$$`. A root matches only as a whole path: where
  ## `rootMayStartAt` allows it to begin, and not when the character after it
  ## continues a file name (`/r/projectx` is not under `/r/project`).
  ## Whatever this leaves, `checkNoRootLeft` refuses.
  var i = 0
  while i < text.len:
    if text[i] == '$':
      result.add "$$"
      inc i
      continue
    var matched = false
    if text[i] == '/' and rootMayStartAt(text, i):
      for root in roots:
        let n = root.path.len
        if n > 0 and text.continuesWith(root.path, i) and
            (i + n == text.len or text[i + n] notin PathNameChars):
          result.add "${" & root.label & "}"
          i += n
          matched = true
          break
    if not matched:
      result.add text[i]
      inc i

proc expandRecorded*(roots: openArray[RecordRoot]; text: string): string =
  ## The inverse of `logicalize`, against this host's roots. Raises on a
  ## token naming a root that is not given, or on a lone `$`.
  var i = 0
  while i < text.len:
    if text[i] != '$':
      result.add text[i]
      inc i
    elif i + 1 < text.len and text[i + 1] == '$':
      result.add '$'
      i += 2
    elif i + 1 < text.len and text[i + 1] == '{':
      let close = text.find('}', i + 2)
      if close < 0:
        raise newException(RecordModeError, "unterminated root token: " & text)
      let label = text[i + 2 ..< close]
      var found = false
      for root in roots:
        if root.label == label and not root.resolved:
          result.add root.path
          found = true
          break
      if not found:
        raise newException(RecordModeError, "no root named " & label)
      i = close + 1
    else:
      raise newException(RecordModeError, "a lone '$' in a recording: " & text)

proc checkNoRootLeft*(roots: openArray[RecordRoot]; recorded: string) =
  ## Fail closed: raise when any spelling of a root is still present in a
  ## recorded string. A plain substring test, not the boundary rules of
  ## `logicalize`: it can refuse a string that only shares a root's prefix
  ## (`/r/projectx` beside the root `/r/project`), which costs a refused
  ## record run, but it cannot pass a physical root path in a form the
  ## rewriting did not anticipate. A recorded string holds no `/` that
  ## `${label}` or `$$` introduced, so the test sees only what was left.
  for root in roots:
    if root.path.len > 1 and root.path in recorded:
      raise newException(RecordModeError, "the recording would name the " &
        "physical path of root '" & root.label & "' (" & root.path &
        "), which the rewriting did not reach: " & recorded)

# ---------------------------------------------------------------------------
# Which lines pass through.

proc expandArgFiles*(args: openArray[string]): seq[string] =
  ## rustc's `@path` arguments replaced by the file's lines, one argument
  ## each (rustc reads the file the same way; a final newline ends the last
  ## line and adds no argument). `@shell:path` (an unstable form with shell
  ## quoting) is refused rather than read wrongly. Raises when a file cannot
  ## be read.
  for arg in args:
    if arg.len > 1 and arg[0] == '@':
      let path = arg[1 .. ^1]
      if path.startsWith("shell:"):
        raise newException(RecordModeError,
          "an @shell: argument file is not supported in record mode: " & arg)
      var content = ""
      try:
        content = readFile(path)
      except IOError as err:
        raise newException(RecordModeError,
          "cannot read the argument file " & path & ": " & err.msg)
      var lines = content.split('\n')
      if content.endsWith("\n"): lines.setLen(lines.len - 1)
      for line in lines:
        result.add(if line.endsWith("\r"): line[0 ..< ^1] else: line)
    else:
      result.add arg

proc recordLineKind*(args: openArray[string]): RecordLineKind =
  ## How record mode treats a rustc line (its arguments, `@path` already
  ## expanded). A probe only when it is positively one: no crate named
  ## (`-vV`, `--version`, `--print sysroot`), cargo's target-info call (crate
  ## `___`), or source from standard input (`-`). Anything else names a crate
  ## and is recorded.
  var crateName = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "-":
      return rlProbe
    if arg == "--crate-name" and i + 1 < args.len:
      crateName = args[i + 1]
      i += 2
      continue
    if arg.startsWith("--crate-name="):
      crateName = arg["--crate-name=".len .. ^1]
    inc i
  if crateName.len == 0 or crateName == "___": rlProbe else: rlUnit

# ---------------------------------------------------------------------------
# What a compile unit writes.

func flagValue(args: openArray[string]; i: int; flag: string;
               value: var string; consumed: var int): bool =
  ## `--flag value` or `--flag=value` (and, for a one-letter flag, `-Xvalue`)
  ## at `args[i]`.
  let arg = args[i]
  if arg == flag:
    if i + 1 < args.len:
      value = args[i + 1]
      consumed = 2
      return true
    return false
  if flag.startsWith("--") and arg.startsWith(flag & "="):
    value = arg[flag.len + 1 .. ^1]
    consumed = 1
    return true
  if not flag.startsWith("--") and flag.len == 2 and arg.len > 2 and
      arg.startsWith(flag):
    value = arg[2 .. ^1]
    consumed = 1
    return true
  false

type TargetFamily = enum
  tfUnix, tfApple, tfWindowsMsvc, tfWindowsGnu, tfWasm

func familyOf(triple: string): TargetFamily =
  if triple.len == 0:
    when defined(macosx): tfApple
    elif defined(windows):
      when defined(vcc): tfWindowsMsvc else: tfWindowsGnu
    else: tfUnix
  elif "wasm" in triple: tfWasm
  elif "windows" in triple:
    if "msvc" in triple: tfWindowsMsvc else: tfWindowsGnu
  elif "apple" in triple or "darwin" in triple: tfApple
  else: tfUnix

func linkOutputName(crateType, stem: string; family: TargetFamily): string =
  ## The file rustc's `link` emit writes for one crate type, from `stem`
  ## (crate name plus extra filename). The Rust Reference, "Linkage".
  case crateType
  of "bin":
    case family
    of tfWindowsMsvc, tfWindowsGnu: stem & ".exe"
    of tfWasm: stem & ".wasm"
    else: stem
  of "lib", "rlib": "lib" & stem & ".rlib"
  of "dylib", "cdylib", "proc-macro":
    case family
    of tfWindowsMsvc, tfWindowsGnu: stem & ".dll"
    of tfApple: "lib" & stem & ".dylib"
    of tfWasm: stem & ".wasm"
    of tfUnix: "lib" & stem & ".so"
  of "staticlib":
    if family == tfWindowsMsvc: stem & ".lib" else: "lib" & stem & ".a"
  else: ""

proc unitOutputsOf*(args: openArray[string]): UnitOutputs =
  ## The files a rustc command line (without the rustc path) writes, as
  ## rustc names them: under `--out-dir` (or the working directory), from the
  ## crate name and `-C extra-filename`, one per `--emit` kind, the `link`
  ## kind once per crate type; an explicit `--emit kind=PATH` or `-o PATH`
  ## names its file itself. Raises when the line names no crate.
  var crateName, outDir, extra, triple, outFile = ""
  var crateTypes: seq[string]
  var emits: seq[(string, string)]
  var isTest = false
  var i = 0
  while i < args.len:
    var value = ""
    var consumed = 0
    if flagValue(args, i, "--crate-name", value, consumed):
      crateName = value
    elif flagValue(args, i, "--crate-type", value, consumed):
      for part in value.split(','):
        if part.len > 0 and part notin crateTypes: crateTypes.add part
    elif flagValue(args, i, "--out-dir", value, consumed):
      outDir = value
    elif flagValue(args, i, "--target", value, consumed):
      triple = value
    elif flagValue(args, i, "--emit", value, consumed):
      for part in value.split(','):
        if part.len == 0: continue
        let eq = part.find('=')
        if eq < 0: emits.add (part, "")
        else: emits.add (part[0 ..< eq], part[eq + 1 .. ^1])
    elif flagValue(args, i, "-o", value, consumed):
      outFile = value
    elif flagValue(args, i, "-C", value, consumed) or
        flagValue(args, i, "--codegen", value, consumed):
      if value.startsWith("extra-filename="):
        extra = value["extra-filename=".len .. ^1]
    elif args[i] == "--test":
      isTest = true
      consumed = 1
    else:
      consumed = 1
    i += consumed
  if crateName.len == 0:
    raise newException(RecordModeError, "the rustc command names no crate")
  if isTest or crateTypes.len == 0: crateTypes = @["bin"]
  if emits.len == 0: emits = @[("link", "")]
  let family = familyOf(triple)
  let stem = crateName & extra
  let dir = if outDir.len > 0: outDir else: "."
  template add(path: string) =
    let added = path
    if added.len > 0 and added notin result.files: result.files.add added
  for (kind, explicit) in emits:
    if explicit.len > 0 and explicit != "-":
      add(explicit)
      continue
    case kind
    of "link":
      if outFile.len > 0:
        add(outFile)
        if "bin" in crateTypes: result.executable = outFile
      else:
        for crateType in crateTypes:
          let name = linkOutputName(crateType, stem, family)
          if name.len > 0:
            add(dir / name)
            if crateType == "bin": result.executable = dir / name
    of "metadata": add(dir / ("lib" & stem & ".rmeta"))
    of "dep-info": add(dir / (stem & ".d"))
    of "obj": add(dir / (stem & ".o"))
    of "asm": add(dir / (stem & ".s"))
    of "llvm-ir": add(dir / (stem & ".ll"))
    of "llvm-bc": add(dir / (stem & ".bc"))
    of "mir": add(dir / (stem & ".mir"))
    else: discard
  # A build script: cargo compiles the package's `custom-build` target, named
  # `build-script-<stem>`, as a binary crate `build_script_<stem>` into its
  # own directory under the target directory's `build/`.
  result.buildScript = result.executable.len > 0 and
    crateName.startsWith("build_script_") and
    extractFilename(parentDir(absolutePath(dir))) == "build"

# ---------------------------------------------------------------------------
# The sentinel directives.

proc sentinelValue*(kind, run: string; suffix = ""): string =
  ## `__repro_slot.<kind>.<run>[.<suffix>]`. `<run>` holds no `.` (cargo's
  ## `<package>-<hash>`), so the kind and the run are the first two fields.
  result = SentinelPrefix & "." & kind & "." & run
  if suffix.len > 0: result.add "." & suffix

proc sentinelLines*(targets: PackageTargets; outDir: string;
                    provider = ""): seq[string] =
  ## The directives the stub prints for a package whose build-script run
  ## has `outDir` as its `OUT_DIR`: one of each kind the interpreter models,
  ## each `rustc-link-arg*` variant only for a target the package has, and
  ## the provider metadata when `provider` is given (a package with `links`).
  let run = extractFilename(parentDir(outDir))
  template line(directive: string) = result.add "cargo:" & directive
  line "rustc-cfg=" & SentinelCfgKey & "=\"" &
    sentinelValue("rustc-cfg", run) & "\""
  line "rustc-check-cfg=cfg(" & SentinelCfgKey & ", values(\"" &
    sentinelValue("rustc-check-cfg", run) & "\"))"
  line "rustc-env=" & SentinelEnvName & "=" & sentinelValue("rustc-env", run)
  line "rustc-link-lib=" & sentinelValue("rustc-link-lib", run)
  # Two search paths: cargo puts one inside `OUT_DIR` on the dynamic-library
  # path of what it runs, and the other not.
  line "rustc-link-search=" & outDir /
    sentinelValue("rustc-link-search-in-out-dir", run)
  line "rustc-link-search=" & parentDir(outDir) /
    sentinelValue("rustc-link-search-outside-out-dir", run)
  line "rustc-link-arg=" & sentinelValue("rustc-link-arg", run)
  if targets.bins.len > 0:
    line "rustc-link-arg-bins=" & sentinelValue("rustc-link-arg-bins", run)
    for bin in targets.bins:
      line "rustc-link-arg-bin=" & bin & "=" &
        sentinelValue("rustc-link-arg-bin", run, bin)
  if targets.hasTests:
    line "rustc-link-arg-tests=" & sentinelValue("rustc-link-arg-tests", run)
  if targets.hasExamples:
    line "rustc-link-arg-examples=" &
      sentinelValue("rustc-link-arg-examples", run)
  if targets.hasBenches:
    line "rustc-link-arg-benches=" &
      sentinelValue("rustc-link-arg-benches", run)
  if targets.hasCdylib:
    line "rustc-link-arg-cdylib=" & sentinelValue("rustc-link-arg-cdylib", run)
  if provider.len > 0:
    line ProviderMetadataKey & "=" & provider

proc packageTargetsOf*(metadata: JsonNode; manifest: string): PackageTargets =
  ## The package whose `manifest_path` is `manifest` in `cargo metadata`'s
  ## output (format version 1:
  ## https://doc.rust-lang.org/cargo/commands/cargo-metadata.html#json-format).
  ## Raises when no package has that manifest.
  let packages = metadata{"packages"}
  if packages.isNil or packages.kind != JArray:
    raise newException(RecordModeError, "cargo metadata lists no packages")
  var found: JsonNode = nil
  for pkg in packages:
    if pkg.kind == JObject and pkg{"manifest_path"}.getStr == manifest:
      found = pkg
      break
  if found.isNil:
    # The same file under another spelling (a symlinked checkout).
    for pkg in packages:
      if pkg.kind != JObject: continue
      let other = pkg{"manifest_path"}.getStr
      if other.len > 0 and fileExists(other) and fileExists(manifest) and
          sameFile(other, manifest):
        found = pkg
        break
  if found.isNil:
    raise newException(RecordModeError,
      "cargo metadata has no package with manifest " & manifest)
  proc malformed(what: string): ref RecordModeError =
    newException(RecordModeError, "malformed cargo metadata for " &
      manifest & ": " & what)
  for key in ["name", "version"]:
    if found{key}.isNil or found{key}.kind != JString:
      raise malformed("no string \"" & key & "\"")
  result.name = found{"name"}.getStr
  result.version = found{"version"}.getStr
  result.isPathPackage = found{"source"}.isNil or
    found{"source"}.kind == JNull
  let targets = found{"targets"}
  if targets.isNil or targets.kind != JArray:
    raise malformed("no \"targets\" array")
  for target in targets:
    if target.kind != JObject:
      raise malformed("a target is not an object")
    let kinds = target{"kind"}
    if kinds.isNil or kinds.kind != JArray:
      raise malformed("a target has no \"kind\" array")
    if target{"name"}.isNil or target{"name"}.kind != JString:
      raise malformed("a target has no string \"name\"")
    for kind in kinds:
      if kind.kind != JString:
        raise malformed("a target kind is not a string")
      case kind.getStr
      of "bin": result.bins.add target{"name"}.getStr
      of "test": result.hasTests = true
      of "example": result.hasExamples = true
      of "bench": result.hasBenches = true
      of "cdylib": result.hasCdylib = true
      else: discard

# ---------------------------------------------------------------------------
# Writing and reading recordings.

proc recordRoots(): seq[RecordRoot] =
  withResolvedSpellings(parseRecordRoots(getEnv(RecordRootsEnv)))

proc recordModeOn*(): bool =
  getEnv(RecordDirEnv).len > 0

proc recordDir*(): string =
  ## The record directory. Raises unless it is absolute: a build-script stub
  ## runs in its package's directory, so a relative one would put each
  ## stub's recording somewhere else.
  result = getEnv(RecordDirEnv)
  if not result.isAbsolute:
    raise newException(RecordModeError, RecordDirEnv &
      " must name an absolute directory, not " & result)

proc recordedEnvSkipped*(name: string): bool =
  ## The variables a recording leaves out: the record mode's own switches,
  ## and RunQuota's lease, session and measurement variables. They describe
  ## the record run, not the build, and change from one run to the next.
  name in [RecordDirEnv, RecordRootsEnv, RecordMetadataEnv] or
    name.startsWith("RUNQUOTA_")

proc environmentNow(): seq[(string, string)] =
  for name, value in envPairs():
    if not recordedEnvSkipped(name):
      result.add (name, value)
  result.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))

proc writeRecording(kind: RecordKind; argv: openArray[string];
                    extra: openArray[(string, JsonNode)]) =
  ## One JSON file per recorded process, written under a temporary name and
  ## renamed into place, so a reader never sees half a recording.
  let dir = recordDir()
  let roots = recordRoots()
  var node = %*{"format": RecordFormat, "kind": $kind}
  var args = newJArray()
  for arg in argv: args.add %logicalize(roots, arg)
  node["argv"] = args
  node["cwd"] = %logicalize(roots, getCurrentDir())
  var env = newJObject()
  for (name, value) in environmentNow():
    env[name] = %logicalize(roots, value)
  node["env"] = env
  for (key, value) in extra: node[key] = value
  # Fail closed: every string written, whatever field it is in.
  proc walk(n: JsonNode) =
    case n.kind
    of JString: checkNoRootLeft(roots, n.getStr)
    of JArray:
      for item in n: walk(item)
    of JObject:
      for _, item in n: walk(item)
    else: discard
  walk(node)
  createDir(dir)
  let name = $kind & "-" & $getCurrentProcessId() & "-" &
    $(epochTime() * 1e6).int64 & ".json"
  let partial = dir / ("." & name & ".partial")
  writeFile(partial, $node & "\n")
  moveFile(partial, dir / name)

proc readRecordings*(dir: string): seq[RecordedInvocation] =
  ## Every recording in `dir`, in file-name order.
  var paths: seq[string]
  for path in walkFiles(dir / "*.json"): paths.add path
  paths.sort()
  for path in paths:
    let node = parseFile(path)
    if node{"format"}.getStr != RecordFormat:
      raise newException(RecordModeError, "not a recording: " & path)
    var rec = RecordedInvocation(
      kind: parseEnum[RecordKind](node{"kind"}.getStr),
      cwd: node{"cwd"}.getStr,
      buildScriptCompile: node{"buildScriptCompile"}.getBool,
      manifest: node{"manifest"}.getStr,
      manifestFrom: node{"manifestFrom"}.getStr,
      provider: node{"provider"}.getStr)
    for arg in node{"argv"}: rec.argv.add arg.getStr
    for name, value in node{"env"}: rec.env.add (name, value.getStr)
    if node.hasKey("placeholders"):
      for p in node["placeholders"]: rec.placeholders.add p.getStr
    if node.hasKey("printed"):
      for p in node["printed"]: rec.printed.add p.getStr
    result.add rec

proc envOf*(rec: RecordedInvocation; name: string): string =
  for (key, value) in rec.env:
    if key == name: return value

proc hasEnv*(rec: RecordedInvocation; name: string): bool =
  for (key, _) in rec.env:
    if key == name: return true

# ---------------------------------------------------------------------------
# The two entry points.

proc recordUnit*(command: openArray[string]; selfImage: string): int =
  ## Record a compile unit and write its placeholders instead of compiling
  ## it. `command` is what cargo gave the wrapper (the rustc path, then
  ## rustc's arguments); `selfImage` is the wrapper's own executable, copied
  ## as a build script's stub. Returns the exit code: 0, or 1 when the unit
  ## could not be recorded (cargo then fails the record run, which is what
  ## must happen: a plan with a unit missing is no plan).
  try:
    let outputs = unitOutputsOf(command[1 .. ^1])
    for path in outputs.files:
      createDir(parentDir(absolutePath(path)))
      if outputs.buildScript and path == outputs.executable:
        copyFileWithPermissions(selfImage, path)
      else:
        writeFile(path, "")
    let roots = recordRoots()
    var placeholders = newJArray()
    for path in outputs.files:
      placeholders.add %logicalize(roots, absolutePath(path))
    writeRecording(rkUnit, command, [
      ("placeholders", placeholders),
      ("buildScriptCompile", %outputs.buildScript)])
    0
  except CatchableError as err:
    stderr.writeLine "repro-rustc-wrapper: record mode: cannot record " &
      "the unit: " & err.msg
    1

proc isStubImage*(paths: openArray[string]): bool =
  ## Whether the running image is a build-script stub: any of `paths` (the
  ## executable's path, argv[0]) is named like a build script.
  for path in paths:
    let name = extractFilename(path)
    for prefix in StubNamePrefixes:
      if name.startsWith(prefix): return true
  false

proc runRecordStub*(argv: openArray[string]): int =
  ## The recording stub, run by cargo in place of a build script: record the
  ## argv, working directory and environment cargo gave it, print the
  ## sentinels, exit 0. Any failure exits 1, which fails the record run.
  try:
    let outDir = getEnv("OUT_DIR")
    if outDir.len == 0:
      raise newException(RecordModeError, "cargo set no OUT_DIR")
    var manifest = getEnv("CARGO_MANIFEST_PATH")
    var manifestFrom = "CARGO_MANIFEST_PATH"
    if manifest.len == 0:
      let dir = getEnv("CARGO_MANIFEST_DIR")
      if dir.len == 0:
        raise newException(RecordModeError, "cargo set no CARGO_MANIFEST_DIR")
      manifest = dir / "Cargo.toml"
      manifestFrom = "CARGO_MANIFEST_DIR"
    let metadataFile = getEnv(RecordMetadataEnv)
    if metadataFile.len == 0:
      raise newException(RecordModeError, RecordMetadataEnv & " is not set")
    let targets = packageTargetsOf(parseFile(metadataFile), manifest)
    let roots = recordRoots()
    var provider = ""
    if getEnv("CARGO_MANIFEST_LINKS").len > 0:
      if targets.isPathPackage:
        provider = logicalize(roots, parentDir(manifest))
        if not provider.startsWith("${"):
          raise newException(RecordModeError, "the path member " &
            targets.name & " provides `links` from " & parentDir(manifest) &
            ", which is under no declared root; its provider cannot be " &
            "named without a physical path")
      else:
        provider = targets.name & "@" & targets.version
    let lines = sentinelLines(targets, outDir, provider)
    var printed = newJArray()
    for line in lines: printed.add %logicalize(roots, line)
    writeRecording(rkBuildScriptRun, argv, [
      ("manifest", %logicalize(roots, manifest)),
      ("manifestFrom", %manifestFrom),
      ("provider", %provider),
      ("printed", printed)])
    for line in lines: stdout.writeLine line
    stdout.flushFile()
    0
  except CatchableError as err:
    stderr.writeLine "repro-rustc-wrapper: record mode: the build-script " &
      "stub failed: " & err.msg
    1
