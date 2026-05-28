version = "0.2.0"
author = "Metacraft Labs"
description = "Reprobuild monitor shim over platform hook runtimes (M26: ct_interpose hook_registry)"
license = "MIT"
srcDir = "src"

requires "nim >= 2.2.0"
# M26: the Windows shim now imports ct_interpose/hook_registry. The
# scripts/build_apps.sh pipeline injects the path manually because the Nim
# ecosystem treats sibling-checkout deps as path-passes rather than as
# nimble requirements; this declaration is purely documentary.
# requires "ct_interpose >= 0.1.0"
