## DSL-port M9.R.2b — Layer-2 operation overload aggregator.
##
## Re-exports the dispatcher entry points so call sites can
## ``import repro_dsl_stdlib/operations`` and reach ``compile`` /
## ``link`` / ``archive`` / ``strip`` plus the toolchain accessor.

import ./operations/toolchain
import ./operations/compile
import ./operations/link
import ./operations/archive
import ./operations/strip

export toolchain
export compile
export link
export archive
export strip
