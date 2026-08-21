## Named lock files: the declared NAME and everything that follows from it.
##
## Named-Lock-Files NLF-M7. The umbrella over three leaves, split by §3's three
## concepts so that nothing accidentally couples two of them:
##
##   * `declarations` — the **name**: what is declared, its doc comment, the
##     designation stack and the two diagnostics.
##   * `binding` — the **binding**: `--lock <name>=<path>`, one invocation.
##   * `propagation` — how a designation reaches a closure (§4.1 / §4.6).
##
## The **file** — one solved graph, pinned — is deliberately NOT here. It lives
## in `repro_lock`, which owns identity, and keeping the two libraries apart is
## how §6.2's requirement that "the lock file name … MUST NOT participate in
## any cache key" is kept structural rather than remembered: this library has
## no identity type to compose a name with, and `repro_lock/identity.nim` has
## no name field to compose an identity with.
##
## `std`-only by construction. Four layers depend on it (the project DSL's
## macros, the stdlib build context, the CLI, and the lock-generation path) and
## a leaf is the only shape all four can take.

import ./repro_lock_files/declarations
import ./repro_lock_files/binding
import ./repro_lock_files/propagation

export declarations
export binding
export propagation
