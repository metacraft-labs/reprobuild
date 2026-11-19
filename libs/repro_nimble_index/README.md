# repro_nimble_index

Reads a Nimble package index by hash, for the solver, and writes one. An index
is a root object naming every shard by its BLAKE3 hash; a shard holds the
package envelopes and version records of the packages whose name key hashes to
its bucket. A reader fetches the root by the identity a lock pins, then only
the shards of the names it is asked about, checking each against the size and
hash the root records before decoding it with the bounded, canonical codec.

| Module | What it holds |
| --- | --- |
| `repro_nimble_index/reader.nim` | object sources (memory, an index directory, memory-mapped objects), `openIndex`, `loadShard`, `lookupPackage` |
| `repro_nimble_index/solver_input.nim` | `solverInput`: the candidates of a closure on one platform pair, each with its own version's requirements in the solver's constraint language, and the reasons a candidate is excluded; `perVersionDependencies` |
| `repro_nimble_index/builder.nim` | `buildIndex`, `buildShard`, `writeIndexDir`: the deterministic writer the generator's `shard` and `root` edges call |
| `repro_nimble_index/from_reader.nim` | `recordFromNimbleFile`: a version record from `repro_nimble_reader`'s output and one commit's facts |

The objects' types, codec, navigator and text view are
`repro_domain_types/nimble_index` (`libs/repro_domain_types/`). Inspect an
object with `repro debug artifact <file>`.

Tests: `libs/repro_nimble_index/tests/`.
