## ReproOS-Generations-And-Foreign-Packages A2.5 — binary-cache client library.
##
## Provides the substitution-client surface that talks to a binary-cache
## server (A2) — lookup, manifest decode + ECDSA-P256 verify, streaming
## payload fetch with hash-as-you-go, and materialize-into-store.
##
## Architecture per ReproOS-Generations-And-Foreign-Packages.milestones.org
## § A2.5: every payload byte travels through one chained sink (HTTP
## receive → optional decompress → BLAKE3 update → write to a temp
## file under the local store; atomic rename on success). No round-trip
## through RAM-buffered intermediate buffers.

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Binary-cache substitution client (ReproOS-Generations-And-Foreign-Packages A2.5)"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.0"
