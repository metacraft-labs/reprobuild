## Gate ``e2e_addon_store_roots_and_btrfs``.
##
## Two store-root properties, in one disposable guest per base:
##
## 1. **GC roots.** After bootstrap and two further generations, `repro
##    system addon status` lists every generation as a ``profile`` store
##    root: the current one, the previous one and generation 0 -- so
##    `repro store gc` can never collect what the current or previous
##    generation runs from. (The retention window beyond that is A4's.)
## 2. **The btrfs leg.** The distributions' cloud images have ext4 roots, so
##    the subvolume branch of the store-root creation never runs in the
##    other gates. Here a loop-backed btrfs filesystem is made in the guest
##    (``btrfs-progs`` installed for ``mkfs.btrfs`` only; the add-on itself
##    uses the kernel ioctls) and `repro system addon selfcheck-btrfs` runs
##    the same code path bootstrap takes on a btrfs root: create the
##    directory as a subvolume (inode 256, mode 0755), then delete it
##    through the subvolume ioctl.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_store_roots_and_btrfs``).
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const Gen1 = """fs.systemFile {
  path = "/etc/repro-addon-fixture/one.conf"
  content = "one
"
}
"""
const Gen2 = """fs.systemFile {
  path = "/etc/repro-addon-fixture/two.conf"
  content = "two
"
}
"""

proc generationOf(applyOutput: string): string =
  ## ``generation <id> (previous <id>)`` from the apply's report line.
  for line in applyOutput.splitLines():
    let f = line.splitWhitespace()
    if f.len >= 2 and f[0] == "generation":
      return f[1]
  ""

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let anchors = g.installAnchors()
    let pre = g.exec(repro & " system addon preflight" & anchors.flags)
    step("preflight is compatible", pre.exitCode == 0, pre.stdout & pre.stderr)
    if pre.exitCode != 0: return fails
    let boot = g.exec(repro & " system addon bootstrap --plan " &
                      planDigestOf(pre.stdout) & anchors.flags)
    step("bootstrap", boot.exitCode == 0, boot.stdout & boot.stderr)
    if boot.exitCode != 0: return fails
    var gen0 = ""
    for line in boot.stdout.splitLines():
      if line.startsWith("generation:"): gen0 = line["generation:".len .. ^1].strip()
    var gens = @[gen0]
    for (n, text) in [("gen1", Gen1), ("gen2", Gen2)]:
      writeFile(g.runDir / (n & ".profile"), text)
      g.copyTo(g.runDir / (n & ".profile"), "/root/addon/" & n & ".profile")
      let a = g.exec(repro & " infra apply --profile /root/addon/" & n & ".profile")
      step("apply " & n, a.exitCode == 0, a.stdout & a.stderr)
      if a.exitCode != 0: return fails
      gens.add(generationOf(a.stdout))
    let status = g.run(repro & " system addon status")
    var allHeld = true
    for gid in gens:
      if gid.len == 0 or ("  " & gid) notin status: allHeld = false
    step("every generation (0, previous, current) is a store root",
         allHeld and ("  " & gens[^1] & " (current)") in status,
         "generations " & $gens & "\n" & status)
    step("the store root is a plain directory on this ext4 base",
         "store root: /repro dir" in status, status)

    # The btrfs leg on a loop-backed filesystem.
    let mk = g.exec("export DEBIAN_FRONTEND=noninteractive; " &
      "apt-get install -y -qq btrfs-progs >/dev/null && " &
      "truncate -s 512M /var/tmp/repro-addon-btrfs.img && " &
      "mkfs.btrfs -q /var/tmp/repro-addon-btrfs.img && " &
      "mkdir -p /mnt/repro-addon-btrfs && " &
      "mount -o loop /var/tmp/repro-addon-btrfs.img /mnt/repro-addon-btrfs && " &
      "stat -f -c %T /mnt/repro-addon-btrfs", timeoutSec = 1200)
    step("a loop-backed btrfs filesystem is mounted",
         mk.exitCode == 0 and mk.stdout.strip() == "btrfs", mk.stdout & mk.stderr)
    if mk.exitCode == 0:
      let sc = g.exec(repro & " system addon selfcheck-btrfs /mnt/repro-addon-btrfs")
      step("the store root's subvolume leg creates and deletes a subvolume",
           sc.exitCode == 0 and "created" in sc.stdout and "deleted" in sc.stdout,
           sc.stdout & sc.stderr)
      let gone = g.exec("test ! -e /mnt/repro-addon-btrfs/repro-addon-selfcheck")
      step("nothing is left on the btrfs filesystem", gone.exitCode == 0, "")
      let notBtrfs = g.exec(repro & " system addon selfcheck-btrfs /etc")
      step("the subvolume leg refuses a non-btrfs parent", notBtrfs.exitCode != 0,
           notBtrfs.stdout & notBtrfs.stderr)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_addon_store_roots_and_btrfs":
  test "generations are store roots, and /repro is a subvolume on btrfs":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_addon_store_roots_and_btrfs)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_store_roots_and_btrfs",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_store_roots_and_btrfs", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
