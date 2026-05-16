import std/[algorithm]
import repro_core/paths

type
  CommandKind* = enum
    ckDirect
    ckShell

  StdioPolicy* = enum
    spInherit
    spNull
    spCapture

  EnvVar* = object
    name*: string
    value*: string

  ProcessSpec* = object
    kind*: CommandKind
    executable*: NormalizedPath
    args*: seq[string]
    env*: seq[EnvVar]
    cwd*: NormalizedPath
    stdinPolicy*: StdioPolicy
    stdoutPolicy*: StdioPolicy
    stderrPolicy*: StdioPolicy

proc normalizedEnv*(env: openArray[EnvVar]): seq[EnvVar] =
  result = @env
  result.sort(proc(a, b: EnvVar): int = cmp(a.name, b.name))

proc directProcess*(executable: NormalizedPath; args: openArray[string];
                    cwd: NormalizedPath; env: openArray[EnvVar] = []): ProcessSpec =
  ProcessSpec(
    kind: ckDirect,
    executable: executable,
    args: @args,
    env: normalizedEnv(env),
    cwd: cwd,
    stdinPolicy: spInherit,
    stdoutPolicy: spCapture,
    stderrPolicy: spCapture)
