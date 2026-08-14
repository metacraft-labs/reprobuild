## Ambient-execution linter — every executed binary must be one reprobuild
## controls.
##
## ``reprobuild-specs/Package-Model.md`` §"Executables, Libraries, And Package
## Collections" (254-273) requires an executable to be "a strongly typed CLI
## interface bound to an execution profile". A bare ``findExe`` + ``execCmdEx``
## is none of the three sanctioned classes: it resolves an arbitrary host binary
## through ambient ``PATH`` and records nothing.
##
## This module is force-imported into every compiled module by ``config.nims``
## (``switch("import", "lints/ambient_execution")``), so it applies with no
## source changes anywhere.
##
## **Warning tier, on purpose.** ~427 call sites already violate the rule;
## errors would make the tree uncompilable and the linter would be deleted
## rather than obeyed. Each rule flips to ``{.error.}`` once its call sites
## reach zero. ``docs/ambient-execution-linter.md`` tracks the baseline.
##
## Two ways to satisfy the rule at a call site:
##
## 1. Use a typed execution profile — the engine binds ``argv[0]`` to a realized
##    executable through ``BuildAction.toolIdentityRefs``. See
##    ``libs/repro_dsl_stdlib/.../packages/expand_archive.nim``.
## 2. Say explicitly that you are stepping outside one, with an
##    ``uncontrolled*`` hatch below. ``git grep uncontrolled`` is the audit
##    surface; it should stay short.
##
## Implementation notes for whoever adds the next rule — both of these fail
## SILENTLY, leaving a linter that enforces nothing:
##
##   * The pattern must declare the proc's FULL arity. Default arguments are
##     filled in before the pattern is matched, so ``findExe(a)`` never matches
##     a call written ``findExe("tar")`` — ``findExe(a, b, c)`` does.
##   * Pattern parameter types must match the TYPED NODE, not the signature
##     text. ``extensions: openArray[string] = ExeExts`` defaults from a
##     ``const`` array, so a pattern parameter declared ``openArray[string]``
##     does not match; ``auto`` does. When unsure, use ``auto``.
##
## See ``metacraft-dev-guidelines/policies/how-to-develop-custom-nim-linters.md``
## for the general mechanism.

import std/[os, osproc, strtabs]

# ---------------------------------------------------------------------------
# Blessed escape hatches.
#
# These take the ARGUMENTS rather than the call expression. A wrapper that
# receives the call (``template blessed(call: untyped)``) does NOT work: the
# argument is semantically analysed — and rewritten — at the call site before it
# reaches the template body, so the warning fires anyway. Containing the call
# means the banned identifier never appears at the call site and the pattern has
# nothing to match.
#
# They are defined unconditionally so code using them keeps compiling when the
# rules are disabled.
#
# Named for the hazard being accepted: reprobuild does not control WHICH BINARY
# RUNS. Using one does not by itself make a call site spec class 2 — that also
# requires recording the search path, resolved executable path and probes into
# the action identity. A hatch without that recording is unclassified, just
# honestly labelled.
# ---------------------------------------------------------------------------

proc uncontrolledFindExe*(exe: string, followSymlinks = true): string =
  ## BLESSED ESCAPE HATCH — resolves `exe` through ambient PATH.
  ## Reviewer: is there a package entry for this tool? If so, consume the
  ## realized prefix instead.
  {.noRewrite.}: os.findExe(exe, followSymlinks)

proc uncontrolledExecCmdEx*(command: string;
                            options: set[ProcessOption] = {poStdErrToStdOut,
                                                           poUsePath};
                            env: StringTableRef = nil;
                            workingDir = ""; input = ""):
    tuple[output: string, exitCode: int] =
  ## BLESSED ESCAPE HATCH — runs `command` through an ambient shell/PATH lookup.
  {.noRewrite.}: osproc.execCmdEx(command, options, env, workingDir, input)

proc uncontrolledExecProcess*(command: string; workingDir = "";
                              args: openArray[string] = [];
                              env: StringTableRef = nil;
                              options: set[ProcessOption] = {poStdErrToStdOut,
                                                             poUsePath,
                                                             poEvalCommand}):
    string =
  ## BLESSED ESCAPE HATCH — runs `command` and captures its output.
  {.noRewrite.}: osproc.execProcess(command, workingDir, args, env, options)

proc uncontrolledExecShellCmd*(command: string): int =
  ## BLESSED ESCAPE HATCH — hands `command` to the system shell verbatim.
  {.noRewrite.}: os.execShellCmd(command)

proc uncontrolledStartProcess*(command: string; workingDir = "";
                               args: openArray[string] = [];
                               env: StringTableRef = nil;
                               options: set[ProcessOption] = {
                                 poStdErrToStdOut}): owned(Process) =
  ## BLESSED ESCAPE HATCH — spawns `command` as a child process.
  {.noRewrite.}: osproc.startProcess(command, workingDir, args, env, options)

# ---------------------------------------------------------------------------
# The rules.
#
# `--define:ambientExecutionAllowed` exempts a whole module. Apply it to the
# specific compile edges of a sanctioned layer, NEVER as a repo-wide default —
# it switches the linter off entirely for everything it touches. Prefer an
# `uncontrolled*` hatch when the exceptions are individual call sites.
# ---------------------------------------------------------------------------

when not defined(ambientExecutionAllowed):

  template warnFindExe*{findExe(a, b, c)}(a: string, b: bool, c: auto): string =
    {.warning: "ambient execution: findExe resolves a binary reprobuild does " &
               "not control. Use a typed execution profile, or " &
               "uncontrolledFindExe() if that is genuinely intended.".}
    {.noRewrite.}: os.findExe(a, b, c)

  template warnExecCmdEx*{execCmdEx(c, o, e, w, i)}(
      c: string, o, e, w, i: auto): tuple[output: string, exitCode: int] =
    {.warning: "ambient execution: execCmdEx runs a binary reprobuild does " &
               "not control. Use a typed execution profile, or " &
               "uncontrolledExecCmdEx() if that is genuinely intended.".}
    {.noRewrite.}: osproc.execCmdEx(c, o, e, w, i)

  template warnExecProcess*{execProcess(c, w, a, e, o)}(
      c: string, w, a, e, o: auto): string =
    {.warning: "ambient execution: execProcess runs a binary reprobuild does " &
               "not control. Use a typed execution profile, or " &
               "uncontrolledExecProcess() if that is genuinely intended.".}
    {.noRewrite.}: osproc.execProcess(c, w, a, e, o)

  template warnExecShellCmd*{execShellCmd(c)}(c: string): int =
    {.warning: "ambient execution: execShellCmd hands a command to the " &
               "system shell. Use a typed execution profile, or " &
               "uncontrolledExecShellCmd() if that is genuinely intended.".}
    {.noRewrite.}: os.execShellCmd(c)

  template warnStartProcess*{startProcess(c, w, a, e, o)}(
      c: string, w, a, e, o: auto): owned(Process) =
    {.warning: "ambient execution: startProcess spawns a binary reprobuild " &
               "does not control. Use a typed execution profile, or " &
               "uncontrolledStartProcess() if that is genuinely intended.".}
    {.noRewrite.}: osproc.startProcess(c, w, a, e, o)
