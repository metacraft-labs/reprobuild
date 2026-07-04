## Action-Cache-Per-Edge-Store AC-2c — repro-cache-daemon.
##
## The single-writer shared-memory action-cache daemon for one cache root.
## Auto-spawned (detached) by a build engine on first open of a root with no
## live owner; the control-region pid/heartbeat election keeps exactly one
## owner. Self-reaps after an idle window so isolated / hermetic-test roots do
## not linger.

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Single-writer shared-memory action-cache daemon — AC-2c"
license       = "MIT"
srcDir        = "."
bin           = @["repro_cache_daemon"]

requires "nim >= 2.2.0"
