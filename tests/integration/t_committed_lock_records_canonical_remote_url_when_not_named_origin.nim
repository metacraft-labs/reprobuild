## RX Phase-F fix — the committed lock's per-dep VCS coordinate ``url`` must be
## resolved from the repo's CANONICAL remote, even when that remote is NOT named
## ``origin``. Metacraft workspace repos name their upstream remote after the org
## (``metacraft-labs``), so a hard-coded ``git remote get-url origin`` returns
## EMPTY and every committed lock records ``url = ""``. An empty coordinate url is
## not harmless: ``fetchLockPinnedProducer`` REFUSES to fetch a pinned sibling
## whose coordinate is incomplete, so a lock-driven CI build cannot materialize
## the pinned source. This test pins the robust-resolution behaviour.
##
## Drives the built ``./build/bin/repro`` against a single git workspace repo
## whose SOLE remote is named ``metacraft-labs`` (there is deliberately no
## ``origin``), then asserts:
##
##   1. ``repro lock refresh`` writes a schema-v2 ``repro.lock``.
##   2. The workspace repo's dep (path ".") carries a NON-EMPTY coordinate
##      ``url`` equal to the ``metacraft-labs`` remote's fetch URL — i.e. the
##      canonical remote was resolved despite not being ``origin``.
##
## Falsifiability: revert the fix (resolve the fetch url from ``origin`` only)
## and the sole ``metacraft-labs`` remote yields an EMPTY url — the lock records
## ``url = ""``, so (2) FAILS (the empty-url guard below trips and the expected
## ``url = "<metacraft-labs-url>"`` line is absent). Restore the fix and both
## pass.
##
## Hermetic: the git repo lives in a fresh tempdir. Skip rule: ``git`` missing
## or repro unbuilt.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

suite "RX Phase-F: committed lock records canonical remote url (not origin)":

  test "t_committed_lock_records_canonical_remote_url_when_not_named_origin":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "rxf-canon-remote-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- A bare upstream + a clone whose SOLE remote is metacraft-labs. ----
      # ``git clone --origin`` names the created remote, so there is deliberately
      # NO remote named ``origin`` in the work tree — mirroring how metacraft
      # workspace repos are configured.
      let upstream = scratch / "upstream.git"
      let repo = scratch / "work"
      check git(gitBin, "", "init --bare -b main " & q(upstream)).code == 0
      check run(q(gitBin) & " clone --origin metacraft-labs " &
        q(upstream) & " " & q(repo)).code == 0
      check git(gitBin, repo, "config user.email t@example.invalid").code == 0
      check git(gitBin, repo, "config user.name Tester").code == 0
      writeFile(repo / "README.md", "rxf fixture\n")
      writeFile(repo / "repro.solver", solverInputs)
      check git(gitBin, repo, "add README.md repro.solver").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      check git(gitBin, repo, "push metacraft-labs main").code == 0

      # Sanity: there is genuinely no ``origin`` remote, only ``metacraft-labs``.
      let remotes = git(gitBin, repo, "remote").output.strip()
      check remotes == "metacraft-labs"
      check git(gitBin, repo, "remote get-url origin").code != 0

      let headSha = git(gitBin, repo, "rev-parse HEAD").output.strip()
      check headSha.len == 40
      let canonUrl =
        git(gitBin, repo, "remote get-url metacraft-labs").output.strip()
      check canonUrl.len > 0

      # ---- (1) refresh writes a v2 lock. ----
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      let lockBody = readFile(repo / "repro.lock")
      check "reprobuild.solved-graph-lock.v2" in lockBody
      check "path = \".\"" in lockBody
      check ("revision = \"" & headSha & "\"") in lockBody

      # ---- (2) the dep records the CANONICAL (metacraft-labs) url, NOT "". ----
      # Falsifiable: origin-only resolution records ``url = ""`` and this fails.
      check ("url = \"" & canonUrl & "\"") in lockBody
      check "url = \"\"" notin lockBody
