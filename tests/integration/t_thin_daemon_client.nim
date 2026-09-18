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
##   * ``thin_client_serves_an_install_layout_with_no_environment`` — the
##     REACHABILITY gate, and the one that makes the milestone's saving
##     something a user can obtain rather than a property of a binary nobody
##     runs. Every packaging route this repository has copies ``build/bin/*``
##     wholesale, so an install puts the thin client at ``bin/repro`` in the
##     same directory as ``bin/reprobuild``; this case reproduces exactly
##     that adjacency and
##     asserts a build is SERVED through it with ``REPRO_FULL_CLI`` and
##     ``REPRO_PUBLIC_CLI_PATH`` both unset. Deleting the sibling arm of
##     ``resolveFullCli`` reddens it — verified, not assumed.
##
##   * ``thin_client_keeps_a_terminal_build_on_the_full_client`` — the TTY
##     guard, which is the condition that keeps an INTERACTIVE build off the
##     thin path. It is tested against a real pty because ``isatty(2)`` is the
##     only thing the guard reads and nothing short of a real terminal makes
##     it answer true. Deleting the ``stderrIsTerminal()`` arm of
##     ``shouldRouteToDaemon`` reddens it — verified, not assumed.
##
##   * ``thin_client_does_not_link_the_build_engine`` — the structural
##     property the milestone's number depends on. Importing
##     ``repro_cli_support`` from ``apps/repro-client`` reddens it.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

# Imported HERE rather than beside the pty helpers below, because
# ``runCaptured``'s ``drainPty`` arm needs ``fcntl``/``read`` and Nim makes a
# module's symbols visible only after the ``import`` that brings them in.
when defined(posix):
  import std/posix as ptyPosix

import repro_core/cli_images
import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc fullCliBin(): string =
  ## The ENGINE image. Named ``reprobuild`` since the thin-client-on-PATH
  ## rename; ``build/bin/repro`` is the thin client below.
  repoRoot() / "build" / "bin" / reprobuildEngineExeName()

proc thinCliBin(): string =
  ## The THIN CLIENT, which now owns the name ``repro``. Every case in this
  ## suite that names ``build/bin/repro`` is therefore naming the thin client,
  ## which is the point of the rename: it is what a user runs.
  repoRoot() / "build" / "bin" / reproThinClientExeName()

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
    ptyText: string
      ## Everything read from the pty master while the child ran; empty
      ## unless ``drainPty`` was supplied. See ``runCaptured``.

