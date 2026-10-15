## Shared fixture for the HL-10 tests: the lock-update node a certifying
## ``repro test`` / ``repro certify`` runs before its tests
## (Unified-Locking-And-Hooks.md §13.3 amended, §13.7.3; Test-Certificates
## decisions D6, D14 (1), D15).
##
## Deliberately not a ``t_*.nim`` file, so the suite generator never compiles
## it as a test of its own.
##
## Builds on ``certify_workspace_mode_fixture``: a real manifest workspace with
## four real git repositories (app → lib-b → lib-c, and lib-d), a committed
## ``repro.lock`` in ``app`` pinning its develop set, a scratch local
## certificate store, a registered daemon signing key, and a real
## ``repro.nim`` in ``app`` whose edges run a one-flag typed tool through the
## real provider, engine and monitor. On top of it:
##
##   * ``lockreader``, an edge whose INPUT is ``repro.lock``: it copies the
##     lock to ``build/lock-seen`` when it runs, so a test can tell which lock
##     the test commands saw;
##   * ``aggregate("test", @[unit_a, lockreader])``, so a plain ``repro test``
##     resolves ``test`` (implicitly certificate-producing, D15), and an
##     unmarked edge ``lone`` (selected as ``lone-out``) for the plan that has
##     no certificate-producing node;
##   * the managed hooks, installed by the real ``repro hooks ensure --vcs``
##     with ``REPROBUILD_REPRO`` naming the built ``repro``, so a commit runs
##     the real dispatcher, the managed refresh and the TC-8g gate.
##
## Nothing is mocked: real repositories, the built ``repro``, real
## ``git commit``, the production verifier.

import std/[os, strutils]

import repro_test_support
import repro_cli_support
import ./certify_workspace_mode_fixture

export certify_workspace_mode_fixture

const lockUpdateBuildLines* =
  "    let lockreader = certTool(actionId = \"lockreader\",\n" &
  "      input = \"repro.lock\",\n" &
  "      output = \"build/lock-seen\",\n" &
  "      marker = \".repro/runs.log\")\n" &
  "    discard aggregate(\"test\", @[unit_a, lockreader])\n"

const repinCauseLine* =
  "this commit's lock refresh re-pinned and staged repro.lock"

proc setupLockUpdateFixture*(label: string; requireTest = false):
    WorkspaceCertifyFixture =
  ## The workspace above. ``requireTest`` adds a ``required``
  ## ``[certificates]`` policy for the target ``test`` on this platform, so
  ## the TC-8g gate refuses any commit a certificate does not cover.
  result = setupWorkspaceCertifyFixture(label, ["unit_a", "lone"],
    lockUpdateBuildLines)
  if requireTest:
    result.cf.appendProjectToml("[certificates]\ngate_mode = \"required\"\n" &
      "required_targets = [\"test\"]\n" &
      "required_platforms = [\"" & currentPlatformTag() & "\"]\n")

proc hookEnv(fx: WorkspaceCertifyFixture): seq[tuple[name, value: string]] =
  @[(name: "REPROBUILD_REPRO", value: fx.cf.sib.repro)]

proc ensureHooks*(fx: WorkspaceCertifyFixture) =
  ## ``repro hooks ensure --vcs app``, serviced by the built ``repro``.
  let res = runShell(shellCommand(@[fx.cf.sib.repro, "hooks", "ensure",
    "--vcs", fx.app], fx.hookEnv), fx.app)
  doAssert res.code == 0, "hooks ensure failed: " & res.output

proc gitApp*(fx: WorkspaceCertifyFixture; args: varargs[string]): CmdResult =
  ## A real git command in ``app``, with the hook environment.
  var argv = @[fx.cf.sib.gitBin, "-C", fx.app]
  for a in args: argv.add(a)
  runShell(shellCommand(argv, fx.hookEnv), fx.app)

proc mustGitApp*(fx: WorkspaceCertifyFixture; args: varargs[string]): string =
  var argv: seq[string]
  for a in args: argv.add(a)
  let res = fx.gitApp(argv)
  doAssert res.code == 0, "git " & argv.join(" ") & ": " & res.output
  res.output

proc reproInEnv*(fx: WorkspaceCertifyFixture; args: openArray[string];
                 extra: openArray[tuple[name, value: string]]): CmdResult =
  ## ``reproIn`` with additional environment.
  var env = daemonKeyEnv(fx.cf.daemonKey, certifyKeyId)
  env.add((name: "PATH", value: fx.binDir & $PathSep & getEnv("PATH")))
  for e in extra: env.add(e)
  var argv = @[fx.cf.sib.repro]
  for arg in args:
    argv.add(arg)
  runShell(shellCommand(argv, env), fx.app)

proc lockText*(fx: WorkspaceCertifyFixture): string =
  readFile(fx.app / "repro.lock")

proc stagedLock*(fx: WorkspaceCertifyFixture): string =
  ## ``repro.lock`` as the index holds it.
  fx.mustGitApp("show", ":repro.lock")

proc lockSeenByTests*(fx: WorkspaceCertifyFixture): string =
  ## What ``lockreader`` copied the last time it ran.
  let path = fx.app / "build" / "lock-seen"
  if fileExists(path): readFile(path) else: ""

proc indexEntries*(fx: WorkspaceCertifyFixture;
                   skipPaths: openArray[string] = []): string =
  ## ``git ls-files --stage --debug`` without the entries for ``skipPaths``:
  ## each remaining entry's mode, object, stage AND cached stat data, so a
  ## writer that refreshed or restaged an unrelated entry shows up.
  let raw = fx.mustGitApp("ls-files", "--stage", "--debug")
  var skipping = false
  for line in raw.splitLines():
    if line.len > 0 and line[0] notin {' ', '\t'}:
      skipping = false
      let tab = line.find('\t')
      if tab >= 0 and line[tab + 1 .. ^1] in skipPaths:
        skipping = true
    if not skipping:
      result.add(line & "\n")

proc headContent*(fx: WorkspaceCertifyFixture): string =
  ## The content id of ``app``'s HEAD tree, computed by git alone.
  treeContentId(fx.cf.sib.gitBin, fx.app, "HEAD")

proc preCommitLog*(fx: WorkspaceCertifyFixture): string =
  let path = preCommitLogPath(fx.cf.sib.ws)
  if fileExists(path): readFile(path) else: ""

proc lastLinesSince*(log: string; offset: int): string =
  ## What was appended to a log after it was ``offset`` bytes long.
  if offset >= log.len: "" else: log[offset .. ^1]

proc withRef*(lockBody, path, newRef: string): string =
  ## ``lockBody`` with the ``ref`` of the ``deps`` entry at ``path`` replaced.
  let entry = depEntry(lockBody, path)
  doAssert entry.len > 0, "no deps entry for " & path
  let at = entry.find("ref = \"")
  doAssert at >= 0, "the entry for " & path & " records no ref"
  let close = entry.find('"', at + "ref = \"".len)
  let replaced = entry[0 ..< at] & "ref = \"" & newRef & "\"" &
    entry[close + 1 .. ^1]
  lockBody.replace(entry, replaced)
