## macOS application archives: DMG disk images, flat installer packages,
## and zip / tar archives that carry a ``.app`` bundle (GM4c of the
## Gradual-Nix-To-Reprobuild-Migration plan; Store-And-Installation-Layout.md
## §"macOS Application Bundles").
##
## ``extractAppBundle`` copies ONE bundle out of a downloaded, digest-verified
## archive into a staging directory. It never runs anything the archive
## ships: a disk image is attached read-only and copied from, an installer
## package is expanded (``pkgutil --expand-full``) and its payload copied
## from — its pre/post-install scripts are not run.
##
## Disk images. ``hdiutil attach -nobrowse -readonly -noautoopen`` mounts the
## image under a private mount root (``-mountrandom``), so Finder does not
## show it and nothing else is likely to hold it open. Every attach is paired
## with a detach in a ``finally``; a detach that fails is retried and then
## forced, and an attach whose output could not be read is found again in
## ``hdiutil info`` by its image path, so no failure path leaves a volume
## mounted. A disk image that presents a software licence agreement is
## attached with stdin closed: hdiutil then declines the agreement and the
## attach fails with a diagnostic naming it, rather than waiting for input.
## HFS+ and APFS volumes are handled alike (an APFS image attaches as a
## partition disk plus a synthesized container disk; detaching the image's
## whole-disk device detaches both).
##
## Copying uses ``ditto``, which keeps the symlinks, extended attributes and
## resource forks a code signature depends on. ``unzip`` does not (it drops
## the AppleDouble metadata and can flatten framework symlinks), which is why
## a zip carrying a bundle is expanded with ``ditto -x -k``.
##
## References: hdiutil(1), ditto(1), pkgutil(1).

import std/[json, os, strutils]

import repro_home_resources/drivers/app_bundle

const
  HdiutilExe* = "/usr/bin/hdiutil"
  PkgutilExe* = "/usr/sbin/pkgutil"
  DittoArchiveExe* = "/usr/bin/ditto"
  TarExe* = "/usr/bin/tar"
  PlutilJsonExe* = "/usr/bin/plutil"

type
  AppArchiveKind* = enum
    aakDmg = "dmg"
    aakPkg = "pkg"
    aakZip = "zip"
    aakTar = "tar"     ## tar.gz / tar.xz / tar.bz2 — bsdtar detects the codec

  EAppArchive* = object of CatchableError
    ## The archive could not be opened, or does not hold the declared bundle.
    archivePath*: string

  EDmgDetachFailed* = object of EAppArchive
    ## Detaching failed even with ``-force``. The device is named so an
    ## operator can detach it by hand.
    device*: string

  EInstallerApp* = object of CatchableError
    ## A macOS installer application could not be run, or did not produce
    ## what its record declares (``macos_installer``;
    ## Store-And-Installation-Layout.md § Installer applications). Nothing
    ## is published. Declared here, beside ``EAppArchive``, so callers on
    ## every platform can name it.
    check*: string
      ## "sandbox" (no ``sandbox-exec``), "executable" (no main
      ## executable), "timeout", "exit-status", "product" (``appBundle``
      ## missing from the prefix, or reached through a symlink),
      ## "prefix-contents" (something besides the placed item in the prefix
      ## root).
    output*: string
      ## What the installer wrote to stdout and stderr (its last 64 KiB).

  AttachedImage* = object
    imagePath*: string
    device*: string            ## the image's whole-disk device (/dev/diskN)
    mountPoints*: seq[string]

proc runProc(exe: string; args: openArray[string]; stdinText = ""):
    tuple[exitCode: int; output, errors: string] =
  ## Every process this module starts goes through the driver's one
  ## system-tool launcher (absolute paths, argument vector, no shell).
  runSystemTool(exe, args, stdinText)

proc archiveError(archivePath, msg: string) {.noreturn.} =
  var e = newException(EAppArchive, msg)
  e.archivePath = archivePath
  raise e

