## The upstream image's own layout, read without mounting anything, and
## checked against a `baseOs:` section's `layout:` (ReproOS Add-On Mode
## §6.5.1, §6.5.2 step 3).
##
## An add-on image starts from the distribution's image, so its layout is
## verified rather than created: the partition-table type, the number and
## order of partitions, and each partition's filesystem format and label
## where the layout names one. The table is read with `sfdisk --json`
## (util-linux; https://man7.org/linux/man-pages/man8/sfdisk.8.html), which
## works on an image file as an unprivileged user. Filesystems are
## recognised by their own on-disk signatures:
##
## - ext2/3/4: the superblock at byte 1024, `s_magic` 0xEF53 at +0x38,
##   `s_feature_incompat` at +0x60 (EXTENTS 0x40 marks ext4),
##   `s_volume_name` at +0x78 (16 bytes)
##   (https://www.kernel.org/doc/html/latest/filesystems/ext4/globals.html);
## - FAT: the boot sector's 0x55AA signature at 510, the file-system type
##   string `FAT32   ` at 82 (label at 71) or `FAT16   ` / `FAT12   ` at 54
##   (label at 43), 11 bytes each (Microsoft FAT specification, "BPB").
##
## Everything here is a pure function of bytes, so the unit tests feed it
## real superblocks and `sfdisk` documents without a disk.

import std/[algorithm, json, strutils, tables]

import repro_profile/types
import repro_profile/base_os

type
  ImageTableKind* = enum
    itMbr = "mbr"
    itGpt = "gpt"

  ImagePartition* = object
    number*: int        ## the partition number (`<image>N` in sfdisk's node)
    start*: int64       ## first sector
    sectors*: int64     ## length in sectors
    typeCode*: string   ## MBR type byte or GPT type GUID, as sfdisk prints it

  ImageTable* = object
    kind*: ImageTableKind
    sectorSize*: int
    partitions*: seq[ImagePartition]  ## ordered by partition number
    lastLba*: int64                   ## GPT: the last usable sector; MBR: 0

  FsProbe* = object
    format*: string   ## "ext4", "ext3", "ext2", "vfat" or "" (unrecognised)
    label*: string    ## "" when the filesystem carries none

  ImageLayoutError* = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(ImageLayoutError, msg)

proc partitionNumber(node: string): int =
  ## The trailing decimal digits of sfdisk's `node` (`image.raw15` -> 15).
  var i = node.len
  while i > 0 and node[i - 1] in Digits: dec i
  if i == node.len: fail("sfdisk node '" & node & "' carries no partition number")
  parseInt(node[i .. ^1])

proc parseSfdiskJson*(text: string): ImageTable =
  ## The partition table of `sfdisk --json <image>`.
  let root = try: parseJson(text)
             except JsonParsingError as e: fail("sfdisk --json: " & e.msg)
  if root.kind != JObject or not root.hasKey("partitiontable"):
    fail("sfdisk --json printed no partition table")
  let t = root["partitiontable"]
  case t{"label"}.getStr()
  of "dos": result.kind = itMbr
  of "gpt": result.kind = itGpt
  else: fail("unsupported partition table '" & t{"label"}.getStr() & "'")
  if t{"unit"}.getStr() != "sectors":
    fail("sfdisk --json reports units of '" & t{"unit"}.getStr() & "'")
  result.sectorSize = t{"sectorsize"}.getInt(512)
  result.lastLba = t{"lastlba"}.getBiggestInt(0)
  for p in t{"partitions"}.getElems():
    result.partitions.add ImagePartition(
      number: partitionNumber(p{"node"}.getStr()),
      start: p{"start"}.getBiggestInt(), sectors: p{"size"}.getBiggestInt(),
      typeCode: p{"type"}.getStr())
  result.partitions.sort(proc(a, b: ImagePartition): int = cmp(a.number, b.number))

proc le16(s: string; o: int): int = int(s[o].uint8) or (int(s[o+1].uint8) shl 8)
proc le32(s: string; o: int): int64 =
  for i in countdown(3, 0): result = (result shl 8) or int64(s[o+i].uint8)

proc trimLabel(raw: string): string =
  result = raw
  let z = result.find('\0')
  if z >= 0: result.setLen(z)
  result = result.strip(leading = false)

