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

import std/os

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
