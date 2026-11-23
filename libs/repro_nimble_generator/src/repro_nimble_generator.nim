## `repro_nimble_generator` -- generating a Nimble package index from a
## source set, as build-graph edges.
##
## * `source_set` -- `nimble-sources.toml`, read as a closed TOML subset.
## * `egress` -- the origin egress policy every fetch passes.
## * `origin_git` -- git as the bounded, confined origin transport.
## * `source_tree` -- the source digest, canonical archive and tree facts.
## * `submodules` -- submodule URLs, bounds and the source object as one
##   composed tree.
## * `registry` -- `packages.json` at the pinned commit.
## * `edge_objects` -- the fetch edges' outputs, a closed vocabulary.
## * `assemble` -- one package's records, observation and origin events.
## * `generator` -- the edges and the generation.
## * `verify` -- comparing two generations of one index.
## * `capture` -- the append-only log of refusals and origin events.
## * `regeneration` -- the independent regeneration's verdict and hold.
## * `probe` -- the probe's sandbox.

import repro_nimble_generator/[source_set, egress, origin_git, source_tree,
  submodules, registry, edge_objects, assemble, generator, verify, capture,
  regeneration, probe]

export source_set, egress, origin_git, source_tree, submodules, registry,
  edge_objects, assemble, generator, verify, capture, regeneration, probe
