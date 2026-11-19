## Test-only driver for the binary-cache client: ``repro cache``.
##
## The shipping ``repro-binary-cache-client`` binary was retired and its
## toolset folded into ``repro cache <subcommand>`` (Binary-Caches.md
## §"Client CLI Surface (`repro cache`)"). The A2/A3/A4/R1 binary-cache
## integration tests, however, spawn a small standalone driver from
## ``build/test-bin/`` and pass it the bare subcommand verb
## (``lookup`` / ``substitute`` / ``publish`` / …) WITHOUT a ``cache``
## prefix. This file is that driver: it runs ``repro cache
## <commandLineParams()>`` -- repro's own declared command line, parsed by
## its generated parser, and the handlers ``repro cache`` runs
## (``repro_cli_support/cache_cli``) -- without linking the build engine.
##
## It is intentionally not an ``apps/`` entrypoint and is never shipped —
## the product surface is ``repro cache``.

import std/os

import repro_cli_support/cache_cli

when isMainModule:
  quit(runReproCacheArgs(commandLineParams()))
