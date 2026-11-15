## MD5 in lower-case hex, for comparing a file with the digest pacman's
## local database records for a backup file (``%BACKUP%``; spec
## ReproOS-Add-On-Mode §4.3.1). MD5 is pacman's choice of digest, used
## here only to ask pacman's own question -- "is this the packaged
## version?" -- never to identify content: the add-on's own records name
## bytes by SHA-256.

{.push warning[Deprecated]: off.}
import std/md5
{.pop.}

proc md5Hex*(data: string): string =
  ## ``data``'s MD5, 32 lower-case hex digits.
  $toMD5(data)

when isMainModule:
  doAssert md5Hex("") == "d41d8cd98f00b204e9800998ecf8427e"
  doAssert md5Hex("abc") == "900150983cd24fb0d6963f7d28e17f72"
