## The preflight's ``foreign-occupants`` check distinguishes Reprobuild's
## own pre-bootstrap inputs from a foreign occupant (ReproOS Add-On Mode
## spec §6.1, §13 decision 17), and accepts an input only in the shape,
## ownership and mode that make it safe to take over.
##
## The fixture is the state ``rpi2`` carried on 2026-10-30 12:12Z, before
## any add-on bootstrap: ``/repro/store`` empty, ``/var/lib/repro/system``
## empty, the deploy agent's ``recipient.key`` (0400, a real P-256 key),
## its allowed-signers file under ``/etc/repro``, the tmpfiles fragment
## that recreates ``/run/repro/secrets``, and nothing applied -- no
## generation, no unit. The old preflight refused that shape outright:
## any of the four roots existing was a ``foreign-occupants`` failure.
## That is the negative control, measured on rpi2 itself with the
## ``a2c3da25e`` binary on 2026-10-30 12:12Z (``compatible: false`` on
## ``foreign-occupants`` alone; infra
## ``machines/server/rpi2/evidence/2026-10-30T12-12Z-preflight-a2c3da25e.json``).
##
## No mocks: ``inspectOccupancy`` is the preflight's own classification,
## run against a real directory tree under a temporary root, with the
## test's own uid as the owner every input must have (root on the live
## host). The live checks (os-release, PID 1, the root filesystem) are not
## exercised here; the VM gates under ``tests/e2e/addon`` run the whole
## preflight.

import std/[os, posix, strutils, unittest]

import repro_peer_cache/auth as peerAuth
import repro_addon/[generation0, preflight]
import repro_core/host_apply_lock

const
  SignerKey = "04" & repeat("ab", 64)
  OtherKey = "04" & repeat("cd", 64)
  StandUpFragment = "# Installed by the A14 bootstrap of rpi2 (reprobuild D1).\n" &
    "d /run/repro 0755 root root -\n" &
    "d /run/repro/secrets 0700 root root -\n"

let
  me = (uid: int(getuid()), gid: int(getgid()))
  keypair = peerAuth.generateKeypair()
  keyText = peerAuth.privateKeyFileText(keypair.privateKey)
  pubHex = peerAuth.publicKeyHex(keypair.publicKey)

proc chmodTo(path: string; mode: int) =
  doAssert chmod(path.cstring, Mode(mode)) == 0, path

proc rpi2Tree(root: string) =
  ## rpi2's pre-bootstrap state, as ``ls -laR`` showed it.
  createDir(root / "repro/store")
  createDir(root / "var/lib/repro/system")
  createDir(root / "var/lib/repro/agent")
  chmodTo(root / "var/lib/repro/agent", 0o700)
  writeFile(root / "var/lib/repro/agent/recipient.key", keyText)
  chmodTo(root / "var/lib/repro/agent/recipient.key", 0o400)
  createDir(root / "etc/repro")
  writeFile(root / "etc/repro/deploy-manifest-allowed-signers",
            SignerKey & "\n")
  createDir(root / "etc/tmpfiles.d")
  writeFile(root / "etc/tmpfiles.d/repro-addon-bootstrap.conf", StandUpFragment)
  createDir(root / "run/repro/secrets")
  chmodTo(root / "run/repro/secrets", 0o700)
  createDir(root / "etc/systemd/system")

proc freshRoot(name: string): string =
  result = getTempDir() / ("repro-addon-preflight-" & name & "-" &
                           $getCurrentProcessId())
  removeDir(result)
  rpi2Tree(result)

proc inspect(root: string; signers: seq[string] = @[];
             given = false): OccupancyReport =
  inspectOccupancy(root, signers, given, owner = me)

proc refusedPaths(r: OccupancyReport): seq[string] =
  for line in r.refused:
    result.add(line[0 ..< line.find(':')])

proc keptPaths(r: OccupancyReport): seq[string] =
  for k in r.inputs.keptFiles: result.add(k.path)

