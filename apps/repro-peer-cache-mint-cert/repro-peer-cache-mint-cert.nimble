## Peer-Cache-BearSSL M4 mint-cert CLI nimble manifest.
##
## Standalone binary (rather than a `repro` umbrella sub-command)
## because the workspace's `repro` CLI is a 21k-line `runThinApp`
## entry point with hard-coded sub-command names parsed inside the
## dispatcher; adding a new sub-command would require threading
## changes through the whole CLI surface for a self-contained tool.
## A separate executable matches the existing
## `repro-peer-cache-admin` and `repro-peer-cache-tier2` precedent.

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Peer-cache cert mint: self-signed, CA, and CA-signed peer certs"
license       = "MIT"
srcDir        = "."
bin           = @["repro_peer_cache_mint_cert"]

requires "nim >= 2.2.0"