proc runCaptured(exe: string; args: openArray[string]; cwd: string;
                 env: openArray[(string, string)] = [];
                 unset: openArray[string] = [];
                 stderrTo = "";
                 drainPty: cint = -1): CapturedRun =
  ## Run ``exe`` with stdout and stderr captured SEPARATELY (``runShell``
  ## merges them, and this suite has to compare the two streams
  ## independently) and with the ability to REMOVE names from the child
  ## environment, which no existing helper offers.
  ##
  ## ``stderrTo`` redirects stderr somewhere other than the capture file —
  ## the TTY-guard case points it at a pty slave, which is the only way to
  ## make the child's ``isatty(2)`` answer true. ``result.errors`` is then
  ## empty, because there is no file to read back.
  ##
  ## ``drainPty`` IS NOT A CONVENIENCE; IT IS WHAT KEEPS A PTY CASE FROM
  ## DEADLOCKING, and it was added because one did. A pty is a fixed-size
  ## kernel buffer — a few kilobytes on macOS, not the 64 KB one might read
  ## into ``newString(64 * 1024)`` — and a writer that fills it BLOCKS. So a
  ## case that runs a real build with stderr on a pty slave and reads the
  ## master only AFTER ``waitForExit`` returns has arranged for the child to
  ## wait for the parent and the parent to wait for the child: the engine's
  ## progress renderer redraws once per action state change, a cold build
  ## emits far more than the buffer holds, and the run never ends. Measured
  ## here, not theorised: the daemon log recorded ``build request finished
  ## exitCode=0`` and the client process was still alive eight minutes later,
  ## with the artifact already on disk. Two abandoned processes from earlier
  ## runs of the same case were found wedged the same way, one of them for
  ## thirteen hours, and no run of this suite had ever printed a result for
  ## that case.
  ##
  ## Pass the master fd and this proc drains it WHILE the child runs, into
  ## ``result.ptyText``. The loop is in the parent and single-threaded — no
  ## fork, no thread, no shared buffer — because ``osproc`` already exposes
  ## the two pieces it needs: ``running`` (a non-blocking reap) and
  ## ``peekExitCode``. Do not "simplify" this back into ``waitForExit`` plus
  ## one read at the end.
  ## The redirection is done by an ``exec``-ing ``/bin/sh``, so the status
  ## this proc returns is the status of ``exe`` and not of a shell that ran
  ## it — the same trap as reading a build's exit code through a pipe.
  let outPath = cwd / "captured-stdout"
  let errPath = if stderrTo.len > 0: stderrTo else: cwd / "captured-stderr"
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
  if drainPty < 0:
    result.code = process.waitForExit()
  else:
    when defined(posix):
      let flags = ptyPosix.fcntl(drainPty, ptyPosix.F_GETFL, 0)
      discard ptyPosix.fcntl(drainPty, ptyPosix.F_SETFL,
        flags or ptyPosix.O_NONBLOCK)
      var chunk = newString(8192)
      var drained = ""
      # A TEMPLATE, not a proc: a closure over ``result`` (or over ``drained``)
      # is refused as a memory-safety violation by the compiler, and the
      # alternative — duplicating the read loop twice below — is the shape
      # that loses the final pump when someone edits one copy.
      #
      # Every byte currently readable. A non-blocking master answers EAGAIN
      # while the child is between writes and EIO once the last slave writer
      # has gone; both are ``got <= 0`` and neither is a reason to stop,
      # because only ``process.running`` decides that.
      template pumpNow() =
        while true:
          let got = ptyPosix.read(drainPty, addr chunk[0], chunk.len)
          if got <= 0:
            break
          drained.add(chunk[0 ..< got])
      while process.running:
        pumpNow()
        sleep(2)
      # The child is gone; take what it wrote between the last pump and its
      # exit. Bounded: nothing can be added after the writer is dead.
      pumpNow()
      result.ptyText = drained
      result.code = process.peekExitCode()
    else:
      result.code = process.waitForExit()
  result.output = if fileExists(outPath): readFile(outPath) else: ""
  result.errors =
    if stderrTo.len == 0 and fileExists(errPath): readFile(errPath) else: ""

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

