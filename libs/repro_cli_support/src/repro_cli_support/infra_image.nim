## `repro infra image --host <host>`: a ready-to-flash disk image of an
## add-on host, synthesised from the digest-pinned upstream image its
## profile's `baseOs:` section names (ReproOS Add-On Mode §6.5.2).
##
## The command needs no privilege. Filesystems are written without being
## mounted -- `debugfs` for ext4 (e2fsprogs; its `<file>?offset=<bytes>` I/O
## option reaches a filesystem inside a partitioned image,
## https://man7.org/linux/man-pages/man8/debugfs.8.html) and `mtools` for
## FAT (`-i <file>@@<offset>`, https://www.gnu.org/software/mtools/manual/) --
## partitions are grown with `sfdisk`, `e2fsck` and `resize2fs`, and the
## image is booted once in QEMU (the assembly boot), where §6.1's preflight,
## §6.2's bootstrap and `repro infra apply` run on the target's own system
## (`repro_addon/image_assemble`). This module has no bootstrap or apply
## code of its own.
##
## Steps (the spec's numbering):
##  2. fetch into `<cache>/reprobuild/base-os/<sha256>/` and check the digest
##     before any use, every time;
##  3. unpack to a raw image in this run's working directory, verify the
##     layout (`repro_addon/image_layout`), grow to `diskSize`;
##  4. stage the payload into the root filesystem;
##  5. boot once (`repro_addon/image_boot`), read `result.json`;
##  6. finish: remove the build-only files, write the declared boot files
##     and cloud-init seed, write the output, its digest and its manifest.
##
## The build-host tools are run through the explicit `uncontrolled` escape
## hatch (`repro_addon/host_exec.runHostTool` with an absolute path found on
## `PATH`), because they ARE the build host's: `xz`, `qemu-img`, `sfdisk`,
## `debugfs`, `e2fsck`, `resize2fs`, `mcopy`, `mdel`, `curl` and the QEMU
## system emulator. A missing one is refused by name before anything runs.

import std/[algorithm, json, os, osproc, posix, sequtils, sets, streams,
            strutils, tables, times]

import nimcrypto/[hash, sha2]

import repro_core
import repro_core/ambient_execution
import repro_profile/types
import repro_profile/base_os
import repro_infra
import repro_dsl_stdlib/packages/apt_closure
import repro_addon/host_exec
from repro_addon/fingerprint import sha256Hex
import repro_addon/image_assemble
import repro_addon/image_boot
import repro_addon/image_layout
import repro_addon/key_material

type
  EInfraImage* = object of CatchableError
    ## The image could not be synthesised; nothing was written at the
    ## output path.

  InfraImageOptions* = object
    host*: string
    profilePath*: string      ## the source profile, as the operator named it
                              ## (for the manifest: an absolute path would
                              ## publish the build host's directory layout)
    profileDir*: string       ## where `baseOs.bootstrap` files are relative to
    baseOs*: BaseOsIntent
    profileText*: string      ## the host profile's canonical text
    addonBinary*: string
    addonSha256*: string
    output*: string
    compress*: string         ## "xz" | "none"
    debCache*: string         ## a directory of `<sha256>.deb`, or ""
    workDir*: string          ## "" => under the cache
    keepWork*: bool
    assemblyTimeoutSec*: int  ## 0 => the machine's default
    log*: proc(line: string) {.closure.}

  InfraImageResult* = object
    output*: string
    outputSha256*: string
    manifestPath*: string
    assembly*: AssemblyResult
    workDir*: string

const
  RequiredTools = ["qemu-img", "sfdisk", "debugfs", "e2fsck", "resize2fs",
                   "mcopy", "mdel"]
  AssemblyDefaultTimeoutSec = [("pc", 1800), ("raspi2b", 4 * 3600)]

proc fail(msg: string) {.noreturn.} =
  raise newException(EInfraImage, msg)

proc say(o: InfraImageOptions; line: string) =
  if o.log != nil: o.log(line)

proc tool(name: string): string =
  ## The tool's path on PATH, NOT resolved through symlinks: mtools is one
  ## multi-call binary that dispatches on its argv[0] (`mcopy`, `mdel`).
  result = uncontrolledFindExe(name, followSymlinks = false)
  if result.len == 0:
    fail("repro infra image needs `" & name & "` on PATH (" &
      "e2fsprogs, util-linux, mtools, xz, qemu)")

proc run(argv: openArray[string]; input = ""; timeoutSec = 0;
         okCodes: openArray[int] = [0]): string =
  ## Run a build-host tool; refuse a non-zero exit (or one not in okCodes).
  let r = runHostTool(argv, input = input, timeoutSec = timeoutSec,
                      path = getEnv("PATH"))
  if r.exitCode notin okCodes:
    fail(argv[0].extractFilename & " " & argv[1 .. ^1].join(" ") &
      " exited " & $r.exitCode & ":\n" & r.output)
  r.output

