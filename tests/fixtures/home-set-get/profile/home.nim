# nim-check: skip
#
# M83 Phase F3 migration: built via the Phase A `repro_profile` macro
# library so `repro home set` / `repro home apply` take the compile-
# then-apply path end-to-end. The package list is unchanged — only the
# import line moved from the legacy slash-form marker to the real
# Phase A macro library import.

import repro_profile

profile "m65-set-get-gate":
  activity default:
    git
    foo
