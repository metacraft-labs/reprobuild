## Undoing a ``collision = "takeOver"``: which bytes go back when the
## add-on stops owning a pacman backup file (spec ReproOS-Add-On-Mode
## §4.3.1, §6.4; §13 decision 89).
##
## A ``takeOver`` writes the add-on's copy over a backup file and keeps the
## packaged bytes it replaced in the ledger (content-addressed under the
## state directory, like every other preserved object). pacman then keeps
## that copy by its own design
## (https://wiki.archlinux.org/title/Pacman/Pacnew_and_Pacsave): on an
## upgrade whose packaged version of the file changed it leaves the copy
## alone and installs the new version as ``<path>.pacnew``, and in every
## case the local database's ``%BACKUP%`` entry then holds the MD5 of the
## installed package's version; on the package's removal it moves the copy
## to ``<path>.pacsave``.
##
## So the bytes the ledger recorded are the right ones to put back only
## while their MD5 is still the one ``%BACKUP%`` holds. Removal and
## uninstall restore, in this order:
##
## 1. the recorded bytes, if their MD5 equals the current ``%BACKUP%``
##    entry;
## 2. else ``<path>.pacnew``, if its MD5 equals it: installed at the path
##    with the mode and owner the path had before the take-over, and the
##    ``.pacnew`` deleted;
## 3. else nothing: the removal is refused with ``EAddOnPackageOwned``
##    naming the package, the path and the three digests. Restoring either
##    would leave a file pacman treats as a local edit from then on.
##
## When the package itself was removed pacman has already moved the copy to
## ``<path>.pacsave``: the ``.pacsave`` is deleted only when its SHA-256
## equals the ledger's (it is the add-on's copy), the path is never
## re-created, and a ``.pacsave`` holding other bytes is left. Each outcome
## is reported.
##
## The recorded bytes are verified against their content address before
## they are used (threat model: the preserved bytes swapped before a
## restore); a ``.pacnew`` or ``.pacsave`` that is a symbolic link is never
## read or deleted through.
##
## Falsifying mutation (``mutations.nim``):
## ``takeover-restores-recorded-bytes`` always restores the recorded
## bytes, so after an upgrade that changed the packaged file the path's
## MD5 differs from ``%BACKUP%`` (``pacman -Qkk`` reports it modified).

import std/[os, strutils]

import repro_infra/addon_diagnostics

import ./collision
import ./etc_write
import ./fingerprint
import ./ledger
import ./md5_hex
import ./mutations

const
  TakeOverCollision* = "takeOver"
    ## The ledger's ``collision`` for an entry a ``takeOver`` produced.
  PacnewSuffix* = ".pacnew"
  PacsaveSuffix* = ".pacsave"

type
  TakeOverUndoKind* = enum
    tuRecorded = "recorded"
      ## The recorded bytes' MD5 is the current ``%BACKUP%`` entry's.
    tuPacnew = "pacnew"
      ## ``<path>.pacnew``'s MD5 is; it is installed and deleted.
    tuRefused = "refused"
      ## Neither is: nothing is restored, the removal is refused.
    tuPacsaveDelete = "pacsave-delete"
      ## The package was removed and ``<path>.pacsave`` holds the ledger's
      ## bytes: it is deleted, the path not re-created.
    tuPacsaveLeave = "pacsave-leave"
      ## The package was removed and ``<path>.pacsave`` holds other bytes
      ## (or there is none): it is left, the path not re-created.
    tuOrphanCopy = "orphan-copy"
      ## No package lists the path any more, yet something is still at it
      ## (a removal that kept no ``.pacsave``, ``pacman -Rn``'s opposite,
      ## or a package that dropped the file): there are no packaged bytes
      ## to restore, so the add-on's copy is removed like any object it
      ## created, after the usual drift check.

  TakeOverUndo* = object
    ## What a removal or uninstall will do with one taken-over path,
    ## decided from the package database and the files beside the path.
    kind*: TakeOverUndoKind
    package*: string       ## the package that lists the path now, or ""
    backupMd5*: string     ## its current ``%BACKUP%`` MD5, or ""
    recordedMd5*: string   ## MD5 of the bytes the ledger preserved
    pacnewMd5*: string     ## MD5 of ``<path>.pacnew``, "" when absent
    pacnewBytes*: string   ## its bytes, read once (``tuPacnew``)
    pacsaveSha256*: string ## SHA-256 of ``<path>.pacsave``, "" when absent

  AddonTakeOverError* = object of CatchableError
    ## The preserved bytes of a taken-over file are missing or altered:
    ## nothing is restored from them.