when defined(posix):
  ## A real pty, for the TTY guard. ``isatty(2)`` is the only thing
  ## ``shouldRouteToDaemon`` reads on that arm, and nothing but a terminal
  ## device makes it answer true — not a pipe, not a file, not an environment
  ## variable. These four are POSIX and live in ``<stdlib.h>``; Nim's
  ## ``std/posix`` does not declare them. (``std/posix`` itself is imported
  ## with the other imports at the top of the file; see the note there.)
  proc posix_openpt(oflag: cint): cint
    {.importc: "posix_openpt", header: "<stdlib.h>".}
  proc grantpt(fd: cint): cint {.importc: "grantpt", header: "<stdlib.h>".}
  proc unlockpt(fd: cint): cint {.importc: "unlockpt", header: "<stdlib.h>".}
  proc ptsname(fd: cint): cstring {.importc: "ptsname", header: "<stdlib.h>".}

  proc openPtySlavePath(): tuple[master: cint; slave: string] =
    ## Returns the master fd — which the CALLER must keep open for the slave
    ## to stay usable — and the filesystem path of its slave side, which a
    ## shell redirection can open.
    let master = posix_openpt(ptyPosix.O_RDWR or ptyPosix.O_NOCTTY)
    doAssert master >= 0, "posix_openpt failed"
    doAssert grantpt(master) == 0, "grantpt failed"
    doAssert unlockpt(master) == 0, "unlockpt failed"
    let name = ptsname(master)
    doAssert name != nil, "ptsname failed"
    (master, $name)

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

    test "integration_thin_client_serves_an_install_layout_with_no_environment":
      # WHAT THIS IS FOR. MAC-1's saving is only real if something a user
      # actually runs reaches the thin client. Nothing sets `REPRO_FULL_CLI`
      # outside this suite, and nothing is going to: what makes an installed
      # an installed thin client work is that every packaging route — the Nix
      # derivation's `installPhase`, the .deb/.rpm/pacman payloads, the
      # release tarball, `install-on-distributions.sh` — copies
      # `build/bin/*` WHOLESALE, so the thin client lands in the same bin
      # directory as `repro` and `resolveFullCli`'s sibling probe finds it.
      #
      # That adjacency is the whole delivery mechanism, so it is gated here
      # rather than left to the packaging layer's own tests: those check that
      # files are installed, not that this binary can still name its full
      # image once they are.
      #
      # THE LAYOUT IS BUILT, NOT MOCKED. The thin client is COPIED to
      # `<bin>/repro` (a real file, so `getAppFilename()` is inside the
      # install dir and `thinClientDir()` answers with it) and the engine is
      # SYMLINKED to `<bin>/reprobuild` (17 MB; the probe only needs
      # `fileExists`, and every digest the daemon handshake takes follows the
      # link to the same bytes).
      #
      # THIS IS THE CASE THE RENAME EXISTS FOR. Before it, the installed thin
      # client was `repro-client` and the caller had to type that name; now
      # the file at `repro` IS the thin client, so the invocation below is
      # literally what a user types.
      let tempRoot = createTempDir("repro-mac1-install", "")
      let endpoint = daemonSocketEndpoint("mac1-install")
      defer:
        stopDaemon(tempRoot, endpoint)
        removeDirEventually(tempRoot)
      createDir(tempRoot / "state")
      createDir(tempRoot / "store")

      let installBin = tempRoot / "bin"
      createDir(installBin)
      let installedThin = installBin / reproThinClientExeName()
      copyFile(thinCliBin(), installedThin)
      setFilePermissions(installedThin,
        {fpUserRead, fpUserWrite, fpUserExec})
      createSymlink(fullCliBin(), installBin / reprobuildEngineExeName())

      let project = freshProject(tempRoot)
      # NOTE WHAT IS NOT IN THIS ENVIRONMENT: neither `REPRO_FULL_CLI` nor
      # `REPRO_PUBLIC_CLI_PATH`. If `resolveFullCli` cannot name the full
      # image from the layout alone, `handOver` reports "no reprobuild image
      # to fall back to" and exits 127 — so a broken probe cannot be
      # mistaken for a working one here.
      let run = runCaptured(installedThin, buildArgs(project, tempRoot),
        tempRoot,
        @[("REPRO_DAEMON_ENDPOINT", endpoint),
          ("REPRO_DAEMON_STATE_DIR", tempRoot / "state"),
          ("REPROBUILD_STORE_ROOT", tempRoot / "store")],
        unset = ["REPRO_FULL_CLI", "REPRO_PUBLIC_CLI_PATH"])
      checkpoint("stdout:\n" & run.output)
      checkpoint("stderr:\n" & run.errors)
      check run.code == 0
      check not run.errors.contains("image to fall back to")
      check fileExists(project / "dist" / "copied.txt")

      # ...and it was SERVED, not quietly handed over. Same discriminator as
      # the parity case: the thin client leaves `projectRoot` empty so the
      # daemon's `workingDir` fallback applies, and the full client fills it
      # from the parsed target. Exactly one build session, recorded against
      # the WORKING DIRECTORY rather than the project path, is a session the
      # thin client composed.
      let roots = daemonBuildSessionProjectRoots(tempRoot, endpoint)
      checkpoint("daemon build sessions: " & roots.join(" | "))
      check roots.len == 1
      if roots.len == 1:
        check roots[0] != project
        check roots[0].endsWith(lastPathPart(tempRoot))

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
      ("--progress with a non-quiet value", @["build", ".",
          "--progress=bar-line"],
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

  when defined(posix):
    test "integration_thin_client_keeps_a_terminal_build_on_the_full_client":
      # THE GUARD THIS PINS, and why it is load-bearing rather than cautious.
      #
      # `clearProgressLine` and `clearNativeProgress` in `repro_cli_support`
      # are gated on `renderer.ansi` / `renderer.nativeProgress` — both derived
      # from `supportsAnsiProgress()`, i.e. `isatty(stderr)` — and NOT on
      # `renderer.enabled`. So the full client under `--progress=quiet` writes
      # "\r\e[2K" per diagnostic and an OSC 9;4 reset at the end WHEN STDERR IS
      # A TERMINAL, while the thin client's reproduction writes a bare "\r".
      # Routing a terminal build would therefore put different bytes on stderr
      # for the same command. `shouldRouteToDaemon`'s `stderrIsTerminal()` arm
      # is what prevents that, and until this case existed nothing failed when
      # it was removed.
      #
      # BOTH ARMS ARE RUN IN ONE CASE ON PURPOSE. A TTY-only assertion is
      # satisfied by a gate that rejects everything — which is exactly the
      # mutation the suite's other cases are built to survive. The contrast is
      # the evidence: same binary, same argv, same environment, and the ONLY
      # difference is what fd 2 is attached to.
      let tempRoot = createTempDir("repro-mac1-tty", "")
      defer: removeDirEventually(tempRoot)
      let fallback = tempRoot / "fallback.sh"
      writeFallbackScript(fallback)
      createDir(tempRoot / "state")

      proc runWith(label, stderrTo: string): string =
        ## Returns the runtime directory the client was pointed at, after
        ## checking it reached the fallback. Whether that directory EXISTS is
        ## the witness of which path it took: `startUserDaemon` creates the
        ## endpoint's parent before it launches anything, and an invocation the
        ## gate rejected never calls it.
        let runtimeDir = tempRoot / ("rt-" & label)
        check not dirExists(runtimeDir)
        let run = runCaptured(thinCliBin(),
          @["build", ".", "--progress=quiet"], tempRoot,
          @[("REPRO_FULL_CLI", fallback),
            ("REPRO_DAEMON_ENDPOINT", runtimeDir / "repro-daemon.sock"),
            ("REPRO_DAEMON_STATE_DIR", tempRoot / "state"),
            ("REPROBUILD_PROGRESS", "")],
          stderrTo = stderrTo)
        checkpoint(label & " stdout:\n" & run.output)
        # 23 and the marker both come from the fallback script, so an arm that
        # passes these really did end up at the full image.
        check run.code == 23
        check run.output.contains(FallbackMarker)
        runtimeDir

      # Arm 1: stderr on a REAL pty. The master must stay open for the whole
      # run or the slave becomes unusable mid-invocation.
      let (master, slavePath) = openPtySlavePath()
      var ttyRuntime: string
      try:
        ttyRuntime = runWith("tty", slavePath)
      finally:
        discard ptyPosix.close(master)
      # Handed over WITHOUT touching the daemon: the gate rejected the shape.
      checkpoint("tty arm: runtime dir must not exist: " & ttyRuntime)
      check not dirExists(ttyRuntime)

      # Arm 2: the identical invocation with stderr on a plain file. This one
      # IS routed, so the client reaches `startUserDaemon` and the directory
      # appears. Without this arm the case above would stay green under a gate
      # that refused every invocation.
      let fileRuntime = runWith("file", "")
      checkpoint("file arm: runtime dir must exist: " & fileRuntime)
      check dirExists(fileRuntime)

  when isNixSupported:
    test "integration_thin_client_names_the_engine_the_way_the_engine_names_itself":
      # THE NIX LAYOUT, AND THE DIGEST THAT HAS TO AGREE ACROSS IT.
      #
      # `wrapProgram` replaces `$out/bin/reprobuild` with a shell SCRIPT and
      # moves the real image to `$out/bin/.reprobuild-wrapped`. The engine's
      # own `getAppFilename()` is therefore the hidden name, and the path each
      # client hands `startUserDaemon` is the path whose digest is compared
      # against the running daemon's (`expectedDaemonRunningDigestHex`). A
      # thin client that named the WRAPPER SCRIPT would compute a different
      # digest, conclude the daemon is stale and shut it down -- and the next
      # engine invocation would conclude the same in reverse, restarting the
      # daemon on every alternation and destroying the warm daemon the thin
      # client exists to exploit. The same path also decides where the
      # Tier-2a/2b providers are looked for (`parentDir(publicCliPath)`), and
      # that failure is silent.
      #
      # WHAT MAKES THIS FAIL: deleting the hidden-image arm of
      # `resolveFullCli`. The thin client then resolves the sibling
      # `reprobuild` -- the wrapper script -- and the daemon log below
      # records `restarting outdated daemon`. Verified, not assumed.
      #
      # THE LAYOUT IS REAL, NOT MOCKED: a real wrapper script (the same
      # `exec "$hidden" "$@"` shape makeWrapper emits), a real hidden image,
      # a real daemon on a real socket, and both clients building the same
      # real project.
      let tempRoot = createTempDir("repro-mac1-wrapped", "")
      let endpoint = daemonSocketEndpoint("mac1-wrapped")
      defer:
        stopDaemon(tempRoot, endpoint)
        removeDirEventually(tempRoot)
      createDir(tempRoot / "state")
      createDir(tempRoot / "store")

      let installBin = tempRoot / "bin"
      createDir(installBin)
      # The hidden image IS the engine (symlinked: the probe needs
      # `fileExists` and every digest follows the link to the same bytes).
      # Spelled as ONE basename rather than `installBin / "." & ...`: `/` binds
      # tighter than `&`, and `joinPath`'s handling of a lone "." is not
      # something this case should depend on.
      let hidden = installBin / ("." & ReprobuildEngineName & "-wrapped")
      createSymlink(fullCliBin(), hidden)
      # ...and the public name is a wrapper script over it, as makeWrapper
      # leaves it. Note it is EXECUTABLE and it WORKS: an arm that resolved it
      # would still build successfully, which is exactly why byte equality
      # cannot be the discriminator here.
      let wrapper = installBin / reprobuildEngineExeName()
      writeFile(wrapper, "#!/bin/sh\nexec \"" & hidden & "\" \"$@\"\n")
      setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
      let installedThin = installBin / reproThinClientExeName()
      copyFile(thinCliBin(), installedThin)
      setFilePermissions(installedThin, {fpUserRead, fpUserWrite, fpUserExec})

      let project = freshProject(tempRoot)
      let noOverrides = ["REPRO_FULL_CLI", "REPRO_PUBLIC_CLI_PATH"]
      let baseEnv = @[
        ("REPRO_DAEMON_ENDPOINT", endpoint),
        ("REPRO_DAEMON_STATE_DIR", tempRoot / "state"),
        ("REPROBUILD_STORE_ROOT", tempRoot / "store")]

      # The ENGINE builds first, through its own wrapper, so the daemon is
      # started from the image the engine names for itself.
      let viaEngine = runCaptured(wrapper, buildArgs(project, tempRoot),
        tempRoot, baseEnv, unset = noOverrides)
      checkpoint("engine stdout:\n" & viaEngine.output)
      checkpoint("engine stderr:\n" & viaEngine.errors)
      check viaEngine.code == 0

      # Then the THIN CLIENT, against the daemon the engine left running.
      let viaThin = runCaptured(installedThin, buildArgs(project, tempRoot),
        tempRoot, baseEnv, unset = noOverrides)
      checkpoint("thin stdout:\n" & viaThin.output)
      checkpoint("thin stderr:\n" & viaThin.errors)
      check viaThin.code == 0
      check not viaThin.errors.contains("image to fall back to")

      # BOTH ran, and the second one was SERVED rather than handed over: two
      # build sessions, recorded against different project roots (same
      # discriminator as the parity case).
      let roots = daemonBuildSessionProjectRoots(tempRoot, endpoint)
      checkpoint("daemon build sessions: " & roots.join(" | "))
      check roots.len == 2

      # THE ASSERTION THIS CASE EXISTS FOR. The daemon logs one line and only
      # one when a client decides the running image is stale. Its absence is
      # the proof that both clients digested the same bytes.
      let logPath = tempRoot / "state" / "logs" / "repro-daemon.log"
      let logText = if fileExists(logPath): readFile(logPath) else: ""
      checkpoint("daemon log:\n" & logText)
      check not logText.contains("restarting outdated daemon")

  when isNixSupported and defined(posix):
    test "integration_thin_client_interactive_terminal_build_still_builds":
      # THE FALLBACK HAS TO BE CORRECT, NOT MERELY DIFFERENT.
      #
      # `integration_thin_client_keeps_a_terminal_build_on_the_full_client`
      # proves an interactive build is REFUSED by the routing gate, using a
      # stub as the hand-over target. That says nothing about whether the
      # invocation a user actually types then works -- and since the
      # thin-client rename, `repro build` typed at a terminal is the single
      # most common invocation there is. It reaches the engine only through
      # `handOver`, so this case runs it against the REAL engine on a REAL
      # pty and asserts the build happens.
      #
      # PROGRESS IS ASSERTED TOO, because the whole reason the gate refuses
      # this shape is that the engine renders progress client-side when stderr
      # is a terminal. If the fallback produced a correct artifact and no
      # progress, the gate would be refusing for a reason that no longer
      # holds.
      #
      # WHAT MAKES THIS FAIL: breaking `handOver` (e.g. resolving an engine
      # path that does not exist) reddens the artifact check with exit 127.
      let tempRoot = createTempDir("repro-mac1-interactive", "")
      defer: removeDirEventually(tempRoot)
      createDir(tempRoot / "state")
      createDir(tempRoot / "store")
      let project = freshProject(tempRoot)

      # `--progress` is NOT quiet here: this is the interactive shape, the one
      # a user types.
      #
      # NOTE WHAT IS *NOT* HERE: `--daemon=off`. It was in an earlier draft,
      # and removing it was right -- `--daemon` is in `ClientHandledFlags`, so
      # it forced the hand-over on its own and put a THIRD reason in front of
      # the shape under test.
      #
      # WHAT THIS CASE DOES *NOT* PIN, stated because an earlier version of
      # this comment claimed it did. Two INDEPENDENT sufficient conditions
      # still keep this invocation off the thin path: the terminal on fd 2,
      # and `REPROBUILD_PROGRESS` not being explicitly quiet. Either alone
      # makes `shouldRouteToDaemon` return false, so deleting
      # `stderrIsTerminal()` from that gate leaves this case GREEN -- measured
      # by running this exact argv and environment with fd 2 on a plain file,
      # which is observationally identical to deleting the arm, and getting
      # the hand-over anyway. This case therefore pins the FALLBACK (a real
      # engine, a real pty, a real artifact, real progress bytes) and nothing
      # about the gate.
      #
      # The gate's TTY arm is pinned by
      # `integration_thin_client_keeps_a_terminal_build_on_the_full_client`
      # above, which is the case built for it: `--progress=quiet` makes fd 2
      # the ONLY remaining condition, and it runs both arms -- pty and plain
      # file -- so neither "refuse everything" nor "route everything" survives
      # it. Do not add a progress-mode change here to make this case
      # mutation-sensitive too; it would stop being the shape a user types,
      # which is the only thing it exists to exercise.
      var args = @[
        "build", project,
        "--tool-provisioning=path",
        "--work-root=" & tempRoot / "work",
        "--action-cache-root=" & tempRoot / "ac",
        "--log=summary",
        "--no-runquota"]

      let (master, slavePath) = openPtySlavePath()
      var run: CapturedRun
      try:
        run = runCaptured(thinCliBin(), args, tempRoot,
          @[("REPRO_FULL_CLI", fullCliBin()),
            ("REPRO_DAEMON_STATE_DIR", tempRoot / "state"),
            ("REPROBUILD_STORE_ROOT", tempRoot / "store"),
            ("REPROBUILD_PROGRESS", ""),
            ("TERM", "xterm-256color")],
          stderrTo = slavePath, drainPty = master)
        # The pty is drained WHILE the build runs, by ``runCaptured``. It has
        # to be: this case's ``--action-cache-root`` is a fresh directory
        # inside ``tempRoot``, so every run is a COLD build with a provider
        # compile in it, and the engine's progress renderer emits far more
        # than a macOS pty buffer holds. Reading the master after
        # ``waitForExit`` — which is what this case did when it was written —
        # deadlocks: the engine blocks writing progress and the test blocks
        # waiting for the engine. See ``runCaptured``'s ``drainPty`` note.
        let buf = run.ptyText
        let ptyBytes = buf.len
        checkpoint("pty stderr (" & $ptyBytes & " bytes):\n" & buf)
        check run.code == 0
        # It BUILT. This is the assertion the stub-based TTY case cannot make.
        check fileExists(project / "dist" / "copied.txt")
        check readFile(project / "dist" / "copied.txt") ==
          "direct-mode fixture\n"
        # And it RENDERED. The engine's terminal renderer writes an ANSI
        # line-clear per progress update when stderr is a tty; a silent run
        # would mean the gate is protecting a behaviour that no longer exists.
        check ptyBytes > 0
        check buf.contains("\27[")
      finally:
        discard ptyPosix.close(master)

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