proc plistToJson(plistText: string): JsonNode =
  ## Convert an XML plist to JSON with ``plutil``; raises on failure.
  let res = runProc(PlutilJsonExe, ["-convert", "json", "-o", "-", "-"],
    stdinText = plistText)
  if res.exitCode != 0:
    raise newException(ValueError, "plutil could not convert the plist: " &
      res.errors.strip())
  parseJson(res.output)

proc isWholeDisk(dev: string): bool =
  ## ``/dev/disk7`` but not ``/dev/disk7s1``.
  let leaf = dev.extractFilename
  leaf.startsWith("disk") and 's' notin leaf["disk".len .. ^1]

proc imageFromEntities(imagePath: string; entities: JsonNode): AttachedImage =
  result.imagePath = imagePath
  for entity in entities:
    let dev = entity{"dev-entry"}.getStr("")
    if dev.len > 0 and result.device.len == 0 and isWholeDisk(dev):
      result.device = dev
    let mp = entity{"mount-point"}.getStr("")
    if mp.len > 0:
      result.mountPoints.add(mp)
  if result.device.len == 0:
    # No whole-disk entry (not observed in practice): fall back to the
    # shortest device name, which is the parent of every slice.
    for entity in entities:
      let dev = entity{"dev-entry"}.getStr("")
      if dev.len > 0 and (result.device.len == 0 or
          dev.len < result.device.len):
        result.device = dev

proc canonicalPath(path: string): string =
  ## hdiutil reports image paths resolved (``/private/tmp`` for ``/tmp``).
  try: expandFilename(path) except OSError: absolutePath(path)

proc attachedImagesOf*(imagePath: string): seq[AttachedImage] =
  ## Every attachment of ``imagePath`` that ``hdiutil info`` reports. Used to
  ## find an attachment whose ``attach`` output was lost, and by tests to
  ## assert nothing is left mounted.
  let res = runProc(HdiutilExe, ["info", "-plist"])
  if res.exitCode != 0:
    return
  let info =
    try: plistToJson(res.output)
    except CatchableError: return
  let wanted = canonicalPath(imagePath)
  for image in info{"images"}.getElems():
    let path = image{"image-path"}.getStr("")
    if path.len > 0 and canonicalPath(path) == wanted:
      result.add(imageFromEntities(path, image{"system-entities"}))

proc detachDevice*(device, imagePath: string): bool {.discardable.} =
  ## Detach ``device``: three ordinary attempts (a volume can be briefly busy
  ## right after a copy — Spotlight, fseventsd), then ``-force``. Returns
  ## true when only ``-force`` succeeded.
  var last = ""
  for attempt in 0 ..< 3:
    let res = runProc(HdiutilExe, ["detach", device, "-quiet"])
    if res.exitCode == 0:
      return false
    last = (res.output & res.errors).strip()
    sleep(500 * (attempt + 1))
  let forced = runProc(HdiutilExe, ["detach", device, "-force", "-quiet"])
  if forced.exitCode == 0:
    return true
  var e = newException(EDmgDetachFailed, "could not detach " & device &
    " (disk image " & imagePath & "): " & last & "; -force: " &
    (forced.output & forced.errors).strip() &
    ". Detach it by hand: hdiutil detach -force " & device)
  e.archivePath = imagePath
  e.device = device
  raise e

proc hasLicenceAgreement*(imagePath: string): bool =
  ## Whether the image carries a software licence agreement (the ``LPic``
  ## resources ``hdiutil attach`` presents before mounting). Read from
  ## ``hdiutil imageinfo``; false when that cannot be read.
  let res = runProc(HdiutilExe, ["imageinfo", "-plist", imagePath])
  if res.exitCode != 0:
    return false
  try:
    plistToJson(res.output){"Properties"}{"Software License Agreement"}.
      getBool(false)
  except CatchableError:
    false