proc isTakeOver*(e: LedgerEntry): bool =
  ## ``e`` is a backup file the add-on took over.
  e.class == lcEtcFile and e.collision == TakeOverCollision

proc recordedBytes*(e: LedgerEntry): string =
  ## The packaged bytes the ledger preserved for ``e``, verified against
  ## the SHA-256 their file is named by. Raises ``AddonTakeOverError`` when
  ## they are missing or do not match: restoring altered bytes would hand
  ## the package something it never shipped.
  if e.preserved.len == 0:
    raise newException(AddonTakeOverError, e.path & " was taken over but " &
      "the ledger preserved no packaged bytes for it")
  if symlinkExists(e.preserved) or not fileExists(e.preserved):
    raise newException(AddonTakeOverError, "the packaged bytes preserved " &
      "for " & e.path & " are missing at " & e.preserved)
  result = readFile(e.preserved)
  if sha256Hex(result) != extractFilename(e.preserved):
    raise newException(AddonTakeOverError, "the packaged bytes preserved " &
      "for " & e.path & " at " & e.preserved & " no longer match their " &
      "digest; nothing is restored from them")

proc regularFileBeside(path: string): bool =
  ## A regular file is at ``path`` and it is not a link: a ``.pacnew`` or
  ## ``.pacsave`` is read or deleted only then.
  fileExists(path) and not symlinkExists(path)

proc decideTakeOverUndo*(e: LedgerEntry; driver: CollisionDriver): TakeOverUndo =
  ## Read-only: what undoing ``e`` will do now (the order of the module
  ## header). Raises ``AddonTakeOverError`` for missing or altered
  ## preserved bytes, and whatever the driver raises for an unreadable
  ## package database.
  result.recordedMd5 = md5Hex(recordedBytes(e))
  let o = driver.packageOwner(e.path)
  if o.package.len == 0:
    if fileExists(e.path) or symlinkExists(e.path) or dirExists(e.path):
      result.kind = tuOrphanCopy
      return
    let pacsave = e.path & PacsaveSuffix
    if regularFileBeside(pacsave):
      result.pacsaveSha256 = sha256OfFile(pacsave)
    result.kind = if result.pacsaveSha256.len > 0 and
                     result.pacsaveSha256 == e.sha256: tuPacsaveDelete
                  else: tuPacsaveLeave
    return
  result.package = o.package
  result.backupMd5 = o.backupMd5
  let pacnew = e.path & PacnewSuffix
  if regularFileBeside(pacnew):
    result.pacnewBytes = readFile(pacnew)
    result.pacnewMd5 = md5Hex(result.pacnewBytes)
  when mutated("takeover-restores-recorded-bytes"):
    # FALSIFYING MUTATION: the first-touch bytes go back whatever pacman's
    # database now says the packaged version is.
    result.kind = tuRecorded
    return
  if o.backup and o.backupMd5.len > 0 and result.recordedMd5 == o.backupMd5:
    result.kind = tuRecorded
  elif o.backup and o.backupMd5.len > 0 and result.pacnewMd5.len > 0 and
      result.pacnewMd5 == o.backupMd5:
    result.kind = tuPacnew
  else:
    # Includes a package that no longer backs the path up (``o.backup``
    # false): no version pacman recognises can be named, so none is
    # written.
    result.kind = tuRefused

proc refusal*(e: LedgerEntry; u: TakeOverUndo): ref EAddOnPackageOwned =
  ## The ``EAddOnPackageOwned`` a ``tuRefused`` undo raises: the package,
  ## the path and the three digests.
  newAddOnTakeOverRestoreRefused(e.path, u.package, u.recordedMd5,
    u.pacnewMd5, (if u.backupMd5.len > 0: u.backupMd5
                  else: "none: the package no longer backs the path up"))

proc sameDecision*(a, b: TakeOverUndo): bool =
  ## Two decisions agree on everything the undo acts on: a write-time
  ## re-check refuses an undo whose inputs changed since the plan.
  a.kind == b.kind and a.package == b.package and a.backupMd5 == b.backupMd5 and
    a.recordedMd5 == b.recordedMd5 and a.pacnewMd5 == b.pacnewMd5 and
    a.pacsaveSha256 == b.pacsaveSha256

