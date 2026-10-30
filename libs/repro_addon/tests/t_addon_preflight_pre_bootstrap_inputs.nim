## The preflight's ``foreign-occupants`` check distinguishes Reprobuild's
## own pre-bootstrap inputs from a foreign occupant (ReproOS Add-On Mode
## spec §6.1, §13 decision 17).
##
## The fixture is the state ``rpi2`` carried on 2026-10-30 12:12Z, before
## any add-on bootstrap: ``/repro/store`` empty, ``/var/lib/repro/system``
## empty, the deploy agent's ``recipient.key`` (0400), its allowed-signers
## file under ``/etc/repro``, the tmpfiles fragment that recreates
## ``/run/repro/secrets``, and nothing applied -- no generation, no unit.
## The old preflight refused that shape outright: any of the four roots
## existing was a ``foreign-occupants`` failure. That is the negative
## control, measured on rpi2 itself with the ``a2c3da25e`` binary on
## 2026-10-30 12:12Z (``compatible: false`` on ``foreign-occupants`` alone;
## infra ``machines/server/rpi2/evidence/2026-10-30T12-12Z-preflight-a2c3da25e.json``),
## and reproduced here as a falsifying mutation of ``inspectOccupancy`` that
## refuses every existing directory, under which the first suite goes red
## (recorded in the commit that added this file).
##
## No mocks: ``inspectOccupancy`` is the preflight's own classification,
## run against a real directory tree under a temporary root. The live
## checks (os-release, PID 1, the root filesystem) are not exercised here;
## the VM gates under ``tests/e2e/addon`` run the whole preflight.

import std/[os, strutils, unittest]

import repro_addon/[generation0, preflight]

const
  SignerKey = "04" & repeat("ab", 64)
  OtherKey = "04" & repeat("cd", 64)

proc rpi2Tree(root: string) =
  ## rpi2's pre-bootstrap state, as ``ls -laR`` showed it.
  createDir(root / "repro/store")
  createDir(root / "var/lib/repro/system")
  createDir(root / "var/lib/repro/agent")
  writeFile(root / "var/lib/repro/agent/recipient.key",
            "ecdsa-p256:" & repeat("00", 32) & "\n")
  setFilePermissions(root / "var/lib/repro/agent/recipient.key", {fpUserRead})
  createDir(root / "etc/repro")
  writeFile(root / "etc/repro/deploy-manifest-allowed-signers",
            SignerKey & "\n")
  createDir(root / "etc/tmpfiles.d")
  writeFile(root / "etc/tmpfiles.d/repro-addon-bootstrap.conf",
    "# Installed by the A14 bootstrap of rpi2 (reprobuild D1).\n" &
    "d /run/repro 0755 root root -\n" &
    "d /run/repro/secrets 0700 root root -\n")
  createDir(root / "run/repro/secrets")
  createDir(root / "etc/systemd/system")

proc freshRoot(name: string): string =
  result = getTempDir() / ("repro-addon-preflight-" & name & "-" &
                           $getCurrentProcessId())
  removeDir(result)
  rpi2Tree(result)

proc refusedPaths(r: OccupancyReport): seq[string] =
  for line in r.refused:
    result.add(line[0 ..< line.find(':')])

suite "rpi2's pre-bootstrap state is taken over, not refused":
  let root = freshRoot("rpi2")
  let r = inspectOccupancy(root, @[], deploySignersGiven = false)

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
    check r.inputs.keptFiles == @[PreBootstrapSignersPath, RecipientKeyPath,
                                  PreBootstrapTmpfilesPath]

  test "without --deploy-signers the kept signers file supplies the anchors":
    check r.inputs.signersKeys == @[SignerKey]

  test "with --deploy-signers the kept file must hold the same key set":
    check inspectOccupancy(root, @[SignerKey], true).refused.len == 0
    let other = inspectOccupancy(root, @[OtherKey], true)
    check other.refusedPaths == @[PreBootstrapSignersPath]
    check "not the --deploy-signers anchors" in other.refused[0]

  test "a pristine host has no inputs and no refusals":
    let empty = getTempDir() / ("repro-addon-preflight-empty-" &
                                $getCurrentProcessId())
    removeDir(empty)
    createDir(empty)
    let e = inspectOccupancy(empty, @[], false)
    check e.refused.len == 0 and e.inputs.roots.len == 0 and
          e.inputs.keptFiles.len == 0
    removeDir(empty)

  test "the agent's sequence floor is kept":
    createDir(root / "var/lib/repro/agent/state/deploy-agent")
    writeFile(root / "var/lib/repro/agent/state/deploy-agent/rpi2.seq", "7\n")
    writeFile(root / "var/lib/repro/agent/state/deploy-agent/rpi2.last-tick.json",
              "{}\n")
    let f = inspectOccupancy(root, @[], false)
    check f.refused.len == 0
    check AgentStateRecordsDir & "/rpi2.seq" in f.inputs.keptFiles
    check AgentStateRecordsDir in f.inputs.roots
    writeFile(root / "var/lib/repro/agent/state/deploy-agent/notes.txt", "")
    let g = inspectOccupancy(root, @[], false)
    check g.refusedPaths == @[AgentStateRecordsDir & "/notes.txt"]
    removeDir(root / "var/lib/repro/agent/state")

  removeDir(root)

suite "everything else at the add-on's roots remains a refusal, by name":
  proc refusalFor(mutate: proc(root: string)): OccupancyReport =
    ## ``mutate`` adds one thing to a fresh rpi2 tree; the classification
    ## of that tree is returned.
    let root = freshRoot("refuse")
    mutate(root)
    result = inspectOccupancy(root, @[], false)
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

  test "a tmpfiles fragment ruling another path":
    let r = refusalFor(proc(root: string) =
      writeFile(root / "etc/tmpfiles.d/repro-addon-bootstrap.conf",
                "d /run/repro 0755 root root -\n" &
                "d /var/lib/other 0755 root root -\n"))
    check r.refusedPaths == @[PreBootstrapTmpfilesPath]
    check "rules a path other than" in r.refused[0]

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

suite "tmpfiles rules":
  test "the path field of every rule, comments skipped":
    check tmpfilesRulePaths("# c\n\nd /run/repro 0755 root root -\nz /x\nD\n") ==
      @["/run/repro", "/x", ""]
