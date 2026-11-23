## The rules of a `baseOs:` section (ReproOS Add-On Mode §6.5.1), shared by
## the `profile` macro (which checks each field where the operator wrote
## it) and by `repro infra image` (which checks the built section, layout
## included, before it fetches anything). Every check returns the problem
## as text, "" when there is none, so the macro can report it at the
## field and the image command can refuse with the same words.

import std/[strutils, tables]

import ./types

const
  BaseOsArches* = ["amd64", "arm64", "armhf"]
    ## The add-on's architectures (§6.1).
  BaseOsBuildBoots* = ["pc", "raspi2b"]
    ## The machines an assembly boot runs on (§6.5.2 step 5): `pc` is
    ## x86-64 booting the image's own boot loader; `raspi2b` is QEMU's
    ## Raspberry Pi 2B, booting `kernel7.img` and `bcm2709-rpi-2-b.dtb`
    ## from the boot partition.
  CloudInitSeeds* = ["rootSeedDir", "bootPartition"]
  DefaultBootMountpoint* = "/boot/firmware"
  NoCloudSeedDir* = "/var/lib/cloud/seed/nocloud"
    ## cloud-init's NoCloud seed directory in the root filesystem
    ## (https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html).

type
  BaseOsImageFormat* = enum
    bifRaw = "raw"
    bifRawXz = "raw.xz"
    bifQcow2 = "qcow2"

proc imageFormatOf*(url: string): tuple[ok: bool; format: BaseOsImageFormat] =
  ## How an image URL is unpacked, from its suffix.
  let u = url.toLowerAscii()
  if u.endsWith(".img.xz") or u.endsWith(".raw.xz"): (true, bifRawXz)
  elif u.endsWith(".img") or u.endsWith(".raw"): (true, bifRaw)
  elif u.endsWith(".qcow2"): (true, bifQcow2)
  else: (false, bifRaw)

proc parseDiskSize*(s: string): int64 =
  ## `"512M"` / `"6G"` in bytes (binary units); -1 when malformed.
  if s.len < 2: return -1
  let unit = s[^1]
  let digits = s[0 ..< ^1]
  if not digits.allCharsInSet(Digits) or digits.len > 12: return -1
  let n = parseBiggestInt(digits)
  if n <= 0: return -1
  case unit
  of 'M': n * 1024 * 1024
  of 'G': n * 1024 * 1024 * 1024
  else: -1

proc isLowerHex(s: string): bool =
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}: return false
  true

proc baseOsScalarProblem*(field, value: string): string =
  ## The problem with one scalar field of `baseOs:`, or "".
  case field
  of "image":
    if not (value.startsWith("https://") or value.startsWith("file:///")):
      return "baseOs.image must be an https:// or file:/// URL, got \"" &
        value & "\""
    if not imageFormatOf(value).ok:
      return "baseOs.image \"" & value & "\" has no suffix that says how " &
        "to unpack it (.img, .raw, .img.xz, .raw.xz, .qcow2)"
  of "sha256":
    if value.len != 64 or not isLowerHex(value):
      return "baseOs.sha256 must be 64 lower-case hexadecimal digits, " &
        "got \"" & value & "\""
  of "arch":
    if value notin BaseOsArches:
      return "baseOs.arch must be one of " & BaseOsArches.join(", ") &
        ", got \"" & value & "\""
  of "buildBoot":
    if value notin BaseOsBuildBoots:
      return "baseOs.buildBoot must be one of " &
        BaseOsBuildBoots.join(", ") & ", got \"" & value & "\""
  of "diskSize":
    if parseDiskSize(value) < 0:
      return "baseOs.diskSize must be a whole number of M or G (\"6G\"), " &
        "got \"" & value & "\""
  of "hostname":
    if value.len == 0 or value.len > 63 or
        not value.allCharsInSet({'a'..'z', '0'..'9', '-'}) or
        value[0] == '-' or value[^1] == '-':
      return "baseOs.hostname must be one lower-case DNS label, got \"" &
        value & "\""
  of "bootMountpoint":
    if not value.startsWith("/") or value == "/" or ".." in value or
        value.endsWith("/"):
      return "baseOs.bootMountpoint must be an absolute directory other " &
        "than /, got \"" & value & "\""
  else:
    return "baseOs: unknown field " & field
  ""

proc bootFileNameProblem*(name: string): string =
  if name.len == 0 or name in [".", ".."] or '/' in name or '\\' in name or
      '\0' in name:
    return "baseOs.bootFiles: \"" & name & "\" is not one path component"
  ""

proc cloudInitSeedProblem*(seed: string): string =
  if seed notin CloudInitSeeds:
    return "baseOs.cloudInit.seed must be one of " &
      CloudInitSeeds.join(", ") & ", got \"" & seed & "\""
  ""

