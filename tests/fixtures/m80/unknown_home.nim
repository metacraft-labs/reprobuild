# nim-check: skip
#
# M83 Phase F2 migration: built via the Phase A `repro_profile` macro
# library so `repro home apply` takes the compile-then-apply path
# (Phase D) end-to-end.

import repro_profile

profile "m80-plan-classifier-unknown-gate":
  activity default:
    `m80-this-package-does-not-exist`
