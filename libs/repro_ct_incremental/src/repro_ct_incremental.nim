## Public API of the `repro_ct_incremental` library.
##
## Trace-based incremental testing engine for `repro watch` (prototype). M0
## ships the CodeTracer-trace reader that returns a run's executed functions;
## later milestones add the shallow/deep-hash invalidation engine and the
## `repro watch --ct-incremental` integration.
##
## See `docs/Trace-Based-Incremental-Testing.milestones.org` in the reprobuild
## repo for the campaign plan.

import repro_ct_incremental/trace_reader
import repro_ct_incremental/extractors
import repro_ct_incremental/engine
import repro_ct_incremental/watch

export trace_reader
export extractors
export engine
export watch
