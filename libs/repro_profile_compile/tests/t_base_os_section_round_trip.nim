## The `baseOs:` section of a system profile (ReproOS Add-On Mode §6.5.1,
## milestone A16) from the Nim DSL to what `repro infra image` reads.
##
## The section travels the path every compiled profile takes -- the
## `profile` macro, the profile binary's JSON, the RBPI envelope (schema 14)
## -- and must come out whole: the pinned image, the `repro disk` layout,
## the boot firmware files (one of them read with `staticRead`), the
## cloud-init seed and the bootstrap options. It is image-time intent, so
## the canonical system-profile text the switch and the deploy agent read
## must be the same with the section and without it. The macro refuses a
## malformed section at the field the operator wrote, and `baseOsProblem`
## refuses what only the built section shows.
##
## No mocks: the real macro, a real `nim` compile of the profile binary
## (`compileProfileBinary`), the real codecs, adapter and renderer.

import std/[os, sets, strutils, tables, tempfiles, unittest]

import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_infra

const Sha = "2c302771f34c67a0b7ae7aa2e0dcdd3eac660504be59193c011ba79d412e1632"

const ImageSection = """
  baseOs:
    image: "https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2026-10-06/2026-10-06-raspios-trixie-armhf-lite.img.xz"
    sha256: """" & Sha & """"
    arch: "armhf"
    buildBoot: "raspi2b"
    diskSize: "8G"
    hostname: "rpi2"
    layout:
      disks:
        "sd":
          table: "mbr"
          partitions:
            "bootfs":
              size: "512M"
              content:
                filesystem:
                  format: "vfat"
                  label: "bootfs"
                  mountpoint: "/boot/firmware"
            "rootfs":
              size: "100%"
              content:
                filesystem:
                  format: "ext4"
                  label: "rootfs"
                  mountpoint: "/"
    bootFiles:
      "config.txt": configTxt
      "cmdline.txt": "console=serial0,115200 root=PARTUUID=4c032286-02 rootwait\n"
    cloudInit:
      seed: "bootPartition"
      userData: "#cloud-config\nhostname: rpi2\n"
      metaData: "instance-id: rpi2\n"
    bootstrap:
      deploySigners: "deploy-signers.anchors"
      cachePublishers: "cache-publishers.anchors"
      cacheUrl: "https://cache" & ".example:7878"
      agentTarget: "rpi2"
      agentSources: [manifestBase & "/rpi2/latest.rdm"]
      pollInterval: 600
"""

const Resources = """
  addOn:
    managedEtcPrefixes:
      "/etc/tb/"
  resources:
    fsSystemFile(path = "/etc/tb/hello", content = "hi\n", address = "hello")
"""

proc profileText(withBaseOs: bool; extra = ""): string =
  "import repro_profile\n\nconst configTxt = staticRead(\"config.txt\")\n" &
    "const manifestBase = \"http://manifests.example\"\n\n" &
    "profile \"img\":\n" &
    (if withBaseOs: ImageSection else: "") & extra & Resources

proc compileIntent(dir, text: string): ProfileIntent =
  ## Compile ``text`` as a profile in ``dir``; a failure re-raises with the
  ## compiler's transcript, so a red case says why.
  createDir(dir)
  writeFile(dir / "config.txt", "arm_boost=1\n[all]\n")
  writeFile(dir / "system.nim", text)
  let res = compileProfileBinary(profileRoot = dir / "system.nim",
    nimcacheDir = dir / "nimcache", outBinary = dir / "nimcache" / "profile",
    repoRoot = reprobuildRepoRoot(), verbose = false)
  decodeRbpi(rbpiBytesFromJson(res.jsonOutput))

proc compileIntentOrShow(dir, text: string): ProfileIntent =
  try:
    compileIntent(dir, text)
  except CompileFailure as e:
    echo e.stderrText
    raise

proc compileFails(dir, text: string): string =
  ## The compile's diagnostic; "" when it compiled.
  try:
    discard compileIntent(dir, text)
    ""
  except CompileFailure as e:
    e.msg & "\n" & e.stderrText
  except CatchableError as e:
    if e.msg.len == 0: "failed without a message" else: e.msg

let tmp = createTempDir("repro-a16-baseos-", "")

# The two compiled profiles, compiled on first use: the test runner runs
# each case in a process of its own, so a case cannot rely on an earlier
# case having compiled them.
var withSectionMemo, withoutMemo: ProfileIntent
var haveWithSection, haveWithout: bool

proc withSection(): ProfileIntent =
  if not haveWithSection:
    withSectionMemo = compileIntentOrShow(tmp / "with", profileText(true))
    haveWithSection = true
  withSectionMemo

proc without(): ProfileIntent =
  if not haveWithout:
    withoutMemo = compileIntentOrShow(tmp / "without", profileText(false))
    haveWithout = true
  withoutMemo

