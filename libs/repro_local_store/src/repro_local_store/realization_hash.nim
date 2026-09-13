## The store's realization-hash computation, split out of ``store.nim``.
##
## Same reason ``prefix_paths`` was split out: a caller that needs to know
## WHERE a realized prefix lives should not have to link the store runtime to
## find out. ``prefix_paths`` gave that caller the directory arithmetic; this
## module gives it the hash that arithmetic is keyed on, so the pair is now
## enough to name a prefix without opening SQLite.
##
## M5 SELF-HOST is the caller that made the second half necessary. The
## resolving launcher (``repro`` trampoline) has to turn a project's committed
## pin into ``<store>/prefixes/reprobuild/<version>-<hash16>/bin/repro`` before
## any reprobuild exists to ask, and a launcher that opens the store index to
## answer that question has recursed on its own dependency problem — the same
## argument ``apps/repro-launcher`` records for staying on kernel32.
##
## ``store.nim`` imports and re-exports this module, so every existing
## ``repro_local_store`` consumer keeps seeing ``computeRealizationHash``
## unchanged.

import blake3
import repro_core/codec

import ./prefix_paths
export prefix_paths

proc computeRealizationHash*(packageName, version, adapter,
                            lockIdentity, declaredExecutablePath: string;
                            provenanceUrl = ""; provenanceChecksum = "";
                            extra: openArray[string] = []): PrefixIdBytes =
  ## Deterministic identity for a realized prefix. Adapters compose the
  ## inputs that fully determine the bytes of the prefix; the store then
  ## treats this hash as opaque.
  var buf: seq[byte] = @[]
  buf.writeString("reprobuild.realization.v1")
  buf.writeString(adapter)
  buf.writeString(packageName)
  buf.writeString(version)
  buf.writeString(lockIdentity)
  buf.writeString(declaredExecutablePath)
  buf.writeString(provenanceUrl)
  buf.writeString(provenanceChecksum)
  buf.writeU32Le(uint32(extra.len))
  for value in extra:
    buf.writeString(value)
  blake3.digest(buf)
