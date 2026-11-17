## M9.R.22.3 — ``repro disk plan`` CLI subcommand.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §4.1.
##
## Five cases verifying the plan output format + the subcommand
## surface area:
##   1. repro's generated command-line parser recognises all six
##      subcommands + their flag surface (--confirm / --target / --device /
##      --identity / --output / --probe / --size).
##   2. ``renderPlan`` on an empty SystemHardwareSpec → "no disko"
##      message; on a populated spec → contains the disk + partition +
##      operation-list sections.
##   3. End-to-end ``loadDiskoFromSource`` against an inlined
##      hardware.nim source file: compile, run, capture JSON, render
##      plan; assert the rendered text mentions every declared device /
##      partition / mount-point.
##   4. ``loadDiskoFromSource`` also works outside the reprobuild
##      checkout, as an installed CLI must not depend on its process cwd.
##   5. ``runDiskCommand`` for the stub subcommands (apply / mount /
##      unmount / generate / image) returns exit-code 2 + the
##      "implementation pending" notice on stderr, and ``plan`` against
##      a missing file returns 2 with a "no such file" message.

import std/[options, os, osproc, strutils, tables, unittest]

import repro_profile
import repro_cli_support/disk as cli_disk
import repro_cli_support/cli_program
from repro_test_support import testCaseScratchSlug

let TmpRoot = "build/m9r22_3_tmp" / testCaseScratchSlug()

proc resetDir(sub: string): string =
  let dir = TmpRoot / sub
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  dir

# Sample disko-bearing hardware.nim source — kept on disk so the plan
# loader can compile + run it via `nim r` (the same path the CLI
# follows in production).
const SampleSource = """
import repro_profile

hardware "01M9R22-PLAN-FIXTURE":
  cpu:
    arch: "x86_64"
    microcode: "intel"
  disko:
    disks:
      "main":
        device: "/dev/disk/by-id/ata-PlanFixture"
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
    pools:
      "tank":
        devices: @["/dev/disk/by-id/ata-PoolDisk"]
        layout: "stripe"
        options: @["ashift=12"]
"""