suite "the baseOs: section, DSL to image command":
  test "the macro builds the whole section":
    let b = withSection().baseOs
    check b.declared
    check b.image.endsWith("2026-10-06-raspios-trixie-armhf-lite.img.xz")
    check b.sha256 == Sha
    check b.arch == "armhf" and b.buildBoot == "raspi2b"
    check b.diskSize == "8G" and b.hostname == "rpi2"
    check b.layout.disks.len == 1
    let d = b.layout.disks["sd"]
    check d.`type` == "mbr"
    var names: seq[string]
    for n, _ in d.partitions: names.add n
    check names == @["bootfs", "rootfs"]
    check d.partitions["bootfs"].content.format == "vfat"
    check d.partitions["bootfs"].content.label == "bootfs"
    check d.partitions["rootfs"].content.mountpoint == "/"
    check b.bootFiles.len == 2
    check b.bootFiles[0].name == "config.txt"
    check b.bootFiles[0].content == "arm_boost=1\n[all]\n"   # staticRead
    check b.bootFiles[1].name == "cmdline.txt"
    check b.cloudInit.declared and b.cloudInit.seed == "bootPartition"
    check b.cloudInit.userData == "#cloud-config\nhostname: rpi2\n"
    check b.cloudInit.networkConfig == ""     # not given: the image's own
    check b.bootstrap.agentSources == @["http://manifests.example/rpi2/latest.rdm"]
    check b.bootstrap.pollIntervalSec == 600
    check b.bootstrap.cacheUrl == "https://cache.example:7878"   # an expression
    check baseOsProblem(b) == ""

  test "RBPI and JSON carry the section unchanged":
    let compiled = withSection()
    check compiled.baseOs.declared
    let viaRbpi = decodeRbpi(encodeRbpi(compiled))
    check encodeBaseOs(viaRbpi.baseOs) == encodeBaseOs(compiled.baseOs)
    let viaJson = parseProfileIntentJson(emitProfileIntentJson(compiled))
    check encodeBaseOs(viaJson.baseOs) == encodeBaseOs(compiled.baseOs)

  test "a profile without the section encodes without the key":
    check not without().baseOs.declared
    check "baseOs" notin emitProfileIntentJson(without())
    check not decodeRbpi(encodeRbpi(without())).baseOs.declared

  test "the canonical system-profile text is the same with and without it":
    let target = systemPlanTarget("rpi2", toHashSet(["default"]), srAddOnDebian)
    let a = renderSystemProfileToText(adaptSystemProfile(withSection(), target).profile)
    let b = renderSystemProfileToText(adaptSystemProfile(without(), target).profile)
    check a.len > 0
    check a == b
    check "baseOs" notin a and Sha notin a

  test "a corrupt section in an envelope is refused, never dropped":
    var bad = withSection()
    check bad.baseOs.declared
    bad.baseOs.layout = DiskLayout()
    # The JSON parser checks shape; a section with a non-object layout is
    # corrupt.
    let broken = emitProfileIntentJson(bad).replace("\"layout\":{", "\"layout\":[{")
    expect CatchableError:
      discard parseProfileIntentJson(broken)

  test "the macro refuses a malformed field where it is written":
    let shortSha = profileText(true).replace(Sha, "abc")
    check "baseOs.sha256 must be 64" in compileFails(tmp / "sha", shortSha)
    let badArch = profileText(true).replace("arch: \"armhf\"", "arch: \"riscv\"")
    check "baseOs.arch must be one of" in compileFails(tmp / "arch", badArch)
    let unknown = profileText(true).replace("    hostname: \"rpi2\"\n",
      "    hostname: \"rpi2\"\n    kernel: \"x\"\n")
    check "baseOs: unknown field kernel" in compileFails(tmp / "unknown", unknown)
    let noLayout = profileText(true).replace("    layout:", "    xlayout:")
    check "unknown field xlayout" in compileFails(tmp / "nolayout", noLayout)
    let badName = profileText(true).replace("\"cmdline.txt\":", "\"../cmdline.txt\":")
    check "is not one path component" in compileFails(tmp / "name", badName)
    let twice = profileText(true, ImageSection)
    check "exactly one `baseOs:` section" in compileFails(tmp / "twice", twice)

suite "baseOsProblem: what only the built section shows":
  proc base(): BaseOsIntent =
    result = BaseOsIntent(declared: true,
      image: "file:///images/debian.qcow2", sha256: Sha, arch: "amd64",
      buildBoot: "pc")
    var d = DiskSpec(`type`: "gpt")
    d.partitions["root"] = PartitionSpec(size: "100%",
      content: ContentSpec(kind: cfsFilesystem, format: "ext4", mountpoint: "/"))
    result.layout.disks["main"] = d

  test "a well-formed section has no problem":
    check baseOsProblem(base()) == ""

  test "the assembly machine must boot the architecture":
    var b = base()
    b.buildBoot = "raspi2b"
    check "raspi2b boots only an armhf image" in baseOsProblem(b)

  test "exactly one disk, exactly one root":
    var b = base()
    b.layout.disks["second"] = b.layout.disks["main"]
    check "exactly one disk" in baseOsProblem(b)
    var c = base()
    c.layout.disks["main"].partitions["root"].content.mountpoint = "/srv"
    check "exactly one partition at /" in baseOsProblem(c)

  test "boot files need the boot partition":
    var b = base()
    b.bootFiles.add BaseOsBootFile(name: "config.txt", content: "x")
    check "mounted at /boot/firmware" in baseOsProblem(b)

  test "a raspi2b assembly boot needs a power-of-two disk":
    var b = base()
    b.arch = "armhf"
    b.buildBoot = "raspi2b"
    check "power of two" in baseOsProblem(b)
    b.diskSize = "6G"
    check "power of two" in baseOsProblem(b)
    b.diskSize = "8G"
    check baseOsProblem(b) == ""

  test "an agent target needs its sources":
    var b = base()
    b.bootstrap.agentTarget = "tb"
    check "needs agentSources" in baseOsProblem(b)

  test "image suffixes and sizes":
    check imageFormatOf("https://x/a.img.xz") == (true, bifRawXz)
    check imageFormatOf("file:///a.qcow2") == (true, bifQcow2)
    check not imageFormatOf("https://x/a.zip").ok
    check parseDiskSize("6G") == 6'i64 * 1024 * 1024 * 1024
    check parseDiskSize("512M") == 512'i64 * 1024 * 1024
    check parseDiskSize("6") == -1 and parseDiskSize("1.5G") == -1

removeDir(tmp)
