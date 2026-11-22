# repro_nimble_generator

Generates a Nimble package index (the objects `repro_nimble_index` reads)
from a source set, `nimble-sources.toml`, as build-graph edges run by the
build engine:

| Edge | Engine kind | Network | Output |
| --- | --- | --- | --- |
| `registry` | `bakMetadataFetch` | `netFetch` | `packages.json` at the pinned registry commit |
| `refs` | `bakMetadataFetch` | `netFetch` | an origin's tags (peeled) and `HEAD`, revalidated every generation |
| `refs-history` | `bakMetadataFetch` | `netFetch` | an origin's commits, to expand `#<commit>` abbreviations and detect rewritten history |
| `source` | `bakMetadataFetch` | `netFetch` | one commit's tree facts, `.nimble` and canonical archive (and, for a tree with gitlinks, its entries and blobs) |
| `submodule` | `bakMetadataFetch` | `netFetch` | one submodule commit's whole tree, one wave per nesting level |
| `source-compose` | `bakCatalogIndex` | none | a gitlinked version's source object: its tree with each submodule's in place |
| `read` | `bakCatalogIndex` | none | the version record the static reader reads from a `.nimble` |
| `shard`, `root` | `bakCatalogIndex` | none | the index objects |

The fetch edges hold no credential, reach origins only through the egress
policy (`egress.nim`: `https` only, public addresses only, every redirect
checked, size and stall limits), read trees from git objects so a symbolic
link is never followed, and fetch a gitlink only as a submodule source: its
`.gitmodules` URL, resolved and refused before any contact unless it is
`https`, vetted like any origin, at the commit it pins, within 8 levels and
256 submodules per version. A version one of whose submodules cannot be
obtained gets no record and a `gone` event naming the submodule. A version's `first_seen`
is the generation's own time; `cooldown_days` holds a version back from its
first sighting. Origin events (`repointed`, `tag-moved`,
`history-rewritten`, `gone`, `tag-removed`) are computed against the
previous generation, whose records are copied, never edited.

| Module | What it holds |
| --- | --- |
| `source_set.nim` | the closed-subset reader of `nimble-sources.toml` and the source set's identity |
| `egress.nim` | the origin egress policy |
| `origin_git.nim` | git as the bounded, confined origin transport |
| `source_tree.nim` | tree digest, canonical archive, links, gitlinks, the `.nimble` |
| `submodules.nim` | submodule URLs (relative resolution, rule 1 of the policy), nesting and count bounds, the source object composed and checked as one tree |
| `registry.nim` | `packages.json` |
| `edge_objects.nim` | the fetch edges' outputs, a closed vocabulary |
| `assemble.nim` | one package's records, observation and events |
| `generator.nim` | the edges and the generation |
| `verify.nim` | repeating a generation and comparing roots |

The verbs are `repro catalog generate` and `repro catalog verify`. The probe
(`probe = "sandboxed"`) is refused: it needs a confinement this build does
not provide yet.

Tests: `libs/repro_nimble_generator/tests/` (local origins served over real
HTTPS by `git http-backend`; nothing reaches the internet).

Publishing: when a generation writes `published-index/`, it first writes
every canonical archive of the generation to each directory `[[mirror]]` the
source set declares, then refuses to write anything unless every source
object the new index names is on every required mirror at its recorded size
(`repro_nimble_fetch/mirror`). An index with no required mirror is not
published. Mirrors are not part of the source set's identity.
