## A store prefix the way a build before the directory-name widening left
## it: indexed, sealed, and named ``<version>-<first 16 hex>``.
##
## Local-Content-Addressed-Store.md §"Realization Hash (normative)" widened
## the name to 40 hex. A store an older build wrote keeps its prefixes under
## 16-hex names -- recorded in each prefix's receipt (``realizedPath``) and
## index row (``realized_path``), with the row's tree digest over that
## receipt -- and the tests of the readers that must still find them need
## such a prefix. No current API writes one (nothing may name a new prefix at
## the old width), so this fixture rewrites a freshly realized prefix into
## exactly that state: it moves the directory to the 16-hex leaf, re-seals
## the receipt with the path it now lies at, and updates the row's path,
## receipt digest and tree digest to match. The result is byte-for-byte what
## an older build's ``realizePrefix`` produced, except for timestamps.
##
## It deliberately uses only APIs that predate the widening
## (``safePathSegment``, ``prefixIdHex``, the receipt codec, the row), so a
## test built on it also compiles against a tree without the widening, where
## it shows which of its assertions that tree fails.

import std/[os, strutils]

import repro_local_store
import repro_local_store/sqlite3_binding

proc legacyLeafFor*(version: string; prefixId: PrefixIdBytes): string =
  ## ``<version>-<first 16 hex>``, spelled out rather than taken from
  ## ``legacyRealizationDirName`` so the fixture states the old contract on
  ## its own.
  safePathSegment(version, "v0") & "-" & prefixIdHex(prefixId)[0 ..< 16]

proc renameToLegacyWidth*(s: var Store; prefixId: PrefixIdBytes): string =
  ## Turn the indexed prefix of ``prefixId`` into the one an older build
  ## would have published, and return its store-relative path. Idempotent
  ## when the prefix already lies at its 16-hex name.
  let lookup = s.lookupPrefix(prefixId)
  doAssert lookup.found, "renameToLegacyWidth: prefix " &
    prefixIdHex(prefixId) & " is not indexed"
  let oldRel = lookup.row.realizedPath
  let oldAbs = s.absolutePrefixPath(oldRel)
  let receiptOld = readReceiptFile(oldAbs / ReceiptFileName)
  let slash = oldRel.rfind('/')
  let rel = oldRel[0 .. slash] & legacyLeafFor(receiptOld.version, prefixId)
  if rel == oldRel:
    return rel
  let newAbs = s.absolutePrefixPath(rel)
  moveDir(oldAbs, newAbs)
  var receipt = receiptOld
  receipt.realizedPath = rel
  let receiptPath = newAbs / ReceiptFileName
  let perms = getFilePermissions(receiptPath)
  setFilePermissions(receiptPath, perms + {fpUserWrite})
  writeReceiptFile(receiptPath, receipt)
  setFilePermissions(receiptPath, perms)
  var u = s.db.prepare("UPDATE prefixes SET realized_path = ?, " &
    "receipt_digest = ?, content_digest = ? WHERE prefix_id = ?")
  defer: u.finalize()
  u.bindText(1, rel)
  u.bindBlob(2, receiptDigest(receipt))
  u.bindBlob(3, prefixTreeDigest(newAbs))
  u.bindBlob(4, prefixId)
  discard u.step()
  forgetVerifiedPrefixes()
  rel
