## DSL-port M9.R.6 — stdlib synthesis aggregator.
##
## Houses the macro-time + recipe-runtime helpers that synthesise
## canonical build pipelines for recipes that declare a ``fetch:``
## block + a recognised ``nativeBuildDeps:`` toolset but no explicit
## ``build:`` block. See
## ``reprobuild-specs/From-Source-DSL-Realignment.milestones.org``
## §M9.R.6 for the design.

import ./synthesis/from_source_default_build
export from_source_default_build
