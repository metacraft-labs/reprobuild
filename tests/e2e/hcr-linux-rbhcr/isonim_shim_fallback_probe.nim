## HLX-M8 — the NEGATIVE CONTROL for
## `e2e_hcr_linux_isonim_shim_against_real_agent`.
##
## The same IsoNim module, the same wrapper calls, built WITHOUT
## `-d:reprobuildHcr`. That is the branch every previous "IsoNim HCR is green
## on Linux" result actually took: `isonim/native/hcr.nim` compiles pure-Nim
## no-op bodies, emits no `rb_hcr_*` C symbol, and links no agent library.
##
## Its purpose is to make the positive gate's `nm -u` and `ldd` checks mean
## something. Without a binary that is known NOT to link the agent, "the ten
## symbols are undefined and resolved" is a claim about one artefact with
## nothing to compare it against — and the campaign's standing lesson is that a
## check which cannot distinguish two worlds has not measured either.

import isonim/native/hcr

when defined(reprobuildHcr):
  {.error: "isonim_shim_fallback_probe is the NO-OP control and must be " &
      "built without -d:reprobuildHcr; with the flag on it would link the " &
      "real agent and the positive gate's comparison would be between two " &
      "identical binaries.".}

proc main() =
  # Exercising the wrappers is what forces the fallback bodies to be emitted;
  # a probe that only imported the module might have them eliminated.
  rbHcrRegisterManagedType("HcrM8State")
  rbHcrBeforeReload(nil, nil)
  let wants = rbHcrWantsReload()
  rbHcrApplyReload()
  echo "{\"schemaId\":\"reprobuild.hcr.hlx-m8.isonim-fallback-probe.v1\"," &
    "\"wantsReload\":" & (if wants: "true" else: "false") &
    ",\"fileChanged\":" &
    (if rbHcrFileChanged("hcr_lx_m8_views.nim"): "true" else: "false") & "}"

main()
