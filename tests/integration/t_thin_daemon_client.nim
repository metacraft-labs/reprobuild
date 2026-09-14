## Dependency-Attribution MAC-1 — gates for the thin daemon client
## (``apps/repro-client``).
##
## NO MOCKS. Every test here runs the two REAL binaries against the real
## filesystem, a real ``repro-daemon`` on a real AF_UNIX socket, and a real
## project that really compiles a provider. The only stand-in anywhere is the
## fallback target in the routing tests, and it is a stand-in for the thing
## being OBSERVED rather than for a collaborator: the question those tests ask
## is "did the client hand this invocation over unchanged?", and a two-line
## script that prints its argv answers it exactly, while the real ``repro``
## would answer it only indirectly and would cost a build per case.
##
## What each test is for, and what makes it fail:
##
##   * ``thin_client_build_is_byte_identical_to_the_full_client`` — the
##     correctness contract. A build driven through the thin client must
##     produce the same stdout, the same stderr, the same exit code and the
##     same artifact as one driven through ``repro`` itself. It runs with the
##     embedded source-package roots REMOVED from the client environment,
##     because that is the configuration in which the two clients last
##     disagreed: the full CLI seeds those names in its prologue and a client
##     with no prologue does not, which moved the provider-compile cache key
##     and turned a hit into a miss. Reverting
##     ``ensureBuiltSourcePackageEnvironment()`` in
##     ``installUserDaemonBuildExecutor`` reddens this test on exactly that
##     line of stdout — verified, not assumed.
##
##     It also asserts the daemon RECORDED TWO SESSIONS WITH DIFFERENT
##     PROJECT ROOTS, because byte equality on its own cannot tell a served
##     thin build from one that quietly handed over to the full image and
##     produced the same bytes that way. See
##     ``daemonBuildSessionProjectRoots``; making ``shouldRouteToDaemon``
##     return ``false`` unconditionally reddens that check and nothing else
##     in this case.
##
##   * ``thin_client_hands_over_every_invocation_it_must_not_serve`` — the
##     routing gate. Each case is a shape the full CLI does NOT route to the
##     daemon, or one where the full CLI does client-side work of its own.
##     Removing any single entry from ``ClientHandledFlags`` reddens the case
##     that names it.
##
##   * ``thin_client_routes_a_plain_quiet_build`` — the gate's other half. A
##     gate that rejects everything would pass the test above and deliver
##     nothing. Widening the reject conditions until this case is rejected
##     reddens it.
##
##   * ``thin_client_falls_back_to_a_working_build_when_the_daemon_cannot_be_reached``
##     — the failure contract. With the daemon endpoint unreachable the thin
##     client must hand over to an image that still builds the project
##     correctly, not exit non-zero and not silently do nothing.
##
##   * ``thin_client_does_not_link_the_build_engine`` — the structural
##     property the milestone's number depends on. Importing
##     ``repro_cli_support`` from ``apps/repro-client`` reddens it.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc fullCliBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc thinCliBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro-client", ExeExt)

proc fixtureSource(): string =
  repoRoot() / "tests" / "fixtures" / "local-daemons-control-plane" /
    "direct-mode-parity" / "project"

const
  EmbeddedSourceRootNames = [
    "REPRO_TEST_ADAPTERS_SRC", "FASTSTREAMS_SRC", "NIM_STEW_SRC",
    "NIM_SERIALIZATION_SRC", "NIM_JSON_SERIALIZATION_SRC",
    "NIM_TOML_SERIALIZATION_SRC", "SSZ_SERIALIZATION_SRC", "NIMCRYPTO_SRC",
    "BEARSSL_SRC", "RESULTS_SRC", "STINT_SRC", "IO_MON_SRC",
    "STACKABLE_HOOKS_SRC", "VM_HARNESS_SRC", "SHM_QUEUE_SRC", "SHM_GSET_SRC",
    "REPRO_CT_TEST_RUNNER_SRC", "CODETRACER_PINNED_SRC", "RUNQUOTA_SRC"
  ]
    ## ``repro_interface_artifacts.BuiltSourcePackageRoots``. Removing these
    ## from the client environment is what puts the parity test in the
    ## configuration where the two clients last disagreed. Kept as a literal
    ## list rather than imported so the test does not pull the CLI's
    ## dependency closure in to ask a question about the environment.

type
  CapturedRun = object
    code: int
    output: string
    errors: string

