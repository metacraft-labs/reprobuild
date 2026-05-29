# nim-check: skip
#
# M83 Phase F2 migration: built via the Phase A `repro_profile` macro
# library so `repro home apply` takes the compile-then-apply path
# (Phase D) end-to-end. The legacy text parser is no longer the source
# of truth for this fixture.

import repro_profile

profile "fresh-install-gate":
  activity default:
    `fresh-install-fixture`
