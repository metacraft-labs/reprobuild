## Peer-Cache-Scale M4 admin CLI nimble manifest.
##
## Build with: `nimble build` from this directory, or via the workspace
## entrypoint list (`apps/entrypoints.txt`). The CLI links against
## `repro_peer_cache` for the shared metrics rendering / event-log
## helpers, but the admin tool itself is a thin HTTP client that does
## not require the full daemon dependency set.

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Peer-cache admin CLI: status / peers / metrics views against a running tier-2 daemon"
license       = "MIT"
srcDir        = "."
bin           = @["repro_peer_cache_admin"]

requires "nim >= 2.2.0"