proc attachDmg*(imagePath, mountRoot: string): AttachedImage =
  ## Attach read-only, unbrowsed, under ``mountRoot``. If hdiutil succeeded
  ## but its output cannot be read, the attachment is looked up and detached
  ## before the error propagates.
  createDir(mountRoot)
  let res = runProc(HdiutilExe, ["attach", "-nobrowse", "-readonly",
    "-noautoopen", "-noverify", "-plist", "-mountrandom", mountRoot,
    imagePath])
  if res.exitCode != 0:
    let detail = (res.errors & res.output).strip()
    # A leftover attachment is possible if hdiutil failed after attaching.
    for leftover in attachedImagesOf(imagePath):
      try: detachDevice(leftover.device, imagePath) except EAppArchive: discard
    archiveError(imagePath, "hdiutil attach failed (exit " & $res.exitCode &
      ")" & (if hasLicenceAgreement(imagePath):
               "; the disk image presents a software licence agreement. " &
                 "Reprobuild attaches non-interactively and does not " &
                 "accept a licence on the user's behalf"
             else: "") & ": " & detail)
  try:
    let parsed = plistToJson(res.output)
    result = imageFromEntities(imagePath, parsed{"system-entities"})
    if result.device.len == 0:
      raise newException(ValueError, "hdiutil reported no device")
    if result.mountPoints.len == 0:
      raise newException(ValueError, "the image has no mountable volume")
  except CatchableError as err:
    var detached = false
    if result.device.len > 0:
      try:
        detachDevice(result.device, imagePath)
        detached = true
      except EAppArchive: discard
    if not detached:
      for leftover in attachedImagesOf(imagePath):
        try: detachDevice(leftover.device, imagePath) except EAppArchive: discard
    archiveError(imagePath, "could not read the attached disk image " &
      imagePath & ": " & err.msg)

# ---------------------------------------------------------------------------
# Bundle lookup inside an unpacked tree
# ---------------------------------------------------------------------------

proc copyTree(archivePath, source, dest: string) =
  let res = runProc(DittoArchiveExe, ["--noqtn", source, dest])
  if res.exitCode != 0:
    archiveError(archivePath, "ditto " & source & " -> " & dest &
      " failed: " & (res.errors & res.output).strip())

proc expandPkg(archivePath, pkgPath, dest: string) =
  ## ``pkgutil --expand-full`` unpacks a flat package's components and their
  ## payloads. It runs none of the package's scripts.
  let res = runProc(PkgutilExe, ["--expand-full", pkgPath, dest])
  if res.exitCode != 0:
    archiveError(archivePath, "pkgutil --expand-full " & pkgPath &
      " failed: " & (res.errors & res.output).strip())

proc validateBundlePath*(bundlePath: string): seq[string] =
  ## Split a declared bundle path into its components, refusing anything that
  ## could leave the unpacked tree.
  let normalized = bundlePath.replace('\\', '/')
  if normalized.len == 0 or normalized.startsWith("/"):
    raise newException(ValueError, "app bundle path " & bundlePath.escape &
      " must be relative to the archive root")
  for part in normalized.split('/'):
    if part.len == 0 or part == "." or part == "..":
      raise newException(ValueError, "app bundle path " & bundlePath.escape &
        " has an empty, '.' or '..' component")
    result.add(part)
  if not result[^1].endsWith(".app"):
    raise newException(ValueError, "app bundle path " & bundlePath.escape &
      " must name a .app bundle")

