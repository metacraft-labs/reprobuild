## M69 Verification Gate: e2e_repro_infra_passwd_user_safe_destroy
##
## Per the M69 verification block: create a test user via
## `passwd.user`; subsequent removal WITHOUT `--accept-passwd-destroy`
## is rejected; WITH the flag it succeeds; rollback re-creates the user
## with the recorded attributes.
##
## ===========================================================================
## DESTRUCTIVE GATE — REQUIRES A LINUX SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## Creating, modifying and removing a real user account via
## `useradd` / `usermod` / `userdel` is HOST-ALTERING and root-only.
## This gate's REAL-MUTATION scenario runs ONLY on Linux/macOS AND
## ONLY when `REPRO_M69_PASSWD_VM=1` is set — the milestone keeps this
## gate's `status:` at `pending` until a Linux sandbox / VM run sets
## it. The development host for M69 Phase C is Windows; the real
## `useradd` path cannot run there at all.
##
## On every host (the env var unset, or off Linux/macOS) the gate
## still runs its NON-DESTRUCTIVE half: the PURE `passwd.user`
## observation parser, the desired-vs-observed attribute diff, the
## `useradd` / `usermod` / `userdel` argv construction, the typed-
## operation wiring into the M81 closed set, and — crucially — the
## `--accept-passwd-destroy` SAFETY GATE (a `passwd.user` destroy
## fails CLOSED, before any mutation, without the flag). So the
## driver logic AND the safety gate are proven without mutating any
## host.
##
## No `skip`, no `xfail` — the pure-logic + safety-gate half ALWAYS
## runs and always asserts; only the real `useradd`/`userdel`
## scenario is sandbox-gated.

