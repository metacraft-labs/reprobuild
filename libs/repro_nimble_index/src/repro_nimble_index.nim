## `repro_nimble_index` -- the Nimble package index as the solver and the
## generator use it.
##
## * `reader` -- object sources, opening a root by hash, fetching and
##   verifying only the shards a lookup needs, memory-mapped objects.
## * `solver_input` -- candidates and their per-version requirements, for a
##   closure and a platform pair, in the solver's constraint language.
## * `builder` -- the deterministic writer of shards, name map, events and
##   root (the generator's `shard` and `root` edges).
## * `resolution` -- the solver input lowered to the solver's declarations,
##   the chosen records read back, module collisions and the diagnostics of
##   a failed resolution (NPC-M6).
## * `from_reader` -- a version record from the static `.nimble` reader's
##   output and the facts of one commit.
## * `layout` -- a record's layout and binary fields on one platform, its
##   conditional entries applied (the only way a consumer reads them).
##
## The objects themselves (types, bounded codec, navigator, text view) are
## `repro_domain_types/nimble_index`.

import repro_nimble_index/[reader, solver_input, builder, from_reader, resolution,
  layout]

export reader, solver_input, builder, from_reader, resolution, layout
