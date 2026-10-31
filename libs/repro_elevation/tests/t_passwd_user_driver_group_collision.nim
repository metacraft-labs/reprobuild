## The `passwd.user` driver's decisions when a group named like the new
## account already exists (System-Profile-And-Infra-Apply.md, `passwd.user`).
##
## rpi2, 2026-10-30, reprobuild d7c86107b: `passwdGroup("nut")` applied first,
## then `useradd nut` failed with "group nut exists - if you want to add this
## user to that group, use -g" (Debian's `USERGROUPS_ENAB yes`). The driver
## now passes `--gid <name>` when the account declares membership in that
## group, refuses when it does not, and on a host where the group does not
## exist (or where `USERGROUPS_ENAB no` never creates one) runs the same plain
## `useradd` it always did.
##
## MOCK JUSTIFICATION. The account commands (`getent`, `id`, `useradd`) go to
## a recording runner (`passwdArgvRunner`, the driver's test seam) instead of
## the host. Running them for real needs root and creates and deletes
## accounts on the machine running the tests, which a unit test must never
## do. What is under test is the driver's own logic: which commands it runs,
## with which argv, what it refuses, and how it reads the post-apply
## observation. The runner answers with the exact text the real commands
## print. The real-account route is the disposable-host `test-buildusers`
## gate and the rpi2 deploy-agent tick.

import std/[strutils, unittest]

import repro_elevation/errors
import repro_elevation/operations
import repro_elevation/posix_system_driver

type FakeHost = ref object
  groupExists: bool
  created: bool
  createArgs: seq[string]
  calls: seq[string]

proc install(h: FakeHost) =
  passwdArgvRunner = proc (exe: string; args: seq[string]):
      tuple[output: string; code: int] {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      h.calls.add(exe & " " & args.join(" "))
      case exe
      of "getent":
        if args[0] == "group":
          if h.groupExists: return ("nut:x:1002:\n", 0)
          return ("", 2)
        if args[0] == "passwd":
          if h.created:
            return ("nut:x:999:1002::/nonexistent:/usr/sbin/nologin\n", 0)
          return ("", 2)
      of "id":
        # What `id` prints for an account whose primary group is `nut`
        # (created with --gid) or a fresh private group `nut`.
        if args[0] == "-nG": return ("nut\n", 0)
        if args[0] == "-gn": return ("nut\n", 0)
      of "useradd":
        h.created = true
        h.createArgs = args
        return ("", 0)
      else: discard
      ("unexpected command " & exe, 127)

proc userOp(groups: seq[string]): PrivilegedOperation =
  PrivilegedOperation(kind: pokPasswdUser, address: "nutUser",
    puName: "nut", puShell: "/usr/sbin/nologin", puGroups: groups)

when defined(linux):
  suite "passwd.user driver: an existing same-named group":
    teardown:
      passwdArgvRunner = nil

    test "declared: the group becomes the primary and the account converges":
      let h = FakeHost(groupExists: true)
      h.install()
      let r = applyPasswdUser(userOp(@["nut"]))
      check r.present
      check h.createArgs == @["nut", "--shell", "/usr/sbin/nologin",
        "--gid", "nut"]

    test "undeclared: refused, and useradd never runs":
      let h = FakeHost(groupExists: true)
      h.install()
      expect EProtocol:
        discard applyPasswdUser(userOp(@[]))
      check not h.created
      for c in h.calls: check not c.startsWith("useradd")

    test "no such group (USERGROUPS_ENAB no, or none yet): plain useradd":
      let h = FakeHost(groupExists: false)
      h.install()
      discard applyPasswdUser(userOp(@["nut"]))
      check h.createArgs == @["nut", "--shell", "/usr/sbin/nologin",
        "--groups", "nut"]
else:
  echo "passwd.user driver group-collision cases are Linux-only (useradd)"
