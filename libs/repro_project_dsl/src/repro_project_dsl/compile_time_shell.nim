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
##
## ## No shell at all, with the pinned compiler
##
## The implicit ``/bin/sh`` described above is upstream Nim's. The Nim
## compiler reprobuild pins (the ``metacraft-labs/nim`` fork the package
## ships) starts a ``staticExec`` / ``gorgeEx`` command without a shell when
## it is plain and quoted words, or ``cd <absolute dir> && [exec] <plain
## words>`` (``compiler/shellfreeexec.nim`` there), so for those commands no
## shell runs either. That matters beyond ``PATH``: a recipe compile runs
## under the filesystem monitor, and a shell it starts puts the host's
## ``/bin/sh`` and its libraries among the compile's recorded inputs, so a
## bundle restored on a machine whose ``/bin/sh`` is another program
## recompiles it. Every command built here is therefore kept plain: the
## composition above, and `compilerWritabilityProbe`.

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
  ##
  ## On POSIX the result is ``cd <workDir> && exec <command>``, and when
  ## ``command`` is made of plain and quoted words (as every caller's is: an
  ## absolute compiler path and ``quoteShell``ed arguments), the pinned Nim
  ## compiler runs it with no shell at all: it starts ``command`` in
  ## ``workDir`` directly (``directCommand`` in the compiler's
  ## ``shellfreeexec``). The shell would make the host's ``/bin/sh`` and its
  ## libraries inputs of the recipe compile, which a machine with another
  ## ``/bin/sh`` does not have, so keep ``command`` plain: a ``$``, a
  ## redirection or any other shell syntax in it sends the whole line to
  ## ``/bin/sh`` again (`t_recipe_compiles_do_not_record_the_host_shell`).
  if workDir.len == 0:
    return command
  when defined(windows):
    "cmd.exe /d /c " &
      quoteShell("cd /d " & quoteShell(workDir) & " && " & command)
  else:
    "cd " & quoteShell(workDir) & " && exec " & command

proc compileTimeCommand*(argv: openArray[string]): string =
  ## ``argv`` as a command line for a compile-time ``staticExec``: each word
  ## ``quoteShell``ed, so the line is plain and quoted words that mean
  ## exactly ``argv``, which the pinned compiler starts without a shell (see
  ## the module header). Build every ``staticExec`` command that runs one
  ## program this way rather than by hand: a word quoted by hand that holds
  ## a ``$`` or a backslash, or an unquoted one with a space, sends the line
  ## to ``/bin/sh``, or changes what it runs.
  for i, word in argv:
    if i > 0: result.add(' ')
    result.add(quoteShell(word))

const WritabilityProbeName = ".reprobuild-write-probe"

proc compilerWritabilityProbe*(nimExe, dir: string): string =
  ## A command that prints ``REPRO_RW`` when a new entry can be created in
  ## the existing directory ``dir``, for a compile-time ``staticExec``, run
  ## by the compiler ``nimExe`` itself (``getCurrentCompilerExe()``) and no
  ## other program: it evaluates ``mkDir`` and ``rmDir`` of a probe entry in
  ## ``dir`` as NimScript and then ``echo``es. A refused ``mkDir`` ends the
  ## evaluation with an error, and nothing is printed.
  ##
  ## Why the compiler. The probe must not name a program that has to be
  ## found on ``PATH`` (a compile action's ``PATH`` has none of ``test`` or
  ## ``sh``), and it must not need a shell: ``test -w`` is a builtin, and
  ## the shell that runs it puts the host's ``/bin/sh`` and its libraries
  ## among the inputs the monitor records for the recipe compile. A
  ## compile-time macro cannot try the creation itself: the Nim VM runs
  ## ``os.createDir`` as a compiler callback whose ``OSError`` escapes the
  ## VM's ``try``. NimScript's ``mkDir`` raises inside the evaluation, which
  ## is a process of its own here, so a refusal costs that process only.
  ##
  ## The command is plain words, so the pinned compiler starts it without a
  ## shell (`compileTimeShellCommand`). The configuration files a user or a
  ## project directory would add are skipped (``--skipUserCfg``,
  ## ``--skipParentCfg``, ``--skipProjCfg``): the evaluation reads the
  ## compiler's own files and nothing else. Two probes of one directory at
  ## once are harmless: ``mkDir`` of an existing directory and ``rmDir`` of a
  ## missing one both succeed.
  let probe = dir / WritabilityProbeName
  let script = "mkDir(" & escape(probe) & "); rmDir(" & escape(probe) &
    "); echo \"REPRO_RW\""
  quoteShell(nimExe) & " --hints:off --warnings:off --colors:off " &
    "--skipUserCfg --skipParentCfg --skipProjCfg --eval:" & quoteShell(script)

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
