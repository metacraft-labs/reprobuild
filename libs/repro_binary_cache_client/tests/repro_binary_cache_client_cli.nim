## Test-only driver for the binary-cache client dispatch.
##
## The shipping ``repro-binary-cache-client`` binary was retired and its
## toolset folded into ``repro cache <subcommand>`` (Binary-Caches.md
## §"Client CLI Surface (`repro cache`)"). The A2/A3/A4/R1 binary-cache
## integration tests, however, spawn a small standalone driver from
## ``build/test-bin/`` and pass it the bare subcommand verb
## (``lookup`` / ``substitute`` / ``publish`` / …) WITHOUT a ``cache``
## prefix. This file is that driver: it forwards ``commandLineParams()``
## straight into the shared ``runCacheSubcommand`` dispatch, so the tests
## exercise byte-for-byte the SAME handlers that back ``repro cache``.
##
## It is intentionally not an ``apps/`` entrypoint and is never shipped —
## the product surface is ``repro cache``.

import std/os

import ../src/repro_binary_cache_client/cli_dispatch

when isMainModule:
  quit(runCacheSubcommand(commandLineParams()))
