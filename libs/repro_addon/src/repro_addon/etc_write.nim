## Writing a file as root without ever following a symbolic link.
##
## The implementation lives in ``repro_elevation/nofollow_write`` since
## A4, so that the system-scope drivers (the writers of unit files,
## drop-ins and fragments) use the same ``openat(O_NOFOLLOW)`` walk the
## add-on's own files always had (threat model T34, G29). This module
## keeps the add-on's spelling of it and the owner-string helper the
## ledger uses.

import std/strutils

import repro_elevation/nofollow_write

export nofollow_write

type
  EtcWriteError* = NoFollowError

proc parseOwner*(owner: string): tuple[uid, gid: int] =
  ## ``uid:gid`` as the ledger and the fingerprint spell it.
  let parts = owner.split(':')
  if parts.len != 2:
    raise newException(EtcWriteError, "malformed owner: " & owner)
  (parseInt(parts[0]), parseInt(parts[1]))
