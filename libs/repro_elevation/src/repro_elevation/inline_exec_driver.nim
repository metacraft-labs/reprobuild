## Windows-System-Resources Phase E — the elevated `inlineExecCall`
## hand-off driver.
##
## Unlike the per-resource typed drivers (`pokFixtureFile`,
## `pokWindowsService`, `pokFsSystemFile`, ...) which converge a
## resource toward a declared steady state via observe / desired-
## digest, `pokInlineExecCall` is a one-shot side-effecting spawn
## driven by the build engine. The build engine has already decided
## (via input hashing + output caching) that the edge needs to run;
## the broker's role is purely to fork the process under elevation,
## wait for completion, and surface the exit code.
##
## This module owns:
##
##   * `expandExecCallArgv`     — the `@FILE:<path>` argv preprocessor
##                                wrapper that threads a typed reader
##                                through `expandArgFiles`; tests can
##                                inject a synthetic reader.
##   * `inlineExecCallAuditDetail`
##                              — the audit-log diagnostic; argv is
##                                rendered through `auditArgvWithRedaction`
##                                so the substituted `@FILE:` contents
##                                never reach the log (spec §2.1).
##   * `runInlineExecCall`      — the spawn shim, through
##                                `bounded_exec.runBoundedExec`: output to
##                                a file, stdin from the null device, and a
##                                deadline that kills the whole process
##                                tree (`effectiveInlineExecTimeoutSeconds`).
##                                The broker is already elevated when this
##                                runs.
##
## Errors:
##   * a missing / unreadable `@FILE:<path>` raises `EProtocol(
##     "@FILE: not found at <path>: <reason>")` — matches spec §2.1.
##   * a spawn failure raises `EProtocol` with the OS reason.
##   * an exit code NOT in `iecAcceptExitCodes` raises `EProtocol`
##     with the captured stderr tail.
##   * an action still running at its deadline has its process tree
##     killed and raises `EProtocol` naming the deadline.

import std/[os, strtabs, strutils]

import ./bounded_exec
import ./errors
import ./operations

export bounded_exec

type
  InlineExecCallOutcome* = object
    ## The result of one `pokInlineExecCall` spawn. Carried back to the
    ## dispatch layer for the audit log + the `OperationResult` frame.
    exitCode*: int
    stdoutTail*: string
    stderrTail*: string

  ArgFileReader* = proc (path: string): string
    ## The `@FILE:<path>` reader injection. The default
    ## (`defaultArgFileReader`) reads from the local filesystem under
    ## the elevated process's identity; tests inject a pure table-
    ## backed reader.

const MaxCapturedOutputTailBytes* = 4096
  ## How many bytes of `stdout` / `stderr` the dispatch layer keeps for
  ## the audit log. A failed elevated process's tail is enough to
  ## diagnose; a full capture is wasteful and risks logging a secret
  ## that scrolled through stdout.

proc defaultArgFileReader*(path: string): string =
  ## Read the file at `path` and return its contents. Raises `IOError`
  ## on the usual filesystem error surface (missing file, permission
  ## denied, etc.); the caller turns the IOError into an `EProtocol`
  ## with the spec-mandated `@FILE: not found` diagnostic.
  ##
  ## Pure delegation to `readFile` — the closed-set / path validation
  ## already happened at the codec boundary.
  result = readFile(path)

proc expandExecCallArgv*(op: PrivilegedOperation;
                         reader: ArgFileReader = defaultArgFileReader):
    seq[string] =
  ## Build the spawn-ready argv for a `pokInlineExecCall` operation:
  ## prepend `iecExecutable` to the `@FILE:`-expanded `iecArguments`.
  ## Pure — the disk-touching part is the injected reader, which
  ## defaults to `defaultArgFileReader`.
  ##
  ## Raises `EProtocol` if any `@FILE:<path>` argv entry refers to a
  ## missing / unreadable file (the spec-mandated diagnostic shape).
  if op.kind != pokInlineExecCall:
    raise newException(ValueError,
      "expandExecCallArgv called with a non-inline-exec operation kind " &
        $op.kind)
  result = newSeqOfCap[string](op.iecArguments.len + 1)
  result.add(op.iecExecutable)
  for arg in op.iecArguments:
    result.add(expandArgFileToken(arg, reader))

proc inlineExecCallAuditDetail*(op: PrivilegedOperation;
                                outcome: InlineExecCallOutcome): string =
  ## Render the apply-log detail string for a `pokInlineExecCall`
  ## dispatch. The argv is rendered with `auditArgvWithRedaction` so
  ## the substituted `@FILE:` contents never reach the log — only the
  ## `<arg redacted: read from <path>>` placeholder appears.
  if op.kind != pokInlineExecCall:
    raise newException(ValueError,
      "inlineExecCallAuditDetail called with a non-inline-exec " &
        "operation kind " & $op.kind)
  var safeArgv: seq[string] = @[op.iecExecutable]
  for redacted in auditArgvWithRedaction(op.iecArguments):
    safeArgv.add(redacted)
  result = "spawned `" & safeArgv.join(" ") & "` -> exit " &
    $outcome.exitCode