proc sha256File*(path: string): string =
  var f: File
  if not open(f, path, fmRead): fail("cannot read " & path)
  defer: f.close()
  var ctx: sha256
  ctx.init()
  var buf = newString(1 shl 20)
  while true:
    let n = f.readBuffer(addr buf[0], buf.len)
    if n <= 0: break
    ctx.update(cast[ptr byte](addr buf[0]), uint(n))
  toLowerAscii($ctx.finish())

proc pipeToFile(argv: openArray[string]; dest: string) =
  ## `argv > dest`, without a shell.
  let p = uncontrolledStartProcess(argv[0], args = argv[1 .. ^1],
                                   options = {})
  defer: p.close()
  var outF: File
  if not open(outF, dest, fmWrite): fail("cannot write " & dest)
  let s = p.outputStream
  var buf = newString(1 shl 20)
  while true:
    let n = s.readData(addr buf[0], buf.len)
    if n <= 0: break
    discard outF.writeBuffer(addr buf[0], n)
  outF.close()
  let rc = p.waitForExit()
  if rc != 0: fail(argv[0].extractFilename & " exited " & $rc)

proc cacheRoot(): string =
  let xdg = getEnv("XDG_CACHE_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".cache") / "reprobuild"

# ---------------------------------------------------------------------------
# Step 2: fetch and verify.
# ---------------------------------------------------------------------------

proc fetchBaseImage*(b: BaseOsIntent; log: proc(l: string) = nil): string =
  ## The verified upstream file. A cached copy is checked again; a mismatch
  ## is refused, never replaced silently (`EBaseOsDigest`).
  let name = b.image.split('/')[^1]
  if b.image.startsWith("file://"):
    result = b.image["file://".len .. ^1]
    if not fileExists(result): fail("baseOs.image " & b.image & " does not exist")
  else:
    let dir = cacheRoot() / "base-os" / b.sha256
    createDir(dir)
    result = dir / name
    if not fileExists(result):
      let part = result & ".part-" & $getCurrentProcessId()
      if log != nil: log("fetching " & b.image)
      discard run([tool("curl"), "-sSfL", "--retry", "3", "-o", part, b.image],
                  timeoutSec = 3600)
      moveFile(part, result)
  let have = sha256File(result)
  if have != b.sha256:
    fail("EBaseOsDigest: " & result & " hashes to " & have &
      ", not the pinned " & b.sha256 & "; nothing was written")

# ---------------------------------------------------------------------------
# debugfs helpers: one ext4 filesystem inside the image.
# ---------------------------------------------------------------------------

type Ext4 = object
  spec: string   ## `<image>?offset=<bytes>`

proc ext4At(image: string; offsetBytes: int64): Ext4 =
  Ext4(spec: image & "?offset=" & $offsetBytes)

proc debugfs(fs: Ext4; command: string; write = false): string =
  var argv = @[tool("debugfs")]
  if write: argv.add "-w"
  argv.add @["-R", command, fs.spec]
  run(argv)

proc exists(fs: Ext4; path: string): bool =
  let r = runHostTool([tool("debugfs"), "-R", "stat " & path, fs.spec],
                      path = getEnv("PATH"))
  r.exitCode == 0 and "File not found" notin r.output and
    "Inode:" in r.output

proc catFile(fs: Ext4; path: string): string =
  ## The bytes of a file (debugfs's banner goes to stderr, kept apart).
  let p = uncontrolledStartProcess(tool("debugfs"),
    args = ["-R", "cat " & path, fs.spec], options = {})
  defer: p.close()
  result = p.outputStream.readAll()
  discard p.waitForExit()

proc listDir(fs: Ext4; path: string): seq[string] =
  ## Entry names (`ls -p` prints `/inode/mode/uid/gid/name/size/`).
  for line in debugfs(fs, "ls -p " & path).splitLines():
    let parts = line.split('/')
    if parts.len >= 7 and parts[5] notin [".", ".."] and parts[5].len > 0:
      result.add parts[5]

proc listEntries(fs: Ext4; path: string): seq[tuple[name: string; isDir: bool]] =
  ## Entries with their type, from `ls -p`'s mode field.
  for line in debugfs(fs, "ls -p " & path).splitLines():
    let parts = line.split('/')
    if parts.len >= 7 and parts[5] notin [".", ".."] and parts[5].len > 0:
      result.add (parts[5], parts[2].startsWith("40"))

proc removeTree(fs: Ext4; path: string; acc: var seq[string]) =
  ## Commands removing `path` and everything below it, deepest first.
  for (n, isDir) in fs.listEntries(path):
    if isDir: fs.removeTree(path / n, acc)
    else: acc.add "rm " & path / n
  acc.add "rmdir " & path

proc copyOut(fs: Ext4; path, localParent: string) =
  ## `debugfs rdump`: `path` and everything below it into `localParent`,
  ## with the files' permission bits.
  createDir(localParent)
  discard run([tool("debugfs"), "-R", "rdump " & path & " " & localParent,
               fs.spec])

proc runScript(fs: Ext4; workDir: string; lines: seq[string]) =
  ## Run `lines` as one `debugfs -w -f` script and refuse any error line
  ## (debugfs reports a failed command and goes on).
  let f = workDir / "debugfs-" & $epochTime().int64 & ".cmds"
  writeFile(f, lines.join("\n") & "\n")
  let out1 = run([tool("debugfs"), "-w", "-f", f, fs.spec])
  for line in out1.splitLines():
    let l = line.toLowerAscii()
    if l.startsWith("debugfs:"): continue
    if ": " in line and ("error" in l or "not found" in l or
        "already exists" in l or "could not" in l or "no free" in l or
        "invalid" in l):
      fail("debugfs on " & fs.spec & ": " & line & "\nscript:\n" &
        lines.join("\n"))

proc mkdirChain(fs: Ext4; path: string; mode: int; acc: var seq[string];
                created: var seq[string]) =
  ## Commands creating every missing directory of `path`, root-owned.
  var cur = ""
  for comp in path.split('/'):
    if comp.len == 0: continue
    cur.add "/" & comp
    if cur in created: continue
    if not fs.exists(cur):
      acc.add "mkdir " & cur
      acc.add "sif " & cur & " uid 0"
      acc.add "sif " & cur & " gid 0"
      acc.add "sif " & cur & " mode 0" & toOct(0o40000 or mode, 6)
      created.add cur

proc putFile(fs: Ext4; acc: var seq[string]; local, dest: string; mode: int;
             replace: bool) =
  if replace: acc.add "rm " & dest
  acc.add "write " & local & " " & dest
  acc.add "sif " & dest & " uid 0"
  acc.add "sif " & dest & " gid 0"
  acc.add "sif " & dest & " mode 0" & toOct(0o100000 or mode, 6)

# ---------------------------------------------------------------------------
# The steps.
# ---------------------------------------------------------------------------

proc partOffset(t: ImageTable; i: int): int64 =
  t.partitions[i].start * int64(t.sectorSize)

proc readTable(image: string): ImageTable =
  parseSfdiskJson(run([tool("sfdisk"), "--json", image]))

proc probeAll(image: string; t: ImageTable): seq[FsProbe] =
  for i in 0 ..< t.partitions.len:
    result.add probeFilesystem(image, partOffset(t, i))

proc unpack(o: InfraImageOptions; src, dest: string) =
  let (_, fmt) = imageFormatOf(o.baseOs.image)
  case fmt
  of bifRaw:
    discard run(["/usr/bin/env", "cp", "--reflink=auto", "--sparse=always",
                 src, dest])
  of bifRawXz:
    pipeToFile([tool("xz"), "-dc", src], dest)
  of bifQcow2:
    discard run([tool("qemu-img"), "convert", "-O", "raw", src, dest],
                timeoutSec = 3600)

proc setLength(path: string; length: int64) =
  var f: File
  if not open(f, path, fmReadWriteExisting): fail("cannot open " & path)
  defer: f.close()
  if posix.ftruncate(f.getFileHandle(), Off(length)) != 0:
    fail("cannot set the length of " & path & ": " & $strerror(errno))

proc copyRange(src: string; srcOff, length: int64; dst: string; dstOff: int64) =
  ## Copy `length` bytes of `src` at `srcOff` into `dst` at `dstOff`,
  ## creating `dst` when it does not exist. A chunk that is zero in the
  ## source and already zero in the destination is skipped, so sparse
  ## images stay sparse.
  var s, d: File
  if not open(s, src, fmRead): fail("cannot read " & src)
  defer: s.close()
  let mode = if fileExists(dst): fmReadWriteExisting else: fmReadWrite
  if not open(d, dst, mode): fail("cannot write " & dst)
  defer: d.close()
  const Chunk = 1 shl 20
  var buf = newString(Chunk)
  var cur = newString(Chunk)
  var done = 0'i64
  let dstLen = getFileSize(d)
  while done < length:
    let n = int(min(int64(Chunk), length - done))
    s.setFilePos(srcOff + done)
    let got = s.readBuffer(addr buf[0], n)
    if got != n: fail("short read of " & src)
    var zero = true
    for i in 0 ..< n:
      if buf[i] != '\0':
        zero = false
        break
    var skip = false
    if zero:
      if dstOff + done + n <= dstLen:
        d.setFilePos(dstOff + done)
        let had = d.readBuffer(addr cur[0], n)
        skip = had == n
        if skip:
          for i in 0 ..< n:
            if cur[i] != '\0':
              skip = false
              break
      else:
        skip = true   # past the destination's end: a hole reads as zeros
    if not skip:
      d.setFilePos(dstOff + done)
      if d.writeBuffer(addr buf[0], n) != n: fail("short write to " & dst)
    done += n
  if getFileSize(d) < dstOff + length:
    setLength(dst, dstOff + length)

proc fsck(args: openArray[string]): tuple[rc: int; output: string] =
  let r = runHostTool(@[tool("e2fsck")] & @args, path = getEnv("PATH"))
  (r.exitCode, r.output)

proc grow(o: InfraImageOptions; image: string; t: var ImageTable): string =
  ## Grow the image to ``diskSize``; returns the upstream filesystem's
  ## check record for the manifest ("" when nothing was grown).
  if o.baseOs.diskSize.len == 0: return
  let want = parseDiskSize(o.baseOs.diskSize)
  let have = getFileSize(image)
  if want < have:
    fail("baseOs.diskSize " & o.baseOs.diskSize & " is smaller than the " &
      "upstream image (" & $have & " bytes)")
  if want == have: return
  o.say("growing the image to " & o.baseOs.diskSize)
  var f: File
  if not open(f, image, fmReadWriteExisting): fail("cannot open " & image)
  try:
    # Extend the file (sparse): a truncate past the end.
    if posix.ftruncate(f.getFileHandle(), Off(want)) != 0:
      fail("cannot extend " & image & ": " & $strerror(errno))
  finally:
    f.close()
  # A GPT's backup header is still where the old end was; sfdisk's write of
  # the grown partition moves it to the new end (sfdisk(8): "the backup GPT
  # table is not on the end of the device ... corrected by write").
  let gi = endOfDiskIndex(t)
  let num = t.partitions[gi].number
  let oldLength = t.partitions[gi].sectors * int64(t.sectorSize)
  discard run([tool("sfdisk"), "--no-reread", "--no-tell-kernel", "-q",
               "-N", $num, image], input = ",+\n")
  t = readTable(image)
  # The filesystem is grown in a file of its own, the partition's new
  # length: resize2fs adjusts the size of a regular file it resizes, so run
  # on the image itself (through `?offset=`) it would cut the image at the
  # filesystem's end, and with it a GPT's backup header.
  let part = image & ".grow-part"
  let offset = partOffset(t, gi)
  let length = t.partitions[gi].sectors * int64(t.sectorSize)
  copyRange(image, offset, oldLength, part, 0)
  setLength(part, length)
  # resize2fs needs a freshly checked filesystem. This is the UPSTREAM
  # image's filesystem, not ours: e2fsck may tidy what the vendor left
  # (Raspberry Pi OS ships with orphan inodes to clean up), and exit 1
  # (fsck(8): "errors corrected"). That is accepted, and what it did is
  # recorded in the image's manifest; anything worse is refused.
  let (rc, outp) = fsck(["-fy", part])
  if rc notin [0, 1]:
    fail("e2fsck of the upstream root filesystem exited " & $rc & ":\n" & outp)
  result = "upstream root: e2fsck -fy exited " & $rc & "\n" & outp
  discard run([tool("resize2fs"), part])
  # resize2fs sets the file to the filesystem's own length, a whole number
  # of blocks, which can end before the partition does.
  let grown = getFileSize(part)
  if grown > length:
    fail("the grown filesystem (" & $grown & " bytes) is longer than its " &
      "partition (" & $length & ")")
  copyRange(part, 0, grown, image, offset)
  removeFile(part)
  let after = readTable(image)
  if after.partitions.len != t.partitions.len:
    fail("the partition table changed while the root filesystem grew")

proc debsOf(profileText: string): seq[AptLockedDeb] =
  ## Every `.deb` of every apt closure the canonical text declares.
  let p = parseSystemProfile(profileText)
  var seen: HashSet[string]
  for r in p.resources:
    var lockText = ""
    if r.kind == srkSystemdSystemUnit: lockText = r.suAptClosureLock
    if lockText.len == 0: continue
    for d in parseAptClosureLock(lockText).debs:
      if d.sha256 notin seen:
        seen.incl d.sha256
        result.add d

proc lockArchiveOf(profileText: string; d: AptLockedDeb): string =
  let p = parseSystemProfile(profileText)
  for r in p.resources:
    if r.kind == srkSystemdSystemUnit and r.suAptClosureLock.len > 0:
      let l = parseAptClosureLock(r.suAptClosureLock)
      for x in l.debs:
        if x.sha256 == d.sha256: return l.archive
  ""

proc stageDebs(o: InfraImageOptions; work: string): seq[tuple[sha, path: string]] =
  ## Every `.deb` the profile's closures need, checked against its lock on
  ## the build host: from `--deb-cache` first, else from the lock's archive.
  for d in debsOf(o.profileText):
    let local = work / "debs" / (d.sha256 & ".deb")
    createDir(work / "debs")
    var src = ""
    if o.debCache.len > 0 and fileExists(o.debCache / (d.sha256 & ".deb")):
      src = o.debCache / (d.sha256 & ".deb")
      copyFile(src, local)
    else:
      let url = lockArchiveOf(o.profileText, d) & "/" & d.filename
      o.say("fetching " & url)
      discard run([tool("curl"), "-sSfL", "--retry", "3", "-o", local, url],
                  timeoutSec = 1800)
    if getFileSize(local) != d.size or sha256File(local) != d.sha256:
      fail(d.name & " " & d.version & ": the .deb does not match its lock " &
        "(size " & $d.size & ", sha256 " & d.sha256 & ")")
    result.add (d.sha256, local)

proc bootstrapFlags(o: InfraImageOptions; work: string;
                    files: var seq[tuple[local, name: string]]): seq[string] =
  let bs = o.baseOs.bootstrap
  for (flag, rel, name) in [("--deploy-signers", bs.deploySigners,
                              "deploy-signers.anchors"),
                             ("--cache-publishers", bs.cachePublishers,
                              "cache-publishers.anchors")]:
    if rel.len > 0:
      let p = o.profileDir / rel
      if not fileExists(p):
        fail("baseOs.bootstrap names " & rel & ", which is not in " &
          o.profileDir)
      files.add (p, name)
      result.add @[flag, AssemblyPayloadDir / name]
  if bs.cacheUrl.len > 0: result.add @["--cache-url", bs.cacheUrl]
  # No image ever carries a recipient key: the device creates its own at its
  # first boot (spec §6.5.2, owner decision 2026-11-08).
  result.add "--defer-recipient-key"
  if bs.agentTarget.len > 0:
    result.add @["--target", bs.agentTarget]
    for s in bs.agentSources: result.add @["--manifest", s]
    if bs.pollIntervalSec > 0:
      result.add @["--poll-interval", $bs.pollIntervalSec]

proc assemblyUnit(): string =
  ## The oneshot unit of the assembly boot. `journal+console` puts every
  ## line on the serial log; success and failure both power the machine off.
  "[Unit]\n" &
  "Description=repro infra image: assembly boot (removes itself)\n" &
  "After=local-fs.target systemd-tmpfiles-setup.service\n" &
  "DefaultDependencies=yes\n" &
  # systemd.unit(5): [Unit] options, run when the unit finishes.
  "SuccessAction=poweroff\n" &
  "FailureAction=poweroff\n\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "ExecStart=" & AssemblyPayloadDir & "/repro system addon image-assemble " &
    "--payload " & AssemblyPayloadDir & "\n" &
  "StandardOutput=journal+console\n" &
  "StandardError=journal+console\n" &
  "TimeoutStartSec=infinity\n\n" &
  "[Install]\n" &
  "WantedBy=multi-user.target\n"

proc synthesiseImage*(o: InfraImageOptions): InfraImageResult =
  let problem = baseOsProblem(o.baseOs)
  if problem.len > 0: fail(problem)
  for t in RequiredTools: discard tool(t)
  discard tool(qemuSystemBinary(o.baseOs.buildBoot))
  if o.compress notin ["xz", "none"]:
    fail("--compress must be xz or none, got " & o.compress)
  if o.compress == "xz": discard tool("xz")
  # The add-on binary: pinned by digest, for the image's architecture.
  if not fileExists(o.addonBinary): fail("no add-on binary at " & o.addonBinary)
  let binSha = sha256File(o.addonBinary)
  if binSha != o.addonSha256:
    fail(o.addonBinary & " hashes to " & binSha & ", not --addon-sha256 " &
      o.addonSha256)
  let elfArch = elfMachineArch(readFile(o.addonBinary)[0 ..< 64])
  if elfArch != o.baseOs.arch:
    fail(o.addonBinary & " is an " & (if elfArch.len > 0: elfArch else: "unknown") &
      " binary; baseOs.arch is " & o.baseOs.arch)
  if fileExists(o.output) or dirExists(o.output):
    fail("--output " & o.output & " already exists")

  # Step 2.
  let upstream = fetchBaseImage(o.baseOs, o.log)
  o.say("verified " & upstream & " (sha256 " & o.baseOs.sha256 & ")")

  # Step 3.
  let work = if o.workDir.len > 0: o.workDir
             else: cacheRoot() / "infra-image" / "runs" /
                   (o.host & "-" & $getCurrentProcessId() & "-" &
                    $epochTime().int64)
  if dirExists(work) and o.workDir.len == 0: fail(work & " already exists")
  createDir(work)
  result.workDir = work
  let image = work / "image.raw"
  try:
    unpack(o, upstream, image)
    var t = readTable(image)
    let why = verifyLayout(o.baseOs, t, probeAll(image, t))
    if why.len > 0: fail("the image does not match baseOs.layout: " & why)
    var fsckNotes: seq[string]
    let grown = grow(o, image, t)
    if grown.len > 0: fsckNotes.add(grown)
    let rootIdx = partitionIndexAt(o.baseOs, "/")
    let root = ext4At(image, partOffset(t, rootIdx))
    if probeFilesystem(image, partOffset(t, rootIdx)).format != "ext4":
      fail("the root partition is not ext4; the image command writes ext4 only")
    let bootIdx = partitionIndexAt(o.baseOs, effectiveBootMountpoint(o.baseOs))

    # Step 4: stage. First what the boot consumes and the clean-up puts back.
    let machineId = if root.exists("/etc/machine-id"): root.catFile("/etc/machine-id")
                    else: ""
    var keepKeys: seq[string]
    if root.exists("/etc/ssh"):
      for n in root.listDir("/etc/ssh"):
        if n.startsWith("ssh_host_"): keepKeys.add n
    var payloadFiles: seq[tuple[local, name: string]]
    let flags = bootstrapFlags(o, work, payloadFiles)
    writeFile(work / "profile.txt", o.profileText)
    payloadFiles.add (work / "profile.txt", "profile.txt")
    let debs = stageDebs(o, work)
    var stagedNames, stagedShas: seq[string]
    for d in debs:
      stagedNames.add d.sha & ".deb"
      stagedShas.add d.sha
    var createdForCache: seq[string]
    for d in ["/var/cache/repro", AssemblyDebCacheDir]:
      if not root.exists(d): createdForCache.insert(d, 0)
    let spec = AssemblySpec(binarySha256: binSha, preflightFlags: flags,
      profileFile: "profile.txt", machineId: machineId,
      keepSshHostKeys: keepKeys, stagedDebs: stagedNames,
      removeDebCacheParents: createdForCache)
    writeFile(work / "assembly.json", renderAssemblySpec(spec))
    payloadFiles.add (work / "assembly.json", "assembly.json")
    writeFile(work / "hostname", (if o.baseOs.hostname.len > 0: o.baseOs.hostname
                                  else: o.host) & "\n")
    writeFile(work / "unit", assemblyUnit())
    writeFile(work / "empty", "")
    var cmds: seq[string]
    var created: seq[string]
    root.putFile(cmds, work / "hostname", "/etc/hostname", 0o644,
                 replace = root.exists("/etc/hostname"))
    let cloudInit = root.exists("/etc/cloud")
    if cloudInit and not root.exists(CloudInitDisabledMarker):
      root.putFile(cmds, work / "empty", CloudInitDisabledMarker, 0o644, false)
    root.mkdirChain(AssemblyPayloadDir, 0o700, cmds, created)
    root.putFile(cmds, o.addonBinary, AssemblyPayloadDir / "repro", 0o755, false)
    for (local, name) in payloadFiles:
      root.putFile(cmds, local, AssemblyPayloadDir / name, 0o600, false)
    if debs.len > 0:
      root.mkdirChain(AssemblyDebCacheDir, 0o755, cmds, created)
      for (sha, local) in debs:
        root.putFile(cmds, local, AssemblyDebCacheDir / (sha & ".deb"), 0o644,
                     false)
    root.putFile(cmds, work / "unit", AssemblyUnitPath, 0o644,
                 replace = root.exists(AssemblyUnitPath))
    root.mkdirChain(parentDir(AssemblyWantsLink), 0o755, cmds, created)
    cmds.add "symlink " & AssemblyWantsLink & " " & AssemblyUnitPath
    o.say("staging the assembly payload (" & $debs.len & " .deb file(s))")
    root.runScript(work, cmds)

    # Step 5: the assembly boot.
    var boot = AssemblyBoot(machine: o.baseOs.buildBoot, image: image,
      serialLog: work / "assembly-serial.log")
    case o.baseOs.buildBoot
    of "pc":
      boot.kvm = access("/dev/kvm".cstring, R_OK or W_OK) == 0
    of "raspi2b":
      if bootIdx < 0: fail("a raspi2b assembly boot needs the boot partition")
      let bootSpec = image & "@@" & $partOffset(t, bootIdx)
      for f in [RaspiKernel, RaspiDtb]:
        discard run([tool("mcopy"), "-o", "-n", "-i", bootSpec, "::/" & f,
                     work / f])
      boot.kernel = work / RaspiKernel
      boot.dtb = work / RaspiDtb
      boot.rootPartition = t.partitions[rootIdx].number
    var timeout = o.assemblyTimeoutSec
    if timeout <= 0:
      for (m, s) in AssemblyDefaultTimeoutSec:
        if m == o.baseOs.buildBoot: timeout = s
    let qemu = tool(qemuSystemBinary(o.baseOs.buildBoot))
    o.say("assembly boot: " & o.baseOs.buildBoot &
      (if boot.kvm: " (KVM)" elif o.baseOs.buildBoot == "pc": " (TCG)" else: " (TCG)") &
      ", serial log " & boot.serialLog)
    let started = epochTime()
    let qr = runHostTool(@[qemu] & assemblyBootArgv(boot), timeoutSec = timeout,
                         path = getEnv("PATH"))
    let serial = (if fileExists(boot.serialLog): readFile(boot.serialLog) else: "")
    if qr.exitCode != 0:
      fail("the assembly boot's QEMU exited " & $qr.exitCode &
        (if qr.exitCode == 124: " (timed out after " & $timeout & " s)" else: "") &
        ":\n" & qr.output & "\nserial log tail:\n" &
        (if serial.len > 6000: serial[^6000 .. ^1] else: serial))
    o.say("assembly boot finished in " & $int(epochTime() - started) & " s")
    # Replay the root filesystem's journal before reading or writing it:
    # debugfs does not, and the next boot's replay would undo what it
    # wrote. A clean power-off leaves nothing to replay; anything else
    # does. The check runs on a copy of the partition: e2fsck re-opens the
    # filesystem after a journal recovery WITHOUT the `?offset=` option,
    # and then reads the image's own first sector as the superblock
    # ("Bad magic number ... while trying to re-open"; measured with
    # e2fsprogs 1.47.3 on a raspi2b assembly that powered off with a dirty
    # journal).
    let rootOffset = partOffset(t, rootIdx)
    let rootLength = t.partitions[rootIdx].sectors * int64(t.sectorSize)
    let check = image & ".fsck-part"
    copyRange(image, rootOffset, rootLength, check, 0)
    #
    # Only the journal is replayed (`-E journal_only`); the filesystem is
    # then checked READ-ONLY and must be clean (exit 0). A filesystem the
    # assembly boot left damaged is refused, never repaired into an image.
    let (jrc, jout) = fsck(["-y", "-E", "journal_only", check])
    if jrc notin [0, 1]:
      fail("replaying the root filesystem's journal after the assembly " &
        "boot: e2fsck exited " & $jrc & ":\n" & jout)
    let (crc, cout) = fsck(["-fn", check])
    if crc != 0:
      fail("the root filesystem is not clean after the assembly boot " &
        "(e2fsck -fn exited " & $crc & "); refusing to write the image:\n" & cout)
    fsckNotes.add("assembly root: journal replay exited " & $jrc &
      "; e2fsck -fn exited 0")
    copyRange(check, 0, getFileSize(check), image, rootOffset)
    removeFile(check)
    let resultPath = AssemblyPayloadDir / AssemblyResultName
    if not root.exists(resultPath):
      fail("the assembly boot left no " & resultPath & "; serial log tail:\n" &
        (if serial.len > 6000: serial[^6000 .. ^1] else: serial))
    result.assembly = parseAssemblyResult(root.catFile(resultPath))
    if not result.assembly.ok:
      var why = ""
      for s in result.assembly.steps:
        if not s.ok: why = s.name & ": " & s.detail
      fail("the assembly failed at " & why)
    # No image carries a private key (spec §6.5.2): every device creates
    # its own at its first boot. Found by content and location, whatever
    # its name (`key_material`); an image that holds one is refused.
    let scan = work / "keyscan"
    removeDir(scan)
    for r in KeyScanRoots:
      if root.exists(r): root.copyOut(r, scan / r.parentDir)
    let keys = scanForPrivateKeys(scan)
    removeDir(scan)
    if keys.len > 0:
      fail("the assembled image holds private-key material; every device " &
        "must create its own. Nothing was written:\n  " & keys.join("\n  "))
    # Nor the assembly boot's random seed: systemd-random-seed writes it at
    # power-off unless the clean-up stopped the unit first, and every
    # device would then credit the same seed.
    if root.exists(RandomSeedPath):
      fail("the assembled image holds " & RandomSeedPath & " (the assembly " &
        "boot's random seed, written at its power-off); nothing was written")

    # Step 6: finish.
    var fin: seq[string]
    if cloudInit:
      fin.add "rm " & CloudInitDisabledMarker
    fin.add "rm " & resultPath
    fin.add "rmdir " & AssemblyPayloadDir
    # The assembly boot's persistent journal, named by its machine id: its
    # log is not the device's, and it names the assembly's identity.
    let assemblyJournal = "/var/log/journal/" &
      result.assembly.assemblyMachineId
    if result.assembly.assemblyMachineId.len == 32 and
        root.exists(assemblyJournal):
      root.removeTree(assemblyJournal, fin)
    let ci = o.baseOs.cloudInit
    var seedFiles: seq[tuple[name, content: string]]
    if ci.declared:
      for (n, c) in [("user-data", ci.userData), ("meta-data", ci.metaData),
                     ("network-config", ci.networkConfig)]:
        if c.len > 0: seedFiles.add (n, c)
    if ci.declared and ci.seed == "rootSeedDir" and seedFiles.len > 0:
      var made: seq[string]
      root.mkdirChain(NoCloudSeedDir, 0o755, fin, made)
      for (n, c) in seedFiles:
        writeFile(work / ("seed-" & n), c)
        root.putFile(fin, work / ("seed-" & n), NoCloudSeedDir / n, 0o600,
                     replace = root.exists(NoCloudSeedDir / n))
    root.runScript(work, fin)
    var bootFiles: seq[tuple[name, content: string]]
    for f in o.baseOs.bootFiles: bootFiles.add (f.name, f.content)
    if ci.declared and ci.seed == "bootPartition":
      bootFiles.add seedFiles
    if bootFiles.len > 0:
      if bootIdx < 0: fail("no boot partition for the boot files")
      let bootProbe = probeFilesystem(image, partOffset(t, bootIdx))
      if bootProbe.format == "vfat":
        let bootSpec = image & "@@" & $partOffset(t, bootIdx)
        for (n, c) in bootFiles:
          writeFile(work / ("boot-" & n), c)
          discard run([tool("mcopy"), "-o", "-n", "-i", bootSpec,
                       work / ("boot-" & n), "::/" & n])
      elif bootProbe.format == "ext4":
        let bfs = ext4At(image, partOffset(t, bootIdx))
        var bc: seq[string]
        for (n, c) in bootFiles:
          writeFile(work / ("boot-" & n), c)
          bfs.putFile(bc, work / ("boot-" & n), "/" & n, 0o644,
                      replace = bfs.exists("/" & n))
        bfs.runScript(work, bc)
      else:
        fail("the boot partition is neither FAT nor ext4")
    # The output: raw or xz, then its digest and manifest.
    let tmpOut = o.output & ".part-" & $getCurrentProcessId()
    if o.compress == "xz":
      pipeToFile([tool("xz"), "-T0", "-c", image], tmpOut)
    else:
      moveFile(image, tmpOut)
    moveFile(tmpOut, o.output)
    result.output = o.output
    result.outputSha256 = sha256File(o.output)
    writeFile(o.output & ".sha256", result.outputSha256 & "  " &
      o.output.extractFilename & "\n")
    var layoutParts = newJArray()
    for p in t.partitions:
      layoutParts.add %*{"number": p.number, "start": p.start,
                         "sectors": p.sectors, "type": p.typeCode}
    let manifest = %*{
      "schema": "reprobuild.infra-image.manifest.v1",
      "host": o.host, "profile": o.profilePath.extractFilename,
      "upstream": {"url": o.baseOs.image, "sha256": o.baseOs.sha256},
      "arch": o.baseOs.arch, "buildBoot": o.baseOs.buildBoot,
      "diskSize": o.baseOs.diskSize, "table": $t.kind,
      "partitions": layoutParts,
      "profileTextSha256": sha256Hex(o.profileText),
      # The canonical text the assembly applied: what a later `repro infra
      # plan --profile` on the booted host plans against.
      "profileText": o.profileText,
      "addonBinarySha256": binSha,
      "debs": stagedShas,
      "assembly": parseJson(renderAssemblyResult(result.assembly)),
      "reprobuildRevision": ReprobuildSourceRevision,
      "fsck": fsckNotes,
      "output": {"file": o.output.extractFilename, "compress": o.compress,
                 "sha256": result.outputSha256}}
    result.manifestPath = o.output & ".manifest.json"
    writeFile(result.manifestPath, manifest.pretty() & "\n")
  finally:
    if not o.keepWork:
      try: removeDir(work)
      except OSError: discard