suite "rpi2's pre-bootstrap state is taken over, not refused":
  let root = freshRoot("rpi2")
  let r = inspect(root)

  test "rpi2's shape is accepted":
    check r.refused == newSeq[string]()

  test "every existing directory is a root bootstrap takes over, parents first":
    check r.inputs.roots == @["/repro", "/repro/store", "/etc/repro",
                              "/var/lib/repro", "/var/lib/repro/system",
                              "/var/lib/repro/agent", "/run/repro",
                              "/run/repro/secrets"]

  test "the recipient key, the signers file and the tmpfiles fragment are kept":
    check r.inputs.recipientKey == RecipientKeyPath
    check r.inputs.signersFile == PreBootstrapSignersPath
    check r.inputs.tmpfilesFragment == PreBootstrapTmpfilesPath
    check r.keptPaths == @[PreBootstrapSignersPath, RecipientKeyPath,
                           PreBootstrapTmpfilesPath]

  test "the kept files are content-pinned, by digest, and the key by its public half":
    for k in r.inputs.keptFiles:
      check k.pinned and k.sha256.len == 64
    check r.inputs.recipientPublicKey == pubHex

  test "without --deploy-signers the kept signers file supplies the anchors":
    check r.inputs.signersKeys == @[SignerKey]

  test "with --deploy-signers the kept file must hold the same key set":
    check inspect(root, @[SignerKey], true).refused.len == 0
    let other = inspect(root, @[OtherKey], true)
    check other.refusedPaths == @[PreBootstrapSignersPath]
    check "not the --deploy-signers anchors" in other.refused[0]

  test "a matching recipient.pub is kept beside the key":
    writeFile(root / "var/lib/repro/agent/recipient.pub", pubHex & "\n")
    let p = inspect(root)
    check p.refused.len == 0
    check RecipientPubPath in p.keptPaths
    removeFile(root / "var/lib/repro/agent/recipient.pub")

  test "a pristine host has no inputs and no refusals":
    let empty = getTempDir() / ("repro-addon-preflight-empty-" &
                                $getCurrentProcessId())
    removeDir(empty)
    createDir(empty)
    let e = inspect(empty)
    check e.refused.len == 0 and e.inputs.roots.len == 0 and
          e.inputs.keptFiles.len == 0
    removeDir(empty)

  test "the host apply lock any apply leaves behind is not an occupant":
    # Every apply, and bootstrap itself, creates the host-wide apply lock.
    # At 97645920d it lived at /run/repro/apply.lock, inside an add-on
    # root, so bootstrap's own lock made the plan it recomputes
    # incompatible (a foreign occupant under /run/repro), and the file
    # stayed and refused every later preflight. It must sit outside every
    # add-on root.
    for tree in ["pristine", "rpi2"]:
      let r = getTempDir() / ("repro-addon-preflight-lock-" & tree & "-" &
                              $getCurrentProcessId())
      removeDir(r)
      if tree == "rpi2": rpi2Tree(r) else: createDir(r)
      let before = inspect(r)
      let lockFile = r & SystemHostApplyLockPath
      createDir(parentDir(lockFile))
      writeFile(lockFile, "")
      let after = inspect(r)
      check after.refused == newSeq[string]()
      check after.inputs.roots == before.inputs.roots
      for root in AddonOwnedRoots:
        check not SystemHostApplyLockPath.startsWith(root & "/")
      removeDir(r)

  test "the agent's sequence floor is kept, with its content unpinned":
    createDir(root / "var/lib/repro/agent/state/deploy-agent")
    chmodTo(root / "var/lib/repro/agent/state", 0o700)
    chmodTo(root / "var/lib/repro/agent/state/deploy-agent", 0o700)
    writeFile(root / "var/lib/repro/agent/state/deploy-agent/rpi2.seq", "7\n")
    writeFile(root / "var/lib/repro/agent/state/deploy-agent/rpi2.last-tick.json",
              "{}\n")
    let f = inspect(root)
    check f.refused.len == 0
    check AgentStateRecordsDir & "/rpi2.seq" in f.keptPaths
    check AgentStateRecordsDir in f.inputs.roots
    for k in f.inputs.keptFiles:
      if k.path.startsWith(AgentStateRecordsDir):
        check not k.pinned and k.sha256.len == 0
    writeFile(root / "var/lib/repro/agent/state/deploy-agent/notes.txt", "")
    let g = inspect(root)
    check g.refusedPaths == @[AgentStateRecordsDir & "/notes.txt"]
    removeDir(root / "var/lib/repro/agent/state")

  removeDir(root)