const
  DefaultInlineExecTimeoutSeconds* = 16_200
    ## 4 h 30 min: the deadline of an inline-exec action whose profile edge
    ## declares no `timeoutSeconds`.
    ##
    ## Chosen against the longest step the production profile bounds itself:
    ## win-ci-bare-001's Hyper-V golden rebuild, which carries its own
    ## 240-minute guard (`vmHarnessGoldenBuildTimeoutMinutes`) and must be
    ## allowed to reach it and clean up. A smaller default would kill that
    ## step half way through its own recovery. The ceiling is the 5-hour
    ## `ExecutionTimeLimit` of the DeployAgent task: past that, Task
    ## Scheduler kills `repro.exe` alone and leaves the action's tree running,
    ## which is the state this deadline exists to prevent. A profile that
    ## knows its step is short says so with `timeoutSeconds`.
  InlineExecTimeoutEnvVar* = "REPRO_APPLY_ACTION_TIMEOUT_SECONDS"
    ## Replaces the default for every edge that declares no deadline of its
    ## own. A value `<= 0` turns the default off (no deadline), the same
    ## convention as `REPRO_INTERFACE_COMPILE_TIMEOUT_SECONDS`.

proc effectiveInlineExecTimeoutSeconds*(op: PrivilegedOperation): int =
  ## The deadline, in seconds, `runInlineExecCall` applies to ``op``; `0`
  ## means none. The edge's own `iecTimeoutSeconds` wins, then
  ## `REPRO_APPLY_ACTION_TIMEOUT_SECONDS`, then
  ## `DefaultInlineExecTimeoutSeconds`.
  if op.kind == pokInlineExecCall and op.iecTimeoutSeconds > 0:
    return op.iecTimeoutSeconds
  let raw = getEnv(InlineExecTimeoutEnvVar).strip()
  if raw.len > 0:
    try:
      return max(0, parseInt(raw))
    except ValueError:
      discard
  DefaultInlineExecTimeoutSeconds

proc spawnInlineExecCall(argv: seq[string]; cwd: string;
                         env: seq[string];
                         timeoutSeconds: int): BoundedExecOutcome =
  ## The actual spawn, through `runBoundedExec`: stdout and stderr to a file,
  ## stdin from the null device, and the whole process tree killed at the
  ## deadline. The broker is already elevated when this runs, so the child
  ## inherits the elevated token.
  ##
  ## Not a pipe, and that is the point. This used to be
  ## `startProcess(..., {poStdErrToStdOut, poUsePath})`, a read of the merged
  ## pipe and an unbounded `waitForExit`; on win-ci-bare-001 that held the
  ## deploy agent for ~21 h. `bounded_exec` has the incident, and the two
  ## ways a pipe holds the parent even when it is read to the end.
  ##
  ## `env` is the `NAME=VALUE` list the operation carried; an empty list means
  ## "inherit the broker's process environment unchanged" (matches what the
  ## engine's non-elevated path does for an unset per-edge `env` list).
  if argv.len == 0:
    raiseProtocol("reprobuild.inlineExecCall: empty argv after expansion")
  var envTable: StringTableRef = nil
  if env.len > 0:
    envTable = newStringTable(modeCaseSensitive)
    for entry in env:
      let eq = entry.find('=')
      if eq <= 0:
        raiseProtocol("reprobuild.inlineExecCall: malformed env entry '" &
          entry & "' (expected NAME=VALUE)")
      envTable[entry[0 ..< eq]] = entry[eq + 1 .. ^1]
  try:
    result = runBoundedExec(argv, cwd = cwd, env = envTable,
      timeoutMs = timeoutSeconds * 1000,
      tailBytes = MaxCapturedOutputTailBytes)
  except BoundedExecError as e:
    raiseProtocol("reprobuild.inlineExecCall spawn failed: " & e.msg)

proc runInlineExecCall*(op: PrivilegedOperation;
                        reader: ArgFileReader = defaultArgFileReader):
    InlineExecCallOutcome =
  ## End-to-end dispatch for a `pokInlineExecCall` operation:
  ##
  ##   1. Expand every `@FILE:<path>` argv entry via `reader` (the
  ##      spec-mandated `@FILE: not found at <path>: <reason>`
  ##      diagnostic surfaces here on a missing / unreadable file).
  ##   2. Spawn the resulting argv under the broker's elevated
  ##      identity.
  ##   3. Wait for completion; capture the stdout (with stderr
  ##      merged) tail for the audit log.
  ##   4. Raise `EProtocol` when the captured exit code is NOT in
  ##      `iecAcceptExitCodes` (the closed set the operation declared;
  ##      defaults to `@[0]` at the codec boundary).
  if op.kind != pokInlineExecCall:
    raise newException(ValueError,
      "runInlineExecCall called with a non-inline-exec operation kind " &
        $op.kind)
  let argv = expandExecCallArgv(op, reader)
  let cwd =
    if op.iecWorkingDirectory.len > 0: op.iecWorkingDirectory
    else: ""
  let timeoutSeconds = effectiveInlineExecTimeoutSeconds(op)
  let run = spawnInlineExecCall(argv, cwd, op.iecEnvironment, timeoutSeconds)
  if run.timedOut:
    raiseProtocol("reprobuild.inlineExecCall '" & op.address &
      "' did not finish within its deadline of " & $timeoutSeconds &
      " s and was stopped (" & run.killNote & "); the action failed and " &
      "the next apply retries it; tail: " & run.outputTail)
  let outcome = InlineExecCallOutcome(
    exitCode: run.exitCode,
    stdoutTail: run.outputTail,
    stderrTail: "")
  let accept =
    if op.iecAcceptExitCodes.len == 0: @[0]
    else: op.iecAcceptExitCodes
  if outcome.exitCode notin accept:
    raiseProtocol("reprobuild.inlineExecCall '" & op.address &
      "' exited " & $outcome.exitCode & " (acceptable: " &
      accept.join(",") & "); tail: " & outcome.stdoutTail)
  result = outcome
