## ReproOS-Generations-And-Foreign-Packages A2 — repro-binary-cache CLI.
##
## Long-lived HTTPS/HTTP daemon serving the package-level substitute
## plane per ``reprobuild-specs/Binary-Caches.md``. Wraps the library
## in ``libs/repro_binary_cache_server/`` and adds CLI option parsing
## + listening-loop lifecycle.

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Binary-cache server daemon — ReproOS-Generations-And-Foreign-Packages A2"
license       = "MIT"
srcDir        = "."
bin           = @["repro_binary_cache"]

requires "nim >= 2.2.0"