proc runCaptured(exe: string; args: openArray[string]; cwd: string;
                 env: openArray[(string, string)] = [];
                 unset: openArray[string] = []): CapturedRun =
  ## Run ``exe`` with stdout and stderr captured SEPARATELY (``runShell``
  ## merges them, and this suite has to compare the two streams
  ## independently) and with the ability to REMOVE names from the child
  ## environment, which no existing helper offers.
  ##
  ## The redirection is done by an ``exec``-ing ``/bin/sh``, so the status
  ## this proc returns is the status of ``exe`` and not of a shell that ran
  ## it — the same trap as reading a build's exit code through a pipe.
  let outPath = cwd / "captured-stdout"
  let errPath = cwd / "captured-stderr"
  var envTable = newStringTable()
  for key, value in envPairs():
    envTable[key] = value
  for name in unset:
    if envTable.hasKey(name):
      envTable.del(name)
  for entry in env:
    envTable[entry[0]] = entry[1]
  var shArgs = @["-c",
    "exec \"$0\" \"$@\" >" & outPath & " 2>" & errPath, exe]
  for arg in args:
    shArgs.add(arg)
  let process = startProcess("/bin/sh", workingDir = cwd, args = shArgs,
    env = envTable, options = {})
  defer: process.close()
  result.code = process.waitForExit()
  result.output = if fileExists(outPath): readFile(outPath) else: ""
  result.errors = if fileExists(errPath): readFile(errPath) else: ""

proc daemonEnv(tempRoot, endpoint: string): seq[(string, string)] =
  @[
    ("REPRO_DAEMON_ENDPOINT", endpoint),
    ("REPRO_DAEMON_STATE_DIR", tempRoot / "state"),
    ("REPROBUILD_STORE_ROOT", tempRoot / "store"),
    ("REPRO_FULL_CLI", fullCliBin())
  ]

proc stopDaemon(tempRoot, endpoint: string) =
  discard runShell(shellCommand(@[fullCliBin(), "daemon", "stop",
    "--endpoint", endpoint, "--state-dir", tempRoot / "state",
    "--log", tempRoot / "state" / "logs" / "repro-daemon.log"]), repoRoot())
  try: removeFile(endpoint) except OSError: discard

proc daemonBuildSessionProjectRoots(tempRoot, endpoint: string): seq[string] =
  ## The ``projectRoot`` column of ``repro daemon sessions``, one entry per
  ## recorded BUILD session, in the order the daemon recorded them.
  ##
  ## This exists to keep the parity case from passing for the wrong reason.
  ## Comparing two byte streams says nothing about WHERE the second one came
  ## from, and the thin client's whole failure mode is silent: when anything
  ## goes wrong it ``execv``s the full ``repro``, which then produces exactly
  ## the bytes the comparison is looking for. A parity case that only compared
  ## output would therefore stay green if the thin client never served a
  ## single build — verified, not assumed: making ``shouldRouteToDaemon``
  ## return ``false`` unconditionally leaves the byte comparisons passing and
  ## reddens only the check below.
  ##
  ## ``projectRoot`` is the discriminator because it is the ONE request field
  ## the two clients are documented to fill differently (see the module header
  ## of ``apps/repro-client/repro_client.nim``): the full client derives it by
  ## parsing the build target, and the thin client leaves it empty so the
  ## daemon's ``workingDir`` fallback applies. Both runs below build the SAME
  ## project path, so a thin run that had fallen back would record the same
  ## ``projectRoot`` as the full run, and a thin run that was served records
  ## the working directory instead.
  let res = runShell(shellCommand(@[fullCliBin(), "daemon", "sessions",
    "--endpoint", endpoint, "--state-dir", tempRoot / "state"]), repoRoot())
  for raw in res.output.splitLines():
    let fields = raw.split('\t')
    if fields.len >= 5 and fields[1] == "build":
      result.add(fields[4])

proc buildArgs(projectRoot, tempRoot: string): seq[string] =
  @[
    "build", projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "work",
    "--action-cache-root=" & tempRoot / "ac",
    "--progress=quiet",
    "--log=summary",
    "--no-runquota"
  ]

proc freshProject(tempRoot: string): string =
  ## A COLD tree at a FIXED path. Both clients must build the same path, or
  ## the worktree identity differs and the comparison would be meaningless
  ## for a reason that has nothing to do with the client.
  let dest = tempRoot / "p"
  removeDir(dest)
  removeDir(tempRoot / "work")
  removeDir(tempRoot / "ac")
  createDir(tempRoot / "work")
  createDir(tempRoot / "ac")
  copyDir(fixtureSource(), dest)
  dest

## The fallback target for the routing tests. It is NOT a repro: its whole
## job is to record that it was reached and with which argv.
const FallbackMarker = "REPRO-CLIENT-HANDED-OVER"