proc anchorPathProblem*(field, path: string): string =
  ## Anchor files are named relative to the profile's directory (a sibling
  ## of the configuration may be named through `..`: rpi2's signer key is
  ## the infra repository's services/repro-deploy-manifest/ file).
  if path.len == 0 or path.startsWith("/") or '\0' in path:
    return "baseOs.bootstrap." & field & " must be a path relative to the " &
      "profile's directory, got \"" & path & "\""
  ""

proc effectiveBootMountpoint*(b: BaseOsIntent): string =
  if b.bootMountpoint.len > 0: b.bootMountpoint else: DefaultBootMountpoint

proc filesystemMountpoint*(p: PartitionSpec): string =
  if p.content.kind == cfsFilesystem: p.content.mountpoint else: ""

proc baseOsProblem*(b: BaseOsIntent): string =
  ## The problem with a built `baseOs:` section as a whole, or "".
  if not b.declared: return "the profile declares no baseOs: section"
  for (f, v) in [("image", b.image), ("sha256", b.sha256), ("arch", b.arch),
                 ("buildBoot", b.buildBoot)]:
    let p = baseOsScalarProblem(f, v)
    if p.len > 0: return p
  for (f, v) in [("diskSize", b.diskSize), ("hostname", b.hostname),
                 ("bootMountpoint", b.bootMountpoint)]:
    if v.len > 0:
      let p = baseOsScalarProblem(f, v)
      if p.len > 0: return p
  if b.buildBoot == "raspi2b" and b.arch != "armhf":
    return "baseOs.buildBoot raspi2b boots only an armhf image, not " & b.arch
  if b.buildBoot == "raspi2b":
    # QEMU's SD card model refuses a card whose size is not a power of two.
    let size = parseDiskSize(b.diskSize)
    if size <= 0 or (size and (size - 1)) != 0:
      return "baseOs.buildBoot raspi2b needs a diskSize that is a power of " &
        "two (QEMU's SD card model), got \"" & b.diskSize & "\""
  if b.buildBoot == "pc" and b.arch != "amd64":
    return "baseOs.buildBoot pc boots only an amd64 image, not " & b.arch
  if b.layout.disks.len != 1:
    return "baseOs.layout must declare exactly one disk, got " &
      $b.layout.disks.len
  if b.layout.pools.len > 0:
    return "baseOs.layout must declare no ZFS pool"
  for name, d in b.layout.disks:
    if d.`type` notin ["gpt", "mbr"]:
      return "baseOs.layout disk \"" & name & "\": type must be gpt or " &
        "mbr, got \"" & d.`type` & "\""
    if d.partitions.len == 0:
      return "baseOs.layout disk \"" & name & "\" declares no partition"
    var roots, boots = 0
    for pn, p in d.partitions:
      let mp = filesystemMountpoint(p)
      if mp == "/": inc roots
      if mp == effectiveBootMountpoint(b): inc boots
      if p.content.kind notin {cfsNone, cfsFilesystem}:
        return "baseOs.layout partition \"" & pn & "\": only a plain " &
          "filesystem (or no content) can be verified in an image"
    if roots != 1:
      return "baseOs.layout must mount exactly one partition at /"
    if b.bootFiles.len > 0 and boots != 1:
      return "baseOs.bootFiles needs exactly one partition mounted at " &
        effectiveBootMountpoint(b)
    if b.cloudInit.declared and b.cloudInit.seed == "bootPartition" and
        boots != 1:
      return "baseOs.cloudInit seed bootPartition needs exactly one " &
        "partition mounted at " & effectiveBootMountpoint(b)
  for f in b.bootFiles:
    let p = bootFileNameProblem(f.name)
    if p.len > 0: return p
  if b.cloudInit.declared:
    let p = cloudInitSeedProblem(b.cloudInit.seed)
    if p.len > 0: return p
  for (f, v) in [("deploySigners", b.bootstrap.deploySigners),
                 ("cachePublishers", b.bootstrap.cachePublishers)]:
    if v.len > 0:
      let p = anchorPathProblem(f, v)
      if p.len > 0: return p
  if b.bootstrap.agentTarget.len > 0 and b.bootstrap.agentSources.len == 0:
    return "baseOs.bootstrap.agentTarget needs agentSources"
  for s in b.bootstrap.agentSources:
    if not (s.startsWith("http://") or s.startsWith("https://")):
      return "baseOs.bootstrap.agentSources: \"" & s & "\" is not an " &
        "http(s) URL"
  if b.bootstrap.cacheUrl.len > 0 and not (b.bootstrap.cacheUrl.startsWith(
      "http://") or b.bootstrap.cacheUrl.startsWith("https://")):
    return "baseOs.bootstrap.cacheUrl must be an http(s) URL"
  ""