proc probeFilesystemBytes*(head: string): FsProbe =
  ## Recognise the filesystem whose first bytes are `head` (at least 2048).
  if head.len >= 2048 and le16(head, 1024 + 0x38) == 0xEF53:
    let incompat = le32(head, 1024 + 0x60)
    let compat = le32(head, 1024 + 0x5C)
    result.format = if (incompat and 0x40) != 0: "ext4"
                    elif (compat and 0x4) != 0: "ext3"
                    else: "ext2"
    result.label = trimLabel(head[1024 + 0x78 ..< 1024 + 0x78 + 16])
    return
  if head.len >= 512 and head[510] == '\x55' and head[511] == '\xAA':
    var label = ""
    if head[82 ..< 90] == "FAT32   ":
      label = head[71 ..< 82]
    elif head[54 ..< 62] in ["FAT16   ", "FAT12   "]:
      label = head[43 ..< 54]
    else:
      return
    result.format = "vfat"
    let l = trimLabel(label)
    result.label = if l == "NO NAME": "" else: l

proc probeFilesystem*(imagePath: string; offset: int64): FsProbe =
  ## Recognise the filesystem at `offset` bytes into `imagePath`.
  var f: File
  if not open(f, imagePath, fmRead): fail("cannot open " & imagePath)
  defer: f.close()
  f.setFilePos(offset)
  var buf = newString(2048)
  let n = f.readBuffer(addr buf[0], buf.len)
  buf.setLen(max(n, 0))
  probeFilesystemBytes(buf)

proc onlyDisk*(b: BaseOsIntent): tuple[name: string; disk: DiskSpec] =
  for n, d in b.layout.disks: return (n, d)
  fail("baseOs.layout declares no disk")

proc partitionIndexAt*(b: BaseOsIntent; mountpoint: string): int =
  ## The index (declaration order, = partition-number order) of the
  ## partition the layout mounts at `mountpoint`, or -1.
  var i = 0
  for _, p in onlyDisk(b).disk.partitions:
    if filesystemMountpoint(p) == mountpoint: return i
    inc i
  -1

proc endOfDiskIndex*(t: ImageTable): int =
  ## The index of the partition whose extent ends last on the disk -- the
  ## one `diskSize` grows (§6.5.1). The GPT images of Debian's cloud put
  ## their root partition, number 1, after the BIOS-boot and EFI ones.
  result = -1
  var best = -1'i64
  for i, p in t.partitions:
    if p.start + p.sectors > best:
      best = p.start + p.sectors
      result = i

proc verifyLayout*(b: BaseOsIntent; t: ImageTable; probes: seq[FsProbe]): string =
  ## The first mismatch between the image (`t`, and `probes[i]` for
  ## `t.partitions[i]`) and the section's layout, or "" when they agree.
  let (diskName, disk) = onlyDisk(b)
  if $t.kind != disk.`type`:
    return "the image's partition table is " & $t.kind & ", but layout disk \"" &
      diskName & "\" declares " & disk.`type`
  if t.partitions.len != disk.partitions.len:
    return "the image has " & $t.partitions.len & " partition(s), but layout " &
      "disk \"" & diskName & "\" declares " & $disk.partitions.len
  var i = 0
  for name, p in disk.partitions:
    let have = probes[i]
    let num = t.partitions[i].number
    if p.content.kind == cfsFilesystem:
      if have.format.len == 0:
        return "partition " & $num & " (\"" & name & "\") holds no filesystem " &
          "this command recognises, but the layout declares " & p.content.format
      let want = if p.content.format == "fat32": "vfat" else: p.content.format
      if have.format != want:
        return "partition " & $num & " (\"" & name & "\") is " & have.format &
          ", but the layout declares " & p.content.format
      if p.content.label.len > 0 and have.label != p.content.label:
        return "partition " & $num & " (\"" & name & "\") is labelled \"" &
          have.label & "\", but the layout declares \"" & p.content.label & "\""
    inc i
  let grow = endOfDiskIndex(t)
  if b.diskSize.len > 0:
    var j = 0
    for name, p in disk.partitions:
      if j == grow:
        if p.content.kind != cfsFilesystem or p.content.format != "ext4":
          return "baseOs.diskSize grows partition " & $t.partitions[j].number &
            " (\"" & name & "\"), the last on the disk, which is not ext4"
      inc j
  ""
