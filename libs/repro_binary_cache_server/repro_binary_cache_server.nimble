## ReproOS-Generations-And-Foreign-Packages A2 — binary-cache server library.
##
## Provides the Layer-3 server-side surface implementing the
## ``Binary-Caches.md`` design: typed manifest record / payload object /
## cache-entry-key types, SSZ/CBOR codec with version-tagged envelopes,
## ECDSA-P256 signing (reusing the peer-cache ``pki.nim`` / ``auth.nim``
## primitives), a thin SSZ index over the existing ``libs/repro_local_store/``
## content store, and the HTTP REST surface served by
## ``apps/repro-binary-cache/``.
##
## This is the SERVER-SIDE library. The substitution client lives in
## the planned ``libs/repro_binary_cache_client/`` per the A2.5 milestone.

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Binary-cache server library (ReproOS-Generations-And-Foreign-Packages A2)"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.0"
