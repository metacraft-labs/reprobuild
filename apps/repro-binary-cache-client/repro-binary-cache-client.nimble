## ReproOS-Generations-And-Foreign-Packages A3 P2 — CLI shim.
##
## A small executable that lets the R4-R9 build scripts (bash) call
## the substitute / publish / lookup primitives from
## ``libs/repro_binary_cache_client/`` without each script writing a
## Nim wrapper of its own.
##
## Subcommands:
##   lookup     <entry-key-hex>                  — does the server have
##                                                  a manifest? exit 0
##                                                  on hit, 1 on miss.
##   substitute <entry-key-hex> <out-prefix-dir> — fetch + materialise
##                                                  into <out-prefix-dir>.
##   publish    <entry-key-hex> <prefix-dir>     — package + sign +
##                                                  upload.

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Binary-cache substitution CLI (ReproOS A3 P2)"
license       = "MIT"
srcDir        = "."
bin           = @["repro_binary_cache_client_cli"]

requires "nim >= 2.2.0"
