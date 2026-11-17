## Where a realized prefix lives on a given store: the one on-host resolver
## from a realization id to its path.
##
## Local-Content-Addressed-Store.md §"Realization Hash (normative)" names a
## prefix ``<version>-<first 40 hex of the realization hash>``
## (``prefix_paths.realizationDirName``). Builds before that used the first
## 16 hex (``prefix_paths.legacyRealizationDirName``), and a store they wrote
## still holds prefixes under those names: indexed, sealed with a receipt
## recording that path, and possibly bound by running units. Moving one would
## break whatever binds it, so it stays where it lies, and every reader has to
## find it there.
##
## THE INVARIANT this module exists to keep: on a given store, one id has
## exactly one path, and every reader agrees on it.
##
## * A prefix an older build wrote lives at its 16-hex name. It is recognised
##   by its receipt: a directory at that name whose ``.repro-receipt`` records
##   EXACTLY this realization hash and EXACTLY that path. The full 256-bit
##   hash in the receipt is what tells two ids apart that share 64 bits, so a
##   16-hex directory holding another id's prefix is never taken for this
##   one's.
## * Every other prefix -- every prefix any current build creates -- lives at
##   its 40-hex name. Nothing names a new prefix at the 16-hex width: an id
##   with no prefix under its legacy name resolves to the 40-hex name, so it
##   is realized there.
##
## The store's writer (``store.realizePrefix``) applies the same rule with
## the index row as its authority (it also honours a row that records the
## legacy path while that directory is being restored), so a reader that
## cannot open the index -- the resolving launcher, a plan computed before
## the store is opened -- and the writer name the same directory.
##
## WHY THIS IS ITS OWN MODULE. The callers that need it are the path-only
## ones (``repro_selfhost`` and the resolving launcher above it, the add-on's
## planned paths, the tool profiles' adapters) which deliberately do not link
## the store runtime. Answering "where does this id live" for a legacy prefix
## needs its receipt, and reading a receipt needs only ``receipt_codec``; so
## this module imports that and ``prefix_paths`` and nothing that opens
## SQLite, exactly as ``prefix_paths`` and ``realization_hash`` were split out
## for the same callers.

import std/[os, strutils]

from repro_core/paths import extendedPath

import ./prefix_paths
import ./receipt_codec

type
  LegacyPrefixOccupant* = enum
    ## What occupies the 16-hex name of an id on a store.
    lpoAbsent
      ## Nothing, or nothing that is a directory (a symbolic link or a file
      ## at a prefix path is never a prefix the store published).
    lpoThisId
      ## A directory whose receipt records this realization hash at exactly
      ## this path: the prefix an older build realized for this id.
    lpoOtherId
      ## A directory whose readable receipt records ANOTHER realization hash:
      ## an id that shares this one's first 64 bits, realized by an older
      ## build. It is that id's prefix, never this one's, and this id lives
      ## at its 40-hex name.
    lpoUnrecognised
      ## A directory with no readable receipt, or a receipt for this hash at
      ## another path. Not a prefix any reader may take for this id.

proc toSlash(value: string): string = value.replace('\\', '/')

proc legacyPrefixOccupant*(storeRoot, legacyRelativePath: string;
                           prefixId: PrefixIdBytes): LegacyPrefixOccupant =
  ## Classify what lies at ``storeRoot / legacyRelativePath`` (the id's
  ## ``legacyPrefixRelativePath``) for ``prefixId``. Never modifies anything.
  let dir = storeRoot / legacyRelativePath
  try:
    if getFileInfo(extendedPath(dir), followSymlink = false).kind != pcDir:
      return lpoAbsent
  except OSError:
    return lpoAbsent
  let receiptPath = dir / ReceiptFileName
  try:
    if getFileInfo(extendedPath(receiptPath),
                   followSymlink = false).kind != pcFile:
      return lpoUnrecognised
  except OSError:
    return lpoUnrecognised
  var receipt: RealizationReceipt
  try:
    receipt = readReceiptFile(receiptPath)
  except CatchableError:
    return lpoUnrecognised
  if receipt.realizationHash != prefixId:
    return lpoOtherId
  if toSlash(receipt.realizedPath) != toSlash(legacyRelativePath):
    return lpoUnrecognised
  lpoThisId

proc resolvePrefixRelativePath*(storeRoot, packageName, version: string;
                                prefixId: PrefixIdBytes;
                                outputName = ""): string =
  ## The store-relative path (forward slashes) of ``prefixId``'s prefix on
  ## the store at ``storeRoot``: its legacy 16-hex path when an older build's
  ## prefix of exactly this id lies there (``lpoThisId``), its 40-hex path
  ## (``prefixRelativePath``) otherwise -- including when nothing is realized
  ## yet, which is where a new prefix is placed. An empty ``storeRoot``
  ## (no store to look at) is the 40-hex path.
  let legacy = legacyPrefixRelativePath(packageName, version, prefixId,
                                        outputName)
  if storeRoot.len > 0 and
      legacyPrefixOccupant(storeRoot, legacy, prefixId) == lpoThisId:
    return legacy
  prefixRelativePath(packageName, version, prefixId, outputName)

proc resolvePrefixAbsolutePath*(storeRoot, packageName, version: string;
                                prefixId: PrefixIdBytes;
                                outputName = ""): string =
  ## ``storeRoot / resolvePrefixRelativePath(...)``.
  storeRoot / resolvePrefixRelativePath(storeRoot, packageName, version,
                                        prefixId, outputName)

proc isPrefixPathOf*(relativePath, packageName, version: string;
                     prefixId: PrefixIdBytes; outputName = ""): bool =
  ## Whether ``relativePath`` is one of the two names ``prefixId`` can have:
  ## its 40-hex path, or its legacy 16-hex path. A shape check only; which
  ## of the two it lives at on a store is ``resolvePrefixRelativePath``'s
  ## answer.
  let rel = toSlash(relativePath)
  rel == prefixRelativePath(packageName, version, prefixId, outputName) or
    rel == legacyPrefixRelativePath(packageName, version, prefixId,
                                    outputName)

proc prefixDirMatchesReceipt*(relativeDir: string;
                              receipt: RealizationReceipt): bool =
  ## Whether a directory at ``relativeDir`` (``prefixes/<package>/<leaf>``,
  ## relative to the store root it lies in) is named for the receipt sealed
  ## inside it: its leaf is the receipt's 40-hex ``realizationDirName``, or
  ## it is the 16-hex ``legacyRealizationDirName`` AND the receipt records
  ## exactly this path (an older build's prefix, sealed where it lies).
  ##
  ## The check the store's recovery, ``store copy`` and bundle import apply
  ## before trusting a directory found on disk. Nothing else about it is
  ## relaxed: a legacy name with a receipt recording another path, or a leaf
  ## of any other shape, does not match.
  let rel = toSlash(relativeDir)
  let slash = rel.rfind('/')
  let leaf = if slash >= 0: rel[slash + 1 .. ^1] else: rel
  if leaf == realizationDirName(receipt.version, receipt.realizationHash):
    return true
  leaf == legacyRealizationDirName(receipt.version, receipt.realizationHash) and
    toSlash(receipt.realizedPath) == rel
