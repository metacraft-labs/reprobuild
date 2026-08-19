## Ambient-execution linter and explicit escape hatches.
##
## Reprobuild-owned executables should normally be invoked through typed
## execution profiles. The ``uncontrolled*`` wrappers below make the remaining
## bootstrap and PATH-only exceptions visible to reviewers. The rewrite rules
## warn when production code calls the ambient process APIs directly.

import std/[os, osproc, strtabs]

proc uncontrolledFindExe*(exe: string, followSymlinks = true): string =
  ## Resolves ``exe`` through the ambient PATH.
  {.noRewrite.}: os.findExe(exe, followSymlinks)

proc uncontrolledExecCmdEx*(command: string;
                            options: set[ProcessOption] = {poStdErrToStdOut,
                                                           poUsePath};
                            env: StringTableRef = nil;
                            workingDir = ""; input = ""):
    tuple[output: string, exitCode: int] =
  ## Runs ``command`` through an ambient shell or PATH lookup.
  {.noRewrite.}: osproc.execCmdEx(command, options, env, workingDir, input)

proc uncontrolledExecProcess*(command: string; workingDir = "";
                              args: openArray[string] = [];
                              env: StringTableRef = nil;
                              options: set[ProcessOption] = {poStdErrToStdOut,
                                                             poUsePath,
                                                             poEvalCommand}):
    string =
  ## Runs ``command`` and captures its output without a typed profile.
  {.noRewrite.}: osproc.execProcess(command, workingDir, args, env, options)

proc uncontrolledExecShellCmd*(command: string): int =
  ## Hands ``command`` to the system shell verbatim.
  {.noRewrite.}: os.execShellCmd(command)

proc uncontrolledStartProcess*(command: string; workingDir = "";
                               args: openArray[string] = [];
                               env: StringTableRef = nil;
                               options: set[ProcessOption] = {
                                 poStdErrToStdOut}): owned(Process) =
  ## Spawns ``command`` without a typed execution profile.
  {.noRewrite.}: osproc.startProcess(command, workingDir, args, env, options)

when not defined(ambientExecutionAllowed):

  template warnFindExe*{findExe(a, b, c)}(a: string, b: bool, c: auto): string =
    {.warning: "ambient execution: findExe resolves a binary reprobuild does " &
               "not control. Use a typed execution profile, or " &
               "uncontrolledFindExe() if that is genuinely intended".}
    {.noRewrite.}: os.findExe(a, b, c)

  template warnExecCmdEx*{execCmdEx(c, o, e, w, i)}(
      c: string, o, e, w, i: auto): auto =
    {.warning: "ambient execution: execCmdEx runs a binary reprobuild does " &
               "not control. Use a typed execution profile, or " &
               "uncontrolledExecCmdEx() if that is genuinely intended".}
    {.noRewrite.}: osproc.execCmdEx(c, o, e, w, i)

  template warnExecProcess*{execProcess(c, w, a, e, o)}(
      c: string, w, a, e, o: auto): string =
    {.warning: "ambient execution: execProcess runs a binary reprobuild does " &
               "not control. Use a typed execution profile, or " &
               "uncontrolledExecProcess() if that is genuinely intended".}
    {.noRewrite.}: osproc.execProcess(c, w, a, e, o)

  template warnExecShellCmd*{execShellCmd(c)}(c: string): int =
    {.warning: "ambient execution: execShellCmd hands a command to the " &
               "system shell. Use a typed execution profile, or " &
               "uncontrolledExecShellCmd() if that is genuinely intended".}
    {.noRewrite.}: os.execShellCmd(c)

  template warnStartProcess*{startProcess(c, w, a, e, o)}(
      c: string, w, a, e, o: auto): owned(Process) =
    {.warning: "ambient execution: startProcess spawns a binary reprobuild " &
               "does not control. Use a typed execution profile, or " &
               "uncontrolledStartProcess() if that is genuinely intended".}
    {.noRewrite.}: osproc.startProcess(c, w, a, e, o)
