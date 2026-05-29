# nim-check: skip
#
# M83 Phase F2 migration: built via the Phase A `repro_profile` macro
# library so `repro home apply` takes the compile-then-apply path
# (Phase D) end-to-end.

import repro_profile

profile "stow-suppression-gate":
  activity default:
    `git-config`

  config:
    "git-config":
      userEmail = "config-block@example.com"
