## The author an installed managed-hook body advertises is recovered from EVERY
## generation of body a released build has written, not only from the one this
## build writes.
##
## THE DEFECT. A managed body's escape hatch names the ``repro`` that wrote it,
## and ``managedHookAuthorBin`` reads that name back. Two generations of the
## line exist on disk:
##
##   * ``99a3f3fe3`` (2026-08-27) up to ``02304993^`` — DOUBLE-quoted message,
##     path RAW:
##       echo "repro hooks:        REPROBUILD_REPRO=<path> git push" >&2
##   * ``02304993`` (2026-09-23) onward — the whole message passed through
##     ``quoteShellPosix``, the path quoted inside it as well:
##       echo 'repro hooks:        REPROBUILD_REPRO=<quoted path> git push' >&2
##
## and bodies older than ``99a3f3fe3`` carry no author line at all.
## ``02304993`` MOVED the reader from the first generation to the second instead
## of teaching it both, so every body installed before that date reads as
## author-less. Measured in one workspace on 2026-10-03: 700 installed bodies,
## 695 of them double-quoted, so the reader answered for 5. Its consumer
## ``installedManagedHookContracts`` then left the writer of the other 695 out
## of ``repro health``'s ``hook-interpreter`` row ("written by …"), which exists
## to name both builds of a skew (reprobuild-pm issue
## ``2026-10-04-managed-hook-author-parser-reads-only-the-single-quoted-generation``).
##
## WHAT THIS SUITE PINS:
##
##   (A) The reader, in process, against one fixture body per generation — the
##       double-quoted raw-path form (the exact line measured on disk), the
##       single-quoted form with a bare path, and the single-quoted form with a
##       path that needs quoting (a space AND an embedded single quote, so both
##       levels of quoting are exercised). The author-less body answers "": that
##       is a positive finding about a pre-``99a3f3fe3`` body, not a miss.
##       **Fails before the fix on the double-quoted fixtures.**
##   (B) The consumer, end to end: real hooks installed by the real binary,
##       ONE body's author line rewritten into the double-quoted generation,
##       and the real ``repro health``'s ``hook-interpreter`` row must name BOTH
##       writers — the old-generation one and the build that wrote the other
##       four. **Fails before the fix: the old-generation writer is absent.**
##
## What a widened read must NOT do — accept an old-generation body as current at
## push time — is pinned beside the tripwire it belongs with, in
## ``t_repro_push_sync_integrates_upstream_then_publishes.nim``
## (``t_repro_push_refuses_an_old_generation_hook_whose_author_it_can_read``):
## ``managedHookBodyIsCurrent`` is not exported, and its public consumer is the
## push preflight that suite already drives.
##
## WHY FIXTURE BODIES RATHER THAN BODIES FROM THE OLD BUILDS. The state is "a
## body written by a build that is not this one", and the builds that wrote the
## double-quoted generation cannot be produced hermetically (the measured writer
## is a Nix store path of 0.1.3). The fixture lines are transcriptions of those
## builds' generator (``git show 99a3f3fe3:…`` and ``02304993^:…``), and (B)
## rewrites exactly one line of an otherwise real installed body — the only
## line the reader looks at. Everything else in (B) is real: binary, git,
## ``hooks ensure`` and ``health``.
##
## Hermetic: one ``createTempDir``, local bares only, no network.
## Skip rule: ``git`` missing on PATH (case B only).

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_cli_support
import repro_core/cli_images
import repro_test_support

proc q(value: string): string = quoteShell(value)

const
  EscapeHatchHead =
    "  if [ -n \"${REPRO_CMD:-}\" ]; then\n" &
    "    echo \"repro hooks:   3. To push right now with the " &
    "build that installed this hook:\" >&2\n"
  EscapeHatchTail = "    fi\n  fi\n"

proc bodyAround(authorLine: string): string =
  ## A managed body reduced to the block the reader scans. Lines before and
  ## after the author line are there so a reader that only looks at the first
  ## or last line of the body fails.
  "#!/usr/bin/env sh\n# reprobuild managed pre-push hook\n" &
    EscapeHatchHead & authorLine & "\n" & EscapeHatchTail &
    "  echo \"repro hooks: Do not reach for --no-verify\" >&2\n"

proc doubleQuotedGeneration(rawPath: string): string =
  ## ``99a3f3fe3`` … ``02304993^``: the path is spliced in RAW.
  "      echo \"repro hooks:        REPROBUILD_REPRO=" & rawPath &
    " git push\" >&2"

proc singleQuotedGeneration(path: string): string =
  ## ``02304993`` onward: path quoted, then the whole message quoted.
  "      echo " & quoteShellPosix("repro hooks:        REPROBUILD_REPRO=" &
    quoteShellPosix(path) & " git push") & " >&2"

