# nim-check: skip
#
# M83 Phase F3 migration: built via the Phase A `repro_profile` macro
# library so `repro home apply` takes the compile-then-apply path
# end-to-end (Phase F3 made that the ONLY path — the legacy text parser
# no longer fires as an auto-fallback). The structural editor's
# source-text reader was extended in F3 to accept the backtick-quoted
# package form so the gate's add / remove operations still round-trip
# cleanly through the editor.

import repro_profile

profile "add-remove-immediate-gate":
  activity default:
    `seed-package`
