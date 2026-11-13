## `repro certify` and `repro test` on a project whose root is `/dev/shm`
## itself refuse it, say why, run nothing and issue no certificate.
##
## Such a root cannot be fingerprinted: in `/dev/shm` a project file and a
## POSIX shared-memory object are the same shape of path, so the
## volatile-path fold would drop the project's reads and a certificate would
## name content no run tested. The engine refuses the build
## (`volatileRootRefusals`); this grades that the refusal reaches both
## issuing verbs and stops issuance, not only `repro build`.
##
## NO MOCKS: the certifying workspace (`certify_workspace_mode_fixture`): real
## repositories, a registered daemon signing key, the built `repro`, the real
## provider and engine. `app` is seen at `/dev/shm` through a bind mount in a
## user and mount namespace of its own (`unshare -rm`, then a nested user
## namespace mapping back to the real uid so `repro` does not run as root).
## POSITIVE CONTROL: `repro certify` on the same `app` at its real path issues
## its certificate. Skip rule: Linux with unprivileged user and
## mount namespaces, `git` and `ssh-keygen`.
##
## Falsifiability, measured: removing the `volatileRootRefusals` call from
## `runBuild` fails every refusal check below. Both verbs then run the edge
## and exit 0. They still issue nothing at `/dev/shm`, for a reason this test
## does not establish (the layout is a workspace member seen at a second
## path), so the zero certificate count there is a guard only; the refusal
## and "nothing ran" are what is graded.

import std/[os, osproc, strutils, unittest]

when defined(posix):
  import std/posix

import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_workspace_mode_fixture

const buildLines =
  "    certificate \"side-suite\", side\n" &
  "    discard aggregate(\"test\", @[side])\n"

proc namespaceReason(): string =
  ## "" when this host lets an unprivileged user bind-mount over `/dev/shm`
  ## in a namespace of its own and map back to its real uid.
  when not defined(linux):
    "needs Linux user and mount namespaces"
  else:
    if findExe("unshare").len == 0:
      return "needs unshare(1) for a private mount"
    let probe = execCmdEx("unshare -rm sh -c " & quoteShell(
      "mount -t tmpfs tmpfs /dev/shm && exec unshare --map-user=" &
      $getuid() & " --map-group=" & $getgid() & " true") & " 2>&1")
    if probe.exitCode != 0:
      return "this host does not allow an unprivileged user and mount " &
        "namespace (unshare -rm): " & probe.output.strip()
    ""

proc reproAtDevShm(fx: WorkspaceCertifyFixture;
                   args: openArray[string]): tuple[code: int; output: string] =
  ## The built `repro <args>` with `app` bind-mounted at `/dev/shm` and run
  ## there, with the tool on `PATH` and the daemon key handed to issuance.
  when defined(posix):
    var env = daemonKeyEnv(fx.cf.daemonKey, certifyKeyId)
    env.add((name: "PATH", value: fx.binDir & $PathSep & getEnv("PATH")))
    var command = "cd /dev/shm &&"
    for item in env:
      command.add(" " & item.name & "=" & quoteShell(item.value))
    command.add(" " & quoteShell(fx.cf.sib.repro))
    for arg in args:
      command.add(" " & quoteShell(arg))
    let outer = "mount --bind " & quoteShell(fx.app) & " /dev/shm && " &
      "exec unshare --map-user=" & $getuid() & " --map-group=" & $getgid() &
      " sh -c " & quoteShell(command)
    let res = execCmdEx("unshare -rm sh -c " & quoteShell(outer) & " 2>&1")
    (code: res.exitCode, output: res.output)
  else:
    (code: -1, output: "")

suite "a refused volatile root is never certified":
  test "repro certify and repro test at /dev/shm refuse it and issue nothing; the same app elsewhere is certified":
    let reason = namespaceReason()
    if reason.len > 0:
      skip(reason)
    elif findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("needs git and ssh-keygen; this test signs certificates in real " &
        "repositories")
    else:
      var fx = setupWorkspaceCertifyFixture("refused-root", ["side"],
        buildLines)
      defer: removeDir(fx.cf.sib.scratch)
      let workspace = "--workspace-root=" & fx.cf.sib.ws

      for verb in [@["certify"], @["test", "--certify"]]:
        let res = fx.reproAtDevShm(verb & @["--tool-provisioning=path",
          workspace, "--current-repo=/dev/shm"])
        checkpoint("repro " & verb.join(" ") & ":\n" & res.output)
        check res.code != 0
        check "refusing to build" in res.output
        check "the project root /dev/shm" in res.output
        check "flat namespace of runtime objects" in res.output
        check fx.executedOutputs().len == 0
        check fx.storedCount() == 0

      # The positive control: the same app at its own path is certified.
      let control = fx.reproIn(["certify", "--tool-provisioning=path"])
      checkpoint("control:\n" & control.output)
      check control.code == 0
      check fx.executedOutputs().len == 1
      check fx.certificatesFor(fx.contentNow(), "side-suite").len == 1
