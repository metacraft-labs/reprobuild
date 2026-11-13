## The input-check policy an action-cache record was made under
## (Caching-Architecture.md; Edge-Derived-Identities.md §3.3a).
##
## Defined here, below `repro_local_store`, because a PUBLISHED record states
## it too (`rbpm-v2`, campaign M17 chunk 2): the portable memo record lives in
## a submodule `repro_local_store` itself imports, and the policy decides
## whether a record may cross hosts at all. `repro_local_store` re-exports it,
## so every existing user sees the same type.

type
  FileFingerprintPolicy* = enum
    ffpTimestamp
    ffpChecksum
    ffpHybrid
