## Foreign dev-environment capture — the one mechanism under NF-4's two
## activation helpers (`useFlakeDevShell`, `useEnvrc`).
##
## §2b of `Nix-Flake-Coexistence.md` leaves the degenerate end's expression
## open between "run arbitrary commands that contribute to the environment"
## and "build the flake and put its directories on the search paths". This
## module implements the first, because that is what the workspace's own
## `direnv` does today: `nix print-dev-env` emits a bash script and the shell
## absorbs whatever sourcing it exports. Absorbing the exports keeps a flake's
## `shellHook`, its non-path variables, and its ordering — none of which
## survive "put `bin` and `lib` on a search path".
##
## ## Why the contribution is a DIFF and not the captured environment
##
## Sourcing `print-dev-env`'s script yields a whole environment, most of which
## is the environment we started from. Recording all of it would bake the
## invoking shell's `HOME`, `TMPDIR` and `PATH` into a cached artifact that is
## then applied in a different shell — the artifact would carry host state that
## has nothing to do with the flake. So the contribution is the DIFFERENCE
## between the environment before and after sourcing, expressed in the dev-env
## DSL's own vocabulary (`setEnv` / `prependPath` / `appendPath` / `unsetEnv`).
##
## ## How a prepend is told apart from a set, without a sentinel
##
## `nix print-dev-env` writes `PATH='<store entries>'` near the top and
## `PATH="$PATH${nix_saved_PATH:+:$nix_saved_PATH}"` at the bottom, so the
## invoking `PATH` survives VERBATIM as a contiguous run inside the result.
## That is the whole detection rule: when the captured value still contains the
## baseline value as a prefix / suffix / infix, the part outside it is a
## prepend / append and the baseline part is discarded. The baseline value IS
## the sentinel, which is better than injecting one: the capture runs with a
## real, usable `PATH`, so `nix` (and an `.envrc`'s `use flake`) can actually
## run inside it. An injected sentinel `PATH` would break the very command
## whose environment we are trying to capture.
##
## A coincidental containment is not a practical concern: the baseline value of
## a path-like variable is a long absolute-path list, and a variable whose
## baseline does not survive is reported as a plain `setEnv`, which is the
## conservative answer.

import std/[algorithm, os, osproc, streams, strtabs, strutils, tables]

import repro_core/ambient_execution
import repro_core/paths

type
  ForeignEnvOpKind* = enum
    ## The dev-env DSL verbs a captured contribution can lower to. One-for-one
    ## with `setEnv` / `unsetEnv` / `prependPath` / `appendPath` in
    ## `repro_project_dsl/runtime_core.nim`, so applying a captured op is a
    ## `case` over this enum and nothing else.
    feoSet
    feoUnset
    feoPrepend
    feoAppend

  ForeignEnvOp* = object
    kind*: ForeignEnvOpKind
    name*: string
    value*: string
      ## Empty for `feoUnset`.

  ForeignEnvCaptureError* = object of CatchableError
    ## Raised when the foreign command, or the shell that sources its output,
    ## fails. NF-4 refuses rather than contributing a partial environment: a
    ## dev shell built from half a flake looks exactly like a working one,
    ## which is the failure mode §5 of the design doc exists to stop.

const
  ForeignEnvIgnoredNames* = [
    # Shell bookkeeping the capture shell rewrites on its own. None of these
    # is a contribution of the foreign environment, and every one of them
    # differs between baseline and capture on EVERY run, so leaving them in
    # would make the artifact churn without anything having changed.
    "_", "PWD", "OLDPWD", "SHLVL", "BASHOPTS", "BASH_EXECUTION_STRING",
    "BASH_ENV", "PS1", "PS2", "PS4", "LINENO", "RANDOM", "SECONDS"
  ]
    ## Names never recorded as a contribution, whatever they hold.

proc isIgnoredForeignEnvName*(name: string): bool =
  ## True when `name` is shell bookkeeping rather than a contribution.
  for ignored in ForeignEnvIgnoredNames:
    if name == ignored:
      return true
  false

