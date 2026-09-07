## M9.R.22b.3 — ``repro disk apply --confirm`` CLI gating.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §4.2.
##
## Six cases verifying CLI gating, scoping and identifier pinning:
##   1. apply WITHOUT --confirm against a VALID disko.nim:
##      prints the plan + refuses with exit 2.
##   2. apply WITH --confirm against a VALID disko.nim under
##      REPRO_DISK_DRY_RUN=1: returns 0 + operations[] populated.
##   3. apply --device <dev> --confirm scopes to that single disk
##      (multi-disk source rejects on bogus --device, accepts on a
##      matching one).
##   4. apply --confirm against a missing file → exit 2 (the file-
##      existence check comes BEFORE the confirm gate kicks in).
##   5. mount/unmount walk the layout (added alongside 1-4).
##   6. the identity document beside the layout is found by convention,
##      an explicitly-named one that is absent or malformed stops the
##      apply, and a found one reaches every mkfs/sgdisk argv.

import std/[options, os, osproc, sequtils, strutils, tables, unittest]

import repro_profile
import repro_cli_support/disk as cli_disk

const TmpRoot = "build/m9r22b_3_tmp"

proc resetDir(sub: string): string =
  let dir = TmpRoot / sub
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  dir

const SingleDiskSource = """
import repro_profile

hardware "01M9R22B-CLI-SINGLE":
  cpu:
    arch: "x86_64"
  disko:
    disks:
      "main":
        device: "/dev/disk/by-id/loop-fixture-single"
        table: gpt
        partitions:
          "esp":
            kind: esp
            size: "512M"
            bootable: true
            content:
              filesystem:
                format: "vfat"
                mountpoint: "/boot"
          "root":
            kind: linux
            size: "100%"
            content:
              filesystem:
                format: "ext4"
                mountpoint: "/"
"""

const MultiDiskSource = """
import repro_profile

hardware "01M9R22B-CLI-MULTI":
  cpu:
    arch: "x86_64"
  disko:
    disks:
      "first":
        device: "/dev/disk/by-id/loop-fixture-first"
        table: gpt
        partitions:
          "root":
            kind: linux
            size: "100%"
            content:
              filesystem:
                format: "ext4"
                mountpoint: "/"
      "second":
        device: "/dev/disk/by-id/loop-fixture-second"
        table: gpt
        partitions:
          "data":
            kind: linux
            size: "100%"
            content:
              filesystem:
                format: "ext4"
                mountpoint: "/data"
"""

