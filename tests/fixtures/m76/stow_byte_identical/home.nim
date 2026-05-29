# nim-check: skip
#
# M83 Phase F3 migration: built via the Phase A `repro_profile` macro
# library so `repro home apply` takes the compile-then-apply path
# (Phase F3 made that the ONLY path — the legacy text parser no longer
# fires as an auto-fallback). The activity body is intentionally empty
# — stow auto-discovery is the load-bearing surface for this fixture,
# not the package list.

import repro_profile

profile "m76-stow-byte-identical-gate":
  activity default:
    discard
