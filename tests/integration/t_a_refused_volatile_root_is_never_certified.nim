## `repro certify` and `repro test` on a project whose root is `/dev/shm`
## itself refuse it, say why, run nothing and issue no certificate. On a
## workspace member seen at a second path, which the build accepts, issuance
## withholds the certificate and says that the checkout is not one the
## workspace declares.
##
## Such a root cannot be fingerprinted: in `/dev/shm` a project file and a
## POSIX shared-memory object are the same shape of path, so the
## volatile-path fold would drop the project's reads and a certificate would
## name content no run tested. The engine refuses the build
## (`volatileRootRefusals`); this grades that the refusal reaches both
## issuing verbs and stops issuance, not only `repro build`.
##
## The second path is why the refused layout issued nothing even with the
## refusal removed. Issuance reuses the workspace publication gate, and the
## gate identifies the repository being certified among the workspace's
## declared checkouts by path. A bind mount is a second path to `app`, so
## the gate refuses it (`current-repo-identity`). Issuance used to report
## that as "repo not at the locked revision", with the gate's push remedy
## (`repro hooks ensure --vcs <path>`, "before retrying the push"), which is
## false: nothing was off-lock. It now names the cause and an issuance remedy.
##
## NO MOCKS: the certifying workspace (`certify_workspace_mode_fixture`): real
## repositories, a registered daemon signing key, the built `repro`, the real
## provider and engine. `app` is seen at `/dev/shm`, or at `/run/lock/<name>`,
## through a bind mount in a user and mount namespace of its own
## (`unshare -rm`, then a nested user namespace mapping back to the real uid
## so `repro` does not run as root). POSITIVE CONTROL: `repro certify` on the
## same `app` at its real path issues its certificate. Skip rule: Linux with
## unprivileged user and mount namespaces, `git` and `ssh-keygen`.
##
## Falsifiability, measured: removing the `volatileRootRefusals` call from
## `runBuild` fails every refusal check of the first case: both verbs run the
## edge and exit 0, withholding the certificate for the second-path reason
## above. Mapping `current-repo-identity` back to the off-lock kind fails the
## second case's message checks.

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

proc reproSeenAt(fx: WorkspaceCertifyFixture; mounts, seen: string;
                 args: openArray[string]): tuple[code: int; output: string] =
  ## The built `repro <args>` run in `seen`, after `mounts` (run as root of a
  ## fresh user and mount namespace) made `app` visible there, with the tool
  ## on `PATH` and the daemon key handed to issuance.
  when defined(posix):
    var env = daemonKeyEnv(fx.cf.daemonKey, certifyKeyId)
    env.add((name: "PATH", value: fx.binDir & $PathSep & getEnv("PATH")))
    var command = "cd " & quoteShell(seen) & " &&"
    # The recipe compile's C and Nim compilers, named explicitly. Otherwise
    # they are provisioned through the per-user Nix daemon, which runs
    # OUTSIDE the namespace and cannot see the private mount.
    for (name, exe) in [("REPRO_BOOTSTRAP_CC", "cc"),
                        ("REPRO_NIM_COMPILER", "nim")]:
      if findExe(exe).len > 0:
        command.add(" " & name & "=" & quoteShell(findExe(exe)))
    for item in env:
      command.add(" " & item.name & "=" & quoteShell(item.value))
    command.add(" " & quoteShell(fx.cf.sib.repro))
    for arg in args:
      command.add(" " & quoteShell(arg))
    let outer = mounts & " && " &
      "exec unshare --map-user=" & $getuid() & " --map-group=" & $getgid() &
      " sh -c " & quoteShell(command)
    let res = execCmdEx("unshare -rm sh -c " & quoteShell(outer) & " 2>&1")
    (code: res.exitCode, output: res.output)
  else:
    (code: -1, output: "")

proc reproAtDevShm(fx: WorkspaceCertifyFixture;
                   args: openArray[string]): tuple[code: int; output: string] =
  ## `app` bind-mounted over `/dev/shm` itself, and run there.
  fx.reproSeenAt("mount --bind " & quoteShell(fx.app) & " /dev/shm",
    "/dev/shm", args)

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

  test "a member certified at a second path is withheld, and issuance says the checkout is not one the workspace declares":
    let reason = namespaceReason()
    if reason.len > 0:
      skip(reason)
    elif not dirExists("/run/lock"):
      skip("needs an existing /run/lock to mount a tmpfs on")
    elif findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("needs git and ssh-keygen; this test signs certificates in real " &
        "repositories")
    else:
      var fx = setupWorkspaceCertifyFixture("second-path", ["side"],
        buildLines)
      defer: removeDir(fx.cf.sib.scratch)
      # A directory of its own under `/run`, so the build accepts the root;
      # only the path differs from the checkout the workspace declares.
      let seen = "/run/lock/repro-second-path-app"
      let mounts = "mount -t tmpfs tmpfs /run/lock && mkdir " &
        quoteShell(seen) & " && mount --bind " & quoteShell(fx.app) & " " &
        quoteShell(seen)
      let res = fx.reproSeenAt(mounts, seen, ["certify",
        "--tool-provisioning=path", "--workspace-root=" & fx.cf.sib.ws,
        "--current-repo=" & seen])
      checkpoint(res.output)
      # The run completes and the tests still run; only the certificate is
      # withheld, with the cause and a remedy for certifying, not pushing.
      check res.code == 0
      check fx.executedOutputs().len == 1
      check fx.storedCount() == 0
      check ("no certificate — this checkout is not a repository the " &
        "workspace declares (" & seen & ")") in res.output
      check "certify from the workspace's own checkout" in res.output
      check "repo not at the locked revision" notin res.output
      check "before retrying the push" notin res.output