proc parseNulEnvDump*(blob: string): seq[(string, string)] =
  ## Parse the `NAME=VALUE\0` stream the capture shell prints. NUL-delimited
  ## rather than newline-delimited because a `shellHook` may legitimately
  ## export a multi-line value, and a newline-delimited dump would silently
  ## truncate it (and then silently disagree with `nix develop`).
  for chunk in blob.split('\0'):
    if chunk.len == 0:
      continue
    let eq = chunk.find('=')
    if eq <= 0:
      # No name, or an empty name: not something the shell can have exported.
      continue
    result.add((chunk[0 ..< eq], chunk[eq + 1 .. ^1]))

proc splitAroundBaseline(captured, baseline, separator: string):
    tuple[matched: bool, prefix, suffix: string] =
  ## Locate `baseline` inside `captured` as a whole `separator`-delimited run
  ## and return what sits before and after it. Anchored on the separator so a
  ## baseline of `/usr/bin` does not match inside `/opt/usr/bin`.
  if baseline.len == 0:
    return (false, "", "")
  if captured == baseline:
    return (true, "", "")
  if captured.startsWith(baseline & separator):
    return (true, "", captured[baseline.len + separator.len .. ^1])
  if captured.endsWith(separator & baseline):
    return (true, captured[0 ..< captured.len - baseline.len - separator.len],
      "")
  let infix = separator & baseline & separator
  let at = captured.find(infix)
  if at >= 0:
    return (true, captured[0 ..< at], captured[at + infix.len .. ^1])
  (false, "", "")

proc foreignEnvOpsFromDump*(baseline, captured: openArray[(string, string)];
                            separator = $PathSep): seq[ForeignEnvOp] =
  ## The pure diff. `baseline` is the environment the foreign command was
  ## launched with; `captured` is what sourcing its output produced. The result
  ## is ordered by variable name so the same inputs always produce the same
  ## artifact bytes — `env` makes no ordering promise, and an artifact whose
  ## bytes depend on the kernel's environ order would never cache-hit.
  var before = initTable[string, string]()
  for pair in baseline:
    before[pair[0]] = pair[1]
  var after = initTable[string, string]()
  var order: seq[string] = @[]
  for pair in captured:
    if not after.hasKey(pair[0]):
      order.add(pair[0])
    after[pair[0]] = pair[1]

  var ops: seq[ForeignEnvOp] = @[]
  for name in order:
    if isIgnoredForeignEnvName(name):
      continue
    let value = after[name]
    if before.hasKey(name):
      let baseValue = before[name]
      if baseValue == value:
        continue
      let split = splitAroundBaseline(value, baseValue, separator)
      if split.matched:
        if split.prefix.len > 0:
          ops.add(ForeignEnvOp(kind: feoPrepend, name: name,
            value: split.prefix))
        if split.suffix.len > 0:
          ops.add(ForeignEnvOp(kind: feoAppend, name: name,
            value: split.suffix))
        continue
    ops.add(ForeignEnvOp(kind: feoSet, name: name, value: value))

  for pair in baseline:
    if isIgnoredForeignEnvName(pair[0]):
      continue
    if not after.hasKey(pair[0]):
      ops.add(ForeignEnvOp(kind: feoUnset, name: pair[0], value: ""))

  ops.sort(proc (a, b: ForeignEnvOp): int =
    result = cmp(a.name, b.name)
    if result == 0:
      result = cmp(ord(a.kind), ord(b.kind)))
  ops

proc currentEnvironmentPairs*(): seq[(string, string)] =
  ## The capture's baseline: the environment this process was started with.
  ## Deliberately the provider's OWN environment rather than a scrubbed one —
  ## `nix` needs a usable `PATH`, `HOME` and `NIX_SSL_CERT_FILE` to run at all,
  ## and the dev-env introspection edge already composes exactly that set
  ## (`commonMonitorEnv` in `repro_dev_env_engine`).
  for key, value in envPairs():
    result.add((key, value))

