## ReproOS-Generations-And-Foreign-Packages A2 — umbrella module.
##
## Re-exports the implementation modules so callers can
## ``import repro_binary_cache_server`` and pull the whole surface:
##
##   * ``types`` — ``BinaryCacheManifest`` / ``PayloadObject`` /
##                 ``CacheEntryKey`` / ``CacheInfoRecord``
##                 + the format-version + envelope-magic constants.
##   * ``key`` — canonical ``CacheEntryKey`` encoder + 32-byte digest
##                 helpers + hex parsers used by the HTTP URL parser.
##   * ``manifest_codec`` — SSZ-style envelope encode/decode + ECDSA-P256
##                          sign + verify on top of the peer-cache
##                          ``auth.nim`` primitives.
##   * ``index`` — thin SSZ index over the local-store CAS rooted at
##                 ``<server-root>/{manifests,index}/``; ride on
##                 ``libs/repro_local_store/`` for payload blobs.
##   * ``server`` — HTTP REST handlers (``/cache-info`` /
##                 ``/manifests/<hex>`` / ``/payloads/<hex>`` /
##                 ``/publish``).
##
## See ``D:/metacraft/reprobuild/recipes/cache/README.md`` for the
## operator handbook + threat model.

import ./repro_binary_cache_server/types
import ./repro_binary_cache_server/key
import ./repro_binary_cache_server/manifest_codec
import ./repro_binary_cache_server/index
import ./repro_binary_cache_server/server

export types
export key
export manifest_codec
export index
export server
