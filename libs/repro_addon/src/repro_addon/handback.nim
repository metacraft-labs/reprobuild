## A ledger path a package came to own: never absorbed, never deleted.
##
## A package installed or upgraded after a generation can ship a file at a
## path the add-on owns (spec §7.6, §7.8). dpkg then lists the path for the
## package -- with the package's bytes on disk, or, for a conffile it met
## on a fresh install and was told to keep (``--force-confdef`` /
## ``--force-confold``), with the add-on's. Either way the path is no
## longer the add-on's alone, and three rules follow (spec §4.3, §7.8):
##
## - every plan and apply refuses the resource with ``EAddOnPackageOwned``
##   (``collision.decideFile``) until the operator resolves it -- the
##   plan-time observation in the ledger is never silently rewritten to
##   the package's name;
## - a removal of the resource, and uninstall, *hand the path back* to the
##   package instead of deleting it: the ledger entry goes, and the file
##   stays; when the add-on's object was its link into the static tree it
##   becomes a regular file with the same bytes first, so nothing dpkg now
##   tracks points into a store generation retention may release;
## - after the hand-back the operator may declare the resource again with
##   ``collision = "divert"``: the path is then an ordinary package-owned
##   path, and the diversion row of §4.3 applies.

import std/[os, strutils]

import ./collision
import ./etc_write
import ./ledger

const HandBackClasses* = {lcEtcFile, lcUnit, lcDropIn}

proc newPackageOwner*(e: LedgerEntry; driver: CollisionDriver): string =
  ## The package that owns ``e``'s path now although the entry's plan-time
  ## observation did not name it; "" when there is none (or ``e`` is not a
  ## file the add-on wrote).
  if e.class notin HandBackClasses or driver == nil: return ""
  let o = driver.packageOwner(e.path)
  if o.package.len == 0: return ""
  if packageOfObservation(e.observation) == o.package: return ""
  o.package

proc isOwnLinkStill*(e: LedgerEntry): bool =
  ## The path still holds the add-on's own link into the static tree (a
  ## package that unpacked its own file there replaced the link).
  e.isLink and symlinkExists(e.path) and expandSymlink(e.path) == e.linkTarget

proc handBackBytes*(e: LedgerEntry): string =
  ## The bytes at ``e``'s path now, read through the add-on's own link.
  readFile(e.path)

proc materialiseHandBack*(e: LedgerEntry; bytes: string) =
  ## Turn the add-on's link at ``e.path`` into a regular file holding
  ## ``bytes`` (the ledger's mode and owner, else ``0644 root``). A regular
  ## file is left as it is: it is the package's bytes, or the add-on's kept
  ## by dpkg, and in both cases dpkg's now.
  ## The file is written beside the link, fsynced and renamed over it: the
  ## path never goes missing, and a crash leaves the link or the file.
  if not isOwnLinkStill(e): return
  let mode = if e.mode.len > 0: e.mode else: "0644"
  let (uid, gid) = parseOwner(if e.owner.len > 0: e.owner else: "0:0")
  writeFileNoFollow(e.path, bytes, parseOctInt(mode), uid, gid,
                    replacingLinkTo = e.linkTarget)
