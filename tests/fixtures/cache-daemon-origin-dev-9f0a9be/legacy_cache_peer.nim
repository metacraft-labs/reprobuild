## A real, separately compiled exact-origin compatibility peer. The imported
## implementation modules are byte-identical to origin/dev 9f0a9be.

import ./origin/libs/repro_shm_index/src/repro_shm_index
import ./origin/libs/repro_shm_index/src/repro_shm_index/daemon

include ./legacy_cache_peer_main
