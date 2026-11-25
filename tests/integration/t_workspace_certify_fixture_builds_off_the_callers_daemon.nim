## The workspace certify fixture builds in an environment it owns, never in
## the caller's per-user daemon: a test chooses its own daemon route, because
## the resident daemon's image, groups and state belong to someone else.
##
## ``reproIn`` used to run the built ``repro`` with the inherited environment
## plus the daemon key and ``PATH``, so a ``repro build`` / ``repro test`` it
## ran went to whatever daemon that environment named. Run by hand on a
## workstation, outside ``just test`` (whose runner exports a private
## ``REPRO_DAEMON_ENDPOINT``), that was the developer's resident daemon, and
## ``t_repro_test_selects_the_collection_beside_a_test_directory`` failed with
## "daemon-hosted build failed: Permission denied".
##
## This test is the hostile caller: before the fixture is set up, it points
## ``REPRO_DAEMON`` at ``require`` and the daemon endpoint and state directory
## at paths under a regular file, where no daemon can be reached or started.
## A fixture ``repro`` that consulted the caller's daemon fails; one that
## builds in its own process tree succeeds and executes the edge. It holds
## ``reproIn`` (``repro build``, and ``repro test --no-certify``, the step
## that failed in the issue) and ``reproInEnv``. Removing ``REPRO_DAEMON=off``
## from ``ownDaemonEnv`` turns all three red with "daemon mode required but
## repro-daemon is unavailable". A last certifying ``repro test`` checks that
## the fixture still certifies in that environment.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and monitor. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, unittest]
import repro_test_support/scoped_env
import repro_test_support/reasoned_skip
import ./lock_update_node_fixture

suite "the workspace certify fixture owns its daemon":

  test "t_workspace_certify_fixture_builds_off_the_callers_daemon":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      # A regular file: nothing can create a socket or a directory under it.
      let blocker = getTempDir() /
        ("repro-not-a-directory-" & $getCurrentProcessId())
      writeFile(blocker, "")
      defer: removeFile(blocker)
      let hostile {.used.} = scopedEnv([
        (name: "REPRO_DAEMON", value: "require"),
        (name: "REPRO_DAEMON_ENDPOINT", value: blocker / "d.sock"),
        (name: "REPRO_DAEMON_STATE_DIR", value: blocker / "state")])
      var fx = setupWorkspaceCertifyFixture("own-daemon", ["unit_a"],
        "    discard aggregate(\"test\", @[unit_a])\n")
      defer: removeDir(fx.cf.sib.scratch)
      let content = fx.contentNow()

      let built = fx.reproIn(["build", "--tool-provisioning=path", "test"])
      checkpoint(built.output)
      check built.code == 0
      check fx.executedOutputs().len == 1

      writeFile(fx.app / "src" / "unit_a.txt", "unit_a v2\n")
      let rebuilt = fx.reproInEnv(["build", "--tool-provisioning=path",
        "test"], [])
      checkpoint(rebuilt.output)
      check rebuilt.code == 0
      check fx.executedOutputs().len == 2

      writeFile(fx.app / "src" / "unit_a.txt", "unit_a v3\n")
      let uncertified = fx.reproIn(["test", "--no-certify",
        "--tool-provisioning=path"])
      checkpoint(uncertified.output)
      check uncertified.code == 0
      check fx.executedOutputs().len == 3

      writeFile(fx.app / "src" / "unit_a.txt", "unit_a v1\n")
      let certified = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint(certified.output)
      check certified.code == 0
      check fx.certificatesFor(content, "test").len == 1
