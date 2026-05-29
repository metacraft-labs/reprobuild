# nim-check: skip
#
# M83 Phase F2 migration: built via the Phase A `repro_profile` macro
# library so `repro home apply` takes the compile-then-apply path
# (Phase D) end-to-end. The activity body is intentionally empty —
# stow auto-discovery is the load-bearing surface for this fixture,
# not the package list.

import repro_profile

profile "stow-basic-gate":
  activity default:
    discard