const CaptureDumpScript = """
while IFS= read -r __repro_foreign_line; do
  case "$__repro_foreign_line" in
    "declare -x "*)
      __repro_foreign_rest=${__repro_foreign_line#declare -x }
      __repro_foreign_name=${__repro_foreign_rest%%=*}
      case "$__repro_foreign_name" in
        ""|*[!A-Za-z0-9_]*) continue ;;
      esac
      printf '%s=%s\0' "$__repro_foreign_name" "${!__repro_foreign_name}"
      ;;
  esac
done < <(export -p)
"""
  ## Dump the exported environment using only bash BUILTINS. Nothing here is
  ## resolved through `PATH`, which matters because the script we just sourced
  ## has rewritten `PATH` to whatever the foreign environment says it should
  ## be: `env` or `printenv` would be looked up through that rewritten `PATH`
  ## and would either fail or, worse, succeed against a different binary than
  ## the one we meant.
  ##
  ## `export -p` supplies the NAMES and `${!name}` supplies the VALUES. Values
  ## are never parsed out of `export -p`'s output, which is the point: bash
  ## quotes them for re-input, and re-implementing bash's quoting rules to undo
  ## that is exactly the kind of almost-right parser that silently corrupts one
  ## value in a thousand. The name is taken from the head of a `declare -x `
  ## line and rejected unless it is a valid identifier, so a multi-line value
  ## whose continuation happens to look like a declaration cannot inject one.
  ##
  ## `compgen -e` would be the obvious spelling and does NOT work: bash can be
  ## built without programmable completion, and the bash this repository's own
  ## dev shell provides is exactly such a build — `compgen` reports
  ## `command not found` there.

proc captureScriptFor*(sourcePath: string): string =
  ## The full bash program the capture runs: source the foreign script with its
  ## stdout redirected to stderr (a `shellHook` that echoes must not corrupt
  ## the dump), then print the resulting exported environment NUL-delimited.
  "set +u\n" &
  ". " & quoteShell(sourcePath) & " 1>&2 || exit 91\n" &
  CaptureDumpScript

proc resolveCaptureShell*(explicit = ""): string =
  ## Absolute path of the bash used for the capture. Absolute because the
  ## capture inherits the provider's `PATH` and a relative lookup would be one
  ## more thing the foreign environment could change under us.
  if explicit.len > 0:
    return explicit
  let fromEnv = getEnv("REPRO_FOREIGN_ENV_BASH")
  if fromEnv.len > 0:
    return fromEnv
  let found = uncontrolledFindExe("bash")
  if found.len == 0:
    raise newException(ForeignEnvCaptureError,
      "foreign env capture needs bash on PATH (or REPRO_FOREIGN_ENV_BASH); " &
      "install bash, or set REPRO_FOREIGN_ENV_BASH=/path/to/bash")
  found

proc environmentTable*(pairs: openArray[(string, string)]): StringTableRef =
  ## `osproc`'s environment shape. `nil` means "inherit", which is NOT what a
  ## capture wants once the baseline has been filtered.
  result = newStringTable(modeCaseSensitive)
  for pair in pairs:
    result[pair[0]] = pair[1]

proc readAndRemove(path: string): string =
  ## Read a capture side-channel file and delete it.
  ##
  ## Deleting matters for invalidation, not tidiness. The capture runs inside
  ## the monitored dev-env introspection edge, so every file it writes and
  ## reads back becomes an observed input of that edge. A file left behind
  ## would carry `nix`'s per-run chatter — which is not stable — into the
  ## fingerprint, and the shell would re-evaluate on every entry. A file that
  ## is always absent when the action ends fingerprints as `ffkMissing` every
  ## time, which is stable.
  if not fileExists(extendedPath(path)):
    return ""
  result = readFile(extendedPath(path))
  try:
    removeFile(extendedPath(path))
  except CatchableError:
    discard