suite "everything else at the add-on's roots remains a refusal, by name":
  proc refusalFor(mutate: proc(root: string)): OccupancyReport =
    ## ``mutate`` adds one thing to a fresh rpi2 tree; the classification
    ## of that tree is returned.
    let root = freshRoot("refuse")
    mutate(root)
    result = inspect(root)
    removeDir(root)

  test "a foreign file under /etc/repro":
    let r = refusalFor(proc(root: string) =
      writeFile(root / "etc/repro/system.nim", "# intent\n"))
    check r.refusedPaths == @["/etc/repro/system.nim"]
    check "not a pre-bootstrap input" in r.refused[0]

  test "a generation of an earlier install":
    let r = refusalFor(proc(root: string) =
      createDir(root / "var/lib/repro/system/generations/g1"))
    check r.refusedPaths == @["/var/lib/repro/system"]
    check "generations or state" in r.refused[0]

  test "a current link in the state directory":
    let r = refusalFor(proc(root: string) =
      createSymlink("generations/g1", root / "var/lib/repro/system/current"))
    check r.refusedPaths == @["/var/lib/repro/system"]
    check "not empty" in r.refused[0]

  test "a store in use":
    let r = refusalFor(proc(root: string) =
      createDir(root / "repro/store/prefixes"))
    check r.refusedPaths == @["/repro/store"]
    check "a store in use" in r.refused[0]

  test "a repro-* unit in any load path":
    let r = refusalFor(proc(root: string) =
      writeFile(root / "etc/systemd/system/repro-deploy-agent.service", "[Unit]\n"))
    check r.refusedPaths == @["/etc/systemd/system/repro-deploy-agent.service"]
    check "repro-* unit" in r.refused[0]

  test "a repro-* unit linked only from a .wants directory":
    let r = refusalFor(proc(root: string) =
      createDir(root / "etc/systemd/system/multi-user.target.wants")
      writeFile(root / "etc/systemd/system/multi-user.target.wants/repro-evil.service",
                "[Unit]\n"))
    check r.refusedPaths ==
      @["/etc/systemd/system/multi-user.target.wants/repro-evil.service"]
    check "repro-* unit link" in r.refused[0]

  test "generation 0's own unit is a refusal here too":
    let r = refusalFor(proc(root: string) =
      writeFile(root / "etc/systemd/system" / AddonTarget, "[Unit]\n"))
    check r.refusedPaths == @["/etc/systemd/system/" & AddonTarget]
    check "repro-* unit" in r.refused[0]

  test "a symbolic link where a root should be":
    let r = refusalFor(proc(root: string) =
      removeDir(root / "run/repro/secrets")
      createSymlink("/tmp", root / "run/repro/secrets"))
    check r.refusedPaths == @["/run/repro/secrets"]
    check "a symbolic link" in r.refused[0]

  test "a file that is not a deploy-signer anchor file":
    let r = refusalFor(proc(root: string) =
      writeFile(root / "etc/repro/deploy-manifest-allowed-signers", "not a key\n"))
    check r.refusedPaths == @[PreBootstrapSignersPath]
    check "not a deploy-signer anchor file" in r.refused[0]

  test "a foreign entry in the agent directory":
    let r = refusalFor(proc(root: string) =
      writeFile(root / "var/lib/repro/agent/cache-publisher.key", "x"))
    check r.refusedPaths == @["/var/lib/repro/agent/cache-publisher.key"]
    check "not a pre-bootstrap input" in r.refused[0]

  test "materialised secrets left behind":
    let r = refusalFor(proc(root: string) =
      writeFile(root / "run/repro/secrets/token", "x"))
    check r.refusedPaths == @["/run/repro/secrets"]
    check "materialised secrets" in r.refused[0]

