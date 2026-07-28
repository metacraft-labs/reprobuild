## Windows-Runner-Binary-Cache-Deploy M6 HTTPS/TLS-gate test-helper entry.
##
## Uniquely-named `include` wrapper over the shipping `repro_binary_cache`
## entry module — see the note in `repro_binary_cache_a2.nim`. Built with
## `-d:ssl` so the M6 gate exercises the daemon's real-TLS HTTPS listener.
## The distinct projectName gives it its own linker response file, so it
## never collides with the plain helper or the shipped entrypoint.
include "repro_binary_cache.nim"