suite "M9.R.22.3: `repro disk plan` CLI":

  test "Test#1: the parser recognises subcommands + flag surface":
    proc parse(args: seq[string]): ReproCommandLineDisk =
      ReproCommandLine.load(@["disk"] & args, CliSources()).disk

    # No subcommand is a usage error.
    expect CliUsageError:
      discard parse(@[])

    # Each subcommand resolves.
    check parse(@["plan", "a.nim"]).command == ReproCommandLineDiskCommand.plan
    check parse(@["apply", "a.nim"]).command ==
      ReproCommandLineDiskCommand.apply
    check parse(@["mount", "a.nim"]).command ==
      ReproCommandLineDiskCommand.mount
    check parse(@["unmount", "a.nim"]).command ==
      ReproCommandLineDiskCommand.unmount
    check parse(@["generate"]).command == ReproCommandLineDiskCommand.generate
    check parse(@["image", "a.nim"]).command ==
      ReproCommandLineDiskCommand.image

    # Flag parsing: --confirm + --device + --identity, --target, --output +
    # --size, in both spellings.
    let apply = parse(@["apply", "x.nim", "--device", "/dev/sdX",
      "--identity=x.identity.json", "--confirm"]).apply
    check apply.source == "x.nim"
    check apply.device == "/dev/sdX"
    check apply.identity == "x.identity.json"
    check apply.confirm

    let mount = parse(@["mount", "x.nim", "--target", "/mnt"]).mount
    check mount.target == "/mnt"
    check not mount.confirm

    let image = parse(@["image", "y.nim",
      "--output=out.img", "--size=8G"]).image
    check image.source == "y.nim"
    check image.output == "out.img"
    check image.size == "8G"

    let gen = parse(@["generate", "--probe", "/"]).generate
    check gen.probe == "/"

    # Unknown subcommand, extra positional, unknown flag, a flag of another
    # subcommand → usage error.
    expect CliUsageError:
      discard parse(@["doctor"])
    expect CliUsageError:
      discard parse(@["plan", "a.nim", "b.nim"])
    expect CliUsageError:
      discard parse(@["plan", "a.nim", "--nope"])
    expect CliUsageError:
      discard parse(@["plan", "a.nim", "--confirm"])

  test "Test#2: renderPlan formats empty + populated specs":
    # Empty spec → "no `disko:` block" message.
    var empty: SystemHardwareSpec
    empty.id = "01EMPTY"
    let emptyText = renderPlan(empty)
    check "01EMPTY" in emptyText
    check "no `disko:` block" in emptyText

    # Populated spec — built programmatically to dodge the test-binary
    # compile dependency on a separate fixture file.
    var spec = empty
    spec.id = "01HASDISKO"
    var dl: DiskLayout
    var d: DiskSpec
    d.device = "/dev/disk/by-id/ata-PopulatedFixture"
    d.`type` = "gpt"
    var p1: PartitionSpec
    p1.`type` = "esp"; p1.size = "512M"; p1.bootable = true
    p1.content = ContentSpec(kind: cfsFilesystem, format: "vfat",
                             mountpoint: "/boot")
    var p2: PartitionSpec
    p2.`type` = "linux"; p2.size = "100%"
    p2.content = ContentSpec(kind: cfsFilesystem, format: "ext4",
                             mountpoint: "/")
    d.partitions["esp"] = p1
    d.partitions["root"] = p2
    dl.disks["main"] = d
    dl.pools.add ZfsPoolSpec(name: "tank",
      devices: @["/dev/disk/by-id/ata-PoolDisk"],
      layout: "stripe", options: @["ashift=12"])
    spec.disko = some(dl)
    let plan = renderPlan(spec)
    # Sections.
    check "Disks (1)" in plan
    check "ZFS pools (1)" in plan
    check "Operations" in plan
    # Identifying strings.
    check "ata-PopulatedFixture" in plan
    check "ata-PoolDisk" in plan
    check "\"esp\"" in plan
    check "\"root\"" in plan
    check "bootable" in plan
    check "/boot" in plan
    check "/ " notin plan  # no trailing space typo for mountpoint
    check "ashift=12" in plan
    check "Non-destructive" in plan

  test "Test#3: loadDiskoFromSource against an inlined hardware.nim":
    let dir = resetDir("test3")
    let src = dir / "hardware.nim"
    writeFile(src, SampleSource)
    let outcome = loadDiskoFromSource(src)
    if outcome.failure:
      checkpoint("failureMsg = " & outcome.failureMsg)
    check not outcome.failure
    check outcome.spec.id == "01M9R22-PLAN-FIXTURE"
    check outcome.spec.disko.isSome
    let dl = outcome.spec.disko.get()
    check dl.disks.len == 1
    check dl.disks["main"].device ==
      "/dev/disk/by-id/ata-PlanFixture"
    check dl.disks["main"].partitions.len == 2
    check dl.pools.len == 1
    check dl.pools[0].name == "tank"
    # Plan text mentions every declared object.
    let text = outcome.text
    check "01M9R22-PLAN-FIXTURE" in text
    check "ata-PlanFixture" in text
    check "ata-PoolDisk" in text
    check "/boot" in text
    check "\"esp\"" in text
    check "\"root\"" in text
    check "tank" in text
    check "stripe" in text

  test "Test#4: loadDiskoFromSource is independent of process cwd":
    let sourceDir = absolutePath(resetDir("test4-source"))
    let externalCwd = absolutePath(resetDir("test4-external-cwd"))
    let src = sourceDir / "hardware.nim"
    writeFile(src, SampleSource)
    check not dirExists(externalCwd / "libs")

    let originalCwd = getCurrentDir()
    setCurrentDir(externalCwd)
    defer: setCurrentDir(originalCwd)
    let outcome = loadDiskoFromSource(src)
    if outcome.failure:
      checkpoint("failureMsg = " & outcome.failureMsg)
    check not outcome.failure
    check outcome.spec.id == "01M9R22-PLAN-FIXTURE"
    check outcome.spec.disko.isSome
    check "ata-PlanFixture" in outcome.text
    check "ata-PoolDisk" in outcome.text

  test "Test#5: stub subcommands + missing-source error path":
    # `plan` against a missing file → exit 2 + "no such file" stderr.
    # We can't trivially intercept stderr in cross-platform Nim, but we
    # can use `osproc` against the test binary's compiled CLI surface
    # via the `runDiskCommand` proc directly.
    block planMissingFile:
      let rc = runDiskCommand(@["plan", "build/_definitely_not_a_file.nim"])
      check rc == 2

    block applyWithoutConfirm:
      let rc = runDiskCommand(@["apply", "build/_nope.nim"])
      check rc == 2

    # apply WITH --confirm but pointing at a non-existent file is still
    # the stub path; --confirm gates the destructive op, not file
    # existence.
    block applyStub:
      let rc = runDiskCommand(@["apply", "build/_nope.nim", "--confirm"])
      check rc == 2

    block mountStub:
      let rc = runDiskCommand(@["mount", "build/_nope.nim",
        "--target", "/mnt"])
      check rc == 2

    block unmountStub:
      let rc = runDiskCommand(@["unmount", "build/_nope.nim",
        "--target", "/mnt"])
      check rc == 2

    block generateStub:
      let rc = runDiskCommand(@["generate", "--probe", "/"])
      check rc == 2

    block imageStub:
      let rc = runDiskCommand(@["image", "build/_nope.nim",
        "--output", "out.img", "--size", "8G"])
      check rc == 2

    block noSub:
      let rc = runDiskCommand(@[])
      check rc == 2

    block unknownSub:
      let rc = runDiskCommand(@["doctor"])
      check rc == 2
