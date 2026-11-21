## The command string a COMPILE-TIME ``staticExec`` must be handed so that it
## runs a program with a chosen working directory.
##
## ## Why this is a module and not three inline string concatenations
##
## An action's runtime ``PATH`` is composed only of the directories the solved
## graph resolved THAT EDGE's tool and THAT EDGE's declared
## ``toolIdentityRefs`` into (`Compose an action's PATH from what the edge
## declares, not from the host`). There is no host tail. A Nim compile edge's
## ``PATH`` is therefore exactly ``<nim>/bin:<gcc-wrapper>/bin`` — measured at
## 1374 of this repository's 2757 actions — and NEITHER directory contains a
## shell.
##
## A macro that shells out at compile time runs INSIDE that action. The DSL's
## resource-accessor generator did:
##
##     "sh -c " & quoteShell("cd " & quoteShell(root) & " && exec " & nimCmd)
##
## and the bare ``sh`` stopped resolving:
##
##     resource accessor generation failed for 'prodres5a': expected an IFP
##     frame, got:
##     /bin/sh: line 1: sh: command not found
##
## Note the shape of that message. The OUTER ``/bin/sh`` ran; the INNER bare
## ``sh`` is the one that was missing. ``staticExec`` on POSIX already goes
## through a shell — ``execCmdEx`` starts the command with ``poEvalCommand``,
## which is ``execv("/bin/sh", ["sh", "-c", cmd])`` — so on POSIX the wrapper
## was buying a second shell process and a ``PATH`` dependency in exchange for
## nothing.
##
## ## Why the fix is here and not on the edge
##
## The alternative was to declare a shell on the Nim compile edges beside the
## ``gcc`` they already declare. That works, and it is wrong for this case.
## Declaring ``sh`` does NOT remove a shell dependency — ``staticExec``
## invokes ``/bin/sh`` by absolute path whatever we declare, and that
## invocation is outside the graph and unkeyed. It only ADDS a second,
## graph-resolved shell on top of the unkeyed one, and charges the cost to
## every one of the ~1397 Nim edges: a new keyed cache-key input, so a bash
## bump re-runs every compile in the repository, and a wider ``PATH`` from
## which more bare names resolve — the exact property the hermetic-``PATH``
## work was establishing.
##
## Not depending on ``PATH`` at all is strictly better than widening it. A
## macro shelling out at compile time is not an action; it is the compiler's
## own process, and the right trust boundary for it is "name nothing that has
## to be searched for".
##
## The Windows branch is unchanged and still names a shell, because there
## ``staticExec`` executes the program DIRECTLY — there is no implicit shell,
## so a composed command line has to supply one.

import std/[compilesettings, os, strutils]

proc compileTimeShellCommand*(workDir: string; command: string): string =
  ## ``command``, wrapped so that a ``staticExec`` of the result runs it with
  ## ``workDir`` as the current directory. An empty ``workDir`` means "run it
  ## wherever the compiler already is" and the command is returned unchanged.
  ##
  ## On POSIX the result names NO executable that must be found on ``PATH``:
  ## ``cd`` is a shell builtin and ``exec`` is a shell keyword, both handled by
  ## the ``/bin/sh`` that ``staticExec`` starts anyway. That is the property
  ## `t_macro_time_shell_out_needs_no_shell_on_the_path.nim` pins.
  if workDir.len == 0:
    return command
  when defined(windows):
    "cmd.exe /d /c " &
      quoteShell("cd /d " & quoteShell(workDir) & " && " & command)
  else:
    "cd " & quoteShell(workDir) & " && exec " & command

# ---------------------------------------------------------------------------
# Did ``staticExec`` run at all?
#
# ``nim check`` does not execute ``staticExec`` (nor ``gorge`` / ``gorgeEx``,
# which share its implementation): every call returns the empty string.
# Measured on nim-fork-2.3.1-codetracer, same dev shell, same file:
# ``staticExec("echo hi")`` is ``""`` under ``nim check`` and ``"hi"`` under
# ``nim c``. A macro that reads a ``staticExec`` result as an answer — "the
# probe did not print REPRO_RW, so the directory is not writable", "the
# generator printed nothing, so it failed" — therefore turns "the probe did not
# run" into a false statement about the world, and the refusal built on it
# names a cause that does not exist.
#
# The two helpers below let such a macro tell the cases apart on its FAILURE
# path. They cost a subprocess each, so they are meant to be called only once a
# ``staticExec`` result has already come back unexpected, never on the happy
# path.
# ---------------------------------------------------------------------------

const StaticExecSentinel = "REPRO_STATICEXEC_RAN"

proc staticExecRuns*(): bool =
  ## Whether ``staticExec`` executes programs in THIS compile. Compile-time
  ## only.
  ##
  ## The probe is a command that cannot run and print nothing: a shell builtin
  ## echoing a fixed sentinel. An empty result is therefore "the command did
  ## not run", never "the command's answer was no". ``contains`` rather than
  ## ``==`` because a compile under io-mon may interleave the monitor's own
  ## diagnostics into the captured output.
  ##
  ## On Windows ``staticExec`` starts the program directly, with no implicit
  ## shell, and ``echo`` is internal to ``cmd.exe`` — so the probe names
  ## ``cmd.exe`` there, as ``compileTimeShellCommand`` does.
  when defined(windows):
    staticExec("cmd.exe /d /c echo " & StaticExecSentinel).contains(
      StaticExecSentinel)
  else:
    staticExec("echo " & StaticExecSentinel).contains(StaticExecSentinel)

proc staticExecSuppressedCause*(): string =
  ## Why ``staticExec`` did not run in this compile, as text a refusal can
  ## quote. Call it only after `staticExecRuns` returned ``false``.
  ##
  ## The compiler skips ``staticExec`` on purpose in two cases: a
  ## ``nim check`` compile (``querySetting(command)`` is ``check``) and a
  ## nimsuggest session (which defines ``nimsuggest``). Anything else means
  ## the compiler tried and the process could not be started — the shell
  ## ``staticExec`` goes through was not there.
  if defined(nimsuggest):
    "this compile runs under nimsuggest, which, like `nim check`, does not " &
      "execute `staticExec` (every call returns \"\"); `nim c` does"
  elif querySetting(command) == "check":
    "this is a `nim check` compile, and `nim check` does not execute " &
      "`staticExec` (every call returns \"\"); `nim c` does"
  else:
    "`staticExec` returned nothing for a probe that always prints output, " &
      "so the compiler could not start the shell it runs commands through (" &
      (when defined(windows): "cmd.exe" else: "/bin/sh") & ")"
