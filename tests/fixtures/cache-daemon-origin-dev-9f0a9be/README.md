# Pinned `origin/dev` cache peer

This fixture builds a real second-process cache peer against the shared-memory
implementation from:

```
9f0a9be84c74985e094a32922b4dd4a210c64473
```

The files below `origin/` are byte-for-byte copies of these blobs at that
commit:

| Path | Git blob |
| --- | --- |
| `libs/repro_shm_index/src/repro_shm_index.nim` | `a389b01057e8b49121f8f9548839a203766d01d6` |
| `libs/repro_shm_index/src/repro_shm_index/atomics_shm.nim` | `c75688dbabbcc35136c08102dcd8c0c325f1df8b` |
| `libs/repro_shm_index/src/repro_shm_index/daemon.nim` | `b37b48f346b289cfca930d3d229ae0a1025c3167` |
| `libs/repro_shm_index/src/repro_shm_index/layout.nim` | `df83d182d3300dda193fd8401a192ab72131a88e` |
| `libs/repro_shm_index/src/repro_shm_index/mapping.nim` | `04be8410b0fbaad70e76bf94783f8ef062ba0d9f` |
| `libs/repro_shm_index/src/repro_shm_index/ring.nim` | `4a89b9b0a0a20f8b0c8d6be0fe63a401b0733753` |
| `libs/repro_shm_index/src/repro_shm_index/segment.nim` | `fe8de0849b59983e539252f5e6bea55ce5340416` |

`legacy_cache_peer.nim` is only a subprocess entry point. Owner election and
release call the complete, unmodified pinned `daemon.nim`; producer, consumer,
layout, mapping, ring, segment, and atomic operations call the pinned modules
directly. It deliberately does not import the working-tree `repro_shm_index`,
so mixed-version tests exercise two independently compiled implementations
instead of imitating the old behavior inside the new test binary.

To audit the checked-in source snapshot:

```sh
set -e
revision=$(git rev-parse '9f0a9be84c74985e094a32922b4dd4a210c64473^{commit}')

for src in \
  libs/repro_shm_index/src/repro_shm_index.nim \
  libs/repro_shm_index/src/repro_shm_index/atomics_shm.nim \
  libs/repro_shm_index/src/repro_shm_index/daemon.nim \
  libs/repro_shm_index/src/repro_shm_index/layout.nim \
  libs/repro_shm_index/src/repro_shm_index/mapping.nim \
  libs/repro_shm_index/src/repro_shm_index/ring.nim \
  libs/repro_shm_index/src/repro_shm_index/segment.nim
do
  cmp <(git show "$revision:$src") \
    "tests/fixtures/cache-daemon-origin-dev-9f0a9be/origin/$src"
done
```