proc writeFallbackScript(path: string) =
  writeFile(path,
    "#!/bin/sh\n" &
    "echo " & FallbackMarker & "\n" &
    "for a in \"$@\"; do echo \"ARG:$a\"; done\n" &
    "exit 23\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "MAC-1 thin daemon client":
  when isNixSupported:
    test "integration_thin_client_build_is_byte_identical_to_the_full_client":
      let tempRoot = createTempDir("repro-mac1-parity", "")
      let endpoint = daemonSocketEndpoint("mac1-parity")
      defer:
        stopDaemon(tempRoot, endpoint)
        removeDirEventually(tempRoot)
      createDir(tempRoot / "state")
      createDir(tempRoot / "store")
      let env = daemonEnv(tempRoot, endpoint)

      let projectFull = freshProject(tempRoot)
      let full = runCaptured(fullCliBin(), buildArgs(projectFull, tempRoot),
        tempRoot, env, EmbeddedSourceRootNames)
      checkpoint("full stdout:\n" & full.output)
      checkpoint("full stderr:\n" & full.errors)
      check full.code == 0
      let fullArtifact = readFile(projectFull / "dist" / "copied.txt")

      let projectThin = freshProject(tempRoot)
      let thin = runCaptured(thinCliBin(), buildArgs(projectThin, tempRoot),
        tempRoot, env, EmbeddedSourceRootNames)
      checkpoint("thin stdout:\n" & thin.output)
      checkpoint("thin stderr:\n" & thin.errors)
      check thin.code == 0

      # Byte equality, not "contains the same words". The provider-compile
      # cache key is printed on this stream, and a key that moves because of
      # which client asked is precisely the defect being gated.
      check thin.output == full.output
      check thin.errors == full.errors
      check readFile(projectThin / "dist" / "copied.txt") == fullArtifact

      # ...and the daemon really served BOTH of them. Without this the case
      # above is satisfied by a thin client that handed every invocation to
      # the full image; see `daemonBuildSessionProjectRoots`.
      let roots = daemonBuildSessionProjectRoots(tempRoot, endpoint)
      checkpoint("daemon build sessions: " & roots.join(" | "))
      check roots.len == 2
      if roots.len == 2:
        # Same project path built twice, two DIFFERENT recorded project roots:
        # the full client's parsed target and the thin client's working-dir
        # fallback. Equal roots means the same client composed both requests.
        check roots[0] != roots[1]

    test "integration_thin_client_falls_back_to_a_working_build_when_the_daemon_cannot_be_reached":
      let tempRoot = createTempDir("repro-mac1-fallback", "")
      defer: removeDirEventually(tempRoot)
      # An endpoint whose parent is a FILE: the daemon cannot be reached and
      # cannot be started there, and the failure is a real OS error rather
      # than a simulated one.
      let blocker = tempRoot / "blocker"
      writeFile(blocker, "not a directory\n")
      let endpoint = blocker / "repro-daemon.sock"
      createDir(tempRoot / "state")
      createDir(tempRoot / "store")
      let project = freshProject(tempRoot)
      let run = runCaptured(thinCliBin(), buildArgs(project, tempRoot),
        tempRoot, daemonEnv(tempRoot, endpoint))
      checkpoint("stdout:\n" & run.output)
      checkpoint("stderr:\n" & run.errors)
      # Handed over to the full image, which fell back to a direct build and
      # produced the artifact. Silently doing nothing, or exiting non-zero,
      # is the failure this gate exists for.
      check run.code == 0
      check fileExists(project / "dist" / "copied.txt")
      check readFile(project / "dist" / "copied.txt") == "direct-mode fixture\n"

  test "integration_thin_client_hands_over_every_invocation_it_must_not_serve":
    let tempRoot = createTempDir("repro-mac1-routing", "")
    defer: removeDirEventually(tempRoot)
    let fallback = tempRoot / "fallback.sh"
    writeFallbackScript(fallback)
    let baseEnv = @[
      ("REPRO_FULL_CLI", fallback),
      ("REPROBUILD_PROGRESS", "quiet")
    ]

    # Each entry is (label, extra argv, extra env). Every one of them is a
    # shape the full CLI either never routes to the daemon, or routes while
    # doing client-side work the thin client cannot reproduce.
    let cases = @[
      ("a verb that is not build", @["daemon", "status"],
        newSeq[(string, string)]()),
      ("no arguments at all", newSeq[string](),
        newSeq[(string, string)]()),
      ("--list-targets", @["build", ".", "--list-targets"],
        newSeq[(string, string)]()),
      ("--list-targets-json", @["build", ".", "--list-targets-json"],
        newSeq[(string, string)]()),
      ("--print-solved-graph", @["build", ".", "--print-solved-graph"],
        newSeq[(string, string)]()),
      ("--only", @["build", ".", "--only", "x"],
        newSeq[(string, string)]()),
      ("--daemon=off", @["build", ".", "--daemon=off"],
        newSeq[(string, string)]()),
      ("--daemon require (space form)", @["build", ".", "--daemon", "require"],
        newSeq[(string, string)]()),
      ("REPRO_DAEMON in the environment", @["build", "."],
        @[("REPRO_DAEMON", "auto")]),
      ("--write-benchmark", @["build", ".", "--write-benchmark=b.json"],
        newSeq[(string, string)]()),
      ("--write-stats", @["build", ".", "--write-stats"],
        newSeq[(string, string)]()),
      ("--stats-groups", @["build", ".", "--stats-groups=all"],
        newSeq[(string, string)]()),
      ("--progress-bars", @["build", ".", "--progress-bars=ascii"],
        newSeq[(string, string)]()),
      ("--progress with a non-quiet value", @["build", ".", "--progress=bar-line"],
        newSeq[(string, string)]()),
      ("progress not configured quiet anywhere", @["build", "."],
        @[("REPROBUILD_PROGRESS", "")])
    ]

    var index = 0
    for (label, extra, extraEnv) in cases:
      inc index
      # THE MARKER ALONE PROVES NOTHING, and an earlier version of this test
      # that checked only the marker passed under a mutation that deleted a
      # whole entry from the gate. With no daemon reachable, a client that
      # WRONGLY routed still ends at the fallback — it just gets there after
      # failing to reach a daemon. The two outcomes have to be told apart by
      # something only the routing path does, and creating the endpoint's
      # parent directory is that: `startUserDaemon` creates it before it
      # launches anything, and a rejected invocation never calls it.
      let runtimeDir = tempRoot / ("rt" & $index)
      let endpoint = runtimeDir / "repro-daemon.sock"
      check not dirExists(runtimeDir)
      let run = runCaptured(thinCliBin(), extra, tempRoot,
        baseEnv & extraEnv & @[("REPRO_DAEMON_ENDPOINT", endpoint),
          ("REPRO_DAEMON_STATE_DIR", tempRoot / ("st" & $index))])
      checkpoint("case: " & label & "\nstdout:\n" & run.output)
      # 23 and the marker both come from the fallback script, so a case that
      # passes here really did reach it.
      check run.code == 23
      check run.output.contains(FallbackMarker)
      # Rejected by the gate, not attempted and abandoned.
      checkpoint("case: " & label & " — runtime dir must not exist")
      check not dirExists(runtimeDir)
      # argv must cross unchanged: a launcher that edits the command line is
      # a launcher that can change the answer.
      for arg in extra:
        check run.output.contains("ARG:" & arg)

  test "integration_thin_client_routes_a_plain_quiet_build":
    let tempRoot = createTempDir("repro-mac1-routes", "")
    defer: removeDirEventually(tempRoot)
    let fallback = tempRoot / "fallback.sh"
    writeFallbackScript(fallback)
    # No daemon is reachable here, so the client will still end up handing
    # over — but only AFTER it has tried the daemon. What this test pins is
    # that the gate itself accepts the shape: with an endpoint that cannot
    # be created, the attempt fails and the marker appears, whereas a gate
    # that rejected the shape would print the marker without ever looking at
    # REPRO_DAEMON_ENDPOINT. Distinguish the two by pointing the endpoint at
    # a directory the client must try to create and observing the attempt.
    let stateDir = tempRoot / "state"
    createDir(stateDir)
    let endpoint = tempRoot / "runtime" / "repro-daemon.sock"
    let run = runCaptured(thinCliBin(), @["build", ".", "--progress=quiet"],
      tempRoot,
      @[("REPRO_FULL_CLI", fallback),
        ("REPRO_DAEMON_ENDPOINT", endpoint),
        ("REPRO_DAEMON_STATE_DIR", stateDir),
        ("REPROBUILD_PROGRESS", "")])
    checkpoint("stdout:\n" & run.output & "\nstderr:\n" & run.errors)
    check run.code == 23
    check run.output.contains(FallbackMarker)
    # The client reached `startUserDaemon`, which creates the endpoint's
    # parent directory before it launches anything. A gate that rejected
    # this shape would have exec'd the fallback with no daemon work at all
    # and this directory would not exist.
    check dirExists(tempRoot / "runtime")

  test "integration_thin_client_does_not_link_the_build_engine":
    # The milestone's whole premise. `repro` is ~16 MB with ~12,000
    # dynamic-linker fixups because it carries the engine, the DSL runtime
    # and their closure; the thin client must carry the daemon protocol and
    # nothing else. Both checks below fail the moment
    # `apps/repro-client/repro_client.nim` imports `repro_cli_support`.
    check fileExists(thinCliBin())
    let thinSize = getFileSize(thinCliBin())
    let fullSize = getFileSize(fullCliBin())
    checkpoint("thin=" & $thinSize & " full=" & $fullSize)
    check thinSize * 8 < fullSize
    # A string only the scheduler emits. Present in `repro`, and its
    # appearance here would mean the engine came along.
    let image = readFile(thinCliBin())
    check not image.contains("scheduler: actions=")
    check readFile(fullCliBin()).contains("scheduler: actions=")
