# repro_nimble_fetch

The client side of the Nimble package catalog's source plane: every locked
Nimble package fetched by its content digest, verified, and kept in a local
content-addressed source store that every project of a user shares.

| Module | What it does |
| --- | --- |
| `tree_walk` | the canonical tree digest of a directory: every file with its executable bit, every symbolic link with its target, read with `lstat`, never followed |
| `archive_extract` | in-process tar extraction confined to a private staging directory: no unsafe name, no write through a link, no hard link or special file, no link out of the tree |
| `https_get` | bounded HTTPS reads: of a configured mirror, and of an origin's forge archive under the origin egress policy (every redirect re-vetted) |
| `mirror` | mirror locations (a directory or an `https://` base), their object layout, the publisher's write, and the check that every source object is on every required mirror |
| `lock_rows` | the `nimble:<name>` rows of a lock (origin, commit, `blake3:<tree>`) and the lock's closure key |
| `closure_index` | the lockfile-keyed closure index a mirror serves, accepted only when it agrees with the lock row for row |
| `store` | the source store: one verified tree per digest, installed by an atomic rename |
| `fetch` | the `nimble.fetch` edges (`bakSourceFetch`, `netFetch`): store, then mirrors, then the origin's forge archive, then the origin by git; every transport ends in the same extractor and the same digest check |
| `verify` | `repro nimble verify`: re-hash the store entries a lock names, offline |

A fetched tree is accepted exactly when it re-hashes to the digest the lock
records, whichever transport delivered it. The canonical archive's
`archive_sha256`, when the caller knows it from the index record, is checked
before the archive is parsed. A staging tree is discarded on any failure, so
the store only ever holds verified trees, and never a `.git` directory.

The per-package edges of one fetch run one after another: the engine runs an
executor-backed built-in edge inline, so concurrent fetch edges need engine
support that does not exist yet.