suite "an input in the wrong ownership or mode is refused, never narrowed":
  proc refusalFor(mutate: proc(root: string)): OccupancyReport =
    let root = freshRoot("mode")
    mutate(root)
    result = inspect(root)
    removeDir(root)

  test "a recipient key readable by group or others is compromised":
    let r = refusalFor(proc(root: string) =
      chmodTo(root / "var/lib/repro/agent/recipient.key", 0o644))
    check r.refusedPaths == @[RecipientKeyPath]
    check "not 0400" in r.refused[0] and "compromised" in r.refused[0]

  test "a recipient key with the owner bits wrong is not 0400 either":
    let r = refusalFor(proc(root: string) =
      chmodTo(root / "var/lib/repro/agent/recipient.key", 0o600))
    check r.refusedPaths == @[RecipientKeyPath]
    check "mode 0600, not 0400" in r.refused[0]

  test "a recipient key that does not parse":
    let r = refusalFor(proc(root: string) =
      removeFile(root / "var/lib/repro/agent/recipient.key")   # it is 0400
      writeFile(root / "var/lib/repro/agent/recipient.key", "ecdsa-p256:zz\n")
      chmodTo(root / "var/lib/repro/agent/recipient.key", 0o400))
    check r.refusedPaths == @[RecipientKeyPath]
    check "not a usable recipient key" in r.refused[0]

  test "a recipient key that is a symbolic link":
    let r = refusalFor(proc(root: string) =
      removeFile(root / "var/lib/repro/agent/recipient.key")
      createSymlink("/etc/shadow", root / "var/lib/repro/agent/recipient.key"))
    check r.refusedPaths == @[RecipientKeyPath]
    check "a symbolic link" in r.refused[0]

  test "a recipient.pub that is not the key's public half":
    let r = refusalFor(proc(root: string) =
      writeFile(root / "var/lib/repro/agent/recipient.pub", "04ff\n"))
    check r.refusedPaths == @[RecipientPubPath]
    check "not the public half" in r.refused[0]

  test "a group- or other-writable agent directory":
    let r = refusalFor(proc(root: string) =
      chmodTo(root / "var/lib/repro/agent", 0o777))
    check r.refusedPaths == @[AgentDir]
    check "writable by group or others (mode 0777)" in r.refused[0]

  test "a group- or other-writable secrets directory":
    let r = refusalFor(proc(root: string) =
      chmodTo(root / "run/repro/secrets", 0o777))
    check r.refusedPaths == @[SecretsRunDir]
    check "writable by group or others" in r.refused[0]

  test "a group-writable signers file":
    let r = refusalFor(proc(root: string) =
      chmodTo(root / "etc/repro/deploy-manifest-allowed-signers", 0o664))
    check r.refusedPaths == @[PreBootstrapSignersPath]
    check "writable by group or others" in r.refused[0]

  test "a path owned by someone else":
    # The live host requires root; here the fixture is the test's, so
    # asking for another owner refuses every input by ownership.
    let root = freshRoot("owner")
    let r = inspectOccupancy(root, @[], false, owner = (uid: me.uid + 1, gid: me.gid))
    check r.refused.len > 0
    check "owned by " & $me.uid & ":" & $me.gid in r.refused[0]
    removeDir(root)

suite "the tmpfiles fragment is accepted only as exactly the stand-up's rules":
  proc fragmentRefusal(text: string): OccupancyReport =
    let root = freshRoot("tmpfiles")
    writeFile(root / "etc/tmpfiles.d/repro-addon-bootstrap.conf", text)
    result = inspect(root)
    removeDir(root)

  test "the stand-up fragment, with or without the age field, with comments":
    check tmpfilesFragmentRefusal(StandUpFragment) == ""
    check tmpfilesFragmentRefusal("d /run/repro 0755 root root\n" &
                                  "d /run/repro/secrets 0700 root root\n") == ""

  test "an L+ rule that would link the secrets directory elsewhere":
    let r = fragmentRefusal("L+ /run/repro/secrets - - - - /tmp/x\n")
    check r.refusedPaths == @[PreBootstrapTmpfilesPath]
    check "holds 1 rule(s)" in r.refused[0]

  test "d rules with a wider mode and another owner":
    let r = fragmentRefusal("d /run/repro 0777 nobody nogroup -\n" &
                            "d /run/repro/secrets 0777 nobody nogroup -\n")
    check r.refusedPaths == @[PreBootstrapTmpfilesPath]
    check "rule `d /run/repro 0777 nobody nogroup` is not `d /run/repro 0755 root root`" in
      r.refused[0]

  test "a C rule copying a file into /run/repro":
    let r = fragmentRefusal("C /run/repro - - - - /etc/shadow\n")
    check r.refusedPaths == @[PreBootstrapTmpfilesPath]

  test "an r rule removing the secrets directory":
    let r = fragmentRefusal("d /run/repro 0755 root root -\nr /run/repro/secrets\n")
    check r.refusedPaths == @[PreBootstrapTmpfilesPath]
    check "rule `r /run/repro/secrets` is not" in r.refused[0]

  test "a third rule, even for the same paths":
    let r = fragmentRefusal(StandUpFragment & "z /run/repro - - - -\n")
    check r.refusedPaths == @[PreBootstrapTmpfilesPath]
    check "holds 3 rule(s)" in r.refused[0]

  test "a fragment ruling another path":
    let r = fragmentRefusal("d /run/repro 0755 root root -\n" &
                            "d /var/lib/other 0755 root root -\n")
    check r.refusedPaths == @[PreBootstrapTmpfilesPath]

  test "the rule parser drops the default age and keeps everything else":
    check tmpfilesRules("# c\n\nd /run/repro 0755 root root -\nz /x\nD\n") ==
      @[@["d", "/run/repro", "0755", "root", "root"], @["z", "/x"], @["D"]]
