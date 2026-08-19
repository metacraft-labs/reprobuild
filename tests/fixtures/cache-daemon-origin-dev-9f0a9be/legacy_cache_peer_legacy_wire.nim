## The same peer frontend compiled against the graph-generated legacy-wire
## tree. Only Darwin boot identity and ctl/segment path semantics differ from
## the exact origin/dev implementation.

import "../../../build/test-fixtures/cache-daemon-legacy-wire/libs/repro_shm_index/src/repro_shm_index"
import "../../../build/test-fixtures/cache-daemon-legacy-wire/libs/repro_shm_index/src/repro_shm_index/daemon"

include ./legacy_cache_peer_main