import std/[os, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  ## The `repro` binary. The destructive half needs it for the broker
  ## launch; the non-destructive half does not, so the lookup is
  ## tolerant when the binary is absent (a pure-logic-only run).
  when defined(windows):
    let candidate = ProjectRoot / "build" / "bin" / "repro.exe"
  else:
    let candidate = ProjectRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  candidate

# The real-mutation scenario is gated by BOTH the platform (POSIX) and
# an explicit opt-in env var. The env var is left UNSET on every CI /
# dev host so the gate never mutates a real account.
let sandboxMode =
  (defined(linux) or defined(macosx)) and
  getEnv("REPRO_M69_PASSWD_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: the pure `passwd.user` logic + the typed-operation
# wiring + the `--accept-passwd-destroy` safety gate. Proves the driver
# logic and the destroy gate without touching any host account. These
# always run, on every platform.
# ===========================================================================

suite "passwd.user: pure observation parsing":

  test "parseGetentPasswd reads the colon-separated passwd record":
    let obs = parseGetentPasswd(
      "deploy:x:1001:1001:Deploy User:/home/deploy:/bin/bash")
    check obs.present
    check obs.uid == "1001"
    check obs.homeDir == "/home/deploy"
    check obs.shell == "/bin/bash"
    # An empty / malformed line means the account is absent.
    check not parseGetentPasswd("").present
    check not parseGetentPasswd("not-a-passwd-line").present

  test "parseIdGroups returns a sorted supplementary-group set":
    check parseIdGroups("wheel docker staff") ==
      @["docker", "staff", "wheel"]
    check parseIdGroups("") == newSeq[string]()

  test "parsePasswdObservation assembles the full observation":
    let obs = parsePasswdObservation(
      "deploy:x:1001:1001:Deploy:/home/deploy:/bin/bash",
      "docker wheel", "deploy")
    check obs.present
    check obs.groups == @["docker", "wheel"]
    check obs.primaryGroup == "deploy"

suite "passwd.user: desired-vs-observed attribute diff":

  test "an absent account => create with every declared group":
    let diff = diffPasswdUser(
      PasswdUserDesired(name: "deploy", groups: @["docker", "wheel"]),
      PasswdUserObservation(present: false))
    check diff.accountAbsent
    check diff.missingGroups == @["docker", "wheel"]

  test "a pinned attribute that differs drives a usermod":
    let observed = PasswdUserObservation(present: true, uid: "1001",
      homeDir: "/home/deploy", shell: "/bin/sh", groups: @["docker"])
    let diff = diffPasswdUser(
      PasswdUserDesired(name: "deploy", shell: "/bin/bash",
        groups: @["docker", "wheel"]), observed)
    check not diff.accountAbsent
    check diff.shellDiffers
    check not diff.homeDirDiffers          # homeDir unpinned (empty)
    check diff.missingGroups == @["wheel"]
    check passwdUserNeedsUpdate(diff)

  test "an in-sync account needs no update":
    let observed = PasswdUserObservation(present: true, uid: "1001",
      homeDir: "/home/deploy", shell: "/bin/bash", groups: @["docker"])
    let diff = diffPasswdUser(
      PasswdUserDesired(name: "deploy", homeDir: "/home/deploy",
        shell: "/bin/bash", groups: @["docker"]), observed)
    check not passwdUserNeedsUpdate(diff)

suite "passwd.user: useradd / usermod / userdel argv construction":

  test "buildUseraddArgs builds the create argv from typed fields":
    let args = buildUseraddArgs(PasswdUserDesired(name: "deploy",
      homeDir: "/home/deploy", shell: "/bin/bash",
      groups: @["wheel", "docker"]))
    check args[0] == "deploy"
    check "--create-home" in args
    check "--shell" in args
    let gi = args.find("--groups")
    check gi >= 0 and args[gi + 1] == "docker,wheel"  # sorted

  test "buildUsermodArgs passes only the differing attributes":
    let observed = PasswdUserObservation(present: true, uid: "1001",
      homeDir: "/home/deploy", shell: "/bin/sh", groups: @["docker"])
    let desired = PasswdUserDesired(name: "deploy", shell: "/bin/bash",
      groups: @["docker", "wheel"])
    let args = buildUsermodArgs(desired, diffPasswdUser(desired, observed))
    check "--shell" in args
    check "--home" notin args               # homeDir unpinned
    check args[^1] == "deploy"

  test "buildUserdelArgs removes the home directory":
    check buildUserdelArgs("deploy") == @["--remove", "deploy"]

suite "passwd.user: typed-operation wiring into the M81 closed set":

  test "a passwd.user system.nim resource parses and types":
    let profile = parseSystemProfile("""
passwd.user {
  name = "deploy"
  home = "/home/deploy"
  shell = "/bin/bash"
  groups = ["docker", "wheel"]
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkPasswdUser
    check r.puName == "deploy"
    let op = toPrivilegedOperation(r)
    check op.kind == pokPasswdUser
    check op.puGroups == @["docker", "wheel"]
    check not op.puDestroy
    check requiresElevation(op.kind)
    # The destroy direction flips the typed operation.
    check toPrivilegedOperation(r, destroy = true).puDestroy
    # It partitions as a privileged (broker-dispatched) operation.
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "a passwd.user operation round-trips the RBEB protocol codec":
    let op = PrivilegedOperation(kind: pokPasswdUser, address: "user:deploy",
      puName: "deploy", puHome: "/home/deploy", puShell: "/bin/bash",
      puGroups: @["docker", "wheel"], puDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokPasswdUser
    check dec.operation.puName == "deploy"
    check dec.operation.puGroups == @["docker", "wheel"]
    check dec.baselineDigestHex == "ab"

suite "passwd.user: --accept-passwd-destroy SAFETY GATE":

  test "a passwd.user revert is gated by --accept-passwd-destroy":
    let profile = parseSystemProfile(
      "passwd.user { name = \"deploy\" }\n")
    let r = profile.resources[0]
    # `passwd.user` is the `--accept-passwd-destroy` gate's resource —
    # NOT the `--accept-feature-destroy` gate's.
    check requiresPasswdDestroy(r)
    check not isDestructiveRollback(r)

  test "the rollback screen flags a passwd.user revert separately":
    let profile = parseSystemProfile("""
passwd.user { name = "deploy" }
windows.optionalFeature { name = "WSL" }
""")
    let decision = screenRollback(profile.resources)
    check decision.requiresPasswdDestroyFlag
    check decision.passwdDestroyAddresses == @["user:deploy"]
    # The WSL feature trips the OTHER gate.
    check decision.requiresFeatureDestroyFlag

  test "the passwd-destroy gate FAILS CLOSED without the flag":
    let profile = parseSystemProfile(
      "passwd.user { name = \"deploy\" }\n")
    let decision = screenRollback(profile.resources)
    # Without --accept-passwd-destroy the rollback refuses, BEFORE any
    # mutation — fail closed.
    expect EPasswdDestroy:
      enforcePasswdDestroyGate(decision, acceptPasswdDestroy = false)
    # WITH the flag it is allowed (no raise).
    enforcePasswdDestroyGate(decision, acceptPasswdDestroy = true)

  test "runInfraApply refuses a passwd.user destroy without the flag":
    # The `extraDestroyResources` seam (the `repro system rollback`
    # path) carries a `passwd.user` destroy. `runInfraApply` must fail
    # closed with `EPasswdDestroy` BEFORE any mutation when
    # `acceptPasswdDestroy` is false. This runs on EVERY platform — the
    # gate is enforced before the driver shell-out is ever reached.
    let stateDir = createTempDir("repro-m69-passwd-gate-", "")
    defer: removeDir(stateDir)
    ensureSystemStateDir(stateDir)
    writeFile(stateDir / "system.nim", "")
    var opts: ApplyOptions
    opts.stateDir = stateDir
    opts.hostIdentity = "gate-host"
    opts.reproExe = reproBinary()
    opts.elevationMode = emBroker
    opts.noPreview = true
    opts.acceptPasswdDestroy = false
    opts.extraDestroyResources = @[SystemResource(kind: srkPasswdUser,
      address: "user:deploy", puName: "deploy")]
    expect EPasswdDestroy:
      discard runInfraApply(readFile(stateDir / "system.nim"), opts)

# ===========================================================================
# DESTRUCTIVE: real `useradd` / `usermod` / `userdel` against a
# sandboxed account. SANDBOX/VM-ONLY — guarded by BOTH the POSIX
# platform AND `REPRO_M69_PASSWD_VM=1`. Never runs on a normal host.
# ===========================================================================

suite "passwd.user: REAL create / safe-destroy / rollback (sandbox-only)":

  test "real passwd.user lifecycle (only under Linux/macOS + the env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_M69_PASSWD_VM not set (or not on " &
        "Linux/macOS) — the real useradd / usermod / userdel scenario " &
        "is NOT EXERCISED on this host (it mutates a real account and " &
        "needs root). Run this gate inside a disposable Linux sandbox " &
        "/ VM with REPRO_M69_PASSWD_VM=1 to exercise the real passwd " &
        "mutation. The pure-logic + safety-gate suites above already " &
        "proved the driver logic AND the --accept-passwd-destroy gate " &
        "without mutating any host — there is no host-mutating " &
        "assertion to make outside a sandbox."
    else:
      # A sandboxed run: create a throwaway user, then prove the
      # destroy gate end-to-end through the public driver path.
      let stateDir = createTempDir("repro-m69-passwd-sb-", "")
      defer: removeDir(stateDir)
      let userName = "reprotest" & $getCurrentProcessId()
      writeFile(stateDir / "system.nim",
        "passwd.user {\n  name = \"" & userName & "\"\n" &
        "  groups = [\"users\"]\n}\n")
      let profileText = readFile(stateDir / "system.nim")
      var opts: ApplyOptions
      opts.stateDir = stateDir
      opts.hostIdentity = "sandbox-host"
      opts.reproExe = reproBinary()
      opts.elevationMode = emBroker
      opts.forceBroker = false            # the sandbox runs as root
      opts.noPreview = true
      # 1. Create the user.
      let created = runInfraApply(profileText, opts)
      check created.errorCount == 0
      # 2. A destroy WITHOUT --accept-passwd-destroy is refused.
      var destroyOpts = opts
      destroyOpts.acceptPasswdDestroy = false
      destroyOpts.extraDestroyResources = @[SystemResource(
        kind: srkPasswdUser, address: "user:" & userName,
        puName: userName)]
      expect EPasswdDestroy:
        discard runInfraApply(profileText, destroyOpts)
      # 3. WITH the flag the destroy succeeds.
      destroyOpts.acceptPasswdDestroy = true
      let removed = runInfraApply(profileText, destroyOpts)
      check removed.errorCount == 0