proc describe*(e: LedgerEntry; u: TakeOverUndo): string =
  ## One line for the plan, the apply's report and uninstall's output.
  case u.kind
  of tuRecorded:
    "restore the packaged bytes recorded at take-over (MD5 " &
      u.recordedMd5 & ", the version package " & u.package & "'s %BACKUP% holds)"
  of tuPacnew:
    "install " & e.path & PacnewSuffix & " (MD5 " & u.pacnewMd5 &
      ", the version package " & u.package & "'s %BACKUP% now holds; the " &
      "recorded bytes are MD5 " & u.recordedMd5 & ") and delete it"
  of tuRefused:
    "refused: the recorded bytes (MD5 " & u.recordedMd5 & ") and " &
      e.path & PacnewSuffix & " (" &
      (if u.pacnewMd5.len > 0: "MD5 " & u.pacnewMd5 else: "absent") &
      ") both differ from package " & u.package & "'s %BACKUP% MD5 " &
      (if u.backupMd5.len > 0: u.backupMd5 else: "(none)")
  of tuPacsaveDelete:
    "the package was removed and pacman kept the add-on's copy as " &
      e.path & PacsaveSuffix & ": delete it; " & e.path & " is not re-created"
  of tuPacsaveLeave:
    "the package was removed; " &
      (if u.pacsaveSha256.len > 0:
         e.path & PacsaveSuffix & " holds other bytes than the add-on's " &
           "(sha256 " & u.pacsaveSha256[0 ..< 12] & "), left in place"
       else: "no " & PacsaveSuffix & " beside it, nothing to delete") &
      "; " & e.path & " is not re-created"
  of tuOrphanCopy:
    "no package lists " & e.path & " any more: the add-on's copy is " &
      "removed, there are no packaged bytes to restore"

proc priorModeOwner(e: LedgerEntry): tuple[mode, uid, gid: int] =
  ## The mode and owner the path had before the take-over (the ledger's
  ## ``replaced`` value, ``f <mode> <uid:gid> sha256:...``), else the
  ## entry's own.
  var mode = e.mode
  var owner = e.owner
  let f = e.replaced.splitWhitespace()
  if f.len >= 3 and f[0] == "f":
    mode = f[1]
    owner = f[2]
  if mode.len == 0: mode = "0644"
  if owner.len == 0: owner = "0:0"
  let (uid, gid) = parseOwner(owner)
  (parseOctInt(mode), uid, gid)

proc applyTakeOverUndo*(e: LedgerEntry; u: TakeOverUndo): string =
  ## Carry out ``u`` and return its report line. Every write goes through
  ## the no-follow writer: the file is written beside the path and renamed
  ## over it, so the path holds the add-on's copy or the packaged bytes and
  ## is never missing. Raises the refusal for ``tuRefused``.
  case u.kind
  of tuRecorded:
    let (mode, uid, gid) = priorModeOwner(e)
    writeFileNoFollow(e.path, recordedBytes(e), mode, uid, gid)
  of tuPacnew:
    let (mode, uid, gid) = priorModeOwner(e)
    writeFileNoFollow(e.path, u.pacnewBytes, mode, uid, gid)
    discard removeLeafNoFollow(e.path & PacnewSuffix)
  of tuRefused:
    raise refusal(e, u)
  of tuPacsaveDelete:
    discard removeLeafNoFollow(e.path & PacsaveSuffix)
  of tuPacsaveLeave:
    discard
  of tuOrphanCopy:
    discard removeLeafNoFollow(e.path)
  describe(e, u)

proc takeOverAlreadyUndone*(e: LedgerEntry; driver: CollisionDriver): bool =
  ## A replayed switch finds the undo already done: the path holds bytes
  ## whose MD5 is the current ``%BACKUP%`` entry's, with no ``.pacnew`` of
  ## that version left beside it; or the package is gone and so are the
  ## path and the add-on's ``.pacsave``.
  if not isTakeOver(e): return false
  let o = driver.packageOwner(e.path)
  if o.package.len == 0:
    let pacsave = e.path & PacsaveSuffix
    return not (fileExists(e.path) or symlinkExists(e.path)) and
      not (regularFileBeside(pacsave) and sha256OfFile(pacsave) == e.sha256)
  o.backup and o.backupMd5.len > 0 and regularFileBeside(e.path) and
    md5OfFile(e.path) == o.backupMd5