suite "a managed hook's author is read from every body generation":

  test "t_managed_hook_author_is_read_from_every_generation":
    # Pre-99a3f3fe3: no author line. "" is the correct answer.
    check managedHookAuthorBin(bodyAround(
      "      echo \"repro hooks:   to push, fix the hook\" >&2")) == ""

    # 99a3f3fe3 … 02304993^, the exact line measured on disk on 2026-10-03.
    const measured =
      "/nix/store/r9dxqdl0c200yl0dckc3jj9h5nizbhbi-reprobuild-0.1.3/bin/" &
      ".repro-wrapped"
    const measuredLine =
      "      echo \"repro hooks:        REPROBUILD_REPRO=/nix/store/" &
      "r9dxqdl0c200yl0dckc3jj9h5nizbhbi-reprobuild-0.1.3/bin/.repro-wrapped " &
      "git push\" >&2"
    check doubleQuotedGeneration(measured) == measuredLine
    check managedHookAuthorBin(bodyAround(measuredLine)) == measured
    # The raw splice keeps a space verbatim, and the reader must too: there is
    # no quoting in this generation to undo.
    const spaced = "/home/op/old builds/bin/repro"
    check managedHookAuthorBin(bodyAround(doubleQuotedGeneration(spaced))) ==
      spaced

    # 02304993 onward, bare path: quoteShellPosix leaves it unquoted.
    const bare = "/home/op/reprobuild/build/bin/reprobuild"
    check singleQuotedGeneration(bare) ==
      "      echo 'repro hooks:        REPROBUILD_REPRO=" & bare &
      " git push' >&2"
    check managedHookAuthorBin(bodyAround(singleQuotedGeneration(bare))) ==
      bare

    # 02304993 onward, a path needing BOTH levels of quoting. Spelled out
    # literally as well as composed, so a change to quoteShellPosix cannot
    # silently move the fixture along with the generator.
    const awkward = "/home/op/it's here/bin/repro"
    const awkwardLine = """      echo 'repro hooks:        REPROBUILD_REPRO='"'"'/home/op/it'"'"'"'"'"'"'"'"'s here/bin/repro'"'"' git push' >&2"""
    check singleQuotedGeneration(awkward) == awkwardLine
    check managedHookAuthorBin(bodyAround(awkwardLine)) == awkward

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc engineBinary(): string =
  ## The full CLI image: the thin ``repro`` client ``execv``s it, so it is the
  ## path ``hooks ensure`` bakes into the bodies it writes.
  requireBinary(repoRoot() / "build" / "bin" / reprobuildEngineExeName(),
    "reprobuild.apps.repro")

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "lib-a"
default_revision = "main"
trunk = "main"

[[remote]]
name = "lib-a-origin"
fetch = "LIB_A_URL"

includes = [
  "repos/lib-a.toml",
]
"""

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

proc rewriteAuthorLine(body, newLine: string): string =
  ## Replace the one escape-hatch author line of a CURRENT-generation body.
  ## Located by the message text rather than by its quoting, so this helper
  ## does not share the reader's anchors.
  var lines = body.split('\n')
  var replaced = 0
  for i in 0 ..< lines.len:
    if "REPROBUILD_REPRO=" in lines[i] and lines[i].endsWith(" >&2") and
        lines[i].strip().startsWith("echo ") and " git push" in lines[i]:
      lines[i] = newLine
      inc replaced
  doAssert replaced == 1,
    "expected exactly one author line in the installed body, found " &
      $replaced
  lines.join("\n")

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  nil

suite "health names a writer that wrote an older body generation":

  test "t_health_names_the_writer_of_a_double_quoted_generation_body":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository carrying " &
        "installed managed hooks for `health` to read")
    else:
      let scratch = createTempDir("repro-hook-author-gen-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let origin = scratch / "origin-lib-a.git"
      let seed = scratch / "seed-lib-a"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(seed))
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.name \"Author Gen Tester\"")
      writeFile(seed / "README.md", "author generations fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m fixture")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " remote add origin " &
        q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

      let workspaceRoot = scratch / "workspace"
      for dir in [workspaceRoot / ".repro", workspaceRoot / "projects",
          workspaceRoot / "repos"]:
        createDir(dir)
      writeFile(workspaceRoot / "projects" / "lib-a.toml",
        projectToml.replace("LIB_A_URL", fileUrl(origin)))
      writeFile(workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
      let repoPath = workspaceRoot / "lib-a"
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
        q(repoPath))

      let ensured = runShell(shellCommand(@[
        reproBin, "hooks", "ensure", "--vcs", workspaceRoot],
        @[(name: "REPROBUILD_REPRO", value: reproBin)]))
      checkpoint("hooks ensure: " & ensured.output)
      check ensured.code == 0

      # One body, rewritten into the double-quoted generation, naming a writer
      # that is not this build. A path that does not exist, so `health` runs
      # nothing foreign while identifying it.
      let oldWriter = scratch / "old-0.1.3" / "bin" / ".repro-wrapped"
      let managed = repoPath / ".git" / "hooks" / "post-commit.repro-managed"
      check fileExists(managed)
      let installed = readFile(managed)
      check engineBinary() in installed
      writeFile(managed,
        rewriteAuthorLine(installed, doubleQuotedGeneration(oldWriter)))
      check oldWriter in readFile(managed)

      # The runner is this build, so the row's VERDICT is not in question; only
      # its list of writers is.
      let res = runShell(shellCommand(
        @[reproBin, "health", "lib-a", "--json",
          "--workspace-root=" & workspaceRoot],
        @[(name: "REPROBUILD_REPRO", value: reproBin)]))
      checkpoint("health --json output:\n" & res.output)
      let row = findCheck(parseJson(res.output), "hook-interpreter")
      check not row.isNil
      let detail = row["detail"].getStr()
      checkpoint("hook-interpreter detail: " & detail)
      check "written by" in detail
      # The writer of the four untouched bodies — the control: without it a
      # row naming only whatever is in the rewritten body would pass.
      check engineBinary() in detail
      # The writer of the old-generation body — what the single-anchor reader
      # dropped.
      check oldWriter in detail
