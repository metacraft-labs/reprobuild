## Pre-push protocol — Git's verbatim source expressions are valid local refs.
##
## Git's pre-push stdin carries ``<local-ref> <local-oid> <remote-ref>
## <remote-oid>``. The ``<local-ref>`` field is the refspec's SOURCE as Git saw
## it: a full ref name only when the source resolved to one, otherwise the
## typed text verbatim — a bare object name (``git push origin <sha>:refs/heads/x``),
## ``HEAD~0``, ``main~0``. The parser used to accept only ``HEAD`` and ``refs/...``,
## so every such push failed with "malformed pre-push protocol: pre-push refs
## record has an invalid local ref" even though Git had already accepted it.
##
## Real Git, no mocks: the refs streams below are CAPTURED from real ``git
## push`` runs against a local bare remote by a recording pre-push hook, and
## parsed with the shipped ``parsePrePushRefStream`` / ``evaluateOutgoingCurrent``.
## No ``repro`` binary is needed because the boundary under test is the parser.
##
## Falsifiable: reverting ``validLocalSource`` to the ref-name-only rule fails
## the bare-SHA and ``HEAD~0`` captures; dropping the expression arm of
## ``evaluateOutgoingCurrent`` fails the outgoing-current assertion. The
## negative controls keep the strictness that remains load-bearing: an invalid
## ``refs/`` name, a ``(delete)`` with a non-zero object, and an expression with
## a zero object are still refused.

import repro_test_support/reasoned_skip
import std/[os, osproc, strutils, tempfiles, unittest]

import repro_cli_support/push_hook_protocol

proc sh(cmd, cwd: string): string =
  let (output, code) = execCmdEx(cmd, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath, poEvalCommand})
  if code != 0:
    checkpoint("command failed: " & cmd & "\n" & output)
    quit 1
  output.strip()

proc capture(repo, log, pushArgs: string): string =
  ## Run one real push and return exactly the refs stream Git handed the hook.
  writeFile(log, "")
  discard sh("git push -q origin " & pushArgs, repo)
  readFile(log)

suite "pre-push protocol — source expressions in the local-ref field":
  test "bare SHA, HEAD~0 and main~0 sources parse and classify as outgoing HEAD":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a repository")
    else:
      let scratch = createTempDir("repro-pre-push-srcexpr-", "")
      defer: removeDir(scratch)
      let origin = scratch / "origin.git"
      let repo = scratch / "app"
      let log = scratch / "refs.log"
      discard sh("git init -q --bare -b main " & quoteShell(origin), scratch)
      discard sh("git init -q -b main " & quoteShell(repo), scratch)
      discard sh("git config user.email t@example.invalid", repo)
      discard sh("git config user.name t", repo)
      discard sh("git commit -q --allow-empty -m one", repo)
      discard sh("git commit -q --allow-empty -m two", repo)
      discard sh("git remote add origin " & quoteShell(origin), repo)
      let hook = repo / ".git" / "hooks" / "pre-push"
      writeFile(hook, "#!/bin/sh\ncat >> " & quoteShell(log) & "\n")
      setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})
      let head = sh("git rev-parse HEAD", repo)

      var streams: seq[(string, string)]
      streams.add(("bare-sha", capture(repo, log, head & ":refs/heads/x")))
      streams.add(("head-tilde", capture(repo, log, "HEAD~0:refs/heads/y")))
      streams.add(("branch-tilde", capture(repo, log, "main~0:refs/heads/z")))
      # Each capture really is a source expression, not a ref Git resolved:
      # otherwise this test would pass vacuously against the old parser.
      check streams[0][1].startsWith(head & " " & head & " refs/heads/x ")
      check streams[1][1].startsWith("HEAD~0 " & head & " refs/heads/y ")
      check streams[2][1].startsWith("main~0 " & head & " refs/heads/z ")

      for (name, bytes) in streams:
        let refsPath = scratch / ("captured-" & name)
        writeFile(refsPath, bytes)
        let parsed = parsePrePushRefStream(gitBin, repo, refsPath)
        if not parsed.ok:
          checkpoint(name & ": " & parsed.diagnostic)
        check parsed.ok
        check parsed.updates.len == 1
        let decision = evaluateOutgoingCurrent(gitBin, repo, refsPath,
          "origin", origin, "origin", origin)
        if not decision.outgoingCurrent:
          checkpoint(name & ": " & decision.diagnostic)
        check decision.protocolOk
        check decision.outgoingCurrent

  test "remaining strictness: bad ref names and impossible object pairs":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a repository")
    else:
      let scratch = createTempDir("repro-pre-push-srcexpr-neg-", "")
      defer: removeDir(scratch)
      let repo = scratch / "app"
      discard sh("git init -q -b main " & quoteShell(repo), scratch)
      discard sh("git config user.email t@example.invalid", repo)
      discard sh("git config user.name t", repo)
      discard sh("git commit -q --allow-empty -m one", repo)
      let head = sh("git rev-parse HEAD", repo)
      let zeros = repeat('0', head.len)
      let cases = @[
        ("refs/heads/bad..name " & head & " refs/heads/main " & zeros,
          "invalid local ref"),
        ("(delete) " & head & " refs/heads/main " & head, "invalid local ref"),
        ("HEAD~1 " & zeros & " refs/heads/main " & zeros, "invalid local ref"),
        (head & " " & head & " not-a-ref " & zeros, "invalid remote ref")]
      for index, (line, expected) in cases:
        let refsPath = scratch / ("neg-" & $index)
        writeFile(refsPath, line & "\n")
        let parsed = parsePrePushRefStream(gitBin, repo, refsPath)
        check not parsed.ok
        if expected notin parsed.diagnostic:
          checkpoint("case " & $index & ": " & parsed.diagnostic)
        check expected in parsed.diagnostic