proc runCaptureCommand*(argv: openArray[string]; workingDir: string;
                        stdoutPath, stderrPath: string;
                        env: StringTableRef = nil;
                        captureShell = ""):
    tuple[output, error: string, exitCode: int] =
  ## Run a foreign command with its stdout and stderr redirected to FILES, and
  ## return what it wrote to each.
  ##
  ## Files rather than pipes, because pipes deadlock here and did. `osproc`'s
  ## streams are blocking `FILE*` reads: draining stdout blocks until 4 KiB
  ## arrive or the pipe closes, and the child cannot close it while it is
  ## itself blocked writing a full 64 KiB stdout buffer that nobody is
  ## draining. A `nix print-dev-env` script for a real dev shell is ~60 KiB and
  ## an exported environment dump is larger, so this is the normal case rather
  ## than an edge one. Getting it right without files needs a reader thread per
  ## stream; two redirections in the shell we already require is smaller and
  ## has no concurrency in it at all.
  ##
  ## Ambient by construction: `nix` and `direnv` are host tools the recipe
  ## reaches for before any engine-provisioned prefix exists, which is exactly
  ## the case `uncontrolledStartProcess` exists to make visible at the call
  ## site.
  if argv.len == 0:
    raise newException(ForeignEnvCaptureError, "empty foreign command")
  createDir(extendedPath(parentDir(stdoutPath)))
  createDir(extendedPath(parentDir(stderrPath)))
  var redirected = "exec >" & quoteShell(stdoutPath) & " 2>" &
    quoteShell(stderrPath) & "\nexec"
  for item in argv:
    redirected.add(" " & quoteShell(item))
  redirected.add("\n")
  let shell = resolveCaptureShell(captureShell)
  var process = uncontrolledStartProcess(shell, workingDir,
    ["--noprofile", "--norc", "-c", redirected], env, {})
  var code = 0
  try:
    code = process.waitForExit()
  finally:
    process.close()
  (readAndRemove(stdoutPath), readAndRemove(stderrPath), code)

proc captureForeignEnvOps*(argv: openArray[string]; workingDir, scriptPath: string;
                           captureShell = "";
                           separator = $PathSep;
                           baseline: openArray[(string, string)] = []):
    seq[ForeignEnvOp] =
  ## Run `argv` (which must print a POSIX shell script on stdout), source that
  ## script in a subshell started from `baseline`, and return the difference as
  ## dev-env operations.
  ##
  ## `baseline` defaults to this process's environment. It is ONE value used
  ## three times — to launch the foreign command, to launch the capture shell,
  ## and as the left side of the diff — and the three must be the same
  ## environment or the diff describes a transition nobody asked for. A caller
  ## that filters the baseline (see `envrc.nim`, which removes direnv's own
  ## state so `direnv export` describes loading an `.envrc` rather than
  ## migrating from whatever direnv context the caller was already in) gets
  ## that filtering applied consistently across all three.
  ##
  ## `scriptPath` is where the produced script is kept. It is a stable name,
  ## and the file is deliberately NOT deleted afterwards, for two reasons. It
  ## is the thing to read when a dev shell is not what somebody expected — the
  ## foreign environment's own words, not Reprobuild's summary of them. And a
  ## per-run temporary name would put a different path into the observed input
  ## set on every evaluation, which is churn the invalidation machinery would
  ## then have to absorb; a stable path with deterministic content is simply
  ## another correctly-fingerprinted input.
  let baselinePairs =
    if baseline.len > 0: @baseline else: currentEnvironmentPairs()
  let baselineEnv = environmentTable(baselinePairs)
  let scratch = parentDir(scriptPath)
  let produced = runCaptureCommand(argv, workingDir,
    scratch / "producer.stdout", scratch / "producer.stderr", baselineEnv,
    captureShell)
  if produced.exitCode != 0:
    raise newException(ForeignEnvCaptureError,
      argv.join(" ") & " failed with exit code " & $produced.exitCode &
      (if produced.error.len > 0: "\n" & produced.error.strip() else: ""))
  if produced.output.len == 0:
    raise newException(ForeignEnvCaptureError,
      argv.join(" ") & " printed nothing on stdout; refusing to contribute " &
      "an empty environment" &
      (if produced.error.len > 0: "\n" & produced.error.strip() else: ""))

  createDir(extendedPath(parentDir(scriptPath)))
  writeFile(extendedPath(scriptPath), produced.output)

  let shell = resolveCaptureShell(captureShell)
  let dumped = runCaptureCommand(
    @[shell, "--noprofile", "--norc", "-c", captureScriptFor(scriptPath)],
    workingDir, scratch / "capture.stdout", scratch / "capture.stderr",
    baselineEnv, captureShell)
  if dumped.exitCode != 0:
    raise newException(ForeignEnvCaptureError,
      "sourcing the environment produced by " & argv.join(" ") &
      " failed with exit code " & $dumped.exitCode &
      (if dumped.error.len > 0: "\n" & dumped.error.strip() else: ""))
  foreignEnvOpsFromDump(baselinePairs, parseNulEnvDump(dumped.output),
    separator)