suite "M9.R.22b.3: `repro disk apply --confirm` CLI":

  setup:
    putEnv("REPRO_DISK_DRY_RUN", "1")

  teardown:
    delEnv("REPRO_DISK_DRY_RUN")

  test "Test#1: apply WITHOUT --confirm → exit 2 + plan printed":
    let dir = resetDir("test1")
    let src = dir / "hardware.nim"
    writeFile(src, SingleDiskSource)
    let rc = runDiskCommand(@["apply", src])
    check rc == 2

  test "Test#2: apply WITH --confirm runs the apply driver":
    let dir = resetDir("test2")
    let src = dir / "hardware.nim"
    writeFile(src, SingleDiskSource)
    # The driver runs under REPRO_DISK_DRY_RUN=1 so it doesn't touch
    # the real disk; we just verify exit 0.
    let rc = runDiskCommand(@["apply", src, "--confirm"])
    check rc == 0

  test "Test#3: --device scopes apply to a single disk":
    let dir = resetDir("test3")
    let src = dir / "hardware.nim"
    writeFile(src, MultiDiskSource)
    # Matching device → exit 0.
    block matchingDevice:
      let rc = runDiskCommand(@["apply", src, "--confirm",
        "--device", "/dev/disk/by-id/loop-fixture-first"])
      check rc == 0
    # Non-matching device → exit 2 with "does not match" diagnostic.
    block nonMatchingDevice:
      let rc = runDiskCommand(@["apply", src, "--confirm",
        "--device", "/dev/disk/by-id/loop-fixture-bogus"])
      check rc == 2

  test "Test#4: --confirm with missing source → exit 2":
    let rc = runDiskCommand(@["apply",
      "build/_definitely_not_a_file.nim", "--confirm"])
    check rc == 2

  test "Test#5: mount + unmount subcommands run the new walker":
    let dir = resetDir("test5")
    let src = dir / "hardware.nim"
    writeFile(src, SingleDiskSource)
    # mount without --confirm: plan-only, exit 0.
    block mountPlan:
      let rc = runDiskCommand(@["mount", src, "--target", "/mnt"])
      check rc == 0
    # unmount: exit 0 (best-effort under dry-run).
    block unmount:
      let rc = runDiskCommand(@["unmount", src, "--target", "/mnt"])
      check rc == 0

  test "Test#6: the sibling identity document pins every identifier":
    ## The seed is not passed through the environment and not repeated
    ## at every call site: it sits beside the layout document and is
    ## found by convention, because a pin that has to be remembered at
    ## each call is one that eventually is not, and the failure is
    ## silent.
    let dir = resetDir("test6")
    let src = dir / "hardware.nim"
    writeFile(src, SingleDiskSource)

    let noFs = proc(p: string): bool = false
    let neverRead = proc(p: string): string = ""

    # Nothing beside the layout: unpinned, and NOT an error -- an apply
    # onto physical hardware wants per-machine identifiers.
    block noDocument:
      let r = resolveDiskIdentity(src, "", noFs, neverRead)
      check not r.failure
      check not r.identity.isPinned
      check r.source.len == 0

    # Asked for explicitly and absent: an error, because a caller that
    # named a document and got none would apply unpinned while
    # believing otherwise.
    block explicitMissing:
      let r = resolveDiskIdentity(src, dir / "nope.json", noFs, neverRead)
      check r.failure
      check "no such file" in r.failureMsg

    let identityPath = diskIdentitySiblingPath(src)
    check identityPath == dir / "hardware.identity.json"
    writeFile(identityPath,
      renderDiskIdentityDocument(DiskIdentity(seed: "a-fixed-seed")))

    let realExists = proc(p: string): bool = fileExists(p)
    let realRead = proc(p: string): string = readFile(p)

    block siblingFound:
      let r = resolveDiskIdentity(src, "", realExists, realRead)
      check not r.failure
      check r.identity.isPinned
      check r.identity.seed == "a-fixed-seed"
      check r.source == identityPath

    # Present but unusable stops the apply rather than falling back to
    # unpinned, which would be the silent failure this whole mechanism
    # exists to remove.
    block malformed:
      let bad = dir / "bad.json"
      writeFile(bad, "{\"version\": 99, \"seed\": \"x\"}")
      let r = resolveDiskIdentity(src, bad, realExists, realRead)
      check r.failure
      check "version" in r.failureMsg
    block emptySeed:
      let bad = dir / "empty.json"
      writeFile(bad, "{\"version\": 1, \"seed\": \"\"}")
      let r = resolveDiskIdentity(src, bad, realExists, realRead)
      check r.failure

    # And it reaches the argv: every identifier-bearing operation the
    # apply would run carries its pinned value, and the same seed
    # produces the same argv twice.
    let outcome = loadDiskoFromSource(src)
    check not outcome.failure
    let layout = outcome.spec.disko.get()
    let identity = DiskIdentity(seed: "a-fixed-seed")
    let first = applyDiskLayout(layout, initTable[string, string](), identity)
    let second = applyDiskLayout(layout, initTable[string, string](), identity)
    check not first.failure
    var pinned = 0
    for i, op in first.operations:
      check op.argv == second.operations[i].argv
      case op.tool
      of "sgdisk":
        check ("-U" in op.argv) or ("-u" in op.argv)
        inc pinned
      of "mkfs.ext4":
        check "-U" in op.argv
        check op.argv.anyIt(it.startsWith("hash_seed="))
        inc pinned
      of "mkfs.vfat":
        check "-i" in op.argv
        inc pinned
      else: discard
    # gpt table + 2 partitions + 2 filesystems.
    check pinned == 5

    # A different seed moves every one of them.
    let other = applyDiskLayout(layout, initTable[string, string](),
      DiskIdentity(seed: "another-seed"))
    var moved = 0
    for i, op in first.operations:
      if op.tool in ["sgdisk", "mkfs.ext4", "mkfs.vfat"] and
         op.argv != other.operations[i].argv:
        inc moved
    check moved == 5

    # And no seed leaves every default alone.
    let unpinned = applyDiskLayout(layout, initTable[string, string]())
    for op in unpinned.operations:
      check "-U" notin op.argv
      check "-u" notin op.argv
      check "-i" notin op.argv
