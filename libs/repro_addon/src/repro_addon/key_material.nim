## Private-key material in the add-on's key-bearing directories of an
## image (ReproOS Add-On Mode §6.5.2, D1 as narrowed by Zahary Karadjov on
## 2026-11-13).
##
## Scope: the directories in ``KeyScanRoots`` only, the formats below
## only, and files up to 1 MiB for the content check. It is NOT a scan of
## the whole image: a key a service writes elsewhere, a GnuPG or raw
## binary key, or a private file in a subdirectory of a key directory is
## not found (reprobuild-pm issues/2026-11-13-image-private-key-detection-
## covers-only-the-scanned-directories.md). Within that scope the check is
## by content and by location, not by file name.
##
## - *Content.* A file holds a private key when it carries the marker of a
##   private-key encoding Reprobuild or the base system writes: Reprobuild's
##   own ``ecdsa-p256:<hex>`` key files (``repro_peer_cache/auth``), PEM and
##   OpenSSH private keys (``-----BEGIN ... PRIVATE KEY-----``, RFC 7468 §10
##   https://www.rfc-editor.org/rfc/rfc7468#section-10, and
##   https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key),
##   age identities (``AGE-SECRET-KEY-``,
##   https://age-encryption.org/v1) and PuTTY key files.
## - *Location.* A key directory -- the add-on agent's, ``/etc/ssh``,
##   ``/etc/wireguard`` -- holds only public material that everyone may
##   read; a regular file directly in one of them that others cannot read
##   is private, whatever it holds (a WireGuard key is 44 bytes of base64 with no marker at all).
##
## ``scanForPrivateKeys`` walks a local copy of the image's files (the
## image command and the gate copy them out with ``debugfs rdump``); it
## never follows a symbolic link.

import std/[algorithm, os, strutils]

const
  KeyScanRoots* = ["/var/lib/repro", "/etc/repro", "/etc/ssh",
                   "/etc/wireguard", "/root", "/home",
                   "/var/lib/addon-image-assembly"]
    ## Where an image's private keys could be: the add-on's state and
    ## anchors, the SSH and WireGuard key directories, the home
    ## directories, and the assembly's payload.
  KeyDirectories* = ["/var/lib/repro/agent", "/etc/ssh", "/etc/wireguard"]
    ## Directories whose every private (not world-readable) file is key
    ## material by location.
  MaxScannedBytes = 1 shl 20
    ## Larger files are not read: no key encoding comes near this size.

proc privateKeyMarker*(content: string): string =
  ## The kind of private key ``content`` holds, or "" when it holds none.
  let head = content.strip(trailing = false)
  if head.startsWith("ecdsa-p256:"): return "Reprobuild ecdsa-p256 private key"
  if "-----BEGIN OPENSSH PRIVATE KEY-----" in content:
    return "OpenSSH private key"
  if "-----BEGIN " in content and " PRIVATE KEY-----" in content:
    return "PEM private key"
  if "-----BEGIN PRIVATE KEY-----" in content: return "PKCS#8 private key"
  if "AGE-SECRET-KEY-" in content: return "age identity"
  if content.startsWith("PuTTY-User-Key-File-"): return "PuTTY private key"
  ""

proc isUnderKeyDirectory(imagePath: string): bool =
  for d in KeyDirectories:
    if imagePath.parentDir == d: return true

proc scanForPrivateKeys*(localRoot: string; imageRoots = @KeyScanRoots):
    seq[string] =
  ## ``<image path>: <why>`` for every file under ``imageRoots`` (image
  ## paths, copied to ``localRoot / <image path>``) that is private-key
  ## material by content or by location. Sorted.
  for r in imageRoots:
    let base = localRoot / r
    if not dirExists(base) and not fileExists(base): continue
    var paths: seq[string]
    if fileExists(base): paths.add base
    else:
      for p in walkDirRec(base, yieldFilter = {pcFile},
                          followFilter = {pcDir}):
        paths.add p
    for p in paths:
      let imagePath = "/" & p.relativePath(localRoot)
      var why: seq[string]
      let info = getFileInfo(p, false)
      if info.kind != pcFile: continue
      if info.size <= MaxScannedBytes:
        let kind = privateKeyMarker(readFile(p))
        if kind.len > 0: why.add kind
      if isUnderKeyDirectory(imagePath) and
          fpOthersRead notin info.permissions:
        why.add "a file others cannot read in a key directory"
      if why.len > 0:
        result.add imagePath & ": " & why.join("; ")
  result.sort()