proc resolveBundle*(archivePath, root, bundlePath, scratch: string): string =
  ## Walk ``bundlePath`` from ``root``. A component that names a flat
  ## installer package (a FILE ending in ``.pkg``) is expanded into
  ## ``scratch`` and the walk continues inside it, so
  ## ``Foo.pkg/Foo.pkg/Payload/Applications/Foo.app`` reaches a bundle in a
  ## package on a disk image. A symlink component is refused: disk images
  ## routinely carry ``Applications -> /Applications``, and following one
  ## would read outside the archive.
  let parts =
    try: validateBundlePath(bundlePath)
    except ValueError as err: archiveError(archivePath, err.msg)
  var current = root
  var expansions = 0
  for i, part in parts:
    let next = current / part
    if symlinkExists(next):
      archiveError(archivePath, "app bundle path " & bundlePath.escape &
        " crosses a symlink at " & next & "; declare the path inside the " &
        "archive")
    if fileExists(next) and part.endsWith(".pkg") and i < parts.high:
      inc expansions
      let expanded = scratch / ("pkg-" & $expansions)
      expandPkg(archivePath, next, expanded)
      current = expanded
    elif dirExists(next):
      current = next
    else:
      var listing: seq[string] = @[]
      if dirExists(current):
        for kind, entry in walkDir(current, relative = true):
          listing.add(entry)
      archiveError(archivePath, "the archive has no " & part.escape &
        " at " & current & " (looking for " & bundlePath.escape &
        "; present: " & listing.join(", ") & ")")
  if not fileExists(current / "Contents" / "Info.plist"):
    archiveError(archivePath, bundlePath.escape & " is not an app bundle " &
      "(no Contents/Info.plist)")
  current

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc extractAppBundle*(archivePath: string; kind: AppArchiveKind;
                       bundlePath, destDir, scratch: string): string =
  ## Copy the bundle at ``bundlePath`` inside ``archivePath`` to
  ## ``destDir / <leaf of bundlePath>`` and return that path. ``scratch`` is
  ## a directory this call may fill and the caller removes.
  createDir(scratch)
  createDir(destDir)
  let leaf = bundlePath.replace('\\', '/').split('/')[^1]
  let dest = destDir / leaf
  case kind
  of aakDmg:
    let image = attachDmg(archivePath, scratch / "mnt")
    var bodyError: ref CatchableError = nil
    try:
      var found = ""
      for mp in image.mountPoints:
        let candidate = mp / bundlePath.replace('\\', '/').split('/')[0]
        if symlinkExists(candidate) or fileExists(candidate) or
            dirExists(candidate):
          found = mp
          break
      if found.len == 0:
        found = image.mountPoints[0]
      let source = resolveBundle(archivePath, found, bundlePath, scratch)
      copyTree(archivePath, source, dest)
    except CatchableError as err:
      bodyError = err
    finally:
      # Detach whether or not the copy succeeded. A detach failure is
      # reported, but never masks the copy's own error.
      try:
        detachDevice(image.device, archivePath)
      except EDmgDetachFailed as err:
        if bodyError.isNil:
          raise err
    if not bodyError.isNil:
      raise bodyError
  of aakPkg:
    let expanded = scratch / "pkg-root"
    expandPkg(archivePath, archivePath, expanded)
    let source = resolveBundle(archivePath, expanded, bundlePath, scratch)
    copyTree(archivePath, source, dest)
  of aakZip:
    let unpacked = scratch / "zip"
    createDir(unpacked)
    let res = runProc(DittoArchiveExe, ["-x", "-k", "--noqtn", archivePath,
      unpacked])
    if res.exitCode != 0:
      archiveError(archivePath, "ditto -x -k failed: " &
        (res.errors & res.output).strip())
    let source = resolveBundle(archivePath, unpacked, bundlePath, scratch)
    moveDir(source, dest)
  of aakTar:
    let unpacked = scratch / "tar"
    createDir(unpacked)
    let res = runProc(TarExe, ["-x", "-f", archivePath, "-C", unpacked])
    if res.exitCode != 0:
      archiveError(archivePath, "tar -x failed: " &
        (res.errors & res.output).strip())
    let source = resolveBundle(archivePath, unpacked, bundlePath, scratch)
    moveDir(source, dest)
  dest
