## NF-2 — **the unpushed skip names the sibling, the revision, and the push
## that would actually make it lockable.**
##
## Spec: Workspace-And-Develop-Mode.md §"Reproducibility And `repro check`"
## ("dirty **or only locally committed**") and Unified-Locking-And-Hooks.md
## §"the named command must RUN where the message is printed".
##
## ## Why the message needs a case of its own
##
## `t_an_unpushed_sibling_revision_is_not_recorded` asserts that nothing was
## written. That assertion is satisfied equally by a hook that skipped and
## warned and by one that silently did nothing — and "silently did nothing while
## looking like it worked" is the failure mode this whole campaign exists to
## remove. It is also the precise shape of the defect being fixed: nix-direnv
## answered the unobtainable pin by falling back to the previous shell instead
## of failing.
##
## So the CONTENT of the notice is asserted here, and not by matching a pattern:
## every command the notice quotes is lifted out of the text, parsed as a shell
## command, RUN from the directory the message itself names, and then the state
## it was named for is checked to have MOVED. A remedy that reads correctly and
## does not work is the thing under test.
##
## The strings are produced by `flakeReconcileCommands` /
## `flakeReconcileAlternative` — the same generators the pre-push refusal and
## the behind-pin skip use — rather than by a second generator grown for this
## path, so the single-pasteable-line fix those already carry cannot be
## reintroduced here independently.
##
## ## What is asserted
##
##   1. the notice names the SIBLING (`gamma`) and the full REVISION. A notice
##      that says "a sibling is unpublished" without saying which, or at what
##      revision, cannot be acted on;
##   2. every backticked chunk is ONE pasteable line — a single physical line
##      that `bash -n` accepts, which is exactly the check a human paste
##      performs;
##   3. the FIRST command really publishes: run from the named directory it
##      exits 0 and the revision becomes reachable from a remote-tracking ref,
##      asked with git's own predicate against a REAL bare origin;
##   4. …and a subsequent refresh then DOES record it. This is the half a
##      message can satisfy in prose and fail in a terminal — the command that
##      "fixes" a state the next run still refuses;
##   5. the ALTERNATIVE (`git fetch`) is a real, runnable command too, and is
##      named because the publication check reads local remote-tracking refs
##      alone: the one way its verdict can be wrong is a checkout that has not
##      fetched, and the message has to say how to disprove it.
##
## ## Mutations
##
##   * emit a command that does not fix the state — name the refresh alone,
##     without the publishing push ⇒ RED on (3) and (4): the lifted command
##     exits 0, publishes nothing, and the pin still does not move;
##   * drop the revision from the notice ⇒ RED on (1);
##   * fold the two commands into one pair of backticks ⇒ RED on (2).
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`. The push
## this case performs is a real `git push` to a real bare repository.

import std/[os, osproc, strutils, unittest]

import nf3_override_state_fixture

proc unpublishedNotice(text: string): string =
  ## The one line of the hook's output that announces the withheld refresh.
  ## Scoped to the line rather than taken as the whole stream, because
  ## `backtickedCommands` over the whole stream would happily pick up a command
  ## quoted by some unrelated diagnostic and the case would then assert about a
  ## string the withholding never produced.
  for line in text.splitLines():
    if line.contains("NOT refreshed") and line.contains("gamma-src"):
      return line
  ""

suite "NF-2: the unpushed skip names the push that would make it lockable":

  test "t_the_unpushed_skip_names_the_push_that_would_make_it_lockable":
    const caseName =
      "t_the_unpushed_skip_names_the_push_that_would_make_it_lockable"
    if not nf2Prerequisites(caseName):
      skip()
    else:
      let shell = findExe("bash")
      if shell.len == 0:
        echo "SKIPPED (loudly): " & caseName & " needs `bash` on PATH to " &
          "check that the printed commands parse as shell commands; " &
          "bash=MISSING"
        skip()
      else:
        let fx = setupNf2Fixture("unpushed-remedy")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()

        commitLockAndPublish(fx, "a lock that names every sibling's seed")
        let before = readFile(lockPath(fx))

        let localOnly = moveSibling(fx, "gamma", "work that is not pushed yet")
        check not siblingRevIsPublished(fx, "gamma", localOnly)

        let committed = tryCommitInApp(fx, "work built against a local gamma")
        checkpoint("commit output:\n" & committed.output)
        check committed.code == 0
        check readFile(lockPath(fx)) == before

        let notice = unpublishedNotice(committed.output)
        checkpoint("notice: " & notice)
        check notice.len > 0
        if notice.len == 0:
          checkpoint("pre-commit log:\n" & preCommitLog(fx))
        else:
          # ---- (1) the sibling, and the REVISION ------------------------
          check notice.contains("gamma")
          check notice.contains(localOnly)

          let namedDir = directoryNamedForRunning(notice)
          checkpoint("named directory: " & namedDir)
          check namedDir.len > 0
          check dirExists(namedDir)

          # ---- (2) every quoted chunk is ONE pasteable line -------------
          let commands = backtickedCommands(notice)
          checkpoint("commands: " & $commands)
          check commands.len == 3
          for cmd in commands:
            check cmd.splitLines().len == 1
            check not cmd.contains("(")
            let parsed = execCmdEx(q(shell) & " -n -c " & q(cmd))
            checkpoint("bash -n `" & cmd & "` -> " & $parsed.exitCode & " " &
              parsed.output)
            check parsed.exitCode == 0

          if commands.len == 3:
            # ---- (5) the ALTERNATIVE runs ------------------------------
            # Asserted BEFORE the push, while the verdict it exists to
            # disprove is still standing: a `git fetch` here legitimately
            # finds nothing, which is the honest outcome when the revision
            # really has never been published.
            let alt = runNamedCommand(fx, commands[2], namedDir)
            checkpoint("ran `" & commands[2] & "` in " & namedDir & " -> " &
              $alt.code & "\n" & alt.output)
            check alt.code == 0
            check not siblingRevIsPublished(fx, "gamma", localOnly)
            check readFile(lockPath(fx)) == before

            # ---- (3) the FIRST command really PUBLISHES ----------------
            let push = runNamedCommand(fx, commands[0], namedDir)
            checkpoint("ran `" & commands[0] & "` in " & namedDir & " -> " &
              $push.code & "\n" & push.output)
            check push.code == 0
            check siblingRevIsPublished(fx, "gamma", localOnly)

            # ---- (4) …and the refresh it names then RECORDS it ----------
            let refresh = runNamedCommand(fx, commands[1], namedDir)
            checkpoint("ran `" & commands[1] & "` in " & namedDir & " -> " &
              $refresh.code & "\n" & refresh.output)
            check refresh.code == 0
            let after = readFile(lockPath(fx))
            if after == before:
              checkpoint("gamma-src UNCHANGED:\n" &
                nodeText(after, "gamma-src"))
            check after != before
            check nodeText(after, "gamma-src").contains(localOnly)
            check not nodeText(after, "gamma-src").contains(fx.seedSha[2])

            # …and the hook stops withholding, because the state the notice
            # was printed about is genuinely resolved rather than merely
            # re-described.
            let again = firePreCommitHook(fx)
            checkpoint("re-fired hook -> " & $again.code & "\n" & again.output)
            check again.code == 0
            check unpublishedNotice(again.output).len == 0
            check readFile(lockPath(fx)) == after
